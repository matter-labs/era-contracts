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

function TEST_asserts() {
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

// function TEST_should ignore

function TEST_getStrLen() {
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

    testing_assertEq(chainedPriorityTxnHashLogKey, 5, "Invalid priority txn hash log key")
    testing_assertEq(numberOfLayer1TxsLogKey, 6, "Invalid num layer 1 txns log key")
    testing_assertEq(protocolUpgradeTxHashKey, 13, "Invalid protocol upgrade txn hash log key")
}

function TEST_getOperatorRefundForTx() {
    let transactionIndex := 12
    let refundTx := getOperatorRefundForTx(transactionIndex)
    let expected := mload(add(TX_OPERATOR_REFUND_BEGIN_BYTE(), mul(transactionIndex, 32)))

    testing_assertEq(refundTx, expected, "Invalid operator refund")
}

function TEST_getOperatorOverheadForTx() {
    let transactionIndex := 12
    let txBatchOverhead := getOperatorOverheadForTx(transactionIndex)
    let expected := mload(add(TX_SUGGESTED_OVERHEAD_BEGIN_BYTE(), mul(transactionIndex, 32)))

    testing_assertEq(txBatchOverhead, expected, "Invalid operator overhead")
}

function TEST_getOperatorTrustedGasLimitForTx() {
    let transactionIndex := 12
    let txTrustedGasLimit := getOperatorTrustedGasLimitForTx(transactionIndex)
    let expected := mload(add(TX_OPERATOR_TRUSTED_GAS_LIMIT_BEGIN_BYTE(), mul(transactionIndex, 32)))

    testing_assertEq(txTrustedGasLimit, expected, "Invalid operator trusted gas limit")

}

function TEST_getCurrentCompressedBytecodeHash() {
    let bytecode := getCurrentCompressedBytecodeHash()
    let expected := mload(add(COMPRESSED_BYTECODES_BEGIN_BYTE(), mload(COMPRESSED_BYTECODES_BEGIN_BYTE())))

    testing_assertEq(bytecode, expected, "Invalid compressed bytecode hash")
}

function TEST_getPubdataCounter() {
    let pubdataCounter := getPubdataCounter()
    let expected := and($llvm_NoInline_llvm$_getMeta(), 0xFFFFFFFF)

    testing_assertEq(pubdataCounter, expected, "Invalid pubdata counter")
}

function TEST_getCurrentPubdataSpent() {
    let currentPubdataCounter := getPubdataCounter()
    let basePubdataSpent := getPubdataCounter()
    let gasPerPubdata := 10
    setPubdataInfo(gasPerPubdata, basePubdataSpent)

    let currentPubdataSpent := getCurrentPubdataSpent(basePubdataSpent)
    let expected := saturatingSub(currentPubdataCounter, basePubdataSpent)

    testing_assertEq(currentPubdataSpent, expected, "Invalid pubdata spent")
}

function TEST_getErgsSpentForPubdata() {
    let basePubdataSpent := getPubdataCounter()
    let gasPerPubdata := 10
    setPubdataInfo(gasPerPubdata, basePubdataSpent)

    let ergsSpentForPubdata := getErgsSpentForPubdata(basePubdataSpent, gasPerPubdata)
    let expected := safeMul(getCurrentPubdataSpent(basePubdataSpent), gasPerPubdata, "mul: getErgsSpentForPubdata")

    testing_assertEq(ergsSpentForPubdata, expected, "Invalid ergs for pubdata")
}

function TEST_getTxType() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let txType := getTxType(innerTxDataOffset)
    let expected := mload(innerTxDataOffset)

    testing_assertEq(txType, expected, "Invalid tx type")
}

function TEST_getFrom() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let from := getFrom(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 32))

    testing_assertEq(from, expected, "Invalid from")
}

function TEST_getTo() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let to := getTo(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 64))

    testing_assertEq(to, expected, "Invalid from")
}

function TEST_getGasLimit() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let gasLimit := getGasLimit(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 96))

    testing_assertEq(gasLimit, expected, "Invalid from")
}

function TEST_getGasPerPubdataByteLimit() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let gasPerPubdataByteLimit := getGasPerPubdataByteLimit(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 128))

    testing_assertEq(gasPerPubdataByteLimit, expected, "Invalid gas per pubdata byte limit")
}

function TEST_getMaxFeePerGas() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let maxFeePerGas := getMaxFeePerGas(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 160))

    testing_assertEq(maxFeePerGas, expected, "Invalid max fee per gas")
}

function TEST_getMaxPriorityFeePerGas() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let maxPriorityFeePerGas := getMaxPriorityFeePerGas(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 192))

    testing_assertEq(maxPriorityFeePerGas, expected, "Invalid max priority fee per gas")
}

