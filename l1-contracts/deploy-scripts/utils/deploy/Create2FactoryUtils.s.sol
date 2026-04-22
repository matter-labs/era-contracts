// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "../Utils.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";
import {AddressHasNoCode} from "../ZkSyncScriptErrors.sol";

/// @title Create2FactoryUtils
/// @notice This abstract contract encapsulates all Create2Factory processing logic,
/// relying only on the provided factory address and factory salt. It stores the determined
/// Create2Factory state and provides deployment helpers that are completely independent
/// of other state.
abstract contract Create2FactoryUtils is Script {
    using stdToml for string;

    bytes32 internal constant DEFAULT_CREATE2_FACTORY_SALT =
        0x88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5;
    string internal constant CREATE2_FACTORY_SALT_ENV = "CREATE2_FACTORY_SALT";

    /// @notice Holds the final deployed Create2Factory address.
    struct Create2FactoryState {
        address create2FactoryAddress;
    }

    /// @notice The state representing the deployed Create2Factory.
    Create2FactoryState internal create2FactoryState;

    /// @notice The salt used for deterministic deployments.
    bytes32 internal _create2FactorySalt;

    /// @notice Optional preconfigured CREATE2 factory address from the existing environment.
    address internal _create2FactoryAddress;

    /// @notice Whether the salt was explicitly set via `setCreate2Salt`.
    bool private _saltExplicitlySet;

    /// @notice Override the default create2 salt.
    /// @dev Must be called before the first deployment.
    /// @param _salt The salt to use for all subsequent create2 deployments.
    function setCreate2Salt(bytes32 _salt) internal {
        _create2FactorySalt = _salt;
        _saltExplicitlySet = true;
    }

    /// @notice Override the default create2 factory address.
    /// @dev Must be called before the first deployment.
    /// @param _factoryAddress The factory address to use for subsequent create2 deployments.
    function setCreate2FactoryAddress(address _factoryAddress) internal {
        _create2FactoryAddress = _factoryAddress;
    }

    function getCreate2FactoryParams() public view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        return (create2FactoryState.create2FactoryAddress, _create2FactorySalt);
    }

    /// @notice Instantiates the Create2Factory.
    /// @dev If the salt has not been explicitly set via `setCreate2Salt`,
    ///      defaults are applied automatically (env var or built-in default).
    ///      Scripts assume deterministic Create2Factory is predeployed.
    ///      If code is missing at deterministic address, this function reverts.
    function instantiateCreate2Factory() internal {
        if (!_saltExplicitlySet) {
            _create2FactorySalt = vm.envOr(CREATE2_FACTORY_SALT_ENV, DEFAULT_CREATE2_FACTORY_SALT);
        }

        if (_create2FactoryAddress != address(0)) {
            if (_create2FactoryAddress.code.length == 0) {
                revert AddressHasNoCode(_create2FactoryAddress);
            }

            create2FactoryState = Create2FactoryState({create2FactoryAddress: _create2FactoryAddress});
            console.log("Using configured Create2Factory address:", _create2FactoryAddress);
            return;
        }

        if (Utils.DETERMINISTIC_CREATE2_ADDRESS.code.length == 0) {
            revert AddressHasNoCode(Utils.DETERMINISTIC_CREATE2_ADDRESS);
        }

        create2FactoryState = Create2FactoryState({create2FactoryAddress: Utils.DETERMINISTIC_CREATE2_ADDRESS});
        console.log("Using deterministic Create2Factory address:", Utils.DETERMINISTIC_CREATE2_ADDRESS);
    }

    /// @notice Ensures the factory has been instantiated, lazily initializing on first use.
    function _ensureCreate2Factory() private {
        if (create2FactoryState.create2FactoryAddress == address(0)) {
            instantiateCreate2Factory();
        }
    }

    /// @notice Deploys a contract via Create2 using the provided complete bytecode.
    /// @param bytecode The full bytecode (creation code concatenated with constructor arguments).
    /// @return The deployed contract address.
    function deployViaCreate2(bytes memory bytecode) internal virtual returns (address) {
        _ensureCreate2Factory();
        return Utils.deployViaCreate2(bytecode, _create2FactorySalt, create2FactoryState.create2FactoryAddress);
    }

    /// @notice Deploys a contract via Create2 by concatenating the creation code and constructor arguments.
    /// @param creationCode The creation code of the contract.
    /// @param constructorArgs The constructor arguments.
    /// @return The deployed contract address.
    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual returns (address) {
        _ensureCreate2Factory();
        return
            Utils.deployViaCreate2(
                abi.encodePacked(creationCode, constructorArgs),
                _create2FactorySalt,
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
        string memory contractName,
        bool isZKBytecode
    ) internal returns (address deployedAddress) {
        deployedAddress = deployViaCreate2AndNotify(
            creationCode,
            constructorParams,
            contractName,
            contractName,
            isZKBytecode
        );
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
        string memory displayName,
        bool isZKBytecode
    ) internal returns (address deployedAddress) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorParams);
        deployedAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(deployedAddress, contractName, constructorParams, displayName, isZKBytecode);
    }

    /// @notice Deploys a contract via Create2 with a deterministic owner.
    /// @param initCode The concatenated initialization code.
    /// @param owner The address to be set as the owner.
    /// @return The deployed contract address.
    function create2WithDeterministicOwner(bytes memory initCode, address owner) internal returns (address) {
        bytes memory creatorInitCode = abi.encodePacked(
            type(Create2AndTransfer).creationCode,
            abi.encode(initCode, _create2FactorySalt, owner)
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
        string memory displayName,
        bool isZKBytecode
    ) internal returns (address contractAddress) {
        contractAddress = create2WithDeterministicOwner(abi.encodePacked(initCode, constructorParams), owner);
        notifyAboutDeployment(contractAddress, contractName, constructorParams, displayName, isZKBytecode);
    }

    /// @notice Overload for notifyAboutDeployment that takes three arguments.
    /// @param contractAddr The deployed contract address.
    /// @param contractName The internal contract name.
    /// @param constructorParams The encoded constructor parameters.
    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams,
        bool isZKBytecode
    ) internal view {
        notifyAboutDeployment(contractAddr, contractName, constructorParams, contractName, isZKBytecode);
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
        string memory displayName,
        bool isZKBytecode
    ) internal view {
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

        if (isZKBytecode) {
            forgeMessage = string.concat(forgeMessage, " --verifier zksync");
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
        return Utils.compareStrings(a, b);
    }
}
