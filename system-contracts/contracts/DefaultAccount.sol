// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IAccount, ACCOUNT_VALIDATION_SUCCESS_MAGIC} from "./interfaces/IAccount.sol";
import {TransactionHelper, Transaction} from "./libraries/TransactionHelper.sol";
import {SystemContractsCaller} from "./libraries/SystemContractsCaller.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {BOOTLOADER_FORMAL_ADDRESS, NONCE_HOLDER_SYSTEM_CONTRACT, DEPLOYER_SYSTEM_CONTRACT, INonceHolder, BASE_TOKEN_SYSTEM_CONTRACT} from "./Constants.sol";
import {Utils} from "./libraries/Utils.sol";
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import {HookManager} from './managers/HookManager.sol';
import {ModuleManager} from './managers/ModuleManager.sol';
import {UpgradeManager} from './managers/UpgradeManager.sol';

import {TokenCallbackHandler, IERC165} from './helpers/TokenCallbackHandler.sol';
import {ERC1271Handler} from './handlers/ERC1271Handler.sol';
import {IClaveAccount} from './interfaces/IClave.sol';
import {Call} from './batch/BatchCaller.sol';
import {Errors} from './libraries/Errors.sol';
import {SignatureDecoder} from './libraries/SignatureDecoder.sol';

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The default implementation of account.
 * @dev The bytecode of the contract is set by default for all addresses for which no other bytecodes are deployed.
 * @notice If the caller is not a bootloader always returns empty data on call, just like EOA does.
 * @notice If it is delegate called always returns empty data, just like EOA does.
 */
