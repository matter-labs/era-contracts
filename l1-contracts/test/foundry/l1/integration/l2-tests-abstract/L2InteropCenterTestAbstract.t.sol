// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {InteropBundle} from "contracts/common/Messaging.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";

import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {InteropBundle, InteropCall, CallStatus, InteropCallStarter, MessageInclusionProof} from "contracts/common/Messaging.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";

import {InteropLibrary} from "contracts/interop/InteropLibrary.sol";

abstract contract L2InteropCenterTestAbstract is Test, SharedL2ContractDeployer {
    uint256 destinationChainId = 271;

    function test_requestTokenTransferInteropViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendToken(destinationChainId, l2TokenAddress, 100, address(this), UNBUNDLER_ADDRESS);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        extractAndExecuteSingleBundle(logs, destinationChainId, EXECUTION_ADDRESS);
    }

    function test_requestSendCallViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        vm.deal(address(this), 1000 ether);

        vm.recordLogs();

        InteropLibrary.sendCall(
            destinationChainId,
            interopTargetContract,
            abi.encodeWithSignature("simpleCall()"),
            EXECUTION_ADDRESS,
            UNBUNDLER_ADDRESS
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        extractAndExecuteSingleBundle(logs, destinationChainId, EXECUTION_ADDRESS);
    }

    function test_requestNativeTokenTransferViaLibrary() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        extractAndExecuteSingleBundle(logs, destinationChainId, EXECUTION_ADDRESS);
    }

    function test_executeBundleViaReceiveMessage() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        bytes memory logsData = extractFirstBundleFromLogs(logs1);
        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, block.chainid);

        vm.recordLogs();

        InteropLibrary.sendCall(
            destinationChainId,
            L2_INTEROP_HANDLER_ADDR,
            abi.encodeCall(L2_INTEROP_HANDLER.executeBundle, (bundle, proof)),
            EXECUTION_ADDRESS,
            UNBUNDLER_ADDRESS
        );
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        extractAndExecuteSingleBundle(logs2, destinationChainId, EXECUTION_ADDRESS);
    }

    function test_unbundleBundleViaReceiveMessage() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        bytes memory logsData = extractFirstBundleFromLogs(logs1);
        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, block.chainid);

        vm.chainId(destinationChainId);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        L2_INTEROP_HANDLER.verifyBundle(bundle, proof);
        vm.chainId(originalChainId);

        vm.recordLogs();

        CallStatus[] memory callStatuses = new CallStatus[](1);
        callStatuses[0] = CallStatus.Executed;
        vm.prank(UNBUNDLER_ADDRESS);
        InteropLibrary.sendCall(
            destinationChainId,
            L2_INTEROP_HANDLER_ADDR,
            abi.encodeCall(L2_INTEROP_HANDLER.unbundleBundle, (originalChainId, bundle, callStatuses)),
            UNBUNDLER_ADDRESS,
            UNBUNDLER_ADDRESS
        );
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        extractAndExecuteSingleBundle(logs2, destinationChainId, UNBUNDLER_ADDRESS);
    }

    function test_sendMessageToL1ViaLibrary() public {
        InteropLibrary.sendMessage("testing interop");
    }

    function test_supportsAttributes() public {
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(IERC7786Attributes.indirectCall.selector),
            true
        );
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(
                IERC7786GatewaySource.supportsAttribute.selector
            ),
            false
        );
    }

    function extractAndExecuteSingleBundle(
        Vm.Log[] memory logs,
        uint256 destinationChainId,
        address executionAddress
    ) internal {
        bytes memory data = extractFirstBundleFromLogs(logs);
        executeBundle(data, executionAddress);
    }

    function extractFirstBundleFromLogs(Vm.Log[] memory logs) internal returns (bytes memory data) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(l2InteropCenter) &&
                logs[i].topics[0] ==
                keccak256(
                    "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes)))"
                )
            ) {
                data = logs[i].data;
                break;
            }
        }
    }

    function executeBundle(bytes memory logsData, address executionAddress) internal {
        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, block.chainid);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.chainId(destinationChainId);
        vm.prank(executionAddress);
        L2_INTEROP_HANDLER.executeBundle(bundle, proof);
    }
}
