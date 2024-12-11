// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";

import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";

contract AcceptAdmin is Script {
    // This function should be called by the owner to update token multiplier setter role
    function chainAllowEvmEmulation(address chainAdmin, address target) public {
        IChainAdmin admin = IChainAdmin(chainAdmin);

        vm.startBroadcast();
        admin.enableEvmEmulator(IZkSyncHyperchain(target));
        vm.stopBroadcast();
    }
}
