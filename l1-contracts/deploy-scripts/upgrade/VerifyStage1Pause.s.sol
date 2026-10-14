// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {console2} from "forge-std/Script.sol";

import {EmergencyStageUpgradeCalldata} from "./EmergencyStageUpgradeCalldata.s.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {EMERGENCY_UPGRADE_SALT} from "../utils/Utils.sol";

/// @notice FORK-ONLY dry run of a package's emergency proposal before any approval is collected:
///         impersonates the EmergencyUpgradeBoard and calls `ProtocolUpgradeHandler.executeEmergencyUpgrade`
///         with every governance call of the package, so only the board's signature check is skipped.
///         The handler's emergency path lifts the ecosystem-wide migration pause before it executes,
///         so calls that rely on a pause held from before the proposal fail here and not after the
///         approvals.
contract VerifyStage1Pause is EmergencyStageUpgradeCalldata {
    /// @notice Executes the package's one emergency proposal as its board would.
    /// @param _protocolUpgradeHandler The handler that executes the package's governance calls.
    /// @param _ecosystemToml The merged package (`upgrade-envs/<version>/output/<env>/ecosystem.toml`).
    function verify(address _protocolUpgradeHandler, string memory _ecosystemToml) external {
        IProtocolUpgradeHandler.Call[] memory calls = loadGovernanceCalls(_ecosystemToml);
        requireZeroTimerDelay(calls);
        IProtocolUpgradeHandler handler = IProtocolUpgradeHandler(_protocolUpgradeHandler);
        address board = handler.emergencyUpgradeBoard();
        vm.prank(board);
        handler.executeEmergencyUpgrade(
            IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: board, salt: EMERGENCY_UPGRADE_SALT})
        );
        console2.log("SUCCESS: the package's %s governance calls executed through the emergency path", calls.length);
    }
}
