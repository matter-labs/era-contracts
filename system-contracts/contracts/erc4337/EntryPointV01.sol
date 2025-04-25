// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IEntryPoint, PackedUserOperation} from "../interfaces/IEntryPoint.sol";
import {IBootloaderUtilities} from "../interfaces/IBootloaderUtilities.sol";
import {IAccount} from "../interfaces/IAccount.sol";
import {IAccountCodeStorage} from "../interfaces/IAccountCodeStorage.sol";
import {INonceHolder} from "../interfaces/INonceHolder.sol";
import {IContractDeployer} from "../interfaces/IContractDeployer.sol";
import {ISystemContext} from "../interfaces/ISystemContext.sol";
import {ContractDeployer} from "../ContractDeployer.sol";
import {Transaction, TransactionHelper, EIP_712_TX_TYPE, LEGACY_TX_TYPE, EIP_2930_TX_TYPE, EIP_1559_TX_TYPE} from "../libraries/TransactionHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS, SYSTEM_CONTEXT_CONTRACT, NONCE_HOLDER_SYSTEM_CONTRACT, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT, DEPLOYER_SYSTEM_CONTRACT} from "../Constants.sol";
import {SystemContractBase} from "../abstract/SystemContractBase.sol";
import {SystemContext} from "../SystemContext.sol";
import {RLPEncoder} from "../libraries/RLPEncoder.sol";
import {EfficientCall} from "../libraries/EfficientCall.sol";
import {UnsupportedTxType, InvalidSig, SigField, HashMismatch} from "../SystemContractErrors.sol";

import {SystemContractsCaller, CalldataForwardingMode} from "../libraries/SystemContractsCaller.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice An EIP4337 EntryPoint contract implementation
 * built on top of the native ZKsync Account Abstraction.
 */
