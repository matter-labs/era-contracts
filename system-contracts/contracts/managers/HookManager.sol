// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Transaction} from "../libraries/TransactionHelper.sol";
import {ExcessivelySafeCall} from "@nomad-xyz/excessively-safe-call/src/ExcessivelySafeCall.sol";

import {Auth} from "../auth/Auth.sol";
import {ClaveStorage} from "../libraries/ClaveStorage.sol";
import {AddressLinkedList} from "../libraries/LinkedList.sol";
import {Errors} from "../libraries/Errors.sol";
import {IExecutionHook, IValidationHook} from "../interfaces/IHook.sol";
import {IInitable} from "../interfaces/IInitable.sol";
import {IHookManager} from "../interfaces/IHookManager.sol";

/**
 * @title Manager contract for hooks
 * @notice Abstract contract for managing the enabled hooks of the account
 * @dev Hook addresses are stored in a linked list
 * @author https://getclave.io
 */
abstract contract HookManager is IHookManager, Auth {
    // Helper library for address to address mappings
    using AddressLinkedList for mapping(address => address);
    // Interface helper library
    using ERC165Checker for address;
    // Low level calls helper library
    using ExcessivelySafeCall for address;

    // Slot for execution hooks to store context
    bytes32 private constant CONTEXT_KEY = keccak256("HookManager.context");

    /// @inheritdoc IHookManager
    function addHook(
        bytes calldata hookAndData,
        bool isValidation
    ) external override onlySelfOrModule {
        _addHook(hookAndData, isValidation);
    }

    /// @inheritdoc IHookManager
    function removeHook(
        address hook,
        bool isValidation
    ) external override onlySelfOrModule {
        _removeHook(hook, isValidation);
    }

    /// @inheritdoc IHookManager
    function setHookData(
        bytes32 key,
        bytes calldata data
    ) external override onlyHook {
        if (key == CONTEXT_KEY) {
            revert Errors.INVALID_KEY();
        }

        _hookDataStore()[msg.sender][key] = data;
    }

    /// @inheritdoc IHookManager
    function getHookData(
        address hook,
        bytes32 key
    ) external view override returns (bytes memory) {
        return _hookDataStore()[hook][key];
    }

    /// @inheritdoc IHookManager
    function isHook(address addr) external view override returns (bool) {
        return _isHook(addr);
    }

    /// @inheritdoc IHookManager
    function listHooks(
        bool isValidation
    ) external view override returns (address[] memory hookList) {
        if (isValidation) {
            hookList = _validationHooksLinkedList().list();
        } else {
            hookList = _executionHooksLinkedList().list();
        }
    }

    // Runs the validation hooks that are enabled by the account and returns true if none reverts
    function runValidationHooks(
        bytes32 signedHash,
        Transaction calldata transaction,
        bytes[] memory hookData
    ) internal returns (bool) {
        mapping(address => address)
            storage validationHooks = _validationHooksLinkedList();

        address cursor = validationHooks[AddressLinkedList.SENTINEL_ADDRESS];
        uint256 idx = 0;
        // Iterate through hooks
        while (cursor > AddressLinkedList.SENTINEL_ADDRESS) {
            // Call it with corresponding hookData
            bool success = _call(
                cursor,
                abi.encodeWithSelector(
                    IValidationHook.validationHook.selector,
                    signedHash,
                    transaction,
                    hookData[idx++]
                )
            );

            if (!success) {
                return false;
            }

            cursor = validationHooks[cursor];
        }

        // Ensure that hookData is not tampered with
        if (hookData.length != idx) return false;

        return true;
    }

    // Runs the execution hooks that are enabled by the account before and after _executeTransaction
    modifier runExecutionHooks(Transaction calldata transaction) {
        mapping(address => address)
            storage executionHooks = _executionHooksLinkedList();

        address cursor = executionHooks[AddressLinkedList.SENTINEL_ADDRESS];
        // Iterate through hooks
        while (cursor > AddressLinkedList.SENTINEL_ADDRESS) {
            // Call the preExecutionHook function with transaction struct
            bytes memory context = IExecutionHook(cursor).preExecutionHook(
                transaction
            );
            // Store returned data as context
            _setContext(cursor, context);

            cursor = executionHooks[cursor];
        }

        _;

        cursor = executionHooks[AddressLinkedList.SENTINEL_ADDRESS];
        // Iterate through hooks
        while (cursor > AddressLinkedList.SENTINEL_ADDRESS) {
            bytes memory context = _getContext(cursor);
            if (context.length > 0) {
                // Call the postExecutionHook function with stored context
                IExecutionHook(cursor).postExecutionHook(context);
                // Delete context
                _deleteContext(cursor);
            }

            cursor = executionHooks[cursor];
        }
    }

    function _addHook(bytes calldata hookAndData, bool isValidation) internal {
        if (hookAndData.length < 20) {
            revert Errors.EMPTY_HOOK_ADDRESS();
        }

        address hookAddress = address(bytes20(hookAndData[0:20]));

        if (!_supportsHook(hookAddress, isValidation)) {
            revert Errors.HOOK_ERC165_FAIL();
        }

        bytes calldata initData = hookAndData[20:];

        if (isValidation) {
            _validationHooksLinkedList().add(hookAddress);
        } else {
            _executionHooksLinkedList().add(hookAddress);
        }

        IInitable(hookAddress).init(initData);

        emit AddHook(hookAddress);
    }

    function _removeHook(address hook, bool isValidation) internal {
        if (isValidation) {
            _validationHooksLinkedList().remove(hook);
        } else {
            _executionHooksLinkedList().remove(hook);
        }

        (bool success, ) = hook.excessivelySafeCall(
            gasleft(),
            0,
            abi.encodeWithSelector(IInitable.disable.selector)
        );
        (success); // silence unused local variable warning

        emit RemoveHook(hook);
    }

    function _isHook(address addr) internal view override returns (bool) {
        return
            _validationHooksLinkedList().exists(addr) ||
            _executionHooksLinkedList().exists(addr);
    }

    function _setContext(address hook, bytes memory context) private {
        _hookDataStore()[hook][CONTEXT_KEY] = context;
    }

    function _deleteContext(address hook) private {
        delete _hookDataStore()[hook][CONTEXT_KEY];
    }

    function _getContext(
        address hook
    ) private view returns (bytes memory context) {
        context = _hookDataStore()[hook][CONTEXT_KEY];
    }

    function _call(
        address target,
        bytes memory data
    ) private returns (bool success) {
        assembly ("memory-safe") {
            success := call(
                gas(),
                target,
                0,
                add(data, 0x20),
                mload(data),
                0,
                0
            )
        }
    }

    function _validationHooksLinkedList()
        private
        view
        returns (mapping(address => address) storage validationHooks)
    {
        validationHooks = ClaveStorage.layout().validationHooks;
    }

    function _executionHooksLinkedList()
        private
        view
        returns (mapping(address => address) storage executionHooks)
    {
        executionHooks = ClaveStorage.layout().executionHooks;
    }

    function _hookDataStore()
        private
        view
        returns (
            mapping(address => mapping(bytes32 => bytes)) storage hookDataStore
        )
    {
        hookDataStore = ClaveStorage.layout().hookDataStore;
    }

    function _supportsHook(
        address hook,
        bool isValidation
    ) internal view returns (bool) {
        return
            isValidation
                ? hook.supportsInterface(type(IValidationHook).interfaceId)
                : hook.supportsInterface(type(IExecutionHook).interfaceId);
    }
}
