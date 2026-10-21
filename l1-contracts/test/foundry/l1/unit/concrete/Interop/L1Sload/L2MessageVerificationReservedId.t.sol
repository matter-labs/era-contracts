// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {L2Log} from "contracts/common/Messaging.sol";
import {ReservedInteropRootChainId} from "contracts/interop/InteropErrors.sol";
import {L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {L2_INTEROP_ROOT_STORAGE} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @notice L1 block-hash anchors are stored as interop roots under `L1_BLOCK_HASH_IMPORT_ID`, so message proofs must
/// never resolve against that id. See {protocol-docs/l1sload.md#anchors}.
/// @dev The proof and root are the valid fixture of `L2MessageVerification.t.sol`; `interopRoots` is mocked to
/// serve the matching root for every key, so the only difference between passing and reverting is the chain id.
contract L2MessageVerificationReservedIdTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant BATCH_NUMBER = 66;
    uint256 internal constant LOG_INDEX = 1;
    bytes32 internal constant ROOT = 0x46ab0a3240394cd4339c065011ad354c67d269d3c6e0f8ad7eb2eb4b8a3ffb49;

    L2MessageVerification internal l2MessageVerification;

    function setUp() public {
        l2MessageVerification = new L2MessageVerification();
        vm.mockCall(
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encodeWithSelector(L2_INTEROP_ROOT_STORAGE.interopRoots.selector),
            abi.encode(ROOT, uint256(0))
        );
    }

    function test_realChainIdVerifies() public view {
        (L2Log memory log, bytes32[] memory proof) = _fixture();
        assertTrue(l2MessageVerification.proveL2LogInclusionShared(CHAIN_ID, BATCH_NUMBER, LOG_INDEX, log, proof));
    }

    function test_revertWhen_chainIdIsTheAnchorImportId() public {
        (L2Log memory log, bytes32[] memory proof) = _fixture();
        vm.expectRevert(abi.encodeWithSelector(ReservedInteropRootChainId.selector, L1_BLOCK_HASH_IMPORT_ID));
        l2MessageVerification.proveL2LogInclusionShared(L1_BLOCK_HASH_IMPORT_ID, BATCH_NUMBER, LOG_INDEX, log, proof);
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
