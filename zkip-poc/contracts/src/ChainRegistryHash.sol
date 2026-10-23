// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    CHAIN_REGISTRY_LEAF_TAG,
    REGISTRY_FIELD,
    REGISTRY_LENGTH_TAG,
    REGISTRY_HALF_FULL_ROUNDS,
    REGISTRY_PARTIAL_ROUNDS,
    REGISTRY_TOTAL_ROUNDS,
    REGISTRY_ROUND_CONSTANTS,
    REGISTRY_DIAGONAL_0,
    REGISTRY_DIAGONAL_1,
    REGISTRY_DIAGONAL_2,
    REGISTRY_DIAGONAL_3
} from "./ChainRegistryConfig.sol";

/// @notice Poseidon2 BN254, t=4, matching the pinned Noir/Barretenberg permutation.
/// @dev Used only when admitting chains, never on the per-statement settlement path.
library ChainRegistryHash {
    function leaf(uint256 _chainId, uint256[REGISTRY_ROUND_CONSTANTS] memory _rc) internal pure returns (uint256) {
        return _permutation([CHAIN_REGISTRY_LEAF_TAG, _chainId, 0, 3 * REGISTRY_LENGTH_TAG], _rc);
    }

    function pair(
        uint256 _left,
        uint256 _right,
        uint256[REGISTRY_ROUND_CONSTANTS] memory _rc
    ) internal pure returns (uint256) {
        return _permutation([_left, _right, 0, 2 * REGISTRY_LENGTH_TAG], _rc);
    }

    function _permutation(
        uint256[4] memory _state,
        uint256[REGISTRY_ROUND_CONSTANTS] memory _rc
    ) private pure returns (uint256) {
        uint256[4] memory state = _external(_state);
        uint256 nextConstant;
        for (uint256 round = 0; round < REGISTRY_TOTAL_ROUNDS; ++round) {
            if (round < REGISTRY_HALF_FULL_ROUNDS || round >= REGISTRY_HALF_FULL_ROUNDS + REGISTRY_PARTIAL_ROUNDS) {
                for (uint256 j = 0; j < state.length; ++j) {
                    state[j] = _sbox(addmod(state[j], _rc[nextConstant++], REGISTRY_FIELD));
                }
                state = _external(state);
            } else {
                state[0] = _sbox(addmod(state[0], _rc[nextConstant++], REGISTRY_FIELD));
                uint256 total = addmod(
                    addmod(state[0], state[1], REGISTRY_FIELD),
                    addmod(state[2], state[3], REGISTRY_FIELD),
                    REGISTRY_FIELD
                );
                state[0] = addmod(total, mulmod(state[0], REGISTRY_DIAGONAL_0, REGISTRY_FIELD), REGISTRY_FIELD);
                state[1] = addmod(total, mulmod(state[1], REGISTRY_DIAGONAL_1, REGISTRY_FIELD), REGISTRY_FIELD);
                state[2] = addmod(total, mulmod(state[2], REGISTRY_DIAGONAL_2, REGISTRY_FIELD), REGISTRY_FIELD);
                state[3] = addmod(total, mulmod(state[3], REGISTRY_DIAGONAL_3, REGISTRY_FIELD), REGISTRY_FIELD);
            }
        }
        return state[0];
    }

    function _sbox(uint256 _x) private pure returns (uint256) {
        uint256 squared = mulmod(_x, _x, REGISTRY_FIELD);
        return mulmod(mulmod(squared, squared, REGISTRY_FIELD), _x, REGISTRY_FIELD);
    }

    function _external(uint256[4] memory _s) private pure returns (uint256[4] memory) {
        uint256 t0 = addmod(_s[0], _s[1], REGISTRY_FIELD);
        uint256 t1 = addmod(_s[2], _s[3], REGISTRY_FIELD);
        uint256 t2 = addmod(mulmod(2, _s[1], REGISTRY_FIELD), t1, REGISTRY_FIELD);
        uint256 t3 = addmod(mulmod(2, _s[3], REGISTRY_FIELD), t0, REGISTRY_FIELD);
        uint256 t4 = addmod(mulmod(4, t1, REGISTRY_FIELD), t3, REGISTRY_FIELD);
        uint256 t5 = addmod(mulmod(4, t0, REGISTRY_FIELD), t2, REGISTRY_FIELD);
        return [addmod(t3, t5, REGISTRY_FIELD), t5, addmod(t2, t4, REGISTRY_FIELD), t4];
    }
}
