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

import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";

import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {InteropBundle, InteropCall, InteropCallStarter, MessageInclusionProof} from "contracts/common/Messaging.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";

abstract contract L2InteropCenterTestAbstract is Test, SharedL2ContractDeployer {
    function test_requestTokenTransferInterop() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        vm.deal(address(this), 1000 ether);

        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this), 0))
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));

        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: secondBridgeCalldata,
            callAttributes: callAttributes
        });

        uint256 destinationChainId = 271;
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        vm.recordLogs();

        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(271), calls, bundleAttributes);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        extractAndExecuteBundles(logs, destinationChainId);
    }

    function test_sendBundle_simple() public {
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(IBaseToken.burnMsgValue.selector),
            abi.encode()
        );
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );

        uint256 destinationChainId = 260;
        bytes memory destinationChainIdBytes = InteroperableAddress.formatEvmV1(destinationChainId);

        address targetContract = makeAddr("targetContract");
        vm.mockCall(
            targetContract,
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );
        InteropCallStarter[] memory callStarters = new InteropCallStarter[](1);

        callStarters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(targetContract),
            data: abi.encodeWithSignature("simpleCall()"),
            callAttributes: new bytes[](0)
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.executionAddress,
            InteroperableAddress.formatEvmV1(EXECUTION_ADDRESS)
        );

        bundleAttributes[1] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            InteroperableAddress.formatEvmV1(260, UNBUNDLER_ADDRESS)
        );

        vm.recordLogs();

        (bool success, bytes memory returnData) = L2_INTEROP_CENTER_ADDR.call(
            abi.encodeWithSelector(
                InteropCenter.sendBundle.selector,
                destinationChainIdBytes,
                callStarters,
                bundleAttributes
            )
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        extractAndExecuteBundles(logs, destinationChainId);

        assertTrue(success, "sendBundle should succeed");

        // Decode the returned bundle hash
        bytes32 bundleHash = abi.decode(returnData, (bytes32));
        assertNotEq(bundleHash, bytes32(0), "Bundle hash should not be zero");
    }

    function test_requestSendCall() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        vm.deal(address(this), 1000 ether);

        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this), 0))
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        bytes[] memory attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        attributes[1] = abi.encodeCall(
            IERC7786Attributes.executionAddress,
            (InteroperableAddress.formatEvmV1(EXECUTION_ADDRESS))
        );
        attributes[2] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        InteroperableAddress.parseEvmV1(InteroperableAddress.formatEvmV1(EXECUTION_ADDRESS));
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: secondBridgeCalldata,
            callAttributes: attributes
        });

        uint256 destinationChainId = 271;
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );
        vm.recordLogs();
        IERC7786GatewaySource(address(l2InteropCenter)).sendMessage(
            InteroperableAddress.formatEvmV1(destinationChainId, L2_ASSET_ROUTER_ADDR),
            calls[0].data,
            calls[0].callAttributes
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        extractAndExecuteBundles(logs, destinationChainId);
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

    function extractAndExecuteBundles(Vm.Log[] memory logs, uint256 destinationChainId) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(l2InteropCenter) &&
                logs[i].topics[0] ==
                keccak256(
                    "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes)))"
                )
            ) {
                bytes memory data = logs[i].data;
                (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
                    data,
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
                vm.prank(EXECUTION_ADDRESS);
                L2_INTEROP_HANDLER.executeBundle(bundle, proof);
            }
        }
    }
}
