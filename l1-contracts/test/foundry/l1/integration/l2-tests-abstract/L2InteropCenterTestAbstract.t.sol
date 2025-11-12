// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {InteropBundle} from "contracts/common/Messaging.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";

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

import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

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

    function test_requestNativeTokenTransferViaLibrary_SameBaseToken() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        extractAndExecuteSingleBundle(logs, destinationChainId, EXECUTION_ADDRESS);
    }

    function test_requestNativeTokenTransferViaLibrary_DifferentBaseToken() public {
        vm.deal(address(this), 1000 ether);

        bytes32 otherBaseTokenAssetId = bytes32(uint256(uint160(makeAddr("otherBaseToken"))));

        // Mock the bridgehub's baseTokenAssetId call for the destination chain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (destinationChainId)),
            abi.encode(otherBaseTokenAssetId)
        );

        // Deploy the other base token properly
        TestnetERC20Token otherBaseToken = new TestnetERC20Token("Other Base Token", "OBT", 18);
        address otherBaseTokenAddress = address(otherBaseToken);

        // Register the token in NTV and set up asset handler
        // vm.prank is used to call from NTV context for setLegacyTokenAssetHandler
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).setLegacyTokenAssetHandler(otherBaseTokenAssetId);

        // Set tokenAddress and assetId mappings in NTV (these are still internal storage)
        bytes32 tokenAddressSlot = keccak256(abi.encode(otherBaseTokenAssetId, uint256(203)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddressSlot, bytes32(uint256(uint160(otherBaseTokenAddress))));

        bytes32 assetIdSlot = keccak256(abi.encode(otherBaseTokenAddress, uint256(204)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, assetIdSlot, otherBaseTokenAssetId);

        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Switch to destination chain to set up storage
        vm.chainId(destinationChainId);

        // Set BASE_TOKEN_ASSET_ID on destination chain L2AssetRouter (slot 256)
        vm.store(L2_ASSET_ROUTER_ADDR, bytes32(uint256(256)), otherBaseTokenAssetId);

        // Register asset handler on destination chain for source base token
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).setLegacyTokenAssetHandler(baseTokenAssetId);

        // Deploy the source base token as a bridged token on destination chain
        BridgedStandardERC20 sourceBaseToken = new BridgedStandardERC20();
        address sourceBaseTokenAddress = address(sourceBaseToken);

        // Set the nativeTokenVault storage on the token (slot 207)
        vm.store(sourceBaseTokenAddress, bytes32(uint256(207)), bytes32(uint256(uint160(L2_NATIVE_TOKEN_VAULT_ADDR))));

        // Set token mappings in NTV
        bytes32 destTokenAddressSlot = keccak256(abi.encode(baseTokenAssetId, uint256(203)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, destTokenAddressSlot, bytes32(uint256(uint160(sourceBaseTokenAddress))));

        bytes32 destAssetIdSlot = keccak256(abi.encode(sourceBaseTokenAddress, uint256(204)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, destAssetIdSlot, baseTokenAssetId);

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (destinationChainId)),
            abi.encode(otherBaseTokenAssetId)
        );

        // Switch back to original chain before executing bundle
        vm.chainId(originalChainId);

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
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
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
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.chainId(destinationChainId);
        vm.prank(executionAddress);
        L2_INTEROP_HANDLER.executeBundle(bundle, proof);
    }
}
