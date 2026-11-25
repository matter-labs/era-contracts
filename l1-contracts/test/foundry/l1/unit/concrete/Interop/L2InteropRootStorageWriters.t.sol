// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {InteropRoot, L2Log, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {
    InteropRootAlreadyExists,
    InteropRootTimestampIsZero,
    InteropRootWritersNotEnabled,
    InvalidInteropRootSource,
    SettlementLayerIsWriterSource,
    SidesLengthNotOne
} from "contracts/interop/InteropErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_ROOT_WRITERS_FEATURE, SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_ROOT_STORAGE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers the interop root writers of `L2InteropRootStorage`: who sets them, who may write, that writes keep
/// the import invariants, and that they leave the bootloader import untouched.
/// See {protocol-docs/interop.md#interop-root-writers}.
/// @dev The real `L2Bridgehub` code is etched at its built-in address and its feature flag is set through the
/// service-transaction path, as on a chain.
contract L2InteropRootStorageWritersTest is Test {
    uint256 internal constant SOURCE_CHAIN_ID = 1338;
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1;
    uint256 internal constant BLOCK_NUMBER = 7;
    uint256 internal constant TIMESTAMP = 1_700_000_000;

    /// @dev topic0 of `InteropRootAdded`, which ZKsync OS folds into the batch's `dependencyRootsRollingHash`.
    bytes32 internal constant INTEROP_ROOT_ADDED_TOPIC =
        keccak256("InteropRootAdded(uint256,uint256,uint256,bytes32[])");

    L2InteropRootStorage internal rootStorage;
    address internal writer;

    function setUp() public {
        rootStorage = new L2InteropRootStorage();
        vm.etch(L2_BRIDGEHUB_ADDR, address(new L2Bridgehub()).code);
        writer = makeAddr("writer");
    }

    function _enableFeature(bool _enabled) internal {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2Bridgehub(L2_BRIDGEHUB_ADDR).setChainFeatureEnabled(INTEROP_ROOT_WRITERS_FEATURE, _enabled);
    }

    function _setWriter(uint256 _sourceChainId, address _writer) internal {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        rootStorage.setInteropRootWriter(_sourceChainId, _writer);
    }

    function _root(
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _timestamp,
        bytes32 _side
    ) internal pure returns (InteropRoot memory interopRoot) {
        interopRoot.chainId = _chainId;
        interopRoot.blockOrBatchNumber = _blockNumber;
        interopRoot.timestamp = _timestamp;
        interopRoot.sides = new bytes32[](1);
        interopRoot.sides[0] = _side;
    }

    /*//////////////////////////////////////////////////////////////
                            setInteropRootWriter
    //////////////////////////////////////////////////////////////*/

    function test_setInteropRootWriter_byServiceTransaction() public {
        vm.expectEmit(true, true, false, true, address(rootStorage));
        emit IL2InteropRootStorage.InteropRootWriterSet(SOURCE_CHAIN_ID, writer);
        _setWriter(SOURCE_CHAIN_ID, writer);
        assertEq(rootStorage.interopRootWriter(SOURCE_CHAIN_ID), writer);

        _setWriter(SOURCE_CHAIN_ID, address(0));
        assertEq(rootStorage.interopRootWriter(SOURCE_CHAIN_ID), address(0));
    }

    /// @notice A chain stays a writer source once a writer was set for it: the roots the writer added outlive it.
    function test_isWriterSource_setWithTheWriterAndKeptAfterRemoval() public {
        assertFalse(rootStorage.isWriterSource(SOURCE_CHAIN_ID));
        _setWriter(SOURCE_CHAIN_ID, address(0));
        assertFalse(rootStorage.isWriterSource(SOURCE_CHAIN_ID), "removing a writer that was never set");

        _setWriter(SOURCE_CHAIN_ID, writer);
        assertTrue(rootStorage.isWriterSource(SOURCE_CHAIN_ID));
        _setWriter(SOURCE_CHAIN_ID, address(0));
        assertTrue(rootStorage.isWriterSource(SOURCE_CHAIN_ID), "kept after removal");
        assertFalse(rootStorage.isWriterSource(SETTLEMENT_LAYER_CHAIN_ID));
    }

    function testFuzz_setInteropRootWriter_revertWhen_notServiceTransaction(address _caller) public {
        vm.assume(_caller != SERVICE_TRANSACTION_SENDER);
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        rootStorage.setInteropRootWriter(SOURCE_CHAIN_ID, writer);
    }

    function test_setInteropRootWriter_revertWhen_sourceIsThisChain() public {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootSource.selector, block.chainid));
        rootStorage.setInteropRootWriter(block.chainid, writer);
    }

    /*//////////////////////////////////////////////////////////////
                            addInteropRootFromWriter
    //////////////////////////////////////////////////////////////*/

    function test_addInteropRootFromWriter_storesTupleAndEmitsWriterEvent() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);
        InteropRoot memory interopRoot = _root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root"));

        vm.recordLogs();
        vm.prank(writer);
        rootStorage.addInteropRootFromWriter(interopRoot);

        StoredInteropRoot memory stored = rootStorage.interopRoots(SOURCE_CHAIN_ID, BLOCK_NUMBER);
        assertEq(stored.root, interopRoot.sides[0]);
        assertEq(stored.timestamp, TIMESTAMP);
        assertEq(rootStorage.latestInteropRootTimestamp(SOURCE_CHAIN_ID), TIMESTAMP);

        // Exactly one event, and not `InteropRootAdded`: the root must stay out of `dependencyRootsRollingHash`.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(rootStorage));
        assertEq(logs[0].topics[0], IL2InteropRootStorage.InteropRootAddedByWriter.selector);
        assertTrue(logs[0].topics[0] != INTEROP_ROOT_ADDED_TOPIC);
        assertEq(uint256(logs[0].topics[1]), SOURCE_CHAIN_ID);
        assertEq(uint256(logs[0].topics[2]), BLOCK_NUMBER);
        assertEq(address(uint160(uint256(logs[0].topics[3]))), writer);
        (uint256 timestamp, bytes32[] memory sides) = abi.decode(logs[0].data, (uint256, bytes32[]));
        assertEq(timestamp, TIMESTAMP);
        assertEq(sides.length, 1);
        assertEq(sides[0], interopRoot.sides[0]);
    }

    function test_addInteropRootFromWriter_revertWhen_notTheChainsWriter() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));
    }

    /// @notice A writer is bound to its source chain: it can't write the settlement layer's roots, whose import the
    /// settlement layer checks, nor any other chain's.
    function test_addInteropRootFromWriter_revertWhen_otherSourceChain() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, writer));
        rootStorage.addInteropRootFromWriter(
            _root(SETTLEMENT_LAYER_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root"))
        );
    }

    function test_addInteropRootFromWriter_revertWhen_writerRemoved() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);
        _setWriter(SOURCE_CHAIN_ID, address(0));

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, writer));
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));
    }

    /// @notice Disabling the chain feature stops every writer at once, without removing them one by one.
    function test_addInteropRootFromWriter_revertWhen_featureDisabled() public {
        _setWriter(SOURCE_CHAIN_ID, writer);

        vm.prank(writer);
        vm.expectRevert(InteropRootWritersNotEnabled.selector);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));

        _enableFeature(true);
        _enableFeature(false);
        vm.prank(writer);
        vm.expectRevert(InteropRootWritersNotEnabled.selector);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));
    }

    function test_addInteropRootFromWriter_revertWhen_invariantsBroken() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);

        vm.startPrank(writer);
        vm.expectRevert(InteropRootTimestampIsZero.selector);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, 0, keccak256("root")));

        vm.expectRevert(MessageRootIsZero.selector);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, bytes32(0)));

        InteropRoot memory twoSides = _root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root"));
        twoSides.sides = new bytes32[](2);
        twoSides.sides[0] = keccak256("root");
        twoSides.sides[1] = keccak256("side");
        vm.expectRevert(SidesLengthNotOne.selector);
        rootStorage.addInteropRootFromWriter(twoSides);

        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));
        vm.expectRevert(InteropRootAlreadyExists.selector);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP + 1, keccak256("other")));
        vm.stopPrank();

        StoredInteropRoot memory stored = rootStorage.interopRoots(SOURCE_CHAIN_ID, BLOCK_NUMBER);
        assertEq(stored.root, keccak256("root"), "the first root stays");
        assertEq(stored.timestamp, TIMESTAMP);
    }

    /// @notice The writer path keeps `latestInteropRootTimestamp` the maximum over all imports, as the bootloader does.
    function test_addInteropRootFromWriter_latestTimestampNeverDecreases() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);

        vm.startPrank(writer);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("a")));
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER - 1, TIMESTAMP - 10, keccak256("b")));
        vm.stopPrank();
        assertEq(rootStorage.latestInteropRootTimestamp(SOURCE_CHAIN_ID), TIMESTAMP);
    }

    /// @notice The built-in is upgraded in place, so the writers are appended after the existing mappings.
    function test_storageLayout_writersAppendedAfterExistingMappings() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);
        vm.prank(writer);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));

        bytes32 rootSlot = keccak256(abi.encode(BLOCK_NUMBER, keccak256(abi.encode(SOURCE_CHAIN_ID, uint256(0)))));
        assertEq(vm.load(address(rootStorage), rootSlot), keccak256("root"), "storedInteropRoots at slot 0");
        assertEq(
            uint256(vm.load(address(rootStorage), bytes32(uint256(rootSlot) + 1))),
            TIMESTAMP,
            "timestamp next to the root"
        );
        assertEq(
            uint256(vm.load(address(rootStorage), keccak256(abi.encode(SOURCE_CHAIN_ID, uint256(1))))),
            TIMESTAMP,
            "latestInteropRootTimestamp at slot 1"
        );
        assertEq(
            address(
                uint160(uint256(vm.load(address(rootStorage), keccak256(abi.encode(SOURCE_CHAIN_ID, uint256(2))))))
            ),
            writer,
            "interopRootWriter at slot 2"
        );
        assertEq(
            uint256(vm.load(address(rootStorage), keccak256(abi.encode(SOURCE_CHAIN_ID, uint256(3))))),
            1,
            "isWriterSource at slot 3"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        The bootloader import is unaffected
    //////////////////////////////////////////////////////////////*/

    function test_bootloaderImport_stillEmitsInteropRootAdded() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);
        InteropRoot memory interopRoot = _root(SETTLEMENT_LAYER_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("sl"));

        vm.expectEmit(true, true, false, true, address(rootStorage));
        emit IL2InteropRootStorage.InteropRootAdded(
            SETTLEMENT_LAYER_CHAIN_ID,
            BLOCK_NUMBER,
            TIMESTAMP,
            interopRoot.sides
        );
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(interopRoot);

        assertEq(rootStorage.interopRoots(SETTLEMENT_LAYER_CHAIN_ID, BLOCK_NUMBER).root, keccak256("sl"));
    }

    /// @notice A writer can't import through the bootloader entry points.
    function test_bootloaderImport_revertWhen_calledByWriter() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, writer));
        rootStorage.addSingleInteropRoot(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));
    }

    /// @notice The writer's and the bootloader's roots share the no-overwrite rule per key.
    function test_bootloaderImport_revertWhen_writerAlreadyWroteTheKey() public {
        _enableFeature(true);
        _setWriter(SOURCE_CHAIN_ID, writer);
        vm.prank(writer);
        rootStorage.addInteropRootFromWriter(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("root")));

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(InteropRootAlreadyExists.selector);
        rootStorage.addSingleInteropRoot(_root(SOURCE_CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, keccak256("other")));
    }

    /*//////////////////////////////////////////////////////////////
            L2MessageVerification and the roots of writers
    //////////////////////////////////////////////////////////////*/

    /// @dev The chain, batch and settlement layer of `_doubleProof`, a real proof of a log of chain 271 through the
    /// root of its settlement layer, chain 506, at block 243 (also used in `L2MessageVerificationDepthRegression`).
    uint256 internal constant PROVEN_CHAIN_ID = 271;
    uint256 internal constant PROVEN_BATCH_NUMBER = 66;
    uint256 internal constant PROOF_SETTLEMENT_LAYER_CHAIN_ID = 506;
    uint256 internal constant PROOF_SETTLEMENT_LAYER_BLOCK = 243;
    bytes32 internal constant PROOF_SETTLEMENT_LAYER_ROOT =
        0xf2ed765ea90479defa99f4853559bec02617067e736f70475cc64a8e571f509a;

    /// @notice A writer's roots vouch for its source chain only, never as the settlement layer of another chain: the
    /// same proof that holds against a bootloader-imported root is refused against a written one.
    function test_l2MessageVerification_refusesWriterSourceAsSettlementLayer() public {
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(rootStorage).code);
        L2InteropRootStorage builtIn = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);
        L2MessageVerification verification = new L2MessageVerification();
        (L2Log memory log, bytes32[] memory proof) = _doubleProof();
        InteropRoot memory slRoot = _root(
            PROOF_SETTLEMENT_LAYER_CHAIN_ID,
            PROOF_SETTLEMENT_LAYER_BLOCK,
            TIMESTAMP,
            PROOF_SETTLEMENT_LAYER_ROOT
        );

        uint256 snapshot = vm.snapshotState();
        InteropRoot[] memory roots = new InteropRoot[](1);
        roots[0] = slRoot;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        builtIn.addInteropRootsInBatch(roots);
        assertTrue(
            verification.proveL2LogInclusionShared(PROVEN_CHAIN_ID, PROVEN_BATCH_NUMBER, 1, log, proof),
            "the settlement layer's own root"
        );
        vm.revertToState(snapshot);

        _enableFeature(true);
        vm.prank(SERVICE_TRANSACTION_SENDER);
        builtIn.setInteropRootWriter(PROOF_SETTLEMENT_LAYER_CHAIN_ID, writer);
        vm.prank(writer);
        builtIn.addInteropRootFromWriter(slRoot);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementLayerIsWriterSource.selector,
                PROOF_SETTLEMENT_LAYER_CHAIN_ID,
                PROVEN_CHAIN_ID
            )
        );
        verification.proveL2LogInclusionShared(PROVEN_CHAIN_ID, PROVEN_BATCH_NUMBER, 1, log, proof);
    }

    function _doubleProof() internal pure returns (L2Log memory log, bytes32[] memory proof) {
        log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: 0x0000000000000000000000000000000000008008,
            key: 0x0000000000000000000000000000000000000000000000000000000000010008,
            value: 0x182bf04331468886c27903ea0bdc761fde4a166e29814a178da2d3f56d205982
        });
        proof = new bytes32[](28);
        proof[0] = bytes32(0x010f060000000000000000000000000000000000000000000000000000000000);
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
        proof[16] = bytes32(uint256(0));
        proof[17] = bytes32(0x0000000000000000000000000000000000000000000000000000000000000034);
        proof[18] = bytes32(0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21);
        proof[19] = bytes32(0xcc4c41edb0c2031348b292b768e9bac1ee8c92c09ef8a3277c2ece409c12d86a);
        proof[20] = bytes32(0x665220c0a39a5c4886626c93dfe3f253324bd0fd48bf037156b977d2da1c2a80);
        proof[21] = bytes32(0x4cd95f8962e2e3b5f525a0f4fdfbbf0667990c7159528a008057f3592bcb2c06);
        proof[22] = bytes32(0x73374357c2721f1e18426e45490035daf9a01b4fd064b9fc6bf85acf888bbc42);
        proof[23] = bytes32(0x9b63d72e0483741f19d143751f22f965461f0a98897b8ffffedd086935f6bc26);
        proof[24] = bytes32(0x000000000000000000000000000000f300000000000000000000000000000001);
        proof[25] = bytes32(0x00000000000000000000000000000000000000000000000000000000000001fa);
        proof[26] = bytes32(0x0101000100000000000000000000000000000000000000000000000000000000);
        proof[27] = bytes32(0xf84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f828);
    }
}
