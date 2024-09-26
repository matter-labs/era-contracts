// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {UnsupportedEncodingVersion, CallNotAllowed, ChainZeroAddress, NotAHyperchain, NotAnAdmin, RemovingPermanentRestriction, ZeroAddress, UnallowedImplementation, AlreadyWhitelisted, NotAllowed, NotBridgehub, InvalidSelector, InvalidAddress, NotEnoughGas} from "../common/L1ContractErrors.sol";

import {L2TransactionRequestTwoBridgesOuter, BridgehubBurnCTMAssetData} from "../bridgehub/IBridgehub.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {NEW_ENCODING_VERSION} from "../bridge/asset-router/IAssetRouterBase.sol";

import {Call} from "./Common.sol";
import {IRestriction} from "./IRestriction.sol";
import {IChainAdmin} from "./IChainAdmin.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";

import {IPermanentRestriction} from "./IPermanentRestriction.sol";

/// @dev We use try-catch to test whether some of the conditions should be checked.
/// To avoid attacks based on the 63/64 gas limitations, we ensure that each such call
/// has at least this amount.
uint256 constant MIN_GAS_FOR_FALLABLE_CALL = 5_000_000;

/// @title PermanentRestriction contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract should be used by chains that wish to guarantee that certain security
/// properties are preserved forever.
/// @dev To be deployed as a transparent upgradable proxy, owned by a trusted decentralized governance.
/// @dev Once of the instances of such contract is to ensure that a ZkSyncHyperchain is a rollup forever.
contract PermanentRestriction is IRestriction, IPermanentRestriction, Ownable2StepUpgradeable {
    /// @notice The address of the Bridgehub contract.
    IBridgehub public immutable BRIDGE_HUB;

    /// @notice The address of the L2 admin factory that should be used to deploy the chain admins
    /// for chains that migrated on top of an L2 settlement layer.
    /// @dev If this contract is deployed on L2, this address is 0.
    /// @dev This address is expected to be the same on all L2 chains.
    address public immutable L2_ADMIN_FACTORY;

    /// @notice The mapping of the allowed admin implementations.
    mapping(bytes32 implementationCodeHash => bool isAllowed) public allowedAdminImplementations;

    /// @notice The mapping of the allowed calls.
    mapping(bytes allowedCalldata => bool isAllowed) public allowedCalls;

    /// @notice The mapping of the validated selectors.
    mapping(bytes4 selector => bool isValidated) public validatedSelectors;

    /// @notice The mapping of whitelisted L2 admins.
    mapping(address adminAddress => bool isWhitelisted) public allowedL2Admins;

    constructor(IBridgehub _bridgehub, address _l2AdminFactory) {
        BRIDGE_HUB = _bridgehub;
        L2_ADMIN_FACTORY = _l2AdminFactory;
    }

    function initialize(address _initialOwner) external initializer {
        // solhint-disable-next-line gas-custom-errors, reason-string
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @notice Allows a certain `ChainAdmin` implementation to be used as an admin.
    /// @param _implementationHash The hash of the implementation code.
    /// @param _isAllowed The flag that indicates if the implementation is allowed.
    function allowAdminImplementation(bytes32 _implementationHash, bool _isAllowed) external onlyOwner {
        allowedAdminImplementations[_implementationHash] = _isAllowed;

        emit AdminImplementationAllowed(_implementationHash, _isAllowed);
    }

    /// @notice Allows a certain calldata for a selector to be used.
    /// @param _data The calldata for the function.
    /// @param _isAllowed The flag that indicates if the calldata is allowed.
    function setAllowedData(bytes calldata _data, bool _isAllowed) external onlyOwner {
        allowedCalls[_data] = _isAllowed;

        emit AllowedDataChanged(_data, _isAllowed);
    }

    /// @notice Allows a certain selector to be validated.
    /// @param _selector The selector of the function.
    /// @param _isValidated The flag that indicates if the selector is validated.
    function setSelectorIsValidated(bytes4 _selector, bool _isValidated) external onlyOwner {
        validatedSelectors[_selector] = _isValidated;

        emit SelectorValidationChanged(_selector, _isValidated);
    }

    /// @notice Whitelists a certain L2 admin.
    /// @param deploymentSalt The salt for the deployment.
    /// @param l2BytecodeHash The hash of the L2 bytecode.
    /// @param constructorInputHash The hash of the constructor data for the deployment.
    function allowL2Admin(bytes32 deploymentSalt, bytes32 l2BytecodeHash, bytes32 constructorInputHash) external {
        // We do not do any additional validations for constructor data or the bytecode,
        // we expect that only admins of the allowed format are to be deployed.
        address expectedAddress = L2ContractHelper.computeCreate2Address(
            L2_ADMIN_FACTORY,
            deploymentSalt,
            l2BytecodeHash,
            constructorInputHash
        );

        if (allowedL2Admins[expectedAddress]) {
            revert AlreadyWhitelisted(expectedAddress);
        }

        allowedL2Admins[expectedAddress] = true;
        emit AllowL2Admin(expectedAddress);
    }

    /// @inheritdoc IRestriction
    function validateCall(
        Call calldata _call,
        address // _invoker
    ) external view override {
        _validateAsChainAdmin(_call);
        _validateMigrationToL2(_call);
        _validateRemoveRestriction(_call);
    }

    /// @notice Validates the migration to an L2 settlement layer.
    /// @param _call The call data.
    /// @dev Note that we do not need to validate the migration to the L1 layer as the admin
    /// is not changed in this case.
    function _validateMigrationToL2(Call calldata _call) internal view {
        _ensureEnoughGas();
        try this.tryGetNewAdminFromMigration(_call) returns (address admin) {
            if (!allowedL2Admins[admin]) {
                revert NotAllowed(admin);
            }
        } catch {
            // It was not the migration call, so we do nothing
        }
    }

    /// @notice Validates the call as the chain admin
    /// @param _call The call data.
    function _validateAsChainAdmin(Call calldata _call) internal view {
        if (!_isAdminOfAChain(_call.target)) {
            // We only validate calls related to being an admin of a chain
            return;
        }

        // All calls with the length of the data below 4 will get into `receive`/`fallback` functions,
        // we consider it to always be allowed.
        if (_call.data.length < 4) {
            return;
        }

        bytes4 selector = bytes4(_call.data[:4]);

        if (selector == IAdmin.setPendingAdmin.selector) {
            _validateNewAdmin(_call);
            return;
        }

        if (!validatedSelectors[selector]) {
            // The selector is not validated, any data is allowed.
            return;
        }

        if (!allowedCalls[_call.data]) {
            revert CallNotAllowed(_call.data);
        }
    }

    /// @notice Validates the correctness of the new admin.
    /// @param _call The call data.
    /// @dev Ensures that the admin has a whitelisted implementation and does not remove this restriction.
    function _validateNewAdmin(Call calldata _call) internal view {
        address newChainAdmin = abi.decode(_call.data[4:], (address));

        bytes32 implementationCodeHash = newChainAdmin.codehash;

        if (!allowedAdminImplementations[implementationCodeHash]) {
            revert UnallowedImplementation(implementationCodeHash);
        }

        // Since the implementation is known to be correct (from the checks above), we
        // can safely trust the returned value from the call below
        if (!IChainAdmin(newChainAdmin).isRestrictionActive(address(this))) {
            revert RemovingPermanentRestriction();
        }
    }

    /// @notice Validates the removal of the restriction.
    /// @param _call The call data.
    /// @dev Ensures that this restriction is not removed.
    function _validateRemoveRestriction(Call calldata _call) internal view {
        if (_call.target != msg.sender) {
            return;
        }

        if (bytes4(_call.data[:4]) != IChainAdmin.removeRestriction.selector) {
            return;
        }

        address removedRestriction = abi.decode(_call.data[4:], (address));

        if (removedRestriction == address(this)) {
            revert RemovingPermanentRestriction();
        }
    }

    /// @notice Checks if the `msg.sender` is an admin of a certain ZkSyncHyperchain.
    /// @param _chain The address of the chain.
    function _isAdminOfAChain(address _chain) internal view returns (bool) {
        _ensureEnoughGas();
        (bool success, ) = address(this).staticcall(abi.encodeCall(this.tryCompareAdminOfAChain, (_chain, msg.sender)));
        return success;
    }

    /// @notice Tries to compare the admin of a chain with the potential admin.
    /// @param _chain The address of the chain.
    /// @param _potentialAdmin The address of the potential admin.
    /// @dev This function reverts if the `_chain` is not a ZkSyncHyperchain or the `_potentialAdmin` is not the
    /// admin of the chain.
    function tryCompareAdminOfAChain(address _chain, address _potentialAdmin) external view {
        if (_chain == address(0)) {
            revert ChainZeroAddress();
        }

        // Unfortunately there is no easy way to double check that indeed the `_chain` is a ZkSyncHyperchain.
        // So we do the following:
        // - Query it for `chainId`. If it reverts, it is not a ZkSyncHyperchain.
        // - Query the Bridgehub for the Hyperchain with the given `chainId`.
        // - We compare the corresponding addresses

        // Note, that we do not use an explicit call here to ensure that the function does not panic in case of
        // incorrect `_chain` address.
        (bool success, bytes memory data) = _chain.staticcall(abi.encodeWithSelector(IGetters.getChainId.selector));
        if (!success || data.length < 32) {
            revert NotAHyperchain(_chain);
        }

        // Can not fail
        uint256 chainId = abi.decode(data, (uint256));

        // Note, that here it is important to use the legacy `getHyperchain` function, so that the contract
        // is compatible with the legacy ones.
        if (BRIDGE_HUB.getHyperchain(chainId) != _chain) {
            revert NotAHyperchain(_chain);
        }

        // Now, the chain is known to be a hyperchain, so it should implement the corresponding interface
        address admin = IZKChain(_chain).getAdmin();
        if (admin != _potentialAdmin) {
            revert NotAnAdmin(admin, _potentialAdmin);
        }
    }

    /// @notice Tries to get the new admin from the migration.
    /// @param _call The call data.
    /// @dev This function reverts if the provided call was not a migration call.
    function tryGetNewAdminFromMigration(Call calldata _call) external view returns (address) {
        if (_call.target != address(BRIDGE_HUB)) {
            revert NotBridgehub(_call.target);
        }

        if (bytes4(_call.data[:4]) != IBridgehub.requestL2TransactionTwoBridges.selector) {
            revert InvalidSelector(bytes4(_call.data[:4]));
        }

        address sharedBridge = BRIDGE_HUB.sharedBridge();

        L2TransactionRequestTwoBridgesOuter memory request = abi.decode(
            _call.data[4:],
            (L2TransactionRequestTwoBridgesOuter)
        );

        if (request.secondBridgeAddress != sharedBridge) {
            revert InvalidAddress(sharedBridge, request.secondBridgeAddress);
        }

        bytes memory secondBridgeData = request.secondBridgeCalldata;
        if (secondBridgeData[0] != NEW_ENCODING_VERSION) {
            revert UnsupportedEncodingVersion();
        }
        bytes memory encodedData = new bytes(secondBridgeData.length - 1);
        assembly {
            mcopy(add(encodedData, 0x20), add(secondBridgeData, 0x21), mload(encodedData))
        }

        (bytes32 chainAssetId, bytes memory bridgehubData) = abi.decode(encodedData, (bytes32, bytes));
        // We will just check that the chainAssetId is a valid chainAssetId.
        // For now, for simplicity, we do not check that the admin is exactly the admin
        // of this chain.
        address ctmAddress = BRIDGE_HUB.ctmAssetIdToAddress(chainAssetId);
        if (ctmAddress == address(0)) {
            revert ZeroAddress();
        }

        BridgehubBurnCTMAssetData memory burnData = abi.decode(bridgehubData, (BridgehubBurnCTMAssetData));
        (address l2Admin, ) = abi.decode(burnData.ctmData, (address, bytes));

        return l2Admin;
    }

    function _ensureEnoughGas() internal view {
        if (gasleft() < MIN_GAS_FOR_FALLABLE_CALL) {
            revert NotEnoughGas();
        }
    }
}