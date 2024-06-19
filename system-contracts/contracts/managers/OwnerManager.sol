// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {ClaveStorage} from "../libraries/ClaveStorage.sol";
import {BytesLinkedList, AddressLinkedList} from "../libraries/LinkedList.sol";
import {Errors} from "../libraries/Errors.sol";
import {Auth} from "../auth/Auth.sol";
import {IClaveAccount} from "../interfaces/IClave.sol";
import {IOwnerManager} from "../interfaces/IOwnerManager.sol";

/**
 * @title Manager contract for owners
 * @notice Abstract contract for managing the owners of the account
 * @dev R1 Owners are 64 byte secp256r1 public keys
 * @dev K1 Owners are secp256k1 addresses
 * @dev Owners are stored in a linked list
 * @author https://getclave.io
 */
abstract contract OwnerManager is IOwnerManager, Auth {
    // Helper library for bytes to bytes mappings
    using BytesLinkedList for mapping(bytes => bytes);
    // Helper library for address to address mappings
    using AddressLinkedList for mapping(address => address);

    /// @inheritdoc IOwnerManager
    function r1AddOwner(
        bytes calldata pubKey
    ) external override onlySelfOrModule {
        _r1AddOwner(pubKey);
    }

    /// @inheritdoc IOwnerManager
    function k1AddOwner(address addr) external override onlySelfOrModule {
        _k1AddOwner(addr);
    }

    /// @inheritdoc IOwnerManager
    function r1RemoveOwner(
        bytes calldata pubKey
    ) external override onlySelfOrModule {
        _r1RemoveOwner(pubKey);
    }

    /// @inheritdoc IOwnerManager
    function k1RemoveOwner(address addr) external override onlySelfOrModule {
        _k1RemoveOwner(addr);
    }

    /// @inheritdoc IOwnerManager
    function resetOwners(
        bytes calldata pubKey
    ) external override onlySelfOrModule {
        _r1ClearOwners();
        _k1ClearOwners();

        emit ResetOwners();

        _r1AddOwner(pubKey);
    }

    /// @inheritdoc IOwnerManager
    function r1IsOwner(
        bytes calldata pubKey
    ) external view override returns (bool) {
        return _r1IsOwner(pubKey);
    }

    /// @inheritdoc IOwnerManager
    function k1IsOwner(address addr) external view override returns (bool) {
        return _k1IsOwner(addr);
    }

    /// @inheritdoc IOwnerManager
    function r1ListOwners()
        external
        view
        override
        returns (bytes[] memory r1OwnerList)
    {
        r1OwnerList = _r1OwnersLinkedList().list();
    }

    /// @inheritdoc IOwnerManager
    function k1ListOwners()
        external
        view
        override
        returns (address[] memory k1OwnerList)
    {
        k1OwnerList = _k1OwnersLinkedList().list();
    }

    function _r1AddOwner(bytes calldata pubKey) internal {
        if (pubKey.length != 64) {
            revert Errors.INVALID_PUBKEY_LENGTH();
        }

        _r1OwnersLinkedList().add(pubKey);

        emit R1AddOwner(pubKey);
    }

    function _k1AddOwner(address addr) internal {
        _k1OwnersLinkedList().add(addr);

        emit K1AddOwner(addr);
    }

    function _r1RemoveOwner(bytes calldata pubKey) internal {
        _r1OwnersLinkedList().remove(pubKey);

        if (_r1OwnersLinkedList().isEmpty()) {
            revert Errors.EMPTY_R1_OWNERS();
        }

        emit R1RemoveOwner(pubKey);
    }

    function _k1RemoveOwner(address addr) internal {
        _k1OwnersLinkedList().remove(addr);

        emit K1RemoveOwner(addr);
    }

    function _r1IsOwner(bytes calldata pubKey) internal view returns (bool) {
        return _r1OwnersLinkedList().exists(pubKey);
    }

    function _k1IsOwner(address addr) internal view returns (bool) {
        return _k1OwnersLinkedList().exists(addr);
    }

    function _r1OwnersLinkedList()
        internal
        view
        returns (mapping(bytes => bytes) storage r1Owners)
    {
        r1Owners = ClaveStorage.layout().r1Owners;
    }

    function _k1OwnersLinkedList()
        internal
        view
        returns (mapping(address => address) storage k1Owners)
    {
        k1Owners = ClaveStorage.layout().k1Owners;
    }

    function _r1ClearOwners() private {
        _r1OwnersLinkedList().clear();
    }

    function _k1ClearOwners() private {
        _k1OwnersLinkedList().clear();
    }
}
