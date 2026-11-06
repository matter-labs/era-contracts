"""Poseidon2 over BN254 (t = 4, x^5), bit-identical to Barretenberg v5.2.1 and Noir's
std::hash::poseidon2_permutation. Parameters come from poseidon2_bn254_params.json, extracted from bb's source."""

import json
from pathlib import Path

P = 21888242871839275222246405745257275088548364400416034343698204186575808495617
TWO_POW_64 = 1 << 64

_params = json.loads((Path(__file__).resolve().parent / "poseidon2_bn254_params.json").read_text())
_DIAG = [int(x, 16) for x in _params["internal_matrix_diagonal_minus_one"]]
_RC = [[int(x, 16) for x in row] for row in _params["round_constants"]]
_RF, _RP = _params["rounds_f"], _params["rounds_p"]


def _external(s):
    t0 = (s[0] + s[1]) % P
    t1 = (s[2] + s[3]) % P
    t2 = (2 * s[1] + t1) % P
    t3 = (2 * s[3] + t0) % P
    t4 = (4 * t1 + t3) % P
    t5 = (4 * t0 + t2) % P
    t6 = (t3 + t5) % P
    t7 = (t2 + t4) % P
    return [t6, t5, t7, t4]


def _internal(s):
    total = sum(s) % P
    return [(s[i] * _DIAG[i] + total) % P for i in range(4)]


def permutation(state):
    s = _external([x % P for x in state])
    for i in range(_RF // 2):
        s = _external([pow((s[j] + _RC[i][j]) % P, 5, P) for j in range(4)])
    for i in range(_RF // 2, _RF // 2 + _RP):
        s[0] = pow((s[0] + _RC[i][0]) % P, 5, P)
        s = _internal(s)
    for i in range(_RF // 2 + _RP, _RF + _RP):
        s = _external([pow((s[j] + _RC[i][j]) % P, 5, P) for j in range(4)])
    return s


def hash2(a, b):
    """Same as zkip_lite_lib::p2_hash2: one permutation with a length-tagged capacity element."""
    return permutation([a, b, 0, 2 * TWO_POW_64])[0]


def hash3(a, b, c):
    return permutation([a, b, c, 3 * TWO_POW_64])[0]


def hash_many(xs):
    """Same as zkip_lite_lib::p2_hash_many: rate-3 sponge, length-tagged IV, as std's Poseidon2Hasher."""
    state = [0, 0, 0, (len(xs) * TWO_POW_64) % P]
    full = len(xs) // 3
    for i in range(full):
        for j in range(3):
            state[j] = (state[j] + xs[3 * i + j]) % P
        state = permutation(state)
    rem = len(xs) % 3
    for j in range(rem):
        state[j] = (state[j] + xs[3 * full + j]) % P
    return permutation(state)[0]


def _self_test():
    out = permutation([int(x, 16) for x in _params["test_vector_input"]])
    assert out == [int(x, 16) for x in _params["test_vector_output"]], "Poseidon2 test vector mismatch"


_self_test()
