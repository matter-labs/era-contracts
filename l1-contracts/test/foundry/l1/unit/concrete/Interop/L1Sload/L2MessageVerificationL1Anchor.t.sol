// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {InteropRoot, L2Log} from "contracts/common/Messaging.sol";
import {L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {L2_BOOTLOADER_ADDRESS, L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice An imported L1 block-hash anchor can never prove a message: anchors are not stored as interop roots, so a
/// proof against `L1_BLOCK_HASH_IMPORT_ID` finds no root. See {protocol-docs/l1sload.md#anchors}.
/// @dev The proof and root are the valid fixture of `L2MessageVerification.t.sol`, imported through the real
/// `L2InteropRootStorage`: the only difference between the verifying and the failing proof is that the root was
/// imported as an anchor.
contract L2MessageVerificationL1AnchorTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant BATCH_NUMBER = 66;
    uint256 internal constant LOG_INDEX = 1;
    bytes32 internal constant ROOT = 0x46ab0a3240394cd4339c065011ad354c67d269d3c6e0f8ad7eb2eb4b8a3ffb49;
    uint256 internal constant IMPORT_TIMESTAMP = 1_700_000_000;

    L2MessageVerification internal l2MessageVerification;

    function setUp() public {
        l2MessageVerification = new L2MessageVerification();
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
    }

    function test_rootImportedForAChainVerifies() public {
        _import(CHAIN_ID);
        (L2Log memory log, bytes32[] memory proof) = _fixture();
        assertTrue(l2MessageVerification.proveL2LogInclusionShared(CHAIN_ID, BATCH_NUMBER, LOG_INDEX, log, proof));
    }

    /// @dev The same root imported as the anchor of L1 block `BATCH_NUMBER` proves nothing.
    function test_proofAgainstAnImportedAnchorFails() public {
        _import(L1_BLOCK_HASH_IMPORT_ID);
        assertEq(L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR).l1AnchorBlockHash(), ROOT, "the anchor is set");

        (L2Log memory log, bytes32[] memory proof) = _fixture();
        assertFalse(
            l2MessageVerification.proveL2LogInclusionShared(
                L1_BLOCK_HASH_IMPORT_ID,
                BATCH_NUMBER,
                LOG_INDEX,
                log,
                proof
            )
        );
    }

    function _import(uint256 _chainId) internal {
        InteropRoot memory root;
        root.chainId = _chainId;
        root.blockOrBatchNumber = BATCH_NUMBER;
        root.timestamp = IMPORT_TIMESTAMP;
        root.sides = new bytes32[](1);
        root.sides[0] = ROOT;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR).addSingleInteropRoot(root);
    }

    function _fixture() internal pure returns (L2Log memory log, bytes32[] memory proof) {
        log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: 0x0000000000000000000000000000000000008008,
            key: 0x0000000000000000000000000000000000000000000000000000000000010008,
            value: 0x182bf04331468886c27903ea0bdc761fde4a166e29814a178da2d3f56d205982
        });
        proof = new bytes32[](4);
        proof[0] = bytes32(0x0103000100000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x32b59b40b87cf8e6ed0cbe1b5ff159ae24e29e9b924068f10a8719ebd5d9f6de);
        proof[2] = bytes32(0x74ba85451a61e8c7007a0f940e1ae069b3769932fca68148f2842d5c7edd253e);
        proof[3] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);
    }
}
