 function TEST_safeSub() {
     testing_assertEq(safeSub(10, 7, "err"), 3, "Failed to subtract 7")
     testing_assertEq(safeSub(10, 8, "err"), 2, "Failed to subtract 8")
 }

 function TEST_safeDiv() {
     testing_assertEq(safeDiv(4, 2, "err"), 2, "Simple division")
     testing_assertEq(safeDiv(5, 2, "err"), 2, "Rounding")
     testing_assertEq(safeDiv(5, 3, "err"), 1, "Rounding down")
     testing_assertEq(safeDiv(4, 3, "err"), 1, "Rounding down")
     testing_assertEq(safeDiv(0, 3, "err"), 0, "Rounding down")
 }

 function TEST_safeDivAssert() {
     testing_testWillFailWith("divByZero")
     safeDiv(4, 0, "divByZero")
 }

 function TEST_safeSubAssert() {
     testing_testWillFailWith("willFail")
     safeSub(10, 12, "willFail")
 }

 function TEST_safeMul() {
     testing_assertEq(safeMul(4, 2, "err"), 8, "Simple")
     testing_assertEq(safeMul(0, 2, "err"), 0, "With zero")
     testing_assertEq(safeMul(0, 0, "err"), 0, "With zero")
     testing_assertEq(safeMul(2, 0, "err"), 0, "With zero")
 }

 function TEST_safeMulAssert() {
     testing_testWillFailWith("overflow")
     let left := shl(129, 1)
     safeMul(left, left, "overflow")
 }

 function TEST_strLen() {
     testing_assertEq(getStrLen("abcd"), 4, "short string")
     testing_assertEq(getStrLen("00"), 2, "0 filled string")
     testing_assertEq(getStrLen(""), 0, "empty string")
     testing_assertEq(getStrLen("12345678901234567890123456789012"), 32, "max length")
     testing_assertEq(getStrLen("1234567890123456789012345678901234"), 0, "over max length")
 }

 function TEST_simple_transaction() {
     // We'll test the transaction from 0.json
     let txDataOffset := testing_txDataOffset(0)
     let innerTxDataOffset := add(txDataOffset, 0x20)
     testing_assertEq(getGasPerPubdataByteLimit(innerTxDataOffset), 0xC350, "Invalid pubdata limit")
 }

 function TEST_getTransactionUpfrontOverhead() {
     // For very large transactions it should be proportional to the memory,
     // but for small ones, the transaction slots are more important

     let smallTxOverhead := getTransactionUpfrontOverhead(32)
     let largeTxOverhead := getTransactionUpfrontOverhead(1000000)

     testing_assertEq(smallTxOverhead, TX_SLOT_OVERHEAD_GAS(), "Invalid small tx overhead")
     testing_assertEq(largeTxOverhead, mul(1000000, MEMORY_OVERHEAD_GAS()), "Invalid small tx overhead")
 }

 function TEST_ceilDiv() {
     testing_assertEq(ceilDiv(1, 0), 0, "Dividing by 0")
     testing_assertEq(ceilDiv(0, 1), 0, "Dividing with overflow")
     testing_assertEq(ceilDiv(5, 2), 3, "Invalid division")
     testing_assertEq(ceilDiv(6, 2), 3, "Invalid division")
 }

 function TEST_lengthRoundedByWords() {
     testing_assertEq(lengthRoundedByWords(65), 96, "Invalid word length")
 }

 function TEST_getGasPrice() {
     let baseFee := basefee()
     testing_log("Base Fee", baseFee)
     testing_assertEq(getGasPrice(6, 5), baseFee, "Invalid gas price")
 }

function TEST_getOperatorRefundForTx() {
    let transactionIndex := 10

    let expected := 3872

    testing_assertEq(getOperatorRefundForTx(transactionIndex), mload(expected), "Invalid refound for tx")
}

function TEST_getOperatorOverheadForTx() {
    let transactionIndex := 10

    let expected := 323872

    testing_assertEq(getOperatorOverheadForTx(transactionIndex), mload(expected), "Invalid operator overhead for tx")
}

function TEST_getOperatorTrustedGasLimitForTx() {
    let transactionIndex := 10

    let expected := 643872

    assertEq(getOperatorTrustedGasLimitForTx(transactionIndex), mload(expected), "Invalid trusted gas limit for tx")
}

function TEST_getCurrentCompressedBytecodeHash() {
    let pointer := mload(COMPRESSED_BYTECODES_BEGIN_BYTE())
    let expected := add(COMPRESSED_BYTECODES_BEGIN_BYTE(), pointer)

    testing_assertEq(getCurrentCompressedBytecodeHash(), mload(expected), "Invalid current")
}

function TEST_checkOffset_success() {
    checkOffset(8534623)
}

