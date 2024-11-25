// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IVectorx} from "./IVectorx.sol";
import {IAvailBridge} from "./IAvailBridge.sol";

abstract contract AvailAttestationLib {
    struct AttestationData {
        uint32 blockNumber;
        uint128 leafIndex;
    }

    IAvailBridge public bridge;
    IVectorx public vectorx;

    mapping(bytes32 => AttestationData) public attestations;

    error InvalidAttestationProof();

    constructor(IAvailBridge _bridge) {
        bridge = _bridge;
        vectorx = bridge.vectorx();
    }

    function _attest(IAvailBridge.MerkleProofInput memory input) internal virtual {
        if (!bridge.verifyBlobLeaf(input)) revert InvalidAttestationProof();
        attestations[input.leaf] = AttestationData(
            vectorx.rangeStartBlocks(input.rangeHash) + uint32(input.dataRootIndex) + 1, uint128(input.leafIndex)
        );
    }
}
