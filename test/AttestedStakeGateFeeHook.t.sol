// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AttestedStakeGateFeeHook} from "../src/AttestedStakeGateFeeHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockStaking {
    mapping(address => uint256) public balances;

    function setStake(address agent, uint256 amount) external {
        balances[agent] = amount;
    }

    function stakedBalanceOf(address agent) external view returns (uint256) {
        return balances[agent];
    }
}

contract GasGriefingStaking {
    function stakedBalanceOf(address) external view returns (uint256) {
        uint256 x;
        while (true) {
            unchecked {
                x += 1;
            }
        }
        return x;
    }
}

contract MockCore {
    struct Job {
        address client;
        address provider;
        address evaluator;
        address paymentToken;
        uint256 budget;
        uint8 status;
    }

    mapping(uint256 => Job) public jobsMap;

    function setJob(uint256 jobId, Job calldata j) external {
        jobsMap[jobId] = j;
    }

    function jobs(uint256 jobId)
        external
        view
        returns (address, address, address, address, uint256, uint8)
    {
        Job memory j = jobsMap[jobId];
        return (j.client, j.provider, j.evaluator, j.paymentToken, j.budget, j.status);
    }
}

contract AttestedStakeGateFeeHookTest is Test {
    AttestedStakeGateFeeHook hook;
    MockCore core;
    MockStaking staking;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address feeWallet = makeAddr("feeWallet");
    address attestor;
    uint256 attestorPk;
    address client = makeAddr("client");
    address provider = makeAddr("provider");

    bytes4 constant FUND_SEL = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 constant COMPLETE_SEL = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 constant REJECT_SEL = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    uint8 constant COMPLETED = 3;
    uint8 constant REJECTED = 4;
    uint8 constant EXPIRED = 5;

    function setUp() public {
        (attestor, attestorPk) = makeAddrAndKey("attestor");
        core = new MockCore();
        staking = new MockStaking();
        usdc = new MockUSDC();

        hook = new AttestedStakeGateFeeHook(
            address(core),
            address(staking),
            feeWallet,
            owner,
            attestor,
            50, // 0.5%
            1_000e6, // absoluteStakeFloor
            5_000e6, // unattestedStakeRequirement
            [FUND_SEL, COMPLETE_SEL, REJECT_SEL],
            [COMPLETED, REJECTED, EXPIRED]
        );

        usdc.mint(client, 1_000_000e6);
    }

    function _setJob(uint256 jobId, uint256 budget, uint8 status) internal {
        core.setJob(
            jobId,
            MockCore.Job({
                client: client,
                provider: provider,
                evaluator: address(0xE),
                paymentToken: address(usdc),
                budget: budget,
                status: status
            })
        );
    }

    // --- access control ---

    function test_beforeAction_revertsIfNotCore() public {
        vm.expectRevert();
        hook.beforeAction(1, FUND_SEL, "");
    }

    // --- stake gate ---

    function test_preFund_revertsIfStakeBelowUnattestedFloor() public {
        _setJob(1, 100_000e6, 0);
        staking.setStake(provider, 4_999e6);
        vm.prank(address(core));
        vm.expectRevert();
        hook.beforeAction(1, FUND_SEL, "");
    }

    // --- fee pull source ---

    function test_preFund_pullsFeeFromClient_notProvider() public {
        uint256 budget = 100_000e6;
        _setJob(2, budget, 0);
        staking.setStake(provider, 5_000e6);

        vm.prank(client);
        usdc.approve(address(hook), type(uint256).max);

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 hookBefore = usdc.balanceOf(address(hook));

        vm.prank(address(core));
        hook.beforeAction(2, FUND_SEL, "");

        uint256 expectedFee = (budget * 50) / 10_000;
        assertEq(usdc.balanceOf(client), clientBefore - expectedFee, "fee must leave the CLIENT");
        assertEq(usdc.balanceOf(address(hook)), hookBefore + expectedFee, "fee must land in hook custody");
        assertEq(usdc.balanceOf(provider), 0, "provider balance untouched at fund time");
    }

    function test_preFund_revertsIfClientHasNotApprovedHook() public {
        uint256 budget = 100_000e6;
        _setJob(3, budget, 0);
        staking.setStake(provider, 5_000e6);

        vm.prank(address(core));
        vm.expectRevert();
        hook.beforeAction(3, FUND_SEL, "");
    }

    function test_previewFundRequirements_flagsMissingHookAllowanceBeforeFundIsAttempted() public {
        uint256 budget = 100_000e6;
        _setJob(4, budget, 0);
        staking.setStake(provider, 5_000e6);

        AttestedStakeGateFeeHook.FundPreview memory p = hook.previewFundRequirements(4, "");
        assertFalse(p.sufficientHookAllowance, "must flag missing allowance BEFORE a real fund() tx is spent");
        assertTrue(p.sufficientStake);
        assertEq(p.requiredHookAllowance, (budget * 50) / 10_000);
    }

    function test_previewFundRequirements_allGreenAfterApproval() public {
        uint256 budget = 100_000e6;
        _setJob(5, budget, 0);
        staking.setStake(provider, 5_000e6);

        vm.prank(client);
        usdc.approve(address(hook), type(uint256).max);

        AttestedStakeGateFeeHook.FundPreview memory p = hook.previewFundRequirements(5, "");
        assertTrue(p.sufficientHookAllowance);
        assertTrue(p.sufficientStake);
    }

    // --- completion / reject accounting ---

    function test_postComplete_movesFeeToAccrued() public {
        uint256 budget = 100_000e6;
        _setJob(6, budget, 0);
        staking.setStake(provider, 5_000e6);
        vm.prank(client);
        usdc.approve(address(hook), type(uint256).max);
        vm.prank(address(core));
        hook.beforeAction(6, FUND_SEL, "");

        vm.prank(address(core));
        hook.afterAction(6, COMPLETE_SEL, "");

        uint256 expectedFee = (budget * 50) / 10_000;
        assertEq(hook.accruedFees(address(usdc)), expectedFee);
    }

    function test_postReject_thenClaimFeeRefund() public {
        uint256 budget = 100_000e6;
        _setJob(7, budget, 0);
        staking.setStake(provider, 5_000e6);
        vm.prank(client);
        usdc.approve(address(hook), type(uint256).max);
        vm.prank(address(core));
        hook.beforeAction(7, FUND_SEL, "");

        vm.prank(address(core));
        hook.afterAction(7, REJECT_SEL, "");

        uint256 clientBefore = usdc.balanceOf(client);
        hook.claimFeeRefund(7);
        uint256 expectedFee = (budget * 50) / 10_000;
        assertEq(usdc.balanceOf(client), clientBefore + expectedFee);
    }

    // --- STAKE_CALL_GAS ---

    function test_setStakeCallGas_revertsOutOfRange() public {
        vm.prank(owner);
        vm.expectRevert();
        hook.setStakeCallGas(1_000);
    }

    function test_setStakeCallGas_onlyOwner() public {
        vm.expectRevert();
        hook.setStakeCallGas(100_000);
    }

    function test_setStakeCallGas_ownerCanRaiseCapPostDeployment() public {
        vm.prank(owner);
        hook.setStakeCallGas(200_000);
        assertEq(hook.stakeCallGas(), 200_000);
    }

    function test_readStake_gasGriefingStakingContractCannotBrickFunding() public {
        GasGriefingStaking griefer = new GasGriefingStaking();
        vm.prank(owner);
        hook.setStakingContract(address(griefer));

        uint256 budget = 100_000e6;
        _setJob(8, budget, 0);
        vm.prank(client);
        usdc.approve(address(hook), type(uint256).max);

        uint256 gasBefore = gasleft();
        vm.prank(address(core));
        vm.expectRevert();
        hook.beforeAction(8, FUND_SEL, "");
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 300_000, "gas-griefing staking contract must not consume unbounded gas");
    }

    // --- EIP-150 pre-check ---

    function test_readStake_revertsExplicitlyWhenCallerStarvesGas() public {
        uint256 budget = 100_000e6;
        _setJob(9, budget, 0);
        staking.setStake(provider, 5_000e6);
        vm.prank(client);
        usdc.approve(address(hook), type(uint256).max);

        vm.prank(address(core));
        vm.expectRevert();
        hook.beforeAction{gas: 50_000}(9, FUND_SEL, "");
    }

    function test_readStake_succeedsWithAmpleGas() public {
        uint256 budget = 100_000e6;
        _setJob(10, budget, 0);
        staking.setStake(provider, 5_000e6);
        vm.prank(client);
        usdc.approve(address(hook), type(uint256).max);

        vm.prank(address(core));
        hook.beforeAction{gas: 1_000_000}(10, FUND_SEL, "");

        (,, AttestedStakeGateFeeHook.FeeState state) = hook.feeOf(10);
        assertEq(uint8(state), uint8(AttestedStakeGateFeeHook.FeeState.Escrowed));
    }

    // --- single-use attestation ---

    function test_attestation_cannotBeReplayedOnZeroFeeJob() public {
        uint256 tinyBudget = 1; // 1 * 50 / 10_000 == 0
        _setJob(11, tinyBudget, 0);
        staking.setStake(provider, 5_000e6);

        uint16 score = 3000;
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 salt = keccak256("salt-11");

        bytes32 digest = hook.attestationDigest(provider, 11, score, expiry, salt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory data = abi.encode(provider, uint256(11), score, expiry, salt, signature);

        vm.prank(address(core));
        hook.beforeAction(11, FUND_SEL, data); // first use: succeeds

        vm.prank(address(core));
        vm.expectRevert();
        hook.beforeAction(11, FUND_SEL, data); // second use: must be rejected
    }
}