function TEST_checkOffset_callDataEncodingTooBig() {
    testing_testWillFailWith("calldataEncoding too big")

    checkOffset(8534623135)
}

function TEST_validateOperatorProvidedPrices1() {
    testing_testWillFailWith("Fair pubdata price too high")

    validateOperatorProvidedPrices(10000000000000, 18446744073709551616)
}

function TEST_validateOperatorProvidedPrices2() {
    testing_testWillFailWith("L2 fair gas price too high")

    validateOperatorProvidedPrices(18446744073709551616, 100000000000000)
}

function TEST_validateOperatorProvidedPrices3() {
    validateOperatorProvidedPrices(1000000000000, 100000000000000)
}

function TEST_txStatusRollingHash_calculatedCorrectly() {
    appendTransactionStatus(0x1234567890123456789012345678901234567890123456789012345678901234, 1)
    appendTransactionStatus(0x1234567890123456789012345678901234567890123456789012345678901234, 0)
    appendTransactionStatus(0x1234567890123456789012345678901234567890123456789012345678901234, 1)
    let actualHash := mload(TXS_STATUS_ROLLING_HASH_BEGIN_BYTE())
    let expectedHash := 0x33f60227f4b0273c1b0475b96365fb3386b1b9f02fb8ca3db01e5f6413d36d97

    testing_assertEq(actualHash, expectedHash, "Invalid tx status rolling hash")
}

function TEST_getFeeParams_HighPubdataPrice() {
    // Under very large L1 gas price, the L2 base fee will start rising to ensure the
    // boundary on the gasLimit

    // 150k gwei L1 pubdata price
    let veryHighL1PubdataPrice := 150000000000000
    // 0.1 gwei L2 base fee
    let l2GasPrice := 100000000

    let baseFee, gasPricePerPubdata := getFeeParams(
        veryHighL1PubdataPrice,
        // 0.1 gwei L2 base fee
        l2GasPrice
    )

    testing_assertEq(baseFee, ceilDiv(veryHighL1PubdataPrice, MAX_L2_GAS_PER_PUBDATA()), "Invalid base fee")
    testing_assertEq(gasPricePerPubdata, MAX_L2_GAS_PER_PUBDATA(), "Invalid gasPricePerPubdata")
}

function TEST_getFeeParams_LowPubdataPrice() {
    // Under low to medium pubdata price, the baseFee is equal to the fair gas price,
    // while the gas per pubdata pubdata is derived by strict division

    // 0.2 gwei L1 pubdata price
    let veryLowL1GasPrice := 200000000
    // 0.1 gwei L2 base fee
    let l2GasPrice := 100000000

    let baseFee, gasPricePerPubdata := getFeeParams(
        veryLowL1GasPrice,
        l2GasPrice
    )

    testing_assertEq(baseFee, l2GasPrice, "Invalid base fee")
    testing_assertEq(gasPricePerPubdata, div(veryLowL1GasPrice, l2GasPrice), "Invalid gasPricePerPubdata")
}

function TEST_systemLogKeys() {
     // Test that the values for various system log keys are correct
     let chainedPriorityTxnHashLogKey := chainedPriorityTxnHashLogKey()
     let numberOfLayer1TxsLogKey := numberOfLayer1TxsLogKey()
     let protocolUpgradeTxHashKey := protocolUpgradeTxHashKey()
     testing_assertEq(chainedPriorityTxnHashLogKey, 2, "Invalid priority txn hash log key")
     testing_assertEq(numberOfLayer1TxsLogKey, 3, "Invalid num layer 1 txns log key")
     testing_assertEq(protocolUpgradeTxHashKey, 10, "Invalid protocol upgrade txn hash log key")
     // keccak256("zksync.bootloader.forceFailedL1TxLog"). Watchers key off it; nothing else pins it.
     testing_assertEq(
        forceFailedL1TxLogKey(),
        0xc347406c856ed927ab49919146282a0c9feb316c83a07792fce67353bcf0e474,
        "Invalid force-fail log key"
     )
 }

function TEST_safeAdd() {
    testing_assertEq(safeAdd(1, 2, "Addition with overflow"), 3, "Invalid addition")
}

function TEST_safeAddAssert() {
    testing_testWillFailWith("Addition with overflow")
    // We use the max value in 256 bit and then add 1 to make it overflow
    let x := 115792089237316195423570985008687907853269984665640564039457584007913129639935
    let y := 1
    safeAdd(x, y, "Addition with overflow")
}

function TEST_saturatingSub() {
    testing_assertEq(saturatingSub(4, 2), 2, "Invalid subtraction")
    testing_assertEq(saturatingSub(2, 4), 0, "Invalid subtraction")
}

