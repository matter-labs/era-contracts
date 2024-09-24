// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";


contract ChainUpgradeript {
    using stdToml for string;


    function prepareChain(
        string memory configPath,
        string memory outputPath
    ) public {
        string memory root = vm.projectRoot();
        configPath = string.concat(root, configPath);
        outputPath = string.concat(root, outputPath);

        // Preparation of chain consists of two parts:
        // - Deploying l2 da validator
        // - Deploying new chain admin 
    }
    /// @dev The caller of this function needs to be the owner of the chain admin 
    /// of the 
    function governanceMoveToNewChainAdmin(

    ) public {

    }


}
