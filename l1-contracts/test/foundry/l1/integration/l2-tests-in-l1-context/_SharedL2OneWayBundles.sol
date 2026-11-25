// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {
    INTEROP_ROOT_WRITERS_FEATURE,
    L1_TO_L2_INTEROP_FEATURE,
    SERVICE_TRANSACTION_SENDER
} from "contracts/common/Config.sol";
import {
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall,
    InteropRoot,
    L2Message,
    MessageInclusionProof
} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_INTEROP_ROOT_STORAGE_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";

import {SharedL2ContractL1Deployer} from "./_SharedL2ContractL1Deployer.sol";

import {OneWayBundleProofBuilder} from "test-utils/OneWayBundleProofBuilder.sol";

/// @notice An L2 that exchanges one-way bundles with its L1 and with a chain whose roots come from an interop root
/// writer. The source chains themselves are not deployed here: the test builds their message roots by hand, which
/// also lets it build the roots a compromised writer could write. The flow against a real L1 is in
/// `OneWayBundlesEndToEnd.t.sol`. See {protocol-docs/interop.md#one-way-bundles-from-an-l1}.
abstract contract SharedL2OneWayBundles is Test, SharedL2ContractL1Deployer {
    /// @dev A chain outside the ecosystem, whose roots a writer brings.
    uint256 internal constant WRITER_SOURCE_CHAIN_ID = 7777;
    /// @dev The source block the roots of the tests are recorded for, and the timestamp of the batch and the root.
    uint256 internal constant ROOT_BLOCK = 1234;
    uint256 internal constant ROOT_TIMESTAMP = 5678;
    /// @dev The source block {_deliver} records the root for; `ROOT_BLOCK` unless a test writes a second root.
    uint256 internal rootBlock = ROOT_BLOCK;
    uint256 internal constant AMOUNT = 1000;

    L2InteropHandler internal interopHandler = L2InteropHandler(payable(L2_INTEROP_HANDLER_ADDR));
    IL2Bridgehub internal bridgehub = IL2Bridgehub(L2_BRIDGEHUB_ADDR);
    L2InteropRootStorage internal rootStorage = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);
    L2NativeTokenVault internal vault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

    address internal writer = makeAddr("writer");
    /// @dev The interop centers of the two sources. The asset router of L1 is the harness's `l1AssetRouter`.
    address internal l1InteropCenter = makeAddr("l1InteropCenter");
    address internal sourceInteropCenter = makeAddr("sourceInteropCenter");
    address internal sourceAssetRouter = makeAddr("sourceAssetRouter");

    address internal depositor = makeAddr("depositor");
    address internal receiver = makeAddr("receiver");
    /// @dev A token native to the source chain of the bundle under test.
    address internal originToken = makeAddr("originToken");

    function setUp() public virtual override {
        super.setUp();
        // The harness deploys a stand-in without the writers; the tests need the production contract.
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
    }

    /*//////////////////////////////////////////////////////////////
                    What L1's service transactions do
    //////////////////////////////////////////////////////////////*/

    function _setChainFeature(bytes32 _feature, bool _enabled) internal {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        bridgehub.setChainFeatureEnabled(_feature, _enabled);
    }

    function _setCounterparts(uint256 _chainId, address _interopCenter, address _assetRouter) internal {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        bridgehub.setInteropCounterparts(_chainId, _interopCenter, _assetRouter);
    }

    function _setWriter(uint256 _sourceChainId, address _writer) internal {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        rootStorage.setInteropRootWriter(_sourceChainId, _writer);
    }

    /// @notice Everything a chain needs to execute bundles of its L1.
    function _setUpL1Source() internal {
        _setChainFeature(L1_TO_L2_INTEROP_FEATURE, true);
        _setCounterparts(L1_CHAIN_ID, l1InteropCenter, l1AssetRouter);
        _mockSettlementLayer(L1_CHAIN_ID);
    }

    /// @notice Everything a chain needs to exchange bundles with a chain whose roots come from a writer.
    function _setUpWriterSource() internal {
        _setChainFeature(INTEROP_ROOT_WRITERS_FEATURE, true);
        _setWriter(WRITER_SOURCE_CHAIN_ID, writer);
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);
    }

    /// @dev Mock justification: the system context is a ZKsync OS system contract the harness does not deploy.
    function _mockSettlementLayer(uint256 _settlementLayerChainId) internal {
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(_settlementLayerChainId)
        );
    }

    /*//////////////////////////////////////////////////////////////
                                Bundles
    //////////////////////////////////////////////////////////////*/

    function _interopCenterOf(uint256 _sourceChainId) internal view returns (address) {
        return _sourceChainId == L1_CHAIN_ID ? l1InteropCenter : sourceInteropCenter;
    }

    function _assetRouterOf(uint256 _sourceChainId) internal view returns (address) {
        return _sourceChainId == L1_CHAIN_ID ? l1AssetRouter : sourceAssetRouter;
    }

    /// @notice The mint data of `AMOUNT` of a token native to `_originChainId`, as its native token vault writes it.
    function _mintData(uint256 _originChainId, address _originToken) internal view returns (bytes memory) {
        return
            DataEncoding.encodeBridgeMintData({
                _originalCaller: depositor,
                _remoteReceiver: receiver,
                _originToken: _originToken,
                _amount: AMOUNT,
                _erc20Metadata: DataEncoding.encodeTokenData(
                    _originChainId,
                    abi.encode("Token"),
                    abi.encode("TKN"),
                    abi.encode(uint8(18))
                )
            });
    }

    /// @notice The bundle the interop center of `_sourceChainId` sends for a transfer of `_assetId`.
    function _transferBundle(
        uint256 _sourceChainId,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal view returns (InteropBundle memory bundle) {
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: _sourceChainId,
            destinationChainId: block.chainid,
            destinationBaseTokenAssetId: baseTokenAssetId,
            interopBundleSalt: keccak256("bundle salt"),
            calls: new InteropCall[](1),
            bundleAttributes: BundleAttributes({
                executionAddress: "",
                unbundlerAddress: "",
                useFixedFee: false,
                salt: keccak256("salt")
            })
        });
        bundle.calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: _assetRouterOf(_sourceChainId),
            value: 0,
            data: abi.encodeCall(AssetRouterBase.finalizeDeposit, (_sourceChainId, _assetId, _transferData))
        });
    }

    /// @notice A transfer of a token native to the source chain, the only kind a writer source may send.
    function _nativeTransferBundle(uint256 _sourceChainId) internal view returns (InteropBundle memory) {
        return
            _transferBundle(
                _sourceChainId,
                DataEncoding.encodeNTVAssetId(_sourceChainId, originToken),
                _mintData(_sourceChainId, originToken)
            );
    }

    /*//////////////////////////////////////////////////////////////
                            Roots and proofs
    //////////////////////////////////////////////////////////////*/

    /// @notice The root of the message root of `_sourceChainId` when its only local message is `_bundle` sent by
    /// `_sender` and it has no other chain: every tree has a single leaf.
    function _sourceRoot(
        uint256 _sourceChainId,
        address _sender,
        bytes memory _bundle
    ) internal pure returns (bytes32) {
        bytes32 batchRoot = OneWayBundleProofBuilder.chainBatchRoot(
            OneWayBundleProofBuilder.messageLeaf(_sender, bytes.concat(bytes1(0x01), _bundle))
        );
        bytes32 chainRoot = MessageHashing.batchLeafHash(batchRoot, 1, ROOT_TIMESTAMP);
        return MessageHashing.chainIdLeafHash(chainRoot, _sourceChainId);
    }

    /// @notice The proof of the bundle of {_sourceRoot}, against the root of `_rootChainId` at `rootBlock`.
    function _proof(
        uint256 _sourceChainId,
        address _sender,
        uint256 _rootChainId
    ) internal view returns (MessageInclusionProof memory) {
        return
            MessageInclusionProof({
                chainId: _sourceChainId,
                l1BatchNumber: 1,
                l2MessageIndex: 0,
                // The handler proves the bundle it executes, whatever data the proof carries.
                message: L2Message({txNumberInBatch: 0, sender: _sender, data: ""}),
                proof: OneWayBundleProofBuilder.twoHopProof({
                    _logLeafSiblings: OneWayBundleProofBuilder.chainBatchRootSiblings(new bytes32[](0)),
                    _batchTimestamp: ROOT_TIMESTAMP,
                    _batchLeafIndex: 0,
                    _batchLeafSiblings: new bytes32[](0),
                    _rootBlockNumber: rootBlock,
                    _rootChainId: _rootChainId,
                    _chainIndex: 0,
                    _sharedTreeSiblings: new bytes32[](0)
                })
            });
    }

    function _proof(uint256 _sourceChainId) internal view returns (MessageInclusionProof memory) {
        return _proof(_sourceChainId, _interopCenterOf(_sourceChainId), _sourceChainId);
    }

    function _interopRoot(uint256 _chainId, bytes32 _root) internal view returns (InteropRoot memory) {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        return InteropRoot({chainId: _chainId, blockOrBatchNumber: rootBlock, timestamp: ROOT_TIMESTAMP, sides: sides});
    }

    /// @notice Stores `_root` as the root of `_chainId` the way the chain gets it: the bootloader imports L1's
    /// roots, the writer writes the roots of its source chain.
    function _storeRoot(uint256 _chainId, bytes32 _root) internal {
        if (_chainId == L1_CHAIN_ID) {
            vm.prank(L2_BOOTLOADER_ADDRESS);
            rootStorage.addSingleInteropRoot(_interopRoot(_chainId, _root));
        } else {
            vm.prank(writer);
            IL2InteropRootStorage(address(rootStorage)).addInteropRootFromWriter(_interopRoot(_chainId, _root));
        }
    }

    /// @notice Stores the root that holds `_bundle` as a message of the source's interop center and returns the
    /// bundle's encoding and proof.
    function _deliver(
        uint256 _sourceChainId,
        InteropBundle memory _bundle
    ) internal returns (bytes memory encodedBundle, MessageInclusionProof memory proof) {
        encodedBundle = abi.encode(_bundle);
        _storeRoot(_sourceChainId, _sourceRoot(_sourceChainId, _interopCenterOf(_sourceChainId), encodedBundle));
        proof = _proof(_sourceChainId);
    }
}
