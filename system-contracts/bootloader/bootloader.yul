object "Bootloader" {
    code {
    }
    object "Bootloader_deployed" {
        code {
            {{CODE_START_PLACEHOLDER}}

            ////////////////////////////////////////////////////////////////////////////
            //                      Function Declarations
            ////////////////////////////////////////////////////////////////////////////

            // While we definitely cannot control the pubdata price on L1,
            // we need to check the operator does not provide any absurd numbers there
            function MAX_ALLOWED_FAIR_PUBDATA_PRICE() -> ret {
                // 1M gwei
                ret := 1000000000000000
            }

            function MAX_ALLOWED_FAIR_L2_GAS_PRICE() -> ret {
                // 10k gwei
                ret := 10000000000000
            }

            /// @dev This method ensures that the prices provided by the operator
            /// are not absurdly high
            function validateOperatorProvidedPrices(fairL2GasPrice, pubdataPrice) {
                // The limit is the same for pubdata price and L1 gas price
                if gt(pubdataPrice, MAX_ALLOWED_FAIR_PUBDATA_PRICE()) {
                    assertionError("Fair pubdata price too high")
                }

                if gt(fairL2GasPrice, MAX_ALLOWED_FAIR_L2_GAS_PRICE()) {
                    assertionError("L2 fair gas price too high")
                }
            }

            /// @dev The overhead for a transaction slot in L2 gas.
            /// It is roughly equal to 80kk/MAX_TRANSACTIONS_IN_BATCH, i.e. how many gas would an L1->L2 transaction
            /// need to pay to compensate for the batch being closed.
            /// @dev It is expected of the operator to set the "fair L2 gas price" appropriately to ensure that it is
            /// compensated enough in case the batch might be prematurely sealed because of the transaction slots being filled up.
            function TX_SLOT_OVERHEAD_GAS() -> ret {
                ret := 10000
            }

            /// @dev The overhead for each byte of the bootloader memory that the encoding of the transaction.
            /// It is roughly equal to 80kk/BOOTLOADER_MEMORY_FOR_TXS, i.e. how many gas would an L1->L2 transaction
            /// need to pay to compensate for the batch being closed.
            /// @dev It is expected of the operator to set the "fair L2 gas price" appropriately to ensure that it is
            /// compensated enough in case the batch might be prematurely sealed because of the memory being filled up.
            function MEMORY_OVERHEAD_GAS() -> ret {
                ret := 10
            }

            /// @dev Returns the base fee and gas per pubdata based on the fair pubdata price and L2 gas price provided by the operator
            /// @param pubdataPrice The price of a single byte of pubdata in Wei
            /// @param fairL2GasPrice The price of an L2 gas in Wei
            /// @return baseFee and gasPerPubdata The base fee and the gas per pubdata to be used by L2 transactions in this batch.
            function getFeeParams(
                fairPubdataPrice,
                fairL2GasPrice,
            ) -> baseFee, gasPerPubdata {
                baseFee := max(
                    fairL2GasPrice,
                    ceilDiv(fairPubdataPrice, MAX_L2_GAS_PER_PUBDATA())
                )

                gasPerPubdata := gasPerPubdataFromBaseFee(baseFee, fairPubdataPrice)
            }

            /// @dev Calculates the gas per pubdata based on the pubdata price provided by the operator
            /// as well the the fixed baseFee.
            function gasPerPubdataFromBaseFee(baseFee, pubdataPrice) -> ret {
                ret := ceilDiv(pubdataPrice, baseFee)
            }

            /// @dev It should be always possible to submit a transaction
            /// that consumes such amount of public data.
            function GUARANTEED_PUBDATA_PER_TX() -> ret {
                ret := {{GUARANTEED_PUBDATA_BYTES}}
            }

            /// @dev The maximal allowed gasPerPubdata, we want it multiplied by the u32::MAX
            /// (i.e. the maximal possible value of the pubdata counter) to be a safe JS integer with a good enough margin.
            /// @dev For now, the 50000 value is used for backward compatibility with SDK, but in the future we will migrate to 2^20.
            function MAX_L2_GAS_PER_PUBDATA() -> ret {
                ret := 50000
            }

            /// @dev The overhead for the interaction with L1.
            /// It should cover proof verification as well as other minor
            /// overheads for committing/executing a transaction in a batch.
            function BATCH_OVERHEAD_L1_GAS() -> ret {
                ret := {{BATCH_OVERHEAD_L1_GAS}}
            }

            /// @dev The maximal number of gas available to the transaction
            function MAX_GAS_PER_TRANSACTION() -> ret {
                ret := {{MAX_GAS_PER_TRANSACTION}}
            }

            /// @dev The number of L1 gas needed to be spent for
            /// L1 byte. While a single pubdata byte costs `16` gas,
            /// we demand at least 17 to cover up for the costs of additional
            /// hashing of it, etc.
            function L1_GAS_PER_PUBDATA_BYTE() -> ret {
                ret := 17
            }

            /// @dev Whether the batch is allowed to accept transactions with
            /// gasPerPubdataByteLimit = 0. On mainnet, this is forbidden for safety reasons.
            function FORBID_ZERO_GAS_PER_PUBDATA() -> ret {
                ret := {{FORBID_ZERO_GAS_PER_PUBDATA}}
            }

            /// @dev The maximum number of transactions per L1 batch.
            function MAX_TRANSACTIONS_IN_BATCH() -> ret {
                ret := {{MAX_TRANSACTIONS_IN_BATCH}}
            }

            /// @dev The slot from which the scratch space starts.
            /// Scratch space is used for various temporary values
            function SCRATCH_SPACE_BEGIN_SLOT() -> ret {
                ret := 8
            }

            /// @dev The byte from which the scratch space starts.
            /// Scratch space is used for various temporary values
            function SCRATCH_SPACE_BEGIN_BYTE() -> ret {
                ret := mul(SCRATCH_SPACE_BEGIN_SLOT(), 32)
            }

            /// @dev The first 32 slots are reserved for event emitting for the
            /// debugging purposes
            function SCRATCH_SPACE_SLOTS() -> ret {
                ret := 32
            }

            /// @dev Slots reserved for saving the paymaster context
            /// @dev The paymasters are allowed to consume at most
            /// 32 slots (1024 bytes) for their context.
            /// The 33 slots are required since the first one stores the length of the calldata.
            function PAYMASTER_CONTEXT_SLOTS() -> ret {
                ret := 33
            }

            /// @dev Bytes reserved for saving the paymaster context
            function PAYMASTER_CONTEXT_BYTES() -> ret {
                ret := mul(PAYMASTER_CONTEXT_SLOTS(), 32)
            }

            /// @dev Slot from which the paymaster context starts
            function PAYMASTER_CONTEXT_BEGIN_SLOT() -> ret {
                ret := add(SCRATCH_SPACE_BEGIN_SLOT(), SCRATCH_SPACE_SLOTS())
            }

            /// @dev The byte from which the paymaster context starts
            function PAYMASTER_CONTEXT_BEGIN_BYTE() -> ret {
                ret := mul(PAYMASTER_CONTEXT_BEGIN_SLOT(), 32)
            }

            /// @dev Each tx must have at least this amount of unused bytes before them to be able to
            /// encode the postOp operation correctly.
            function MAX_POSTOP_SLOTS() -> ret {
                // Before the actual transaction encoding, the postOp contains 6 slots:
                // 1. Context offset
                // 2. Transaction offset
                // 3. Transaction hash
                // 4. Suggested signed hash
                // 5. Transaction result
                // 6. Maximum refunded gas
                // And one more slot for the padding selector
                ret := add(PAYMASTER_CONTEXT_SLOTS(), 7)
            }

            /// @dev Slots needed to store the canonical and signed hash for the current L2 transaction.
            function CURRENT_L2_TX_HASHES_RESERVED_SLOTS() -> ret {
                ret := 2
            }

            /// @dev Slot from which storing of the current canonical and signed hashes begins
            function CURRENT_L2_TX_HASHES_BEGIN_SLOT() -> ret {
                ret := add(PAYMASTER_CONTEXT_BEGIN_SLOT(), PAYMASTER_CONTEXT_SLOTS())
            }

            /// @dev The byte from which storing of the current canonical and signed hashes begins
            function CURRENT_L2_TX_HASHES_BEGIN_BYTE() -> ret {
                ret := mul(CURRENT_L2_TX_HASHES_BEGIN_SLOT(), 32)
            }

            /// @dev The maximum number of new factory deps that are allowed in a transaction
            function MAX_NEW_FACTORY_DEPS() -> ret {
                ret := 32
            }

            /// @dev Besides the factory deps themselves, we also need another 4 slots for:
            /// selector, marker of whether the user should pay for the pubdata,
            /// the offset for the encoding of the array as well as the length of the array.
            function NEW_FACTORY_DEPS_RESERVED_SLOTS() -> ret {
                ret := add(MAX_NEW_FACTORY_DEPS(), 4)
            }

            /// @dev The slot starting from which the factory dependencies are stored
            function NEW_FACTORY_DEPS_BEGIN_SLOT() -> ret {
                ret := add(CURRENT_L2_TX_HASHES_BEGIN_SLOT(), CURRENT_L2_TX_HASHES_RESERVED_SLOTS())
            }

            /// @dev The byte starting from which the factory dependencies are stored
            function NEW_FACTORY_DEPS_BEGIN_BYTE() -> ret {
                ret := mul(NEW_FACTORY_DEPS_BEGIN_SLOT(), 32)
            }

            /// @dev The slot starting from which the refunds provided by the operator are stored
            function TX_OPERATOR_REFUND_BEGIN_SLOT() -> ret {
                ret := add(NEW_FACTORY_DEPS_BEGIN_SLOT(), NEW_FACTORY_DEPS_RESERVED_SLOTS())
            }

            /// @dev The byte starting from which the refunds provided by the operator are stored
            function TX_OPERATOR_REFUND_BEGIN_BYTE() -> ret {
                ret := mul(TX_OPERATOR_REFUND_BEGIN_SLOT(), 32)
            }

            /// @dev The number of slots dedicated for the refunds for the transactions.
            /// It is equal to the number of transactions in the batch.
            function TX_OPERATOR_REFUNDS_SLOTS() -> ret {
                ret := MAX_TRANSACTIONS_IN_BATCH()
            }

            /// @dev The slot starting from which the overheads proposed by the operator will be stored
            function TX_SUGGESTED_OVERHEAD_BEGIN_SLOT() -> ret {
                ret := add(TX_OPERATOR_REFUND_BEGIN_SLOT(), TX_OPERATOR_REFUNDS_SLOTS())
            }

            /// @dev The byte starting from which the overheads proposed by the operator will be stored
            function TX_SUGGESTED_OVERHEAD_BEGIN_BYTE() -> ret {
                ret := mul(TX_SUGGESTED_OVERHEAD_BEGIN_SLOT(), 32)
            }

            /// @dev The number of slots dedicated for the overheads for the transactions.
            /// It is equal to the number of transactions in the batch.
            function TX_SUGGESTED_OVERHEAD_SLOTS() -> ret {
                ret := MAX_TRANSACTIONS_IN_BATCH()
            }

            /// @dev The slot starting from which the maximum number of gas that the operator "trusts"
            /// the transaction to use for its execution is stored. Sometimes, the operator may know that
            /// a certain transaction can be allowed more gas that what the protocol-level worst-case allows.
            function TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_SLOT() -> ret {
                ret := add(TX_SUGGESTED_OVERHEAD_BEGIN_SLOT(), TX_SUGGESTED_OVERHEAD_SLOTS())
            }

            /// @dev byte starting from which the maximum number of gas that the operator "trusts"
            /// the transaction to use for its execution is stored.
            function TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_BYTE() -> ret {
                ret := mul(TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_SLOT(), 32)
            }

            /// @dev The number of slots dedicated for the trusted gas limits for the transactions.
            /// It is equal to the number of transactions in the batch.
            function TX_OPERATOR_TRUSTED_GAS_LIMIT_SLOTS() -> ret {
                ret := MAX_TRANSACTIONS_IN_BATCH()
            }

            /// @dev The slot starting from the L2 block information for transactions is stored.
            function TX_OPERATOR_L2_BLOCK_INFO_BEGIN_SLOT() -> ret {
                ret := add(TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_SLOT(), TX_OPERATOR_TRUSTED_GAS_LIMIT_SLOTS())
            }

            /// @dev The byte starting from which the L2 block information for transactions is stored.
            function TX_OPERATOR_L2_BLOCK_INFO_BEGIN_BYTE() -> ret {
                ret := mul(TX_OPERATOR_L2_BLOCK_INFO_BEGIN_SLOT(), 32)
            }

            /// @dev The size of each of the L2 block information. Each L2 block information contains four fields:
            /// - number of the block
            /// - timestamp of the block
            /// - hash of the previous block
            /// - the maximal number of virtual blocks to create
            function TX_OPERATOR_L2_BLOCK_INFO_SLOT_SIZE() -> ret {
                ret := 4
            }

            /// @dev The size of each of the L2 block information in bytes.
            function TX_OPERATOR_L2_BLOCK_INFO_SIZE_BYTES() -> ret {
                ret := mul(TX_OPERATOR_L2_BLOCK_INFO_SLOT_SIZE(), 32)
            }

            /// @dev The number of slots dedicated for the L2 block information for the transactions.
            /// Note, that an additional slot is required for the fictive L2 block at the end of the batch.
            /// For technical reasons inside the sequencer implementation,
            /// each batch ends with a fictive block with no transactions.
            function TX_OPERATOR_L2_BLOCK_INFO_SLOTS() -> ret {
                ret := mul(add(MAX_TRANSACTIONS_IN_BATCH(), 1), TX_OPERATOR_L2_BLOCK_INFO_SLOT_SIZE())
            }

            /// @dev The slot starting from which the compressed bytecodes are located in the bootloader's memory.
            /// Each compressed bytecode is provided in the following format:
            /// - 32 byte formatted bytecode hash
            /// - 32 byte of zero (it will be replaced within the code with left-padded selector of the `publishCompressedBytecode`).
            /// - ABI-encoding of the parameters of the `publishCompressedBytecode` method.
            ///
            /// At the slot `TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_SLOT()` the pointer to the currently processed compressed bytecode
            /// is stored, i.e. this pointer will be increased once the current bytecode which the pointer points to is published.
            /// At the start of the bootloader, the value stored at the `TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_SLOT` is equal to
            /// `TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_SLOT + 32`, where the hash of the first compressed bytecode to publish should be stored.
            function COMPRESSED_BYTECODES_BEGIN_SLOT() -> ret {
                ret := add(TX_OPERATOR_L2_BLOCK_INFO_BEGIN_SLOT(), TX_OPERATOR_L2_BLOCK_INFO_SLOTS())
            }

            /// @dev The byte starting from which the compressed bytecodes are located in the bootloader's memory.
            function COMPRESSED_BYTECODES_BEGIN_BYTE() -> ret {
                ret := mul(COMPRESSED_BYTECODES_BEGIN_SLOT(), 32)
            }

            /// @dev The number of slots dedicated to the compressed bytecodes.
            function COMPRESSED_BYTECODES_SLOTS() -> ret {
                ret := {{COMPRESSED_BYTECODES_SLOTS}}
            }

            /// @dev The slot right after the last slot of the compressed bytecodes memory area.
            function COMPRESSED_BYTECODES_END_SLOT() -> ret {
                ret := add(COMPRESSED_BYTECODES_BEGIN_SLOT(), COMPRESSED_BYTECODES_SLOTS())
            }

            /// @dev The first byte in memory right after the compressed bytecodes memory area.
            function COMPRESSED_BYTECODES_END_BYTE() -> ret {
                ret := mul(COMPRESSED_BYTECODES_END_SLOT(), 32)
            }

            /// @dev Slots needed to store priority txs L1 data (`chainedPriorityTxsHash` and `numberOfLayer1Txs`).
            function PRIORITY_TXS_L1_DATA_RESERVED_SLOTS() -> ret {
                ret := 2
            }

            /// @dev Slot from which storing of the priority txs L1 data begins.
            function PRIORITY_TXS_L1_DATA_BEGIN_SLOT() -> ret {
                ret := add(COMPRESSED_BYTECODES_BEGIN_SLOT(), COMPRESSED_BYTECODES_SLOTS())
            }

            /// @dev The byte from which storing of the priority txs L1 data begins.
            function PRIORITY_TXS_L1_DATA_BEGIN_BYTE() -> ret {
                ret := mul(PRIORITY_TXS_L1_DATA_BEGIN_SLOT(), 32)
            }

            /// @dev Slot from which storing of the L1 Messenger pubdata begins.
            function OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_BEGIN_SLOT() -> ret {
                ret := add(PRIORITY_TXS_L1_DATA_BEGIN_SLOT(), PRIORITY_TXS_L1_DATA_RESERVED_SLOTS())
            }

            /// @dev The byte storing of the L1 Messenger pubdata begins.
            function OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_BEGIN_BYTE() -> ret {
                ret := mul(OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_BEGIN_SLOT(), 32)
            }

            /// @dev Slots needed to store L1 Messenger pubdata.
            /// @dev Note that are many more these than the maximal pubdata in batch, since
            /// it needs to also accommodate uncompressed state diffs that are required for the state diff
            /// compression verification.
            function OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_SLOTS() -> ret {
                ret := {{OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_SLOTS}}
            }

            /// @dev The slot right after the last slot of the L1 Messenger pubdata memory area.
            function OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_END_SLOT() -> ret {
                ret := add(OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_BEGIN_SLOT(), OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_SLOTS())
            }

            /// @dev The slot from which the bootloader transactions' descriptions begin
            function TX_DESCRIPTION_BEGIN_SLOT() -> ret {
                ret := OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_END_SLOT()
            }

            /// @dev The byte from which the bootloader transactions' descriptions begin
            function TX_DESCRIPTION_BEGIN_BYTE() -> ret {
                ret := mul(TX_DESCRIPTION_BEGIN_SLOT(), 32)
            }

            // Each tx description has the following structure
            //
            // struct BootloaderTxDescription {
            //     uint256 txMeta;
            //     uint256 txDataOffset;
            // }
            //
            // `txMeta` contains flags to manipulate the transaction execution flow.
            // For playground batches:
            //      It can have the following information (0 byte is LSB and 31 byte is MSB):
            //      0 byte: `execute`, bool. Denotes whether transaction should be executed by the bootloader.
            //      31 byte: server-side tx execution mode
            // For proved batches:
            //      It can simply denotes whether to execute the transaction (0 to stop executing the batch, 1 to continue)
            //
            // Each such encoded struct consumes 2 words
            function TX_DESCRIPTION_SIZE() -> ret {
                ret := 64
            }

            /// @dev The byte right after the basic description of bootloader transactions
            function TXS_IN_BATCH_LAST_PTR() -> ret {
                ret := add(TX_DESCRIPTION_BEGIN_BYTE(), mul(MAX_TRANSACTIONS_IN_BATCH(), TX_DESCRIPTION_SIZE()))
            }

            /// @dev The memory page consists of 59000000 / 32 VM words.
            /// Each execution result is a single boolean, but
            /// for the sake of simplicity we will spend 32 bytes on each
            /// of those for now.
            function MAX_MEM_SIZE() -> ret {
                ret := 63800000
            }

            function L1_TX_INTRINSIC_L2_GAS() -> ret {
                ret := {{L1_TX_INTRINSIC_L2_GAS}}
            }

            function L1_TX_INTRINSIC_PUBDATA() -> ret {
                ret := {{L1_TX_INTRINSIC_PUBDATA}}
            }

            function L2_TX_INTRINSIC_GAS() -> ret {
                ret := {{L2_TX_INTRINSIC_GAS}}
            }

            function L2_TX_INTRINSIC_PUBDATA() -> ret {
                ret := {{L2_TX_INTRINSIC_PUBDATA}}
            }

            /// @dev The byte from which the pointers on the result of transactions are stored
            function RESULT_START_PTR() -> ret {
                ret := sub(MAX_MEM_SIZE(), mul(MAX_TRANSACTIONS_IN_BATCH(), 32))
            }

            /// @dev The pointer writing to which invokes the VM hooks
            function VM_HOOK_PTR() -> ret {
                ret := sub(RESULT_START_PTR(), 32)
            }

            /// @dev The maximum number the VM hooks may accept
            function VM_HOOK_PARAMS() -> ret {
                ret := 3
            }

            /// @dev The offset starting from which the parameters for VM hooks are located
            function VM_HOOK_PARAMS_OFFSET() -> ret {
                ret := sub(VM_HOOK_PTR(), mul(VM_HOOK_PARAMS(), 32))
            }

            function LAST_FREE_SLOT() -> ret {
                // The slot right before the vm hooks is the last slot that
                // can be used for transaction's descriptions
                ret := sub(VM_HOOK_PARAMS_OFFSET(), 32)
            }

            /// @dev The formal address of the bootloader
            function BOOTLOADER_FORMAL_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008001
            }

            function ACCOUNT_CODE_STORAGE_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008002
            }

            function NONCE_HOLDER_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008003
            }

            function KNOWN_CODES_CONTRACT_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008004
            }

            function CONTRACT_DEPLOYER_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008006
            }

            function FORCE_DEPLOYER() -> ret {
                ret := 0x0000000000000000000000000000000000008007
            }

            function L1_MESSENGER_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008008
            }

            function MSG_VALUE_SIMULATOR_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008009
            }

            function ETH_L2_TOKEN_ADDR() -> ret {
                ret := 0x000000000000000000000000000000000000800a
            }

            function SYSTEM_CONTEXT_ADDR() -> ret {
                ret := 0x000000000000000000000000000000000000800b
            }

            function BOOTLOADER_UTILITIES() -> ret {
                ret := 0x000000000000000000000000000000000000800c
            }

            function BYTECODE_COMPRESSOR_ADDR() -> ret {
                ret := 0x000000000000000000000000000000000000800e
            }

            function MAX_SYSTEM_CONTRACT_ADDR() -> ret {
                ret := 0x000000000000000000000000000000000000ffff
            }

            /// @dev The minimal allowed distance in bytes between the pointer to the compressed data
            /// and the end of the area dedicated for the compressed bytecodes.
            /// In fact, only distance of 192 should be sufficient: there it would be possible to insert
            /// the hash of the bytecode, the 32 bytes buffer for selector and 2 offsets of the calldata,
            /// but we keep it at 512 just in case.
            function MIN_ALLOWED_OFFSET_FOR_COMPRESSED_BYTES_POINTER() -> ret {
                ret := 512
            }

            /// @dev Whether the bootloader should enforce that accounts have returned the correct
            /// magic value for signature. This value is enforced to be "true" on the main proved batch, but
            /// we need the ability to ignore invalid signature results during fee estimation,
            /// where the signature for the transaction is usually not known beforehand.
            function SHOULD_ENSURE_CORRECT_RETURNED_MAGIC() -> ret {
                ret := {{ENSURE_RETURNED_MAGIC}}
            }

            /// @notice The type of the transaction used for system upgrades.
            function UPGRADE_TRANSACTION_TX_TYPE() -> ret {
                ret := 254
            }

            /// @notice The type of every non-upgrade transaction that comes from L1.
            function L1_TX_TYPE() -> ret {
                ret := 255
            }

            /// @dev The overhead in gas that will be used when checking whether the context has enough gas, i.e.
            /// when checking for X gas, the context should have at least X+CHECK_ENOUGH_GAS_OVERHEAD() gas.
            function CHECK_ENOUGH_GAS_OVERHEAD() -> ret {
                ret := 1000000
            }

            /// @dev Ceil division of integers
            function ceilDiv(x, y) -> ret {
                switch or(eq(x, 0), eq(y, 0))
                case 0 {
                    // (x + y - 1) / y can overflow on addition, so we distribute.
                    ret := add(div(sub(x, 1), y), 1)
                }
                default {
                    ret := 0
                }
            }

            /// @dev Calculates the length of a given number of bytes rounded up to the nearest multiple of 32.
            function lengthRoundedByWords(len) -> ret {
                let neededWords := div(add(len, 31), 32)
                ret := safeMul(neededWords, 32, "xv")
            }

            /// @dev Function responsible for processing the transaction
            /// @param txDataOffset The offset to the ABI-encoding of the structure
            /// @param resultPtr The pointer at which the result of the transaction's execution should be stored
            /// @param transactionIndex The index of the transaction in the batch
            /// @param isETHCall Whether the call is an ethCall.
            /// @param gasPerPubdata The number of L2 gas to charge users for each byte of pubdata
            /// On proved batch this value should always be zero
            function processTx(
                txDataOffset,
                resultPtr,
                transactionIndex,
                isETHCall,
                gasPerPubdata
            ) {
                // We set the L2 block info for this particular transaction
                setL2Block(transactionIndex)

                let innerTxDataOffset := add(txDataOffset, 32)

                // By default we assume that the transaction has failed.
                mstore(resultPtr, 0)

                let userProvidedPubdataPrice := getGasPerPubdataByteLimit(innerTxDataOffset)
                debugLog("userProvidedPubdataPrice:", userProvidedPubdataPrice)

                debugLog("gasPerPubdata:", gasPerPubdata)

                switch getTxType(innerTxDataOffset)
                    case 254 {
                        // This is an upgrade transaction.
                        // Protocol upgrade transactions are processed totally in the same manner as the normal L1->L2 transactions,
                        // the only difference are:
                        // - They must be the first one in the batch
                        // - They have a different type to prevent tx hash collisions and preserve the expectation that the
                        // L1->L2 transactions have priorityTxId inside them.
                        if transactionIndex {
                            assertionError("Protocol upgrade tx not first")
                        }

                        // This is to be called in the event that the L1 Transaction is a protocol upgrade txn.
                        // Since this is upgrade transactions, we are okay that the gasUsed by the transaction will
                        // not cover this additional hash computation
                        let canonicalL1TxHash := getCanonicalL1TxHash(txDataOffset)
                        sendToL1Native(true, protocolUpgradeTxHashKey(), canonicalL1TxHash)

                        processL1Tx(txDataOffset, resultPtr, transactionIndex, userProvidedPubdataPrice, false)
                    }
                    case 255 {
                        // This is an L1->L2 transaction.
                        processL1Tx(txDataOffset, resultPtr, transactionIndex, userProvidedPubdataPrice, true)
                    }
                    default {
                        // The user has not agreed to this pubdata price
                        if lt(userProvidedPubdataPrice, gasPerPubdata) {
                            revertWithReason(UNACCEPTABLE_GAS_PRICE_ERR_CODE(), 0)
                        }

                        <!-- @if BOOTLOADER_TYPE=='proved_batch' -->
                        processL2Tx(txDataOffset, resultPtr, transactionIndex, gasPerPubdata)
                        <!-- @endif -->

                        <!-- @if BOOTLOADER_TYPE=='playground_batch' -->
                        switch isETHCall
                            case 1 {
                                let gasLimitForTx, reservedGas := getGasLimitForTx(
                                    innerTxDataOffset, 
                                    transactionIndex, 
                                    gasPerPubdata,
                                    L2_TX_INTRINSIC_GAS(), 
                                    L2_TX_INTRINSIC_PUBDATA()
                                )

                                let nearCallAbi := getNearCallABI(gasLimitForTx)
                                checkEnoughGas(gasLimitForTx)

                                if iszero(gasLimitForTx) {
                                    // We disallow providing 0 gas limit for an eth call transaction.
                                    // Note, in case it is 0 `ZKSYNC_NEAR_CALL_ethCall` will get the entire
                                    // gas of the bootloader.
                                    revertWithReason(
                                        ETH_CALL_ERR_CODE(),
                                        0
                                    )
                                }

                                ZKSYNC_NEAR_CALL_ethCall(
                                    nearCallAbi,
                                    txDataOffset,
                                    resultPtr,
                                    reservedGas,
                                    gasPerPubdata
                                )
                            }
                            default {
                                processL2Tx(txDataOffset, resultPtr, transactionIndex, gasPerPubdata)
                            }
                        <!-- @endif -->
                    }
            }

            /// @notice Returns "raw" code hash of the address. "Raw" means that it returns exactly the value
            /// that is stored in the AccountCodeStorage system contract for that address, without applying any
            /// additional transformations, which the standard `extcodehash` does for EVM-compatibility
            /// @param addr The address of the account to get the code hash of.
            /// @param assertSuccess Whether to revert the bootloader if the call to the AccountCodeStorage fails. If `false`, only
            /// `nearCallPanic` will be issued in case of failure, which is helpful for cases, when the reason for failure is user providing not
            /// enough gas.
            function getRawCodeHash(addr, assertSuccess) -> ret {
                mstore(0, {{RIGHT_PADDED_GET_RAW_CODE_HASH_SELECTOR}})
                mstore(4, addr)
                let success := staticcall(
                    gas(),
                    ACCOUNT_CODE_STORAGE_ADDR(),
                    0,
                    36,
                    0,
                    32
                )

                // In case the call to the account code storage fails,
                // it most likely means that the caller did not provide enough gas for
                // the call.
                // In case the caller is certain that the amount of gas provided is enough, i.e.
                // (`assertSuccess` = true), then we should panic.
                if iszero(success) {
                    if assertSuccess {
                        // The call must've succeeded, but it didn't. So we revert the bootloader.
                        assertionError("getRawCodeHash failed")
                    }

                    // Most likely not enough gas provided, revert the current frame.
                    nearCallPanic()
                }

                ret := mload(0)
            }

            /// @dev The function that is temporarily needed to upgrade the SystemContext system contract. This function is to be removed 
            /// once the upgrade is complete.
            /// @dev Checks whether the code hash of the SystemContext contract is correct and updates it if needed.
            /// @dev The bootloader calls `setPubdataInfo` before each transaction, including the upgrade one.
            /// However, the old SystemContext does not have this method. So the bootloader should invoke this function 
            /// before starting any transaction.
            function upgradeSystemContextIfNeeded() {
                let expectedCodeHash := {{SYSTEM_CONTEXT_EXPECTED_CODE_HASH}}
                
                let actualCodeHash := getRawCodeHash(SYSTEM_CONTEXT_ADDR(), true)
                if iszero(eq(expectedCodeHash, actualCodeHash)) {
                    // Now, we need to encode the call to the `ContractDeployer.forceDeployOnAddresses()` function.

                    // The `mimicCallOnlyResult` requires that the first word of the data
                    // contains its length. Here it is 292 bytes.
                    mstore(0, 292)
                    mstore(32, {{PADDED_FORCE_DEPLOY_ON_ADDRESSES_SELECTOR}})

                    // The 0x20 offset, for the array of forced deployments
                    mstore(36, 0x0000000000000000000000000000000000000000000000000000000000000020)
                    // Only one force deployment
                    mstore(68, 0x0000000000000000000000000000000000000000000000000000000000000001)

                    // Now, starts the description of the forced deployment itself. 
                    // Firstly, the offset.
                    mstore(100, 0x0000000000000000000000000000000000000000000000000000000000000020)
                    // The new hash of the SystemContext contract.
                    mstore(132, expectedCodeHash)
                    // The address of the system context
                    mstore(164, SYSTEM_CONTEXT_ADDR())
                    // The constructor must be called to reset the `blockGasLimit` variable
                    mstore(196, 0x0000000000000000000000000000000000000000000000000000000000000001)
                    // The value should be 0.
                    mstore(228, 0x0000000000000000000000000000000000000000000000000000000000000000)
                    // The offset of the input array.
                    mstore(260, 0x00000000000000000000000000000000000000000000000000000000000000a0)
                    // No input is provided, the array is empty.
                    mstore(292, 0x0000000000000000000000000000000000000000000000000000000000000000)
                    
                    // We'll use a mimicCall to simulate the correct sender.
                    let success := mimicCallOnlyResult(
                        CONTRACT_DEPLOYER_ADDR(),
                        FORCE_DEPLOYER(), 
                        0,
                        0,
                        0,
                        0,
                        0,
                        0
                    )

                    if iszero(success) {
                        assertionError("system context upgrade fail")
                    }
                }
            }

            /// @dev Calculates the canonical hash of the L1->L2 transaction that will be
            /// sent to L1 as a message to the L1 contract that a certain operation has been processed.
            function getCanonicalL1TxHash(txDataOffset) -> ret {
                // Putting the correct value at the `txDataOffset` just in case, since
                // the correctness of this value is not part of the system invariants.
                // Note, that the correct ABI encoding of the Transaction structure starts with 0x20
                mstore(txDataOffset, 32)

                let innerTxDataOffset := add(txDataOffset, 32)
                let dataLength := safeAdd(32, getDataLength(innerTxDataOffset), "qev")

                debugLog("HASH_OFFSET", innerTxDataOffset)
                debugLog("DATA_LENGTH", dataLength)

                ret := keccak256(txDataOffset, dataLength)
            }

            /// @dev The purpose of this function is to make sure the operator
            /// gets paid for the transaction. Note, that the beneficiary of the payment is
            /// bootloader.
            /// The operator will be paid at the end of the batch.
            function ensurePayment(txDataOffset, gasPrice) {
                // Skipping the first 0x20 byte in the encoding of the transaction.
                let innerTxDataOffset := add(txDataOffset, 32)
                let from := getFrom(innerTxDataOffset)
                let requiredETH := safeMul(getGasLimit(innerTxDataOffset), gasPrice, "lal")

                let bootloaderBalanceETH := balance(BOOTLOADER_FORMAL_ADDR())
                let paymaster := getPaymaster(innerTxDataOffset)

                let payer := 0

                switch paymaster
                case 0 {
                    payer := from

                    // There is no paymaster, the user should pay for the execution.
                    // Calling the `payForTransaction` method of the account.
                    setHook(VM_HOOK_ACCOUNT_VALIDATION_ENTERED())
                    let res := accountPayForTx(from, txDataOffset)
                    setHook(VM_HOOK_NO_VALIDATION_ENTERED())


                    if iszero(res) {
                        revertWithReason(
                            PAY_FOR_TX_FAILED_ERR_CODE(),
                            1
                        )
                    }
                }
                default {
                    // There is some paymaster present.
                    payer := paymaster

                    // Firstly, the `prepareForPaymaster` method of the user's account is called.
                    setHook(VM_HOOK_ACCOUNT_VALIDATION_ENTERED())
                    let userPrePaymasterResult := accountPrePaymaster(from, txDataOffset)
                    setHook(VM_HOOK_NO_VALIDATION_ENTERED())

                    if iszero(userPrePaymasterResult) {
                        revertWithReason(
                            PRE_PAYMASTER_PREPARATION_FAILED_ERR_CODE(),
                            1
                        )
                    }

                    // Then, the paymaster is called. The paymaster should pay us in this method.
                    setHook(VM_HOOK_PAYMASTER_VALIDATION_ENTERED())
                    let paymasterPaymentSuccess := validateAndPayForPaymasterTransaction(paymaster, txDataOffset)
                    if iszero(paymasterPaymentSuccess) {
                        revertWithReason(
                            PAYMASTER_VALIDATION_FAILED_ERR_CODE(),
                            1
                        )
                    }

                    storePaymasterContextAndCheckMagic()
                    setHook(VM_HOOK_NO_VALIDATION_ENTERED())
                }

                let bootloaderReceivedFunds := safeSub(balance(BOOTLOADER_FORMAL_ADDR()), bootloaderBalanceETH, "qsx")

                // If the amount of funds provided to the bootloader is less than the minimum required one
                // then this transaction should be rejected.
                if lt(bootloaderReceivedFunds, requiredETH)  {
                    revertWithReason(
                        FAILED_TO_CHARGE_FEE_ERR_CODE(),
                        0
                    )
                }

                let excessiveFunds := safeSub(bootloaderReceivedFunds, requiredETH, "llm")

                if gt(excessiveFunds, 0) {
                    // Returning back the excessive funds taken.
                    directETHTransfer(excessiveFunds, payer)
                }
            }

            /// @notice Mints ether to the recipient
            /// @param to -- the address of the recipient
            /// @param amount -- the amount of ETH to mint
            /// @param useNearCallPanic -- whether to use nearCallPanic in case of
            /// the transaction failing to execute. It is desirable in cases
            /// where we want to allow the method fail without reverting the entire bootloader
            function mintEther(to, amount, useNearCallPanic) {
                mstore(0, {{RIGHT_PADDED_MINT_ETHER_SELECTOR}})
                mstore(4, to)
                mstore(36, amount)
                let success := call(
                    gas(),
                    ETH_L2_TOKEN_ADDR(),
                    0,
                    0,
                    68,
                    0,
                    0
                )
                if iszero(success) {
                    switch useNearCallPanic
                    case 0 {
                        revertWithReason(
                            MINT_ETHER_FAILED_ERR_CODE(),
                            0
                        )
                    }
                    default {
                        nearCallPanic()
                    }
                }
            }

            /// @dev Saves the paymaster context and checks that the paymaster has returned the correct
            /// magic value.
            /// @dev IMPORTANT: this method should be called right after
            /// the validateAndPayForPaymasterTransaction method to keep the `returndata` from that transaction
            function storePaymasterContextAndCheckMagic()    {
                // The paymaster validation step should return context of type "bytes context"
                // This means that the returndata is encoded the following way:
                // 0x20 || context_len || context_bytes...
                let returnlen := returndatasize()
                // The minimal allowed returndatasize is 64: magicValue || offset
                if lt(returnlen, 64) {
                    revertWithReason(
                        PAYMASTER_RETURNED_INVALID_CONTEXT(),
                        0
                    )
                }

                // Note that it is important to copy the magic even though it is not needed if the
                // `SHOULD_ENSURE_CORRECT_RETURNED_MAGIC` is false. It is never false in production
                // but it is so in fee estimation and we want to preserve as many operations as
                // in the original operation.
                {
                    returndatacopy(0, 0, 32)
                    let magic := mload(0)

                    let isMagicCorrect := eq(magic, {{SUCCESSFUL_PAYMASTER_VALIDATION_MAGIC_VALUE}})

                    if and(iszero(isMagicCorrect), SHOULD_ENSURE_CORRECT_RETURNED_MAGIC()) {
                        revertWithReason(
                            PAYMASTER_RETURNED_INVALID_MAGIC_ERR_CODE(),
                            0
                        )
                    }
                }

                returndatacopy(0, 32, 32)
                let returnedContextOffset := mload(0)

                // Ensuring that the returned offset is not greater than the returndata length
                // Note, that we cannot use addition here to prevent an overflow
                if gt(returnedContextOffset, returnlen) {
                    revertWithReason(
                        PAYMASTER_RETURNED_INVALID_CONTEXT(),
                        0
                    )
                }

                // Can not read the returned length.
                // It is safe to add here due to the previous check.
                if gt(add(returnedContextOffset, 32), returnlen) {
                    revertWithReason(
                        PAYMASTER_RETURNED_INVALID_CONTEXT(),
                        0
                    )
                }

                // Reading the length of the context
                returndatacopy(0, returnedContextOffset, 32)
                let returnedContextLen := mload(0)

                // Ensuring that returnedContextLen is not greater than the length of the paymaster context
                // Note, that this check at the same time prevents an overflow in the future operations with returnedContextLen
                if gt(returnedContextLen, PAYMASTER_CONTEXT_BYTES()) {
                    revertWithReason(
                        PAYMASTER_RETURNED_CONTEXT_IS_TOO_LONG(),
                        0
                    )
                }

                let roundedContextLen := lengthRoundedByWords(returnedContextLen)

                // The returned context's size should not exceed the maximum length
                if gt(add(roundedContextLen, 32), PAYMASTER_CONTEXT_BYTES()) {
                    revertWithReason(
                        PAYMASTER_RETURNED_CONTEXT_IS_TOO_LONG(),
                        0
                    )
                }

                if gt(add(returnedContextOffset, add(32, returnedContextLen)), returnlen) {
                    revertWithReason(
                        PAYMASTER_RETURNED_INVALID_CONTEXT(),
                        0
                    )
                }

                returndatacopy(PAYMASTER_CONTEXT_BEGIN_BYTE(), returnedContextOffset, add(32, returnedContextLen))
            }

            /// @dev The function responsible for processing L1->L2 transactions.
            /// @param txDataOffset The offset to the transaction's information
            /// @param resultPtr The pointer at which the result of the execution of this transaction
            /// @param transactionIndex The index of the transaction
            /// @param gasPerPubdata The price per pubdata to be used
            /// @param isPriorityOp Whether the transaction is a priority one
            function processL1Tx(
                txDataOffset,
                resultPtr,
                transactionIndex,
                gasPerPubdata,
                isPriorityOp
            ) {
                // For L1->L2 transactions we always use the pubdata price provided by the transaction.
                // This is needed to ensure DDoS protection. All the excess expenditure
                // will be refunded to the user.

                // Skipping the first formal 0x20 byte
                let innerTxDataOffset := add(txDataOffset, 32)

                let basePubdataSpent := getPubdataCounter()

                let gasLimitForTx, reservedGas := getGasLimitForTx(
                    innerTxDataOffset,
                    transactionIndex,
                    gasPerPubdata,
                    L1_TX_INTRINSIC_L2_GAS(),
                    L1_TX_INTRINSIC_PUBDATA()
                )

                let gasUsedOnPreparation := 0
                let canonicalL1TxHash := 0

                canonicalL1TxHash, gasUsedOnPreparation := l1TxPreparation(txDataOffset, gasPerPubdata, basePubdataSpent)

                let refundGas := 0
                let success := 0

                // The invariant that the user deposited more than the value needed
                // for the transaction must be enforced on L1, but we double check it here
                let gasLimit := getGasLimit(innerTxDataOffset)

                // Note, that for now the property of block.base <= tx.maxFeePerGas does not work
                // for L1->L2 transactions. For now, these transactions are processed with the same gasPrice
                // they were provided on L1. In the future, we may apply a new logic for it.
                let gasPrice := getMaxFeePerGas(innerTxDataOffset)
                let txInternalCost := safeMul(gasPrice, gasLimit, "poa")
                let value := getValue(innerTxDataOffset)
                if lt(getReserved0(innerTxDataOffset), safeAdd(value, txInternalCost, "ol")) {
                    assertionError("deposited eth too low")
                }

                // In previous steps, there might have been already some pubdata published (e.g. to mark factory dependencies as published).
                // However, these actions are mandatory and it is assumed that the L1 Mailbox contract ensured that the provided gas is enough to cover for pubdata.
                if gt(gasLimitForTx, gasUsedOnPreparation) {
                    let gasSpentOnExecution := 0
                    let gasForExecution := sub(gasLimitForTx, gasUsedOnPreparation)

                    gasSpentOnExecution, success := getExecuteL1TxAndNotifyResult(
                        txDataOffset,
                        gasForExecution,
                        basePubdataSpent,
                        gasPerPubdata,
                    )

                    let ergsSpentOnPubdata := getErgsSpentForPubdata(
                        basePubdataSpent,
                        gasPerPubdata
                    )

                    // It is assumed that `isNotEnoughGasForPubdata` ensured that the user did not publish too much pubdata.
                    let potentialRefund := saturatingSub(
                        safeAdd(reservedGas, gasForExecution, "safeadd: potentialRefund1"),
                        safeAdd(gasSpentOnExecution, ergsSpentOnPubdata, "safeadd: potentialRefund2")
                    )

                    // Asking the operator for refund
                    askOperatorForRefund(potentialRefund, ergsSpentOnPubdata, gasPerPubdata)

                    // In case the operator provided smaller refund than the one calculated
                    // by the bootloader, we return the refund calculated by the bootloader.
                    refundGas := max(getOperatorRefundForTx(transactionIndex), potentialRefund)
                }

                if gt(refundGas, gasLimit) {
                    assertionError("L1: refundGas > gasLimit")
                }

                let payToOperator := safeMul(gasPrice, safeSub(gasLimit, refundGas, "lpah"), "mnk")

                notifyAboutRefund(refundGas)

                // Paying the fee to the operator
                mintEther(BOOTLOADER_FORMAL_ADDR(), payToOperator, false)

                let toRefundRecipient
                switch success
                case 0 {
                    if iszero(isPriorityOp) {
                        // Upgrade transactions must always succeed
                        assertionError("Upgrade tx failed")
                    }

                    // If the transaction reverts, then minting the msg.value to the user has been reverted
                    // as well, so we can simply mint everything that the user has deposited to
                    // the refund recipient
                    toRefundRecipient := safeSub(getReserved0(innerTxDataOffset), payToOperator, "vji")
                }
                default {
                    // If the transaction succeeds, then it is assumed that msg.value was transferred correctly. However, the remaining
                    // ETH deposited will be given to the refund recipient.

                    toRefundRecipient := safeSub(getReserved0(innerTxDataOffset), safeAdd(getValue(innerTxDataOffset), payToOperator, "kpa"), "ysl")
                }

                if gt(toRefundRecipient, 0) {
                    let refundRecipient := getReserved1(innerTxDataOffset)
                    // Zero out the first 12 bytes to be sure that refundRecipient is address.
                    // In case of an issue in L1 contracts, we still will be able to process tx.
                    refundRecipient := and(refundRecipient, sub(shl(160, 1), 1))
                    mintEther(refundRecipient, toRefundRecipient, false)
                }

                mstore(resultPtr, success)

                debugLog("Send message to L1", success)

                // Sending the L2->L1 log so users will be able to prove transaction execution result on L1.
                sendL2LogUsingL1Messenger(true, canonicalL1TxHash, success)

                if isPriorityOp {
                    // Update priority txs L1 data
                    mstore(0, mload(PRIORITY_TXS_L1_DATA_BEGIN_BYTE()))
                    mstore(32, canonicalL1TxHash)
                    mstore(PRIORITY_TXS_L1_DATA_BEGIN_BYTE(), keccak256(0, 64))
                    mstore(add(PRIORITY_TXS_L1_DATA_BEGIN_BYTE(), 32), add(mload(add(PRIORITY_TXS_L1_DATA_BEGIN_BYTE(), 32)), 1))
                }
            }

            /// @dev The function responsible for execution of L1->L2 transactions.
            /// @param txDataOffset The offset to the transaction's information
            /// @param gasForExecution The amount of gas available for the execution
            /// @param basePubdataSpent The amount of pubdata spent at the start of the transaction
            /// @param gasPerPubdata The price per each pubdata byte in L2 gas
            function getExecuteL1TxAndNotifyResult(
                txDataOffset,
                gasForExecution,
                basePubdataSpent,
                gasPerPubdata
            ) -> gasSpentOnExecution, success {
                debugLog("gasForExecution", gasForExecution)

                let callAbi := getNearCallABI(gasForExecution)
                debugLog("callAbi", callAbi)

                checkEnoughGas(gasForExecution)

                let gasBeforeExecution := gas()
                success := ZKSYNC_NEAR_CALL_executeL1Tx(
                    callAbi,
                    txDataOffset,
                    basePubdataSpent,
                    gasPerPubdata
                )
                notifyExecutionResult(success)
                gasSpentOnExecution := sub(gasBeforeExecution, gas())
            }

            /// @dev The function responsible for doing all the pre-execution operations for L1->L2 transactions.
            /// @param txDataOffset The offset to the transaction's information
            /// @param gasPerPubdata The price per each pubdata byte in L2 gas
            /// @param basePubdataSpent The amount of pubdata spent at the start of the transaction
            /// @return canonicalL1TxHash The hash of processed L1->L2 transaction
            /// @return gasUsedOnPreparation The number of L2 gas used in the preparation stage
            function l1TxPreparation(
                txDataOffset,
                gasPerPubdata,
                basePubdataSpent
            ) -> canonicalL1TxHash, gasUsedOnPreparation {
                let innerTxDataOffset := add(txDataOffset, 32)

                setPubdataInfo(gasPerPubdata, basePubdataSpent)

                let gasBeforePreparation := gas()
                debugLog("gasBeforePreparation", gasBeforePreparation)

                // Even though the smart contracts on L1 should make sure that the L1->L2 provide enough gas to generate the hash
                // we should still be able to do it even if this protection layer fails.
                canonicalL1TxHash := getCanonicalL1TxHash(txDataOffset)
                debugLog("l1 hash", canonicalL1TxHash)

                // Appending the transaction's hash to the current L2 block
                appendTransactionHash(canonicalL1TxHash, true)

                markFactoryDepsForTx(innerTxDataOffset, true)

                gasUsedOnPreparation := safeSub(gasBeforePreparation, gas(), "xpa")
                debugLog("gasUsedOnPreparation", gasUsedOnPreparation)
            }

            /// @dev Returns the gas price that should be used by the transaction
            /// based on the EIP1559's maxFeePerGas and maxPriorityFeePerGas.
            /// The following invariants should hold:
            /// maxPriorityFeePerGas <= maxFeePerGas
            /// baseFee <= maxFeePerGas
            /// While we charge baseFee from the users, the method is mostly used as a method for validating
            /// the correctness of the fee parameters
            function getGasPrice(
                maxFeePerGas,
                maxPriorityFeePerGas
            ) -> ret {
                let baseFee := basefee()

                if gt(maxPriorityFeePerGas, maxFeePerGas) {
                    revertWithReason(
                        MAX_PRIORITY_FEE_PER_GAS_GREATER_THAN_MAX_FEE_PER_GAS(),
                        0
                    )
                }

                if gt(baseFee, maxFeePerGas) {
                    revertWithReason(
                        BASE_FEE_GREATER_THAN_MAX_FEE_PER_GAS(),
                        0
                    )
                }

                // We always use `baseFee` to charge the transaction
                ret := baseFee
            }

            /// @dev The function responsible for processing L2 transactions.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param resultPtr The pointer at which the result of the execution of this transaction
            /// should be stored.
            /// @param transactionIndex The index of the current transaction.
            /// @param gasPerPubdata The L2 gas to be used for each byte of pubdata published onchain.
            /// @dev This function firstly does the validation step and then the execution step in separate near_calls.
            /// It is important that these steps are split to avoid rollbacking the state made by the validation step.
            function processL2Tx(
                txDataOffset,
                resultPtr,
                transactionIndex,
                gasPerPubdata
            ) {
                let basePubdataSpent := getPubdataCounter()

                debugLog("baseSpent", basePubdataSpent)

                let innerTxDataOffset := add(txDataOffset, 32)

                // Firstly, we publish all the bytecodes needed. This is needed to be done separately, since
                // bytecodes usually form the bulk of the L2 gas prices.

                let gasLimitForTx, reservedGas := getGasLimitForTx(
                    innerTxDataOffset,
                    transactionIndex,
                    gasPerPubdata,
                    L2_TX_INTRINSIC_GAS(),
                    L2_TX_INTRINSIC_PUBDATA()
                )

                let gasPrice := getGasPrice(getMaxFeePerGas(innerTxDataOffset), getMaxPriorityFeePerGas(innerTxDataOffset))

                debugLog("gasLimitForTx", gasLimitForTx)

                let gasLeft := l2TxValidation(
                    txDataOffset,
                    gasLimitForTx,
                    gasPrice,
                    basePubdataSpent,
                    reservedGas,
                    gasPerPubdata
                )

                debugLog("validation finished", 0)

                let gasSpentOnExecute := 0
                let success := 0
                success, gasSpentOnExecute := l2TxExecution(txDataOffset, gasLeft, basePubdataSpent, reservedGas, gasPerPubdata)

                debugLog("execution finished", 0)

                let refund := 0
                let gasToRefund := saturatingSub(gasLeft, gasSpentOnExecute)

                // Note, that we pass reservedGas from the refundGas separately as it should not be used
                // during the postOp execution.
                refund := refundCurrentL2Transaction(
                    txDataOffset,
                    transactionIndex,
                    success,
                    gasToRefund,
                    gasPrice,
                    reservedGas,
                    basePubdataSpent,
                    gasPerPubdata
                )

                notifyAboutRefund(refund)
                mstore(resultPtr, success)
            }

            /// @dev Calculates the L2 gas limit for the transaction
            /// @param innerTxDataOffset The offset for the ABI-encoded Transaction struct fields.
            /// @param transactionIndex The index of the transaction within the batch.
            /// @param gasPerPubdata The price for a pubdata byte in L2 gas.
            /// @param intrinsicGas The intrinsic number of L2 gas required for transaction processing.
            /// @param intrinsicPubdata The intrinsic number of pubdata bytes required for transaction processing.
            /// @return gasLimitForTx The maximum number of L2 gas that can be spent on a transaction.
            /// @return reservedGas The number of L2 gas that is beyond the `MAX_GAS_PER_TRANSACTION` and beyond the operator's trust limit,
            /// i.e. gas which we cannot allow the transaction to use and will refund.
            function getGasLimitForTx(
                innerTxDataOffset,
                transactionIndex,
                gasPerPubdata,
                intrinsicGas,
                intrinsicPubdata
            ) -> gasLimitForTx, reservedGas {
                let totalGasLimit := getGasLimit(innerTxDataOffset)

                // `MAX_GAS_PER_TRANSACTION` is the amount of gas each transaction
                // is guaranteed to get, so even if the operator does not trust the account enough,
                // it is still obligated to provide at least that
                let operatorTrustedGasLimit := max(MAX_GAS_PER_TRANSACTION(), getOperatorTrustedGasLimitForTx(transactionIndex))

                // We remember the amount of gas that is beyond the operator's trust limit to refund it back later.
                switch gt(totalGasLimit, operatorTrustedGasLimit)
                case 0 {
                    reservedGas := 0
                }
                default {
                    reservedGas := sub(totalGasLimit, operatorTrustedGasLimit)
                    totalGasLimit := operatorTrustedGasLimit
                }

                let txEncodingLen := safeAdd(32, getDataLength(innerTxDataOffset), "lsh")

                let operatorOverheadForTransaction := getVerifiedOperatorOverheadForTx(
                    transactionIndex,
                    totalGasLimit,
                    txEncodingLen
                )
                gasLimitForTx := safeSub(totalGasLimit, operatorOverheadForTransaction, "qr")

                let intrinsicOverhead := safeAdd(
                    intrinsicGas,
                    // the error messages are trimmed to fit into 32 bytes
                    safeMul(intrinsicPubdata, gasPerPubdata, "qw"),
                    "fj"
                )

                switch lt(gasLimitForTx, intrinsicOverhead)
                case 1 {
                    gasLimitForTx := 0
                }
                default {
                    gasLimitForTx := sub(gasLimitForTx, intrinsicOverhead)
                }
            }

            /// @dev The function responsible for the L2 transaction validation.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param gasLimitForTx The L2 gas limit for the transaction validation & execution.
            /// @param gasPrice The L2 gas price that should be used by the transaction.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param reservedGas The amount of gas reserved for the pubdata.            
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            /// @return gasLeft The gas left after the validation step.
            function l2TxValidation(
                txDataOffset,
                gasLimitForTx,
                gasPrice,
                basePubdataSpent,
                reservedGas,
                gasPerPubdata
            ) -> gasLeft {
                let gasBeforeValidate := gas()

                debugLog("gasBeforeValidate", gasBeforeValidate)

                // Saving the tx hash and the suggested signed tx hash to memory
                saveTxHashes(txDataOffset)

                // Appending the transaction's hash to the current L2 block
                appendTransactionHash(mload(CURRENT_L2_TX_HASHES_BEGIN_BYTE()), false)

                setPubdataInfo(gasPerPubdata, basePubdataSpent)

                checkEnoughGas(gasLimitForTx)

                // Note, that it is assumed that `ZKSYNC_NEAR_CALL_validateTx` will always return true
                // unless some error which made the whole bootloader to revert has happened or
                // it runs out of gas.
                let isValid := 0

                // Only if the gasLimit for tx is non-zero, we will try to actually run the validation
                if gasLimitForTx {
                    let validateABI := getNearCallABI(gasLimitForTx)

                    debugLog("validateABI", validateABI)

                    isValid := ZKSYNC_NEAR_CALL_validateTx(validateABI, txDataOffset, gasPrice)
                }

                debugLog("isValid", isValid)

                let gasUsedForValidate := sub(gasBeforeValidate, gas())
                debugLog("gasUsedForValidate", gasUsedForValidate)

                gasLeft := saturatingSub(gasLimitForTx, gasUsedForValidate)

                // isValid can only be zero if the validation has failed with out of gas
                if or(iszero(gasLeft), iszero(isValid)) {
                    revertWithReason(TX_VALIDATION_OUT_OF_GAS(), 0)
                }

                if isNotEnoughGasForPubdata(
                    basePubdataSpent, gasLeft, reservedGas, gasPerPubdata
                ) {
                    revertWithReason(TX_VALIDATION_OUT_OF_GAS(), 0)
                }

                setHook(VM_HOOK_VALIDATION_STEP_ENDED())
            }

            /// @dev The function responsible for the execution step of the L2 transaction.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param gasLeft The gas left after the validation step.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param reservedGas The amount of gas reserved for the pubdata.            
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            /// @return success Whether or not the execution step was successful.
            /// @return gasSpentOnExecute The gas spent on the transaction execution.
            function l2TxExecution(
                txDataOffset,
                gasLeft,
                basePubdataSpent,
                reservedGas,
                gasPerPubdata
            ) -> success, gasSpentOnExecute {
                let newCompressedFactoryDepsPointer := 0
                let gasSpentOnFactoryDeps := 0
                let gasBeforeFactoryDeps := gas()
                if gasLeft {
                    let markingDependenciesABI := getNearCallABI(gasLeft)
                    checkEnoughGas(gasLeft)
                    newCompressedFactoryDepsPointer := ZKSYNC_NEAR_CALL_markFactoryDepsL2(
                        markingDependenciesABI,
                        txDataOffset,
                        basePubdataSpent,
                        reservedGas,
                        gasPerPubdata
                    )
                    gasSpentOnFactoryDeps := sub(gasBeforeFactoryDeps, gas())
                }

                // If marking of factory dependencies has been unsuccessful, 0 value is returned.
                // Otherwise, all the previous dependencies have been successfully published, so
                // we need to move the pointer.
                if newCompressedFactoryDepsPointer {
                    mstore(COMPRESSED_BYTECODES_BEGIN_BYTE(), newCompressedFactoryDepsPointer)
                }

                switch gt(gasLeft, gasSpentOnFactoryDeps)
                case 0 {
                    gasSpentOnExecute := gasLeft
                    gasLeft := 0
                }
                default {
                    // Note, that since gt(gasLeft, gasSpentOnFactoryDeps) = true
                    // sub(gasLeft, gasSpentOnFactoryDeps) > 0, which is important
                    // because a nearCall with 0 gas passes on all the gas of the parent frame.
                    gasLeft := sub(gasLeft, gasSpentOnFactoryDeps)

                    let executeABI := getNearCallABI(gasLeft)
                    checkEnoughGas(gasLeft)

                    let gasBeforeExecute := gas()
                    // for this one, we don't care whether or not it fails.
                    success := ZKSYNC_NEAR_CALL_executeL2Tx(
                        executeABI,
                        txDataOffset,
                        basePubdataSpent,
                        reservedGas,
                        gasPerPubdata
                    )

                    gasSpentOnExecute := add(gasSpentOnFactoryDeps, sub(gasBeforeExecute, gas()))
                }

                debugLog("notifySuccess", success)

                notifyExecutionResult(success)
            }

            /// @dev Function responsible for the validation & fee payment step of the transaction.
            /// @param abi The nearCall ABI. It is implicitly used as gasLimit for the call of this function.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param gasPrice The gasPrice to be used in this transaction.
            function ZKSYNC_NEAR_CALL_validateTx(
                abi,
                txDataOffset,
                gasPrice
            ) -> ret {
                // For the validation step we always use the bootloader as the tx.origin of the transaction
                setTxOrigin(BOOTLOADER_FORMAL_ADDR())
                setGasPrice(gasPrice)

                // Skipping the first 0x20 word of the ABI-encoding
                let innerTxDataOffset := add(txDataOffset, 32)
                debugLog("Starting validation", 0)

                accountValidateTx(txDataOffset)
                debugLog("Tx validation complete", 1)

                ensurePayment(txDataOffset, gasPrice)

                ret := 1
            }

            /// @dev Function responsible for the execution of the L2 transaction.
            /// It includes both the call to the `executeTransaction` method of the account
            /// and the call to postOp of the account.
            /// @param abi The nearCall ABI. It is implicitly used as gasLimit for the call of this function.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param reservedGas The amount of gas reserved for the pubdata.            
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            function ZKSYNC_NEAR_CALL_executeL2Tx(
                abi,
                txDataOffset,
                basePubdataSpent,
                reservedGas,
                gasPerPubdata,
            ) -> success {
                // Skipping the first word of the ABI-encoding encoding
                let innerTxDataOffset := add(txDataOffset, 32)
                let from := getFrom(innerTxDataOffset)

                debugLog("Executing L2 tx", 0)
                // The tx.origin can only be an EOA
                switch isEOA(from)
                case true {
                    setTxOrigin(from)
                }
                default {
                    setTxOrigin(BOOTLOADER_FORMAL_ADDR())
                }

                success := executeL2Tx(txDataOffset, from)

                if isNotEnoughGasForPubdata(
                    basePubdataSpent,
                    gas(),
                    reservedGas,
                    gasPerPubdata
                ) {
                    // If not enough gas for pubdata was provided, we revert all the state diffs / messages
                    // that caused the pubdata to be published
                    nearCallPanic()
                }

                debugLog("Executing L2 ret", success)
            }

            /// @dev Sets factory dependencies for an L2 transaction with possible usage of packed bytecodes.
            /// @param abi The nearCall ABI. It is implicitly used as gasLimit for the call of this function.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param reservedGas The amount of gas reserved for the pubdata.            
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            function ZKSYNC_NEAR_CALL_markFactoryDepsL2(
                abi,
                txDataOffset,
                basePubdataSpent,
                reservedGas,
                gasPerPubdata
            ) -> newDataInfoPtr {
                let innerTxDataOffset := add(txDataOffset, 32)

                /// Note, that since it is the near call when it panics it reverts the state changes, but it DOES NOT
                /// revert the changes in *memory* of the current frame. That is why we do not change the value under
                /// COMPRESSED_BYTECODES_BEGIN_BYTE(), and it is only changed outside of this method.
                let dataInfoPtr := mload(COMPRESSED_BYTECODES_BEGIN_BYTE())
                let factoryDepsPtr := getFactoryDepsPtr(innerTxDataOffset)
                let factoryDepsLength := mload(factoryDepsPtr)

                let iter := add(factoryDepsPtr, 32)
                let endPtr := add(iter, mul(32, factoryDepsLength))

                for { } lt(iter, endPtr) { iter := add(iter, 32)} {
                    let bytecodeHash := mload(iter)

                    let currentExpectedBytecodeHash := mload(dataInfoPtr)

                    if eq(bytecodeHash, currentExpectedBytecodeHash) {
                        // Here we are making sure that the bytecode is indeed not yet know and needs to be published,
                        // preventing users from being overcharged by the operator.
                        let marker := getCodeMarker(bytecodeHash)

                        if marker {
                            assertionError("invalid republish")
                        }

                        dataInfoPtr := sendCompressedBytecode(dataInfoPtr, bytecodeHash)
                    }
                }

                // For all the bytecodes that have not been compressed on purpose or due to the inefficiency
                // of compressing the entire preimage of the bytecode will be published.
                // For bytecodes published in the previous step, no need pubdata will have to be published
                markFactoryDepsForTx(innerTxDataOffset, false)

                if isNotEnoughGasForPubdata(
                    basePubdataSpent,
                    gas(),
                    reservedGas,
                    gasPerPubdata
                ) {
                    // If not enough gas for pubdata was provided, we revert all the state diffs / messages
                    // that caused the pubdata to be published
                    nearCallPanic()
                }

                newDataInfoPtr := dataInfoPtr
            }

            function getCodeMarker(bytecodeHash) -> ret {
                mstore(0, {{GET_MARKER_PADDED_SELECTOR}})
                mstore(4, bytecodeHash)
                let success := call(
                    gas(),
                    KNOWN_CODES_CONTRACT_ADDR(),
                    0,
                    0,
                    36,
                    0,
                    32
                )

                if iszero(success) {
                    nearCallPanic()
                }

                ret := mload(0)
            }


            /// @dev Used to refund the current transaction.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param transactionIndex The index of the transaction in the batch.
            /// @param success The transaction execution status.
            /// @param gasLeft The gas left after the execution step.
            /// @param gasPrice The L2 gas price that should be used by the transaction.
            /// @param reservedGas The amount of gas reserved for the pubdata.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            /// The gas that this transaction consumes has been already paid in the
            /// process of the validation
            function refundCurrentL2Transaction(
                txDataOffset,
                transactionIndex,
                success,
                gasLeft,
                gasPrice,
                reservedGas,
                basePubdataSpent,
                gasPerPubdata
            ) -> finalRefund {
                setTxOrigin(BOOTLOADER_FORMAL_ADDR())

                finalRefund := 0

                let innerTxDataOffset := add(txDataOffset, 32)

                let paymaster := getPaymaster(innerTxDataOffset)
                let refundRecipient := 0
                switch paymaster
                case 0 {
                    // No paymaster means that the sender should receive the refund
                    refundRecipient := getFrom(innerTxDataOffset)
                }
                default {
                    refundRecipient := paymaster

                    if gt(gasLeft, 0) {
                        checkEnoughGas(gasLeft)
                        let nearCallAbi := getNearCallABI(gasLeft)
                        let gasBeforePostOp := gas()

                        let spentOnPubdata := getErgsSpentForPubdata(
                            basePubdataSpent,
                            gasPerPubdata
                        )

                        pop(ZKSYNC_NEAR_CALL_callPostOp(
                            // Maximum number of gas that the postOp could spend
                            nearCallAbi,
                            paymaster,
                            txDataOffset,
                            success,
                            // Since the paymaster will be refunded with reservedGas,
                            // it should know about it
                            saturatingSub(safeAdd(gasLeft, reservedGas, "jkl"), spentOnPubdata),
                            basePubdataSpent,
                            gasPerPubdata,
                            reservedGas
                        ))
                        let gasSpentByPostOp := sub(gasBeforePostOp, gas())

                        gasLeft := saturatingSub(gasLeft, gasSpentByPostOp)
                    }
                }

                // It was expected that before this point various `isNotEnoughGasForPubdata` methods would ensure that the user
                // has enough funds for pubdata. Now, we just subtract the leftovers from the user.
                let spentOnPubdata := getErgsSpentForPubdata(
                    basePubdataSpent,
                    gasPerPubdata
                )

                let totalRefund := saturatingSub(add(reservedGas, gasLeft), spentOnPubdata)

                askOperatorForRefund(
                    totalRefund,
                    spentOnPubdata,
                    gasPerPubdata
                )

                let operatorProvidedRefund := getOperatorRefundForTx(transactionIndex)

                // If the operator provides the value that is lower than the one suggested for
                // the bootloader, we will use the one calculated by the bootloader.
                let refundInGas := max(operatorProvidedRefund, totalRefund)

                // The operator cannot refund more than the gasLimit for the transaction
                if gt(refundInGas, getGasLimit(innerTxDataOffset)) {
                    assertionError("refundInGas > gasLimit")
                }

                if iszero(validateUint64(refundInGas)) {
                    assertionError("refundInGas is not uint64")
                }

                let ethToRefund := safeMul(
                    refundInGas,
                    gasPrice,
                    "fdf"
                )

                directETHTransfer(ethToRefund, refundRecipient)

                finalRefund := refundInGas
            }

            /// @notice A function that transfers ETH directly through the L2BaseToken system contract.
            /// Note, that unlike classical EVM transfers it does NOT call the recipient, but only changes the balance.
            function directETHTransfer(amount, recipient) {
                let ptr := 0
                mstore(ptr, {{PADDED_TRANSFER_FROM_TO_SELECTOR}})
                mstore(add(ptr, 4), BOOTLOADER_FORMAL_ADDR())
                mstore(add(ptr, 36), recipient)
                mstore(add(ptr, 68), amount)

                let transferSuccess := call(
                    gas(),
                    ETH_L2_TOKEN_ADDR(),
                    0,
                    0,
                    100,
                    0,
                    0
                )

                if iszero(transferSuccess) {
                    assertionError("Failed to refund")
                }
            }

            /// @dev Return the operator suggested transaction refund.
            function getOperatorRefundForTx(transactionIndex) -> ret {
                let refundPtr := add(TX_OPERATOR_REFUND_BEGIN_BYTE(), mul(transactionIndex, 32))
                ret := mload(refundPtr)
            }

            /// @dev Return the operator suggested transaction overhead cost.
            function getOperatorOverheadForTx(transactionIndex) -> ret {
                let txBatchOverheadPtr := add(TX_SUGGESTED_OVERHEAD_BEGIN_BYTE(), mul(transactionIndex, 32))
                ret := mload(txBatchOverheadPtr)
            }

            /// @dev Return the operator's "trusted" transaction gas limit
            function getOperatorTrustedGasLimitForTx(transactionIndex) -> ret {
                let txTrustedGasLimitPtr := add(TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_BYTE(), mul(transactionIndex, 32))
                ret := mload(txTrustedGasLimitPtr)
            }

            /// @dev Returns the bytecode hash that is next for being published
            function getCurrentCompressedBytecodeHash() -> ret {
                let compressionPtr := mload(COMPRESSED_BYTECODES_BEGIN_BYTE())

                ret := mload(add(COMPRESSED_BYTECODES_BEGIN_BYTE(), compressionPtr))
            }

            function checkOffset(pointer) {
                if gt(pointer, sub(COMPRESSED_BYTECODES_END_BYTE(), MIN_ALLOWED_OFFSET_FOR_COMPRESSED_BYTES_POINTER())) {
                    assertionError("calldataEncoding too big")
                }
            }

            /// @dev It is expected that the pointer at the COMPRESSED_BYTECODES_BEGIN_BYTE()
            /// stores the position of the current bytecodeHash
            function sendCompressedBytecode(dataInfoPtr, bytecodeHash) -> ret {
                // Storing the right selector, ensuring that the operator cannot manipulate it
                mstore(safeAdd(dataInfoPtr, 32, "vmt"), {{PUBLISH_COMPRESSED_BYTECODE_SELECTOR}})

                let calldataPtr := safeAdd(dataInfoPtr, 60, "vty")
                let afterSelectorPtr := safeAdd(calldataPtr, 4, "vtu")

                let originalBytecodeOffset := safeAdd(mload(afterSelectorPtr), afterSelectorPtr, "vtr")
                checkOffset(originalBytecodeOffset)
                let potentialRawCompressedDataOffset := validateBytes(
                    originalBytecodeOffset
                )

                if iszero(eq(originalBytecodeOffset, safeAdd(afterSelectorPtr, 64, "vtp"))) {
                    assertionError("Compression calldata incorrect")
                }

                let rawCompressedDataOffset := safeAdd(mload(safeAdd(afterSelectorPtr, 32, "ewq")), afterSelectorPtr, "vbt")
                checkOffset(rawCompressedDataOffset)

                if iszero(eq(potentialRawCompressedDataOffset, rawCompressedDataOffset)) {
                    assertionError("Compression calldata incorrect")
                }

                let nextAfterCalldata := validateBytes(
                    rawCompressedDataOffset
                )
                checkOffset(nextAfterCalldata)

                let totalLen := safeSub(nextAfterCalldata, calldataPtr, "xqwf")
                let success := call(
                    gas(),
                    BYTECODE_COMPRESSOR_ADDR(),
                    0,
                    calldataPtr,
                    totalLen,
                    0,
                    32
                )

                // If the transaction failed, either there was not enough gas or compression is malformed.
                if iszero(success) {
                    debugLog("compressor call failed", 0)
                    debugReturndata()
                    nearCallPanic()
                }

                let returnedBytecodeHash := mload(0)

                // If the bytecode hash calculated on the bytecode compressor's side
                // is not equal to the one provided by the operator means that the operator is
                // malicious and we should revert the batch altogether
                if iszero(eq(returnedBytecodeHash, bytecodeHash)) {
                    assertionError("bytecodeHash incorrect")
                }

                ret := nextAfterCalldata
            }

            /// @dev Get checked for overcharged operator's overhead for the transaction.
            /// @param transactionIndex The index of the transaction in the batch
            /// @param txTotalGasLimit The total gass limit of the transaction (including the overhead).
            /// @param gasPerPubdataByte The price for pubdata byte in gas.
            /// @param txEncodeLen The length of the ABI-encoding of the transaction
            function getVerifiedOperatorOverheadForTx(
                transactionIndex,
                txTotalGasLimit,
                txEncodeLen
            ) -> ret {
                let operatorOverheadForTransaction := getOperatorOverheadForTx(transactionIndex)
                if gt(operatorOverheadForTransaction, txTotalGasLimit) {
                    assertionError("Overhead higher than gasLimit")
                }

                let requiredOverhead := getTransactionUpfrontOverhead(txEncodeLen)

                debugLog("txTotalGasLimit", txTotalGasLimit)
                debugLog("requiredOverhead", requiredOverhead)
                debugLog("operatorOverheadForTransaction", operatorOverheadForTransaction)

                // The required overhead is less than the overhead that the operator
                // has requested from the user, meaning that the operator tried to overcharge the user
                if lt(requiredOverhead, operatorOverheadForTransaction) {
                    assertionError("Operator's overhead too high")
                }

                ret := operatorOverheadForTransaction
            }

            /// @dev Function responsible for the execution of the L1->L2 transaction.
            /// @param abi The nearCall ABI. It is implicitly used as gasLimit for the call of this function.
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            function ZKSYNC_NEAR_CALL_executeL1Tx(
                abi,
                txDataOffset,
                basePubdataSpent,
                gasPerPubdata,
            ) -> success {
                // Skipping the first word of the ABI encoding of the struct
                let innerTxDataOffset := add(txDataOffset, 32)
                let from := getFrom(innerTxDataOffset)
                let gasPrice := getMaxFeePerGas(innerTxDataOffset)

                debugLog("Executing L1 tx", 0)
                debugLog("from", from)
                debugLog("gasPrice", gasPrice)

                // We assume that addresses of smart contracts on zkSync and Ethereum
                // never overlap, so no need to check whether `from` is an EOA here.
                debugLog("setting tx origin", from)

                setTxOrigin(from)
                debugLog("setting gas price", gasPrice)

                setGasPrice(gasPrice)

                debugLog("execution itself", 0)

                let value := getValue(innerTxDataOffset)
                if value {
                    mintEther(from, value, true)
                }

                success := executeL1Tx(innerTxDataOffset, from)

                debugLog("Executing L1 ret", success)

                // If the success is zero, we will revert in order
                // to revert the minting of ether to the user
                if iszero(success) {
                    nearCallPanic()
                }

                if isNotEnoughGasForPubdata(
                    basePubdataSpent,
                    gas(),
                    // Note, that for L1->L2 transactions the reserved gas is used to protect the operator from
                    // transactions that might accidentally cause to publish too many pubdata.
                    // Thus, even if there is some accidental `reservedGas` left, it should not be used to publish pubdata.
                    0,
                    gasPerPubdata,
                ) {
                    // If not enough gas for pubdata was provided, we revert all the state diffs / messages
                    // that caused the pubdata to be published
                    nearCallPanic()
                }
            }

            /// @dev Returns the ABI for nearCalls.
            /// @param gasLimit The gasLimit for this nearCall
            function getNearCallABI(gasLimit) -> ret {
                ret := gasLimit
            }

            /// @dev Used to panic from the nearCall without reverting the parent frame.
            /// If you use `revert(...)`, the error will bubble up from the near call and
            /// make the bootloader to revert as well. This method allows to exit the nearCall only.
            function nearCallPanic() {
                // Here we exhaust all the gas of the current frame.
                // This will cause the execution to panic.
                // Note, that it will cause only the inner call to panic.
                precompileCall(gas())
            }

            /// @dev Executes the `precompileCall` opcode.
            /// Since the bootloader has no implicit meaning for this opcode,
            /// this method just burns gas.
            function precompileCall(gasToBurn) {
                // We don't care about the return value, since it is a opcode simulation
                // and the return value doesn't have any meaning.
                let ret := verbatim_2i_1o("precompile", 0, gasToBurn)
            }

            /// @dev Returns the pointer to the latest returndata.
            function returnDataPtr() -> ret {
                ret := verbatim_0i_1o("get_global::ptr_return_data")
            }


            <!-- @if BOOTLOADER_TYPE=='playground_batch' -->
            function ZKSYNC_NEAR_CALL_ethCall(
                abi,
                txDataOffset,
                resultPtr,
                reservedGas,
                gasPerPubdata
            ) {
                let basePubdataSpent := getPubdataCounter()

                setPubdataInfo(gasPerPubdata, basePubdataSpent)

                let innerTxDataOffset := add(txDataOffset, 32)
                let to := getTo(innerTxDataOffset)
                let from := getFrom(innerTxDataOffset)

                debugLog("from: ", from)
                debugLog("to: ", to)

                switch isEOA(from)
                case true {
                    setTxOrigin(from)
                }
                default {
                    setTxOrigin(0)
                }

                let dataPtr := getDataPtr(innerTxDataOffset)
                markFactoryDepsForTx(innerTxDataOffset, false)

                let value := getValue(innerTxDataOffset)

                let success := msgValueSimulatorMimicCall(
                    to,
                    from,
                    value,
                    dataPtr
                )

                if iszero(success) {
                    // If success is 0, we need to revert
                    revertWithReason(
                        ETH_CALL_ERR_CODE(),
                        1
                    )
                }

                if isNotEnoughGasForPubdata(
                    basePubdataSpent,
                    gas(),
                    reservedGas,
                    gasPerPubdata
                ) {
                    // If not enough gas for pubdata, eth call reverts too
                    revertWithReason(
                        ETH_CALL_ERR_CODE(),
                        0
                    )
                }

                mstore(resultPtr, success)

                // Store results of the call in the memory.
                if success {
                    let returnsize := returndatasize()
                    returndatacopy(0,0,returnsize)
                    return(0,returnsize)
                }

            }
            <!-- @endif -->

            /// @dev Given the callee and the data to be called with,
            /// this function returns whether the mimicCall should use the `isSystem` flag.
            /// This flag should only be used for contract deployments and nothing else.
            /// @param to The callee of the call.
            /// @param dataPtr The pointer to the calldata of the transaction.
            function shouldMsgValueMimicCallBeSystem(to, dataPtr) -> ret {
                let dataLen := mload(dataPtr)
                // Note, that this point it is not fully known whether it is indeed the selector
                // of the calldata (it might not be the case if the `dataLen` < 4), but it will be checked later on
                let selector := shr(224, mload(add(dataPtr, 32)))

                let isSelectorCreate := or(
                    eq(selector, {{CREATE_SELECTOR}}),
                    eq(selector, {{CREATE_ACCOUNT_SELECTOR}})
                )
                let isSelectorCreate2 := or(
                    eq(selector, {{CREATE2_SELECTOR}}),
                    eq(selector, {{CREATE2_ACCOUNT_SELECTOR}})
                )

                // Firstly, ensure that the selector is a valid deployment function
                ret := or(
                    isSelectorCreate,
                    isSelectorCreate2
                )
                // Secondly, ensure that the callee is ContractDeployer
                ret := and(ret, eq(to, CONTRACT_DEPLOYER_ADDR()))
                // Thirdly, ensure that the calldata is long enough to contain the selector
                ret := and(ret, gt(dataLen, 3))
            }

            /// @dev Given the pointer to the calldata, the value and to
            /// performs the call through the msg.value simulator.
            /// @param to Which contract to call
            /// @param from The `msg.sender` of the call.
            /// @param value The `value` that will be used in the call.
            /// @param dataPtr The pointer to the calldata of the transaction. It must store
            /// the length of the calldata and the calldata itself right afterwards.
            function msgValueSimulatorMimicCall(to, from, value, dataPtr) -> success {
                // Only calls to the deployer system contract are allowed to be system
                let isSystem := shouldMsgValueMimicCallBeSystem(to, dataPtr)

                success := mimicCallOnlyResult(
                    MSG_VALUE_SIMULATOR_ADDR(),
                    from,
                    dataPtr,
                    0,
                    1,
                    value,
                    to,
                    isSystem
                )
            }

            /// @dev Checks whether the current frame has enough gas
            /// @dev It does not use 63/64 rule and should only be called before nearCalls.
            function checkEnoughGas(gasToProvide) {
                debugLog("gas()", gas())
                debugLog("gasToProvide", gasToProvide)

                // Using margin of CHECK_ENOUGH_GAS_OVERHEAD gas to make sure that the operation will indeed
                // have enough gas
                if lt(gas(), safeAdd(gasToProvide, CHECK_ENOUGH_GAS_OVERHEAD(), "cjq")) {
                    revertWithReason(NOT_ENOUGH_GAS_PROVIDED_ERR_CODE(), 0)
                }
            }

            /// @dev This method returns the overhead that should be paid upfront by a transaction.
            /// The goal of this overhead is to cover the possibility that this transaction may use up a certain
            /// limited resource per batch: a single-instance circuit, etc.
            /// The transaction needs to be able to pay the same % of the costs for publishing & proving the batch
            /// as the % of the batch's limited resources that it can consume.
            /// @param txEncodeLen The length of the ABI-encoding of the transaction
            /// @dev The % following 2 resources is taken into account when calculating the % of the batch's overhead to pay.
            /// 1. Overhead for taking up the bootloader memory. The bootloader memory has a cap on its length, mainly enforced to keep the RAM requirements
            /// for the node smaller. That is, the user needs to pay a share proportional to the length of the ABI encoding of the transaction.
            /// 2. Overhead for taking up a slot for the transaction. Since each batch has the limited number of transactions in it, the user must pay
            /// at least 1/MAX_TRANSACTIONS_IN_BATCH part of the overhead.
            function getTransactionUpfrontOverhead(
                txEncodeLen
            ) -> ret {
                ret := max(
                    safeMul(txEncodeLen, MEMORY_OVERHEAD_GAS(), "iot"),
                    TX_SLOT_OVERHEAD_GAS()
                )
            }

            /// @dev A method where all panics in the nearCalls get to.
            /// It is needed to prevent nearCall panics from bubbling up.
            function ZKSYNC_CATCH_NEAR_CALL() {
                debugLog("ZKSYNC_CATCH_NEAR_CALL",0)
                setHook(VM_HOOK_CATCH_NEAR_CALL())
            }

            /// @dev Prepends the selector before the txDataOffset,
            /// preparing it to be used to call either `verify` or `execute`.
            /// Returns the pointer to the calldata.
            /// Note, that this overrides 32 bytes before the current transaction:
            function prependSelector(txDataOffset, selector) -> ret {

                let calldataPtr := sub(txDataOffset, 4)
                // Note, that since `mstore` stores 32 bytes at once, we need to
                // actually store the selector in one word starting with the
                // (txDataOffset - 32) = (calldataPtr - 28)
                mstore(sub(calldataPtr, 28), selector)

                ret := calldataPtr
            }

            /// @dev Returns the maximum of two numbers
            function max(x, y) -> ret {
                ret := y
                if gt(x, y) {
                    ret := x
                }
            }

            /// @dev Returns the minimum of two numbers
            function min(x, y) -> ret {
                ret := y
                if lt(x, y) {
                    ret := x
                }
            }

            /// @dev Returns constant that is equal to `keccak256("")`
            function EMPTY_STRING_KECCAK() -> ret {
                ret := 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
            }

            /// @dev Returns whether x <= y
            function lte(x, y) -> ret {
                ret := or(lt(x,y), eq(x,y))
            }

            /// @dev Checks whether an address is an account
            /// @param addr The address to check
            function ensureAccount(addr) {
                mstore(0, {{RIGHT_PADDED_GET_ACCOUNT_VERSION_SELECTOR}})
                mstore(4, addr)

                let success := call(
                    gas(),
                    CONTRACT_DEPLOYER_ADDR(),
                    0,
                    0,
                    36,
                    0,
                    32
                )

                let supportedVersion := mload(0)

                if iszero(success) {
                    revertWithReason(
                        FAILED_TO_CHECK_ACCOUNT_ERR_CODE(),
                        1
                    )
                }

                // This method returns AccountAbstractVersion enum.
                // Currently only two versions are supported: 1 or 0, which basically
                // mean whether the contract is an account or not.
                if iszero(supportedVersion) {
                    revertWithReason(
                        FROM_IS_NOT_AN_ACCOUNT_ERR_CODE(),
                        0
                    )
                }
            }

            /// @dev Checks whether an address is an EOA (i.e. has not code deployed on it)
            /// @param addr The address to check
            function isEOA(addr) -> ret {
                ret := 0

                if gt(addr, MAX_SYSTEM_CONTRACT_ADDR()) {
                    ret := iszero(getRawCodeHash(addr, false))
                }
            }

            /// @dev Calls the `payForTransaction` method of an account
            function accountPayForTx(account, txDataOffset) -> success {
                success := callAccountMethod({{PAY_FOR_TX_SELECTOR}}, account, txDataOffset)
            }

            /// @dev Calls the `prepareForPaymaster` method of an account
            function accountPrePaymaster(account, txDataOffset) -> success {
                success := callAccountMethod({{PRE_PAYMASTER_SELECTOR}}, account, txDataOffset)
            }

            /// @dev Calls the `validateAndPayForPaymasterTransaction` method of a paymaster
            function validateAndPayForPaymasterTransaction(paymaster, txDataOffset) -> success {
                success := callAccountMethod({{VALIDATE_AND_PAY_PAYMASTER}}, paymaster, txDataOffset)
            }

            /// @dev Used to call a method with the following signature;
            /// someName(
            ///     bytes32 _txHash,
            ///     bytes32 _suggestedSignedHash,
            ///     Transaction calldata _transaction
            /// )
            // Note, that this method expects that the current tx hashes are already stored
            // in the `CURRENT_L2_TX_HASHES` slots.
            function callAccountMethod(selector, account, txDataOffset) -> success {
                // Safety invariant: it is safe to override data stored under
                // `txDataOffset`, since the account methods are called only using
                // `callAccountMethod` or `callPostOp` methods, both of which reformat
                // the contents before innerTxDataOffset (i.e. txDataOffset + 32 bytes),
                // i.e. make sure that the position at the txDataOffset has valid value.
                let txDataWithHashesOffset := sub(txDataOffset, 64)

                // First word contains the canonical tx hash
                let currentL2TxHashesPtr := CURRENT_L2_TX_HASHES_BEGIN_BYTE()
                mstore(txDataWithHashesOffset, mload(currentL2TxHashesPtr))

                // Second word contains the suggested tx hash for verifying
                // signatures.
                currentL2TxHashesPtr := add(currentL2TxHashesPtr, 32)
                mstore(add(txDataWithHashesOffset, 32), mload(currentL2TxHashesPtr))

                // Third word contains the offset of the main tx data (it is always 96 in our case)
                mstore(add(txDataWithHashesOffset, 64), 96)

                let calldataPtr := prependSelector(txDataWithHashesOffset, selector)
                let innerTxDataOffset := add(txDataOffset, 32)

                let len := getDataLength(innerTxDataOffset)

                // Besides the length of the transaction itself,
                // we also require 3 words for hashes and the offset
                // of the inner tx data.
                let fullLen := add(len, 100)

                // The call itself.
                success := call(
                    gas(), // The number of gas to pass.
                    account, // The address to call.
                    0, // The `value` to pass.
                    calldataPtr, // The pointer to the calldata.
                    fullLen, // The size of the calldata, which is 4 for the selector + the actual length of the struct.
                    0, // The pointer where the returned data will be written.
                    0 // The output has size of 32 (a single bool is expected)
                )
            }

            /// @dev Calculates and saves the explorer hash and the suggested signed hash for the transaction.
            function saveTxHashes(txDataOffset) {
                let calldataPtr := prependSelector(txDataOffset, {{GET_TX_HASHES_SELECTOR}})
                let innerTxDataOffset := add(txDataOffset, 32)

                let len := getDataLength(innerTxDataOffset)

                // The first word is formal, but still required by the ABI
                // We also should take into account the selector.
                let fullLen := add(len, 36)

                // The call itself.
                let success := call(
                    gas(), // The number of gas to pass.
                    BOOTLOADER_UTILITIES(), // The address to call.
                    0, // The `value` to pass.
                    calldataPtr, // The pointer to the calldata.
                    fullLen, // The size of the calldata, which is 4 for the selector + the actual length of the struct.
                    CURRENT_L2_TX_HASHES_BEGIN_BYTE(), // The pointer where the returned data will be written.
                    64 // The output has size of 32 (signed tx hash and explorer tx hash are expected)
                )

                if iszero(success) {
                    revertWithReason(
                        ACCOUNT_TX_VALIDATION_ERR_CODE(),
                        1
                    )
                }

                if iszero(eq(returndatasize(), 64)) {
                    assertionError("saveTxHashes: returndata invalid")
                }
            }

            /// @dev Encodes and calls the postOp method of the contract.
            /// Note, that it *breaks* the contents of the previous transactions.
            /// @param abi The near call ABI of the call
            /// @param paymaster The address of the paymaster
            /// @param txDataOffset The offset to the ABI-encoded Transaction struct.
            /// @param txResult The status of the transaction (1 if succeeded, 0 otherwise).
            /// @param maxRefundedGas The maximum number of gas the bootloader can be refunded.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            /// @param reservedGas The amount of gas reserved for the pubdata.            
            /// This is the `maximum` number because it does not take into account the number of gas that
            /// can be spent by the paymaster itself.
            function ZKSYNC_NEAR_CALL_callPostOp(
                abi,
                paymaster,
                txDataOffset,
                txResult,
                maxRefundedGas,
                basePubdataSpent,
                gasPerPubdata,
                reservedGas,
            ) -> success {
                // The postOp method has the following signature:
                // function postTransaction(
                //     bytes calldata _context,
                //     Transaction calldata _transaction,
                //     bytes32 _txHash,
                //     bytes32 _suggestedSignedHash,
                //     ExecutionResult _txResult,
                //     uint256 _maxRefundedGas
                // ) external payable;
                // The encoding is the following:
                // 1. Offset to the _context's content. (32 bytes)
                // 2. Offset to the _transaction's content. (32 bytes)
                // 3. _txHash (32 bytes)
                // 4. _suggestedSignedHash (32 bytes)
                // 5. _txResult (32 bytes)
                // 6. _maxRefundedGas (32 bytes)
                // 7. _context (note, that the content must be padded to 32 bytes)
                // 8. _transaction

                let contextLen := mload(PAYMASTER_CONTEXT_BEGIN_BYTE())
                let paddedContextLen := lengthRoundedByWords(contextLen)
                // The length of selector + the first 7 fields (with context len) + context itself.
                let preTxLen := add(228, paddedContextLen)

                let innerTxDataOffset := add(txDataOffset, 32)
                let calldataPtr := sub(innerTxDataOffset, preTxLen)

                {
                    let ptr := calldataPtr

                    // Selector
                    mstore(ptr, {{RIGHT_PADDED_POST_TRANSACTION_SELECTOR}})
                    ptr := add(ptr, 4)

                    // context ptr
                    mstore(ptr, 192) // The context always starts at 32 * 6 position
                    ptr := add(ptr, 32)

                    // transaction ptr
                    mstore(ptr, sub(innerTxDataOffset, add(calldataPtr, 4)))
                    ptr := add(ptr, 32)

                    // tx hash
                    mstore(ptr, mload(CURRENT_L2_TX_HASHES_BEGIN_BYTE()))
                    ptr := add(ptr, 32)

                    // suggested signed hash
                    mstore(ptr, mload(add(CURRENT_L2_TX_HASHES_BEGIN_BYTE(), 32)))
                    ptr := add(ptr, 32)

                    // tx result
                    mstore(ptr, txResult)
                    ptr := add(ptr, 32)

                    // maximal refunded gas
                    mstore(ptr, maxRefundedGas)
                    ptr := add(ptr, 32)

                    // storing context itself
                    memCopy(PAYMASTER_CONTEXT_BEGIN_BYTE(), ptr, add(32, paddedContextLen))
                    ptr := add(ptr, add(32, paddedContextLen))

                    // At this point, the ptr should reach the innerTxDataOffset.
                    // If not, we have done something wrong here.
                    if iszero(eq(ptr, innerTxDataOffset)) {
                        assertionError("postOp: ptr != innerTxDataOffset")
                    }

                    // no need to store the transaction as from the innerTxDataOffset starts
                    // valid encoding of the transaction
                }

                let calldataLen := safeAdd(preTxLen, getDataLength(innerTxDataOffset), "jiq")

                success := call(
                    gas(),
                    paymaster,
                    0,
                    calldataPtr,
                    calldataLen,
                    0,
                    0
                )

                if isNotEnoughGasForPubdata(
                    basePubdataSpent,
                    gas(),
                    reservedGas,
                    gasPerPubdata,
                ) {
                    // If not enough gas for pubdata was provided, we revert all the state diffs / messages
                    // that caused the pubdata to be published
                    nearCallPanic()
                }
            }

            /// @dev Copies [from..from+len] to [to..to+len]
            /// Note, that len must be divisible by 32.
            function memCopy(from, to, len) {
                // Ensuring that len is always divisible by 32.
                if mod(len, 32) {
                    assertionError("Memcopy with unaligned length")
                }

                let finalFrom := safeAdd(from, len, "cka")

                for { } lt(from, finalFrom) {
                    from := add(from, 32)
                    to := add(to, 32)
                } {
                    mstore(to, mload(from))
                }
            }

            /// @dev Validates the transaction against the senders' account.
            /// Besides ensuring that the contract agrees to a transaction,
            /// this method also enforces that the nonce has been marked as used.
            function accountValidateTx(txDataOffset) {
                // Skipping the first 0x20 word of the ABI-encoding of the struct
                let innerTxDataOffset := add(txDataOffset, 32)
                let from := getFrom(innerTxDataOffset)
                ensureAccount(from)

                // The nonce should be unique for each transaction.
                let nonce := getNonce(innerTxDataOffset)
                // Here we check that this nonce was not available before the validation step
                ensureNonceUsage(from, nonce, 0)

                setHook(VM_HOOK_ACCOUNT_VALIDATION_ENTERED())
                debugLog("pre-validate",0)
                debugLog("pre-validate",from)
                let success := callAccountMethod({{VALIDATE_TX_SELECTOR}}, from, txDataOffset)
                setHook(VM_HOOK_NO_VALIDATION_ENTERED())

                if iszero(success) {
                    revertWithReason(
                        ACCOUNT_TX_VALIDATION_ERR_CODE(),
                        1
                    )
                }

                ensureCorrectAccountMagic()

                // Here we make sure that the nonce is no longer available after the validation step
                ensureNonceUsage(from, nonce, 1)
            }

            /// @dev Ensures that the magic returned by the validate account method is correct
            /// It must be called right after the call of the account validation method to preserve the
            /// correct returndatasize
            function ensureCorrectAccountMagic() {
                // It is expected that the returned value is ABI-encoded bytes4 magic value
                // The Solidity always pads such value to 32 bytes and so we expect the magic to be
                // of length 32
                if iszero(eq(32, returndatasize())) {
                    revertWithReason(
                        ACCOUNT_RETURNED_INVALID_MAGIC_ERR_CODE(),
                        0
                    )
                }

                // Note that it is important to copy the magic even though it is not needed if the
                // `SHOULD_ENSURE_CORRECT_RETURNED_MAGIC` is false. It is never false in production
                // but it is so in fee estimation and we want to preserve as many operations as
                // in the original operation.
                returndatacopy(0, 0, 32)
                let returnedValue := mload(0)
                let isMagicCorrect := eq(returnedValue, {{SUCCESSFUL_ACCOUNT_VALIDATION_MAGIC_VALUE}})

                if and(iszero(isMagicCorrect), SHOULD_ENSURE_CORRECT_RETURNED_MAGIC()) {
                    revertWithReason(
                        ACCOUNT_RETURNED_INVALID_MAGIC_ERR_CODE(),
                        0
                    )
                }
            }

            /// @dev Calls the KnownCodesStorage system contract to mark the factory dependencies of
            /// the transaction as known.
            function markFactoryDepsForTx(innerTxDataOffset, isL1Tx) {
                debugLog("starting factory deps", 0)
                let factoryDepsPtr := getFactoryDepsPtr(innerTxDataOffset)
                let factoryDepsLength := mload(factoryDepsPtr)

                if gt(factoryDepsLength, MAX_NEW_FACTORY_DEPS()) {
                    assertionError("too many factory deps")
                }

                let ptr := NEW_FACTORY_DEPS_BEGIN_BYTE()
                // Selector
                mstore(ptr, {{MARK_BATCH_AS_REPUBLISHED_SELECTOR}})
                ptr := add(ptr, 32)

                // Saving whether the dependencies should be sent on L1
                // There is no need to send them for L1 transactions, since their
                // preimages are already available on L1.
                mstore(ptr, iszero(isL1Tx))
                ptr := add(ptr, 32)

                // Saving the offset to array (it is always 64)
                mstore(ptr, 64)
                ptr := add(ptr, 32)

                // Saving the array

                // We also need to include 32 bytes for the length itself
                let arrayLengthBytes := safeAdd(32, safeMul(factoryDepsLength, 32, "ag"), "af")
                // Copying factory deps array
                memCopy(factoryDepsPtr, ptr, arrayLengthBytes)

                let success := call(
                    gas(),
                    KNOWN_CODES_CONTRACT_ADDR(),
                    0,
                    // Shifting by 28 to start from the selector
                    add(NEW_FACTORY_DEPS_BEGIN_BYTE(), 28),
                    // 4 (selector) + 32 (send to l1 flag) + 32 (factory deps offset)+ 32 (factory deps length)
                    safeAdd(100, safeMul(factoryDepsLength, 32, "op"), "ae"),
                    0,
                    0
                )

                debugLog("factory deps success", success)

                if iszero(success) {
                    debugReturndata()
                    switch isL1Tx
                    case 1 {
                        revertWithReason(
                            FAILED_TO_MARK_FACTORY_DEPS(),
                            1
                        )
                    }
                    default {
                        // For L2 transactions, we use near call panic
                        nearCallPanic()
                    }
                }
            }

            /// @dev Function responsible for executing the L1->L2 transactions.
            function executeL1Tx(innerTxDataOffset, from) -> ret {
                let to := getTo(innerTxDataOffset)
                debugLog("to", to)
                let value := getValue(innerTxDataOffset)
                debugLog("value", value)
                let dataPtr := getDataPtr(innerTxDataOffset)

                ret := msgValueSimulatorMimicCall(
                    to,
                    from,
                    value,
                    dataPtr
                )

                if iszero(ret) {
                    debugReturndata()
                }
            }

            /// @dev Function responsible for the execution of the L2 transaction
            /// @dev Returns `true` or `false` depending on whether or not the tx has reverted.
            function executeL2Tx(txDataOffset, from) -> ret {
                ret := callAccountMethod({{EXECUTE_TX_SELECTOR}}, from, txDataOffset)

                if iszero(ret) {
                    debugReturndata()
                }
            }

            ///
            /// zkSync-specific utilities:
            ///

            /// @dev Returns an ABI that can be used for low-level
            /// invocations of calls and mimicCalls
            /// @param dataPtr The pointer to the calldata.
            /// @param gasPassed The number of gas to be passed with the call.
            /// @param shardId The shard id of the callee. Currently only `0` (Rollup) is supported.
            /// @param forwardingMode The mode of how the calldata is forwarded
            /// It is possible to either pass a pointer, slice of auxheap or heap. For the
            /// bootloader purposes using heap (0) is enough.
            /// @param isConstructorCall Whether the call should contain the isConstructor flag.
            /// @param isSystemCall Whether the call should contain the isSystemCall flag.
            /// @return ret The ABI
            function getFarCallABI(
                dataPtr,
                gasPassed,
                shardId,
                forwardingMode,
                isConstructorCall,
                isSystemCall
            ) -> ret {
                let dataStart := add(dataPtr, 32)
                let dataLength := mload(dataPtr)

                // Skip dataOffset and memoryPage, because they are always zeros
                ret := or(ret, shl(64, dataStart))
                ret := or(ret, shl(96, dataLength))

                ret := or(ret, shl(192, gasPassed))
                ret := or(ret, shl(224, forwardingMode))
                ret := or(ret, shl(232, shardId))
                ret := or(ret, shl(240, isConstructorCall))
                ret := or(ret, shl(248, isSystemCall))
            }

            /// @dev Does mimicCall without copying the returndata.
            /// @param to Who to call
            /// @param whoToMimic The `msg.sender` of the call
            /// @param data The pointer to the calldata
            /// @param isConstructor Whether the call should contain the isConstructor flag
            /// @param isSystemCall Whether the call should contain the isSystem flag.
            /// @param extraAbi1 The first extraAbiParam
            /// @param extraAbi2 The second extraAbiParam
            /// @param extraAbi3 The third extraAbiParam
            /// @return ret 1 if the call was successful, 0 otherwise.
            function mimicCallOnlyResult(
                to,
                whoToMimic,
                data,
                isConstructor,
                isSystemCall,
                extraAbi1,
                extraAbi2,
                extraAbi3
            ) -> ret {
                let farCallAbi := getFarCallABI(
                    data,
                    gas(),
                    // Only rollup is supported for now
                    0,
                    0,
                    isConstructor,
                    isSystemCall
                )

                ret := verbatim_7i_1o("system_mimic_call", to, whoToMimic, farCallAbi, extraAbi1, extraAbi2, extraAbi3, 0)
            }

            <!-- @if BOOTLOADER_TYPE=='playground_batch' -->
            // Extracts the required byte from the 32-byte word.
            // 31 would mean the MSB, 0 would mean LSB.
            function getWordByte(word, byteIdx) -> ret {
                // Shift the input to the right so the required byte is LSB
                ret := shr(mul(8, byteIdx), word)
                // Clean everything else in the word
                ret := and(ret, 0xFF)
            }
            <!-- @endif -->


            /// @dev Sends a L2->L1 log using L1Messengers' `sendL2ToL1Log`.
            /// @param isService The isService flag of the call.
            /// @param key The `key` parameter of the log.
            /// @param value The `value` parameter of the log.
            function sendL2LogUsingL1Messenger(isService, key, value) {
                mstore(0, {{RIGHT_PADDED_SEND_L2_TO_L1_LOG_SELECTOR}})
                mstore(4, isService)
                mstore(36, key)
                mstore(68, value)

                let success := call(
                    gas(),
                    L1_MESSENGER_ADDR(),
                    0,
                    0,
                    100,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("Failed to send L1Messenger L2Log", key)
                    debugLog("Failed to send L1Messenger L2Log", value)

                    revertWithReason(L1_MESSENGER_LOG_SENDING_FAILED_ERR_CODE(), 1)
                }
            }

            /// @dev Sends a native (VM) L2->L1 log.
            /// @param isService The isService flag of the call.
            /// @param key The `key` parameter of the log.
            /// @param value The `value` parameter of the log.
            function sendToL1Native(isService, key, value) {
                verbatim_3i_0o("to_l1", isService, key, value)
            }

            /// @notice Performs L1 Messenger pubdata "publishing" call.
            /// @dev Expected to be used at the end of the batch.
            function l1MessengerPublishingCall() {
                let ptr := OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_BEGIN_BYTE()
                debugLog("Publishing batch data to L1", 0)
                // First slot (only last 4 bytes) -- selector
                mstore(ptr, {{PUBLISH_PUBDATA_SELECTOR}})
                // Second slot -- offset
                mstore(add(ptr, 32), 32)
                setHook(VM_HOOK_PUBDATA_REQUESTED())
                // Third slot -- length of pubdata
                let len := mload(add(ptr, 64))
                // 4 bytes for selector, 32 bytes for array offset and 32 bytes for array length
                let fullLen := add(len, 68)

                // ptr + 28 because the function selector only takes up the last 4 bytes in the first slot.
                let success := call(
                    gas(),
                    L1_MESSENGER_ADDR(),
                    0,
                    add(ptr, 28),
                    fullLen,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("Failed to publish L2Logs data", 0)

                    revertWithReason(L1_MESSENGER_PUBLISHING_FAILED_ERR_CODE(), 1)
                }
            }

            function publishTimestampDataToL1() {
                debugLog("Publishing timestamp data to L1", 0)

                mstore(0, {{RIGHT_PADDED_PUBLISH_TIMESTAMP_DATA_TO_L1_SELECTOR}})
                let success := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    4,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("Failed publish timestamp to L1", 0)
                    revertWithReason(FAILED_TO_PUBLISH_TIMESTAMP_DATA_TO_L1(), 1)
                }
            }

            /// @notice Performs a call of a System Context
            /// method that have no input parameters
            function callSystemContext(paddedSelector) {
                mstore(0, paddedSelector)

                let success := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    4,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("Failed to call System Context", 0)

                    revertWithReason(FAILED_TO_CALL_SYSTEM_CONTEXT_ERR_CODE(), 1)
                }
            }

            /// @dev Increment the number of txs in the batch
            function considerNewTx() {
                verbatim_0i_0o("increment_tx_counter")

                callSystemContext({{RIGHT_PADDED_INCREMENT_TX_NUMBER_IN_BLOCK_SELECTOR}})
            }

            function $llvm_NoInline_llvm$_getMeta() -> ret {
                ret := verbatim_0i_1o("meta")
            }

            function getPubdataCounter() -> ret {
                ret := and($llvm_NoInline_llvm$_getMeta(), 0xFFFFFFFF)
            }

            function getCurrentPubdataSpent(basePubdataSpent) -> ret {
                let currentPubdataCounter := getPubdataCounter()
                debugLog("basePubdata", basePubdataSpent)
                debugLog("currentPubdata", currentPubdataCounter)
                ret := saturatingSub(currentPubdataCounter, basePubdataSpent)
            }

            function getErgsSpentForPubdata(
                basePubdataSpent,
                gasPerPubdata,
            ) -> ret {
                ret := safeMul(getCurrentPubdataSpent(basePubdataSpent), gasPerPubdata, "mul: getErgsSpentForPubdata")
            }

            /// @dev Compares the amount of spent ergs on the pubdatawith the allowed amount.
            /// @param basePubdataSpent The amount of pubdata spent at the beginning of the transaction.
            /// @param computeGas The amount of execution gas remaining that can still be spent on future computation.
            /// @param reservedGas The amount of gas reserved for the pubdata.
            /// @param gasPerPubdata The price of each byte of pubdata in L2 gas.
            /// @return ret Whether the amount of pubdata spent so far is valid and
            /// and can be covered by the user.
            function isNotEnoughGasForPubdata(
                basePubdataSpent,
                computeGas,
                reservedGas,
                gasPerPubdata
            ) -> ret {
                let spentErgs := getErgsSpentForPubdata(basePubdataSpent, gasPerPubdata)
                debugLog("spentErgsPubdata", spentErgs)
                let allowedGasLimit := add(computeGas, reservedGas)
                
                ret := lt(allowedGasLimit, spentErgs)
            }

            /// @dev Set the new value for the tx origin context value
            function setTxOrigin(newTxOrigin) {
                let success := setContextVal({{RIGHT_PADDED_SET_TX_ORIGIN}}, newTxOrigin)

                if iszero(success) {
                    debugLog("Failed to set txOrigin", newTxOrigin)
                    nearCallPanic()
                }
            }

            /// @dev Set the new value for the gas price value
            function setGasPrice(newGasPrice) {
                let success := setContextVal({{RIGHT_PADDED_SET_GAS_PRICE}}, newGasPrice)

                if iszero(success) {
                    debugLog("Failed to set gas price", newGasPrice)
                    nearCallPanic()
                }
            }

            /// @dev Sets the gas per pubdata byte value in the `SystemContext` contract.
            /// @param newGasPerPubdata The amount L2 gas that the operator charge the user for single byte of pubdata.
            /// @param basePubdataSpent The number of pubdata spent as of the start of the transaction.
            /// @notice Note that it has no actual impact on the execution of the contract.
            function setPubdataInfo(
                newGasPerPubdata,
                basePubdataSpent
            ) {
                mstore(0, {{RIGHT_PADDED_SET_PUBDATA_INFO}})
                mstore(4, newGasPerPubdata)
                mstore(36, basePubdataSpent)

                let success := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    68,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("setPubdataInfo failed", newGasPerPubdata)
                    assertionError("setPubdataInfo failed")
                }
            }

            /// @notice Sets the context information for the current batch.
            /// @dev The SystemContext.sol system contract is responsible for validating
            /// the validity of the new batch's data.
            function setNewBatch(prevBatchHash, newTimestamp, newBatchNumber, baseFee) {
                mstore(0, {{RIGHT_PADDED_SET_NEW_BATCH_SELECTOR}})
                mstore(4, prevBatchHash)
                mstore(36, newTimestamp)
                mstore(68, newBatchNumber)
                mstore(100, baseFee)

                let success := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    132,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("Failed to set new batch: ", prevBatchHash)
                    debugLog("Failed to set new batch: ", newTimestamp)

                    revertWithReason(FAILED_TO_SET_NEW_BATCH_ERR_CODE(), 1)
                }
            }

            /// @notice Sets the context information for the current L2 block.
            /// @param txId The index of the transaction in the batch for which to get the L2 block information.
            function setL2Block(txId) {
                let txL2BlockPosition := add(TX_OPERATOR_L2_BLOCK_INFO_BEGIN_BYTE(), mul(TX_OPERATOR_L2_BLOCK_INFO_SIZE_BYTES(), txId))

                let currentL2BlockNumber := mload(txL2BlockPosition)
                let currentL2BlockTimestamp := mload(add(txL2BlockPosition, 32))
                let previousL2BlockHash := mload(add(txL2BlockPosition, 64))
                let virtualBlocksToCreate := mload(add(txL2BlockPosition, 96))

                let isFirstInBatch := iszero(txId)

                debugLog("Setting new L2 block: ", currentL2BlockNumber)
                debugLog("Setting new L2 block: ", currentL2BlockTimestamp)
                debugLog("Setting new L2 block: ", previousL2BlockHash)
                debugLog("Setting new L2 block: ", virtualBlocksToCreate)

                mstore(0, {{RIGHT_PADDED_SET_L2_BLOCK_SELECTOR}})
                mstore(4, currentL2BlockNumber)
                mstore(36, currentL2BlockTimestamp)
                mstore(68, previousL2BlockHash)
                mstore(100, isFirstInBatch)
                mstore(132, virtualBlocksToCreate)

                let success := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    164,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("Failed to set new L2 block: ", currentL2BlockNumber)
                    debugLog("Failed to set new L2 block: ", currentL2BlockTimestamp)
                    debugLog("Failed to set new L2 block: ", previousL2BlockHash)
                    debugLog("Failed to set new L2 block: ", isFirstInBatch)

                    revertWithReason(FAILED_TO_SET_L2_BLOCK(), 1)
                }
            }

            /// @notice Appends the transaction hash to the current L2 block.
            /// @param txHash The hash of the transaction to append.
            /// @param isL1Tx Whether the transaction is an L1 transaction. If it is an L1 transaction,
            /// and this method fails, then the bootloader execution will be explicitly reverted.
            /// Otherwise, the nearCallPanic will be used to implicitly fail the validation of the transaction.
            function appendTransactionHash(
                txHash,
                isL1Tx
            ) {
                debugLog("Appending tx to L2 block", txHash)

                mstore(0, {{RIGHT_PADDED_APPEND_TRANSACTION_TO_L2_BLOCK_SELECTOR}})
                mstore(4, txHash)

                let success := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    36,
                    0,
                    0
                )

                if iszero(success) {
                    debugReturndata()
                    switch isL1Tx
                    case 1 {
                        revertWithReason(
                            FAILED_TO_APPEND_TRANSACTION_TO_L2_BLOCK(),
                            1
                        )
                    }
                    default {
                        // For L2 transactions, we use near call panic, it will trigger the validation
                        // step of the transaction to fail, returning a consistent error message.
                        nearCallPanic()
                    }
                }
            }

            <!-- @if BOOTLOADER_TYPE=='playground_batch' -->
            /// @notice Arbitrarily overrides the current batch information.
            /// @dev It should NOT be available in the proved batch.
            function unsafeOverrideBatch(newTimestamp, newBatchNumber, baseFee) {
                mstore(0, {{RIGHT_PADDED_OVERRIDE_BATCH_SELECTOR}})
                mstore(4, newTimestamp)
                mstore(36, newBatchNumber)
                mstore(68, baseFee)

                let success := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    100,
                    0,
                    0
                )

                if iszero(success) {
                    debugLog("Failed to override batch: ", newTimestamp)
                    debugLog("Failed to override batch: ", newBatchNumber)

                    revertWithReason(FAILED_TO_SET_NEW_BATCH_ERR_CODE(), 1)
                }
            }
            <!-- @endif -->


            // Checks whether the nonce `nonce` have been already used for
            // account `from`. Reverts if the nonce has not been used properly.
            function ensureNonceUsage(from, nonce, shouldNonceBeUsed) {
                // INonceHolder.validateNonceUsage selector
                mstore(0, {{RIGHT_PADDED_VALIDATE_NONCE_USAGE_SELECTOR}})
                mstore(4, from)
                mstore(36, nonce)
                mstore(68, shouldNonceBeUsed)

                let success := call(
                    gas(),
                    NONCE_HOLDER_ADDR(),
                    0,
                    0,
                    100,
                    0,
                    0
                )

                if iszero(success) {
                    revertWithReason(
                        ACCOUNT_TX_VALIDATION_ERR_CODE(),
                        1
                    )
                }
            }

            /// @dev Encodes and performs a call to a method of
            /// `SystemContext.sol` system contract of the roughly the following interface:
            /// someMethod(uint256 val)
            function setContextVal(
                selector,
                value,
            ) -> ret {
                mstore(0, selector)
                mstore(4, value)

                ret := call(
                    gas(),
                    SYSTEM_CONTEXT_ADDR(),
                    0,
                    0,
                    36,
                    0,
                    0
                )
            }

            // Each of the txs have the following type:
            // struct Transaction {
            //     // The type of the transaction.
            //     uint256 txType;
            //     // The caller.
            //     uint256 from;
            //     // The callee.
            //     uint256 to;
            //     // The gasLimit to pass with the transaction.
            //     // It has the same meaning as Ethereum's gasLimit.
            //     uint256 gasLimit;
            //     // The maximum amount of gas the user is willing to pay for a byte of pubdata.
            //     uint256 gasPerPubdataByteLimit;
            //     // The maximum fee per gas that the user is willing to pay.
            //     // It is akin to EIP1559's maxFeePerGas.
            //     uint256 maxFeePerGas;
            //     // The maximum priority fee per gas that the user is willing to pay.
            //     // It is akin to EIP1559's maxPriorityFeePerGas.
            //     uint256 maxPriorityFeePerGas;
            //     // The transaction's paymaster. If there is no paymaster, it is equal to 0.
            //     uint256 paymaster;
            //     // The nonce of the transaction.
            //     uint256 nonce;
            //     // The value to pass with the transaction.
            //     uint256 value;
            //     // In the future, we might want to add some
            //     // new fields to the struct. The `txData` struct
            //     // is to be passed to account and any changes to its structure
            //     // would mean a breaking change to these accounts. In order to prevent this,
            //     // we should keep some fields as "reserved".
            //     // It is also recommended that their length is fixed, since
            //     // it would allow easier proof integration (in case we will need
            //     // some special circuit for preprocessing transactions).
            //     uint256[4] reserved;
            //     // The transaction's calldata.
            //     bytes data;
            //     // The signature of the transaction.
            //     bytes signature;
            //     // The properly formatted hashes of bytecodes that must be published on L1
            //     // with the inclusion of this transaction. Note, that a bytecode has been published
            //     // before, the user won't pay fees for its republishing.
            //     bytes32[] factoryDeps;
            //     // The input to the paymaster.
            //     bytes paymasterInput;
            //     // Reserved dynamic type for the future use-case. Using it should be avoided,
            //     // But it is still here, just in case we want to enable some additional functionality.
            //     bytes reservedDynamic;
            // }

            /// @notice Asserts the equality of two values and reverts
            /// with the appropriate error message in case it doesn't hold
            /// @param value1 The first value of the assertion
            /// @param value2 The second value of the assertion
            /// @param message The error message
            function assertEq(value1, value2, message) {
                switch eq(value1, value2)
                    case 0 { assertionError(message) }
                    default { }
            }

            /// @notice Makes sure that the structure of the transaction is set in accordance to its type
            /// @dev This function validates only L2 transactions, since the integrity of the L1->L2
            /// transactions is enforced by the L1 smart contracts.
            function validateTypedTxStructure(innerTxDataOffset) {
                /// Some common checks for all transactions.
                let reservedDynamicLength := getReservedDynamicBytesLength(innerTxDataOffset)
                if gt(reservedDynamicLength, 0) {
                    assertionError("non-empty reservedDynamic")
                }
                let txType := getTxType(innerTxDataOffset)
                switch txType
                    case 0 {
                        let maxFeePerGas := getMaxFeePerGas(innerTxDataOffset)
                        let maxPriorityFeePerGas := getMaxPriorityFeePerGas(innerTxDataOffset)
                        assertEq(maxFeePerGas, maxPriorityFeePerGas, "EIP1559 params wrong")

                        <!-- @if BOOTLOADER_TYPE!='playground_batch' -->

                        let from := getFrom(innerTxDataOffset)
                        let iseoa := isEOA(from)
                        assertEq(iseoa, true, "Only EIP-712 can use non-EOA")

                        <!-- @endif -->

                        // Here, for type 0 transactions the reserved0 field is used as a marker
                        // whether the transaction should include chainId in its encoding.
                        assertEq(lte(getGasPerPubdataByteLimit(innerTxDataOffset), MAX_L2_GAS_PER_PUBDATA()), 1, "Gas per pubdata is wrong")
                        assertEq(getPaymaster(innerTxDataOffset), 0, "paymaster non zero")

                        <!-- @if BOOTLOADER_TYPE=='proved_batch' -->
                        assertEq(gt(getFrom(innerTxDataOffset), MAX_SYSTEM_CONTRACT_ADDR()), 1, "from in kernel space")
                        <!-- @endif -->

                        assertEq(getReserved1(innerTxDataOffset), 0, "reserved1 non zero")
                        assertEq(getReserved2(innerTxDataOffset), 0, "reserved2 non zero")
                        assertEq(getReserved3(innerTxDataOffset), 0, "reserved3 non zero")
                        assertEq(getFactoryDepsBytesLength(innerTxDataOffset), 0, "factory deps non zero")
                        assertEq(getPaymasterInputBytesLength(innerTxDataOffset), 0, "paymasterInput non zero")
                    }
                    case 1 {
                        let maxFeePerGas := getMaxFeePerGas(innerTxDataOffset)
                        let maxPriorityFeePerGas := getMaxPriorityFeePerGas(innerTxDataOffset)
                        assertEq(maxFeePerGas, maxPriorityFeePerGas, "EIP1559 params wrong")

                        <!-- @if BOOTLOADER_TYPE!='playground_batch' -->

                        let from := getFrom(innerTxDataOffset)
                        let iseoa := isEOA(from)
                        assertEq(iseoa, true, "Only EIP-712 can use non-EOA")

                        <!-- @endif -->

                        assertEq(lte(getGasPerPubdataByteLimit(innerTxDataOffset), MAX_L2_GAS_PER_PUBDATA()), 1, "Gas per pubdata is wrong")
                        assertEq(getPaymaster(innerTxDataOffset), 0, "paymaster non zero")

                        <!-- @if BOOTLOADER_TYPE=='proved_batch' -->
                        assertEq(gt(getFrom(innerTxDataOffset), MAX_SYSTEM_CONTRACT_ADDR()), 1, "from in kernel space")
                        <!-- @endif -->

                        assertEq(getReserved0(innerTxDataOffset), 0, "reserved0 non zero")
                        assertEq(getReserved1(innerTxDataOffset), 0, "reserved1 non zero")
                        assertEq(getReserved2(innerTxDataOffset), 0, "reserved2 non zero")
                        assertEq(getReserved3(innerTxDataOffset), 0, "reserved3 non zero")
                        assertEq(getFactoryDepsBytesLength(innerTxDataOffset), 0, "factory deps non zero")
                        assertEq(getPaymasterInputBytesLength(innerTxDataOffset), 0, "paymasterInput non zero")
                    }
                    case 2 {
                        assertEq(lte(getGasPerPubdataByteLimit(innerTxDataOffset), MAX_L2_GAS_PER_PUBDATA()), 1, "Gas per pubdata is wrong")
                        assertEq(getPaymaster(innerTxDataOffset), 0, "paymaster non zero")

                        <!-- @if BOOTLOADER_TYPE!='playground_batch' -->

                        let from := getFrom(innerTxDataOffset)
                        let iseoa := isEOA(from)
                        assertEq(iseoa, true, "Only EIP-712 can use non-EOA")

                        <!-- @endif -->

                        <!-- @if BOOTLOADER_TYPE=='proved_batch' -->
                        assertEq(gt(getFrom(innerTxDataOffset), MAX_SYSTEM_CONTRACT_ADDR()), 1, "from in kernel space")
                        <!-- @endif -->

                        assertEq(getReserved0(innerTxDataOffset), 0, "reserved0 non zero")
                        assertEq(getReserved1(innerTxDataOffset), 0, "reserved1 non zero")
                        assertEq(getReserved2(innerTxDataOffset), 0, "reserved2 non zero")
                        assertEq(getReserved3(innerTxDataOffset), 0, "reserved3 non zero")
                        assertEq(getFactoryDepsBytesLength(innerTxDataOffset), 0, "factory deps non zero")
                        assertEq(getPaymasterInputBytesLength(innerTxDataOffset), 0, "paymasterInput non zero")
                    }
                    case 113 {
                        let paymaster := getPaymaster(innerTxDataOffset)
                        assertEq(or(gt(paymaster, MAX_SYSTEM_CONTRACT_ADDR()), iszero(paymaster)), 1, "paymaster in kernel space")

                        if iszero(paymaster) {
                            // Double checking that the paymasterInput is 0 if the paymaster is 0
                            assertEq(getPaymasterInputBytesLength(innerTxDataOffset), 0, "paymasterInput non zero")
                        }

                        <!-- @if BOOTLOADER_TYPE=='proved_batch' -->
                        assertEq(gt(getFrom(innerTxDataOffset), MAX_SYSTEM_CONTRACT_ADDR()), 1, "from in kernel space")
                        <!-- @endif -->
                        assertEq(getReserved0(innerTxDataOffset), 0, "reserved0 non zero")
                        assertEq(getReserved1(innerTxDataOffset), 0, "reserved1 non zero")
                        assertEq(getReserved2(innerTxDataOffset), 0, "reserved2 non zero")
                        assertEq(getReserved3(innerTxDataOffset), 0, "reserved3 non zero")
                    }
                    case 254 {
                        // Upgrade transaction, no need to validate as it is validated on L1.
                    }
                    case 255 {
                        // Double-check that the operator doesn't try to do an upgrade transaction via L1 -> L2 transaction.
                        assertEq(gt(getFrom(innerTxDataOffset), MAX_SYSTEM_CONTRACT_ADDR()), 1, "from in kernel space")
                        // L1 transaction, no need to validate as it is validated on L1.
                    }
                    default {
                        assertionError("Unknown tx type")
                    }
            }

            ///
            /// TransactionData utilities
            ///
            /// @dev The next methods are programmatically generated
            ///

            function getTxType(innerTxDataOffset) -> ret {
                ret := mload(innerTxDataOffset)
            }

            function getFrom(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 32))
            }

            function getTo(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 64))
            }

            function getGasLimit(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 96))
            }

            function getGasPerPubdataByteLimit(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 128))
            }

            function getMaxFeePerGas(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 160))
            }

            function getMaxPriorityFeePerGas(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 192))
            }

            function getPaymaster(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 224))
            }

            function getNonce(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 256))
            }

            function getValue(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 288))
            }

            function getReserved0(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 320))
            }

            function getReserved1(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 352))
            }

            function getReserved2(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 384))
            }

            function getReserved3(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 416))
            }

            function getDataPtr(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 448))
                ret := add(innerTxDataOffset, ret)
            }

            function getDataBytesLength(innerTxDataOffset) -> ret {
                let ptr := getDataPtr(innerTxDataOffset)
                ret := lengthRoundedByWords(mload(ptr))
            }

            function getSignaturePtr(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 480))
                ret := add(innerTxDataOffset, ret)
            }

            function getSignatureBytesLength(innerTxDataOffset) -> ret {
                let ptr := getSignaturePtr(innerTxDataOffset)
                ret := lengthRoundedByWords(mload(ptr))
            }

            function getFactoryDepsPtr(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 512))
                ret := add(innerTxDataOffset, ret)
            }

            function getFactoryDepsBytesLength(innerTxDataOffset) -> ret {
                let ptr := getFactoryDepsPtr(innerTxDataOffset)
                ret := safeMul(mload(ptr),32, "fwop")
            }

            function getPaymasterInputPtr(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 544))
                ret := add(innerTxDataOffset, ret)
            }

            function getPaymasterInputBytesLength(innerTxDataOffset) -> ret {
                let ptr := getPaymasterInputPtr(innerTxDataOffset)
                ret := lengthRoundedByWords(mload(ptr))
            }

            function getReservedDynamicPtr(innerTxDataOffset) -> ret {
                ret := mload(add(innerTxDataOffset, 576))
                ret := add(innerTxDataOffset, ret)
            }

            function getReservedDynamicBytesLength(innerTxDataOffset) -> ret {
                let ptr := getReservedDynamicPtr(innerTxDataOffset)
                ret := lengthRoundedByWords(mload(ptr))
            }

            /// This method checks that the transaction's structure is correct
            /// and tightly packed
            function validateAbiEncoding(txDataOffset) -> ret {
                if iszero(eq(mload(txDataOffset), 32)) {
                    assertionError("Encoding offset")
                }

                let innerTxDataOffset := add(txDataOffset, 32)

                let fromValue := getFrom(innerTxDataOffset)
                if iszero(validateAddress(fromValue)) {
                    assertionError("Encoding from")
                }

                let toValue := getTo(innerTxDataOffset)
                if iszero(validateAddress(toValue)) {
                    assertionError("Encoding to")
                }

                let gasLimitValue := getGasLimit(innerTxDataOffset)
                if iszero(validateUint64(gasLimitValue)) {
                    assertionError("Encoding gasLimit")
                }

                let gasPerPubdataByteLimitValue := getGasPerPubdataByteLimit(innerTxDataOffset)
                if iszero(validateUint32(gasPerPubdataByteLimitValue)) {
                    assertionError("Encoding gasPerPubdataByteLimit")
                }

                let maxFeePerGas := getMaxFeePerGas(innerTxDataOffset)
                if iszero(validateUint128(maxFeePerGas)) {
                    assertionError("Encoding maxFeePerGas")
                }

                let maxPriorityFeePerGas := getMaxPriorityFeePerGas(innerTxDataOffset)
                if iszero(validateUint128(maxPriorityFeePerGas)) {
                    assertionError("Encoding maxPriorityFeePerGas")
                }

                let paymasterValue := getPaymaster(innerTxDataOffset)
                if iszero(validateAddress(paymasterValue)) {
                    assertionError("Encoding paymaster")
                }

                let expectedDynamicLenPtr := add(innerTxDataOffset, 608)

                let dataLengthPos := getDataPtr(innerTxDataOffset)
                if iszero(eq(dataLengthPos, expectedDynamicLenPtr)) {
                    assertionError("Encoding data")
                }
                expectedDynamicLenPtr := validateBytes(dataLengthPos)

                let signatureLengthPos := getSignaturePtr(innerTxDataOffset)
                if iszero(eq(signatureLengthPos, expectedDynamicLenPtr)) {
                    assertionError("Encoding signature")
                }
                expectedDynamicLenPtr := validateBytes(signatureLengthPos)

                let factoryDepsLengthPos := getFactoryDepsPtr(innerTxDataOffset)
                if iszero(eq(factoryDepsLengthPos, expectedDynamicLenPtr)) {
                    assertionError("Encoding factoryDeps")
                }
                expectedDynamicLenPtr := validateBytes32Array(factoryDepsLengthPos)

                let paymasterInputLengthPos := getPaymasterInputPtr(innerTxDataOffset)
                if iszero(eq(paymasterInputLengthPos, expectedDynamicLenPtr)) {
                    assertionError("Encoding paymasterInput")
                }
                expectedDynamicLenPtr := validateBytes(paymasterInputLengthPos)

                let reservedDynamicLengthPos := getReservedDynamicPtr(innerTxDataOffset)
                if iszero(eq(reservedDynamicLengthPos, expectedDynamicLenPtr)) {
                    assertionError("Encoding reservedDynamic")
                }
                expectedDynamicLenPtr := validateBytes(reservedDynamicLengthPos)

                ret := expectedDynamicLenPtr
            }

            function getDataLength(innerTxDataOffset) -> ret {
                // To get the length of the txData in bytes, we can simply
                // get the number of fields * 32 + the length of the dynamic types
                // in bytes.
                ret := 768

                ret := safeAdd(ret, getDataBytesLength(innerTxDataOffset), "asx")
                ret := safeAdd(ret, getSignatureBytesLength(innerTxDataOffset), "qwqa")
                ret := safeAdd(ret, getFactoryDepsBytesLength(innerTxDataOffset), "sic")
                ret := safeAdd(ret, getPaymasterInputBytesLength(innerTxDataOffset), "tpiw")
                ret := safeAdd(ret, getReservedDynamicBytesLength(innerTxDataOffset), "shy")
            }

            ///
            /// End of programmatically generated code
            ///

            /// @dev Accepts an address and returns whether or not it is
            /// a valid address
            function validateAddress(addr) -> ret {
                ret := lt(addr, shl(160, 1))
            }

            /// @dev Accepts an uint32 and returns whether or not it is
            /// a valid uint32
            function validateUint32(x) -> ret {
                ret := lt(x, shl(32,1))
            }

            /// @dev Accepts an uint64 and returns whether or not it is
            /// a valid uint64
            function validateUint64(x) -> ret {
                ret := lt(x, shl(64,1))
            }

            /// @dev Accepts an uint128 and returns whether or not it is
            /// a valid uint128
            function validateUint128(x) -> ret {
                ret := lt(x, shl(128,1))
            }

            /// Validates that the `bytes` is formed correctly
            /// and returns the pointer right after the end of the bytes
            function validateBytes(bytesPtr) -> bytesEnd {
                let length := mload(bytesPtr)
                let lastWordBytes := mod(length, 32)

                switch lastWordBytes
                case 0 {
                    // If the length is divisible by 32, then
                    // the bytes occupy whole words, so there is
                    // nothing to validate
                    bytesEnd := safeAdd(bytesPtr, safeAdd(length, 32, "pol"), "aop")
                }
                default {
                    // If the length is not divisible by 32, then
                    // the last word is padded with zeroes, i.e.
                    // the last 32 - `lastWordBytes` bytes must be zeroes
                    // The easiest way to check this is to use AND operator

                    let zeroBytes := sub(32, lastWordBytes)
                    // It has its first 32 - `lastWordBytes` bytes set to 255
                    let mask := sub(shl(mul(zeroBytes,8),1),1)

                    let fullLen := lengthRoundedByWords(length)
                    bytesEnd := safeAdd(bytesPtr, safeAdd(32, fullLen, "dza"), "dzp")

                    let lastWord := mload(sub(bytesEnd, 32))

                    // If last word contains some unintended bits
                    // return 0
                    if and(lastWord, mask) {
                        assertionError("bad bytes encoding")
                    }
                }
            }

            /// @dev Accepts the pointer to the bytes32[] array length and
            /// returns the pointer right after the array's content
            function validateBytes32Array(arrayPtr) -> arrayEnd {
                // The bytes32[] array takes full words which may contain any content.
                // Thus, there is nothing to validate.
                let length := mload(arrayPtr)
                arrayEnd := safeAdd(arrayPtr, safeAdd(32, safeMul(length, 32, "lop"), "asa"), "sp")
            }

            ///
            /// Safe math utilities
            ///

            /// @dev Returns the multiplication of two unsigned integers, reverting on overflow.
            function safeMul(x, y, errMsg) -> ret {
                switch y
                case 0 {
                    ret := 0
                }
                default {
                    ret := mul(x, y)
                    if iszero(eq(div(ret, y), x)) {
                        assertionError(errMsg)
                    }
                }
            }

            /// @dev Returns the integer division of two unsigned integers. Reverts with custom message on
            /// division by zero. The result is rounded towards zero.
            function safeDiv(x, y, errMsg) -> ret {
                if iszero(y) {
                    assertionError(errMsg)
                }
                ret := div(x, y)
            }

            /// @dev Returns the addition of two unsigned integers, reverting on overflow.
            function safeAdd(x, y, errMsg) -> ret {
                ret := add(x, y)
                if lt(ret, x) {
                    assertionError(errMsg)
                }
            }

            /// @dev Returns the subtraction of two unsigned integers, reverting on underflow.
            function safeSub(x, y, errMsg) -> ret {
                if gt(y, x) {
                    assertionError(errMsg)
                }
                ret := sub(x, y)
            }

            function saturatingSub(x, y) -> ret {
                switch gt(x,y)
                case 0 {
                    ret := 0
                }
                default {
                    ret := sub(x,y)
                }
            }

            ///
            /// Debug utilities
            ///

            /// @dev This method accepts the message and some 1-word data associated with it
            /// It triggers a VM hook that allows the server to observe the behavior of the system.
            function debugLog(msg, data) {
                storeVmHookParam(0, msg)
                storeVmHookParam(1, data)
                setHook(VM_HOOK_DEBUG_LOG())
            }

            /// @dev Triggers a hook that displays the returndata on the server side.
            function debugReturndata() {
                debugLog("returndataptr", returnDataPtr())
                storeVmHookParam(0, returnDataPtr())
                setHook(VM_HOOK_DEBUG_RETURNDATA())
            }

            /// @dev Triggers a hook that notifies the operator about the factual number of gas
            /// refunded to the user. This is to be used by the operator to derive the correct
            /// `gasUsed` in the API.
            function notifyAboutRefund(refund) {
                storeVmHookParam(0, refund)
                setHook(VM_NOTIFY_OPERATOR_ABOUT_FINAL_REFUND())
                debugLog("refund(gas)", refund)
            }

            function notifyExecutionResult(success) {
                let ptr := returnDataPtr()
                storeVmHookParam(0, success)
                storeVmHookParam(1, ptr)
                setHook(VM_HOOK_EXECUTION_RESULT())

                debugLog("execution result: success", success)
                debugLog("execution result: ptr", ptr)
            }

            /// @dev Asks operator for the refund for the transaction. The function provides
            /// the operator with the proposed refund gas by the bootloader, 
            /// total spent gas on the pubdata and gas per 1 byte of pubdata.
            /// This function is called before the refund stage, because at that point
            /// only the operator knows how close does a transaction
            /// bring us to closing the batch as well as how much the transaction
            /// should've spent on the pubdata/computation/etc.
            /// After it is run, the operator should put the expected refund
            /// into the memory slot (in the out of circuit execution).
            /// Since the slot after the transaction is not touched,
            /// this slot can be used in the in-circuit VM out of box.
            /// @param proposedRefund The proposed refund gas by the bootloader.
            /// @param spentOnPubdata The number of gas that transaction spent on the pubdata.
            /// @param gasPerPubdataByte The price of each byte of pubdata in L2 gas.
            function askOperatorForRefund(
                proposedRefund,
                spentOnPubdata,
                gasPerPubdataByte
            ) {
                storeVmHookParam(0, proposedRefund)
                storeVmHookParam(1, spentOnPubdata)
                storeVmHookParam(2, gasPerPubdataByte)
                setHook(VM_HOOK_ASK_OPERATOR_FOR_REFUND())
            }

            ///
            /// Error codes used for more correct diagnostics from the server side.
            ///

            function ETH_CALL_ERR_CODE() -> ret {
                ret := 0
            }

            function ACCOUNT_TX_VALIDATION_ERR_CODE() -> ret {
                ret := 1
            }

            function FAILED_TO_CHARGE_FEE_ERR_CODE() -> ret {
                ret := 2
            }

            function FROM_IS_NOT_AN_ACCOUNT_ERR_CODE() -> ret {
                ret := 3
            }

            function FAILED_TO_CHECK_ACCOUNT_ERR_CODE() -> ret {
                ret := 4
            }

            function UNACCEPTABLE_GAS_PRICE_ERR_CODE() -> ret {
                ret := 5
            }

            function FAILED_TO_SET_NEW_BATCH_ERR_CODE() -> ret {
                ret := 6
            }

            function PAY_FOR_TX_FAILED_ERR_CODE() -> ret {
                ret := 7
            }

            function PRE_PAYMASTER_PREPARATION_FAILED_ERR_CODE() -> ret {
                ret := 8
            }

            function PAYMASTER_VALIDATION_FAILED_ERR_CODE() -> ret {
                ret := 9
            }

            function FAILED_TO_SEND_FEES_TO_THE_OPERATOR() -> ret {
                ret := 10
            }

            function UNACCEPTABLE_PUBDATA_PRICE_ERR_CODE() -> ret {
                ret := 11
            }

            function TX_VALIDATION_FAILED_ERR_CODE() -> ret {
                ret := 12
            }

            function MAX_PRIORITY_FEE_PER_GAS_GREATER_THAN_MAX_FEE_PER_GAS() -> ret {
                ret := 13
            }

            function BASE_FEE_GREATER_THAN_MAX_FEE_PER_GAS() -> ret {
                ret := 14
            }

            function PAYMASTER_RETURNED_INVALID_CONTEXT() -> ret {
                ret := 15
            }

            function PAYMASTER_RETURNED_CONTEXT_IS_TOO_LONG() -> ret {
                ret := 16
            }

            function ASSERTION_ERROR() -> ret {
                ret := 17
            }

            function FAILED_TO_MARK_FACTORY_DEPS() -> ret {
                ret := 18
            }

            function TX_VALIDATION_OUT_OF_GAS() -> ret {
                ret := 19
            }

            function NOT_ENOUGH_GAS_PROVIDED_ERR_CODE() -> ret {
                ret := 20
            }

            function ACCOUNT_RETURNED_INVALID_MAGIC_ERR_CODE() -> ret {
                ret := 21
            }

            function PAYMASTER_RETURNED_INVALID_MAGIC_ERR_CODE() -> ret {
                ret := 22
            }

            function MINT_ETHER_FAILED_ERR_CODE() -> ret {
                ret := 23
            }

            function FAILED_TO_APPEND_TRANSACTION_TO_L2_BLOCK() -> ret {
                ret := 24
            }

            function FAILED_TO_SET_L2_BLOCK() -> ret {
                ret := 25
            }

            function FAILED_TO_PUBLISH_TIMESTAMP_DATA_TO_L1() -> ret {
                ret := 26
            }

            function L1_MESSENGER_PUBLISHING_FAILED_ERR_CODE() -> ret {
                ret := 27
            }

            function L1_MESSENGER_LOG_SENDING_FAILED_ERR_CODE() -> ret {
                ret := 28
            }

            function FAILED_TO_CALL_SYSTEM_CONTEXT_ERR_CODE() -> ret {
                ret := 29
            }

            /// @dev Accepts a 1-word literal and returns its length in bytes
            /// @param str A string literal
            function getStrLen(str) -> len {
                len := 0
                // The string literals are stored left-aligned. Thus,
                // In order to get the length of such string,
                // we shift it to the left (remove one byte to the left) until
                // no more non-empty bytes are left.
                for {} str {str := shl(8, str)} {
                    len := add(len, 1)
                }
            }

            // Selector of the errors used by the "require" statements in Solidity
            // and the one that can be parsed by our server.
            function GENERAL_ERROR_SELECTOR() -> ret {
                ret := {{REVERT_ERROR_SELECTOR}}
            }

            /// @notice Reverts with assertion error with the provided error string literal.
            function assertionError(err) {
                let ptr := 0

                // The first byte indicates that the revert reason is an assertion error
                mstore8(ptr, ASSERTION_ERROR())
                ptr := add(ptr, 1)

                // Then, we need to put the returndata in a way that is easily parsable by our
                // servers
                mstore(ptr, GENERAL_ERROR_SELECTOR())
                ptr := add(ptr, 4)

                // Then, goes the "data offset". It is has constant value of 32.
                mstore(ptr, 32)
                ptr := add(ptr, 32)

                // Then, goes the length of the string:
                mstore(ptr, getStrLen(err))
                ptr := add(ptr, 32)

                // Then, we put the actual string
                mstore(ptr, err)
                ptr := add(ptr, 32)

                revert(0, ptr)
            }

            /// @notice Accepts an error code and whether there is a need to copy returndata
            /// @param errCode The code of the error
            /// @param sendReturnData A flag of whether or not the returndata should be used in the
            /// revert reason as well.
            function revertWithReason(errCode, sendReturnData) {
                let returndataLen := 1
                mstore8(0, errCode)

                if sendReturnData {
                    // Here we ignore all kinds of limits on the returned data,
                    // since the `revert` will happen shortly after.
                    returndataLen := add(returndataLen, returndatasize())
                    returndatacopy(1, 0, returndatasize())
                }
                revert(0, returndataLen)
            }

            /// @notice The id of the VM hook that notifies the operator that the transaction
            /// validation rules should start applying (i.e. the user should not be allowed to access
            /// other users' storage, etc).
            function VM_HOOK_ACCOUNT_VALIDATION_ENTERED() -> ret {
                ret := 0
            }

            /// @notice The id of the VM hook that notifies the operator that the transaction
            /// paymaster validation has started.
            function VM_HOOK_PAYMASTER_VALIDATION_ENTERED() -> ret {
                ret := 1
            }

            /// @notice The id of the VM hook that notifies the operator that the transaction's validation
            /// restrictions should no longer apply. Note, that this is different from the validation ending,
            /// since for instance the bootloader needs to do some actions during validation which are forbidden for users.
            /// So this hook is used to notify the operator that the restrictions should be temporarily lifted.
            function VM_HOOK_NO_VALIDATION_ENTERED() -> ret {
                ret := 2
            }

            /// @notice The id of the VM hook that notifies the operator that the transaction's validation has ended.
            function VM_HOOK_VALIDATION_STEP_ENDED() -> ret {
                ret := 3
            }

            /// @notice The id of the VM hook that notifies the operator that the transaction's execution has started.
            function VM_HOOK_TX_HAS_ENDED() -> ret {
                ret := 4
            }

            /// @notice The id of the VM hook that is used to emit debugging logs consisting of pair <msg, data>.
            function VM_HOOK_DEBUG_LOG() -> ret {
                ret := 5
            }

            /// @notice The id of the VM hook that is used to emit debugging logs with the returndata of the latest transaction.
            function VM_HOOK_DEBUG_RETURNDATA() -> ret {
                ret := 6
            }

            /// @notice The id of the VM hook that is used to notify the operator about the entry into the
            /// `ZKSYNC_CATCH_NEAR_CALL` function.
            function VM_HOOK_CATCH_NEAR_CALL() -> ret {
                ret := 7
            }

            /// @notice The id of the VM hook that is used to notify the operator about the need to put the refund for
            /// the current transaction into the bootloader's memory.
            function VM_HOOK_ASK_OPERATOR_FOR_REFUND() -> ret {
                ret := 8
            }

            /// @notice The id of the VM hook that is used to notify the operator about the refund given to the user by the bootloader.
            function VM_NOTIFY_OPERATOR_ABOUT_FINAL_REFUND() -> ret {
                ret := 9
            }

            /// @notice The id of the VM hook that is used to notify the operator about the execution result of the transaction.
            function VM_HOOK_EXECUTION_RESULT() -> ret {
                ret := 10
            }

            /// @notice The id of the VM hook that is used to notify the operator that it needs to insert the information about the last
            /// fictive miniblock.
            function VM_HOOK_FINAL_L2_STATE_INFO() -> ret {
                ret := 11
            }

            /// @norice The id of the VM hook that use used to notify the operator that it needs to insert the pubdata.
            function VM_HOOK_PUBDATA_REQUESTED() -> ret {
                ret := 12
            }

            // Need to prevent the compiler from optimizing out similar operations,
            // which may have different meaning for the offline debugging
            function $llvm_NoInline_llvm$_unoptimized(val) -> ret {
                ret := add(val, callvalue())
            }

            /// @notice Triggers a VM hook.
            /// The server will recognize it and output corresponding logs.
            function setHook(hook) {
                mstore(VM_HOOK_PTR(), $llvm_NoInline_llvm$_unoptimized(hook))
            }

            /// @notice Sets a value to a param of the vm hook.
            /// @param paramId The id of the VmHook parameter.
            /// @param value The value of the parameter.
            /// @dev This method should be called before triggering the VM hook itself.
            /// @dev It is the responsibility of the caller to never provide
            /// paramId smaller than the VM_HOOK_PARAMS()
            function storeVmHookParam(paramId, value) {
                let offset := add(VM_HOOK_PARAMS_OFFSET(), mul(32, paramId))
                mstore(offset, $llvm_NoInline_llvm$_unoptimized(value))
            }

            /// @dev Log key used by Executor.sol for processing. See Constants.sol::SystemLogKey enum
            function chainedPriorityTxnHashLogKey() -> ret {
                ret := 5
            }

            /// @dev Log key used by Executor.sol for processing. See Constants.sol::SystemLogKey enum
            function numberOfLayer1TxsLogKey() -> ret {
                ret := 6
            }

            /// @dev Log key used by Executor.sol for processing. See Constants.sol::SystemLogKey enum
            function protocolUpgradeTxHashKey() -> ret {
                ret := 13
            }

            ////////////////////////////////////////////////////////////////////////////
            //                      Main Transaction Processing
            ////////////////////////////////////////////////////////////////////////////

            /// @notice the address that will be the beneficiary of all the fees
            let OPERATOR_ADDRESS := mload(0)

            let GAS_PRICE_PER_PUBDATA := 0

            // Initializing block params
            {
                /// @notice The hash of the previous batch
                let PREV_BATCH_HASH := mload(32)
                /// @notice The timestamp of the batch being processed
                let NEW_BATCH_TIMESTAMP := mload(64)
                /// @notice The number of the new batch being processed.
                /// While this number is deterministic for each batch, we
                /// still provide it here to ensure consistency between the state
                /// of the VM and the state of the operator.
                let NEW_BATCH_NUMBER := mload(96)

                /// @notice The minimal price per pubdata byte in ETH that the operator agrees on.
                /// In the future, a trustless value will be enforced.
                /// For now, this value is trusted to be fairly provided by the operator.
                /// It is expected of the operator to already include the L1 batch overhead costs into the value.
                let FAIR_PUBDATA_PRICE := mload(128)

                /// @notice The minimal gas price that the operator agrees upon.
                /// In the future, it will have an EIP1559-like lower bound.
                /// It is expected of the operator to already include the L1 batch overhead costs into the value.
                let FAIR_L2_GAS_PRICE := mload(160)

                /// @notice The expected base fee by the operator.
                /// Just like the batch number, while calculated on the bootloader side,
                /// the operator still provides it to make sure that its data is in sync.
                let EXPECTED_BASE_FEE := mload(192)

                validateOperatorProvidedPrices(FAIR_L2_GAS_PRICE, FAIR_PUBDATA_PRICE)



                <!-- @if BOOTLOADER_TYPE=='proved_batch' -->

                let baseFee := 0

                baseFee, GAS_PRICE_PER_PUBDATA := getFeeParams(
                    FAIR_PUBDATA_PRICE,
                    FAIR_L2_GAS_PRICE
                )

                // Only for the proved batch we enforce that the baseFee proposed
                // by the operator is equal to the expected one. For the playground batch, we allow
                // the operator to provide any baseFee the operator wants.
                if iszero(eq(baseFee, EXPECTED_BASE_FEE)) {
                    debugLog("baseFee", baseFee)
                    debugLog("EXPECTED_BASE_FEE", EXPECTED_BASE_FEE)
                    assertionError("baseFee inconsistent")
                }

                upgradeSystemContextIfNeeded()

                setNewBatch(PREV_BATCH_HASH, NEW_BATCH_TIMESTAMP, NEW_BATCH_NUMBER, EXPECTED_BASE_FEE)

                <!-- @endif -->

                <!-- @if BOOTLOADER_TYPE=='playground_batch' -->

                let SHOULD_SET_NEW_BATCH := mload(224)

                upgradeSystemContextIfNeeded()

                switch SHOULD_SET_NEW_BATCH
                case 0 {
                    unsafeOverrideBatch(NEW_BATCH_TIMESTAMP, NEW_BATCH_NUMBER, EXPECTED_BASE_FEE)
                }
                default {
                    setNewBatch(PREV_BATCH_HASH, NEW_BATCH_TIMESTAMP, NEW_BATCH_NUMBER, EXPECTED_BASE_FEE)
                }

                GAS_PRICE_PER_PUBDATA := gasPerPubdataFromBaseFee(EXPECTED_BASE_FEE, FAIR_PUBDATA_PRICE)

                <!-- @endif -->
            }

            // Now, we iterate over all transactions, processing each of them
            // one by one.
            // Here, the `resultPtr` is the pointer to the memory slot, where we will write
            // `true` or `false` based on whether the tx execution was successful,

            // The position at which the tx offset of the transaction should be placed
            let currentExpectedTxOffset := add(TXS_IN_BATCH_LAST_PTR(), mul(MAX_POSTOP_SLOTS(), 32))

            let txPtr := TX_DESCRIPTION_BEGIN_BYTE()

            // At the COMPRESSED_BYTECODES_BEGIN_BYTE() the pointer to the newest bytecode to be published
            // is stored.
            mstore(COMPRESSED_BYTECODES_BEGIN_BYTE(), add(COMPRESSED_BYTECODES_BEGIN_BYTE(), 32))

            // At start storing keccak256("") as `chainedPriorityTxsHash` and 0 as `numberOfLayer1Txs`
            mstore(PRIORITY_TXS_L1_DATA_BEGIN_BYTE(), EMPTY_STRING_KECCAK())
            mstore(add(PRIORITY_TXS_L1_DATA_BEGIN_BYTE(), 32), 0)

            // Iterating through transaction descriptions
            let transactionIndex := 0
            for {
                let resultPtr := RESULT_START_PTR()
            } lt(txPtr, TXS_IN_BATCH_LAST_PTR()) {
                txPtr := add(txPtr, TX_DESCRIPTION_SIZE())
                resultPtr := add(resultPtr, 32)
                transactionIndex := add(transactionIndex, 1)
            } {
                let execute := mload(txPtr)

                debugLog("txPtr", txPtr)
                debugLog("execute", execute)

                if iszero(execute) {
                    // We expect that all transactions that are executed
                    // are continuous in the array.
                    break
                }

                let txDataOffset := mload(add(txPtr, 32))

                // We strongly enforce the positions of transactions
                if iszero(eq(currentExpectedTxOffset, txDataOffset)) {
                    debugLog("currentExpectedTxOffset", currentExpectedTxOffset)
                    debugLog("txDataOffset", txDataOffset)

                    assertionError("Tx data offset is incorrect")
                }

                currentExpectedTxOffset := validateAbiEncoding(txDataOffset)

                // Checking whether the last slot of the transaction's description
                // does not go out of bounds.
                if gt(sub(currentExpectedTxOffset, 32), LAST_FREE_SLOT()) {
                    debugLog("currentExpectedTxOffset", currentExpectedTxOffset)
                    debugLog("LAST_FREE_SLOT", LAST_FREE_SLOT())

                    assertionError("currentExpectedTxOffset too high")
                }

                validateTypedTxStructure(add(txDataOffset, 32))

                <!-- @if BOOTLOADER_TYPE=='proved_batch' -->
                {
                    debugLog("ethCall", 0)
                    processTx(txDataOffset, resultPtr, transactionIndex, 0, GAS_PRICE_PER_PUBDATA)
                }
                <!-- @endif -->
                <!-- @if BOOTLOADER_TYPE=='playground_batch' -->
                {
                    let txMeta := mload(txPtr)
                    let processFlags := getWordByte(txMeta, 31)
                    debugLog("flags", processFlags)


                    // `processFlags` argument denotes which parts of execution should be done:
                    //  Possible values:
                    //     0x00: validate & execute (normal mode)
                    //     0x02: perform ethCall (i.e. use mimicCall to simulate the call)

                    let isETHCall := eq(processFlags, 0x02)
                    debugLog("ethCall", isETHCall)
                    processTx(txDataOffset, resultPtr, transactionIndex, isETHCall, GAS_PRICE_PER_PUBDATA)
                }
                <!-- @endif -->
                // Signal to the vm that the transaction execution is complete
                setHook(VM_HOOK_TX_HAS_ENDED())
                // Increment tx index within the system.
                considerNewTx()
            }

            // Resetting tx.origin and gasPrice to 0, so we don't pay for
            // publishing them on-chain.
            setTxOrigin(0)
            setGasPrice(0)

            // Transferring all the ETH received in the block to the operator
            directETHTransfer(
                selfbalance(),
                OPERATOR_ADDRESS
            )

            // Hook that notifies that the operator should provide final information for the batch
            setHook(VM_HOOK_FINAL_L2_STATE_INFO())

            // Each batch typically ends with a special block which contains no transactions.
            // So we need to have this method to reflect it in the system contracts too.
            //
            // The reason is that as of now our node requires that each storage write (event, etc) belongs to a particular
            // L2 block. In case a batch is sealed by timeout (i.e. the resources of the batch have not been exhausted, but we need
            // to seal it to assure timely finality), we need to process sending funds to the operator *after* the last
            // non-empty L2 block has been already sealed. We can not override old L2 blocks, so we need to create a new empty "fictive" block for it.
            //
            // The other reason why we need to set this block is so that in case of empty batch (i.e. the one which has no transactions),
            // the virtual block number as well as miniblock number are incremented.
            setL2Block(transactionIndex)

            callSystemContext({{RIGHT_PADDED_RESET_TX_NUMBER_IN_BLOCK_SELECTOR}})

            publishTimestampDataToL1()

            // Sending system logs (to be processed on L1)
            sendToL1Native(true, chainedPriorityTxnHashLogKey(), mload(PRIORITY_TXS_L1_DATA_BEGIN_BYTE()))
            sendToL1Native(true, numberOfLayer1TxsLogKey(), mload(add(PRIORITY_TXS_L1_DATA_BEGIN_BYTE(), 32)))

            l1MessengerPublishingCall()
        }
    }
}