function TEST_getPaymaster() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let paymaster := getPaymaster(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 224))

    testing_assertEq(paymaster, expected, "Invalid paymaster")
}

function TEST_getNonce() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let nonce := getNonce(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 256))

    testing_assertEq(nonce, expected, "Invalid nonce")
}

function TEST_getValue() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let value := getValue(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 288))

    testing_assertEq(value, expected, "Invalid value")
}

function TEST_getReserved0() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let reserved0 := getReserved0(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 320))

    testing_assertEq(reserved0, expected, "Invalid reserved0")
}

function TEST_getReserved1() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let reserved1 := getReserved1(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 352))

    testing_assertEq(reserved1, expected, "Invalid reserved1")
}

function TEST_getReserved2() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let reserved2 := getReserved2(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 384))

    testing_assertEq(reserved2, expected, "Invalid reserved2")
}

function TEST_getReserved3() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let reserved3 := getReserved3(innerTxDataOffset)
    let expected := mload(add(innerTxDataOffset, 416))

    testing_assertEq(reserved3, expected, "Invalid reserved3")
}

function TEST_getDataPtr() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := mload(add(innerTxDataOffset, 448))

    let dataPtr := getDataPtr(innerTxDataOffset)
    let expected := add(innerTxDataOffset, ptr)

    testing_assertEq(dataPtr, expected, "Invalid data pointer")
}

function TEST_getDataBytesLength() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := getDataPtr(innerTxDataOffset)

    let dataBytesLength := getDataBytesLength(innerTxDataOffset)
    let expected := lengthRoundedByWords(mload(ptr))

    testing_assertEq(dataBytesLength, expected, "Invalid data bytes length")
}

function TEST_getSignaturePtr() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := mload(add(innerTxDataOffset, 480))

    let signaturePtr := getSignaturePtr(innerTxDataOffset)
    let expected := add(innerTxDataOffset, ptr)

    testing_assertEq(signaturePtr, expected, "Invalid signature pointer")
}

function TEST_getSignatureBytesLength() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := getSignaturePtr(innerTxDataOffset)

    let signatureBytesLength := getSignatureBytesLength(innerTxDataOffset)
    let expected := lengthRoundedByWords(mload(ptr))

    testing_assertEq(signatureBytesLength, expected, "Invalid signature bytes length")
}

function TEST_getFactoryDepsPtr() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := mload(add(innerTxDataOffset, 512))

    let factoryDepsPtr := getFactoryDepsPtr(innerTxDataOffset)
    let expected := add(innerTxDataOffset, ptr)

    testing_assertEq(factoryDepsPtr, expected, "Invalid factory deps pointer")
}

function TEST_getFactoryDepsBytesLength() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := getFactoryDepsPtr(innerTxDataOffset)

    let factoryDepsBytesLength := getFactoryDepsBytesLength(innerTxDataOffset)
    let expected := safeMul(mload(ptr),32, "fwop")

    testing_assertEq(factoryDepsBytesLength, expected, "Invalid factory deps bytes length")
}

function TEST_getPaymasterInputPtr() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := mload(add(innerTxDataOffset, 544))

    let paymasterInputPtr := getPaymasterInputPtr(innerTxDataOffset)
    let expected := add(innerTxDataOffset, ptr)

    testing_assertEq(paymasterInputPtr, expected, "Invalid paymaster input pointer")
}

function TEST_getPaymasterInputBytesLength() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := getPaymasterInputPtr(innerTxDataOffset)

    let paymasterInputBytesLength := getPaymasterInputBytesLength(innerTxDataOffset)
    let expected := lengthRoundedByWords(mload(ptr))

    testing_assertEq(paymasterInputBytesLength, expected, "Invalid paymaster input bytes length")
}

function TEST_getReservedDynamicPtr() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr := mload(add(innerTxDataOffset, 576))

    let reservedDynamicPtr := getReservedDynamicPtr(innerTxDataOffset)
    let expected := add(innerTxDataOffset, ptr)

    testing_assertEq(reservedDynamicPtr, expected, "Invalid reserved dynamic pointer")
}

function TEST_getReservedDynamicBytesLength() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)

    let reservedDynamicBytesLength := getReservedDynamicBytesLength(innerTxDataOffset)
    let expected := lengthRoundedByWords(mload(getReservedDynamicPtr(innerTxDataOffset)))

    testing_assertEq(reservedDynamicBytesLength, expected, "Invalid reserved dynamic bytes length")
}

