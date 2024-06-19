// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

library Errors {
    /*//////////////////////////////////////////////////////////////
                               CLAVE
    //////////////////////////////////////////////////////////////*/

    error INSUFFICIENT_FUNDS();
    error FEE_PAYMENT_FAILED();
    error UNAUTHORIZED_OUTSIDE_TRANSACTION();
    error VALIDATION_HOOK_FAILED();

    /*//////////////////////////////////////////////////////////////
                               LINKED LIST
    //////////////////////////////////////////////////////////////*/

    error INVALID_PREV();
    // Bytes
    error INVALID_BYTES();
    error BYTES_ALREADY_EXISTS();
    error BYTES_NOT_EXISTS();
    // Address
    error INVALID_ADDRESS();
    error ADDRESS_ALREADY_EXISTS();
    error ADDRESS_NOT_EXISTS();

    /*//////////////////////////////////////////////////////////////
                              OWNER MANAGER
    //////////////////////////////////////////////////////////////*/

    error EMPTY_R1_OWNERS();
    error INVALID_PUBKEY_LENGTH();

    /*//////////////////////////////////////////////////////////////
                             VALIDATOR MANAGER
    //////////////////////////////////////////////////////////////*/

    error EMPTY_R1_VALIDATORS();
    error VALIDATOR_ERC165_FAIL();

    /*//////////////////////////////////////////////////////////////
                              UPGRADE MANAGER
    //////////////////////////////////////////////////////////////*/

    error SAME_IMPLEMENTATION();

    /*//////////////////////////////////////////////////////////////
                              HOOK MANAGER
    //////////////////////////////////////////////////////////////*/

    error EMPTY_HOOK_ADDRESS();
    error HOOK_ERC165_FAIL();
    error INVALID_KEY();

    /*//////////////////////////////////////////////////////////////
                             MODULE MANAGER
    //////////////////////////////////////////////////////////////*/

    error EMPTY_MODULE_ADDRESS();
    error RECUSIVE_MODULE_CALL();
    error MODULE_ERC165_FAIL();

    /*//////////////////////////////////////////////////////////////
                              AUTH
    //////////////////////////////////////////////////////////////*/

    error NOT_FROM_BOOTLOADER();
    error NOT_FROM_MODULE();
    error NOT_FROM_HOOK();
    error NOT_FROM_SELF();
    error NOT_FROM_SELF_OR_MODULE();

    /*//////////////////////////////////////////////////////////////
                            R1 VALIDATOR
    //////////////////////////////////////////////////////////////*/

    error INVALID_SIGNATURE();

    /*//////////////////////////////////////////////////////////////
                          SOCIAL RECOVERY
    //////////////////////////////////////////////////////////////*/

    error INVALID_RECOVERY_CONFIG();
    error INVALID_RECOVERY_NONCE();
    error INVALID_GUARDIAN();
    error INVALID_GUARDIAN_SIGNATURE();
    error ZERO_ADDRESS_GUARDIAN();
    error GUARDIANS_MUST_BE_SORTED();
    error RECOVERY_TIMELOCK();
    error RECOVERY_NOT_STARTED();
    error RECOVERY_NOT_INITED();
    error RECOVERY_IN_PROGRESS();
    error INSUFFICIENT_GUARDIANS();
    error ALREADY_INITED();

    /*//////////////////////////////////////////////////////////////
                            FACTORY
    //////////////////////////////////////////////////////////////*/

    error DEPLOYMENT_FAILED();
    error INITIALIZATION_FAILED();

    /*//////////////////////////////////////////////////////////////
                            PAYMASTER
    //////////////////////////////////////////////////////////////*/

    error UNSUPPORTED_FLOW();
    error UNAUTHORIZED_WITHDRAW();
    error INVALID_TOKEN();
    error SHORT_PAYMASTER_INPUT();
    error UNSUPPORTED_TOKEN();
    error LESS_ALLOWANCE_FOR_PAYMASTER();
    error FAILED_FEE_TRANSFER();
    error INVALID_MARKUP();
    error USER_LIMIT_REACHED();
    error INVALID_USER_LIMIT();
    error NOT_CLAVE_ACCOUNT();
    error EXCEEDS_MAX_SPONSORED_ETH();

    /*//////////////////////////////////////////////////////////////
                             REGISTRY
    //////////////////////////////////////////////////////////////*/

    error NOT_FROM_FACTORY();
    error NOT_FROM_DEPLOYER();

    /*//////////////////////////////////////////////////////////////
                            BatchCaller
    //////////////////////////////////////////////////////////////*/

    error ONLY_DELEGATECALL();
    error CALL_FAILED();

    /*//////////////////////////////////////////////////////////////
                            INITABLE
    //////////////////////////////////////////////////////////////*/

    error MODULE_NOT_ADDED_CORRECTLY();
    error MODULE_NOT_REMOVED_CORRECTLY();
}
