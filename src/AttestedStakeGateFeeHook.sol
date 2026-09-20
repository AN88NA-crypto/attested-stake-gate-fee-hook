// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC8183Hook is IERC165 {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}

/// @notice Matches the real deployed AgenticCommerceV3 core's Job struct --
/// (client, status, provider, expiredAt, evaluator, hook, budget,
/// description) -- confirmed against its verified source via `cast source`,
/// not assumed. `status` is declared `uint8` rather than mirroring the
/// core's own JobStatus enum: ABI-encodes identically, and keeps this
/// interface decoupled from an enum type we don't own. paymentToken is NOT
/// part of the Job struct on this core -- it's a single contract-wide
/// value, read separately.
interface IERC8183Core {
    struct Job {
        address client;
        uint8 status;
        address provider;
        uint48 expiredAt;
        address evaluator;
        address hook;
        uint256 budget;
        string description;
    }

    function getJob(uint256 jobId) external view returns (Job memory);
    function paymentToken() external view returns (address);
}

/// @dev Only selector + return shape matter; every staking contract that
/// exposes a per-agent balance under some name can be adapted by pointing
/// `stakeSelector` at it. Called via gas-capped staticcall, never via a
/// solidity-level external call, so a hostile or broken staking contract
/// cannot consume the caller's gas or brick funding.
interface IAgentStaking {
    function stakedBalanceOf(address agent) external view returns (uint256);
}

