// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {
    PubdataContent,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
    ZKSYNC_OS_MAX_BLOCK_GAS_LIMIT
} from "contracts/common/Config.sol";

contract ChainConfigGetterTest is ExecutorTest {
    function test_DefaultConfigHash() public view {
        assertEq(getters.getZKsyncOSChainConfigHash(), Utils.defaultChainConfigHash(l2ChainId));
    }

    function testFuzz_ConfigHashTracksGasLimit(uint64 _gasLimit) public {
        uint64 gasLimit = uint64(bound(_gasLimit, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, ZKSYNC_OS_MAX_BLOCK_GAS_LIMIT));
        vm.prank(owner);
        admin.setZKsyncOSMaxTxGasLimit(gasLimit);
        assertEq(
            getters.getZKsyncOSChainConfigHash(),
            Utils.chainConfigHash(l2ChainId, gasLimit, PubdataContent.FULL_PUBDATA)
        );
    }

    function test_ConfigHashTracksPubdataContent() public {
        bytes32 previousHash = getters.getZKsyncOSChainConfigHash();
        vm.prank(owner);
        admin.setPubdataContent(PubdataContent.LOGS_ONLY);
        assertEq(
            getters.getZKsyncOSChainConfigHash(),
            Utils.chainConfigHash(l2ChainId, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, PubdataContent.LOGS_ONLY)
        );
        assertNotEq(getters.getZKsyncOSChainConfigHash(), previousHash);
    }
}
