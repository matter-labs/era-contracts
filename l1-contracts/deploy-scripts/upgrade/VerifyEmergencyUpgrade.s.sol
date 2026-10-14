// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {console2} from "forge-std/Script.sol";

import {EmergencyUpgradeCalldata} from "./EmergencyUpgradeCalldata.s.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {EMERGENCY_UPGRADE_SALT} from "../utils/Utils.sol";

/// @notice FORK-ONLY dry run of a package's emergency proposal before any approval is collected:
///         impersonates the EmergencyUpgradeBoard and calls `ProtocolUpgradeHandler.executeEmergencyUpgrade`
///         with the package's governance bundle, so only the board's signature check is skipped and a
///         bundle that would revert fails here, not after the approvals.
contract VerifyEmergencyUpgrade is EmergencyUpgradeCalldata {
    /// @notice Executes the package's one emergency proposal as its board would.
    /// @param _protocolUpgradeHandler The handler that executes the package's governance calls.
    /// @param _ecosystemToml The merged package (`upgrade-envs/<version>/output/<env>/ecosystem.toml`).
    function verify(address _protocolUpgradeHandler, string memory _ecosystemToml) external {
        IProtocolUpgradeHandler.Call[] memory calls = loadGovernanceCalls(_ecosystemToml);
        IProtocolUpgradeHandler handler = IProtocolUpgradeHandler(_protocolUpgradeHandler);
        address board = handler.emergencyUpgradeBoard();
        vm.prank(board);
        handler.executeEmergencyUpgrade(
            IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: board, salt: EMERGENCY_UPGRADE_SALT})
        );
        console2.log("SUCCESS: the package's %s governance calls executed through the emergency path", calls.length);
    }
}
