// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {InvalidSettlementLayerForBatch} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {InteropRoot, L2Message, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_INTEROP_ROOT_STORAGE_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";

import {OneWayBundleProofBuilder} from "test-utils/OneWayBundleProofBuilder.sol";

/// @notice The local messages of `L1MessageRoot`, see {protocol-docs/message-root.md#local-messages}. The Bridgehub
/// is mocked to isolate the message root. The proofs are checked by a real `L2MessageVerification` over a real
/// `L2InteropRootStorage`, as a chain that imports the roots would check them.
contract L1MessageRootLocalMessagesTest is Test {
    uint256 internal constant OTHER_CHAIN_ID = 271;

    address internal bridgehub = makeAddr("bridgehub");
    address internal chainAssetHandler = makeAddr("chainAssetHandler");
    address internal bridgehubOwner = makeAddr("bridgehubOwner");
    address internal upgrader = makeAddr("upgrader");
    address internal otherChain = makeAddr("otherChain");
    address internal sender = makeAddr("localMessageSender");

    L1MessageRoot internal messageRoot;
    L2MessageVerification internal verification;

    function setUp() public {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(new uint256[](0)));
        vm.mockCall(bridgehub, abi.encodeCall(IOwnable.owner, ()), abi.encode(bridgehubOwner));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (OTHER_CHAIN_ID)), abi.encode(otherChain));

        vm.prank(upgrader);
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(bridgehub, chainAssetHandler)),
                    address(proxyAdmin),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );

        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
        verification = new L2MessageVerification();

        vm.prank(bridgehubOwner);
        messageRoot.setLocalMessageSender(sender, true);
    }

    /*//////////////////////////////////////////////////////////////
                        setLocalMessageSender
    //////////////////////////////////////////////////////////////*/

    function test_setLocalMessageSender_byBridgehubOwnerOrUpgrader() public {
        address newSender = makeAddr("newSender");
        assertFalse(messageRoot.isLocalMessageSender(newSender));

        vm.expectEmit(true, false, false, true, address(messageRoot));
        emit IL1MessageRoot.LocalMessageSenderSet(newSender, true);
        vm.prank(bridgehubOwner);
        messageRoot.setLocalMessageSender(newSender, true);
        assertTrue(messageRoot.isLocalMessageSender(newSender));

        vm.expectEmit(true, false, false, true, address(messageRoot));
        emit IL1MessageRoot.LocalMessageSenderSet(newSender, false);
        vm.prank(upgrader);
        messageRoot.setLocalMessageSender(newSender, false);
        assertFalse(messageRoot.isLocalMessageSender(newSender));
    }

    function testFuzz_setLocalMessageSender_revertWhen_notOwnerNorUpgrader(address _caller) public {
        vm.assume(_caller != bridgehubOwner && _caller != upgrader);
        // The proxy admin can't reach the implementation at all.
        vm.assume(_caller != address(uint160(uint256(vm.load(address(messageRoot), _ADMIN_SLOT)))));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        messageRoot.setLocalMessageSender(_caller, true);
    }

    /*//////////////////////////////////////////////////////////////
                            sendLocalMessage
    //////////////////////////////////////////////////////////////*/

    function testFuzz_sendLocalMessage_revertWhen_notAllowed(address _caller) public {
        vm.assume(_caller != sender);
        vm.assume(_caller != address(uint160(uint256(vm.load(address(messageRoot), _ADMIN_SLOT)))));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        messageRoot.sendLocalMessage(keccak256("message"));
    }

    function test_sendLocalMessage_revertWhen_senderWasDisallowed() public {
        vm.prank(bridgehubOwner);
        messageRoot.setLocalMessageSender(sender, false);

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, sender));
        messageRoot.sendLocalMessage(keccak256("message"));
    }

    /// @notice A message is the only message of the next batch of the message root's own chain: the batch root is the
    /// chain batch root of a batch whose logs root is the message's leaf, built with the caller as the sender.
    function test_sendLocalMessage_recordsOneBatchPerMessage() public {
        bytes32 messageHash = keccak256("message");
        // The leaf written out, independently of `MessageHashing`.
        bytes32 leaf = keccak256(
            abi.encodePacked(
                uint8(0),
                true,
                uint16(0),
                L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                bytes32(uint256(uint160(sender))),
                messageHash
            )
        );
        bytes32 batchRoot = ChainBatchRootTree.compute(
            leaf,
            bytes32(0),
            ChainBatchRootTree.EMPTY_IMT_ROOT,
            ChainBatchRootTree.EMPTY_IMT_ROOT
        );
        vm.warp(1234);
        vm.roll(77);
        assertEq(messageRoot.currentChainBatchNumber(block.chainid), 0);
        assertEq(messageRoot.chainTreeLeafCount(block.chainid), 0);

        vm.expectEmit(true, true, false, true, address(messageRoot));
        emit IMessageRootBase.AppendedChainBatchRoot(block.chainid, 1, batchRoot, 1234);
        vm.expectEmit(true, true, false, true, address(messageRoot));
        emit IL1MessageRoot.LocalMessageSent(sender, 1, messageHash);
        vm.prank(sender);
        uint256 batchNumber = messageRoot.sendLocalMessage(messageHash);

        assertEq(batchNumber, 1);
        assertEq(messageRoot.currentChainBatchNumber(block.chainid), 1);
        assertEq(messageRoot.chainBatchRoots(block.chainid, 1), batchRoot);
        assertEq(messageRoot.chainBatchRootTimestamp(block.chainid, 1), 1234);
        assertEq(messageRoot.chainTreeLeafCount(block.chainid), 1);
        // The chain tree holds one leaf, so its root is the leaf, and so does the shared tree.
        bytes32 chainRoot = MessageHashing.batchLeafHash(batchRoot, 1, 1234);
        assertEq(messageRoot.getChainRoot(block.chainid), chainRoot);
        bytes32 sharedRoot = MessageHashing.chainIdLeafHash(chainRoot, block.chainid);
        assertEq(messageRoot.getAggregatedRoot(), sharedRoot);
        StoredInteropRoot memory recorded = messageRoot.historicalRoot(77);
        assertEq(recorded.root, sharedRoot);
        assertEq(recorded.timestamp, 1234);

        vm.prank(sender);
        assertEq(messageRoot.sendLocalMessage(keccak256("second message")), 2);
        assertEq(messageRoot.currentChainBatchNumber(block.chainid), 2);
        assertEq(messageRoot.chainTreeLeafCount(block.chainid), 2);
    }

    /// @notice The same message hash sent by two senders gives two different batch roots: a sender only sends as
    /// itself.
    function test_sendLocalMessage_bindsTheSender() public {
        address otherSender = makeAddr("otherSender");
        vm.prank(bridgehubOwner);
        messageRoot.setLocalMessageSender(otherSender, true);
        bytes memory data = "message";

        vm.prank(sender);
        messageRoot.sendLocalMessage(keccak256(data));
        vm.prank(otherSender);
        messageRoot.sendLocalMessage(keccak256(data));

        assertEq(
            messageRoot.chainBatchRoots(block.chainid, 1),
            OneWayBundleProofBuilder.chainBatchRoot(OneWayBundleProofBuilder.messageLeaf(sender, data))
        );
        assertEq(
            messageRoot.chainBatchRoots(block.chainid, 2),
            OneWayBundleProofBuilder.chainBatchRoot(OneWayBundleProofBuilder.messageLeaf(otherSender, data))
        );
        assertNotEq(messageRoot.chainBatchRoots(block.chainid, 1), messageRoot.chainBatchRoots(block.chainid, 2));
    }

    /*//////////////////////////////////////////////////////////////
                                Proofs
    //////////////////////////////////////////////////////////////*/

    /// @notice The first message is provable while the message root's own chain is the only chain: both the chain
    /// tree and the shared tree have a single leaf, so the proof has no siblings in either.
    function test_proof_firstMessageOfTheOnlyChain() public {
        bytes memory data = "message";
        vm.roll(10);
        vm.prank(sender);
        messageRoot.sendLocalMessage(keccak256(data));

        bytes32[] memory proof = OneWayBundleProofBuilder.localMessageProof(messageRoot, 1, 10);
        assertEq(proof.length, 9, "metadata, 3 log siblings, timestamp, mask, block, chain id, metadata");
        _importRoot(10);
        assertTrue(_proveOnL2(1, sender, data, proof));
        assertFalse(_proveOnL2(1, makeAddr("otherSender"), data, proof), "another sender");
        assertFalse(_proveOnL2(1, sender, "other message", proof), "another message");
    }

    /// @notice Every local message stays provable against any later root, whatever the depth of the chain tree
    /// and with another chain's batches in the shared tree.
    function testFuzz_proof_anyMessageAgainstALaterRoot(uint256 _messageCount, uint256 _provenBatch) public {
        _messageCount = bound(_messageCount, 1, 9);
        _provenBatch = bound(_provenBatch, 1, _messageCount);

        vm.prank(bridgehub);
        messageRoot.addNewChain(OTHER_CHAIN_ID, 0);
        for (uint256 i = 1; i <= _messageCount; ++i) {
            vm.roll(100 + i);
            vm.warp(1000 + i);
            vm.prank(sender);
            messageRoot.sendLocalMessage(keccak256(_message(i)));
            // The other chain settles batches in between, which changes the shared tree only.
            vm.prank(otherChain);
            messageRoot.addChainBatchRootV32(OTHER_CHAIN_ID, i, keccak256(abi.encode("other chain batch", i)));
        }
        uint256 rootBlock = 100 + _messageCount;

        bytes32[] memory proof = OneWayBundleProofBuilder.localMessageProof(messageRoot, _provenBatch, rootBlock);
        _importRoot(rootBlock);
        assertTrue(_proveOnL2(_provenBatch, sender, _message(_provenBatch), proof));
        // A proof is bound to its batch: it does not prove the message of another batch.
        uint256 otherBatch = _provenBatch == 1 ? 2 : _provenBatch - 1;
        assertFalse(_proveOnL2(_provenBatch, sender, _message(otherBatch), proof));
    }

    /// @notice A local message is provable on the chain that sent it, against its own batch root.
    function test_proof_onTheSendingChain() public {
        bytes memory data = "message";
        vm.prank(sender);
        messageRoot.sendLocalMessage(keccak256(data));

        bytes32[] memory proof = OneWayBundleProofBuilder.finalProof(new bytes32[](0));
        L2Message memory message = L2Message({txNumberInBatch: 0, sender: sender, data: data});
        assertTrue(messageRoot.proveL2MessageInclusionShared(block.chainid, 1, 0, message, proof));
        message.data = "other message";
        assertFalse(messageRoot.proveL2MessageInclusionShared(block.chainid, 1, 0, message, proof));
    }

    /// @notice No chain settles on the message root's own slot: a proof that names this chain as the settlement
    /// layer of another chain is refused before the slot's batch roots are read.
    function test_proof_revertWhen_settlementLayerIsThisChain() public {
        vm.prank(sender);
        messageRoot.sendLocalMessage(keccak256("message"));

        bytes32[] memory proof = OneWayBundleProofBuilder.twoHopProof({
            _logLeafSiblings: new bytes32[](0),
            _batchTimestamp: block.timestamp,
            _batchLeafIndex: 0,
            _batchLeafSiblings: new bytes32[](0),
            _rootBlockNumber: 1,
            _rootChainId: block.chainid,
            _chainIndex: 0,
            _sharedTreeSiblings: new bytes32[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(InvalidSettlementLayerForBatch.selector, OTHER_CHAIN_ID, 5, block.chainid)
        );
        messageRoot.proveL2LeafInclusionShared(OTHER_CHAIN_ID, 5, 0, keccak256("leaf"), proof);
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev EIP-1967 admin slot.
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _message(uint256 _index) internal pure returns (bytes memory) {
        return abi.encode("message", _index);
    }

    /// @dev Imports the message root's recorded root of `_blockNumber` as the bootloader of a chain that settles on
    /// this chain does.
    function _importRoot(uint256 _blockNumber) internal {
        StoredInteropRoot memory recorded = messageRoot.historicalRoot(_blockNumber);
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = recorded.root;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR).addSingleInteropRoot(
            InteropRoot({
                chainId: block.chainid,
                blockOrBatchNumber: _blockNumber,
                sides: sides,
                timestamp: recorded.timestamp
            })
        );
    }

    function _proveOnL2(
        uint256 _batchNumber,
        address _sender,
        bytes memory _data,
        bytes32[] memory _proof
    ) internal view returns (bool) {
        return
            verification.proveL2MessageInclusionShared(
                block.chainid,
                _batchNumber,
                0,
                L2Message({txNumberInBatch: 0, sender: _sender, data: _data}),
                _proof
            );
    }
}
