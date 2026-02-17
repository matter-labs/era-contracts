// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";

/// @notice Script for chain admins to set the pre-V31 total supply on ZKOS chains.
/// @dev This should be run after the V31 upgrade. It calls the Admin facet on the chain's
/// @dev diamond proxy, which sends a service transaction to L2BaseTokenZKOS.
/// @dev Usage:
/// @dev   CHAIN_ADMIN=0x... CHAIN_DIAMOND_PROXY=0x... PRE_V31_TOTAL_SUPPLY=... forge script SetZkosPreV31TotalSupplyScript --broadcast
contract SetZkosPreV31TotalSupplyScript is Script {
    function run() public {
        address chainAdminAddr = vm.envAddress("CHAIN_ADMIN");
        address diamondProxy = vm.envAddress("CHAIN_DIAMOND_PROXY");
        uint256 preV31TotalSupply = vm.envUint("PRE_V31_TOTAL_SUPPLY");

        console.log("Chain Admin:", chainAdminAddr);
        console.log("Diamond Proxy:", diamondProxy);
        console.log("Pre-V31 Total Supply:", preV31TotalSupply);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: diamondProxy,
            value: 0,
            data: abi.encodeCall(IAdmin.setZkosPreV31TotalSupply, (preV31TotalSupply))
        });

        vm.startBroadcast();
        IChainAdmin(chainAdminAddr).multicall(calls, true);
        vm.stopBroadcast();

        console.log("Service transaction sent to set ZKOS pre-V31 total supply");
    }
}
