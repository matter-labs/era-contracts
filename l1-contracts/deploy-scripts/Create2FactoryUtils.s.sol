// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Utils} from "./Utils.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";
import {AddressHasNoCode} from "./ZkSyncScriptErrors.sol";

/// @title Create2FactoryUtils
/// @notice This abstract contract encapsulates all Create2Factory processing logic,
/// relying only on the provided factory address and factory salt. It stores the determined
/// Create2Factory state and provides deployment helpers that are completely independent
/// of other state.
abstract contract Create2FactoryUtils is Script {
    /// @notice Holds the final deployed Create2Factory address.
    struct Create2FactoryState {
        address create2FactoryAddress;
    }

    /// @notice Holds the input parameters for Create2Factory processing.
    struct Create2FactoryParams {
        address factoryAddress;
        bytes32 factorySalt;
    }

    /// @notice The state representing the deployed Create2Factory.
    Create2FactoryState internal create2FactoryState;

    /// @notice The input parameters for the Create2Factory.
    Create2FactoryParams internal create2FactoryParams;

    /// @notice Constant for the known deterministic Create2Factory address.
    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Initializes the Create2Factory parameters.
    /// @param _factoryAddress The preconfigured factory address (if any).
    /// @param _factorySalt The salt used for deterministic deployment.
    function _initCreate2FactoryParams(address _factoryAddress, bytes32 _factorySalt) internal {
        create2FactoryParams = Create2FactoryParams({factoryAddress: _factoryAddress, factorySalt: _factorySalt});
    }

    /// @notice Instantiates the Create2Factory.
    /// If a factory address is configured and contains code, that address is used.
    /// Otherwise, if the deterministic address is deployed, then it is used.
    /// If neither condition holds, a new Create2Factory is deployed via Utils.deployCreate2Factory().
    /// The determined address is stored in create2FactoryState.
    function instantiateCreate2Factory() internal {
        address deployedAddress;
        bool isConfigured = create2FactoryParams.factoryAddress != address(0);
        bool isDeterministicDeployed = DETERMINISTIC_CREATE2_ADDRESS.code.length > 0;

        if (isConfigured) {
            if (create2FactoryParams.factoryAddress.code.length == 0) {
                revert AddressHasNoCode(create2FactoryParams.factoryAddress);
            }
            deployedAddress = create2FactoryParams.factoryAddress;
            console.log("Using configured Create2Factory address:", deployedAddress);
        } else if (isDeterministicDeployed) {
            deployedAddress = DETERMINISTIC_CREATE2_ADDRESS;
            console.log("Using deterministic Create2Factory address:", deployedAddress);
        } else {
            deployedAddress = Utils.deployCreate2Factory();
            console.log("Create2Factory deployed at:", deployedAddress);
        }

        create2FactoryState = Create2FactoryState({create2FactoryAddress: deployedAddress});
    }

    /// @notice Deploys a contract via Create2 using the provided complete bytecode.
    /// @param bytecode The full bytecode (creation code concatenated with constructor arguments).
    /// @return The deployed contract address.
    function deployViaCreate2(bytes memory bytecode) internal virtual returns (address) {
        return
            Utils.deployViaCreate2(
                bytecode,
                create2FactoryParams.factorySalt,
                create2FactoryState.create2FactoryAddress
            );
    }

    /// @notice Deploys a contract via Create2 by concatenating the creation code and constructor arguments.
    /// @param creationCode The creation code of the contract.
    /// @param constructorArgs The constructor arguments.
    /// @return The deployed contract address.
    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual returns (address) {
        return
            Utils.deployViaCreate2(
                abi.encodePacked(creationCode, constructorArgs),
                create2FactoryParams.factorySalt,
                create2FactoryState.create2FactoryAddress
            );
    }

    /// @notice Deploys a contract via Create2 and notifies via console logs.
    /// This version uses the same string for the internal contract name and its display name.
    /// @param creationCode The creation code for the contract.
    /// @param constructorParams The encoded constructor parameters.
    /// @param contractName The internal name of the contract.
    /// @return deployedAddress The deployed contract address.
    function deployViaCreate2AndNotify(
        bytes memory creationCode,
        bytes memory constructorParams,
        string memory contractName
    ) internal returns (address deployedAddress) {
        deployedAddress = deployViaCreate2AndNotify(creationCode, constructorParams, contractName, contractName);
    }

    /// @notice Deploys a contract via Create2 and notifies via console logs.
    /// @param creationCode The creation code for the contract.
    /// @param constructorParams The encoded constructor parameters.
    /// @param contractName The internal name of the contract.
    /// @param displayName The name to be displayed in the logs.
    /// @return deployedAddress The deployed contract address.
    function deployViaCreate2AndNotify(
        bytes memory creationCode,
        bytes memory constructorParams,
        string memory contractName,
        string memory displayName
    ) internal returns (address deployedAddress) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorParams);
        deployedAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(deployedAddress, contractName, constructorParams, displayName);
    }

    /// @notice Deploys a contract via Create2 with a deterministic owner.
    /// @param initCode The concatenated initialization code.
    /// @param owner The address to be set as the owner.
    /// @return The deployed contract address.
    function create2WithDeterministicOwner(bytes memory initCode, address owner) internal returns (address) {
        bytes memory creatorInitCode = abi.encodePacked(
            type(Create2AndTransfer).creationCode,
            abi.encode(initCode, create2FactoryParams.factorySalt, owner)
        );
        address deployerAddr = deployViaCreate2(creatorInitCode);
        return Create2AndTransfer(deployerAddr).deployedAddress();
    }

    /// @notice Deploys a contract via Create2 with a deterministic owner and notifies via console logs.
    /// @param initCode The initialization code for the contract.
    /// @param constructorParams The encoded constructor arguments.
    /// @param owner The owner address.
    /// @param contractName The internal contract name.
    /// @param displayName The name to display in the logs.
    /// @return contractAddress The deployed contract address.
    function deployWithOwnerAndNotify(
        bytes memory initCode,
        bytes memory constructorParams,
        address owner,
        string memory contractName,
        string memory displayName
    ) internal returns (address contractAddress) {
        contractAddress = create2WithDeterministicOwner(abi.encodePacked(initCode, constructorParams), owner);
        notifyAboutDeployment(contractAddress, contractName, constructorParams, displayName);
    }

    /// @notice Overload for notifyAboutDeployment that takes three arguments.
    /// @param contractAddr The deployed contract address.
    /// @param contractName The internal contract name.
    /// @param constructorParams The encoded constructor parameters.
    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams
    ) internal {
        notifyAboutDeployment(contractAddr, contractName, constructorParams, contractName);
    }

    /// @notice Notifies about a deployment by printing messages to the console.
    /// It displays both a basic message and a Forge verification message.
    /// @param contractAddr The deployed contract address.
    /// @param contractName The internal contract name.
    /// @param constructorParams The encoded constructor parameters.
    /// @param displayName The display name for the contract.
    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams,
        string memory displayName
    ) internal {
        string memory basicMessage = string.concat(displayName, " has been deployed at ", vm.toString(contractAddr));
        console.log(basicMessage);

        string memory deployedContractName = getDeployedContractName(contractName);
        string memory forgeMessage;
        if (constructorParams.length == 0) {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                deployedContractName
            );
        } else {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                deployedContractName,
                " --constructor-args ",
                vm.toString(constructorParams)
            );
        }
        console.log(forgeMessage);
    }

    /// @notice Returns the deployed contract name.
    /// This function can be modified if the deployed name should differ from the internal name.
    /// @param contractName The internal name of the contract.
    /// @return The name to be used for verification.
    function getDeployedContractName(string memory contractName) internal view virtual returns (string memory) {
        if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return "UpgradeableBeacon";
        } else {
            return contractName;
        }
    }

    /// @notice Compares two strings for equality.
    /// @param a The first string.
    /// @param b The second string.
    /// @return True if the strings are identical, false otherwise.
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
