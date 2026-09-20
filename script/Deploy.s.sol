// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/AttestedStakeGateFeeHook.sol";

contract DeployScript is Script {
    function run() external {
        address core = vm.envAddress("CORE_CONTRACT");
        address staking = vm.envAddress("STAKING_CONTRACT");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address attestor = vm.envAddress("ATTESTATION_SIGNER");

        uint256 feeBps = vm.envUint("FEE_BPS");
        uint256 absoluteStakeFloor = vm.envUint("ABSOLUTE_STAKE_FLOOR");
        uint256 unattestedStakeRequirement = vm.envUint("UNATTESTED_STAKE_REQUIREMENT");

        bytes4 fundSelector = bytes4(keccak256(bytes(vm.envString("FUND_SIGNATURE"))));
        bytes4 completeSelector = bytes4(keccak256(bytes(vm.envString("COMPLETE_SIGNATURE"))));
        bytes4 rejectSelector = bytes4(keccak256(bytes(vm.envString("REJECT_SIGNATURE"))));

        uint8 completedStatus = uint8(vm.envUint("COMPLETED_STATUS"));
        uint8 rejectedStatus = uint8(vm.envUint("REJECTED_STATUS"));
        uint8 expiredStatus = uint8(vm.envUint("EXPIRED_STATUS"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        AttestedStakeGateFeeHook hook = new AttestedStakeGateFeeHook(
            core,
            staking,
            feeWallet,
            owner,
            attestor,
            feeBps,
            absoluteStakeFloor,
            unattestedStakeRequirement,
            [fundSelector, completeSelector, rejectSelector],
            [completedStatus, rejectedStatus, expiredStatus]
        );

        console.log("==========================================");
        console.log("AttestedStakeGateFeeHook deployed at:", address(hook));
        console.log("fundSelector:");
        console.logBytes4(fundSelector);
        console.log("completeSelector:");
        console.logBytes4(completeSelector);
        console.log("rejectSelector:");
        console.logBytes4(rejectSelector);
        console.log("==========================================");

        vm.stopBroadcast();
    }
}