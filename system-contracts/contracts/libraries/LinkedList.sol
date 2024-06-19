// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {Errors} from "../libraries/Errors.sol";

/**
 * @title Bytes linked list library
 * @notice Helper library for bytes linkedlist operations
 * @author https://getclave.io
 */
library BytesLinkedList {
    bytes internal constant SENTINEL_BYTES = hex"00";
    uint8 internal constant SENTINEL_LENGTH = 1;

    modifier validBytes(bytes calldata value) {
        if (value.length <= SENTINEL_LENGTH) {
            revert Errors.INVALID_BYTES();
        }
        _;
    }

    function add(
        mapping(bytes => bytes) storage self,
        bytes calldata value
    ) internal validBytes(value) {
        if (self[value].length != 0) {
            revert Errors.BYTES_ALREADY_EXISTS();
        }

        bytes memory prev = self[SENTINEL_BYTES];
        if (prev.length < SENTINEL_LENGTH) {
            self[SENTINEL_BYTES] = value;
            self[value] = SENTINEL_BYTES;
        } else {
            self[SENTINEL_BYTES] = value;
            self[value] = prev;
        }
    }

    function replace(
        mapping(bytes => bytes) storage self,
        bytes calldata oldValue,
        bytes calldata newValue
    ) internal {
        if (!exists(self, oldValue)) {
            revert Errors.BYTES_NOT_EXISTS();
        }
        if (exists(self, newValue)) {
            revert Errors.BYTES_ALREADY_EXISTS();
        }

        bytes memory cursor = SENTINEL_BYTES;
        while (true) {
            bytes memory _value = self[cursor];
            if (equals(_value, oldValue)) {
                bytes memory next = self[_value];
                self[newValue] = next;
                self[cursor] = newValue;
                delete self[_value];
                return;
            }
            cursor = _value;
        }
    }

    function replaceUsingPrev(
        mapping(bytes => bytes) storage self,
        bytes calldata prevValue,
        bytes calldata oldValue,
        bytes calldata newValue
    ) internal {
        if (!exists(self, oldValue)) {
            revert Errors.BYTES_NOT_EXISTS();
        }
        if (exists(self, newValue)) {
            revert Errors.BYTES_ALREADY_EXISTS();
        }
        if (!equals(self[prevValue], oldValue)) {
            revert Errors.INVALID_PREV();
        }

        self[newValue] = self[oldValue];
        self[prevValue] = newValue;
        delete self[oldValue];
    }

    function remove(
        mapping(bytes => bytes) storage self,
        bytes calldata value
    ) internal {
        if (!exists(self, value)) {
            revert Errors.BYTES_NOT_EXISTS();
        }

        bytes memory cursor = SENTINEL_BYTES;
        while (true) {
            bytes memory _value = self[cursor];
            if (equals(_value, value)) {
                bytes memory next = self[_value];
                self[cursor] = next;
                delete self[_value];
                return;
            }
            cursor = _value;
        }
    }

    function removeUsingPrev(
        mapping(bytes => bytes) storage self,
        bytes calldata prevValue,
        bytes calldata value
    ) internal {
        if (!exists(self, value)) {
            revert Errors.BYTES_NOT_EXISTS();
        }
        if (!equals(self[prevValue], value)) {
            revert Errors.INVALID_PREV();
        }

        self[prevValue] = self[value];
        delete self[value];
    }

    function clear(mapping(bytes => bytes) storage self) internal {
        bytes memory cursor = SENTINEL_BYTES;
        do {
            bytes memory nextCursor = self[cursor];
            delete self[cursor];
            cursor = nextCursor;
        } while (cursor.length > SENTINEL_LENGTH);
    }

    function exists(
        mapping(bytes => bytes) storage self,
        bytes calldata value
    ) internal view validBytes(value) returns (bool) {
        return self[value].length != 0;
    }

    function size(
        mapping(bytes => bytes) storage self
    ) internal view returns (uint256) {
        uint256 result = 0;
        bytes memory cursor = self[SENTINEL_BYTES];
        while (cursor.length > SENTINEL_LENGTH) {
            cursor = self[cursor];
            unchecked {
                result++;
            }
        }
        return result;
    }

    function isEmpty(
        mapping(bytes => bytes) storage self
    ) internal view returns (bool) {
        return self[SENTINEL_BYTES].length <= SENTINEL_LENGTH;
    }

    function list(
        mapping(bytes => bytes) storage self
    ) internal view returns (bytes[] memory) {
        uint256 _size = size(self);
        bytes[] memory result = new bytes[](_size);
        uint256 i = 0;
        bytes memory cursor = self[SENTINEL_BYTES];
        while (cursor.length > SENTINEL_LENGTH) {
            result[i] = cursor;
            cursor = self[cursor];
            unchecked {
                i++;
            }
        }

        return result;
    }

    function equals(
        bytes memory a,
        bytes memory b
    ) private pure returns (bool result) {
        assembly {
            result := eq(
                keccak256(add(a, 0x20), mload(a)),
                keccak256(add(b, 0x20), mload(b))
            )
        }
    }
}

