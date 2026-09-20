# AttestedStakeGateFeeHook

An [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) hook for Virtuals Protocol's Agentic Commerce Protocol (`AgenticCommerceV3` on Base). It does two things at the two points where the core calls into a job's attached hook:

- **`beforeAction` (at `fund()`)** — gates the job's provider behind an EIP-712 reputation attestation and an on-chain stake check, and escrows a platform fee pulled from the **client** (not the provider) into the hook's own custody.
- **`afterAction` (at `complete()` / `reject()`)** — pure internal bookkeeping on the already-escrowed fee: no external calls, so nothing here can revert the core's own state transition or get silently swallowed.

Full design rationale (why the fee is pulled from the client at fund-time instead of from the provider at completion-time, why reputation arrives as an off-chain-signed attestation instead of a live on-chain registry call, why the required stake never drops to zero regardless of score) is documented inline as NatSpec comments in [`src/AttestedStakeGateFeeHook.sol`](src/AttestedStakeGateFeeHook.sol).

## Status

Interface and Job-struct assumptions have been confirmed against the real deployed `AgenticCommerceV3` core on Base mainnet (`0x238E541BfefD82238730D00a2208E5497F1832E0`) via its verified source. The hook is not yet whitelisted (`whitelistedHooks`) on the core — that requires `ADMIN_ROLE`, which this project does not hold. A whitelisting request is pending with the Virtuals team.

## Requirements

- [Foundry](https://getfoundry.sh) (forge, cast)

## Setup

This repo uses git submodules for its dependencies (`forge-std`, `openzeppelin-contracts`). A plain `git clone` will leave `lib/` empty — use:

    git clone --recurse-submodules https://github.com/AN88NA-crypto/attested-stake-gate-fee-hook.git
    cd attested-stake-gate-fee-hook

If you already cloned without that flag:

    git submodule update --init --recursive

## Build & test

    forge build
    forge test -vv

## Deployment

`script/Deploy.s.sol` reads its constructor arguments from environment variables. Copy the list below into a `.env` file (never commit it — it holds a deployer private key) and fill in real values:

    CORE_CONTRACT=0x238E541BfefD82238730D00a2208E5497F1832E0
    STAKING_CONTRACT=<staking contract address>
    FEE_WALLET=<address that receives the platform fee>
    OWNER_ADDRESS=<admin address for this hook>
    ATTESTATION_SIGNER=<initial attestor address>
    FEE_BPS=50
    ABSOLUTE_STAKE_FLOOR=<uint>
    UNATTESTED_STAKE_REQUIREMENT=<uint>
    FUND_SIGNATURE=fund(uint256,uint256,bytes)
    COMPLETE_SIGNATURE=complete(uint256,bytes32,bytes)
    REJECT_SIGNATURE=reject(uint256,bytes32,bytes)
    COMPLETED_STATUS=3
    REJECTED_STATUS=4
    EXPIRED_STATUS=5
    PRIVATE_KEY=<deployer private key>

Then:

    source .env
    forge script script/Deploy.s.sol:DeployScript \
      --rpc-url $BASE_SEPOLIA_RPC_URL \
      --broadcast \
      -vvvv

After deployment, call `setStakeTiers` in the same session as the deploy — an empty tier table between deploy and configuration is a real (if brief) window where every provider falls back to `unattestedStakeRequirement`.

## Contract overview

| File | Purpose |
|---|---|
| `src/AttestedStakeGateFeeHook.sol` | The hook itself, plus the `BaseERC8183Hook` generic `beforeAction`/`afterAction` dispatcher it's built on. |
| `test/AttestedStakeGateFeeHook.t.sol` | Foundry unit tests against mocks of the core and a staking contract. |
| `script/Deploy.s.sol` | Env-var-driven deployment script. |
