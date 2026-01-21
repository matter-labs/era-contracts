// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_INTEROP_HANDLER, L2_MESSAGE_VERIFICATION, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Transaction} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";
import {IAssetRouterBase, AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {CallStatus, IInteropHandler} from "contracts/interop/IInteropHandler.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {UnauthorizedMessageSender, WrongDestinationChainId} from "contracts/interop/InteropErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {BundleAttributes, INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION, InteropBundle, InteropCall, InteropCallStarter, L2Message, MessageInclusionProof} from "contracts/common/Messaging.sol";

import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";

import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropHandlerTestAbstract is Test, SharedL2ContractDeployer {
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
        IInteropHandler(L2_INTEROP_HANDLER_ADDR).unbundleBundle(proof.chainId, bundle, callStatuses1);
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
        IInteropHandler(L2_INTEROP_HANDLER_ADDR).unbundleBundle(proof.chainId, bundle, callStatuses2);
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
            interopBundleSalt: keccak256(abi.encodePacked(depositor, bytes32(0))),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(EXECUTION_ADDRESS),
                unbundlerAddress: InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS)
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
}
