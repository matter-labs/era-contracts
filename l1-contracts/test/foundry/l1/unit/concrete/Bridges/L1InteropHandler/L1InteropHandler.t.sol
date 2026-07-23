// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_INTEROP_CENTER_ADDR, L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    BundleAttributes,
    BundleStatus,
    CallStatus,
    InteropBundle,
    InteropCall,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    L2Message,
    MessageInclusionProof
} from "contracts/common/Messaging.sol";

import {SlotOccupied} from "contracts/common/L1ContractErrors.sol";
import {
    BundleAlreadyProcessed,
    EmptyBundle,
    MessageNotIncluded,
    UnauthorizedMessageSender,
    WrongDestinationBaseTokenAssetId,
    WrongSourceChainId
} from "contracts/interop/InteropErrors.sol";
import {InteropWithdrawalNonZeroValue} from "contracts/bridge/L1BridgeContractErrors.sol";

/// @notice Minimal `MessageRoot` stub whose inclusion proof always succeeds, so the handler's `executeBundle`
/// flow can be exercised without a real settlement-layer proof. Isolated on purpose: the proof machinery is
/// covered elsewhere; here we only test the L1 handler's own logic.
contract MockMessageRoot {
    function proveL2MessageInclusionShared(
        uint256,
        uint256,
        uint256,
        L2Message calldata,
        bytes32[] calldata
    ) external pure returns (bool) {
        return true;
    }
}

/// @notice Minimal ERC-7786 recipient that records the call and returns the required selector. Stands in for an
/// arbitrary L1 call target (e.g. the asset router) so we can assert dispatch without a real recipient.
contract MockInteropRecipient is IERC7786Recipient {
    bytes32 public lastReceiveId;
    bytes public lastPayload;
    uint256 public callCount;

    function receiveMessage(
        bytes32 receiveId,
        bytes calldata,
        bytes calldata payload
    ) external payable returns (bytes4) {
        lastReceiveId = receiveId;
        lastPayload = payload;
        ++callCount;
        return IERC7786Recipient.receiveMessage.selector;
    }
}

