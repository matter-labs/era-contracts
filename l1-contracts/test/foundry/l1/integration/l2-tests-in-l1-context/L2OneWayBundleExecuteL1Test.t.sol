// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {AssetHandlerNotAllowed} from "contracts/bridge/L1BridgeContractErrors.sol";
import {INTEROP_ROOT_WRITERS_FEATURE, L1_TO_L2_INTEROP_FEATURE} from "contracts/common/Config.sol";
import {AssetIdNotSupported, InvalidProofLengthForFinalNode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    BundleStatus,
    CallStatus,
    InteropBundle,
    InteropCall,
    L2Message,
    MessageInclusionProof
} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {
    BundleAlreadyProcessed,
    ChainFeatureNotEnabled,
    ExecutingNotAllowed,
    InteropCounterpartsNotSet,
    MessageNotIncluded,
    NotSettlingOnL1,
    OneWayAssetOriginNotAllowed,
    OneWayBundleNotSingleCall,
    OneWayCallNotToAssetRouter,
    OneWayCallValueNotZero,
    ProofNotSelfRooted,
    SettlementLayerIsWriterSource,
    UnauthorizedMessageSender,
    WrongDestinationBaseTokenAssetId,
    WrongDestinationChainId,
    WrongSourceChainId,
    WriterRootNotCurrent
} from "contracts/interop/InteropErrors.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {SharedL2OneWayBundles} from "./_SharedL2OneWayBundles.sol";

import {OneWayBundleProofBuilder} from "test-utils/OneWayBundleProofBuilder.sol";

