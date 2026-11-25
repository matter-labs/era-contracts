// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {AssetHandlerNotAllowed} from "contracts/bridge/L1BridgeContractErrors.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {InteropBundle, InteropCall, InteropCallStarter, MessageInclusionProof} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {
    DestinationChainNotRegistered,
    DirectCallToL1NotSupported,
    InteropCallToL1NotToAssetRouter,
    MultiCallToL1NotSupported,
    NonAtomicSendUnsupported,
    NonZeroValueToL1NotSupported,
    OneWayAssetOriginNotAllowed,
    RecoveryToOneWayDestinationNotSupported
} from "contracts/interop/InteropErrors.sol";
import {AtomicFlowPreimage, ATOMIC_FLOW_PREIMAGE_VERSION} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {SharedL2OneWayBundles} from "./_SharedL2OneWayBundles.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

/// @notice One-way bundles from an L2 to a chain it has interop counterparts for, and the origin rule of that link
/// in the asset tracker. See {protocol-docs/interop.md#one-way-bundles-with-a-writer-source}.
contract L2OneWayBundleSendL1Test is SharedL2OneWayBundles {
    using LogFinder for Vm.Log[];

    bytes32 internal constant SALT = keccak256("exit salt");

    /// @dev The asset native to the writer source and its bridged token on this chain, held by `receiver`.
    bytes32 internal assetId;
    address internal bridgedToken;
    address internal sourceReceiver = makeAddr("receiverOnTheSource");

    function setUp() public override {
        super.setUp();
        _setUpWriterSource();
        // The bridged token of the source's token exists once a bundle of the source minted it.
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );
        interopHandler.executeBundle(bundle, proof);
        assetId = DataEncoding.encodeNTVAssetId(WRITER_SOURCE_CHAIN_ID, originToken);
        bridgedToken = vault.tokenAddress(assetId);
    }

    /// @notice The call starter of a transfer of `_amount` of `_assetId` through this chain's asset router.
    function _starters(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _messageValue
    ) internal view returns (InteropCallStarter[] memory starters) {
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (_messageValue));
        starters = new InteropCallStarter[](1);
        starters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: DataEncoding.encodeAssetRouterBridgehubDepositData(
                _assetId,
                DataEncoding.encodeBridgeBurnData(_amount, sourceReceiver, address(0))
            ),
            callAttributes: callAttributes
        });
    }

    function _saltAttribute() internal pure returns (bytes[] memory attributes) {
        attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (SALT));
    }

    function _sendToSource(InteropCallStarter[] memory _callStarters, bytes[] memory _attributes) internal {
        vm.prank(receiver);
        l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(WRITER_SOURCE_CHAIN_ID),
            _callStarters,
            _attributes
        );
    }

    /*//////////////////////////////////////////////////////////////
                                Sending
    //////////////////////////////////////////////////////////////*/

    /// @notice A transfer back to the source burns the bridged token and publishes the bundle as an L2->L1 message,
    /// addressed to the source's asset router and free of interop fees, exactly as a withdrawal to L1.
    function test_sendBundle_toAWriterSource() public {
        // An interop fee is set, to show that a one-way bundle does not pay it.
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(1 ether);
        uint256 feeUnitsBefore = l2InteropCenter.interopFeeUnits();
        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector)
        );

        vm.recordLogs();
        _sendToSource(_starters(assetId, AMOUNT, 0), _saltAttribute());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(bridgedToken).balanceOf(receiver), 0);
        assertEq(IERC20(bridgedToken).totalSupply(), 0, "burned");
        assertEq(l2InteropCenter.interopFeeUnits(), feeUnitsBefore, "not a leg of an atomic flow");

        Vm.Log memory bundleLog = logs.requireOneFrom(
            "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes,bool,bytes32)))",
            L2_INTEROP_CENTER_ADDR
        );
        (bytes32 messageHash, , InteropBundle memory bundle) = abi.decode(
            bundleLog.data,
            (bytes32, bytes32, InteropBundle)
        );
        // The harness mocks the L2->L1 messenger to return this hash, so the bundle went out as a message.
        assertEq(messageHash, bytes32(uint256(1)));
        assertEq(bundle.sourceChainId, block.chainid);
        assertEq(bundle.destinationChainId, WRITER_SOURCE_CHAIN_ID);
        assertEq(
            bundle.destinationBaseTokenAssetId,
            DataEncoding.encodeNTVAssetId(WRITER_SOURCE_CHAIN_ID, ETH_TOKEN_ADDRESS),
            "what the source's interop handler expects"
        );
        assertEq(bundle.calls.length, 1);
        InteropCall memory interopCall = bundle.calls[0];
        assertEq(interopCall.to, sourceAssetRouter, "the source's real asset router");
        assertEq(interopCall.from, L2_ASSET_ROUTER_ADDR, "this chain's real asset router");
        assertEq(interopCall.value, 0);
        assertEq(
            interopCall.data,
            abi.encodeCall(
                AssetRouterBase.finalizeDeposit,
                (
                    block.chainid,
                    assetId,
                    DataEncoding.encodeBridgeMintData({
                        _originalCaller: receiver,
                        _remoteReceiver: sourceReceiver,
                        _originToken: originToken,
                        _amount: AMOUNT,
                        _erc20Metadata: vault.getERC20Getters(bridgedToken, WRITER_SOURCE_CHAIN_ID)
                    })
                )
            )
        );
    }

    /// @notice A chain without counterparts is not a one-way destination: removing them stops the sends.
    function test_sendBundle_revertWhen_counterpartsRemoved() public {
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, address(0), address(0));
        vm.expectRevert(NonAtomicSendUnsupported.selector);
        _sendToSource(_starters(assetId, AMOUNT, 0), _saltAttribute());
    }

    /// @notice An atomic flow has no leg on a chain with counterparts: the chain is never an allowed peer.
    function test_sendBundle_revertWhen_atomicBundleToAWriterSource() public {
        bytes[] memory attributes = new bytes[](2);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (SALT));
        attributes[1] = abi.encodeCall(
            IERC7786Attributes.atomicBundle,
            (
                AtomicFlowPreimage({
                    version: ATOMIC_FLOW_PREIMAGE_VERSION,
                    deadline: type(uint64).max,
                    settlementLayerChainId: L1_CHAIN_ID,
                    legBundleHashes: new bytes32[](0),
                    legSourceChainIds: new uint256[](0)
                }),
                uint256(0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotRegistered.selector, WRITER_SOURCE_CHAIN_ID));
        _sendToSource(_starters(assetId, AMOUNT, 0), attributes);
    }

    /// @notice `sendMessage` stays atomic-only: a one-way bundle is sent with `sendBundle`.
    function test_sendMessage_revertWhen_toAWriterSource() public {
        vm.prank(receiver);
        vm.expectRevert(NonAtomicSendUnsupported.selector);
        l2InteropCenter.sendMessage(
            InteroperableAddress.formatEvmV1(WRITER_SOURCE_CHAIN_ID, L2_ASSET_ROUTER_ADDR),
            _starters(assetId, AMOUNT, 0)[0].data,
            _starters(assetId, AMOUNT, 0)[0].callAttributes
        );
    }

    /// @notice The restrictions of a withdrawal to L1 hold for every one-way destination.
    function test_sendBundle_revertWhen_notASingleIndirectAssetRouterCallWithoutValue() public {
        InteropCallStarter[] memory one = _starters(assetId, AMOUNT, 0);
        InteropCallStarter[] memory two = new InteropCallStarter[](2);
        two[0] = one[0];
        two[1] = one[0];
        vm.expectRevert(abi.encodeWithSelector(MultiCallToL1NotSupported.selector, 2));
        _sendToSource(two, _saltAttribute());

        InteropCallStarter[] memory direct = _starters(assetId, AMOUNT, 0);
        direct[0].callAttributes = new bytes[](0);
        vm.expectRevert(DirectCallToL1NotSupported.selector);
        _sendToSource(direct, _saltAttribute());

        InteropCallStarter[] memory otherTarget = _starters(assetId, AMOUNT, 0);
        otherTarget[0].to = InteroperableAddress.formatEvmV1(interopTargetContract);
        vm.expectRevert(abi.encodeWithSelector(InteropCallToL1NotToAssetRouter.selector, interopTargetContract));
        _sendToSource(otherTarget, _saltAttribute());

        InteropCallStarter[] memory withValue = _starters(assetId, AMOUNT, 0);
        withValue[0].callAttributes = new bytes[](2);
        withValue[0].callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        withValue[0].callAttributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (5));
        vm.expectRevert(abi.encodeWithSelector(NonZeroValueToL1NotSupported.selector, 5));
        _sendToSource(withValue, _saltAttribute());
    }

    /*//////////////////////////////////////////////////////////////
                            The origin rule
    //////////////////////////////////////////////////////////////*/

    /// @notice Only assets native to a writer source go to it: the source's vault could not release anything else,
    /// and the burn has no refund.
    function test_sendBundle_revertWhen_assetNotNativeToTheWriterSource() public {
        address l1BridgedToken = initializeTokenByDeposit();
        bytes32 l1AssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, L1_TOKEN_ADDRESS);
        IERC20(l1BridgedToken).transfer(receiver, AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(OneWayAssetOriginNotAllowed.selector, WRITER_SOURCE_CHAIN_ID, l1AssetId, L1_CHAIN_ID)
        );
        _sendToSource(_starters(l1AssetId, AMOUNT, 0), _saltAttribute());
        assertEq(IERC20(l1BridgedToken).balanceOf(receiver), AMOUNT, "nothing was burned");
    }

    /// @notice An asset of a writer source does not go to L1, which could never release it.
    function test_sendBundle_revertWhen_writerSourceAssetGoesToL1() public {
        vm.prank(receiver);
        vm.expectRevert(
            abi.encodeWithSelector(OneWayAssetOriginNotAllowed.selector, L1_CHAIN_ID, assetId, WRITER_SOURCE_CHAIN_ID)
        );
        l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(L1_CHAIN_ID),
            _starters(assetId, AMOUNT, 0),
            _saltAttribute()
        );
        assertEq(IERC20(bridgedToken).balanceOf(receiver), AMOUNT, "nothing was burned");
    }

    /// @notice The chain's base token does not go to a writer source: the base-token holder's burn reaches the same
    /// rule as the vault's.
    /// @dev The harness's base-token holder is a stand-in that does not notify the asset tracker, so the holder is
    /// pranked to make the call the production holder makes.
    function test_handleInitiateBaseTokenBridgingOnL2_revertWhen_toAWriterSource() public {
        uint256 baseTokenOriginChainId = vault.originChainId(baseTokenAssetId);
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        vm.expectRevert(
            abi.encodeWithSelector(
                OneWayAssetOriginNotAllowed.selector,
                WRITER_SOURCE_CHAIN_ID,
                baseTokenAssetId,
                baseTokenOriginChainId
            )
        );
        L2AssetTracker(L2_ASSET_TRACKER_ADDR).handleInitiateBaseTokenBridgingOnL2(WRITER_SOURCE_CHAIN_ID, 1);
    }

    /// @notice An asset of a writer source moves to and from other chains freely: the rule is about the link with
    /// the source only.
    /// @dev The vault is pranked to isolate the tracker's rule from the atomic flow that would carry the asset.
    function test_originRule_leavesOtherChainsAlone() public {
        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        vm.startPrank(L2_NATIVE_TOKEN_VAULT_ADDR);
        tracker.handleInitiateBridgingOnL2(INTEROP_DESTINATION_CHAIN_ID, assetId, AMOUNT, WRITER_SOURCE_CHAIN_ID);
        tracker.handleFinalizeBridgingOnL2(
            INTEROP_DESTINATION_CHAIN_ID,
            assetId,
            AMOUNT,
            WRITER_SOURCE_CHAIN_ID,
            bridgedToken
        );
        vm.stopPrank();
    }

    /// @notice A burn toward a one-way destination is never recovered, like a withdrawal to L1.
    function test_assertRecoveryIsAccountingNeutral_revertWhen_toAWriterSource() public {
        vm.expectRevert(
            abi.encodeWithSelector(RecoveryToOneWayDestinationNotSupported.selector, WRITER_SOURCE_CHAIN_ID)
        );
        L2AssetTracker(L2_ASSET_TRACKER_ADDR).assertRecoveryIsAccountingNeutral(assetId, WRITER_SOURCE_CHAIN_ID);
    }

    /// @notice An asset with a custom handler does not go to a writer source: the source's asset router would
    /// refuse it, and the tracker's origin rule never sees it.
    /// @dev The custom handler is mocked: only the asset router's check after the burn is under test.
    function test_sendBundle_revertWhen_assetHasACustomHandler() public {
        bytes32 customAssetId = keccak256("customAsset");
        address customHandler = makeAddr("customHandler");
        vm.prank(aliasedL1AssetRouter);
        l2AssetRouter.setAssetHandlerAddress(L1_CHAIN_ID, customAssetId, customHandler);
        vm.mockCall(customHandler, abi.encodeWithSelector(IAssetHandler.bridgeBurn.selector), abi.encode(hex"1234"));

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetHandlerNotAllowed.selector,
                WRITER_SOURCE_CHAIN_ID,
                customAssetId,
                customHandler
            )
        );
        _sendToSource(_starters(customAssetId, AMOUNT, 0), _saltAttribute());
    }
}
