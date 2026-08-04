// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {BridgedOutPopulationLib} from "./default-upgrade/BridgedOutPopulationLib.sol";

/// @notice Standalone entry point for the `bridgedOut` population that `stage3` of the upgrade runs.
/// @dev Useful for resuming an interrupted stage3 (the population is idempotent per asset) and for
/// populating legacy tokens that were registered in the NTV later. Requires no governance privileges.
/// @dev Usage:
/// @dev   forge script PopulateBridgedOutScript --sig "run(address)" <BRIDGEHUB> --broadcast --private-key <KEY>
/// @dev Env knobs: `BRIDGED_OUT_ASSETS_PER_CALL` sets the assets per transaction; see
/// `BridgedOutPopulationLib` for its default.
contract PopulateBridgedOutScript is Script {
    function run(address _bridgehub) public {
        console.log("Bridgehub:", _bridgehub);

        vm.startBroadcast();
        BridgedOutPopulationLib.populateBridgedOutForAllAssets(_bridgehub);
        vm.stopBroadcast();
    }
}
