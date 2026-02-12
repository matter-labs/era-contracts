// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {Utils} from "../utils/Utils.sol";

/// @title DeployCreate2Factory
/// @notice Deploys the deterministic CREATE2 factory (Arachnid's deterministic-deployment-proxy)
/// @dev This is only needed for dev/local networks. Mainnet and testnets already have this deployed.
/// @dev See: https://github.com/Arachnid/deterministic-deployment-proxy
contract DeployCreate2Factory is Script {
    // The deployer address that will deploy the factory (from the pre-signed transaction)
    address constant DETERMINISTIC_DEPLOYER = 0x3fAB184622Dc19b6109349B94811493BF2a45362;

    // The exact amount needed to fund the deployer (gas cost of deployment)
    uint256 constant DEPLOYER_FUNDING = 0.01 ether;

    // The pre-signed deployment transaction (from Arachnid's deterministic-deployment-proxy)
    // This transaction deploys the factory to 0x4e59b44847b379578588920cA78FbF26c0B4956C
    bytes constant DEPLOYMENT_TX =
        hex"f8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222";

    function run() public {
        // Check if already deployed
        if (Utils.DETERMINISTIC_CREATE2_ADDRESS.code.length > 0) {
            console.log("CREATE2 factory already deployed at:", Utils.DETERMINISTIC_CREATE2_ADDRESS);
            return;
        }

        vm.broadcast();
        (bool success, ) = DETERMINISTIC_DEPLOYER.call{value: DEPLOYER_FUNDING}("");
        require(success, "Failed to fund deployer");
        console.log("Funded deployer at:", DETERMINISTIC_DEPLOYER);

        // Send the pre-signed deployment transaction
        vm.broadcast();
        vm.broadcastRawTransaction(DEPLOYMENT_TX);

        // Verify deployment
        require(Utils.DETERMINISTIC_CREATE2_ADDRESS.code.length > 0, "CREATE2 factory deployment failed");

        console.log("CREATE2 factory deployed at:", Utils.DETERMINISTIC_CREATE2_ADDRESS);
    }
}
