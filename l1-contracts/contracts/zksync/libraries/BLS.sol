// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library BLS {
    // Field order
    uint256 private constant N = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // (N + 1) / 4
    uint256 private constant N14 = 5472060717959818805561601436314318772174077789324455915672259473661306552146;

    // Negated generator of G2
    uint256 private constant N_G2_X1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 private constant N_G2_X0 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 private constant N_G2_Y1 = 17805874995975841540914202342111839520379459829704422454583296818431106115052;
    uint256 private constant N_G2_Y0 = 13392588948715843804641432497768002650278120570034223513918757245338268106653;

    // Generator of G1
    uint256 private constant G1_X = 7875458235035678754887153468411793526875066621955642619646139314277366414792;
    uint256 private constant G1_Y = 8106623690154677659962327366078301943507317780154727084061147098569974335996;

    function verifyAggregation(
        uint256[2][] calldata pk1s,
        uint256[4] calldata aggregated_pk2s,
        uint256[2] calldata aggregated_sig,
        bytes calldata msg,
        uint256 nonce
    ) internal view returns (bool) {
        require(pk1s.length >= 2, "BLS: number of pk1s must be at least 2");

        uint256[2] memory message_point = hashToPoint(msg, nonce);
        if (!ecPairing(aggregated_sig, aggregated_pk2s, message_point)) {
            return false;
        }

        uint256[2] memory aggregated_pk1s = ecAdd(pk1s[0], pk1s[1]);
        for (uint i = 2; i < pk1s.length; i++) {
            aggregated_pk1s = ecAdd(aggregated_pk1s, pk1s[i]);
        }

        uint256 hash = uint256(keccak256(abi.encodePacked(
            msg,
            aggregated_sig[0],
            aggregated_sig[1],
            aggregated_pk2s[0],
            aggregated_pk2s[1],
            aggregated_pk2s[2],
            aggregated_pk2s[3],
            aggregated_pk1s[0],
            aggregated_pk1s[1]
        )));

        uint256[2] memory scaled_pk1s = ecMul(aggregated_pk1s, hash);
        uint256[2] memory scaled_pk1s_generator = ecMul([G1_X, G1_Y], hash);
        uint256[2] memory g1_part_sig = ecAdd(aggregated_sig, scaled_pk1s);
        uint256[2] memory g1_part_message_point = ecAdd(message_point, scaled_pk1s_generator);

        return ecPairing(g1_part_sig, aggregated_pk2s, g1_part_message_point);
    }

    function hashToPoint(
        bytes calldata msg,
        uint256 nonce
    ) internal view returns (uint256[2] memory p)
    {
        return mapToPoint(keccak256(msg), nonce);
    }

    function mapToPoint(
        bytes32 hash,
        uint256 nonce
    ) internal view returns (uint256[2] memory p) {
        uint256 x = addmod(uint256(hash), nonce, N);
        uint256 y;
        y = mulmod(x, x, N);
        y = mulmod(y, x, N);
        y = addmod(y, 3, N);

        bool found;
        (y, found) = sqrt(y);
        require(found, "BLS: sqrt failed");

        p[0] = x;
        p[1] = y;
    }

    function ecAdd(
        uint256[2] memory p1,
        uint256[2] memory p2
    ) internal view returns (uint256[2] memory r) {
        uint[4] memory input;
        input[0] = p1[0];
        input[1] = p1[1];
        input[2] = p2[0];
        input[3] = p2[1];
        bool callSuccess;
        assembly {
            callSuccess := staticcall(gas(), 6, input, 0xc0, r, 0x60)
        }
        require(callSuccess);
    }

    function ecMul(uint256[2] memory p, uint256 s) internal view returns (uint256[2] memory r) {
        uint[3] memory input;
        input[0] = p[0];
        input[1] = p[1];
        input[2] = s;
        bool callSuccess;
        assembly {
            callSuccess := staticcall(gas(), 7, input, 0x80, r, 0x60)
        }
        require(callSuccess);
    }

    function ecPairing(
        uint256[2] memory sig,
        uint256[4] memory pk,
        uint256[2] memory msgPoint
    ) internal view returns (bool) {
        uint[12] memory input;
        input[0] = sig[0];
        input[1] = sig[1];
        input[2] = N_G2_X1;
        input[3] = N_G2_X0;
        input[4] = N_G2_Y1;
        input[5] = N_G2_Y0;
        input[6] = msgPoint[0];
        input[7] = msgPoint[1];
        input[8] = pk[1];
        input[9] = pk[0];
        input[10] = pk[3];
        input[11] = pk[2];

        uint256[1] memory out;
        bool callSuccess;
        assembly {
            callSuccess := staticcall(gas(), 8, input, 384, out, 0x20)
        }
        if (!callSuccess) {
            return (false);
        }
        return (out[0] != 0);
    }

    function sqrt(uint256 xx) internal view returns (uint256 x, bool hasRoot) {
        bool callSuccess;
        assembly {
            let freemem := mload(0x40)
            mstore(freemem, 0x20)
            mstore(add(freemem, 0x20), 0x20)
            mstore(add(freemem, 0x40), 0x20)
            mstore(add(freemem, 0x60), xx)
            mstore(add(freemem, 0x80), N14)
            mstore(add(freemem, 0xA0), N)
            callSuccess := staticcall(gas(), 5, freemem, 0xC0, freemem, 0x20)
            x := mload(freemem)
            hasRoot := eq(xx, mulmod(x, x, N))
        }
        require(callSuccess, "BLS: sqrt modexp call failed");
    }
}
