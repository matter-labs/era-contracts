// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";

import {L2InteropTestUtils, BundleExecutionResult} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropNativeTokenDifferentBaseTestAbstract is L2InteropTestUtils {
    function test_requestNativeTokenTransferViaLibrary_DifferentBaseToken() public {
        vm.deal(address(this), 1000 ether);

        bytes32 otherBaseTokenAssetId = bytes32(uint256(uint160(makeAddr("otherBaseToken"))));

        // Mock the bridgehub's baseTokenAssetId call for the destination chain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (destinationChainId)),
            abi.encode(otherBaseTokenAssetId)
        );

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (originalChainId)),
            abi.encode(baseTokenAssetId)
        );

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (block.chainid)),
            abi.encode(baseTokenAssetId)
        );
        // Deploy the other base token properly
        TestnetERC20Token otherBaseToken = new TestnetERC20Token("Other Base Token", "OBT", 18);
        address otherBaseTokenAddress = address(otherBaseToken);
        vm.mockCall(
            otherBaseTokenAddress,
            abi.encodeWithSelector(BridgedStandardERC20.bridgeBurn.selector),
            abi.encode()
        );
        vm.mockCall(
            otherBaseTokenAddress,
            abi.encodeCall(IBridgedStandardToken.originToken, ()),
            abi.encode(address(otherBaseTokenAddress))
        );

        // Register the token in NTV and set up asset handler
        // vm.prank is used to call from NTV context for setLegacyTokenAssetHandler
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).setLegacyTokenAssetHandler(otherBaseTokenAssetId);

        // Set tokenAddress and assetId mappings in NTV (these are still internal storage)
        bytes32 originChainIdSlot = keccak256(abi.encode(otherBaseTokenAssetId, uint256(202)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, originChainIdSlot, bytes32(uint256(destinationChainId)));

        bytes32 tokenAddressSlot = keccak256(abi.encode(otherBaseTokenAssetId, uint256(203)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddressSlot, bytes32(uint256(uint160(otherBaseTokenAddress))));

        bytes32 assetIdSlot = keccak256(abi.encode(otherBaseTokenAddress, uint256(204)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, assetIdSlot, otherBaseTokenAssetId);

        vm.recordLogs();

        uint256 amount = 100;

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropLibrary.buildSendDestinationChainBaseTokenCall(
            destinationChainId,
            interopTargetContract,
            amount
        );
        bytes memory empty = hex"";
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (amount));

        calls[1] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(interopTargetContract),
            data: empty,
            callAttributes: callAttributes
        });
        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);

        L2_INTEROP_CENTER.sendBundle{value: amount}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );
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
        bytes32 destOriginChainIdSlot = keccak256(abi.encode(baseTokenAssetId, uint256(202)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, destOriginChainIdSlot, bytes32(uint256(originalChainId)));

        bytes32 destTokenAddressSlot = keccak256(abi.encode(baseTokenAssetId, uint256(203)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, destTokenAddressSlot, bytes32(uint256(uint160(sourceBaseTokenAddress))));

        bytes32 destAssetIdSlot = keccak256(abi.encode(sourceBaseTokenAddress, uint256(204)));
        vm.store(L2_NATIVE_TOKEN_VAULT_ADDR, destAssetIdSlot, baseTokenAssetId);

        // Switch back to original chain before executing bundle
        vm.chainId(originalChainId);

        // Verify bundle was emitted
        assertTrue(logs.length > 0, "Expected logs to be emitted for cross-chain token transfer");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs,
            destinationChainId,
            EXECUTION_ADDRESS
        );

        // Verify the bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Bundle hash should be non-zero");
        assertEq(result.callCount, 2, "Bundle should contain 2 calls for different base token transfer");
    }
}
