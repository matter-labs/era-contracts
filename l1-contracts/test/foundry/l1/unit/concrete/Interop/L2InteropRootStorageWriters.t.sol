// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {
    InteropRootAlreadyExists,
    InteropRootTimestampIsZero,
    InteropRootWritersNotEnabled,
    InvalidInteropRootSource,
    SidesLengthNotOne
} from "contracts/interop/InteropErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_ROOT_WRITERS_FEATURE, SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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
}
