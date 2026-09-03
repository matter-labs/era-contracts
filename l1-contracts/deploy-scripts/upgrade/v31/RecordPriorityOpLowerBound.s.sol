// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console} from "forge-std/Script.sol";

import {IPriorityOpLowerBound} from "contracts/upgrades/IPriorityOpLowerBound.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

/// @notice Records a ZKsync OS chain's priority-op lower bound ahead of its v32 upgrade.
/// @dev The upgrade requires a recorded bound and all priority ops below it processed (see
/// `V32UpgradeZKsyncOS`), so this must run in a transaction well before the chain's
/// upgrade executes — never in the same bundle. The bound is also enforced when the chain admin
/// *schedules* the upgrade (`ServerNotifier.setUpgradeTimestamp` consults the registered
/// `V33UpgradePreconditionChecker`), and the pinned bound includes priority ops pending at record
/// time — so record it well before scheduling and let the chain process past the bound first; see
/// {protocol-docs/upgrade-scheduling.md}. The registry address is the CTM upgrade output's
/// `priority_op_lower_bound_addr`. The call is permissionless and this script is idempotent.
contract RecordPriorityOpLowerBound is Script {
    function run(address _priorityOpLowerBound, address _bridgehub, uint256 _chainId) public {
        address chainDiamond = IBridgehubBase(_bridgehub).getZKChain(_chainId);
        require(chainDiamond != address(0), "chain not registered on the bridgehub");

        IPriorityOpLowerBound registry = IPriorityOpLowerBound(_priorityOpLowerBound);
        if (registry.recorded(chainDiamond)) {
            console.log("Lower bound already recorded for", chainDiamond, ":", registry.lowerBound(chainDiamond));
            return;
        }

        vm.startBroadcast();
        registry.lowerBoundPriorityOp(chainDiamond);
        vm.stopBroadcast();

        console.log("Recorded lower bound for", chainDiamond, ":", registry.lowerBound(chainDiamond));
    }
}
