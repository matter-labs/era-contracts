// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Transaction} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData, IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {IInteropHandler, CallStatus} from "contracts/interop/IInteropHandler.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {UnauthorizedMessageSender, WrongDestinationChainId} from "contracts/interop/InteropErrors.sol";
import {InteroperableAddress} from "@openzeppelin/contracts-master/utils/draft-InteroperableAddress.sol";
import {IAssetRouterBase, NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {SharedL2ContractDeployer, SystemContractsArgs} from "./_SharedL2ContractDeployer.sol";
import {BUNDLE_IDENTIFIER, BridgehubL2TransactionRequest, InteropBundle, InteropCall, InteropCallStarter, L2CanonicalTransaction, L2Log, L2Message, MessageInclusionProof, TxStatus, BundleAttributes, INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION} from "contracts/common/Messaging.sol";
import {DummyL2StandardTriggerAccount} from "../../../../../contracts/dev-contracts/test/DummyL2StandardTriggerAccount.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {L2_INTEROP_ACCOUNT_ADDR, L2_STANDARD_TRIGGER_ACCOUNT_ADDR} from "./Utils.sol";
import {GasFields, InteropTrigger, TRIGGER_IDENTIFIER} from "contracts/dev-contracts/test/Utils.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";

abstract contract L2InteropTestAbstract is Test, SharedL2ContractDeployer {
    address constant UNBUNDLER_ADDRESS = address(0x1);
    address constant EXECUTION_ADDRESS = address(0x2);

    function test_requestL2TransactionDirectWithCalldata() public {
        // Note: get this from real local txs
        bytes
            memory data = hex"d52471c1000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001f9000000000000000000000000000000000000000000000001158e460913d000000000000000000000000000009ca26d77cde9cff9145d06725b400b2ec4bbc6160000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000023c34600000000000000000000000000000000000000000000000000000000000000032000000000000000000000000000000000000000000000000000000000000001400000000000000000000000009ca26d77cde9cff9145d06725b400b2ec4bbc61600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );
        address recipient = L2_BRIDGEHUB_ADDR;
        // (bool success, ) = recipient.call(data);
        // assertTrue(success);
    }

    function test_realData_sendBundle() public {
        // Note: get this from real local txs
        bytes
            memory data = hex"f044849f0000000000000000000000000000000000000000000000000000000000000104000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000001000300000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000c1017a005cb19c843f9446854b7cd15e02a0d5a3bda7f843b74d7bd284551ce8e768000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000064000000000000000000000000ec5ed4c53525423385f9d6e0a7d9d78e82c563e7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000024c8496ea7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(0))
        );
        address recipient = L2_INTEROP_CENTER_ADDR;
        // (bool success, ) = recipient.call(data);
        // assertTrue(success);
    }

    function getInclusionProof(address messageSender) public view returns (MessageInclusionProof memory) {
        bytes32[] memory proof = new bytes32[](27);
        proof[0] = bytes32(0x010f050000000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba);
        proof[2] = bytes32(0xc3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0);
        proof[3] = bytes32(0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111);
        proof[4] = bytes32(0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa);
        proof[5] = bytes32(0xe4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db89);
        proof[6] = bytes32(0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272);
        proof[7] = bytes32(0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d);
        proof[8] = bytes32(0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c);
        proof[9] = bytes32(0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db);
        proof[10] = bytes32(0x124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470f);
        proof[11] = bytes32(0xc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13f);
        proof[12] = bytes32(0xfef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87);
        proof[13] = bytes32(0xa707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00b);
        proof[14] = bytes32(0xf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291);
        proof[15] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);
        proof[16] = bytes32(0x000000000000000000000000000000000000000000000000000000000000001e);
        proof[17] = bytes32(0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21);
        proof[18] = bytes32(0x72bb6e886e3de761d93578a590bfe0e44fb544481eb63186f6a6d184aec321a8);
        proof[19] = bytes32(0x3cc519adb13de86ec011fa462394c5db945103c4d35919c9433d7b990de49c87);
        proof[20] = bytes32(0xcc52bf2ee1507ce0b5dbf31a95ce4b02043c142aab2466fc24db520852cddf5f);
        proof[21] = bytes32(0x40ad48c159fc740c32e9b540f79561a4760501ef80e32c61e477ac3505d3dabd);
        proof[22] = bytes32(0x0000000000000000000000000000009f00000000000000000000000000000001);
        proof[23] = bytes32(0x00000000000000000000000000000000000000000000000000000000000001fa);
        proof[24] = bytes32(0x0102000100000000000000000000000000000000000000000000000000000000);
        proof[25] = bytes32(0xf84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f828);
        proof[26] = bytes32(0xe25714e53790167f58b1da56145a1c025a461008fe358f583f53d764000ca847);

        return
            MessageInclusionProof({
                chainId: ERA_CHAIN_ID,
                l1BatchNumber: 31,
                l2MessageIndex: 0,
                message: L2Message(
                    0,
                    address(messageSender),
                    hex"9c884fd1000000000000000000000000000000000000000000000000000000000000010f76b59944c0e577e988c1b823ef4ad168478ddfe6044cca433996ade7637ec70d00000000000000000000000083aeb38092d5f5a5cf7fb8ccf94c981c1d37d81300000000000000000000000083aeb38092d5f5a5cf7fb8ccf94c981c1d37d813000000000000000000000000ee0dcf9b8c3048530fd6b2211ae3ba32e8590905000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c1010000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000004574254430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000"
                ),
                proof: proof
            });
    }

    function test_l2MessageVerification() public {
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR);
        L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            proof.chainId,
            proof.l1BatchNumber,
            proof.l2MessageIndex,
            proof.message,
            proof.proof
        );
    }

    function test_l2MessageInclusion() public {
        bytes
            memory data = hex"000000000000000000000000000000000000000000000000000000000000010f000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000042000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000010003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002e49c884fd1000000000000000000000000000000000000000000000000000000000000010f76b59944c0e577e988c1b823ef4ad168478ddfe6044cca433996ade7637ec70d0000000000000000000000007bf0d042d77d77762db0da0198241e1ed52fcfec0000000000000000000000007bf0d042d77d77762db0da0198241e1ed52fcfec000000000000000000000000ee0dcf9b8c3048530fd6b2211ae3ba32e8590905000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c101000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000045742544300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b010f05000000000000000000000000000000000000000000000000000000000072abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43bac3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0e3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fae4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db891798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef227266d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770db04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396cac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470fc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13ffef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87a707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00bf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf759440000000000000000000000000000000000000000000000000000000000000019964bc0ec60b4ef3961a574f9600449173bd53b1b5c849d16f62f0f6c0abb507ecc4c41edb0c2031348b292b768e9bac1ee8c92c09ef8a3277c2ece409c12d86a266f52b16165e9e2253be106c3774931e09bc1aff98955a74814788fbaba6b7f7fb5ed988285f34b64f87805c7c4aea5d4304769ebc0646fec775c4b2f442704d65feac380aaaf873c998d9341e47ee14561dd24e0bce7845c372183d94e98a3000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001fa0102000100000000000000000000000000000000000000000000000000000000f84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f82803916fcde2bef5aa3b302f7eb413ecc65bb744d4ba66e1b4c6757107025f40c7";
        (bool success, ) = address(L2_MESSAGE_VERIFICATION).call(
            abi.encodePacked(IMessageVerification.proveL2MessageInclusionShared.selector, data)
        );
        require(success);
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
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(proof.chainId, bundle);
        // Expect event
        vm.expectEmit(true, false, false, false);
        emit IInteropHandler.BundleExecuted(bundleHash);
        vm.prank(EXECUTION_ADDRESS);
        IInteropHandler(L2_INTEROP_HANDLER_ADDR).executeBundle(bundle, proof);
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
                IAssetRouterBase.finalizeDeposit,
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
                IAssetRouterBase.finalizeDeposit,
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
                IAssetRouterBase.finalizeDeposit,
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

    /// @notice Test setAddresses functionality in InteropCenter
    function test_interopCenter_setAddresses() public {
        address interopCenterOwner = InteropCenter(L2_INTEROP_CENTER_ADDR).owner();

        address newAssetRouter = makeAddr("newAssetRouter");
        address newAssetTracker = makeAddr("newAssetTracker");

        address oldAssetRouter = InteropCenter(L2_INTEROP_CENTER_ADDR).assetRouter();
        address oldAssetTracker = address(InteropCenter(L2_INTEROP_CENTER_ADDR).assetTracker());

        vm.expectEmit(true, true, false, false);
        emit IInteropCenter.NewAssetRouter(oldAssetRouter, newAssetRouter);
        vm.expectEmit(true, true, false, false);
        emit IInteropCenter.NewAssetTracker(oldAssetTracker, newAssetTracker);

        vm.prank(interopCenterOwner);
        InteropCenter(L2_INTEROP_CENTER_ADDR).setAddresses(newAssetRouter, newAssetTracker);

        assertEq(InteropCenter(L2_INTEROP_CENTER_ADDR).assetRouter(), newAssetRouter, "Asset router not updated");
        assertEq(
            address(InteropCenter(L2_INTEROP_CENTER_ADDR).assetTracker()),
            newAssetTracker,
            "Asset tracker not updated"
        );
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

    /// @notice Test that only owner can call setAddresses
    function test_interopCenter_setAddresses_onlyOwner() public {
        address nonOwner = makeAddr("nonOwner");
        address newAssetRouter = makeAddr("newAssetRouter");
        address newAssetTracker = makeAddr("newAssetTracker");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        InteropCenter(L2_INTEROP_CENTER_ADDR).setAddresses(newAssetRouter, newAssetTracker);
    }
}