function TEST_validateProvedTxMeta() {
    testing_assertEq(validateProvedTxMeta(0x0001), 0, "execute only")
    testing_assertEq(validateProvedTxMeta(0x0101), 1, "execute + forceFail")
}

function TEST_validateTxMeta_forceFailBit() {
    testing_testWillFailWith("invalid txMeta")
    pop(validateProvedTxMeta(0x0201))
}

function TEST_validateTxMeta_executeClear() {
    testing_testWillFailWith("invalid txMeta")
    pop(validateProvedTxMeta(0x0100))
}

function TEST_validateTxMeta_executeByte() {
    testing_testWillFailWith("invalid txMeta")
    pop(validateProvedTxMeta(0x0002))
}

function TEST_validatePlaygroundTxMeta() {
    let ethCallMode := shl(248, 0x02)
    testing_assertEq(validatePlaygroundTxMeta(0x0001), 0, "execute only")
    testing_assertEq(validatePlaygroundTxMeta(or(ethCallMode, 0x0001)), 0, "ethCall")
    testing_assertEq(validatePlaygroundTxMeta(or(ethCallMode, 0x0101)), 1, "ethCall + forceFail")
}

function TEST_validatePlaygroundTxMeta_executeClear() {
    // A non-zero word does not break the loop, so the execute byte has to be checked here.
    testing_testWillFailWith("invalid txMeta")
    pop(validatePlaygroundTxMeta(or(shl(248, 0x02), 0x0100)))
}

function TEST_validatePlaygroundTxMeta_unexpectedByte() {
    testing_testWillFailWith("invalid txMeta")
    pop(validatePlaygroundTxMeta(0x010001))
}

function INT_TEST_forceFailOnL2Tx() {
    // The bit is only valid on a priority op, and tx(0) is an L2 transaction.
    testing_testWillFailWith("forceFail on L2 tx")
    mstore(testing_txDescriptionPtr(0), 0x0101)
}

function INT_TEST_invalidTxMetaInLoop() {
    // Pins that the loop validates the meta word it actually reads.
    testing_testWillFailWith("invalid txMeta")
    mstore(testing_txDescriptionPtr(0), 0x0201)
}

// Executor reconciles these system logs on L1, so a force-failed priority op that stopped
// contributing to them would make its batch unexecutable.
function expectPriorityQueueAccounting() {
    // Words 0 and 32 are the operator address and previous batch hash, which the loop has not read
    // yet: borrow them as keccak scratch and put them back.
    let savedWord0 := mload(0)
    let savedWord32 := mload(32)

    let rollingHash := EMPTY_STRING_KECCAK()
    mstore(0, rollingHash)
    mstore(32, getCanonicalL1TxHash(testing_txDataOffset(2)))
    rollingHash := keccak256(0, 64)
    mstore(0, rollingHash)
    mstore(32, getCanonicalL1TxHash(testing_txDataOffset(3)))
    rollingHash := keccak256(0, 64)
    mstore(0, rollingHash)
    mstore(32, getCanonicalL1TxHash(testing_txDataOffset(4)))
    rollingHash := keccak256(0, 64)

    mstore(0, savedWord0)
    mstore(32, savedWord32)

    testing_expectSystemLog(chainedPriorityTxnHashLogKey(), rollingHash)
    // Fixtures 0-1 are L2 txs, 2-4 priority ops; counters pack as `l1Count | l2Count << 128`.
    testing_expectSystemLog(numberOfLayer1TxsLogKey(), add(3, mul(2, TWO_POW_128())))
}

function INT_TEST_l1TxBaseline() {
    // Control for INT_TEST_forceFailL1Tx: the same deposit, unmutated. Zero gas price, so the
    // operator takes nothing and the refund recipient stays empty.
    let txDataOffset := testing_txDataOffset(2)
    let innerTxDataOffset := add(txDataOffset, 0x20)
    testing_assertEq(getTxType(innerTxDataOffset), 255, "tx(2) must be a priority op")

    testing_expectBootloaderLog(getCanonicalL1TxHash(txDataOffset), 1)
    // The marker is for force-failed transactions only.
    testing_expectNoBootloaderLogKey(forceFailedL1TxLogKey())
    testing_expectBalance(getFrom(innerTxDataOffset), 0)
    testing_expectBalance(getTo(innerTxDataOffset), getValue(innerTxDataOffset))
    testing_expectBalance(getReserved1(innerTxDataOffset), 0)
    expectPriorityQueueAccounting()
}

