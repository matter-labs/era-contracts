// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {InteropBundle} from "contracts/common/Messaging.sol";
import {
    AtomicFinalityProof,
    AtomicFlowPreimage,
    ATOMIC_FLOW_PREIMAGE_VERSION
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {InteropPreviewHash} from "contracts/interop/InteropErrors.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";

/// @notice Struct to hold bundle execution result for assertions
struct BundleExecutionResult {
    bytes32 bundleHash;
    uint256 callCount;
    uint256 destinationChainId;
}

abstract contract L2InteropTestUtils is Test, SharedL2ContractDeployer {
    /// @dev Token amount the atomic integration fixtures move.
    uint256 internal constant TRANSFER_AMOUNT = 100;

    uint256 destinationChainId = INTEROP_DESTINATION_CHAIN_ID;
    bytes32 destinationBaseTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

    /// @dev The AtomicFlowManager `append`/`requireFlowFinalized` gates are mocked to succeed in
    /// {SharedL2ContractDeployer.setUp}; the real gates are covered by the atomic suites and, on a
    /// local node, by the anvil-interop atomic-swap spec.

    /// @notice Returns a copy of `_attrs` with the mandatory ERC-7786 `atomicBundle` attribute appended.
    /// @dev Every interop send must be atomic (see {InteropCenter}); without this attribute the send
    ///      reverts with `NonAtomicSendUnsupported`. The flow metadata is a placeholder because the
    ///      `AtomicFlowManager.append` gate is mocked in setUp. Use this to wrap inline attribute arrays;
    ///      arrays produced by {InteropLibrary.buildBundleAttributes} already include the attribute.
    function _withAtomicBundle(bytes[] memory _attrs) internal pure returns (bytes[] memory out) {
        out = new bytes[](_attrs.length + 1);
        for (uint256 i = 0; i < _attrs.length; ++i) {
            out[i] = _attrs[i];
        }
        out[_attrs.length] = abi.encodeCall(
            IERC7786Attributes.atomicBundle,
            (
                AtomicFlowPreimage({
                    version: ATOMIC_FLOW_PREIMAGE_VERSION,
                    deadline: type(uint64).max,
                    settlementLayerChainId: 0,
                    legBundleHashes: new bytes32[](0),
                    legSourceChainIds: new uint256[](0)
                }),
                uint256(0)
            )
        );
    }

    function extractAndExecuteSingleBundle(
        Vm.Log[] memory logs,
        uint256 _destinationChainId,
        address executionAddress
    ) internal returns (BundleExecutionResult memory result) {
        bytes memory data = extractFirstBundleFromLogs(logs);
        result = executeBundle(data, executionAddress, _destinationChainId);
    }

    function extractFirstBundleFromLogs(Vm.Log[] memory logs) internal returns (bytes memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(l2InteropCenter) &&
                logs[i].topics[0] ==
                    keccak256(
                        "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes,bool,bytes32)))"
                    )
            ) {
                data = logs[i].data;
                break;
            }
        }
    }

    function executeBundle(
        bytes memory logsData,
        address executionAddress,
        uint256 _destinationChainId
    ) internal returns (BundleExecutionResult memory result) {
        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );
        bytes memory bundle = abi.encode(interopBundle);

        // Finality is proven via the AtomicFlowManager's IMT gate, mocked to succeed here (the real
        // gate is covered by the atomic suites), so a default AtomicFinalityProof suffices.
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundle);
        AtomicFinalityProof memory finality;

        vm.mockCall(
            L2_ATOMIC_FLOW_MANAGER_ADDR,
            abi.encodeWithSelector(IAtomicFlowManager.requireFlowFinalized.selector),
            ""
        );
        vm.chainId(_destinationChainId);
        vm.prank(executionAddress);
        L2_INTEROP_HANDLER.executeAtomicBundle(bundle, finality);

        result = BundleExecutionResult({
            bundleHash: bundleHash,
            callCount: interopBundle.calls.length,
            destinationChainId: _destinationChainId
        });
    }

    /// @notice Asserts that a bundle was executed successfully
    /// @param result The bundle execution result to verify
    function assertBundleExecuted(BundleExecutionResult memory result) internal view {
        // Verify bundle status is FullyExecuted (value 2)
        assertEq(
            uint256(L2InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(result.bundleHash)),
            2,
            "Bundle status should be FullyExecuted"
        );

        // Verify all call statuses are Executed (value 1)
        for (uint256 i = 0; i < result.callCount; i++) {
            assertEq(
                uint256(L2InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(result.bundleHash, i)),
                1,
                string(abi.encodePacked("Call ", vm.toString(i), " status should be Executed"))
            );
        }
    }

    /// @dev Reads a hash out of the `previewBundleHash`/`previewMessageHash` quoters, which always
    /// revert with `InteropPreviewHash(bytes32)` after running (and unwinding) the real assembly.
    /// @dev The hash is caller-dependent and feeds `flowId`, so a preview taken as the wrong sender
    /// fails much later as a proof mismatch. Pass `address(this)` when the send is unpranked.
    function _decodePreviewHash(address _sender, bytes memory _callData) internal returns (bytes32 predicted) {
        vm.prank(_sender);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = address(l2InteropCenter).call(_callData);
        require(
            !ok && ret.length == 36 && bytes4(ret) == InteropPreviewHash.selector,
            "preview must revert with InteropPreviewHash (quoter pattern)"
        );
        // ret layout: 4-byte selector followed by the abi-encoded bytes32 hash.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            predicted := mload(add(ret, 0x24))
        }
    }

    /// @dev One second-bridge call starter transferring `_amount` of `_l2Token` to `_receiver`.
    function _tokenCallStarter(
        address _l2Token,
        uint256 _amount,
        address _receiver
    ) internal view returns (InteropCallStarter[] memory calls) {
        bytes memory secondBridgeCalldata = InteropLibrary.buildSecondBridgeCalldata(
            L2_NATIVE_TOKEN_VAULT.assetId(_l2Token),
            _amount,
            _receiver,
            address(0)
        );
        calls = new InteropCallStarter[](1);
        calls[0] = InteropLibrary.buildSecondBridgeCall(secondBridgeCalldata, L2_ASSET_ROUTER_ADDR);
    }
}
