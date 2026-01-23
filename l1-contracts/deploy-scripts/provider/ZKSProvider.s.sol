// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {FinalizeL1DepositParams} from "contracts/common/Messaging.sol";
import {Utils} from "../utils/Utils.sol";
import {
    AltL2ToL1Log,
    AltLog,
    AltTransactionReceipt,
    L2ToL1Log,
    L2ToL1LogProof,
    Log,
    TransactionReceipt
} from "./ReceipTypes.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IGetters} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";

contract ZKSProvider is Script {
    function finalizeWithdrawal(
        uint256 chainId,
        address l1Bridgehub,
        string memory l2RpcUrl,
        bytes32 withdrawalHash,
        uint256 index
    ) public {
        FinalizeL1DepositParams memory params = getFinalizeWithdrawalParams(chainId, l2RpcUrl, withdrawalHash, index);

        IBridgehubBase bridgehub = IBridgehubBase(l1Bridgehub);
        IL1AssetRouter assetRouter = IL1AssetRouter(address(bridgehub.assetRouter()));
        IL1Nullifier nullifier = IL1Nullifier(assetRouter.L1_NULLIFIER());

        waitForBatchToBeExecuted(l1Bridgehub, chainId, params);

        // Send the transaction
        vm.startBroadcast();
        nullifier.finalizeDeposit(params);
        vm.stopBroadcast();
    }

    function waitForWithdrawalToBeFinalized(
        uint256 chainId,
        address l1Bridgehub,
        string memory l2RpcUrl,
        bytes32 withdrawalHash,
        uint256 index
    ) public {
        FinalizeL1DepositParams memory params = getFinalizeWithdrawalParams(chainId, l2RpcUrl, withdrawalHash, index);
        waitForBatchToBeExecuted(l1Bridgehub, chainId, params);
    }

    /// we might not need this.
    /// nullifier.finalizeDeposit simulation probably happens at an earlier blocknumber.
    /// It might be enough to wait for the merkle proof from the server.
    function waitForBatchToBeExecuted(
        address l1Bridgehub,
        uint256 chainId,
        FinalizeL1DepositParams memory params
    ) public {
        IBridgehubBase bridgehub = IBridgehubBase(l1Bridgehub);
        // IL1AssetRouter assetRouter = IL1AssetRouter(bridgehub.assetRouter());
        // IL1Nullifier nullifier = IL1Nullifier(assetRouter.L1_NULLIFIER());
        IMessageRoot messageRoot = IMessageRoot(bridgehub.messageRoot());
        ProofData memory proofData = messageRoot.getProofData(
            params.chainId,
            params.l2BatchNumber,
            params.l2MessageIndex,
            bytes32(0),
            params.merkleProof
        );

        // console.log("proofData");
        uint256 actualChainId = chainId;
        uint256 actualBatchNumber = params.l2BatchNumber;
        if (proofData.settlementLayerChainId != chainId && proofData.settlementLayerChainId != 0) {
            actualChainId = proofData.settlementLayerChainId;
            actualBatchNumber = proofData.settlementLayerBatchNumber;
        }

        IGetters getters = IGetters(bridgehub.getZKChain(actualChainId));
        uint256 totalBatchesExecuted;
        uint256 loopCount = 0;
        // _initCreate2FactoryParams(address(0), bytes32(0));
        // instantiateCreate2Factory();

        // IteratedReader reader = IteratedReader(deployViaCreate2(abi.encodePacked(type(IteratedReader).creationCode)));
        // console.log("Reader deployed at", address(reader));

        while (totalBatchesExecuted < actualBatchNumber && loopCount < 30) {
            loopCount++;
            // totalBatchesExecuted = getters.getTotalBatchesExecuted();
            totalBatchesExecuted = getTotalBatchesExecuted(address(getters));
            uint256 secondsToWait = 5;
            vm.sleep(secondsToWait * 1000);
            console.log("Waiting for batch to be executed", totalBatchesExecuted, actualBatchNumber);
            console.log("Waited", loopCount * secondsToWait, "seconds");
        }
        // require(totalBatchesExecuted >= actualBatchNumber, "Batch not executed");
    }

    /// we use this as forge caches the result
    function getTotalBatchesExecuted(address chainAddress) public returns (uint256) {
        string[] memory args = new string[](5);
        args[0] = "cast";
        args[1] = "call";
        args[2] = vm.toString(chainAddress);
        args[3] = "getTotalBatchesExecuted()(uint256)";
        args[4] = "--json";

        bytes memory modifiedJsonBytes = vm.ffi(args);
        string memory modifiedJson = vm.toString(modifiedJsonBytes);
        string memory json2 = string(modifiedJsonBytes);
        // console.log("Total batches executed", modifiedJson);
        // console.log("json2", json2);
        bytes memory res = vm.parseJson(json2, "$[0]");
        uint256 val = abi.decode(res, (uint256));
        return val;
    }

    function getWithdrawalLog(
        string memory l2RpcUrl,
        bytes32 withdrawalHash,
        uint256 index
    ) public returns (Log memory log, uint64 l1BatchTxId) {
        require(bytes(l2RpcUrl).length > 0, "L2 RPC URL not set");

        // Get transaction receipt
        TransactionReceipt memory receipt = getTransactionReceipt(l2RpcUrl, withdrawalHash);

        // Find withdrawal logs (logs from L1_MESSENGER_ADDRESS)
        address L1_MESSENGER_ADDRESS = 0x0000000000000000000000000000000000008008;
        bytes32 L1_MESSAGE_SENT_TOPIC = 0x3a36e47291f4201faf137fab081d92295bce2d53be2c6ca68ba82c7faa9ce241;
        uint256 withdrawalLogCount = 0;

        for (uint256 i = 0; i < receipt.logs.length; i++) {
            if (receipt.logs[i].addr == L1_MESSENGER_ADDRESS && receipt.logs[i].topics[0] == L1_MESSAGE_SENT_TOPIC) {
                // console.log(receipt.logs[i].addr);
                // console.log()
                if (withdrawalLogCount == index) {
                    log = receipt.logs[i];
                    l1BatchTxId = uint64(receipt.transactionIndex);
                    return (log, l1BatchTxId);
                }
                withdrawalLogCount++;
            }
        }

        console.log("Withdrawal log not found at specified index", index);
    }

    function getWithdrawalL2ToL1Log(
        string memory l2RpcUrl,
        bytes32 withdrawalHash,
        uint256 index
    ) public returns (uint64 logIndex, L2ToL1Log memory log) {
        require(bytes(l2RpcUrl).length > 0, "L2 RPC URL not set");

        // Get transaction receipt
        TransactionReceipt memory receipt = getTransactionReceipt(l2RpcUrl, withdrawalHash);

        // Find L2ToL1 logs from L1_MESSENGER_ADDRESS
        address L1_MESSENGER_ADDRESS = 0x0000000000000000000000000000000000008008;
        uint256 withdrawalLogCount = 0;

        for (uint256 i = 0; i < receipt.l2ToL1Logs.length; i++) {
            // console.log("l2ToL1Logs");
            // console.log(i, receipt.l2ToL1Logs[i].logIndex);
            if (receipt.l2ToL1Logs[i].sender == L1_MESSENGER_ADDRESS) {
                if (withdrawalLogCount == index) {
                    log = receipt.l2ToL1Logs[i];
                    logIndex = uint64(i);
                    return (logIndex, log);
                }
                withdrawalLogCount++;
            }
        }

        console.log("L2ToL1 log not found at specified index", index);
    }

    function getFinalizeWithdrawalParams(
        uint256 chainId,
        string memory l2RpcUrl,
        bytes32 withdrawalHash,
        uint256 index
    ) public returns (FinalizeL1DepositParams memory params) {
        require(bytes(l2RpcUrl).length > 0, "L2 RPC URL not set");

        // Get withdrawal log and L2ToL1 log
        (Log memory log, uint64 l1BatchTxId) = getWithdrawalLog(l2RpcUrl, withdrawalHash, index);
        (uint64 l2ToL1LogIndex, L2ToL1Log memory l2ToL1Log) = getWithdrawalL2ToL1Log(l2RpcUrl, withdrawalHash, index);
        if (l2ToL1Log.key == bytes32(0)) {
            return params;
        }

        // Get L2ToL1 log proof
        L2ToL1LogProof memory proof = getL2ToL1LogProof(l2RpcUrl, withdrawalHash, l2ToL1LogIndex);
        // console.log("withdrawalHash");
        // console.logBytes32(withdrawalHash);

        // Extract sender and message from log
        (address sender, bytes memory message) = getMessageFromLog(log);

        params = FinalizeL1DepositParams({
            chainId: chainId,
            l2BatchNumber: log.l1BatchNumber,
            l2MessageIndex: proof.id,
            l2TxNumberInBatch: uint16(l2ToL1Log.txIndexInL1Batch),
            message: message,
            l2Sender: sender,
            merkleProof: proof.proof
        });
    }

    function getMessageFromLog(Log memory log) public pure returns (address sender, bytes memory message) {
        // Extract sender from topic[1] (last 20 bytes)
        // console.log("log.topics[1]");
        // console.log(log.topics.length);
        // console.logBytes32(log.topics[0]);
        sender = address(uint160(uint256(log.topics[1])));

        // Decode message from log data
        // Assuming the data contains the message directly
        message = abi.decode(abi.decode(log.data, (bytes)), (bytes));
    }

    function getTransactionReceipt(
        string memory l2RpcUrl,
        bytes32 txHash
    ) internal returns (TransactionReceipt memory receipt) {
        string[] memory args = new string[](9);
        args[0] = "curl";
        args[1] = "--request";
        args[2] = "POST";
        args[3] = "--url";
        args[4] = l2RpcUrl;
        args[5] = "--header";
        args[6] = "Content-Type: application/json";
        args[7] = "--data";
        args[8] = string.concat(
            '{"jsonrpc":"2.0","method":"eth_getTransactionReceipt","params":["',
            vm.toString(txHash),
            '"],"id":1}'
        );

        bytes memory result = vm.ffi(args);

        receipt = parseTransactionReceipt(result);
    }

    function getL2ToL1LogProof(
        string memory l2RpcUrl,
        bytes32 txHash,
        uint64 logIndex
    ) internal returns (L2ToL1LogProof memory proof) {
        string[] memory args = new string[](9);
        args[0] = "curl";
        args[1] = "--request";
        args[2] = "POST";
        args[3] = "--url";
        args[4] = l2RpcUrl;
        args[5] = "--header";
        args[6] = "Content-Type: application/json";
        args[7] = "--data";
        args[8] = string.concat(
            '{"jsonrpc":"2.0","id":1,"method":"zks_getL2ToL1LogProof","params":["',
            vm.toString(txHash),
            '",',
            vm.toString(logIndex),
            "]}"
        ); // todo later: add ,"proof_based_gw" for interop
        // Execute RPC call

        bytes memory nullProofBytes = "0x7b226a736f6e727063223a22322e30222c226964223a312c22726573756c74223a6e756c6c7d";
        string memory nullProofString2 = '{"jsonrpc":"2.0","id":1,"result":null}';
        bytes memory result = nullProofBytes;
        while (
            compareStrings(string(result), string(nullProofBytes)) ||
            compareStrings(string(result), string(nullProofString2))
        ) {
            result = vm.ffi(args);
            vm.sleep(4000);
        }

        proof = parseL2ToL1LogProof(result);
    }

    function parseTransactionReceipt(bytes memory jsonResponse) internal returns (TransactionReceipt memory receipt) {
        // Parse the JSON response using stdJson
        // This is a simplified implementation - you may need to enhance the parsing
        string memory responseStr = string(jsonResponse);

        string memory modifiedJson = callParseAltLog(responseStr, "parse-transaction-receipt.sh");
        string memory altTransactionReceiptJson = callParseAltLog(responseStr, "parse-alt-transaction-receipt.sh");
        // console.log(responseStr);
        // console.log(altTransactionReceiptJson);
        bytes memory resultBytes = vm.parseJson(altTransactionReceiptJson, "$.result");
        AltTransactionReceipt memory result = abi.decode(resultBytes, (AltTransactionReceipt));

        // console.log("successful result");
        // console.log("Block Number:", result.blockNumber);
        // console.log("Block Hash:", vm.toString(result.blockHash));
        // // console.log("Contract Address:", result.contractAddress);
        // console.log("Cumulative Gas Used:", result.cumulativeGasUsed);
        // console.log("Effective Gas Price:", result.effectiveGasPrice);
        // console.log("From:", result.from);
        // console.log("Gas Used:", result.gasUsed);
        // console.log("L1 Batch Number:", result.l1BatchNumber);
        // console.log("L1 Batch Tx Index:", result.l1BatchTxIndex);
        // console.log("Status:", result.status);
        // console.log("To:", result.to);
        // console.log("Transaction Hash:", vm.toString(result.transactionHash));
        // console.log("Transaction Index:", result.transactionIndex);
        // console.log("Transaction Type:", result.txType);

        AltLog[] memory altLogs;
        {
            string memory altLogsJson = callParseAltLog(responseStr, "parse-alt-logs.sh");
            // console.log(altLogsJson);

            bytes memory logBytes = vm.parseJson(altLogsJson, "$.logs");
            altLogs = abi.decode(logBytes, (AltLog[]));
            // console.log("altLogs");
            // console.log("length", altLogs.length);
            // console.log("addr", altLogs[0].addr);
            // console.log("blockHash", vm.toString(altLogs[0].blockHash));
            // console.log("blockNumber", altLogs[0].blockNumber);
            // console.log("blockTimestamp", altLogs[0].blockTimestamp);
            // console.log("logIndex", altLogs[0].logIndex);
            // console.log("l1BatchNumber", altLogs[0].l1BatchNumber);
            // console.log("transactionHash", vm.toString(altLogs[0].transactionHash));
            // console.log("transactionIndex", altLogs[0].transactionIndex);
            // console.log("transactionLogIndex", altLogs[0].transactionLogIndex);
        }

        bytes[] memory altLogsData = new bytes[](altLogs.length);
        bytes32[][] memory altLogsTopics = new bytes32[][](altLogs.length);
        {
            for (uint256 i = 0; i < altLogs.length; i++) {
                string memory altLogsDataJson = callParseAltLog(responseStr, "parse-alt-logs-data.sh", i);
                string memory altLogsTopicsJson = callParseAltLog(responseStr, "parse-alt-logs-topics.sh", i);
                // console.log(altLogsDataJson);
                // console.log(altLogsTopicsJson);
                bytes memory altLogsDataBytes = vm.parseJson(altLogsDataJson, "$.data");
                // console.logBytes(altLogsDataBytes);
                bytes memory altLogsTopicsBytes = vm.parseJson(altLogsTopicsJson, "$.topics");
                altLogsData[i] = altLogsDataBytes;
                altLogsTopics[i] = abi.decode(altLogsTopicsBytes, (bytes32[]));
            }
        }

        // console.log("successful logs");
        // console.log(altLogs.length);
        // console.log(altLogs[0].addr);
        // console.log(vm.toString(altLogs[0].blockHash));
        // console.log(vm.toString(altLogs[0].blockNumber));
        // console.log(vm.toString(altLogs[0].blockTimestamp));
        // console.log(vm.toString(altLogs[0].logIndex));
        // console.log(vm.toString(altLogs[0].l1BatchNumber));
        // console.log(vm.toString(altLogs[0].transactionHash));
        // console.log(vm.toString(altLogs[0].transactionIndex));

        string memory altL2ToL1LogsJson = callParseAltLog(responseStr, "parse-alt-l2-to-l1-logs.sh");
        // console.log(altL2ToL1LogsJson);

        bytes memory l2ToL1LogsBytes = vm.parseJson(altL2ToL1LogsJson, "$.l2ToL1Logs");
        AltL2ToL1Log[] memory l2ToL1Logs = abi.decode(l2ToL1LogsBytes, (AltL2ToL1Log[]));

        // console.log("l2ToL1Logs");
        // console.log(l2ToL1Logs.length);
        // console.log(l2ToL1Logs[0].logIndex);
        // console.log(l2ToL1Logs[0].txIndexInL1Batch);
        // for (uint256 i = 0; i < l2ToL1Logs.length; i++) {
        //     console.log("L2ToL1Log", i);
        //     console.log("  blockNumber:", l2ToL1Logs[i].blockNumber);
        //     console.log("  blockHash:", vm.toString(l2ToL1Logs[i].blockHash));
        //     // console.log("  isService:", l2ToL1Logs[i].isService);
        //     console.log("  key:", vm.toString(l2ToL1Logs[i].key));
        //     console.log("  logIndex:", l2ToL1Logs[i].logIndex);
        //     console.log("  l1BatchNumber:", l2ToL1Logs[i].l1BatchNumber);
        //     console.log("  sender:", vm.toString(l2ToL1Logs[i].sender));
        //     console.log("  shardId:", l2ToL1Logs[i].shardId);
        //     console.log("  transactionHash:", vm.toString(l2ToL1Logs[i].transactionHash));
        //     console.log("  transactionIndex:", l2ToL1Logs[i].transactionIndex);
        //     console.log("  transactionLogIndex:", l2ToL1Logs[i].transactionLogIndex);
        //     console.log("  txIndexInL1Batch:", l2ToL1Logs[i].txIndexInL1Batch);
        //     console.log("  value:", vm.toString(l2ToL1Logs[i].value));
        // }

        bool status;
        if (result.status == 1) {
            status = true;
        } else {
            status = false;
        }

        Log[] memory logs = new Log[](altLogs.length);
        for (uint256 i = 0; i < altLogs.length; i++) {
            bool removed;
            string memory trueString = "true";
            logs[i] = Log({
                addr: address(uint160(altLogs[i].addr)),
                // addr: address(0),
                blockHash: altLogs[i].blockHash,
                blockNumber: uint64(altLogs[i].blockNumber),
                blockTimestamp: uint64(altLogs[i].blockTimestamp),
                data: altLogsData[i],
                logIndex: uint64(altLogs[i].logIndex),
                // logType: altLogs[i].logType,
                l1BatchNumber: uint64(altLogs[i].l1BatchNumber),
                // removed: compareStrings(altLogs[i].removed, trueString) ? true : false,
                // topics: altLogs[i].topics,
                topics: altLogsTopics[i],
                transactionIndex: uint64(altLogs[i].transactionIndex),
                transactionHash: altLogs[i].transactionHash,
                transactionLogIndex: uint64(altLogs[i].transactionLogIndex)
            });
        }

        L2ToL1Log[] memory realL2ToL1Logs = new L2ToL1Log[](l2ToL1Logs.length);

        for (uint256 i = 0; i < l2ToL1Logs.length; i++) {
            realL2ToL1Logs[i] = L2ToL1Log({
                blockNumber: uint64(l2ToL1Logs[i].blockNumber),
                blockHash: l2ToL1Logs[i].blockHash,
                // isService: l2ToL1Logs[i].isService == 1 ? true : false,
                key: l2ToL1Logs[i].key,
                logIndex: uint64(l2ToL1Logs[i].logIndex),
                l1BatchNumber: uint64(l2ToL1Logs[i].l1BatchNumber),
                sender: l2ToL1Logs[i].sender,
                shardId: uint64(l2ToL1Logs[i].shardId),
                transactionHash: l2ToL1Logs[i].transactionHash,
                transactionIndex: uint64(l2ToL1Logs[i].transactionIndex),
                transactionLogIndex: uint64(l2ToL1Logs[i].transactionLogIndex),
                txIndexInL1Batch: uint64(l2ToL1Logs[i].txIndexInL1Batch),
                value: l2ToL1Logs[i].value
            });
        }

        receipt = TransactionReceipt({
            blockNumber: uint64(result.blockNumber),
            blockHash: result.blockHash,
            // contractAddress: result.contractAddress,
            cumulativeGasUsed: uint64(result.cumulativeGasUsed),
            gasUsed: uint64(result.gasUsed),
            logs: logs,
            l2ToL1Logs: realL2ToL1Logs,
            status: status,
            transactionIndex: uint64(result.transactionIndex),
            transactionHash: result.transactionHash
        });
    }

    // todo import from Utils
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function parseL2ToL1LogProof(bytes memory jsonResponse) internal returns (L2ToL1LogProof memory proof) {
        string memory json = string(jsonResponse);

        bytes memory proofIdBytes = vm.parseJson(json, "$.result.id");
        proof.id = abi.decode(proofIdBytes, (uint64));

        string memory proofJson = callParseAltLog(json, "parse-proof.sh");
        bytes memory lengthBytes = vm.parseJson(proofJson, "$.length");
        uint256 length = abi.decode(lengthBytes, (uint256));
        proof.proof = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            bytes memory proofBytes = vm.parseJson(proofJson, string.concat("$.proof[", vm.toString(i), "]"));
            proof.proof[i] = bytes32(proofBytes);
            // proof.proof = abi.decode(proofBytes, (bytes32[]));
        }
    }

    function getBashScriptPath(string memory scriptName) internal returns (string memory scriptPath) {
        scriptPath = string.concat("./deploy-scripts/provider/bash-scripts/", scriptName);
    }

    function callParseAltLog(
        string memory jsonStr,
        string memory scriptName
    ) internal returns (string memory modifiedJson) {
        string memory scriptPath = getBashScriptPath(scriptName);
        string[] memory args = new string[](3);
        args[0] = "sh";
        args[1] = scriptPath;
        args[2] = jsonStr;

        bytes memory modifiedJsonBytes = vm.ffi(args);
        modifiedJson = string(modifiedJsonBytes);
    }

    function callParseAltLog(
        string memory jsonStr,
        string memory scriptName,
        uint256 index
    ) internal returns (string memory modifiedJson) {
        string memory scriptPath = getBashScriptPath(scriptName);
        string[] memory args = new string[](4);
        args[0] = "sh";
        args[1] = scriptPath;
        args[2] = jsonStr;
        args[3] = vm.toString(index);

        bytes memory modifiedJsonBytes = vm.ffi(args);
        modifiedJson = string(modifiedJsonBytes);
    }
}
