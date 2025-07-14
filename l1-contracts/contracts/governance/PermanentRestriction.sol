// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {TooHighDeploymentNonce, CallNotAllowed, RemovingPermanentRestriction, ZeroAddress, UnallowedImplementation, AlreadyWhitelisted, NotAllowed} from "../common/L1ContractErrors.sol";

import {L2TransactionRequestTwoBridgesOuter, BridgehubBurnCTMAssetData} from "../bridgehub/IBridgehub.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {NEW_ENCODING_VERSION, IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";

import {Call} from "./Common.sol";
import {Restriction} from "./restriction/Restriction.sol";
import {IChainAdmin} from "./IChainAdmin.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";

import {IPermanentRestriction} from "./IPermanentRestriction.sol";

/// @dev The value up to which the nonces of the L2AdminDeployer could be used. This is needed
/// to limit the impact of the birthday paradox attack, where an attack could craft a malicious
/// address on L1.
uint256 constant MAX_ALLOWED_NONCE = (1 << 48);

/// @title PermanentRestriction contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract should be used by chains that wish to guarantee that certain security
/// properties are preserved forever.
/// @dev To be deployed as a transparent upgradable proxy, owned by a trusted decentralized governance.
/// @dev Once of the instances of such contract is to ensure that a ZkSyncHyperchain is a rollup forever.
contract PermanentRestriction is Restriction, IPermanentRestriction, Ownable2StepUpgradeable {
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
    mapping(bytes4 selector => bool isValidated) public selectorsToValidate;

    /// @notice The mapping of whitelisted L2 admins.
    mapping(address adminAddress => bool isWhitelisted) public allowedL2Admins;

    constructor(IBridgehub _bridgehub, address _l2AdminFactory) {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        L2_ADMIN_FACTORY = _l2AdminFactory;
    }

    /// @notice The initialization function for the proxy contract.
    /// @param _initialOwner The initial owner of the permanent restriction.
    /// @dev Expected to be delegatecalled by the `TransparentUpgradableProxy`
    /// upon initialization.
    function initialize(address _initialOwner) external initializer {
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @notice Allows a certain `ChainAdmin` implementation to be used as an admin.
    /// @param _implementationHash The hash of the implementation code.
    /// @param _isAllowed The flag that indicates if the implementation is allowed.
    function setAllowedAdminImplementation(bytes32 _implementationHash, bool _isAllowed) external onlyOwner {
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
    function setSelectorShouldBeValidated(bytes4 _selector, bool _isValidated) external onlyOwner {
        selectorsToValidate[_selector] = _isValidated;

        emit SelectorValidationChanged(_selector, _isValidated);
    }

    /// @notice Whitelists a certain L2 admin.
    /// @param deploymentNonce The deployment nonce of the `L2_ADMIN_FACTORY` used for the deployment.
    function allowL2Admin(uint256 deploymentNonce) external {
        if (deploymentNonce > MAX_ALLOWED_NONCE) {
            revert TooHighDeploymentNonce();
        }

        // We do not do any additional validations for constructor data or the bytecode,
        // we expect that only admins of the allowed format are to be deployed.
        address expectedAddress = L2ContractHelper.computeCreateAddress(L2_ADMIN_FACTORY, deploymentNonce);

        if (allowedL2Admins[expectedAddress]) {
            revert AlreadyWhitelisted(expectedAddress);
        }

        allowedL2Admins[expectedAddress] = true;
        emit AllowL2Admin(expectedAddress);
    }

    /// @inheritdoc Restriction
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
    function _validateMigrationToL2(Call calldata _call) private view {
        (address admin, bool isMigration) = _getNewAdminFromMigration(_call);
        if (isMigration) {
            if (!allowedL2Admins[admin]) {
                revert NotAllowed(admin);
            }
        }
    }

    /// @notice Validates the call as the chain admin
    /// @param _call The call data.
    function _validateAsChainAdmin(Call calldata _call) private view {
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

        if (!selectorsToValidate[selector]) {
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
    function _validateNewAdmin(Call calldata _call) private view {
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
    function _validateRemoveRestriction(Call calldata _call) private view {
        if (_call.target != msg.sender) {
            return;
        }

        if (_call.data.length < 4) {
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
        if (_chain == address(0)) {
            return false;
        }

        // Unfortunately there is no easy way to double check that indeed the `_chain` is a ZkSyncHyperchain.
        // So we do the following:
        // - Query it for `chainId`. If it reverts, it is not a ZkSyncHyperchain.
        // - Query the Bridgehub for the Hyperchain with the given `chainId`.
        // - We compare the corresponding addresses

        // Note, that we do use assembly here to ensure that the function does not panic in case of
        // either incorrect `_chain` address or in case the returndata is too large

        (uint256 chainId, bool chainIdQuerySuccess) = _getChainIdUnffallibleCall(_chain);

        if (!chainIdQuerySuccess) {
            // It is not a hyperchain, so we can return `false` here.
            return false;
        }

        // Note, that here it is important to use the legacy `getHyperchain` function, so that the contract
        // is compatible with the legacy ones.
        if (BRIDGE_HUB.getHyperchain(chainId) != _chain) {
            // It is not a hyperchain, so we can return `false` here.
            return false;
        }

        // Now, the chain is known to be a hyperchain, so it must implement the corresponding interface
        address admin = IZKChain(_chain).getAdmin();

        return admin == msg.sender;
    }

    /// @notice Tries to call `IGetters.getChainId()` function on the `_potentialChainAddress`.
    /// It ensures that the returndata is of correct format and if not, it returns false.
    /// @param _chain The address of the potential chain
    /// @return chainId The chainId of the chain.
    /// @return success Whether the `chain` is indeed an address of a ZK Chain.
    /// @dev Returns a tuple of the chainId and whether the call was successful.
    /// If the second item is `false`, the caller should ignore the first value.
    function _getChainIdUnffallibleCall(address _chain) private view returns (uint256 chainId, bool success) {
        bytes4 selector = IGetters.getChainId.selector;
        assembly {
            // We use scratch space here, so it is safe
            mstore(0, selector)
            success := staticcall(gas(), _chain, 0, 4, 0, 0)

            let isReturndataSizeCorrect := eq(returndatasize(), 32)

            success := and(success, isReturndataSizeCorrect)

            if success {
                // We use scratch space here, so it is safe
                returndatacopy(0, 0, 32)

                chainId := mload(0)
            }
        }
    }

    /// @notice Tries to get the new admin from the migration.
    /// @param _call The call data.
    /// @return Returns a tuple of of the new admin and whether the transaction is indeed the migration.
    /// If the second item is `false`, the caller should ignore the first value.
    /// @dev If any other error is returned, it is assumed to be out of gas or some other unexpected
    /// error that should be bubbled up by the caller.
    function _getNewAdminFromMigration(Call calldata _call) internal view returns (address, bool) {
        if (_call.target != address(BRIDGE_HUB)) {
            return (address(0), false);
        }

        if (_call.data.length < 4) {
            return (address(0), false);
        }

        if (bytes4(_call.data[:4]) != IBridgehub.requestL2TransactionTwoBridges.selector) {
            return (address(0), false);
        }

        address sharedBridge = BRIDGE_HUB.sharedBridge();

        // Assuming that correctly encoded calldata is provided, the following line must never fail,
        // since the correct selector was checked before.
        L2TransactionRequestTwoBridgesOuter memory request = abi.decode(
            _call.data[4:],
            (L2TransactionRequestTwoBridgesOuter)
        );

        if (request.secondBridgeAddress != sharedBridge) {
            return (address(0), false);
        }

        bytes memory secondBridgeData = request.secondBridgeCalldata;
        if (secondBridgeData.length == 0) {
            return (address(0), false);
        }

        if (secondBridgeData[0] != NEW_ENCODING_VERSION) {
            return (address(0), false);
        }
        bytes memory encodedData = new bytes(secondBridgeData.length - 1);
        assembly {
            mcopy(add(encodedData, 0x20), add(secondBridgeData, 0x21), mload(encodedData))
        }

        // From now on, we know that the used encoding version is `NEW_ENCODING_VERSION` that is
        // supported only in the new protocol version with Gateway support, so we can assume
        // that the methods like e.g. Bridgehub.ctmAssetIdToAddress must exist.

        // This is the format of the `secondBridgeData` under the `NEW_ENCODING_VERSION`.
        // If it fails, it would mean that the data is not correct and the call would eventually fail anyway.
        (bytes32 chainAssetId, bytes memory bridgehubData) = abi.decode(encodedData, (bytes32, bytes));

        // We will just check that the chainAssetId is a valid chainAssetId.
        // For now, for simplicity, we do not check that the admin is exactly the admin
        // of this chain.
        address ctmAddress = BRIDGE_HUB.ctmAssetIdToAddress(chainAssetId);
        if (ctmAddress == address(0)) {
            return (address(0), false);
        }

        // Almost certainly it will be Bridgehub, but we add this check just in case we have circumstances
        // that require us to use a different asset handler.
        address assetHandlerAddress = IAssetRouterBase(sharedBridge).assetHandlerAddress(chainAssetId);
        if (assetHandlerAddress != address(BRIDGE_HUB)) {
            return (address(0), false);
        }

        // The asset handler of CTM is the bridgehub and so the following decoding should work
        BridgehubBurnCTMAssetData memory burnData = abi.decode(bridgehubData, (BridgehubBurnCTMAssetData));
        (address l2Admin, ) = abi.decode(burnData.ctmData, (address, bytes));

        return (l2Admin, true);
    }
}