/// @notice `L2InteropHandler.executeBundle`: one-way bundles of the chain's L1 and of a chain whose roots come from
/// an interop root writer. See {protocol-docs/interop.md#executing-a-one-way-bundle-on-an-l2}.
contract L2OneWayBundleExecuteL1Test is SharedL2OneWayBundles {
    /// @dev `executeBundle` has the selector of the L1 handler's function, so clients call both the same way.
    function test_executeBundle_hasTheL1Selector() public view {
        assertEq(interopHandler.executeBundle.selector, L1InteropHandler.executeBundle.selector);
    }

    /*//////////////////////////////////////////////////////////////
                                Execution
    //////////////////////////////////////////////////////////////*/

    /// @notice A bundle of L1, proven against a root the bootloader imported, mints like a deposit: the bridged
    /// token of an L1 token, counted as a successful deposit from L1.
    function test_executeBundle_fromL1() public {
        _setUpL1Source();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, originToken);
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            L1_CHAIN_ID,
            _nativeTransferBundle(L1_CHAIN_ID)
        );
        bytes32 bundleHash = keccak256(bundle);
        address expectedToken = vault.calculateCreate2TokenAddress(L1_CHAIN_ID, originToken);

        vm.expectEmit(true, false, false, false, L2_INTEROP_HANDLER_ADDR);
        emit IInteropHandlerBase.BundleExecuted(bundleHash);
        // Anyone executes a bundle.
        vm.prank(makeAddr("anyone"));
        interopHandler.executeBundle(bundle, proof);

        assertEq(vault.tokenAddress(assetId), expectedToken, "same token as a priority deposit deploys");
        assertEq(IERC20(expectedToken).balanceOf(receiver), AMOUNT);
        assertEq(IERC20(expectedToken).totalSupply(), AMOUNT);
        assertTrue(interopHandler.bundleStatus(bundleHash) == BundleStatus.FullyExecuted);
        assertTrue(interopHandler.callStatus(bundleHash, 0) == CallStatus.Executed);
        (, uint256 totalSuccessfulDepositsFromL1) = L2AssetTracker(L2_ASSET_TRACKER_ADDR).interopInfo(assetId);
        assertEq(totalSuccessfulDepositsFromL1, AMOUNT, "counted like a priority deposit");
    }

    /// @notice A bundle of a writer source, proven against a root its writer wrote, mints the bridged token of a
    /// token native to that source.
    function test_executeBundle_fromWriterSource() public {
        _setUpWriterSource();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(WRITER_SOURCE_CHAIN_ID, originToken);
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );
        bytes32 bundleHash = keccak256(bundle);

        vm.expectEmit(true, false, false, false, L2_INTEROP_HANDLER_ADDR);
        emit IInteropHandlerBase.BundleExecuted(bundleHash);
        vm.prank(makeAddr("anyone"));
        interopHandler.executeBundle(bundle, proof);

        address token = vault.tokenAddress(assetId);
        assertEq(token, vault.calculateCreate2TokenAddress(WRITER_SOURCE_CHAIN_ID, originToken));
        assertEq(vault.originChainId(assetId), WRITER_SOURCE_CHAIN_ID);
        assertEq(IERC20(token).balanceOf(receiver), AMOUNT);
        assertTrue(interopHandler.bundleStatus(bundleHash) == BundleStatus.FullyExecuted);
        (, uint256 totalSuccessfulDepositsFromL1) = L2AssetTracker(L2_ASSET_TRACKER_ADDR).interopInfo(assetId);
        assertEq(totalSuccessfulDepositsFromL1, 0, "not a deposit from L1");
    }

    /// @notice A bundle executes once, whoever calls and however often its root is written.
    function test_executeBundle_revertWhen_executedAgain() public {
        _setUpWriterSource();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );
        interopHandler.executeBundle(bundle, proof);

        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, keccak256(bundle)));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice An execution address in the bundle restricts who executes it, as for every bundle.
    function test_executeBundle_respectsTheExecutionAddress() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        interopBundle.bundleAttributes.executionAddress = InteroperableAddress.formatEvmV1(
            block.chainid,
            EXECUTION_ADDRESS
        );
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(WRITER_SOURCE_CHAIN_ID, interopBundle);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutingNotAllowed.selector,
                keccak256(bundle),
                InteroperableAddress.formatEvmV1(block.chainid, stranger),
                interopBundle.bundleAttributes.executionAddress
            )
        );
        interopHandler.executeBundle(bundle, proof);

        vm.prank(EXECUTION_ADDRESS);
        interopHandler.executeBundle(bundle, proof);
        assertTrue(interopHandler.bundleStatus(keccak256(bundle)) == BundleStatus.FullyExecuted);
    }

    /*//////////////////////////////////////////////////////////////
                                Gating
    //////////////////////////////////////////////////////////////*/

    /// @notice A chain without interop counterparts for the source executes nothing: a valid proof against an
    /// imported root is not enough. This is what keeps the function unused on every chain that does not opt in.
    function test_executeBundle_revertWhen_noCounterparts() public {
        _setChainFeature(L1_TO_L2_INTEROP_FEATURE, true);
        _mockSettlementLayer(L1_CHAIN_ID);
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            L1_CHAIN_ID,
            _nativeTransferBundle(L1_CHAIN_ID)
        );

        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsNotSet.selector, L1_CHAIN_ID));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice Removing the counterparts stops the bundles already sent, and setting them again resumes them.
    function test_executeBundle_revertWhen_counterpartsRemoved() public {
        _setUpWriterSource();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, address(0), address(0));

        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsNotSet.selector, WRITER_SOURCE_CHAIN_ID));
        interopHandler.executeBundle(bundle, proof);

        _setCounterparts(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice A new interop center on the source leaves the roots written for the old one behind: its bundles
    /// no longer execute.
    function test_executeBundle_revertWhen_interopCenterReplaced() public {
        _setUpWriterSource();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );
        address newCenter = makeAddr("newSourceInteropCenter");
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, newCenter, sourceAssetRouter);

        vm.expectRevert(abi.encodeWithSelector(UnauthorizedMessageSender.selector, newCenter, sourceInteropCenter));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice Replacing a compromised writer stops the bundles proven against the roots it wrote, even ones not
    /// executed yet. The new writer writes the roots it vouches for again.
    function test_executeBundle_revertWhen_writerReplaced() public {
        _setUpWriterSource();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );
        uint256 generation = rootStorage.interopRootWriterGeneration(WRITER_SOURCE_CHAIN_ID);
        assertTrue(rootStorage.isCurrentWriterRoot(WRITER_SOURCE_CHAIN_ID, ROOT_BLOCK));

        address newWriter = makeAddr("newWriter");
        _setWriter(WRITER_SOURCE_CHAIN_ID, newWriter);
        assertEq(rootStorage.interopRootWriterGeneration(WRITER_SOURCE_CHAIN_ID), generation + 1);
        assertFalse(rootStorage.isCurrentWriterRoot(WRITER_SOURCE_CHAIN_ID, ROOT_BLOCK));

        vm.expectRevert(abi.encodeWithSelector(WriterRootNotCurrent.selector, WRITER_SOURCE_CHAIN_ID, ROOT_BLOCK));
        interopHandler.executeBundle(bundle, proof);

        // The new writer writes the source's roots from then on. The source's message root is cumulative, so a
        // later root holds the bundle as well.
        writer = newWriter;
        rootBlock = ROOT_BLOCK + 1;
        (bundle, proof) = _deliver(WRITER_SOURCE_CHAIN_ID, _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice Removing the writer stops the bundles proven against its roots as well.
    function test_executeBundle_revertWhen_writerRemoved() public {
        _setUpWriterSource();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );
        _setWriter(WRITER_SOURCE_CHAIN_ID, address(0));

        vm.expectRevert(abi.encodeWithSelector(WriterRootNotCurrent.selector, WRITER_SOURCE_CHAIN_ID, ROOT_BLOCK));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice Disabling the chain feature stops execution too, not only new counterparts and new roots.
    function test_executeBundle_revertWhen_featureDisabled() public {
        _setUpL1Source();
        _setUpWriterSource();
        (bytes memory l1Bundle, MessageInclusionProof memory l1Proof) = _deliver(
            L1_CHAIN_ID,
            _nativeTransferBundle(L1_CHAIN_ID)
        );
        (bytes memory sourceBundle, MessageInclusionProof memory sourceProof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID)
        );

        _setChainFeature(L1_TO_L2_INTEROP_FEATURE, false);
        vm.expectRevert(abi.encodeWithSelector(ChainFeatureNotEnabled.selector, L1_TO_L2_INTEROP_FEATURE));
        interopHandler.executeBundle(l1Bundle, l1Proof);
        // Each source has its own feature.
        _setChainFeature(INTEROP_ROOT_WRITERS_FEATURE, false);
        vm.expectRevert(abi.encodeWithSelector(ChainFeatureNotEnabled.selector, INTEROP_ROOT_WRITERS_FEATURE));
        interopHandler.executeBundle(sourceBundle, sourceProof);

        _setChainFeature(L1_TO_L2_INTEROP_FEATURE, true);
        interopHandler.executeBundle(l1Bundle, l1Proof);
    }

    /// @notice A bundle of L1 waits while the chain settles elsewhere, so its mint is always counted as a deposit
    /// from L1.
    function test_executeBundle_revertWhen_notSettlingOnL1() public {
        _setUpL1Source();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            L1_CHAIN_ID,
            _nativeTransferBundle(L1_CHAIN_ID)
        );
        _mockSettlementLayer(GATEWAY_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(NotSettlingOnL1.selector, GATEWAY_CHAIN_ID));
        interopHandler.executeBundle(bundle, proof);

        _mockSettlementLayer(L1_CHAIN_ID);
        interopHandler.executeBundle(bundle, proof);
    }

    /*//////////////////////////////////////////////////////////////
                            The bundle's shape
    //////////////////////////////////////////////////////////////*/

    /// @notice Only the source's interop center sends bundles: another local message of the source is not one,
    /// even with the bundle's bytes.
    function test_executeBundle_revertWhen_messageNotFromTheInteropCenter() public {
        _setUpL1Source();
        address otherSender = makeAddr("otherLocalMessageSender");
        bytes memory bundle = abi.encode(_nativeTransferBundle(L1_CHAIN_ID));
        _storeRoot(L1_CHAIN_ID, _sourceRoot(L1_CHAIN_ID, otherSender, bundle));

        vm.expectRevert(abi.encodeWithSelector(UnauthorizedMessageSender.selector, l1InteropCenter, otherSender));
        interopHandler.executeBundle(bundle, _proof(L1_CHAIN_ID, otherSender, L1_CHAIN_ID));
    }

    function test_executeBundle_revertWhen_notASingleCall() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        InteropCall memory interopCall = interopBundle.calls[0];
        interopBundle.calls = new InteropCall[](2);
        interopBundle.calls[0] = interopCall;
        interopBundle.calls[1] = interopCall;
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(WRITER_SOURCE_CHAIN_ID, interopBundle);
        vm.expectRevert(abi.encodeWithSelector(OneWayBundleNotSingleCall.selector, 2));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice A forged root can't make the handler call anything but the asset router.
    function test_executeBundle_revertWhen_callNotToAssetRouter() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        interopBundle.calls[0].to = interopTargetContract;
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(WRITER_SOURCE_CHAIN_ID, interopBundle);
        vm.expectRevert(abi.encodeWithSelector(OneWayCallNotToAssetRouter.selector, interopTargetContract));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice A forged root can't hand out the chain's base token: a one-way call carries no value.
    function test_executeBundle_revertWhen_callCarriesValue() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        interopBundle.calls[0].value = 1 ether;
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(WRITER_SOURCE_CHAIN_ID, interopBundle);
        vm.expectRevert(abi.encodeWithSelector(OneWayCallValueNotZero.selector, 1 ether));
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice The call's sender must be the source's asset router from the counterparts, so only an asset transfer
    /// of the source is delivered.
    function test_executeBundle_revertWhen_callNotFromTheAssetRouter() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        // The address every ZK chain's asset router has is not the source's asset router.
        interopBundle.calls[0].from = L2_ASSET_ROUTER_ADDR;
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(WRITER_SOURCE_CHAIN_ID, interopBundle);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_ASSET_ROUTER_ADDR));
        interopHandler.executeBundle(bundle, proof);
    }

    function test_executeBundle_revertWhen_wrongDestinationChain() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        interopBundle.destinationChainId = block.chainid + 1;
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(WRITER_SOURCE_CHAIN_ID, interopBundle);
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongDestinationChainId.selector,
                keccak256(bundle),
                block.chainid + 1,
                block.chainid
            )
        );
        interopHandler.executeBundle(bundle, proof);
    }

    function test_executeBundle_revertWhen_wrongDestinationBaseToken() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        interopBundle.destinationBaseTokenAssetId = keccak256("otherBaseToken");
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(WRITER_SOURCE_CHAIN_ID, interopBundle);
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongDestinationBaseTokenAssetId.selector,
                keccak256(bundle),
                baseTokenAssetId,
                keccak256("otherBaseToken")
            )
        );
        interopHandler.executeBundle(bundle, proof);
    }

    /*//////////////////////////////////////////////////////////////
                                The proof
    //////////////////////////////////////////////////////////////*/

    /// @notice The proof binds the bundle: another bundle, or no root at all, proves nothing.
    function test_executeBundle_revertWhen_bundleNotInTheRoot() public {
        _setUpWriterSource();
        InteropBundle memory interopBundle = _nativeTransferBundle(WRITER_SOURCE_CHAIN_ID);
        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = _proof(WRITER_SOURCE_CHAIN_ID);

        vm.expectRevert(MessageNotIncluded.selector);
        interopHandler.executeBundle(bundle, proof);

        _storeRoot(WRITER_SOURCE_CHAIN_ID, _sourceRoot(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, bundle));
        interopBundle.bundleAttributes.salt = keccak256("another salt");
        vm.expectRevert(MessageNotIncluded.selector);
        interopHandler.executeBundle(abi.encode(interopBundle), proof);
    }

    /// @notice The source named by the bundle is the chain the proof is for.
    function test_executeBundle_revertWhen_bundleNamesAnotherSource() public {
        _setUpL1Source();
        _setUpWriterSource();
        // A root of the writer source that holds a bundle claiming to come from L1.
        bytes memory bundle = abi.encode(_nativeTransferBundle(L1_CHAIN_ID));
        _storeRoot(WRITER_SOURCE_CHAIN_ID, _sourceRoot(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, bundle));

        vm.expectRevert(
            abi.encodeWithSelector(WrongSourceChainId.selector, keccak256(bundle), L1_CHAIN_ID, WRITER_SOURCE_CHAIN_ID)
        );
        interopHandler.executeBundle(bundle, _proof(WRITER_SOURCE_CHAIN_ID));
    }

    /// @notice A writer source's root does not vouch for L1's messages: the message verification refuses a writer
    /// source as the settlement layer of another chain.
    function test_executeBundle_revertWhen_l1BundleProvenThroughAWriterRoot() public {
        _setUpL1Source();
        _setUpWriterSource();
        bytes memory bundle = abi.encode(_nativeTransferBundle(L1_CHAIN_ID));
        // The writer writes a root whose only leaf is the chain tree of "L1" with the forged bundle.
        _storeRoot(WRITER_SOURCE_CHAIN_ID, _sourceRoot(L1_CHAIN_ID, l1InteropCenter, bundle));

        vm.expectRevert(
            abi.encodeWithSelector(SettlementLayerIsWriterSource.selector, WRITER_SOURCE_CHAIN_ID, L1_CHAIN_ID)
        );
        interopHandler.executeBundle(bundle, _proof(L1_CHAIN_ID, l1InteropCenter, WRITER_SOURCE_CHAIN_ID));
    }

    /// @notice A writer source is proven only against its own roots: a leaf under its chain id inside a root of L1
    /// is not its message root, whatever chain L1 registered under that id.
    function test_executeBundle_revertWhen_writerSourceProvenThroughL1() public {
        _setUpWriterSource();
        bytes memory bundle = abi.encode(_nativeTransferBundle(WRITER_SOURCE_CHAIN_ID));
        // A root of L1 whose only leaf is a chain tree under the writer source's chain id.
        _storeRoot(L1_CHAIN_ID, _sourceRoot(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, bundle));

        vm.expectRevert(abi.encodeWithSelector(ProofNotSelfRooted.selector, WRITER_SOURCE_CHAIN_ID, L1_CHAIN_ID));
        interopHandler.executeBundle(bundle, _proof(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, L1_CHAIN_ID));
    }

    /// @notice A stored root is a message root, never a batch root: a proof that ends at the batch is refused.
    function test_executeBundle_revertWhen_proofEndsAtABatchRoot() public {
        _setUpWriterSource();
        bytes memory bundle = abi.encode(_nativeTransferBundle(WRITER_SOURCE_CHAIN_ID));
        // The writer writes the batch root itself, keyed by the batch number the proof names.
        bytes32 batchRoot = OneWayBundleProofBuilder.chainBatchRoot(
            OneWayBundleProofBuilder.messageLeaf(sourceInteropCenter, bytes.concat(bytes1(0x01), bundle))
        );
        _storeRoot(WRITER_SOURCE_CHAIN_ID, batchRoot);
        MessageInclusionProof memory proof = MessageInclusionProof({
            chainId: WRITER_SOURCE_CHAIN_ID,
            l1BatchNumber: ROOT_BLOCK,
            l2MessageIndex: 0,
            message: L2Message({txNumberInBatch: 0, sender: sourceInteropCenter, data: ""}),
            proof: OneWayBundleProofBuilder.finalProof(new bytes32[](0))
        });

        vm.expectRevert(InvalidProofLengthForFinalNode.selector);
        interopHandler.executeBundle(bundle, proof);
    }

    /*//////////////////////////////////////////////////////////////
                    What a writer source can transfer
    //////////////////////////////////////////////////////////////*/

    /// @notice Only assets native to a writer source come from it: a forged root can't mint a bridged token of L1 or
    /// of another chain.
    function testFuzz_executeBundle_revertWhen_assetNotNativeToTheWriterSource(uint256 _originChainId) public {
        // Zero is not a chain id: the token data without one is the legacy encoding of an L1 token.
        vm.assume(_originChainId != 0);
        vm.assume(_originChainId != WRITER_SOURCE_CHAIN_ID && _originChainId != block.chainid);
        _checkAssetNotNativeToTheWriterSource(_originChainId);
    }

    /// @notice The most valuable case of the rule above: the bridged tokens of L1's tokens.
    function test_executeBundle_revertWhen_writerSourceSendsAnL1Asset() public {
        _checkAssetNotNativeToTheWriterSource(L1_CHAIN_ID);
    }

    function _checkAssetNotNativeToTheWriterSource(uint256 _originChainId) internal {
        _setUpWriterSource();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_originChainId, originToken);
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _transferBundle(WRITER_SOURCE_CHAIN_ID, assetId, _mintData(_originChainId, originToken))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                OneWayAssetOriginNotAllowed.selector,
                WRITER_SOURCE_CHAIN_ID,
                assetId,
                _originChainId
            )
        );
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice A forged root can't release a token native to this chain from the vault either.
    function test_executeBundle_revertWhen_assetNativeToThisChain() public {
        _setUpWriterSource();
        TestnetERC20Token nativeToken = new TestnetERC20Token("Native", "NAT", 18);
        vault.registerToken(address(nativeToken));
        // What the vault would hold after the token was bridged out.
        nativeToken.mint(address(vault), AMOUNT);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(nativeToken));
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _transferBundle(WRITER_SOURCE_CHAIN_ID, assetId, _mintData(block.chainid, address(nativeToken)))
        );

        vm.expectRevert(
            abi.encodeWithSelector(OneWayAssetOriginNotAllowed.selector, WRITER_SOURCE_CHAIN_ID, assetId, block.chainid)
        );
        interopHandler.executeBundle(bundle, proof);
        assertEq(nativeToken.balanceOf(address(vault)), AMOUNT);
    }

    /// @notice The origin rule lives in the native token vault's tracker, so an asset with any other handler does
    /// not cross a writer link at all.
    function test_executeBundle_revertWhen_assetHasACustomHandler() public {
        _setUpWriterSource();
        (bytes32 assetId, address customHandler) = _registerCustomHandler();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            WRITER_SOURCE_CHAIN_ID,
            _transferBundle(WRITER_SOURCE_CHAIN_ID, assetId, hex"1234")
        );

        vm.expectRevert(
            abi.encodeWithSelector(AssetHandlerNotAllowed.selector, WRITER_SOURCE_CHAIN_ID, assetId, customHandler)
        );
        interopHandler.executeBundle(bundle, proof);
    }

    /// @notice The restriction is for one-way links only: an asset with a custom handler still arrives from a chain
    /// without counterparts.
    /// @dev The interop handler is pranked and the custom handler mocked, to isolate the asset router's check from
    /// the atomic proof and from a real handler.
    function test_finalizeDeposit_customHandlerFromAChainWithoutCounterparts() public {
        _setUpWriterSource();
        (bytes32 assetId, address customHandler) = _registerCustomHandler();
        vm.mockCall(customHandler, abi.encodeWithSelector(IAssetHandler.bridgeMint.selector), "");

        vm.expectCall(
            customHandler,
            abi.encodeCall(IAssetHandler.bridgeMint, (INTEROP_DESTINATION_CHAIN_ID, assetId, hex"1234"))
        );
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        AssetRouterBase(L2_ASSET_ROUTER_ADDR).receiveMessage(
            bytes32(0),
            InteroperableAddress.formatEvmV1(INTEROP_DESTINATION_CHAIN_ID, L2_ASSET_ROUTER_ADDR),
            abi.encodeCall(AssetRouterBase.finalizeDeposit, (INTEROP_DESTINATION_CHAIN_ID, assetId, hex"1234"))
        );
    }

    /// @notice L1's counterparts restrict nothing for deposits: an asset with a custom handler still arrives from L1
    /// as a priority deposit. L1 itself refuses to send such an asset in a bundle.
    /// @dev The custom handler is mocked, to isolate the asset router's check from a real handler.
    function test_finalizeDeposit_customHandlerFromL1WithCounterparts() public {
        _setUpL1Source();
        (bytes32 assetId, address customHandler) = _registerCustomHandler();
        vm.mockCall(customHandler, abi.encodeWithSelector(IAssetHandler.bridgeMint.selector), "");

        vm.expectCall(customHandler, abi.encodeCall(IAssetHandler.bridgeMint, (L1_CHAIN_ID, assetId, hex"1234")));
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1AssetRouter));
        AssetRouterBase(L2_ASSET_ROUTER_ADDR).finalizeDeposit(L1_CHAIN_ID, assetId, hex"1234");
    }

    /// @notice The chain's base token is never minted through the asset router.
    function test_executeBundle_revertWhen_assetIsTheBaseToken() public {
        _setUpL1Source();
        (bytes memory bundle, MessageInclusionProof memory proof) = _deliver(
            L1_CHAIN_ID,
            _transferBundle(L1_CHAIN_ID, baseTokenAssetId, _mintData(L1_CHAIN_ID, originToken))
        );
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotSupported.selector, baseTokenAssetId));
        interopHandler.executeBundle(bundle, proof);
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev Registers an asset with a handler other than the native token vault, as L1 does for a chain.
    function _registerCustomHandler() internal returns (bytes32 assetId, address customHandler) {
        assetId = keccak256("customAsset");
        customHandler = makeAddr("customHandler");
        vm.prank(aliasedL1AssetRouter);
        l2AssetRouter.setAssetHandlerAddress(L1_CHAIN_ID, assetId, customHandler);
    }
}