function TEST_getDataLength() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let ptr0 := 768
    let ptr1 := safeAdd(ptr0, getDataBytesLength(innerTxDataOffset), "asx")
    let ptr2 := safeAdd(ptr1, getSignatureBytesLength(innerTxDataOffset), "qwqa")
    let ptr3 := safeAdd(ptr2, getFactoryDepsBytesLength(innerTxDataOffset), "sic")
    let ptr4 := safeAdd(ptr3, getPaymasterInputBytesLength(innerTxDataOffset), "tpiw")

    let dataLength := getDataLength(innerTxDataOffset)
    let expected := safeAdd(ptr4, getReservedDynamicBytesLength(innerTxDataOffset), "shy")

    testing_assertEq(dataLength, expected, "Invalid data length")
}

function TEST_getGasPrice() {
    let baseFee := basefee()

    testing_assertEq(getGasPrice(6, 5), baseFee, "Invalid gas price")
}

function TEST_getGasPrice_maxPriorityFeeGreaterThenMaxFee() {
    testing_testWillFailWith("Max priority fee greater than max fee")

    //getGasPrice(4, 5)
}

function TEST_getGasPrice_baseFeeGreaterThenMaxFee() {
    testing_testWillFailWith("Base fee greater than max fee")
    let baseFee := basefee()
    getGasPrice(baseFee, baseFee)
}

function TEST_getRawCodeHashSuccessTrue() {
    let addr := SYSTEM_CONTEXT_ADDR()
    let assertSuccess := 0

    let expected := 0x010001a5d85e6baddaf82e2d7a43974ab3ad285facf4c3e28844adfc0125a0ce
    let rawCodeHash := getRawCodeHash(addr, assertSuccess)

    testing_assertEq(rawCodeHash, expected, "Invalid raw code hash")
}

function TEST_getRawCodeHashSuccessFalse() {
    let addr := SYSTEM_CONTEXT_ADDR()
    let assertSuccess := 1

    testing_testWillFailWith("getRawCodeHash failed")
    let rawCodeHash := getRawCodeHash(addr, assertSuccess)
}

function TEST_getCanonicalL1TxHash() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    mstore(txDataOffset, 32)
    let innerTxDataOffset := add(txDataOffset, 32)
    let dataLength := safeAdd(32, getDataLength(innerTxDataOffset), "qev")

    let canonicalL1TxHash := getCanonicalL1TxHash(txDataOffset)
    let expected := keccak256(txDataOffset, dataLength)
    
    testing_assertEq(canonicalL1TxHash, expected, "Invalid cannonical L1 TX hash")
}

function TEST_getExecuteL1TxAndNotifyResult() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let basePubdataSpent := getPubdataCounter()
    let gasPerPubdata := 10
    setPubdataInfo(gasPerPubdata, basePubdataSpent)
    let transactionIndex := 12
    let gasLimitForTx := getGasLimitForTx(
        innerTxDataOffset, 
        transactionIndex, 
        gasPerPubdata, 
        L1_TX_INTRINSIC_L2_GAS(), 
        L1_TX_INTRINSIC_PUBDATA()
    )
    let gasSpentOnExecution := 0
    let gasForExecution := sub(gasLimitForTx, gasSpentOnExecution)
    let callAbi := getNearCallABI(gasForExecution)
    checkEnoughGas(gasForExecution)
    let gasBeforeExecution := sub(gas(), 5310)

    let success := ZKSYNC_NEAR_CALL_executeL1Tx(
        callAbi,
        txDataOffset,
        basePubdataSpent,
        gasPerPubdata
    )
    notifyExecutionResult(success)
    let expected := sub(gasBeforeExecution, gas())
    
    let gasSpentOnExecution := getExecuteL1TxAndNotifyResult(
        txDataOffset, 
        gasForExecution, 
        basePubdataSpent, 
        gasPerPubdata
    )

    testing_assertEq(gasSpentOnExecution, expected, "Invalid gas spent on execution")
}

function TEST_getGasLimitForTxDefault() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let totalGasLimit := getGasLimit(innerTxDataOffset)
    let transactionIndex := 12
    let basePubdataSpent := getPubdataCounter()
    let gasPerPubdata := 10
    setPubdataInfo(gasPerPubdata, basePubdataSpent)
    let intrinsicGas := 100000000000
    let intrinsicPubdata := 2

    let expectedGasLimitForTx := 0
    let expectedReservedGas := 0

    let gasLimitForTx, reservedGas := getGasLimitForTx(
        innerTxDataOffset,
        transactionIndex,
        gasPerPubdata,
        intrinsicGas,
        intrinsicPubdata
    )

    testing_assertEq(gasLimitForTx, expectedGasLimitForTx, "Invalid gas limit for tx")
    testing_assertEq(reservedGas, expectedReservedGas, "Invalid reserved gas")
}

