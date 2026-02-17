// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {Utils} from "../../utils/Utils.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {Call} from "contracts/governance/Common.sol";

/// @notice Script for chain admins to set the pre-V31 total supply on ZKOS chains.
/// @dev This should be run after the V31 upgrade. It calls the Admin facet on the chain's
/// @dev diamond proxy, which sends a service transaction to L2BaseTokenZKOS.
/// @dev
/// @dev Execute mode (default):
/// @dev   BRIDGEHUB=0x... CHAIN_ID=... PRE_V31_TOTAL_SUPPLY=... forge script SetZkosPreV31TotalSupplyScript --broadcast --private-key <KEY>
/// @dev
/// @dev Calldata-only mode (for multisig submission):
/// @dev   BRIDGEHUB=0x... CHAIN_ID=... PRE_V31_TOTAL_SUPPLY=... SAVE_CALLDATA_ONLY=true OUTPUT_FILE=/script-out/... forge script SetZkosPreV31TotalSupplyScript
contract SetZkosPreV31TotalSupplyScript is Script {
    function run() public {
        address bridgehub = vm.envAddress("BRIDGEHUB");
        uint256 chainId = vm.envUint("CHAIN_ID");
        uint256 preV31TotalSupply = vm.envUint("PRE_V31_TOTAL_SUPPLY");
        bool saveOutputOnly = vm.envOr("SAVE_CALLDATA_ONLY", false);

        address diamondProxy = L1Bridgehub(bridgehub).getZKChain(chainId);
        address chainAdmin = IZKChain(diamondProxy).getAdmin();

        console.log("Bridgehub:", bridgehub);
        console.log("Chain ID:", chainId);
        console.log("Diamond Proxy:", diamondProxy);
        console.log("Chain Admin:", chainAdmin);
        console.log("Pre-V31 Total Supply:", preV31TotalSupply);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: diamondProxy,
            value: 0,
            data: abi.encodeCall(IAdmin.setZkosPreV31TotalSupply, (preV31TotalSupply))
        });

        if (saveOutputOnly) {
            saveOutput(chainAdmin, calls);
        } else {
            Utils.adminExecute(
                chainAdmin,
                address(0),
                diamondProxy,
                abi.encodeCall(IAdmin.setZkosPreV31TotalSupply, (preV31TotalSupply)),
                0
            );
            console.log("Service transaction sent to set ZKOS pre-V31 total supply");
        }
    }

    function saveOutput(address chainAdmin, Call[] memory calls) internal {
        string memory defaultOutput = "/script-out/set-zkos-pre-v31-total-supply.toml";
        string memory output = vm.envOr("OUTPUT_FILE", defaultOutput);
        string memory path = string.concat(vm.projectRoot(), output);

        vm.serializeAddress("root", "admin_address", chainAdmin);
        string memory toml = vm.serializeBytes(
            "root",
            "encoded_data",
            abi.encodeCall(IChainAdmin.multicall, (calls, true))
        );

        vm.writeToml(toml, path);
        console.log("Calldata saved to:", path);
    }
}
