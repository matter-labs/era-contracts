// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";

contract SetChainCreationParamsTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_SettingInitialCutHash() public {
        bytes32 initialCutHash = keccak256(abi.encode(getDiamondCutData(address(diamondInit))));
        address randomDiamondInit = makeAddr("randomDiamondInit");

        assertEq(chainContractAddress.initialCutHash(), initialCutHash, "Initial cut hash is not correct");

        Diamond.DiamondCutData memory newDiamondCutData = getDiamondCutData(address(randomDiamondInit));
        bytes32 newCutHash = keccak256(abi.encode(newDiamondCutData));

        address newGenesisUpgrade = makeAddr("newGenesisUpgrade");
        bytes32 genesisBatchHash = bytes32(uint256(0x02));
        uint64 genesisIndexRepeatedStorageChanges = 2;
        bytes32 genesisBatchCommitment = bytes32(uint256(0x02));

        ChainCreationParams memory newChainCreationParams = ChainCreationParams({
            genesisUpgrade: newGenesisUpgrade,
            genesisBatchHash: genesisBatchHash,
            genesisIndexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            genesisBatchCommitment: genesisBatchCommitment,
            genesisAirbenderBatchCommitment: genesisBatchCommitment,
            diamondCut: newDiamondCutData,
            forceDeploymentsData: bytes("")
        });

        vm.prank(governor);
        chainContractAddress.setChainCreationParams(newChainCreationParams);

        assertEq(chainContractAddress.initialCutHash(), newCutHash, "Initial cut hash update was not successful");
        assertEq(chainContractAddress.l1GenesisUpgrade(), newGenesisUpgrade, "Genesis upgrade was not set correctly");

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory newBatchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: genesisBatchHash,
            indexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: 0,
            commitment: genesisBatchCommitment,
            airbenderCommitment: genesisBatchCommitment
        });
        bytes32 expectedStoredBatchZero = keccak256(abi.encode(newBatchZero));

        assertEq(
            chainContractAddress.storedBatchZero(),
            expectedStoredBatchZero,
            "Stored batch zero was not set correctly"
        );
    }

    /// Batch zero must be rebuildable from the logs `setChainCreationParams` emits, without its calldata.
    function test_StoredBatchZeroCanBeRebuiltFromEvents() public {
        bytes32 genesisBatchHash = bytes32(uint256(0x02));
        uint64 genesisIndexRepeatedStorageChanges = 2;
        bytes32 genesisBatchCommitment = bytes32(uint256(0x03));
        bytes32 genesisAirbenderBatchCommitment = bytes32(uint256(0x04));

        ChainCreationParams memory newChainCreationParams = ChainCreationParams({
            genesisUpgrade: makeAddr("newGenesisUpgrade"),
            genesisBatchHash: genesisBatchHash,
            genesisIndexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            genesisBatchCommitment: genesisBatchCommitment,
            genesisAirbenderBatchCommitment: genesisAirbenderBatchCommitment,
            diamondCut: getDiamondCutData(makeAddr("randomDiamondInit")),
            forceDeploymentsData: bytes("")
        });

        vm.expectEmit(address(chainContractAddress));
        emit IChainTypeManager.NewGenesisAirbenderBatchCommitment(genesisAirbenderBatchCommitment);
        vm.recordLogs();
        vm.prank(governor);
        chainContractAddress.setChainCreationParams(newChainCreationParams);

        IExecutor.StoredBatchInfo memory rebuiltBatchZero;
        rebuiltBatchZero.priorityOperationsHash = EMPTY_STRING_KECCAK;
        rebuiltBatchZero.l2LogsTreeRoot = DEFAULT_L2_LOGS_TREE_ROOT_HASH;
        bool foundCreationParams;
        bool foundAirbenderCommitment;
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == IChainTypeManager.NewChainCreationParams.selector) {
                (
                    rebuiltBatchZero.batchHash,
                    rebuiltBatchZero.indexRepeatedStorageChanges,
                    rebuiltBatchZero.commitment
                ) = _decodeGenesisBatchFields(entries[i].data);
                foundCreationParams = true;
            } else if (entries[i].topics[0] == IChainTypeManager.NewGenesisAirbenderBatchCommitment.selector) {
                rebuiltBatchZero.airbenderCommitment = abi.decode(entries[i].data, (bytes32));
                foundAirbenderCommitment = true;
            }
        }

        assertTrue(foundCreationParams && foundAirbenderCommitment, "both events must be emitted");
        assertEq(rebuiltBatchZero.airbenderCommitment, genesisAirbenderBatchCommitment);
        assertEq(keccak256(abi.encode(rebuiltBatchZero)), chainContractAddress.storedBatchZero());
    }

    function _decodeGenesisBatchFields(
        bytes memory _data
    ) private pure returns (bytes32 batchHash, uint64 indexRepeatedStorageChanges, bytes32 commitment) {
        (, batchHash, indexRepeatedStorageChanges, commitment, , , , ) = abi.decode(
            _data,
            (address, bytes32, uint64, bytes32, Diamond.DiamondCutData, bytes32, bytes, bytes32)
        );
    }
}