contract DefaultAccount is
    Initializable,
    UpgradeManager,
    HookManager,
    ModuleManager,
    ERC1271Handler,
    TokenCallbackHandler,
    IClaveAccount
{
    // Helper library for the Transaction struct
    using TransactionHelper for Transaction;
    // Batch transaction helper contract
    address private _BATCH_CALLER = address(0xbeef);

    // /**
    //  * @notice Constructor for the account implementation
    //  * @param batchCaller address - Batch transaction helper contract
    //  */
    // constructor(address batchCaller) {
    //     _BATCH_CALLER = batchCaller;
    //     _disableInitializers();
    // }

    // /**
    //  * @notice Initializer function for the account contract
    //  * @param initialR1Owner bytes calldata - The initial r1 owner of the account
    //  * @param initialR1Validator address    - The initial r1 validator of the account
    //  * @param modules bytes[] calldata      - The list of modules to enable for the account
    //  * @param initCall Call calldata         - The initial call to be executed after the account is created
    //  */
    // function initialize(
    //     bytes calldata initialR1Owner,
    //     address initialR1Validator,
    //     bytes[] calldata modules,
    //     Call calldata initCall
    // ) external initializer {
    //     _r1AddOwner(initialR1Owner);
    //     _r1AddValidator(initialR1Validator);

    //     for (uint256 i = 0; i < modules.length; ) {
    //         _addModule(modules[i]);
    //         unchecked {
    //             i++;
    //         }
    //     }

    //     if (initCall.target != address(0)) {
    //         uint128 value = Utils.safeCastToU128(initCall.value);
    //         _executeCall(initCall.target, value, initCall.callData, initCall.allowFailure);
    //     }
    // }

    // Receive function to allow ETHs
    receive() external payable {}

    /**
     * @notice Called by the bootloader to validate that an account agrees to process the transaction
     * (and potentially pay for it).
     * @dev The developer should strive to preserve as many steps as possible both for valid
     * and invalid transactions as this very method is also used during the gas fee estimation
     * (without some of the necessary data, e.g. signature).
     * @param - bytes32                        - Not used
     * @param suggestedSignedHash bytes32      - The suggested hash of the transaction that is signed by the signer
     * @param transaction Transaction calldata - The transaction itself
     * @return magic bytes4 - The magic value that should be equal to the signature of this function
     * if the user agrees to proceed with the transaction.
     */
    function validateTransaction(
        bytes32,
        bytes32 suggestedSignedHash,
        Transaction calldata transaction
    ) external payable onlyBootloader returns (bytes4 magic) {
        _incrementNonce(transaction.nonce);

        // The fact there is enough balance for the account
        // should be checked explicitly to prevent user paying for fee for a
        // transaction that wouldn't be included on Ethereum.
        if (transaction.totalRequiredBalance() > address(this).balance) {
            revert Errors.INSUFFICIENT_FUNDS();
        }

        // While the suggested signed hash is usually provided, it is generally
        // not recommended to rely on it to be present, since in the future
        // there may be tx types with no suggested signed hash.
        bytes32 signedHash = suggestedSignedHash == bytes32(0)
            ? transaction.encodeHash()
            : suggestedSignedHash;

        magic = _validateTransaction(signedHash, transaction);
    }

    /**
     * @notice Called by the bootloader to make the account execute the transaction.
     * @dev The transaction is considered successful if this function does not revert
     * @param - bytes32                        - Not used
     * @param - bytes32                        - Not used
     * @param transaction Transaction calldata - The transaction itself
     */
    function executeTransaction(
        bytes32,
        bytes32,
        Transaction calldata transaction
    ) external override payable onlyBootloader {
        _executeTransaction(transaction);
    }

    /**
     * @notice This function allows an EOA to start a transaction for the account.
     * @dev There is no point in providing possible signed hash in the `executeTransactionFromOutside` method,
     * since it typically should not be trusted.
     * @param transaction Transaction calldata - The transaction itself
     */
    function executeTransactionFromOutside(
        Transaction calldata transaction
    ) external override payable {
        // Check if msg.sender is authorized
        if (!_k1IsOwner(msg.sender)) {
            revert Errors.UNAUTHORIZED_OUTSIDE_TRANSACTION();
        }

        // Extract hook data from transaction.signature
        bytes[] memory hookData = SignatureDecoder.decodeSignatureOnlyHookData(
            transaction.signature
        );

        // Get the hash of the transaction
        bytes32 signedHash = transaction.encodeHash();

        // Run the validation hooks
        if (!runValidationHooks(signedHash, transaction, hookData)) {
            revert Errors.VALIDATION_HOOK_FAILED();
        }

        _executeTransaction(transaction);
    }

    /**
     * @notice This function allows the account to pay for its own gas and used when there is no paymaster
     * @param - bytes32                        - not used
     * @param - bytes32                        - not used
     * @param transaction Transaction calldata - Transaction to pay for
     * @dev "This method must send at least `tx.gasprice * tx.gasLimit` ETH to the bootloader address."
     */
    function payForTransaction(
        bytes32,
        bytes32,
        Transaction calldata transaction
    ) external payable onlyBootloader {
        bool success = transaction.payToTheBootloader();

        if (!success) {
            revert Errors.FEE_PAYMENT_FAILED();
        }

        emit FeePaid();
    }

    /**
     * @notice This function is called by the system if the transaction has a paymaster
        and prepares the interaction with the paymaster
     * @param - bytes32               - not used 
     * @param - bytes32               - not used 
     * @param transaction Transaction - The transaction itself
     */
    function prepareForPaymaster(
        bytes32,
        bytes32,
        Transaction calldata transaction
    ) external payable onlyBootloader {
        transaction.processPaymasterInput();
    }

    /// @dev type(IClave).interfaceId indicates Clave accounts
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(IERC165, TokenCallbackHandler) returns (bool) {
        return
            interfaceId == type(IClaveAccount).interfaceId || super.supportsInterface(interfaceId);
    }

    function _validateTransaction(
        bytes32 signedHash,
        Transaction calldata transaction
    ) internal returns (bytes4 magicValue) {
        magicValue = ACCOUNT_VALIDATION_SUCCESS_MAGIC;
        if (transaction.signature.length == 65) {
            // extract ECDSA signature
            uint8 v;
            bytes32 r;
            bytes32 s;
            // Signature loading code
            // we jump 32 (0x20) as the first slot of bytes contains the length
            // we jump 65 (0x41) per signature
            // for v we load 32 bytes ending with v (the first 31 come from s) then apply a mask
            bytes memory signature = transaction.signature;
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := and(mload(add(signature, 0x41)), 0xff)
            }

            if (v != 27 && v != 28) {
                magicValue = bytes4(0);
            }

            // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
            // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
            // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
            // signatures from current libraries generate a unique signature with an s-value in the lower half order.
            //
            // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
            // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
            // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
            // these malleable signatures as well.
            if (
                uint256(s) >
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
            ) {
                magicValue = bytes4(0);
            }

            address recoveredAddress = ecrecover(signedHash, v, r, s);

            // Note, that we should abstain from using the require here in order to allow for fee estimation to work
            if (recoveredAddress != address(this) && recoveredAddress != address(0)) {
                magicValue = bytes4(0);
            }
        } else {
            // Extract the signature, validator address and hook data from the transaction.signature
            (bytes memory signature, address validator, bytes[] memory hookData) = SignatureDecoder
                .decodeSignature(transaction.signature);

            // Run validation hooks
            bool hookSuccess = runValidationHooks(signedHash, transaction, hookData);

            if (!hookSuccess) {
                magicValue = bytes4(0);
            }

            bool valid = _handleValidation(validator, signedHash, signature);

            magicValue = valid ? ACCOUNT_VALIDATION_SUCCESS_MAGIC : bytes4(0);
        }
    }

    function _executeTransaction(
        Transaction calldata transaction
    ) internal runExecutionHooks(transaction) {
        address to = _safeCastToAddress(transaction.to);
        uint128 value = Utils.safeCastToU128(transaction.value);
        bytes calldata data = transaction.data;

        _executeCall(to, value, data, false);
    }

    function _executeCall(
        address to,
        uint128 value,
        bytes calldata data,
        bool allowFailure
    ) internal {
        uint32 gas = Utils.safeCastToU32(gasleft());

        if (to == address(DEPLOYER_SYSTEM_CONTRACT)) {
            // Note, that the deployer contract can only be called
            // with a "systemCall" flag.
            (bool success, bytes memory returnData) = SystemContractsCaller
                .systemCallWithReturndata(gas, to, value, data);
            if (!success && !allowFailure) {
                assembly {
                    let size := mload(returnData)
                    revert(add(returnData, 0x20), size)
                }
            }
        } else if (to == _BATCH_CALLER) {
            bool success = EfficientCall.rawDelegateCall(gas, to, data);
            if (!success && !allowFailure) {
                EfficientCall.propagateRevert();
            }
        } else {
            bool success = EfficientCall.rawCall(gas, to, value, data, false);
            if (!success && !allowFailure) {
                EfficientCall.propagateRevert();
            }
        }
    }

    function _incrementNonce(uint256 nonce) internal {
        SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            address(NONCE_HOLDER_SYSTEM_CONTRACT),
            0,
            abi.encodeCall(INonceHolder.incrementMinNonceIfEquals, (nonce))
        );
    }

    function _safeCastToAddress(uint256 value) internal pure returns (address) {
        if (value > type(uint160).max) revert();
        return address(uint160(value));
    }
}