abstract contract BaseERC8183Hook is IERC8183Hook {
    address public immutable coreJob;

    error NotCoreJob(address caller);

    constructor(address coreJob_) {
        if (coreJob_ == address(0)) revert NotCoreJob(address(0));
        coreJob = coreJob_;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        if (msg.sender != coreJob) revert NotCoreJob(msg.sender);
        if (selector == fundSelector()) _preFund(jobId, data);
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        if (msg.sender != coreJob) revert NotCoreJob(msg.sender);
        if (selector == completeSelector()) _postComplete(jobId, data);
        else if (selector == rejectSelector()) _postReject(jobId, data);
    }

    function fundSelector() public view virtual returns (bytes4);
    function completeSelector() public view virtual returns (bytes4);
    function rejectSelector() public view virtual returns (bytes4);

    function _preFund(uint256 jobId, bytes calldata data) internal virtual;
    function _postComplete(uint256 jobId, bytes calldata data) internal virtual;
    function _postReject(uint256 jobId, bytes calldata data) internal virtual;

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title AttestedStakeGateFeeHook
/// @notice ERC-8183 hook for Base (chainId 8453).
///
/// FEE COLLECTION: taken into the hook's own custody at fund() time, out of
/// the client's approval, inside beforeAction, where a revert is free and
/// total: no fee, no escrow, no job. `client` below is read from the core's
/// own job record (_loadJob), not unchecked calldata, and this whole path
/// is gated by onlyCoreJob -- pulling from the client's wallet (not
/// msg.sender) is the entire point of that transfer.
///
/// REPUTATION SOURCE: no live registry call. Scores arrive as EIP-712
/// attestations signed off-chain by an allowlisted attestor, bound to
/// (provider, jobId) and expiring. The score never replaces stake, only
/// buys down the required stake against a floor that is never zero.
contract AttestedStakeGateFeeHook is
    BaseERC8183Hook,
    Ownable2Step,
    Pausable,
    ReentrancyGuardTransient,
    EIP712
{
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000;
    uint256 public constant MAX_SCORE = 10_000;
    uint256 public constant MIN_STAKE_CALL_GAS = 30_000;
    uint256 public constant MAX_STAKE_CALL_GAS = 500_000;
    uint256 public constant STAKE_CALL_GAS_OVERHEAD = 10_000;
    /// @dev Mutable, not constant: a proxied or multi-SLOAD staking
    /// contract discovered post-deployment to need more than the initial
    /// budget would otherwise permanently brick every provider's fund()
    /// with no on-chain remediation.
    uint256 public stakeCallGas = 80_000;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "ReputationAttestation(address provider,uint256 jobId,uint16 score,uint64 expiry,bytes32 salt)"
    );

    enum FeeState {
        None,
        Escrowed,
        Earned,
        Refunded
    }

    struct FeeRecord {
        address token;
        uint128 amount;
        FeeState state;
    }

    struct StakeTier {
        uint16 minScore;
        uint256 requiredStake;
    }

    address public stakingContract;
    address public feeWallet;
    uint256 public feeBps;
    uint256 public absoluteStakeFloor;
    uint256 public unattestedStakeRequirement;

    bytes4 private _fundSelector;
    bytes4 private _completeSelector;
    bytes4 private _rejectSelector;

    StakeTier[] private _stakeTiers;

    mapping(address => bool) public isAttestor;
    mapping(bytes32 => bool) public revokedAttestation;
    mapping(bytes32 => bool) public consumedAttestation;
    mapping(uint256 => FeeRecord) public feeOf;
    mapping(address => uint256) public accruedFees;

    event ProviderAdmitted(
        uint256 indexed jobId, address indexed provider, uint256 score, uint256 staked, uint256 requiredStake
    );
    event FeeEscrowed(uint256 indexed jobId, address indexed client, address token, uint256 amount);
    event FeeEarned(uint256 indexed jobId, address token, uint256 amount);
    event FeeRefunded(uint256 indexed jobId, address indexed client, address token, uint256 amount);
    event FeeWithdrawn(address indexed token, address indexed to, uint256 amount);
    event AttestorSet(address indexed attestor, bool allowed);
    event AttestationRevoked(bytes32 indexed digest);
    event StakeTiersUpdated(uint256 tierCount);
    event ConfigUpdated(string field, uint256 value);
    event FeeWalletUpdated(address indexed feeWallet);
    event SelectorsUpdated(bytes4 fundSelector, bytes4 completeSelector, bytes4 rejectSelector);

    error ZeroAddress();
    error FeeBpsTooHigh(uint256 requested, uint256 max);
    error StakeTooLow(address provider, uint256 staked, uint256 required);
    error StakeReadFailed(address provider);
    error InsufficientGasForStakeCheck(uint256 available, uint256 required);
    error AttestationAlreadyConsumed(bytes32 digest);
    error AttestationExpired(uint64 expiry);
    error AttestationProviderMismatch(address attested, address actual);
    error AttestationJobMismatch(uint256 attested, uint256 actual);
    error AttestationRevokedError(bytes32 digest);
    error UnknownAttestor(address recovered);
    error ScoreOutOfRange(uint256 score);
    error JobLookupFailed(uint256 jobId);
    error FeeAlreadyRecorded(uint256 jobId);
    error FeeAmountOverflowsUint128(uint256 feeAmount);
    error FeeTransferShortfall(uint256 expected, uint256 received);
    error StakeCallGasOutOfRange(uint256 requested, uint256 min, uint256 max);
    error NothingToReconcile(uint256 jobId);
    error TiersNotMonotonic();
    error TierBelowFloor(uint256 requiredStake, uint256 floor);
    error InsufficientAccrual(address token, uint256 requested, uint256 available);

    /// @dev Confirmed for AgenticCommerceV3: Open=0, Funded=1, Submitted=2,
    /// Completed=3, Rejected=4, Expired=5. Still injected via constructor
    /// rather than hardcoded, since other cores may order differently.
    uint8 public completedStatus;
    uint8 public rejectedStatus;
    uint8 public expiredStatus;

    constructor(
        address coreJob_,
        address stakingContract_,
        address feeWallet_,
        address owner_,
        address initialAttestor_,
        uint256 feeBps_,
        uint256 absoluteStakeFloor_,
        uint256 unattestedStakeRequirement_,
        bytes4[3] memory selectors_,
        uint8[3] memory terminalStatuses_
    ) BaseERC8183Hook(coreJob_) Ownable(owner_) EIP712("AttestedStakeGateFeeHook", "1") {
        if (
            stakingContract_ == address(0) || feeWallet_ == address(0) || owner_ == address(0)
                || initialAttestor_ == address(0)
        ) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeBpsTooHigh(feeBps_, MAX_FEE_BPS);
        if (unattestedStakeRequirement_ < absoluteStakeFloor_) {
            revert TierBelowFloor(unattestedStakeRequirement_, absoluteStakeFloor_);
        }

        stakingContract = stakingContract_;
        feeWallet = feeWallet_;
        feeBps = feeBps_;
        absoluteStakeFloor = absoluteStakeFloor_;
        unattestedStakeRequirement = unattestedStakeRequirement_;
        isAttestor[initialAttestor_] = true;

        _fundSelector = selectors_[0];
        _completeSelector = selectors_[1];
        _rejectSelector = selectors_[2];

        completedStatus = terminalStatuses_[0];
        rejectedStatus = terminalStatuses_[1];
        expiredStatus = terminalStatuses_[2];

        emit AttestorSet(initialAttestor_, true);
    }

    function fundSelector() public view override returns (bytes4) {
        return _fundSelector;
    }

    function completeSelector() public view override returns (bytes4) {
        return _completeSelector;
    }

    function rejectSelector() public view override returns (bytes4) {
        return _rejectSelector;
    }

    // -----------------------------------------------------------------
    // fund(): gate + fee escrow.
    // -----------------------------------------------------------------

    function _preFund(uint256 jobId, bytes calldata data) internal override whenNotPaused nonReentrant {
        (address client, address provider, uint256 budget,) = _loadJob(jobId);
        address paymentToken = IERC8183Core(coreJob).paymentToken();

        // The real core wraps fund()'s hook payload as
        // abi.encode(msg.sender, optParams) -- confirmed against its
        // verified source (AgenticCommerceV3.fund). Unwrap before handing
        // the inner bytes to attestation verification.
        (, bytes memory optParams) = abi.decode(data, (address, bytes));

        (uint256 score, bytes32 digest) = _verifyAttestation(provider, jobId, optParams);
        uint256 required = requiredStakeFor(score);
        uint256 staked = _readStake(provider);
        if (staked < required) revert StakeTooLow(provider, staked, required);

        if (digest != bytes32(0)) consumedAttestation[digest] = true;

        emit ProviderAdmitted(jobId, provider, score, staked, required);

        uint256 feeAmount = (budget * feeBps) / BPS_DENOMINATOR;
        if (feeAmount == 0) return;
        if (feeOf[jobId].state != FeeState.None) revert FeeAlreadyRecorded(jobId);
        if (feeAmount > type(uint128).max) revert FeeAmountOverflowsUint128(feeAmount);

        feeOf[jobId] = FeeRecord({token: paymentToken, amount: uint128(feeAmount), state: FeeState.Escrowed});

         // Balance-delta check: a fee-on-transfer or rebasing payment token
        // would otherwise leave the recorded amount and the held amount
        // permanently out of step, making later refunds under-fund.
        uint256 before = IERC20(paymentToken).balanceOf(address(this));
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        // Safe: `client` comes from the core's own job record (_loadJob),
        // not unchecked calldata, and this call is gated by onlyCoreJob.
        // Pulling from the client's wallet is the entire point of this line.
        IERC20(paymentToken).safeTransferFrom(client, address(this), feeAmount);
        uint256 received = IERC20(paymentToken).balanceOf(address(this)) - before;
        if (received != feeAmount) revert FeeTransferShortfall(feeAmount, received);

        emit FeeEscrowed(jobId, client, paymentToken, feeAmount);
    }

    function _postComplete(uint256 jobId, bytes calldata /* data */ ) internal override {
        FeeRecord storage rec = feeOf[jobId];
        if (rec.state != FeeState.Escrowed) return;
        rec.state = FeeState.Earned;
        accruedFees[rec.token] += rec.amount;
        emit FeeEarned(jobId, rec.token, rec.amount);
    }

    function _postReject(uint256 jobId, bytes calldata /* data */ ) internal override {
        FeeRecord storage rec = feeOf[jobId];
        if (rec.state != FeeState.Escrowed) return;
        rec.state = FeeState.Refunded;
        emit FeeRefunded(jobId, address(0), rec.token, rec.amount);
    }

    /// @notice Permissionless repair + expiry path. claimRefund/expiry is
    /// non-hookable, so expired jobs produce no callback and the escrowed
    /// fee would otherwise be stranded.
    function reconcile(uint256 jobId) external {
        FeeRecord storage rec = feeOf[jobId];
        if (rec.state != FeeState.Escrowed) revert NothingToReconcile(jobId);

        (, , , uint8 status) = _loadJob(jobId);

        if (status == completedStatus) {
            rec.state = FeeState.Earned;
            accruedFees[rec.token] += rec.amount;
            emit FeeEarned(jobId, rec.token, rec.amount);
        } else if (status == rejectedStatus || status == expiredStatus) {
            rec.state = FeeState.Refunded;
            emit FeeRefunded(jobId, address(0), rec.token, rec.amount);
        } else {
            revert NothingToReconcile(jobId);
        }
    }

    function claimFeeRefund(uint256 jobId) external nonReentrant {
        FeeRecord storage rec = feeOf[jobId];
        if (rec.state != FeeState.Refunded) revert NothingToReconcile(jobId);

        (address client, , , ) = _loadJob(jobId);
        uint256 amount = rec.amount;
        address token = rec.token;
        rec.amount = 0;
        rec.state = FeeState.None;

        IERC20(token).safeTransfer(client, amount);
        emit FeeRefunded(jobId, client, token, amount);
    }

    function withdrawFees(address token, uint256 amount) external onlyOwner nonReentrant {
        uint256 available = accruedFees[token];
        if (amount > available) revert InsufficientAccrual(token, amount, available);
        accruedFees[token] = available - amount;
        IERC20(token).safeTransfer(feeWallet, amount);
        emit FeeWithdrawn(token, feeWallet, amount);
    }

    function _verifyAttestation(address provider, uint256 jobId, bytes memory data)
        private
        view
        returns (uint256 score, bytes32 digest)
    {
        if (data.length == 0) return (0, bytes32(0));

        (address attProvider, uint256 attJobId, uint16 attScore, uint64 expiry, bytes32 salt, bytes memory signature) =
            abi.decode(data, (address, uint256, uint16, uint64, bytes32, bytes));

        if (attProvider != provider) revert AttestationProviderMismatch(attProvider, provider);
        if (attJobId != jobId) revert AttestationJobMismatch(attJobId, jobId);
        if (expiry <= block.timestamp) revert AttestationExpired(expiry);
        if (attScore > MAX_SCORE) revert ScoreOutOfRange(attScore);

        digest = _hashTypedDataV4(
            keccak256(abi.encode(ATTESTATION_TYPEHASH, provider, jobId, attScore, expiry, salt))
        );
        if (revokedAttestation[digest]) revert AttestationRevokedError(digest);
        if (consumedAttestation[digest]) revert AttestationAlreadyConsumed(digest);

        address recovered = ECDSA.recover(digest, signature);
        if (!isAttestor[recovered]) revert UnknownAttestor(recovered);

        return (attScore, digest);
    }

    function requiredStakeFor(uint256 score) public view returns (uint256) {
        if (score == 0) return unattestedStakeRequirement;
        uint256 n = _stakeTiers.length;
        for (uint256 i = n; i > 0;) {
            unchecked {
                --i;
            }
            StakeTier storage tier = _stakeTiers[i];
            if (score >= tier.minScore) {
                return tier.requiredStake < absoluteStakeFloor ? absoluteStakeFloor : tier.requiredStake;
            }
        }
        return unattestedStakeRequirement;
    }

    function _readStake(address provider) private view returns (uint256) {
        uint256 required = stakeCallGas + STAKE_CALL_GAS_OVERHEAD;
        if ((gasleft() * 63) / 64 < required) {
            revert InsufficientGasForStakeCheck(gasleft(), required);
        }
        (bool ok, bytes memory ret) = stakingContract.staticcall{gas: stakeCallGas}(
            abi.encodeCall(IAgentStaking.stakedBalanceOf, (provider))
        );
        if (!ok || ret.length < 32) revert StakeReadFailed(provider);
        return abi.decode(ret, (uint256));
    }

    function _loadJob(uint256 jobId)
        private
        view
        returns (address client, address provider, uint256 budget, uint8 status)
    {
        try IERC8183Core(coreJob).getJob(jobId) returns (IERC8183Core.Job memory job) {
            return (job.client, job.provider, job.budget, job.status);
        } catch {
            revert JobLookupFailed(jobId);
        }
    }

    function setAttestor(address attestor, bool allowed) external onlyOwner {
        if (attestor == address(0)) revert ZeroAddress();
        isAttestor[attestor] = allowed;
        emit AttestorSet(attestor, allowed);
    }

    function revokeAttestation(bytes32 digest) external onlyOwner {
        revokedAttestation[digest] = true;
        emit AttestationRevoked(digest);
    }

    function setStakeTiers(StakeTier[] calldata tiers) external onlyOwner {
        delete _stakeTiers;
        uint256 lastScore = 0;
        uint256 lastStake = type(uint256).max;
        for (uint256 i = 0; i < tiers.length; ++i) {
            if (i > 0 && tiers[i].minScore <= lastScore) revert TiersNotMonotonic();
            if (tiers[i].requiredStake > lastStake) revert TiersNotMonotonic();
            if (tiers[i].requiredStake < absoluteStakeFloor) {
                revert TierBelowFloor(tiers[i].requiredStake, absoluteStakeFloor);
            }
            if (tiers[i].minScore > MAX_SCORE) revert ScoreOutOfRange(tiers[i].minScore);
            lastScore = tiers[i].minScore;
            lastStake = tiers[i].requiredStake;
            _stakeTiers.push(tiers[i]);
        }
        emit StakeTiersUpdated(tiers.length);
    }

    function stakeTiers() external view returns (StakeTier[] memory) {
        return _stakeTiers;
    }

    function setStakingContract(address newStaking) external onlyOwner {
        if (newStaking == address(0)) revert ZeroAddress();
        stakingContract = newStaking;
        emit ConfigUpdated("stakingContract", uint256(uint160(newStaking)));
    }

    function setStakeCallGas(uint256 newGas) external onlyOwner {
        if (newGas < MIN_STAKE_CALL_GAS || newGas > MAX_STAKE_CALL_GAS) {
            revert StakeCallGasOutOfRange(newGas, MIN_STAKE_CALL_GAS, MAX_STAKE_CALL_GAS);
        }
        stakeCallGas = newGas;
        emit ConfigUpdated("stakeCallGas", newGas);
    }

    function setFeeWallet(address newFeeWallet) external onlyOwner {
        if (newFeeWallet == address(0)) revert ZeroAddress();
        feeWallet = newFeeWallet;
        emit FeeWalletUpdated(newFeeWallet);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeBpsTooHigh(newFeeBps, MAX_FEE_BPS);
        feeBps = newFeeBps;
        emit ConfigUpdated("feeBps", newFeeBps);
    }

    function setStakeRequirements(uint256 floor_, uint256 unattested_) external onlyOwner {
        if (unattested_ < floor_) revert TierBelowFloor(unattested_, floor_);
        absoluteStakeFloor = floor_;
        unattestedStakeRequirement = unattested_;
        emit ConfigUpdated("absoluteStakeFloor", floor_);
        emit ConfigUpdated("unattestedStakeRequirement", unattested_);
    }

    function setSelectors(bytes4 fund_, bytes4 complete_, bytes4 reject_) external onlyOwner {
        _fundSelector = fund_;
        _completeSelector = complete_;
        _rejectSelector = reject_;
        emit SelectorsUpdated(fund_, complete_, reject_);
    }

    function setTerminalStatuses(uint8 completed_, uint8 rejected_, uint8 expired_) external onlyOwner {
        completedStatus = completed_;
        rejectedStatus = rejected_;
        expiredStatus = expired_;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    struct FundPreview {
        address client;
        address provider;
        address paymentToken;
        uint256 feeAmount;
        uint256 requiredHookAllowance;
        uint256 currentHookAllowance;
        bool sufficientHookAllowance;
        uint256 score;
        uint256 requiredStake;
        uint256 currentStake;
        bool sufficientStake;
    }

    function previewFundRequirements(uint256 jobId, bytes calldata attestationData)
        external
        view
        returns (FundPreview memory preview)
    {
        (address client, address provider, uint256 budget,) = _loadJob(jobId);
        address paymentToken = IERC8183Core(coreJob).paymentToken();
        preview.client = client;
        preview.provider = provider;
        preview.paymentToken = paymentToken;

        (preview.score,) = _verifyAttestation(provider, jobId, attestationData);
        preview.requiredStake = requiredStakeFor(preview.score);
        preview.currentStake = _readStake(provider);
        preview.sufficientStake = preview.currentStake >= preview.requiredStake;

        uint256 feeAmount = (budget * feeBps) / BPS_DENOMINATOR;
        preview.feeAmount = feeAmount;
        preview.requiredHookAllowance = feeAmount;
        if (feeAmount == 0) {
            preview.sufficientHookAllowance = true;
        } else {
            preview.currentHookAllowance = IERC20(paymentToken).allowance(client, address(this));
            preview.sufficientHookAllowance = preview.currentHookAllowance >= feeAmount;
        }
    }

    function attestationDigest(address provider, uint256 jobId, uint16 score, uint64 expiry, bytes32 salt)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(ATTESTATION_TYPEHASH, provider, jobId, score, expiry, salt)));
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}