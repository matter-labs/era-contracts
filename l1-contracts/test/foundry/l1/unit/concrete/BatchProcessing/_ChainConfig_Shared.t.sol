// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {TESTNET_COMMIT_TIMESTAMP_NOT_OLDER} from "contracts/common/Config.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

// The executor fixture isolates DA and cryptographic verification. Configuration tests
// advance batch state through the real commit/prove/revert entry points.
abstract contract ChainConfigTest is ExecutorTest {
    function setUp() public {
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        newCommitBatchInfoZKsyncOS.firstBlockTimestamp = uint64(block.timestamp);
        newCommitBatchInfoZKsyncOS.lastBlockTimestamp = uint64(block.timestamp);
    }

    function _currentChainConfigHash() internal view returns (bytes32) {
        return
            Utils.chainConfigHash({
                _chainId: getters.getChainId(),
                _maxTxGasLimit: getters.getZKsyncOSMaxTxGasLimit(),
                _pubdataContent: getters.getPubdataContent(),
                _filteringEnabled: getters.isZKsyncOSL1TxFilteringEnabled(),
                _largeContractsEnabled: getters.isZKsyncOSLargeContractsEnabled()
            });
    }

    function _commitFirstBatch() internal returns (IExecutor.StoredBatchInfo memory) {
        newCommitBatchInfoZKsyncOS.chainConfigHash = _currentChainConfigHash();
        return _commitOSBatchGetStored(genesisStoredBatchInfo, newCommitBatchInfoZKsyncOS);
    }
}