contract EntryPointV01 is IEntryPoint, SystemContractBase {
    using TransactionHelper for *;

    function handleUserOps(PackedUserOperation[] calldata _ops) external {
        for (uint i = 0; i < _ops.length; i++) {
            PackedUserOperation memory op = _ops[i];
            Transaction memory tx = abi.decode(op.callData, (Transaction));

            // Alignment checks.
            // These are important in case data will be indexed: we want to make sure that
            // "wrapped" fields are aligned with the original ones.
            require(op.sender == address(uint160(tx.from)), "Sender mismatch");
            require(op.nonce == tx.nonce, "Nonce mismatch");
            require(op.initCode.length == 0, "Init code not supported");
            require(uint256(op.accountGasLimits) >> 128 == 0, "Verification gas limit must be 0");
            require(uint256(op.accountGasLimits) == tx.gasLimit, "Call gas limit mismatch");
            require(uint256(op.gasFees) >> 128 == tx.maxPriorityFeePerGas, "Max priority fee per gas mismatch");
            require(uint256(uint128(uint256(op.gasFees))) == tx.maxFeePerGas, "Max fee per gas mismatch");

            require(op.preVerificationGas == 0, "Pre-verification gas limit must be 0");
            if (op.paymasterAndData.length > 0) {
                // Decode address and params
                (address paymaster, bytes memory paymasterInput) = abi.decode(op.paymasterAndData, (address, bytes)); // TODO: is that correct?
                require(paymaster == address(uint160(tx.paymaster)), "Paymaster mismatch");
                require(keccak256(paymasterInput) == keccak256(tx.paymasterInput), "Paymaster input mismatch");
            }
            require(keccak256(op.signature) == keccak256(tx.signature), "Signature mismatch");

            _handleTransaction(tx);
        }
    }

    function _handleTransaction(Transaction memory tx) private {
        bytes32 txHash = bytes32(0); // TODO: Should we calculate it for user?
        bytes32 suggestedTxHash = bytes32(0); // TODO: Should we calculate it for user?

        _validateTransaction(txHash, suggestedTxHash, tx);
        _payForTransaction(txHash, suggestedTxHash, tx);

        // TODO: here and below, we probably should not revert after the transaction payment;
        // instead we should go to the next transaction.
        _executeTransaction(txHash, suggestedTxHash, tx);

        // refund?
    }

    function _validateTransaction(bytes32 _txHash, bytes32 _suggestedSignedHash, Transaction memory _tx) private {
        address from = address(uint160(_tx.from));
        // check account type via ContractDeployer
        IContractDeployer.AccountAbstractionVersion version = ContractDeployer(address(DEPLOYER_SYSTEM_CONTRACT))
            .extendedAccountVersion(from);
        require(version == IContractDeployer.AccountAbstractionVersion.Version1, "Unsupported account version");

        // check that nonce is available yet
        NONCE_HOLDER_SYSTEM_CONTRACT.validateNonceUsage(from, _tx.nonce, false);

        // validate transaction
        bytes memory returnData = this._performMimicCall(
            uint32(gasleft()), // Should be value from the transaction?
            BOOTLOADER_FORMAL_ADDRESS,
            from,
            abi.encodeCall(IAccount(from).validateTransaction, (_txHash, _suggestedSignedHash, _tx))
        );
        bytes4 magic = abi.decode(returnData, (bytes4));
        // We have to revert, since user didn't pay for the transaction just yet.
        require(magic == IAccount.validateTransaction.selector, "Verification failed");

        // check that nonce is not available anymore
        NONCE_HOLDER_SYSTEM_CONTRACT.validateNonceUsage(from, _tx.nonce, true);
    }

    function _payForTransaction(bytes32 _txHash, bytes32 _suggestedSignedHash, Transaction memory _tx) private {
        address from = address(uint160(_tx.from));
        if (_tx.paymaster == 0) {
            // No paymaster, pay directly
            uint256 bootloaderBalanceBefore = address(BOOTLOADER_FORMAL_ADDRESS).balance;
            this._performMimicCall(
                uint32(gasleft()), // Should be value from the transaction?
                BOOTLOADER_FORMAL_ADDRESS,
                from,
                abi.encodeCall(IAccount(from).payForTransaction, (_txHash, _suggestedSignedHash, _tx))
            );
            uint256 bootloaderBalanceAfter = address(BOOTLOADER_FORMAL_ADDRESS).balance;
            require(bootloaderBalanceAfter > bootloaderBalanceBefore, "Transaction payment failed");
            require(
                bootloaderBalanceAfter - bootloaderBalanceBefore >= _tx.gasLimit * _tx.maxFeePerGas,
                "Transaction payment amount mismatch"
            );
            // TODO: should we send back excessive funds like bootloader does?
        } else {
            // Pay through the paymaster
            revert("Not implemented yet");
        }
    }

    function _executeTransaction(bytes32 _txHash, bytes32 _suggestedSignedHash, Transaction memory _tx) private {
        address from = address(uint160(_tx.from));
        require(_tx.factoryDeps.length == 0, "Factory deps cannot be sent through the EntryPoint contract");

        // set tx.origin
        bool isEOA = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(from) == 0;
        address txOrigin = address(0);
        if (isEOA) {
            txOrigin = from;
        }
        this._performMimicCall(
            uint32(gasleft()), // Should be value from the transaction?
            BOOTLOADER_FORMAL_ADDRESS,
            address(SYSTEM_CONTEXT_CONTRACT),
            abi.encodeCall(SystemContext.setTxOrigin, (txOrigin))
        );

        // execute transaction
        // TODO: do we need to do it through MsgValueSimulator?
        this._performMimicCall(
            uint32(gasleft()), // Should be value from the transaction?
            BOOTLOADER_FORMAL_ADDRESS,
            from,
            abi.encodeCall(IAccount(from).executeTransaction, (_txHash, _suggestedSignedHash, _tx))
        );
    }

    // Needed to convert `memory` to `calldata`
    function _performMimicCall(
        uint32 _gas,
        address _whoToMimic,
        address _to,
        bytes calldata _data
    ) external onlyCallFrom(address(this)) returns (bytes memory returnData) {
        return
            EfficientCall.mimicCall(
                _gas,
                _to,
                _data,
                _whoToMimic,
                false,
                true // isSystem TODO <- is it required?
            );
    }
}
