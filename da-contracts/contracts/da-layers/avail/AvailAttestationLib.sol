// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IVectorx} from "./IVectorx.sol";
import {IAvailBridge} from "./IAvailBridge.sol";

abstract contract AvailAttestationLib {
    struct AttestationData {
        /// @dev Address of the chain's diamond
        address attester;
        /// @dev Block number on Avail
        uint32 blockNumber;
        /// @dev Index of the leaf in the data root
        uint128 leafIndex;
    }

    IAvailBridge public bridge;
    IVectorx public vectorx;

    /// @dev Mapping from attestation leaf to attestation data.
    /// It is necessary for recovery of the state from the onchain data.
    mapping(bytes32 => AttestationData) public attestations;

    error InvalidAttestationProof();

    constructor(IAvailBridge _bridge) {
        bridge = _bridge;
        vectorx = bridge.vectorx();
    }

    function _attest(IAvailBridge.MerkleProofInput memory input) internal virtual {
        if (!bridge.verifyBlobLeaf(input)) revert InvalidAttestationProof();
        attestations[input.leaf] = AttestationData(
            msg.sender,
            vectorx.rangeStartBlocks(input.rangeHash) + uint32(input.dataRootIndex) + 1,
            uint128(input.leafIndex)
        );
    }
}