function INT_TEST_forceFailL1Tx() {
    // Same transaction as INT_TEST_l1TxBaseline, force-failed by the operator.
    let txDataOffset := testing_txDataOffset(2)
    let innerTxDataOffset := add(txDataOffset, 0x20)
    testing_assertEq(getTxType(innerTxDataOffset), 255, "tx(2) must be a priority op")
    let canonicalL1TxHash := getCanonicalL1TxHash(txDataOffset)

    mstore(testing_txDescriptionPtr(2), 0x0101)

    testing_expectTxFailureNoReturndata(2)
    // What `claimFailedDeposit` and `proveL1ToL2TransactionStatus` consume on L1 ...
    testing_expectBootloaderLog(canonicalL1TxHash, 0)
    // ... and nothing that lets the same hash prove as a success.
    testing_expectNoBootloaderLog(canonicalL1TxHash, 1)
    testing_expectBootloaderLog(forceFailedL1TxLogKey(), canonicalL1TxHash)
    // The sender receives no mint; the refund recipient receives the refundable amount.
    testing_expectBalance(getFrom(innerTxDataOffset), 0)
    testing_expectBalance(getTo(innerTxDataOffset), 0)
    testing_expectBalance(getReserved1(innerTxDataOffset), getReserved0(innerTxDataOffset))
    expectPriorityQueueAccounting()
}

function INT_TEST_forceFailL1TxFee() {
    // Checks the refund with a non-zero gas price.
    let txDataOffset := testing_txDataOffset(3)
    let innerTxDataOffset := add(txDataOffset, 0x20)
    testing_assertEq(getTxType(innerTxDataOffset), 255, "tx(3) must be a priority op")

    mstore(testing_txDescriptionPtr(3), 0x0101)

    let billedToUser := safeMul(
        getMaxFeePerGas(innerTxDataOffset),
        getGasLimit(innerTxDataOffset),
        "fee overflow"
    )
    testing_expectTxFailureNoReturndata(3)
    testing_expectBootloaderLog(getCanonicalL1TxHash(txDataOffset), 0)
    testing_expectBalance(getFrom(innerTxDataOffset), 0)
    testing_expectBalance(getTo(innerTxDataOffset), 0)
    testing_expectBalance(
        getReserved1(innerTxDataOffset),
        safeSub(getReserved0(innerTxDataOffset), billedToUser, "fee underflow")
    )
}

function INT_TEST_l1TxRevertBaseline() {
    // The claim force-fail rests on: a priority op that reverts on its first instruction leaves the
    // same balances and logs, minus the marker. tx(4) calls a system contract with no such selector.
    let txDataOffset := testing_txDataOffset(4)
    let innerTxDataOffset := add(txDataOffset, 0x20)
    testing_assertEq(getTxType(innerTxDataOffset), 255, "tx(4) must be a priority op")
    let canonicalL1TxHash := getCanonicalL1TxHash(txDataOffset)

    testing_expectBootloaderLog(canonicalL1TxHash, 0)
    testing_expectNoBootloaderLog(canonicalL1TxHash, 1)
    // A natural revert carries no marker; only the operator's choice does.
    testing_expectNoBootloaderLogKey(forceFailedL1TxLogKey())
    testing_expectBalance(getFrom(innerTxDataOffset), 0)
    testing_expectBalance(getTo(innerTxDataOffset), 0)
    testing_expectBalance(getReserved1(innerTxDataOffset), getReserved0(innerTxDataOffset))
    expectPriorityQueueAccounting()
}

function INT_TEST_forceFailOffL1Settle() {
    // The marker log is only executable on L1, so the bit is rejected on any other settlement layer.
    testing_testWillFailWith("forceFail off L1 settlement")
    mstore(SETTLEMENT_LAYER_CHAIN_ID_BYTE(), add(getL1ChainId(), 1))
    mstore(testing_txDescriptionPtr(2), 0x0101)
}

function INT_TEST_forceFailOnUpgradeTx() {
    // Retyping tx(0) makes it an upgrade tx. The bit's guard runs before the "must be first" one.
    testing_testWillFailWith("forceFail on upgrade tx")
    mstore(add(testing_txDataOffset(0), 0x20), 254)
    mstore(testing_txDescriptionPtr(0), 0x0101)
}

function INT_TEST_evmCreateNonZeroToFails() {
    // tx(1) should be an EVM create transaction where `reserved1 == 1` and `to == 0`.
    let txDataOffset := testing_txDataOffset(1)
    let innerTxDataOffset := add(txDataOffset, 0x20)
    testing_assertEq(getReserved1(innerTxDataOffset), 1, "tx(1) must mark EVM create")
    testing_assertEq(getTo(innerTxDataOffset), 0, "tx(1) must start with zero `to`")

    // Mutate `to` to a non-zero address and let the regular bootloader flow execute it.
    mstore(add(innerTxDataOffset, 0x40), 1)
    testing_testTransactionWillFailWith("0xc4141521")
}
