// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {console2} from "forge-std/Script.sol";

import {EmergencyUpgradeCalldata} from "./EmergencyUpgradeCalldata.s.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {EMERGENCY_UPGRADE_SALT} from "../utils/Utils.sol";

/// @notice FORK-ONLY dry run of a package's emergency proposals before any approval is collected:
///         impersonates the EmergencyUpgradeBoard and calls `ProtocolUpgradeHandler.executeEmergencyUpgrade`
///         with the package's CTM-domain ProxyAdmin split, when it has one, then its governance bundle, so
///         only the board's signature check is skipped and a proposal that would revert fails here, not
///         after the approvals.
contract VerifyEmergencyUpgrade is EmergencyUpgradeCalldata {
    /// @notice Executes the package's emergency proposals, in order, as its board would.
    /// @param _protocolUpgradeHandler The handler that executes the package's governance calls.
    /// @param _ecosystemToml The merged package (`upgrade-envs/<version>/output/<env>/ecosystem.toml`).
    function verify(address _protocolUpgradeHandler, string memory _ecosystemToml) external {
        IProtocolUpgradeHandler handler = IProtocolUpgradeHandler(_protocolUpgradeHandler);
        IProtocolUpgradeHandler.Call[] memory split = loadCTMProxyAdminSplitCalls(_ecosystemToml);
        if (split.length != 0) {
            _executeAsBoard(handler, split);
            console2.log("SUCCESS: the package's %s CTM-domain ProxyAdmin split calls executed first", split.length);
        }
        IProtocolUpgradeHandler.Call[] memory calls = loadGovernanceCalls(_ecosystemToml);
        _executeAsBoard(handler, calls);
        console2.log("SUCCESS: the package's %s governance calls executed through the emergency path", calls.length);
    }

    function _executeAsBoard(IProtocolUpgradeHandler _handler, IProtocolUpgradeHandler.Call[] memory _calls) private {
        address board = _handler.emergencyUpgradeBoard();
        vm.prank(board);
        _handler.executeEmergencyUpgrade(
            IProtocolUpgradeHandler.UpgradeProposal({calls: _calls, executor: board, salt: EMERGENCY_UPGRADE_SALT})
        );
    }
}