function TEST_getGasLimitForTxCase() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := 32
    let totalGasLimit := getGasLimit(innerTxDataOffset)
    let transactionIndex := 12
    let basePubdataSpent := getPubdataCounter()
    let gasPerPubdata := 10
    setPubdataInfo(gasPerPubdata, basePubdataSpent)
    let expectedReservedGas
    let intrinsicGas := 1
    let intrinsicPubdata := 2

    let operatorTrustedGasLimit := max(MAX_GAS_PER_TRANSACTION(), getOperatorTrustedGasLimitForTx(transactionIndex))

    switch gt(totalGasLimit, operatorTrustedGasLimit)
    case 0 {
        expectedReservedGas := 0
    }
    default {
        expectedReservedGas := sub(totalGasLimit, operatorTrustedGasLimit)
        totalGasLimit := operatorTrustedGasLimit
    }

    let txEncodingLen := safeAdd(32, getDataLength(innerTxDataOffset), "lsh")

    let operatorOverheadForTransaction := getVerifiedOperatorOverheadForTx(
        transactionIndex,
        totalGasLimit,
        txEncodingLen
    )
    let expectedGasLimitForTx := safeSub(totalGasLimit, operatorOverheadForTransaction, "qr")

    let intrinsicOverhead := safeAdd(
        intrinsicGas,
        safeMul(intrinsicPubdata, gasPerPubdata, "qw"),
        "fj"
    )

    switch lt(expectedGasLimitForTx, intrinsicOverhead)
    case 1 {
        expectedGasLimitForTx := 0
    }
    default {
        expectedGasLimitForTx := sub(expectedGasLimitForTx, intrinsicOverhead)
    }

    let gasLimitForTx, reservedGas := getGasLimitForTx(
        innerTxDataOffset,
        transactionIndex,
        gasPerPubdata,
        intrinsicGas,
        intrinsicPubdata
    )

    testing_assertEq(gasLimitForTx, expectedGasLimitForTx, "Invalid gas limit for tx")
    testing_assertEq(reservedGas, expectedReservedGas, "Invalid reserved gas")
}

function TEST_getCodeMarker() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let factoryDepsPtr := getFactoryDepsPtr(innerTxDataOffset)
    let iter := add(factoryDepsPtr, 32)
    let bytecodeHash := mload(iter)

    let codeMarker := getCodeMarker(bytecodeHash)

    mstore(4, bytecodeHash)
    call(
        gas(),
        KNOWN_CODES_CONTRACT_ADDR(),
        0,
        0,
        36,
        0,
        32
    )
    let expected := mload(0)

    testing_assertEq(codeMarker, expected, "Invalid code marker")
}

function TEST_getNearCallABI() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let gasLimit := getGasLimit(innerTxDataOffset)

    let abi := getNearCallABI(gasLimit)
    let expected := gasLimit

    testing_assertEq(abi, expected, "Invalid near call ABI")
}

function TEST_getFarCallABI() {
    let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
    let txDataOffset := mload(add(txPtr, 32))
    let innerTxDataOffset := add(txDataOffset, 32)
    let dataPtr := getDataPtr(innerTxDataOffset)

    let to := getTo(innerTxDataOffset)
    let isSystemCall := shouldMsgValueMimicCallBeSystem(to, dataPtr)

    let isConstructorCall := 0

    let dataStart := add(dataPtr, 32)
    let dataLength := mload(dataPtr)
    let ret
    let gasPassed := gas()

    ret := or(ret, shl(64, dataStart))
    ret := or(ret, shl(96, dataLength))

    ret := or(ret, shl(192, gasPassed))
    ret := or(ret, shl(224, 0))
    ret := or(ret, shl(232, 0))
    ret := or(ret, shl(240, isConstructorCall))
    ret := or(ret, shl(248, isSystemCall))

    let result := getFarCallABI(
        dataPtr,
        gasPassed,
        0,
        0,
        isConstructorCall,
        isSystemCall
    )

    testing_assertEq(result, ret, "Invalid far call ABI")
}

// function TEST_getWordByte() {
//     let txPtr := TX_DESCRIPTION_BEGIN_BYTE()
//     let word := mload(txPtr)
//     let byteIdx := 31
//     let ptr := shr(mul(8, byteIdx), word)

//     let wordByte := getWordByte(word, byteIdx)
//     let expected := and(ptr, 0xFF)

//     testing_assertEq(wordByte, expected, "Invalid word byte")
// }