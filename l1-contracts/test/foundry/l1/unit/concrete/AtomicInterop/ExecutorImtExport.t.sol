// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExecutingTest} from "../BatchProcessing/Executing.t.sol";

import {IExecutor, InteropImtExport} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {InteropRoot, L2Log} from "contracts/common/Messaging.sol";
import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {Utils} from "../Utils/Utils.sol";
import {GlobalInteropIMT} from "contracts/atomic-interop/GlobalInteropIMT.sol";

/// @notice Verifies that, when a chain opts in (`setGlobalInteropImt`), executing a batch whose
/// execute data carries an interop IMT export causes the Executor to push that root into the L1
/// {GlobalInteropIMT} registry — and that the legacy (no-export) path leaves the registry untouched.
contract ExecutorImtExportTest is ExecutingTest {
    GlobalInteropIMT internal globalImt;

    function _setUpRegistry() internal {
        // The registry resolves the authorized submitter (the diamond proxy) from the Bridgehub; the
        // harness's DummyBridgehub already maps the chain to this diamond, which is the msg.sender
        // when the Executor calls the registry.
        globalImt = new GlobalInteropIMT(address(dummyBridgehub));
        // The chain admin (`owner`) opts the chain in.
        vm.prank(owner);
        IAdmin(address(executor)).setGlobalInteropImt(address(globalImt));
    }

    /// @dev Builds version-2 execute data (legacy fields + per-batch IMT exports) for the L1 path.
    function _encodeExecuteWithImt(
        IExecutor.StoredBatchInfo[] memory _batches,
        PriorityOpsBatchInfo[] memory _priorityOps,
        InteropImtExport[] memory _imtExports
    ) internal pure returns (uint256, uint256, bytes memory) {
        uint256 len = _batches.length;
        bytes memory encoded = abi.encode(
            _batches,
            _priorityOps,
            new InteropRoot[][](len),
            new L2Log[][](0),
            new bytes[][](0),
            new bytes32[](0),
            address(0),
            _imtExports
        );
        return (
            _batches[0].batchNumber,
            _batches[len - 1].batchNumber,
            bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE_WITH_IMT), encoded)
        );
    }

    function test_execute_exportsImtRootToRegistry() public {
        _setUpRegistry();
        appendPriorityOps();

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        InteropImtExport[] memory imtExports = new InteropImtExport[](1);
        imtExports[0] = InteropImtExport({imtRoot: keccak256("imtRoot1")});

        (uint256 from, uint256 to, bytes memory executeData) = _encodeExecuteWithImt(
            batches,
            Utils.generatePriorityOps(batches.length),
            imtExports
        );

        vm.prank(validator);
        executor.executeBatchesSharedBridge(address(0), from, to, executeData);

        assertEq(globalImt.chainRootOf(l2ChainId), keccak256("imtRoot1"), "IMT root exported");
        assertEq(globalImt.currentBatchNumber(l2ChainId), batches[0].batchNumber);
        assertTrue(globalImt.globalRoot() != bytes32(0), "global root advanced");
    }

    function test_execute_legacyPath_doesNotTouchRegistry() public {
        _setUpRegistry();
        appendPriorityOps();

        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = newStoredBatchInfo;

        // Legacy (version 1) execute data carries no IMT exports.
        (uint256 from, uint256 to, bytes memory executeData) = Utils.encodeExecuteBatchesDataZeroLogs(
            batches,
            Utils.generatePriorityOps(batches.length)
        );

        vm.prank(validator);
        executor.executeBatchesSharedBridge(address(0), from, to, executeData);

        assertFalse(globalImt.isChainRegistered(l2ChainId), "registry untouched on legacy path");
    }
}
