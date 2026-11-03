// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.7.0 <0.9.0;

/// @title PilfflonkVerifier
/// @notice Verifies the pilfflonk proofs of the vkey with digest 0xe8f7e04ba2ff5bedda661368eb890d4b70fa8c139cac772ef42cb30cac2f454b: its
///         pilfflonk.vkey.json, from which `proofman-setup setup-pilfflonk --solidity` or
///         `proofman-setup pilfflonk-solidity` generated it.
/// @dev    It accepts exactly the proofs the JS verifier (pilfflonk/js, verify.js) accepts, and its
///         steps are the JS's. Calldata: `proof` is the proof's bytes (the commitments of the
///         non-fixed f_i, W, W', the evaluations, the Q_i(xi) if Q is split, inv and invZh) as
///         69 big-endian words; `pubSignals`, the publics.
contract PilfflonkVerifier {
    uint32 constant n = 1048576; // Domain size, N = 2^20

    // Scalar field size
    uint256 constant q    = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant qf   = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    // [1]_1
    uint256 constant G1x  = 1;
    uint256 constant G1y  = 2;
    // [1]_2
    uint256 constant G2x1 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant G2x2 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant G2y1 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    uint256 constant G2y2 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;

    // Verifier preprocessed input x·[1]_2: the vkey's X_2, [tau]_2
    uint256 constant X2x1 = 21831381940315734285607113342023901060522397560371972897001948545212302161822;
    uint256 constant X2x2 = 17231025384763736816414546592865244497437017442647097510447326538965263639101;
    uint256 constant X2y1 = 2388026358213174446665280700919698872609886601280537296205114254867301080648;
    uint256 constant X2y2 = 11507326595632554467052522095592665270651932854513688777769618397986436103170;

    // The vkey's digest mod r, the first value of the transcript
    uint256 constant DIGEST = 17821568639304283155844778003823657539909158166921017530636260459436777096519;

    // The commitments of the fixed f_i, the vkey's: never the proof's
    uint256 constant f0x = 11100321013976884875374740240166113250992033727963372534921505806656579460061;
    uint256 constant f0y = 17568762424974132221896330878994881199219653345805682551975077737218425146171;
    uint256 constant f1x = 8109160553318540370373626134121471686403517801330575531198080918243764256174;
    uint256 constant f1y = 2170144729288253735972236377176544304833810567330602983178520141597277886938;
    uint256 constant f2x = 1629218841826553250808522290457231574509104745320440655007676224910579415807;
    uint256 constant f2y = 11969251427647224160527854216675576905598723981155430914351102250810251245612;

    // Proof calldata: the byte offset of every value (proof.rs, Proof::to_bytes)
    uint256 constant pF3 = 4; // [f3]_1, stage 1
    uint256 constant pF4 = 68; // [f4]_1, stage 1
    uint256 constant pF5 = 132; // [f5]_1, stage 1
    uint256 constant pF6 = 196; // [f6]_1, stage 1
    uint256 constant pF7 = 260; // [f7]_1, stage 2
    uint256 constant pF8 = 324; // [f8]_1, stage 3
    uint256 constant pW = 388; // [W]_1
    uint256 constant pWp = 452; // [W']_1
    uint256 constant pEval2 = 516; // Wrap.S[0] (evMap[2])
    uint256 constant pEval3 = 548; // Wrap.S[1] (evMap[3])
    uint256 constant pEval4 = 580; // Wrap.S[2] (evMap[4])
    uint256 constant pEval5 = 612; // Wrap.S[3] (evMap[5])
    uint256 constant pEval6 = 644; // Wrap.S[4] (evMap[6])
    uint256 constant pEval7 = 676; // Wrap.S[5] (evMap[7])
    uint256 constant pEval8 = 708; // Wrap.S[6] (evMap[8])
    uint256 constant pEval9 = 740; // Wrap.S[7] (evMap[9])
    uint256 constant pEval10 = 772; // Wrap.S[8] (evMap[10])
    uint256 constant pEval11 = 804; // Wrap.C[0] (evMap[11])
    uint256 constant pEval12 = 836; // Wrap.C[1] (evMap[12])
    uint256 constant pEval13 = 868; // Wrap.C[2] (evMap[13])
    uint256 constant pEval14 = 900; // Wrap.C[3] (evMap[14])
    uint256 constant pEval15 = 932; // Wrap.C[4] (evMap[15])
    uint256 constant pEval16 = 964; // Wrap.K[0] (evMap[16])
    uint256 constant pEval17 = 996; // Wrap.K[1] (evMap[17])
    uint256 constant pEval18 = 1028; // Wrap.K[2] (evMap[18])
    uint256 constant pEval19 = 1060; // Wrap.K[3] (evMap[19])
    uint256 constant pEval20 = 1092; // Wrap.K[4] (evMap[20])
    uint256 constant pEval21 = 1124; // Wrap.POSEIDON (evMap[21])
    uint256 constant pEval22 = 1156; // Wrap.POSEIDON_FULL_ROUND (evMap[22])
    uint256 constant pEval23 = 1188; // Wrap.POSEIDON_PARTIAL_ROUND (evMap[23])
    uint256 constant pEval24 = 1220; // Wrap.RANGE_CHECK (evMap[24])
    uint256 constant pEval25 = 1252; // Wrap.RANGE (evMap[25])
    uint256 constant pEval26 = 1284; // Wrap.PUBLICS_ROW (evMap[26])
    uint256 constant pEval27 = 1316; // Wrap.ID (evMap[27])
    uint256 constant pEval28 = 1348; // __L1__ (evMap[28])
    uint256 constant pEval43 = 1380; // __L1__w (evMap[43])
    uint256 constant pEval0 = 1412; // gsumw-1 (evMap[0])
    uint256 constant pEval1 = 1444; // gprodw-1 (evMap[1])
    uint256 constant pEval29 = 1476; // a[0] (evMap[29])
    uint256 constant pEval30 = 1508; // a[1] (evMap[30])
    uint256 constant pEval31 = 1540; // a[2] (evMap[31])
    uint256 constant pEval32 = 1572; // a[3] (evMap[32])
    uint256 constant pEval33 = 1604; // a[4] (evMap[33])
    uint256 constant pEval34 = 1636; // a[5] (evMap[34])
    uint256 constant pEval35 = 1668; // a[6] (evMap[35])
    uint256 constant pEval36 = 1700; // a[7] (evMap[36])
    uint256 constant pEval37 = 1732; // a[8] (evMap[37])
    uint256 constant pEval38 = 1764; // RANGE_MUL (evMap[38])
    uint256 constant pEval39 = 1796; // gsum (evMap[39])
    uint256 constant pEval40 = 1828; // im_cluster (evMap[40])
    uint256 constant pEval41 = 1860; // gprod (evMap[41])
    uint256 constant pEval42 = 1892; // im_low[0] (evMap[42])
    uint256 constant pEval44 = 1924; // a[0]w (evMap[44])
    uint256 constant pEval45 = 1956; // a[1]w (evMap[45])
    uint256 constant pEval46 = 1988; // a[2]w (evMap[46])
    uint256 constant pEval47 = 2020; // a[3]w (evMap[47])
    uint256 constant pEval48 = 2052; // a[4]w (evMap[48])
    uint256 constant pEval49 = 2084; // im_clusterw-1 (evMap[49])
    uint256 constant pEval50 = 2116; // im_low[0]w-1 (evMap[50])
    uint256 constant pInv = 2148; // inv = 1/(prod_i Z_T_i(y), i >= 1, times the Lagrange denominators)
    uint256 constant pInvZh = 2180; // invZh = 1/Z_H(xi)
    // The publics, the unnamed `uint256[]` (pubSignals), follow at 2212.

    // Memory data, at absolute addresses from 0x80 (solidity.rs, MEM_BASE)
    uint256 constant pCh2_0 = 128; // challenge 0 of stage 2
    uint256 constant pCh2_1 = 160; // challenge 1 of stage 2
    uint256 constant pStdVc = 192; // std_vc
    uint256 constant pXiSeed = 224; // xiSeed (std_xi)
    uint256 constant pAlpha = 256; // alpha_S
    uint256 constant pY = 288; // y
    uint256 constant pXi = 320; // xi = xiSeed^powerW
    uint256 constant pXiN = 352; // xi^N
    uint256 constant pZh = 384; // Z_H(xi) = xi^N - 1
    uint256 constant pZi0 = 416; // Zi of boundaries[0], EveryRow
    uint256 constant pQ = 448; // Q(xi)
    uint256 constant pYk1 = 480; // y^1
    uint256 constant pYk2 = 512; // y^2
    uint256 constant pYk3 = 544; // y^3
    uint256 constant pYk4 = 576; // y^4
    uint256 constant pYk13 = 608; // y^13
    uint256 constant pZ0 = 640; // xi*w^s of each offset s of k = 13, offsets [0]
    uint256 constant pZt0 = 672; // Z_T(y) of k = 13, offsets [0]
    uint256 constant pZ1 = 704; // xi*w^s of each offset s of k = 1, offsets [0, 1]
    uint256 constant pZt1 = 768; // Z_T(y) of k = 1, offsets [0, 1]
    uint256 constant pL1 = 800; // the CRT factor of each offset of k = 1, offsets [0, 1]
    uint256 constant pXiNeg1 = 864; // xi^-1
    uint256 constant pZ2 = 896; // xi*w^s of each offset s of k = 2, offsets [0, 1]
    uint256 constant pZt2 = 960; // Z_T(y) of k = 2, offsets [0, 1]
    uint256 constant pL2 = 992; // the CRT factor of each offset of k = 2, offsets [0, 1]
    uint256 constant pZ3 = 1056; // xi*w^s of each offset s of k = 3, offsets [0, 1]
    uint256 constant pZt3 = 1120; // Z_T(y) of k = 3, offsets [0, 1]
    uint256 constant pL3 = 1152; // the CRT factor of each offset of k = 3, offsets [0, 1]
    uint256 constant pZ4 = 1216; // xi*w^s of each offset s of k = 2, offsets [0]
    uint256 constant pZt4 = 1248; // Z_T(y) of k = 2, offsets [0]
    uint256 constant pZ5 = 1280; // xi*w^s of each offset s of k = 3, offsets [0]
    uint256 constant pZt5 = 1312; // Z_T(y) of k = 3, offsets [0]
    uint256 constant pZ6 = 1344; // xi*w^s of each offset s of k = 4, offsets [-1, 0]
    uint256 constant pZt6 = 1408; // Z_T(y) of k = 4, offsets [-1, 0]
    uint256 constant pL6 = 1440; // the CRT factor of each offset of k = 4, offsets [-1, 0]
    uint256 constant pZ7 = 1504; // xi*w^s of each offset s of k = 1, offsets [0]
    uint256 constant pZt7 = 1536; // Z_T(y) of k = 1, offsets [0]
    uint256 constant pInvZt1 = 1568; // Z_T(y) of f1, then its inverse
    uint256 constant pInvZt2 = 1600; // Z_T(y) of f2, then its inverse
    uint256 constant pInvZt3 = 1632; // Z_T(y) of f3, then its inverse
    uint256 constant pInvZt4 = 1664; // Z_T(y) of f4, then its inverse
    uint256 constant pInvZt5 = 1696; // Z_T(y) of f5, then its inverse
    uint256 constant pInvZt6 = 1728; // Z_T(y) of f6, then its inverse
    uint256 constant pInvZt7 = 1760; // Z_T(y) of f7, then its inverse
    uint256 constant pInvZt8 = 1792; // Z_T(y) of f8, then its inverse
    uint256 constant pR0 = 1824; // r_0(y)
    uint256 constant pR1 = 1856; // r_1(y)
    uint256 constant pR2 = 1888; // r_2(y)
    uint256 constant pR3 = 1920; // r_3(y)
    uint256 constant pR4 = 1952; // r_4(y)
    uint256 constant pR5 = 1984; // r_5(y)
    uint256 constant pR6 = 2016; // r_6(y)
    uint256 constant pR7 = 2048; // r_7(y)
    uint256 constant pR8 = 2080; // r_8(y)
    uint256 constant pF = 2112; // [F]_1
    uint256 constant pE = 2176; // [E]_1
    uint256 constant pJ = 2240; // [J]_1
    uint256 constant pTmp = 2304; // the stored values of the qVerifier
    uint256 constant lastMem = 2656;

    // `proof` has no name: the contract reads its words at the constant offsets above.
    function verifyProof(bytes32[69] calldata, uint256[1] calldata) public view returns (bool) {
        assembly {
            mstore(0x60, q)
            // The proof is rejected: verifyProof returns false.
            function fail() {
                mstore(0, 0)
                return(0, 0x20)
            }

            // elements.js, frFromObject: every scalar below r. bad is whether one is not, accumulated
            // over them without a branch each.
            function checkFields(bad) {
                if bad {
                    fail()
                }
            }

            // elements.js, g1FromObject: a point of G1, affine, its coordinates below the base
            // field's q, not the point at infinity (0, 0), and on y^2 = x^3 + 3, which is G1: its
            // cofactor is 1.
            function checkPointBelongsToBN128Curve(p) {
                let x := calldataload(p)
                let y := calldataload(add(p, 32))
                if iszero(and(lt(x, qf), lt(y, qf))) {
                    fail()
                }
                if iszero(or(x, y)) {
                    fail()
                }
                if iszero(eq(mulmod(y, y, qf), addmod(mulmod(x, mulmod(x, x, qf), qf), 3, qf))) {
                    fail()
                }
            }

            // transcript.js, addPolCommitment: a point the transcript absorbs has no coordinate
            // below 2^192.
            function checkAbsorbed(p) {
                if or(iszero(shr(192, calldataload(p))), iszero(shr(192, calldataload(add(p, 32))))) {
                    fail()
                }
            }

            // STEPS 1-3 (verify.js; proof.js, fromObjectProof and fromObjectPublics): the
            // commitments, W and W' in G1; the evaluations, the pieces of Q, inv, invZh (and the
            // auxiliary inverses) and the publics in Fr. The lengths are the vkey's, fixed by the
            // types of the arguments; the vkey is this contract's constants.
            function checkInput() {
                checkPointBelongsToBN128Curve(4)
                checkPointBelongsToBN128Curve(68)
                checkPointBelongsToBN128Curve(132)
                checkPointBelongsToBN128Curve(196)
                checkPointBelongsToBN128Curve(260)
                checkPointBelongsToBN128Curve(324)
                checkPointBelongsToBN128Curve(388)
                checkPointBelongsToBN128Curve(452)
                // Those the transcript absorbs: the commitments and W (challenges.js).
                checkAbsorbed(4)
                checkAbsorbed(68)
                checkAbsorbed(132)
                checkAbsorbed(196)
                checkAbsorbed(260)
                checkAbsorbed(324)
                checkAbsorbed(388)
                let r := mload(0x60)
                let bad := 0
                bad := or(bad, iszero(lt(calldataload(516), r)))
                bad := or(bad, iszero(lt(calldataload(548), r)))
                bad := or(bad, iszero(lt(calldataload(580), r)))
                bad := or(bad, iszero(lt(calldataload(612), r)))
                bad := or(bad, iszero(lt(calldataload(644), r)))
                bad := or(bad, iszero(lt(calldataload(676), r)))
                bad := or(bad, iszero(lt(calldataload(708), r)))
                bad := or(bad, iszero(lt(calldataload(740), r)))
                bad := or(bad, iszero(lt(calldataload(772), r)))
                bad := or(bad, iszero(lt(calldataload(804), r)))
                bad := or(bad, iszero(lt(calldataload(836), r)))
                bad := or(bad, iszero(lt(calldataload(868), r)))
                bad := or(bad, iszero(lt(calldataload(900), r)))
                bad := or(bad, iszero(lt(calldataload(932), r)))
                bad := or(bad, iszero(lt(calldataload(964), r)))
                bad := or(bad, iszero(lt(calldataload(996), r)))
                bad := or(bad, iszero(lt(calldataload(1028), r)))
                bad := or(bad, iszero(lt(calldataload(1060), r)))
                bad := or(bad, iszero(lt(calldataload(1092), r)))
                bad := or(bad, iszero(lt(calldataload(1124), r)))
                bad := or(bad, iszero(lt(calldataload(1156), r)))
                bad := or(bad, iszero(lt(calldataload(1188), r)))
                bad := or(bad, iszero(lt(calldataload(1220), r)))
                bad := or(bad, iszero(lt(calldataload(1252), r)))
                bad := or(bad, iszero(lt(calldataload(1284), r)))
                bad := or(bad, iszero(lt(calldataload(1316), r)))
                bad := or(bad, iszero(lt(calldataload(1348), r)))
                bad := or(bad, iszero(lt(calldataload(1380), r)))
                bad := or(bad, iszero(lt(calldataload(1412), r)))
                bad := or(bad, iszero(lt(calldataload(1444), r)))
                bad := or(bad, iszero(lt(calldataload(1476), r)))
                bad := or(bad, iszero(lt(calldataload(1508), r)))
                bad := or(bad, iszero(lt(calldataload(1540), r)))
                bad := or(bad, iszero(lt(calldataload(1572), r)))
                bad := or(bad, iszero(lt(calldataload(1604), r)))
                bad := or(bad, iszero(lt(calldataload(1636), r)))
                bad := or(bad, iszero(lt(calldataload(1668), r)))
                bad := or(bad, iszero(lt(calldataload(1700), r)))
                bad := or(bad, iszero(lt(calldataload(1732), r)))
                bad := or(bad, iszero(lt(calldataload(1764), r)))
                bad := or(bad, iszero(lt(calldataload(1796), r)))
                bad := or(bad, iszero(lt(calldataload(1828), r)))
                bad := or(bad, iszero(lt(calldataload(1860), r)))
                bad := or(bad, iszero(lt(calldataload(1892), r)))
                bad := or(bad, iszero(lt(calldataload(1924), r)))
                bad := or(bad, iszero(lt(calldataload(1956), r)))
                bad := or(bad, iszero(lt(calldataload(1988), r)))
                bad := or(bad, iszero(lt(calldataload(2020), r)))
                bad := or(bad, iszero(lt(calldataload(2052), r)))
                bad := or(bad, iszero(lt(calldataload(2084), r)))
                bad := or(bad, iszero(lt(calldataload(2116), r)))
                bad := or(bad, iszero(lt(calldataload(2148), r)))
                bad := or(bad, iszero(lt(calldataload(2180), r)))
                bad := or(bad, iszero(lt(calldataload(2212), r)))
                checkFields(bad)
            }

            // STEP 4: challenges.js, computeChallenges, the transcript. Its buffer, pT,
            // holds what is absorbed since the last squeeze, which is keccak256 of it mod r and
            // then the buffer's only value (transcript.js, squeeze).
            function computeChallenges(pPublic) {
                let pT := mload(0x40)
                let c
                // Step 1: digest mod r, the number of instances of the AIR (1), the publics
                mstore(pT, DIGEST)
                mstore(add(pT, 32), 1)
                calldatacopy(add(pT, 64), pPublic, 32)
                // Step 2, stage 1: the commitments of its f
                calldatacopy(add(pT, 96), pF3, 256)
                // challenge 0 of stage 2
                c := mod(keccak256(pT, 352), mload(0x60))
                mstore(pCh2_0, c)
                mstore(pT, c)
                // challenge 1 of stage 2
                c := mod(keccak256(pT, 32), mload(0x60))
                mstore(pCh2_1, c)
                mstore(pT, c)
                // Step 2, stage 2: the commitments of its f
                calldatacopy(add(pT, 32), pF7, 64)
                // Step 3: std_vc; the commitments of Q; xiSeed
                c := mod(keccak256(pT, 96), mload(0x60))
                mstore(pStdVc, c)
                mstore(pT, c)
                calldatacopy(add(pT, 32), pF8, 64)
                c := mod(keccak256(pT, 96), mload(0x60))
                mstore(pXiSeed, c)
                mstore(pT, c)
                // Step 4: the evaluations, in the order of the proof, and the pieces of Q
                calldatacopy(add(pT, 32), pEval2, 1632)
                c := mod(keccak256(pT, 1664), mload(0x60))
                mstore(pAlpha, c)
                mstore(pT, c)
                // Step 5: [W]_1; y
                calldatacopy(add(pT, 32), pW, 64)
                c := mod(keccak256(pT, 96), mload(0x60))
                mstore(pY, c)
                mstore(pT, c)
            }

            // b^e mod r.
            function powMod(b, e) -> result {
                result := 1
                for { } gt(e, 0) { e := shr(1, e) } {
                    if and(e, 1) {
                        result := mulmod(result, b, mload(0x60))
                    }
                    b := mulmod(b, b, mload(0x60))
                }
            }

            // STEP 5 (verify.js): xi = xiSeed^powerW, and Z_H(xi) = xi^N - 1 checked against the
            // proof's invZh.
            function computeZh() {
                let xi := powMod(mload(pXiSeed), 156)
                mstore(pXi, xi)
                let xin := xi
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                xin := mulmod(xin, xin, mload(0x60))
                mstore(pXiN, xin)
                let zh := addmod(xin, sub(mload(0x60), 1), mload(0x60))
                mstore(pZh, zh)
                if iszero(eq(mulmod(zh, calldataload(pInvZh), mload(0x60)), 1)) {
                    fail()
                }
            }

            // STEP 5: qverifier.js, computeZi, Zi(D) at xi for each boundary D:
            // 1/Z_H(xi) for everyRow, Z_H(xi)/Z_D(xi) for the others.
            function computeZi() {
                let xi := mload(pXi)
                let zh := mload(pZh)
                // boundaries[0], everyRow: 1/Z_H(xi): the proof's invZh
                mstore(pZi0, calldataload(pInvZh))
            }

            // STEP 5: verify.js, computeQ, and qverifier.js, executeCode: Q(xi) with the vkey's
            // qVerifier, the STARK's fold of the constraints, over the evaluations.
            function computeQ(pPublic) {
                mstore(add(pTmp, 0), addmod(mulmod(mload(pStdVc), mulmod(calldataload(pEval24), addmod(calldataload(pEval29), sub(mload(0x60), addmod(addmod(addmod(addmod(mulmod(calldataload(pEval16), calldataload(pEval30), mload(0x60)), mulmod(calldataload(pEval17), calldataload(pEval31), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval18), calldataload(pEval32), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval19), calldataload(pEval33), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval20), calldataload(pEval34), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval26), addmod(calldataload(pEval29), sub(mload(0x60), calldataload(pPublic)), mload(0x60)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 32), addmod(1, sub(mload(0x60), addmod(calldataload(pEval21), calldataload(pEval24), mload(0x60))), mload(0x60)))
                mstore(add(pTmp, 0), mulmod(mload(pStdVc), addmod(mulmod(mload(pStdVc), mload(add(pTmp, 0)), mload(0x60)), mulmod(mload(add(pTmp, 32)), addmod(addmod(addmod(addmod(mulmod(calldataload(pEval11), mulmod(calldataload(pEval29), calldataload(pEval30), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval12), calldataload(pEval29), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval13), calldataload(pEval30), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval14), calldataload(pEval31), mload(0x60)), mload(0x60)), calldataload(pEval15), mload(0x60)), mload(0x60)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 0), mulmod(mload(pStdVc), addmod(mload(add(pTmp, 0)), mulmod(mload(add(pTmp, 32)), addmod(addmod(addmod(addmod(mulmod(calldataload(pEval11), mulmod(calldataload(pEval32), calldataload(pEval33), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval12), calldataload(pEval32), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval13), calldataload(pEval33), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval14), calldataload(pEval34), mload(0x60)), mload(0x60)), calldataload(pEval15), mload(0x60)), mload(0x60)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 32), addmod(calldataload(pEval22), calldataload(pEval23), mload(0x60)))
                mstore(add(pTmp, 64), addmod(calldataload(pEval29), calldataload(pEval16), mload(0x60)))
                mstore(add(pTmp, 96), mulmod(mload(add(pTmp, 64)), mload(add(pTmp, 64)), mload(0x60)))
                mstore(add(pTmp, 64), mulmod(mload(add(pTmp, 32)), mulmod(mulmod(mload(add(pTmp, 96)), mload(add(pTmp, 96)), mload(0x60)), mload(add(pTmp, 64)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 96), addmod(calldataload(pEval30), calldataload(pEval17), mload(0x60)))
                mstore(add(pTmp, 128), mulmod(mload(add(pTmp, 96)), mload(add(pTmp, 96)), mload(0x60)))
                mstore(add(pTmp, 96), addmod(mulmod(calldataload(pEval22), mulmod(mulmod(mload(add(pTmp, 128)), mload(add(pTmp, 128)), mload(0x60)), mload(add(pTmp, 96)), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval23), mload(add(pTmp, 96)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 128), addmod(calldataload(pEval31), calldataload(pEval18), mload(0x60)))
                mstore(add(pTmp, 160), mulmod(mload(add(pTmp, 128)), mload(add(pTmp, 128)), mload(0x60)))
                mstore(add(pTmp, 128), addmod(mulmod(calldataload(pEval22), mulmod(mulmod(mload(add(pTmp, 160)), mload(add(pTmp, 160)), mload(0x60)), mload(add(pTmp, 128)), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval23), mload(add(pTmp, 128)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 160), addmod(calldataload(pEval32), calldataload(pEval19), mload(0x60)))
                mstore(add(pTmp, 192), mulmod(mload(add(pTmp, 160)), mload(add(pTmp, 160)), mload(0x60)))
                mstore(add(pTmp, 160), addmod(mulmod(calldataload(pEval22), mulmod(mulmod(mload(add(pTmp, 192)), mload(add(pTmp, 192)), mload(0x60)), mload(add(pTmp, 160)), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval23), mload(add(pTmp, 160)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 192), addmod(calldataload(pEval33), calldataload(pEval20), mload(0x60)))
                mstore(add(pTmp, 224), mulmod(mload(add(pTmp, 192)), mload(add(pTmp, 192)), mload(0x60)))
                mstore(add(pTmp, 192), addmod(mulmod(calldataload(pEval22), mulmod(mulmod(mload(add(pTmp, 224)), mload(add(pTmp, 224)), mload(0x60)), mload(add(pTmp, 192)), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval23), mload(add(pTmp, 192)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 0), addmod(mulmod(mload(pStdVc), addmod(mload(add(pTmp, 0)), addmod(addmod(addmod(addmod(mulmod(calldataload(pEval11), mulmod(calldataload(pEval35), calldataload(pEval36), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval12), calldataload(pEval35), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval13), calldataload(pEval36), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval14), calldataload(pEval37), mload(0x60)), mload(0x60)), calldataload(pEval15), mload(0x60)), mload(0x60)), mload(0x60)), addmod(mulmod(mload(add(pTmp, 32)), calldataload(pEval44), mload(0x60)), sub(mload(0x60), addmod(addmod(addmod(addmod(mulmod(16789463359527776692258765063233607350971630674230623383979223533600140787105, mload(add(pTmp, 64)), mload(0x60)), mulmod(17179611066821656668705197789232102741366879862607190942874777813024566441829, mload(add(pTmp, 96)), mload(0x60)), mload(0x60)), mulmod(18653277315487164762584377009009109585010878033606596417396490909822722930739, mload(add(pTmp, 128)), mload(0x60)), mload(0x60)), mulmod(7373070639853668650581790286343199505413793790160702463077019294817051722180, mload(add(pTmp, 160)), mload(0x60)), mload(0x60)), mulmod(4823864393442908763804841692709014014130031798360007432734996408628916373879, mload(add(pTmp, 192)), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 0), addmod(mulmod(mload(pStdVc), addmod(mulmod(mload(pStdVc), mload(add(pTmp, 0)), mload(0x60)), addmod(mulmod(mload(add(pTmp, 32)), calldataload(pEval45), mload(0x60)), sub(mload(0x60), addmod(addmod(addmod(addmod(mulmod(19196309854577132760746782449135315310664418272926255500908899397538686486585, mload(add(pTmp, 64)), mload(0x60)), mulmod(18123132816088485879885148351452823314623055244145916622592591084094232513914, mload(add(pTmp, 96)), mload(0x60)), mload(0x60)), mulmod(18436594886553181913092702411547018228276047601279727265790147051821171174455, mload(add(pTmp, 128)), mload(0x60)), mload(0x60)), mulmod(15167500404313194506503404655898040457721633218143681920692711693000769735187, mload(add(pTmp, 160)), mload(0x60)), mload(0x60)), mulmod(9437986152015460505719924283993842205604222075968464846270136901243896809793, mload(add(pTmp, 192)), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)), mload(0x60)), addmod(mulmod(mload(add(pTmp, 32)), calldataload(pEval46), mload(0x60)), sub(mload(0x60), addmod(addmod(addmod(addmod(mulmod(21445376105821232747280055223032050399373725161014449207033808524504027971613, mload(add(pTmp, 64)), mload(0x60)), mulmod(49684738714301073369749035791061182456037935161360748355432247732088942674, mload(add(pTmp, 96)), mload(0x60)), mload(0x60)), mulmod(9826409059947591908303145327284336313371973037536805760095514429930589897515, mload(add(pTmp, 128)), mload(0x60)), mload(0x60)), mulmod(8494798325496773219358794086647759478982958403252584257436898618394561204124, mload(add(pTmp, 160)), mload(0x60)), mload(0x60)), mulmod(21251937175072447337747316555423152807036003235223125066270735279039060889959, mload(add(pTmp, 192)), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 0), addmod(mulmod(mload(pStdVc), addmod(mulmod(mload(pStdVc), mload(add(pTmp, 0)), mload(0x60)), addmod(mulmod(mload(add(pTmp, 32)), calldataload(pEval47), mload(0x60)), sub(mload(0x60), addmod(addmod(addmod(addmod(mulmod(5539100337780919206842837176908516952801756637410959104376645017856664270896, mload(add(pTmp, 64)), mload(0x60)), mulmod(6297628909516159190915174165284309160976659474973668336571577778869958189934, mload(add(pTmp, 96)), mload(0x60)), mload(0x60)), mulmod(12792263637464508665199868777503118105486490400267592501708855807938962470650, mload(add(pTmp, 128)), mload(0x60)), mload(0x60)), mulmod(17254685306085558791725544672172906900581495686070720065168939143671412445514, mload(add(pTmp, 160)), mload(0x60)), mload(0x60)), mulmod(3590396502942934679818900672232030233017710909687947858184099000783280809247, mload(add(pTmp, 192)), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)), mload(0x60)), addmod(mulmod(mload(add(pTmp, 32)), calldataload(pEval48), mload(0x60)), sub(mload(0x60), addmod(addmod(addmod(addmod(mulmod(19055249881366445073616526879263250763682650596233071589085239500077496415637, mload(add(pTmp, 64)), mload(0x60)), mulmod(7367697936402141224946246030743627391716576575953707640061577218995381577033, mload(add(pTmp, 96)), mload(0x60)), mload(0x60)), mulmod(1322791522030759131093883057746095061798181102708855007233180025036972924046, mload(add(pTmp, 128)), mload(0x60)), mload(0x60)), mulmod(20456741074925985565499300081580917471340328842103779922028754640077047587707, mload(add(pTmp, 160)), mload(0x60)), mload(0x60)), mulmod(9059147312071680695674575245237100802111605600478121517359780850134328696420, mload(add(pTmp, 192)), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 32), addmod(addmod(mulmod(calldataload(pEval34), mload(pCh2_0), mload(0x60)), 2, mload(0x60)), mload(pCh2_1), mload(0x60)))
                mstore(add(pTmp, 64), addmod(addmod(mulmod(calldataload(pEval25), mload(pCh2_0), mload(0x60)), 2, mload(0x60)), mload(pCh2_1), mload(0x60)))
                mstore(add(pTmp, 96), addmod(0, sub(mload(0x60), calldataload(pEval24)), mload(0x60)))
                mstore(add(pTmp, 128), addmod(1, sub(mload(0x60), calldataload(pEval28)), mload(0x60)))
                mstore(add(pTmp, 160), addmod(addmod(mulmod(calldataload(pEval30), mload(pCh2_0), mload(0x60)), 2, mload(0x60)), mload(pCh2_1), mload(0x60)))
                mstore(add(pTmp, 192), addmod(addmod(mulmod(calldataload(pEval31), mload(pCh2_0), mload(0x60)), 2, mload(0x60)), mload(pCh2_1), mload(0x60)))
                mstore(add(pTmp, 224), mulmod(mload(add(pTmp, 160)), mload(add(pTmp, 192)), mload(0x60)))
                mstore(add(pTmp, 256), addmod(addmod(mulmod(calldataload(pEval32), mload(pCh2_0), mload(0x60)), 2, mload(0x60)), mload(pCh2_1), mload(0x60)))
                mstore(add(pTmp, 288), mulmod(mload(add(pTmp, 224)), mload(add(pTmp, 256)), mload(0x60)))
                mstore(add(pTmp, 320), addmod(addmod(mulmod(calldataload(pEval33), mload(pCh2_0), mload(0x60)), 2, mload(0x60)), mload(pCh2_1), mload(0x60)))
                mstore(add(pTmp, 0), mulmod(mload(pStdVc), addmod(mulmod(mload(pStdVc), addmod(mulmod(mload(pStdVc), mload(add(pTmp, 0)), mload(0x60)), addmod(mulmod(calldataload(pEval40), mulmod(mload(add(pTmp, 32)), mload(add(pTmp, 64)), mload(0x60)), mload(0x60)), sub(mload(0x60), addmod(mulmod(mload(add(pTmp, 96)), mload(add(pTmp, 64)), mload(0x60)), mulmod(calldataload(pEval38), mload(add(pTmp, 32)), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)), mload(0x60)), addmod(mulmod(addmod(addmod(calldataload(pEval39), sub(mload(0x60), mulmod(calldataload(pEval0), mload(add(pTmp, 128)), mload(0x60))), mload(0x60)), sub(mload(0x60), calldataload(pEval40)), mload(0x60)), mulmod(mload(add(pTmp, 288)), mload(add(pTmp, 320)), mload(0x60)), mload(0x60)), sub(mload(0x60), addmod(mulmod(addmod(mulmod(addmod(mulmod(mload(add(pTmp, 96)), mload(add(pTmp, 192)), mload(0x60)), mulmod(mload(add(pTmp, 96)), mload(add(pTmp, 160)), mload(0x60)), mload(0x60)), mload(add(pTmp, 256)), mload(0x60)), mulmod(mload(add(pTmp, 96)), mload(add(pTmp, 224)), mload(0x60)), mload(0x60)), mload(add(pTmp, 320)), mload(0x60)), mulmod(mload(add(pTmp, 96)), mload(add(pTmp, 288)), mload(0x60)), mload(0x60))), mload(0x60)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 32), mulmod(mulmod(mulmod(addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval27), mload(pCh2_0), mload(0x60)), calldataload(pEval29), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(mulmod(5266228460530200451425464971825753823072228272503274930591399474110020095489, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval30), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(mulmod(7105417016332174850410570896152637638969286250121046049601916147253836355616, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval31), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(mulmod(11368207234942670888835120453873516417666490693300823184588242808005266577922, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval32), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 64), mulmod(mulmod(mulmod(mulmod(addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval2), mload(pCh2_0), mload(0x60)), calldataload(pEval29), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval3), mload(pCh2_0), mload(0x60)), calldataload(pEval30), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval4), mload(pCh2_0), mload(0x60)), calldataload(pEval31), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval5), mload(pCh2_0), mload(0x60)), calldataload(pEval32), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval6), mload(pCh2_0), mload(0x60)), calldataload(pEval33), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 32), addmod(mulmod(calldataload(pEval42), mulmod(mload(add(pTmp, 32)), addmod(addmod(mulmod(addmod(mulmod(mulmod(20868252896871137417296149845131845111459623412721253026236963874583831508289, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval33), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), mload(0x60)), sub(mload(0x60), mulmod(mload(add(pTmp, 64)), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval7), mload(pCh2_0), mload(0x60)), calldataload(pEval34), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60))), mload(0x60)))
                mstore(add(pTmp, 64), mulmod(mulmod(mulmod(addmod(addmod(mulmod(addmod(mulmod(mulmod(228143782555411425321250818103251186713928635596850332649653733142161217259, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval34), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(mulmod(10945236620154748055396050216833787909156199273451639663503130598895656939410, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval35), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(mulmod(20116697486602678194958186545291394969653616150754282372500669671401371518655, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval36), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(mulmod(3183002806311292071170077895443612615705583737297126452770910814205281990567, calldataload(pEval27), mload(0x60)), mload(pCh2_0), mload(0x60)), calldataload(pEval37), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 96), mulmod(addmod(mulmod(calldataload(pEval1), mload(add(pTmp, 128)), mload(0x60)), calldataload(pEval28), mload(0x60)), mulmod(mulmod(mulmod(calldataload(pEval42), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval8), mload(pCh2_0), mload(0x60)), calldataload(pEval35), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval9), mload(pCh2_0), mload(0x60)), calldataload(pEval36), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), addmod(addmod(mulmod(addmod(mulmod(calldataload(pEval10), mload(pCh2_0), mload(0x60)), calldataload(pEval37), mload(0x60)), mload(pCh2_0), mload(0x60)), 1, mload(0x60)), mload(pCh2_1), mload(0x60)), mload(0x60)), mload(0x60)))
                mstore(add(pTmp, 0), addmod(mulmod(mload(pStdVc), addmod(mulmod(mload(pStdVc), addmod(mulmod(mload(pStdVc), addmod(mload(add(pTmp, 0)), mulmod(calldataload(pEval43), addmod(0, sub(mload(0x60), calldataload(pEval39)), mload(0x60)), mload(0x60)), mload(0x60)), mload(0x60)), mload(add(pTmp, 32)), mload(0x60)), mload(0x60)), addmod(mulmod(calldataload(pEval41), mload(add(pTmp, 64)), mload(0x60)), sub(mload(0x60), mload(add(pTmp, 96))), mload(0x60)), mload(0x60)), mload(0x60)), mulmod(calldataload(pEval43), addmod(1, sub(mload(0x60), calldataload(pEval41)), mload(0x60)), mload(0x60)), mload(0x60)))
                mstore(pQ, mulmod(mload(add(pTmp, 0)), mload(pZi0), mload(0x60)))
            }

            // STEP 6 (verify.js); shplonk.js, computeRoots: the roots T_i of every f_i are, for each
            // offset s, the k-th roots of z_s = xi·w_N^s; the verifier needs only the z_s and y^k
            // (computeInversions, computeR), never the roots.
            function computeZ() {
                let xiSeed := mload(pXiSeed)
                // shplonk.js, checkOpening: xiSeed is not zero.
                if iszero(xiSeed) {
                    fail()
                }
                let xi := mload(pXi)
                let y := mload(pY)
                mstore(pYk1, y)
                mstore(pYk2, powMod(y, 2))
                mstore(pYk3, powMod(y, 3))
                mstore(pYk4, powMod(y, 4))
                mstore(pYk13, powMod(y, 13))
                // k = 13, offsets [0]
                mstore(pZ0, xi)
                // k = 1, offsets [0, 1]
                mstore(pZ1, xi)
                mstore(add(pZ1, 32), mulmod(xi, 17220337697351015657950521176323262483320249231368149235373741788599650842711, mload(0x60)))
                // k = 2, offsets [0, 1]
                mstore(pZ2, xi)
                mstore(add(pZ2, 32), mulmod(xi, 17220337697351015657950521176323262483320249231368149235373741788599650842711, mload(0x60)))
                // k = 3, offsets [0, 1]
                mstore(pZ3, xi)
                mstore(add(pZ3, 32), mulmod(xi, 17220337697351015657950521176323262483320249231368149235373741788599650842711, mload(0x60)))
                // k = 2, offsets [0]
                mstore(pZ4, xi)
                // k = 3, offsets [0]
                mstore(pZ5, xi)
                // k = 4, offsets [-1, 0]
                mstore(pZ6, mulmod(xi, 7258560947846415542561780768613294257363507129322102188167496063542901903859, mload(0x60)))
                mstore(add(pZ6, 32), xi)
                // k = 1, offsets [0]
                mstore(pZ7, xi)
            }

            // shplonk.js, isValidInverse: inv·A·B = 1, with invB = inv·A.
            function checkInv(invB, b) {
                if iszero(eq(mulmod(invB, b, mload(0x60)), 1)) {
                    fail()
                }
            }

            // The inverses of the len values from pVals, given acc, the inverse of their product:
            // snarkjs's inverseArray without its check, which computeInversions makes.
            function batchInverse(pVals, len, acc) {
                let pAux := mload(0x40)
                let p := mload(pVals)
                mstore(pAux, p)
                for { let i := 1 } lt(i, len) { i := add(i, 1) } {
                    p := mulmod(p, mload(add(pVals, mul(i, 32))), mload(0x60))
                    mstore(add(pAux, mul(i, 32)), p)
                }
                for { let i := sub(len, 1) } gt(i, 0) { i := sub(i, 1) } {
                    let pV := add(pVals, mul(i, 32))
                    let v := mload(pV)
                    mstore(pV, mulmod(acc, mload(add(pAux, mul(sub(i, 1), 32))), mload(0x60)))
                    acc := mulmod(acc, v, mload(0x60))
                }
                mstore(pVals, acc)
            }

            // STEP 6 (verify.js): shplonk.js, computeZerofiers and computeInverseDenominators, and
            // isValidInverse. The proof's inv inverts A·B: A = prod_i Z_{T_i}(y), i ≥ 1, with
            // Z_T(y) = prod_s (y^k - z_s), and B the product of every f_i's Lagrange denominators,
            // which has the closed form G·xi^E·prod_i Z_{T_i}(y) (solidity.rs, Context::new): the check
            // inv·A·B = 1 is the JS's. Then 1/A = inv·B gives each 1/Z_{T_i}(y) and, for the sets of
            // several offsets, (1/B)·G·prod_i Z_{T_i}(y) = xi^(-E) gives their CRT factors.
            function computeInversions() {
                let d
                // k = 13, offsets [0]
                d := 1
                d := mulmod(d, addmod(mload(pYk13), sub(mload(0x60), mload(pZ0)), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt0, d)
                // k = 1, offsets [0, 1]
                d := 1
                d := mulmod(d, addmod(mload(pYk1), sub(mload(0x60), mload(pZ1)), mload(0x60)), mload(0x60))
                d := mulmod(d, addmod(mload(pYk1), sub(mload(0x60), mload(add(pZ1, 32))), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt1, d)
                // k = 2, offsets [0, 1]
                d := 1
                d := mulmod(d, addmod(mload(pYk2), sub(mload(0x60), mload(pZ2)), mload(0x60)), mload(0x60))
                d := mulmod(d, addmod(mload(pYk2), sub(mload(0x60), mload(add(pZ2, 32))), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt2, d)
                // k = 3, offsets [0, 1]
                d := 1
                d := mulmod(d, addmod(mload(pYk3), sub(mload(0x60), mload(pZ3)), mload(0x60)), mload(0x60))
                d := mulmod(d, addmod(mload(pYk3), sub(mload(0x60), mload(add(pZ3, 32))), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt3, d)
                // k = 2, offsets [0]
                d := 1
                d := mulmod(d, addmod(mload(pYk2), sub(mload(0x60), mload(pZ4)), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt4, d)
                // k = 3, offsets [0]
                d := 1
                d := mulmod(d, addmod(mload(pYk3), sub(mload(0x60), mload(pZ5)), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt5, d)
                // k = 4, offsets [-1, 0]
                d := 1
                d := mulmod(d, addmod(mload(pYk4), sub(mload(0x60), mload(pZ6)), mload(0x60)), mload(0x60))
                d := mulmod(d, addmod(mload(pYk4), sub(mload(0x60), mload(add(pZ6, 32))), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt6, d)
                // k = 1, offsets [0]
                d := 1
                d := mulmod(d, addmod(mload(pYk1), sub(mload(0x60), mload(pZ7)), mload(0x60)), mload(0x60))
                // shplonk.js, verifyOpening: y is not a root of an f_i (inv·A·B = 1 checks it too).
                if iszero(d) {
                    fail()
                }
                mstore(pZt7, d)
                let a := 1
                d := mload(pZt0)
                mstore(pInvZt1, d)
                a := mulmod(a, d, mload(0x60))
                d := mload(pZt1)
                mstore(pInvZt2, d)
                a := mulmod(a, d, mload(0x60))
                d := mload(pZt2)
                mstore(pInvZt3, d)
                a := mulmod(a, d, mload(0x60))
                d := mload(pZt3)
                mstore(pInvZt4, d)
                a := mulmod(a, d, mload(0x60))
                d := mload(pZt4)
                mstore(pInvZt5, d)
                a := mulmod(a, d, mload(0x60))
                d := mload(pZt5)
                mstore(pInvZt6, d)
                a := mulmod(a, d, mload(0x60))
                d := mload(pZt6)
                mstore(pInvZt7, d)
                a := mulmod(a, d, mload(0x60))
                d := mload(pZt7)
                mstore(pInvZt8, d)
                a := mulmod(a, d, mload(0x60))
                let zts := mulmod(a, mload(pZt0), mload(0x60))
                let b := mulmod(zts, mulmod(872127579632135716965470207166898052388577162142041400471193899370514963701, powMod(mload(pXi), 59), mload(0x60)), mload(0x60))
                let invB := mulmod(calldataload(pInv), a, mload(0x60))
                checkInv(invB, b)
                batchInverse(pInvZt1, 8, mulmod(calldataload(pInv), b, mload(0x60)))
                let xiNegE := mulmod(invB, mulmod(872127579632135716965470207166898052388577162142041400471193899370514963701, zts, mload(0x60)), mload(0x60))
                mstore(pXiNeg1, mulmod(xiNegE, powMod(mload(pXi), 58), mload(0x60)))
                // k = 1, offsets [0, 1]: L_s = prod_{s' != s} (y^k - z_s')/(z_s - z_s')
                d := mulmod(18891174137072410644159713240788227550940121292175075153801163539494952511361, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk1), sub(mload(0x60), mload(add(pZ1, 32))), mload(0x60)), mload(0x60))
                mstore(pL1, d)
                d := mulmod(2997068734766864578086692504469047537608243108240959189897040647080855984256, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk1), sub(mload(0x60), mload(pZ1)), mload(0x60)), mload(0x60))
                mstore(add(pL1, 32), d)
                // k = 2, offsets [0, 1]: L_s = prod_{s' != s} (y^k - z_s')/(z_s - z_s')
                d := mulmod(18891174137072410644159713240788227550940121292175075153801163539494952511361, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk2), sub(mload(0x60), mload(add(pZ2, 32))), mload(0x60)), mload(0x60))
                mstore(pL2, d)
                d := mulmod(2997068734766864578086692504469047537608243108240959189897040647080855984256, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk2), sub(mload(0x60), mload(pZ2)), mload(0x60)), mload(0x60))
                mstore(add(pL2, 32), d)
                // k = 3, offsets [0, 1]: L_s = prod_{s' != s} (y^k - z_s')/(z_s - z_s')
                d := mulmod(18891174137072410644159713240788227550940121292175075153801163539494952511361, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk3), sub(mload(0x60), mload(add(pZ3, 32))), mload(0x60)), mload(0x60))
                mstore(pL3, d)
                d := mulmod(2997068734766864578086692504469047537608243108240959189897040647080855984256, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk3), sub(mload(0x60), mload(pZ3)), mload(0x60)), mload(0x60))
                mstore(add(pL3, 32), d)
                // k = 4, offsets [-1, 0]: L_s = prod_{s' != s} (y^k - z_s')/(z_s - z_s')
                d := mulmod(18891174137072410644159713240788227550940121292175075153801163539494952511360, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk4), sub(mload(0x60), mload(add(pZ6, 32))), mload(0x60)), mload(0x60))
                mstore(pL6, d)
                d := mulmod(2997068734766864578086692504469047537608243108240959189897040647080855984257, mload(pXiNeg1), mload(0x60))
                d := mulmod(d, addmod(mload(pYk4), sub(mload(0x60), mload(pZ6)), mload(0x60)), mload(0x60))
                mstore(add(pL6, 32), d)
            }

            // STEP 7 (verify.js, openingEvaluations; shplonk.js, computeR): r_i(y), the polynomial of
            // degree < k·t that f_i is on its roots, at y. On the roots of an offset s, X^k = z_s and
            // f_i(X) = R_s(X) = sum_j p_j(xi·w^s)·X^j, of degree < k: with one offset r_i = R_s, and
            // with several the CRT, r_i = sum_s R_s·L_s. p_j(xi·w^s) are the proof's evaluations and,
            // for Q's f, Q(xi) computed or the proof's Q_i(xi) if Q is split.
            function computeR() {
                let y := mload(pY)
                let v
                // f0: stage 0, k = 13, offsets [0]
                v := calldataload(pEval15)
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval16), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval17), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval18), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval19), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval20), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval21), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval22), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval23), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval24), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval25), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval26), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval27), mload(0x60))
                mstore(pR0, v)
                // f1: stage 0, k = 13, offsets [0]
                v := calldataload(pEval2)
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval3), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval4), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval5), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval6), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval7), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval8), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval9), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval10), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval11), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval12), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval13), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval14), mload(0x60))
                mstore(pR1, v)
                // f2: stage 0, k = 1, offsets [0, 1]
                {
                    let acc := 0
                    v := calldataload(pEval28)
                    acc := addmod(acc, mulmod(v, mload(pL1), mload(0x60)), mload(0x60))
                    v := calldataload(pEval43)
                    acc := addmod(acc, mulmod(v, mload(add(pL1, 32)), mload(0x60)), mload(0x60))
                    mstore(pR2, acc)
                }
                // f3: stage 1, k = 2, offsets [0, 1]
                {
                    let acc := 0
                    v := calldataload(pEval32)
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval33), mload(0x60))
                    acc := addmod(acc, mulmod(v, mload(pL2), mload(0x60)), mload(0x60))
                    v := calldataload(pEval47)
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval48), mload(0x60))
                    acc := addmod(acc, mulmod(v, mload(add(pL2, 32)), mload(0x60)), mload(0x60))
                    mstore(pR3, acc)
                }
                // f4: stage 1, k = 3, offsets [0, 1]
                {
                    let acc := 0
                    v := calldataload(pEval29)
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval30), mload(0x60))
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval31), mload(0x60))
                    acc := addmod(acc, mulmod(v, mload(pL3), mload(0x60)), mload(0x60))
                    v := calldataload(pEval44)
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval45), mload(0x60))
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval46), mload(0x60))
                    acc := addmod(acc, mulmod(v, mload(add(pL3, 32)), mload(0x60)), mload(0x60))
                    mstore(pR4, acc)
                }
                // f5: stage 1, k = 2, offsets [0]
                v := calldataload(pEval37)
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval38), mload(0x60))
                mstore(pR5, v)
                // f6: stage 1, k = 3, offsets [0]
                v := calldataload(pEval34)
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval35), mload(0x60))
                v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval36), mload(0x60))
                mstore(pR6, v)
                // f7: stage 2, k = 4, offsets [-1, 0]
                {
                    let acc := 0
                    v := calldataload(pEval0)
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval1), mload(0x60))
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval49), mload(0x60))
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval50), mload(0x60))
                    acc := addmod(acc, mulmod(v, mload(pL6), mload(0x60)), mload(0x60))
                    v := calldataload(pEval39)
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval41), mload(0x60))
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval40), mload(0x60))
                    v := addmod(mulmod(v, y, mload(0x60)), calldataload(pEval42), mload(0x60))
                    acc := addmod(acc, mulmod(v, mload(add(pL6, 32)), mload(0x60)), mload(0x60))
                    mstore(pR7, acc)
                }
                // f8: stage 3, k = 1, offsets [0]
                v := mload(pQ)
                mstore(pR8, v)
            }

            // Whether a call to the precompile 0x06 or 0x07 succeeded and returned a point: 64 bytes.
            // snarkjs checks success only; on a chain where the precompile is missing, the call
            // succeeds and returns nothing.
            function checkPointResult(success) {
                if iszero(and(success, eq(returndatasize(), 64))) {
                    fail()
                }
            }

            // G1 function to accumulate a G1 value to an address
            function g1_acc(pR, pP) {
                let mIn := mload(0x40)
                mstore(mIn, mload(pR))
                mstore(add(mIn, 32), mload(add(pR, 32)))
                mstore(add(mIn, 64), mload(pP))
                mstore(add(mIn, 96), mload(add(pP, 32)))

                let success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                checkPointResult(success)
            }

            // G1 function to multiply a G1 value (in the calldata at pP) to value in an address
            function g1_mulAcc(pR, pP, s) {
                let success
                let mIn := mload(0x40)
                mstore(mIn, calldataload(pP))
                mstore(add(mIn, 32), calldataload(add(pP, 32)))
                mstore(add(mIn, 64), s)

                success := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)

                checkPointResult(success)

                mstore(add(mIn, 64), mload(pR))
                mstore(add(mIn, 96), mload(add(pR, 32)))

                success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                checkPointResult(success)
            }

            // G1 function to multiply a G1 value (x, y) to value in an address
            function g1_mulAccC(pR, x, y, s) {
                let success
                let mIn := mload(0x40)
                mstore(mIn, x)
                mstore(add(mIn, 32), y)
                mstore(add(mIn, 64), s)

                success := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)

                checkPointResult(success)

                mstore(add(mIn, 64), mload(pR))
                mstore(add(mIn, 96), mload(add(pR, 32)))

                success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                checkPointResult(success)
            }

            // G1 function to write s·(x, y) to an address
            function g1_mulSetC(pR, x, y, s) {
                let mIn := mload(0x40)
                mstore(mIn, x)
                mstore(add(mIn, 32), y)
                mstore(add(mIn, 64), s)

                let success := staticcall(sub(gas(), 2000), 7, mIn, 96, pR, 64)

                checkPointResult(success)
            }

            // STEP 7: shplonk.js, computeQuotients, computeF, computeE and computeJ:
            // q_0 = Z_{T_0}(y), q_i = alpha^i·Z_{T_0}(y)/Z_{T_i}(y), F = [f_0] + sum_i q_i·[f_i],
            // E = (r_0(y) + sum_i q_i·r_i(y))·[1]_1, J = q_0·[W]; the fixed [f_i] are the vkey's.
            function computeFEJ() {
                let zt0 := mload(pZt0)
                let alpha := mload(pAlpha)
                let alphaPow := 1
                let quotient
                let e := mload(pR0)
                mstore(pF, f0x)
                mstore(add(pF, 32), f0y)
                // f1
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt1), mload(0x60)), mload(0x60))
                g1_mulAccC(pF, f1x, f1y, quotient)
                e := addmod(e, mulmod(quotient, mload(pR1), mload(0x60)), mload(0x60))
                // f2
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt2), mload(0x60)), mload(0x60))
                g1_mulAccC(pF, f2x, f2y, quotient)
                e := addmod(e, mulmod(quotient, mload(pR2), mload(0x60)), mload(0x60))
                // f3
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt3), mload(0x60)), mload(0x60))
                g1_mulAcc(pF, pF3, quotient)
                e := addmod(e, mulmod(quotient, mload(pR3), mload(0x60)), mload(0x60))
                // f4
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt4), mload(0x60)), mload(0x60))
                g1_mulAcc(pF, pF4, quotient)
                e := addmod(e, mulmod(quotient, mload(pR4), mload(0x60)), mload(0x60))
                // f5
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt5), mload(0x60)), mload(0x60))
                g1_mulAcc(pF, pF5, quotient)
                e := addmod(e, mulmod(quotient, mload(pR5), mload(0x60)), mload(0x60))
                // f6
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt6), mload(0x60)), mload(0x60))
                g1_mulAcc(pF, pF6, quotient)
                e := addmod(e, mulmod(quotient, mload(pR6), mload(0x60)), mload(0x60))
                // f7
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt7), mload(0x60)), mload(0x60))
                g1_mulAcc(pF, pF7, quotient)
                e := addmod(e, mulmod(quotient, mload(pR7), mload(0x60)), mload(0x60))
                // f8
                alphaPow := mulmod(alphaPow, alpha, mload(0x60))
                quotient := mulmod(alphaPow, mulmod(zt0, mload(pInvZt8), mload(0x60)), mload(0x60))
                g1_mulAcc(pF, pF8, quotient)
                e := addmod(e, mulmod(quotient, mload(pR8), mload(0x60)), mload(0x60))

                // Compute group-encoded batch evaluation [E]_1
                g1_mulSetC(pE, G1x, G1y, e)

                // Compute the full difference [J]_1
                g1_mulSetC(pJ, calldataload(pW), calldataload(add(pW, 32)), zt0)
            }

            // STEP 7: shplonk.js, isValidPairing: e([F]_1 - [E]_1 - [J]_1 + y·[W']_1, [1]_2) ==
            // e([W']_1, [x]_2)
            function checkPairing() -> isOk {
                let mIn := mload(0x40)

                // First pairing value
                // Compute -E
                mstore(add(pE, 32), mod(sub(qf, mload(add(pE, 32))), qf))
                // Compute -J
                mstore(add(pJ, 32), mod(sub(qf, mload(add(pJ, 32))), qf))
                // F = F - E - J + y·W'
                g1_acc(pF, pE)
                g1_acc(pF, pJ)
                g1_mulAcc(pF, pWp, mload(pY))

                mstore(mIn, mload(pF))
                mstore(add(mIn, 32), mload(add(pF, 32)))

                // Second pairing value
                mstore(add(mIn, 64), G2x2)
                mstore(add(mIn, 96), G2x1)
                mstore(add(mIn, 128), G2y2)
                mstore(add(mIn, 160), G2y1)

                // Third pairing value
                // Compute -W'
                mstore(add(mIn, 192), calldataload(pWp))
                let s := calldataload(add(pWp, 32))
                s := mod(sub(qf, s), qf)
                mstore(add(mIn, 224), s)

                // Fourth pairing value
                mstore(add(mIn, 256), X2x2)
                mstore(add(mIn, 288), X2x1)
                mstore(add(mIn, 320), X2y2)
                mstore(add(mIn, 352), X2y1)

                let success := staticcall(sub(gas(), 2000), 8, mIn, 384, mIn, 0x20)

                // The precompile's answer, 32 bytes, is 1 (snarkjs takes any non-zero word).
                isOk := and(and(success, eq(returndatasize(), 0x20)), eq(mload(mIn), 1))
            }

            mstore(0x40, lastMem)

            // STEPS 1-3: the proof and the publics are well-formed
            checkInput()

            // STEP 4: the challenges
            computeChallenges(2212)

            // STEP 5: Z_H(xi), the Zi and Q(xi)
            computeZh()
            computeZi()
            computeQ(2212)

            // STEP 6: the z_s, and inv
            computeZ()
            computeInversions()

            // STEP 7: the SHPLONK opening, with a pairing
            computeR()
            computeFEJ()
            let isValid := checkPairing()

            mstore(0, isValid)
            return(0, 0x20)
        }
    }
}
