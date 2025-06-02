// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

/// @title DeploymentNotifier
/// @notice A library to handle console notifications and forge verification messages
library DeploymentNotifier {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice Notify about a deployment using the contractName as displayName
    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams,
        bool isZKBytecode
    ) internal pure {
        notifyAboutDeployment(contractAddr, contractName, constructorParams, contractName, isZKBytecode);
    }

    /// @notice Notify about a deployment with a custom displayName
    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams,
        string memory displayName,
        bool isZKBytecode
    ) internal pure {
        // Basic console message
        string memory basicMessage = string.concat(displayName, " has been deployed at ", vm.toString(contractAddr));
        console.log(basicMessage);

        // Forge verification command
        string memory deployedName = getDeployedContractName(contractName);
        string memory forgeCmd = "forge verify-contract ";
        if (isZKBytecode) {
            forgeCmd = string.concat(forgeCmd, "--zksync ");
        }
        if (constructorParams.length == 0) {
            forgeCmd = string.concat(forgeCmd, vm.toString(contractAddr), " ", deployedName);
        } else {
            forgeCmd = string.concat(
                forgeCmd,
                vm.toString(contractAddr),
                " ",
                deployedName,
                " --constructor-args ",
                vm.toString(constructorParams)
            );
        }
        console.log(forgeCmd);
    }

    /// @notice Map certain contract names to their verification target names
    function getDeployedContractName(string memory contractName) internal pure returns (string memory) {
        if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return "UpgradeableBeacon";
        }
        return contractName;
    }

    /// @notice Compare two strings for equality
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
