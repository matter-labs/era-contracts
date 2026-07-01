// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {EmergencyStageUpgradeCalldata} from "./EmergencyStageUpgradeCalldata.s.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {console2} from "forge-std/Script.sol";

/// @notice FORK-ONLY: verifies the stage-1 emergency upgrade (with the prepended pauseMigration call)
/// executes end-to-end. Impersonates the EmergencyUpgradeBoard and calls PUH.executeEmergencyUpgrade
/// directly, bypassing the board's signature check (which would otherwise need fresh approvals for the
/// new 24-call proposal). If the old 23-call proposal would revert with MigrationsNotPaused() but this
/// passes, the pauseMigration fix is confirmed.
contract VerifyStage1Pause is EmergencyStageUpgradeCalldata {
    function verify() external {
        IProtocolUpgradeHandler.Call[] memory calls = _loadCalls(1); // includes prepended pauseMigration
        address board = PUH.emergencyUpgradeBoard();
        console2.log("stage-1 calls (expect 24):", calls.length);
        console2.log("first call target (expect CAH):", calls[0].target);
        console2.logBytes4(bytes4(calls[0].data));

        IProtocolUpgradeHandler.UpgradeProposal memory proposal = IProtocolUpgradeHandler.UpgradeProposal({
            calls: calls,
            executor: board,
            salt: SALT
        });

        vm.prank(board);
        PUH.executeEmergencyUpgrade(proposal);
        console2.log("SUCCESS: stage-1 executed end-to-end; checkMigrationsPaused passed.");
    }
}