/**
 * @title Address linked list library
 * @notice Helper library for address linkedlist operations
 */
library AddressLinkedList {
    address internal constant SENTINEL_ADDRESS = address(1);

    modifier validAddress(address value) {
        if (value <= SENTINEL_ADDRESS) {
            revert Errors.INVALID_ADDRESS();
        }
        _;
    }

    function add(
        mapping(address => address) storage self,
        address value
    ) internal validAddress(value) {
        if (self[value] != address(0)) {
            revert Errors.ADDRESS_ALREADY_EXISTS();
        }

        address prev = self[SENTINEL_ADDRESS];
        if (prev == address(0)) {
            self[SENTINEL_ADDRESS] = value;
            self[value] = SENTINEL_ADDRESS;
        } else {
            self[SENTINEL_ADDRESS] = value;
            self[value] = prev;
        }
    }

    function replace(
        mapping(address => address) storage self,
        address oldValue,
        address newValue
    ) internal {
        if (!exists(self, oldValue)) {
            revert Errors.ADDRESS_NOT_EXISTS();
        }
        if (exists(self, newValue)) {
            revert Errors.ADDRESS_ALREADY_EXISTS();
        }

        address cursor = SENTINEL_ADDRESS;
        while (true) {
            address _value = self[cursor];
            if (_value == oldValue) {
                address next = self[_value];
                self[newValue] = next;
                self[cursor] = newValue;
                delete self[_value];
                return;
            }
            cursor = _value;
        }
    }

    function replaceUsingPrev(
        mapping(address => address) storage self,
        address prevValue,
        address oldValue,
        address newValue
    ) internal {
        if (!exists(self, oldValue)) {
            revert Errors.ADDRESS_NOT_EXISTS();
        }
        if (exists(self, newValue)) {
            revert Errors.ADDRESS_ALREADY_EXISTS();
        }
        if (self[prevValue] != oldValue) {
            revert Errors.INVALID_PREV();
        }

        self[newValue] = self[oldValue];
        self[prevValue] = newValue;
        delete self[oldValue];
    }

    function remove(
        mapping(address => address) storage self,
        address value
    ) internal {
        if (!exists(self, value)) {
            revert Errors.ADDRESS_NOT_EXISTS();
        }

        address cursor = SENTINEL_ADDRESS;
        while (true) {
            address _value = self[cursor];
            if (_value == value) {
                address next = self[_value];
                self[cursor] = next;
                delete self[_value];
                return;
            }
            cursor = _value;
        }
    }

    function removeUsingPrev(
        mapping(address => address) storage self,
        address prevValue,
        address value
    ) internal {
        if (!exists(self, value)) {
            revert Errors.ADDRESS_NOT_EXISTS();
        }
        if (self[prevValue] != value) {
            revert Errors.INVALID_PREV();
        }

        self[prevValue] = self[value];
        delete self[value];
    }

    function clear(mapping(address => address) storage self) internal {
        address cursor = SENTINEL_ADDRESS;
        do {
            address nextCursor = self[cursor];
            delete self[cursor];
            cursor = nextCursor;
        } while (cursor > SENTINEL_ADDRESS);
    }

    function exists(
        mapping(address => address) storage self,
        address value
    ) internal view validAddress(value) returns (bool) {
        return self[value] != address(0);
    }

    function size(
        mapping(address => address) storage self
    ) internal view returns (uint256) {
        uint256 result = 0;
        address cursor = self[SENTINEL_ADDRESS];
        while (cursor > SENTINEL_ADDRESS) {
            cursor = self[cursor];
            unchecked {
                result++;
            }
        }
        return result;
    }

    function isEmpty(
        mapping(address => address) storage self
    ) internal view returns (bool) {
        return self[SENTINEL_ADDRESS] <= SENTINEL_ADDRESS;
    }

    function list(
        mapping(address => address) storage self
    ) internal view returns (address[] memory) {
        uint256 _size = size(self);
        address[] memory result = new address[](_size);
        uint256 i = 0;
        address cursor = self[SENTINEL_ADDRESS];
        while (cursor > SENTINEL_ADDRESS) {
            result[i] = cursor;
            cursor = self[cursor];
            unchecked {
                i++;
            }
        }

        return result;
    }
}
