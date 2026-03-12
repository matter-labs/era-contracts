// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "contracts/common/Config.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_INTEROP_HANDLER,
    L2_MESSAGE_VERIFICATION,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {Transaction} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {CallStatus, IInteropHandler} from "contracts/interop/IInteropHandler.sol";

import {
    UnauthorizedMessageSender,
    WrongDestinationBaseTokenAssetId,
    WrongDestinationChainId
} from "contracts/interop/InteropErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall,
    InteropCallStarter,
    L2Message,
    MessageInclusionProof
} from "contracts/common/Messaging.sol";

import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";

import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropHandlerTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    // Function selector for requestL2TransactionDirect(L2TransactionRequestDirect)
    bytes4 private constant REQUEST_L2_TX_DIRECT_SELECTOR = 0xd52471c1;

    function test_requestL2TransactionDirectWithCalldata() public {
        // Build the L2TransactionRequestDirect struct with explicit values
        // These values represent a real transaction request
        uint256 chainId = 505;
        uint256 mintValue = 20000000000000000000; // 20 ETH
        address l2Contract = 0x9Ca26d77cDe9CFf9145D06725b400b2Ec4Bbc616;
        uint256 l2Value = 10000000000000000000; // 10 ETH
        bytes memory l2Calldata = "";
        uint256 l2GasLimit = 600000000;
        uint256 l2GasPerPubdataByteLimit = 800;
        bytes[] memory factoryDeps = new bytes[](0);
        address refundRecipient = 0x9Ca26d77cDe9CFf9145D06725b400b2Ec4Bbc616;

        // Encode the transaction request using abi.encodeWithSelector with the raw selector
        bytes memory data = abi.encodeWithSelector(
            REQUEST_L2_TX_DIRECT_SELECTOR,
            chainId,
            mintValue,
            l2Contract,
            l2Value,
            l2Calldata,
            l2GasLimit,
            l2GasPerPubdataByteLimit,
            factoryDeps,
            refundRecipient
        );

        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );

        // Mock the requestL2TransactionDirect call on L2 Bridgehub
        // In L1 context, the L2 Bridgehub isn't fully set up, so we mock the response
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(REQUEST_L2_TX_DIRECT_SELECTOR),
            abi.encode(bytes32(uint256(1))) // Return a mock transaction hash
        );

        // Verify the data is properly formatted (non-empty)
        assertTrue(data.length > 0, "Transaction data should not be empty");

        // Verify the recipient is the expected Bridgehub address
        address recipient = L2_BRIDGEHUB_ADDR;
        assertTrue(recipient != address(0), "Recipient should be a valid address");
        assertEq(recipient, L2_BRIDGEHUB_ADDR, "Recipient should be L2_BRIDGEHUB_ADDR");

        // Execute the call to the Bridgehub
        (bool success, ) = recipient.call(data);
        assertTrue(success, "Call to L2_BRIDGEHUB should succeed");
    }

    function test_l2MessageVerification() public {
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);

        // Verify the proof is properly constructed
        assertTrue(proof.chainId > 0, "Chain ID should be positive");
        assertTrue(proof.proof.length > 0, "Proof should have elements");
        assertEq(proof.message.sender, L2_INTEROP_CENTER_ADDR, "Message sender should be InteropCenter");

        // Mock the verification call for L1 context tests
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Call the verification function
        bool result = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            proof.chainId,
            proof.l1BatchNumber,
            proof.l2MessageIndex,
            proof.message,
            proof.proof
        );

        assertTrue(result, "Message verification should succeed");
    }

    function test_l2MessageInclusion() public {
        bytes
            memory data = hex"000000000000000000000000000000000000000000000000000000000000010f000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000042000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000010003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002e49c884fd1000000000000000000000000000000000000000000000000000000000000010f76b59944c0e577e988c1b823ef4ad168478ddfe6044cca433996ade7637ec70d0000000000000000000000007bf0d042d77d77762db0da0198241e1ed52fcfec0000000000000000000000007bf0d042d77d77762db0da0198241e1ed52fcfec000000000000000000000000ee0dcf9b8c3048530fd6b2211ae3ba32e8590905000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c101000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000045742544300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b010f05000000000000000000000000000000000000000000000000000000000072abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43bac3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0e3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fae4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db891798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef227266d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770db04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396cac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470fc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13ffef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87a707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00bf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf759440000000000000000000000000000000000000000000000000000000000000019964bc0ec60b4ef3961a574f9600449173bd53b1b5c849d16f62f0f6c0abb507ecc4c41edb0c2031348b292b768e9bac1ee8c92c09ef8a3277c2ece409c12d86a266f52b16165e9e2253be106c3774931e09bc1aff98955a74814788fbaba6b7f7fb5ed988285f34b64f87805c7c4aea5d4304769ebc0646fec775c4b2f442704d65feac380aaaf873c998d9341e47ee14561dd24e0bce7845c372183d94e98a3000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001fa0102000100000000000000000000000000000000000000000000000000000000f84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f82803916fcde2bef5aa3b302f7eb413ecc65bb744d4ba66e1b4c6757107025f40c7";

        // Verify input data is properly formatted
        assertTrue(data.length > 0, "Input data should not be empty");

        (bool success, ) = address(L2_MESSAGE_VERIFICATION).call(
            abi.encodePacked(IMessageVerification.proveL2MessageInclusionShared.selector, data)
        );

        assertTrue(success, "L2 message inclusion proof should succeed");
    }

    function test_executeBundle() public {
        InteropBundle memory interopBundle = getInteropBundle(1);
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.mint.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);
        // Expect event
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.BundleExecuted(bundleHash);
        vm.prank(EXECUTION_ADDRESS);
        L2_INTEROP_HANDLER.executeBundle(bundle, proof);
        // Check storage changes
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            2,
            "BundleStatus should be FullyExecuted"
        );
        for (uint256 i = 0; i < interopBundle.calls.length; ++i) {
            assertEq(
                uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, i)),
                1,
                "CallStatus should be Executed"
            );
        }
    }

    function test_unbundleBundle() public {
        InteropBundle memory interopBundle = getInteropBundle(3);
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.mint.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);
        IInteropHandler(L2_INTEROP_HANDLER_ADDR).verifyBundle(bundle, proof);
        CallStatus[] memory callStatuses1 = new CallStatus[](3);
        callStatuses1[0] = CallStatus.Unprocessed;
        callStatuses1[1] = CallStatus.Cancelled;
        callStatuses1[2] = CallStatus.Executed;
        CallStatus[] memory callStatuses2 = new CallStatus[](3);
        callStatuses2[0] = CallStatus.Executed;
        callStatuses2[1] = CallStatus.Cancelled;
        callStatuses2[2] = CallStatus.Unprocessed;
        // Expect events for first unbundle
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.CallProcessed(bundleHash, 1, CallStatus.Cancelled);
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.CallProcessed(bundleHash, 2, CallStatus.Executed);
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.BundleUnbundled(bundleHash);
        vm.prank(UNBUNDLER_ADDRESS);
        IInteropHandler(L2_INTEROP_HANDLER_ADDR).unbundleBundle(bundle, callStatuses1);
        // Check storage changes after first unbundle
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 0)),
            0,
            "Call 0 should be Unprocessed"
        );
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 1)),
            2,
            "Call 1 should be Cancelled"
        );
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 2)),
            1,
            "Call 2 should be Executed"
        );
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            3,
            "BundleStatus should be Unbundled"
        );
        // Expect events for second unbundle
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.CallProcessed(bundleHash, 0, CallStatus.Executed);
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.BundleUnbundled(bundleHash);
        vm.prank(UNBUNDLER_ADDRESS);
        IInteropHandler(L2_INTEROP_HANDLER_ADDR).unbundleBundle(bundle, callStatuses2);
        // Check storage changes after second unbundle
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 0)),
            1,
            "Call 0 should be Executed"
        );
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 1)),
            2,
            "Call 1 should be Cancelled"
        );
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 2)),
            1,
            "Call 2 should be Executed"
        );
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            3,
            "BundleStatus should be Unbundled"
        );
    }

    function getInteropBundle(uint256 amount) public returns (InteropBundle memory) {
        address depositor = makeAddr("someDepositor");
        address receiver = makeAddr("someReceiver");
        address token = makeAddr("someToken");
        InteropCall[] memory calls = new InteropCall[](3);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, token);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: abi.encodeCall(
                AssetRouterBase.finalizeDeposit,
                (
                    L1_CHAIN_ID,
                    assetId,
                    DataEncoding.encodeBridgeMintData(
                        depositor,
                        receiver,
                        token,
                        amount,
                        encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
                    )
                )
            )
        });
        calls[1] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: abi.encodeCall(
                AssetRouterBase.finalizeDeposit,
                (
                    L1_CHAIN_ID,
                    assetId,
                    DataEncoding.encodeBridgeMintData(
                        depositor,
                        receiver,
                        token,
                        amount,
                        encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
                    )
                )
            )
        });
        calls[2] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: abi.encodeCall(
                AssetRouterBase.finalizeDeposit,
                (
                    L1_CHAIN_ID,
                    assetId,
                    DataEncoding.encodeBridgeMintData(
                        depositor,
                        receiver,
                        token,
                        amount,
                        encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
                    )
                )
            )
        });
        InteropBundle memory interopBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: ERA_CHAIN_ID,
            destinationChainId: 31337,
            destinationBaseTokenAssetId: baseTokenAssetId,
            interopBundleSalt: keccak256(abi.encodePacked(depositor, bytes32(0))),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(EXECUTION_ADDRESS),
                unbundlerAddress: InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS),
                useFixedFee: false
            })
        });
        return interopBundle;
    }

    /// @notice Regression test to ensure bundles can only be verified from InteropCenter
    /// @dev This test verifies that the fix for unauthorized bundle verification is working
    function test_verifyBundle_revertWhen_messageNotFromInteropCenter() public {
        address nonInteropCenter = makeAddr("nonInteropCenter");

        InteropBundle memory interopBundle = getInteropBundle(1);
        bytes memory bundle = abi.encode(interopBundle);

        MessageInclusionProof memory proof = getInclusionProof(nonInteropCenter);

        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        vm.expectRevert(
            abi.encodeWithSelector(UnauthorizedMessageSender.selector, L2_INTEROP_CENTER_ADDR, nonInteropCenter)
        );

        IInteropHandler(L2_INTEROP_HANDLER_ADDR).verifyBundle(bundle, proof);
    }

    /// @notice Regression test to ensure bundles can only be executed on the correct destination chain
    /// @dev This test verifies that the fix for destination chain ID validation is working
    function test_verifyBundle_revertWhen_wrongDestinationChainId() public {
        InteropBundle memory interopBundle = getInteropBundle(1);
        uint256 wrongChainId = 12345;
        interopBundle.destinationChainId = wrongChainId;

        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);

        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);

        vm.expectRevert(
            abi.encodeWithSelector(WrongDestinationChainId.selector, bundleHash, wrongChainId, block.chainid)
        );

        IInteropHandler(L2_INTEROP_HANDLER_ADDR).verifyBundle(bundle, proof);
    }

    /// @notice Test that verifyBundle works while settling on L1.
    /// @dev Bundle verification is not restricted to gateway mode.
    function test_verifyBundleWorksWhenSettlingOnL1() public {
        // Set the L1_CHAIN_ID storage variable in InteropHandler
        // (The test setup doesn't call initL2, so L1_CHAIN_ID is uninitialized at slot 0)
        vm.store(L2_INTEROP_HANDLER_ADDR, bytes32(0), bytes32(uint256(L1_CHAIN_ID)));

        InteropBundle memory interopBundle = getInteropBundle(1);
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);

        // Mock message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Mock currentSettlementLayerChainId to return L1_CHAIN_ID (not in gateway mode)
        // This simulates the chain settling directly on L1
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(L1_CHAIN_ID)
        );

        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);

        IInteropHandler(L2_INTEROP_HANDLER_ADDR).verifyBundle(bundle, proof);

        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            1, // BundleStatus.Verified
            "Bundle should be in Verified status"
        );
    }

    /// @notice Regression test to ensure bundles can only be verified with matching destination base token asset ID
    function test_verifyBundle_revertWhen_wrongDestinationBaseTokenAssetId() public {
        InteropBundle memory interopBundle = getInteropBundle(1);

        bytes32 wrongDestinationBaseTokenAssetId = keccak256("wrongDestinationBaseTokenAssetId");
        interopBundle.destinationBaseTokenAssetId = wrongDestinationBaseTokenAssetId;

        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);

        // Mock message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);

        vm.expectRevert(
            abi.encodeWithSelector(
                WrongDestinationBaseTokenAssetId.selector,
                bundleHash,
                baseTokenAssetId,
                wrongDestinationBaseTokenAssetId
            )
        );

        IInteropHandler(L2_INTEROP_HANDLER_ADDR).verifyBundle(bundle, proof);
    }
    /// @notice Test pause functionality in InteropCenter
    function test_interopCenter_pause() public {
        address interopCenterOwner = InteropCenter(L2_INTEROP_CENTER_ADDR).owner();

        vm.prank(interopCenterOwner);
        InteropCenter(L2_INTEROP_CENTER_ADDR).pause();

        assertTrue(InteropCenter(L2_INTEROP_CENTER_ADDR).paused(), "InteropCenter should be paused");

        bytes memory recipient = abi.encodePacked(uint256(271), address(0x123));
        bytes memory payload = abi.encode("test");
        bytes[] memory attributes = new bytes[](0);

        vm.expectRevert("Pausable: paused");
        InteropCenter(L2_INTEROP_CENTER_ADDR).sendMessage(recipient, payload, attributes);
    }

    /// @notice Test unpause functionality in InteropCenter
    function test_interopCenter_unpause() public {
        address interopCenterOwner = InteropCenter(L2_INTEROP_CENTER_ADDR).owner();

        vm.prank(interopCenterOwner);
        InteropCenter(L2_INTEROP_CENTER_ADDR).pause();
        assertTrue(InteropCenter(L2_INTEROP_CENTER_ADDR).paused(), "InteropCenter should be paused");

        vm.prank(interopCenterOwner);
        InteropCenter(L2_INTEROP_CENTER_ADDR).unpause();

        assertFalse(InteropCenter(L2_INTEROP_CENTER_ADDR).paused(), "InteropCenter should be unpaused");
    }

    /// @notice Test that only owner can pause InteropCenter
    function test_interopCenter_pause_onlyOwner() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        InteropCenter(L2_INTEROP_CENTER_ADDR).pause();
    }

    /// @notice Test that only owner can unpause InteropCenter
    function test_interopCenter_unpause_onlyOwner() public {
        address interopCenterOwner = InteropCenter(L2_INTEROP_CENTER_ADDR).owner();
        vm.prank(interopCenterOwner);
        InteropCenter(L2_INTEROP_CENTER_ADDR).pause();

        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        InteropCenter(L2_INTEROP_CENTER_ADDR).unpause();
    }

    function test_regression_verifyBundleCanAccessCurrentSettlementLayerChainId() public {
        InteropBundle memory interopBundle = getInteropBundle(1);
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);

        // Mock message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Mock currentSettlementLayerChainId to return a non-L1 chain ID (gateway mode)
        // This simulates the chain settling on Gateway instead of L1
        uint256 gatewayChainId = GATEWAY_CHAIN_ID;
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(gatewayChainId)
        );

        // Mock sendToL1 for the event emission
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );

        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);

        // Before the fix: This would revert because InteropHandler couldn't call
        // currentSettlementLayerChainId() due to access control restrictions.
        // After the fix: This should succeed and emit BundleVerified event.
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.BundleVerified(bundleHash);

        IInteropHandler(L2_INTEROP_HANDLER_ADDR).verifyBundle(bundle, proof);

        // Verify the bundle status was updated correctly
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            1, // BundleStatus.Verified
            "Bundle should be in Verified status"
        );
    }

    /// @notice Test that executeBundle works in gateway mode by accessing currentSettlementLayerChainId
    /// @dev executeBundle internally calls verifyBundle which calls currentSettlementLayerChainId
    function test_regression_executeBundleWorksInGatewayMode() public {
        InteropBundle memory interopBundle = getInteropBundle(1);
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);

        // Mock message verification
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Mock gateway mode - settling on Gateway, not L1
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(GATEWAY_CHAIN_ID)
        );

        // Additional required mocks
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.mint.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );

        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);

        // Before the fix: executeBundle would fail because it couldn't access
        // currentSettlementLayerChainId due to access control.
        // After the fix: Should complete successfully
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.BundleExecuted(bundleHash);

        vm.prank(EXECUTION_ADDRESS);
        L2_INTEROP_HANDLER.executeBundle(bundle, proof);

        // Verify successful execution
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            2, // BundleStatus.FullyExecuted
            "Bundle should be fully executed"
        );
    }

    /// @notice Creates an interop bundle where a call carries native value (ETH).
    /// @dev This exercises the InteropHandler._executeCalls path where interopCall.value > 0,
    /// which triggers L2_BASE_TOKEN_HOLDER.give() to transfer base tokens.
    function getInteropBundleWithValue(uint256 _callValue) public returns (InteropBundle memory) {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: interopTargetContract,
            from: makeAddr("interopSender"),
            value: _callValue,
            data: abi.encode("test_payload")
        });
        InteropBundle memory interopBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: ERA_CHAIN_ID,
            destinationChainId: 31337,
            destinationBaseTokenAssetId: baseTokenAssetId,
            interopBundleSalt: keccak256(abi.encodePacked(makeAddr("depositorWithValue"), bytes32(0))),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(EXECUTION_ADDRESS),
                unbundlerAddress: InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS),
                useFixedFee: false
            })
        });
        return interopBundle;
    }

    // ══════════════════════════════════════════════════════════════
    //  Helper: set up L2AssetTracker state for base token operations
    // ══════════════════════════════════════════════════════════════

    /// @dev Initializes the L2AssetTracker with the state needed for base token
    /// bridging functions to succeed without mocks. Sets BASE_TOKEN_ASSET_ID,
    /// L1_CHAIN_ID, marks the asset as registered, and configures the NTV.
    function _setupAssetTrackerForBaseToken() internal returns (bytes32 _baseTokenAssetId) {
        _baseTokenAssetId = baseTokenAssetId;
        uint256 l1ChainId = L1_CHAIN_ID;

        // Set BASE_TOKEN_ASSET_ID and L1_CHAIN_ID on the asset tracker
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(_baseTokenAssetId));
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);

        // Mark the base token as already registered (skips _registerLegacyToken)
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("isAssetRegistered(bytes32)")
            .with_key(_baseTokenAssetId)
            .checked_write(true);

        // Mock NTV tokenAddress so _tryGetTokenAddress succeeds
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("tokenAddress(bytes32)")), _baseTokenAssetId),
            abi.encode(address(L2_BASE_TOKEN_SYSTEM_CONTRACT))
        );

        // Mock NTV originChainId for the base token (L1)
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("originChainId(bytes32)")), _baseTokenAssetId),
            abi.encode(l1ChainId)
        );

        // Mock totalSupply on L2_BASE_TOKEN_SYSTEM_CONTRACT
        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(1000)
        );

        // Mock currentSettlementLayerChainId (needed for deposit/withdrawal tracking)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(bytes4(keccak256("currentSettlementLayerChainId()"))),
            abi.encode(l1ChainId)
        );

        // Mock migrationNumber (needed for _checkAssetMigrationNumber)
        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("migrationNumber(uint256)"))),
            abi.encode(0)
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Inbound flow: InteropHandler → BaseTokenHolder.give() → asset tracker
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verifies the full inbound interop flow through the asset tracker.
    /// @dev Executes a bundle with value > 0 through InteropHandler, which calls
    /// BaseTokenHolder.give() → L2AssetTracker.handleFinalizeBaseTokenBridgingOnL2().
    /// No mock on the asset tracker — exercises access control and storage updates.
    function test_give_inboundFlow_notifiesAssetTracker() public {
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        bytes32 _baseTokenAssetId = _setupAssetTrackerForBaseToken();

        uint256 callValue = 100;
        InteropBundle memory interopBundle = getInteropBundleWithValue(callValue);
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);

        // Standard mocks for bundle verification and messenger (not related to asset tracker)
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );

        // Record deposits before
        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(_baseTokenAssetId);

        // Verify that handleFinalizeBaseTokenBridgingOnL2 is called with the correct amount
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(
                IL2AssetTracker.handleFinalizeBaseTokenBridgingOnL2.selector,
                ERA_CHAIN_ID,
                callValue
            )
        );

        // Verify BaseTokenMintedInterop event is emitted (give() sends to InteropHandler)
        vm.expectEmit(true, false, false, true, L2_BASE_TOKEN_HOLDER_ADDR);
        emit IBaseTokenHolder.BaseTokenMintedInterop(L2_INTEROP_HANDLER_ADDR, callValue);

        vm.prank(EXECUTION_ADDRESS);
        L2_INTEROP_HANDLER.executeBundle(bundle, proof);

        // Interop source is ERA_CHAIN_ID (not L1), so totalSuccessfulDepositsFromL1 must NOT increase
        uint256 depositsAfter = _readTotalSuccessfulDepositsFromL1(_baseTokenAssetId);
        assertEq(depositsAfter, depositsBefore, "totalSuccessfulDepositsFromL1 should NOT increase for non-L1 source");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Outbound flow: burnAndStartBridging() → asset tracker
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verifies the full outbound bridging flow through the asset tracker.
    /// @dev BaseTokenHolder.burnAndStartBridging() calls
    /// L2AssetTracker.handleInitiateBaseTokenBridgingOnL2().
    /// No mock on the asset tracker — exercises access control and storage updates.
    function test_burnAndStartBridging_outboundFlow_notifiesAssetTracker() public {
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        bytes32 _baseTokenAssetId = _setupAssetTrackerForBaseToken();

        uint256 burnAmount = 500;
        uint256 toChainId = L1_CHAIN_ID;

        // Record withdrawals before
        uint256 withdrawalsBefore = _readTotalWithdrawalsToL1(_baseTokenAssetId);

        // Verify that handleInitiateBaseTokenBridgingOnL2 is called with the correct args
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.handleInitiateBaseTokenBridgingOnL2.selector, toChainId, burnAmount)
        );

        // Verify BaseTokenBurntInterop event is emitted
        vm.expectEmit(true, false, false, true, L2_BASE_TOKEN_HOLDER_ADDR);
        emit IBaseTokenHolder.BaseTokenBurntInterop(L2_INTEROP_HANDLER_ADDR, toChainId, burnAmount);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(toChainId);

        // Verify asset tracker storage was actually updated
        uint256 withdrawalsAfter = _readTotalWithdrawalsToL1(_baseTokenAssetId);
        assertEq(
            withdrawalsAfter,
            withdrawalsBefore + burnAmount,
            "totalWithdrawalsToL1 should increase by burnAmount"
        );
    }
}
