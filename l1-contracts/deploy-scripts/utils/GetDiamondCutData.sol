// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Vm} from "forge-std/Vm.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

library GetDiamondCutData {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    error NoLogsFound(bytes32 selector);
    error NoMatchingLogEntry();

    /// @notice Fetches logs from a specific block with a given topic selector.
    function _fetchLogsFromBlock(
        uint256 blockNumber,
        address contractAddress,
        bytes32 topicSelector
    ) internal returns (Vm.EthGetLogs[] memory logs) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topicSelector;
        logs = vm.eth_getLogs(blockNumber, blockNumber, contractAddress, topics);
    }

    /// @notice Finds a log entry matching the given criteria from recorded logs.
    function _findLogEntry(
        Vm.Log[] memory logs,
        address contractAddress,
        bytes32 topicSelector
    ) internal pure returns (Vm.Log memory logEntry) {
        uint256 logsLength = logs.length;
        for (uint256 i = 0; i < logsLength; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter == contractAddress && entry.topics.length > 0 && entry.topics[0] == topicSelector) {
                return entry;
            }
        }
        revert NoMatchingLogEntry();
    }

    /// @notice Fetches the diamond cut data by reading the on-chain log for the given protocol version.
    /// @dev This keeps the existing behavior for live scripts where `eth_getLogs` is available.
    function getDiamondCutData(
        address ctm,
        uint256 protocolVersion
    ) external returns (Diamond.DiamondCutData memory diamondCutData) {
        ChainTypeManagerBase chainTypeManager = ChainTypeManagerBase(ctm);
        uint256 blockWithData = chainTypeManager.upgradeCutDataBlock(protocolVersion);
        Vm.EthGetLogs[] memory logs = _fetchLogsFromBlock(
            blockWithData,
            ctm,
            IChainTypeManager.NewUpgradeCutData.selector
        );
        if (logs.length == 0) {
            revert NoLogsFound(IChainTypeManager.NewUpgradeCutData.selector);
        }
        diamondCutData = abi.decode(logs[0].data, (Diamond.DiamondCutData));
    }

    /// @notice Parse diamond cut data from already-recorded logs (e.g. in tests).
    function getDiamondCutDataFromRecordedLogs(
        Vm.Log[] memory logs,
        address ctm
    ) internal pure returns (Diamond.DiamondCutData memory diamondCutData) {
        Vm.Log memory logEntry = _findLogEntry(logs, ctm, IChainTypeManager.NewUpgradeCutData.selector);
        diamondCutData = abi.decode(logEntry.data, (Diamond.DiamondCutData));
    }

    function getDiamondCutAndForceDeployment(
        address ctm
    ) external returns (bytes memory diamondCutData, bytes memory forceDeploymentsData) {
        ChainTypeManagerBase chainTypeManager = ChainTypeManagerBase(ctm);
        uint256 protocolVersion = chainTypeManager.protocolVersion();
        uint256 blockWithData = chainTypeManager.newChainCreationParamsBlock(protocolVersion);
        Vm.EthGetLogs[] memory logs = _fetchLogsFromBlock(
            blockWithData,
            ctm,
            IChainTypeManager.NewChainCreationParams.selector
        );
        if (logs.length == 0) {
            revert NoLogsFound(IChainTypeManager.NewChainCreationParams.selector);
        }

        // Decode the event data as a tuple of all event parameters
        // Event: NewChainCreationParams(address, bytes32, uint64, bytes32, Diamond.DiamondCutData, bytes32, bytes, bytes32)
        (
            ,
            ,
            ,
            ,
            // genesisUpgrade
            // genesisBatchHash
            // genesisIndexRepeatedStorageChanges
            // genesisBatchCommitment
            Diamond.DiamondCutData memory newInitialCut, // newInitialCutHash
            ,
            bytes memory forceDeployments, // forceDeploymentHash

        ) = abi.decode(
                logs[0].data,
                (address, bytes32, uint64, bytes32, Diamond.DiamondCutData, bytes32, bytes, bytes32)
            );

        diamondCutData = abi.encode(newInitialCut);
        forceDeploymentsData = forceDeployments;
    }
}
