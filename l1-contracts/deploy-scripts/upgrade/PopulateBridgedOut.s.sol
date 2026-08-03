// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {BridgedOutPopulationLib} from "./default-upgrade/BridgedOutPopulationLib.sol";

/// @notice Standalone entry point for the `bridgedOut` population that `stage3` of the upgrade runs.
/// @dev Useful for resuming an interrupted stage3 (the population is idempotent per (chain, asset) pair)
/// and for populating chains that were registered later. Requires no governance privileges.
/// @dev
/// @dev   forge script PopulateBridgedOutScript --sig "run(address)" <BRIDGEHUB> --broadcast --private-key <KEY>
/// @dev
/// @dev Env knobs (see `BridgedOutPopulationLib`):
/// @dev   BRIDGED_OUT_ASSETS_PER_CALL       assets per transaction (default 25)
/// @dev   BRIDGED_OUT_SKIP_INVARIANT_CHECK  populate even if the legacy totals cross-check fails
contract PopulateBridgedOutScript is Script {
    function run(address _bridgehub) public {
        console.log("Bridgehub:", _bridgehub);

        vm.startBroadcast();
        uint256 populated = BridgedOutPopulationLib.populateBridgedOutForAllChains(_bridgehub);
        vm.stopBroadcast();

        console.log("Total amount populated:", populated);
    }
}
