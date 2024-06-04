// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {EMPTY_STRING_KECCAK, DEFAULT_L2_LOGS_TREE_ROOT_HASH} from "contracts/common/Config.sol";

contract SetChainCreationParamsTest is StateTransitionManagerTest {
    function test_SettingInitialCutHash() public {
        bytes32 initialCutHash = keccak256(abi.encode(getDiamondCutData(address(diamondInit))));
        address randomDiamondInit = address(0x303030303030303030303);

        assertEq(chainContractAddress.initialCutHash(), initialCutHash, "Initial cut hash is not correct");

        Diamond.DiamondCutData memory newDiamondCutData = getDiamondCutData(address(randomDiamondInit));
        bytes32 newCutHash = keccak256(abi.encode(newDiamondCutData));

        address newGenesisUpgrade = address(0x02);
        bytes32 genesisBatchHash = bytes32(uint256(0x02));
        uint64 genesisIndexRepeatedStorageChanges = 2;
        bytes32 genesisBatchCommitment = bytes32(uint256(0x02));

        ChainCreationParams memory newChainCreationParams = ChainCreationParams({
            genesisUpgrade: newGenesisUpgrade,
            genesisBatchHash: genesisBatchHash,
            genesisIndexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            genesisBatchCommitment: genesisBatchCommitment,
            diamondCut: newDiamondCutData
        });

        chainContractAddress.setChainCreationParams(newChainCreationParams);

        assertEq(chainContractAddress.initialCutHash(), newCutHash, "Initial cut hash update was not successful");
        assertEq(chainContractAddress.genesisUpgrade(), newGenesisUpgrade, "Genesis upgrade was not set correctly");

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory newBatchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: genesisBatchHash,
            indexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: genesisBatchCommitment
        });
        bytes32 expectedStoredBatchZero = keccak256(abi.encode(newBatchZero));

        assertEq(
            chainContractAddress.storedBatchZero(),
            expectedStoredBatchZero,
            "Stored batch zero was not set correctly"
        );
    }
}