/// @title L1InteropHandlerTest
/// @notice Unit tests for `L1InteropHandler`: proxy initialization plus the L1-specific `executeBundle` surface
/// (its virtual hooks). The full multi-chain proof/settlement flow is covered by the integration suite; here the
/// MessageRoot proof is stubbed so we can isolate the handler's own destination-context and value handling.
contract L1InteropHandlerTest is Test {
    L1InteropHandler internal handler;
    L1InteropHandler internal handlerImpl;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal owner = makeAddr("owner");
    address internal messageRoot;
    MockInteropRecipient internal recipient;

    uint256 internal constant SOURCE_CHAIN_ID = 271;

    function setUp() public {
        messageRoot = address(new MockMessageRoot());
        recipient = new MockInteropRecipient();
        handlerImpl = new L1InteropHandler(IMessageRootBase(messageRoot));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(handlerImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1InteropHandler.initialize.selector, owner)
        );
        handler = L1InteropHandler(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsState() public view {
        assertEq(address(handler.MESSAGE_ROOT()), messageRoot, "MESSAGE_ROOT mismatch");
        assertEq(handler.owner(), owner, "owner mismatch");
        assertFalse(handler.paused(), "handler must start unpaused");
    }

    function test_Initialize_RevertWhen_CalledTwice() public {
        // The `reentrancyGuardInitializer` modifier rejects the second init with `SlotOccupied`.
        vm.expectRevert(SlotOccupied.selector);
        handler.initialize(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Only the owner may pause/unpause withdrawal processing.
    function test_Pause_RevertWhen_NotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        handler.pause();
    }

    /// @notice While paused, `executeBundle` (withdrawal finalization) is blocked; unpausing restores it and
    /// the very same bundle then finalizes.
    function test_ExecuteBundle_RevertWhen_Paused_ThenSucceedsAfterUnpause() public {
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            hex"c0ffee"
        );

        vm.prank(owner);
        handler.pause();
        assertTrue(handler.paused(), "pause must take effect");

        vm.expectRevert("Pausable: paused");
        handler.executeBundle(bundle, proof);

        vm.prank(owner);
        handler.unpause();

        handler.executeBundle(bundle, proof);
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundle);
        assertTrue(
            handler.bundleStatus(bundleHash) == BundleStatus.FullyExecuted,
            "bundle must finalize after unpause"
        );
        assertEq(recipient.callCount(), 1, "recipient must be called exactly once");
    }

    /// @notice `unbundleBundle` also executes calls, so it is blocked while paused (checked before any decoding).
    function test_UnbundleBundle_RevertWhen_Paused() public {
        vm.prank(owner);
        handler.pause();

        vm.expectRevert("Pausable: paused");
        handler.unbundleBundle(hex"", new CallStatus[](0));
    }

    /// @notice `verifyBundle` stays usable while paused: it only records message inclusion and moves no assets,
    /// so verification can proceed during an emergency pause (execution of the verified bundle stays blocked).
    function test_VerifyBundle_SucceedsWhen_Paused() public {
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            hex"c0ffee"
        );

        vm.prank(owner);
        handler.pause();

        handler.verifyBundle(bundle, proof);
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundle);
        assertTrue(handler.bundleStatus(bundleHash) == BundleStatus.Verified, "bundle must verify while paused");
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE BUNDLE
    //////////////////////////////////////////////////////////////*/

    /// @notice A single-call bundle to an arbitrary L1 recipient is finalized: the call is dispatched via
    /// ERC-7786 `receiveMessage` and the bundle is marked fully executed. The recipient here is a generic mock,
    /// not the asset router — documenting that the L1 handler accepts any single call, not only withdrawals.
    function test_ExecuteBundle_FinalizesArbitrarySingleCall() public {
        bytes memory payload = hex"c0ffee";
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            payload
        );
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundle);

        vm.expectEmit(true, false, false, false, address(handler));
        emit IInteropHandlerBase.BundleExecuted(bundleHash);

        handler.executeBundle(bundle, proof);

        assertTrue(handler.bundleStatus(bundleHash) == BundleStatus.FullyExecuted, "bundle not fully executed");
        assertEq(recipient.callCount(), 1, "recipient should be called exactly once");
        assertEq(recipient.lastPayload(), payload, "recipient payload mismatch");
    }

    /// @notice The same bundle cannot be executed twice: the second attempt is rejected as already processed.
    function test_ExecuteBundle_RevertWhen_AlreadyExecuted() public {
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            hex""
        );
        handler.executeBundle(bundle, proof);

        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundle);
        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, bundleHash));
        handler.executeBundle(bundle, proof);
    }

    /// @notice L1 forbids base-token call value: the amount must ride inside the call payload, never as value.
    /// `_handleCallValue` reverts on any non-zero value.
    function test_ExecuteBundle_RevertWhen_NonZeroCallValue() public {
        uint256 value = 1 ether;
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            value,
            _ethAssetId(),
            hex""
        );

        vm.expectRevert(abi.encodeWithSelector(InteropWithdrawalNonZeroValue.selector, value));
        handler.executeBundle(bundle, proof);
    }

    /// @notice A bundle whose destination base token is not L1's ETH asset ID is rejected by the shared
    /// destination-context validation (`_expectedDestinationBaseTokenAssetId` returns L1's ETH asset ID).
    function test_ExecuteBundle_RevertWhen_WrongDestinationBaseToken() public {
        bytes32 wrongAssetId = keccak256("not-eth");
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            wrongAssetId,
            hex""
        );
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundle);

        vm.expectRevert(
            abi.encodeWithSelector(WrongDestinationBaseTokenAssetId.selector, bundleHash, _ethAssetId(), wrongAssetId)
        );
        handler.executeBundle(bundle, proof);
    }

    /// @notice A bundle whose inclusion proof does not verify is rejected.
    function test_ExecuteBundle_RevertWhen_MessageNotIncluded() public {
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            hex""
        );
        // Force the MessageRoot inclusion proof to fail.
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(false)
        );
        vm.expectRevert(MessageNotIncluded.selector);
        handler.executeBundle(bundle, proof);
    }

    /// @notice The bundle's source chain must match the proof's chain.
    function test_ExecuteBundle_RevertWhen_WrongSourceChainId() public {
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            hex""
        );
        proof.chainId = SOURCE_CHAIN_ID + 1; // no longer matches bundle.sourceChainId
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundle);
        vm.expectRevert(
            abi.encodeWithSelector(WrongSourceChainId.selector, bundleHash, SOURCE_CHAIN_ID, SOURCE_CHAIN_ID + 1)
        );
        handler.executeBundle(bundle, proof);
    }

    /// @notice Only messages emitted by the canonical L2 L2InteropCenter are accepted.
    function test_ExecuteBundle_RevertWhen_UnauthorizedMessageSender() public {
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            hex""
        );
        address badSender = makeAddr("notInteropCenter");
        proof.message.sender = badSender;
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedMessageSender.selector, L2_INTEROP_CENTER_ADDR, badSender));
        handler.executeBundle(bundle, proof);
    }

    /// @notice An empty bundle is rejected with a clean error rather than an abi.decode panic.
    function test_ExecuteBundle_RevertWhen_EmptyBundle() public {
        (, MessageInclusionProof memory proof) = _buildBundle(address(recipient), 0, _ethAssetId(), hex"");
        vm.expectRevert(EmptyBundle.selector);
        handler.executeBundle(hex"", proof);
    }

    /// @notice A bundle can be verified first and executed in a second call: `executeBundle` skips re-verification
    /// once the bundle is already `Verified`.
    function test_VerifyThenExecuteBundle() public {
        (bytes memory bundle, MessageInclusionProof memory proof) = _buildBundle(
            address(recipient),
            0,
            _ethAssetId(),
            hex""
        );
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundle);

        handler.verifyBundle(bundle, proof);
        assertTrue(handler.bundleStatus(bundleHash) == BundleStatus.Verified, "bundle should be verified");

        handler.executeBundle(bundle, proof);
        assertTrue(handler.bundleStatus(bundleHash) == BundleStatus.FullyExecuted, "bundle should be fully executed");
        assertEq(recipient.callCount(), 1, "recipient should be called exactly once");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev L1's expected destination base-token asset ID: the NTV ETH asset ID for this chain.
    function _ethAssetId() internal view returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }

    /// @dev Builds a single-call `InteropBundle` (ABI-encoded) plus a matching `MessageInclusionProof`. The proof's
    /// message sender is the canonical `L2_INTEROP_CENTER_ADDR` (the only sender `_verifyBundle` accepts); the
    /// MockMessageRoot then accepts the inclusion proof unconditionally.
    function _buildBundle(
        address _target,
        uint256 _value,
        bytes32 _destinationBaseTokenAssetId,
        bytes memory _data
    ) internal view returns (bytes memory bundle, MessageInclusionProof memory proof) {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: _target,
            from: L2_ASSET_ROUTER_ADDR,
            value: _value,
            data: _data
        });
        InteropBundle memory interopBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: SOURCE_CHAIN_ID,
            destinationChainId: block.chainid,
            destinationBaseTokenAssetId: _destinationBaseTokenAssetId,
            interopBundleSalt: bytes32(uint256(1)),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: hex"",
                unbundlerAddress: hex"",
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
        bundle = abi.encode(interopBundle);
        bytes32[] memory merkleProof = new bytes32[](0);
        proof = MessageInclusionProof({
            chainId: SOURCE_CHAIN_ID,
            l1BatchNumber: 1,
            l2MessageIndex: 0,
            message: L2Message({txNumberInBatch: 0, sender: L2_INTEROP_CENTER_ADDR, data: hex""}),
            proof: merkleProof
        });
    }
}
