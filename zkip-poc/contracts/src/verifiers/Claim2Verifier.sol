
// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec
pragma solidity ^0.8.27;

interface IVerifier {
    function verify(bytes calldata _proof, bytes32[] calldata _publicInputs) external view returns (bool);
}



uint256 constant NUMBER_OF_SUBRELATIONS = 29;
uint256 constant BATCHED_RELATION_PARTIAL_LENGTH = 9;
uint256 constant ZK_BATCHED_RELATION_PARTIAL_LENGTH = 9;
uint256 constant NUMBER_OF_ENTITIES = 42;
uint256 constant NUMBER_UNSHIFTED = 37;
uint256 constant NUMBER_TO_BE_SHIFTED = 5;
uint256 constant PAIRING_POINTS_SIZE = 8;

uint256 constant VK_HASH = 0x1d7139db775576b97066ca05f179a60d6db731cbfecd21f26f166c53a9655143;
uint256 constant CIRCUIT_SIZE = 4194304;
uint256 constant LOG_N = 22;
uint256 constant NUMBER_PUBLIC_INPUTS = 24;
uint256 constant REAL_NUMBER_PUBLIC_INPUTS = 16;
uint256 constant PUBLIC_INPUTS_OFFSET = 5; // NUM_DISABLED_ROWS_IN_SUMCHECK + NUM_ZERO_ROWS = 4 + 1

contract HonkVerifier is IVerifier {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SLAB ALLOCATION                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /**
     * We manually manage memory within this optimised implementation.
     * Memory is loaded into a large slab with the following layout:
     *
     * HIGH MEMORY (persistent, non-overlapping regions from 0x1000 upward):
     *
     *   VK Data (Verification Key G1 commitment points)
     *   Proof: Pairing point limbs (8 field elements)
     *   Proof: Gemini masking poly commitment (1 G1 point) [ZK]
     *   Proof: Witness commitments (W_L..Z_PERM, 8 G1 points)
     *   Proof: Libra concat commitment + Libra sum (1 G1 + 1 Fr) [ZK]
     *   Proof: Sumcheck univariates (LOG_N rounds x 9 coefficients)
     *   Proof: Sumcheck evaluations (42 entity evals incl. masking) [ZK]
     *   Proof: Libra evaluation (1 Fr) [ZK]
     *   Proof: Libra grand product + quotient (2 G1 points) [ZK]
     *   Proof: Gemini fold commitments (LOG_N-1 G1 points)
     *   Proof: Gemini A evaluations (LOG_N field elements)
     *   Proof: Libra poly evaluations (4 Fr values) [ZK]
     *   Proof: Shplonk Q + KZG quotient (2 G1 points)
     *   Challenges (eta..sum_u, alpha[0..26], gate + libra + sum_u)
     *              [Libra challenge at 0x3EC0 between gate and sum_u challenges]
     *   Subrelation evaluations (28 slots, used during sumcheck)
     *   Subrelation intermediates (7 slots: round target, pow, AUX)
     *   Powers of evaluation challenge (LOG_N slots)
     *   Batch scalars (69 slots, for MSM - depending on LOG_N)
     *   LATER_SCRATCH_SPACE (batch inversion products marker)
     *   Temporary space (ephemeral computation)
     *
     * LOW MEMORY / SCRATCH SPACE (two temporally disjoint overlapping phases):
     *
     *   Phase 1 (Sumcheck -- barycentric evaluation, domain size 9 for ZK):
     *     Barycentric Lagrange denominators (9 domain points)
     *     Barycentric denominator inverses (LOG_N x 9 = 135 slots)
     *
     *   Phase 2 (Shplemini -- after sumcheck completes, reuses same addresses):
     *     Inverted Gemini denominator 0 (1 slot, = POS_INVERTED_DENOM_0)
     *     Batched eval, constant term accumulator, pos/neg inv denom
     *     Fold-pos evaluations (LOG_N slots)
     *     Libra subgroup denominator (1 slot, separately inverted) [ZK]
     *
     *   Phase 2 (Shplemini inversions at 0x6800+ to avoid overlap with barycentric):
     *     GEMINI_R_INV (1/gemini_r)
     *     Inverted challenge^pow - u (LOG_N slots)
     *     Pos inverted denominators (LOG_N slots)
     *     Neg inverted denominators (LOG_N slots)
     *
     *   Scratch aliases (0x00-0x40): CHALL_POW/SUMCHECK_U/GEMINI_A during sumcheck;
     *   SS_POS_INV_DENOM/SS_NEG_INV_DENOM/SS_GEMINI_EVALS during shplemini.
     *   MSM stage reuses 0x00-0xA0 for ACCUMULATOR, G1_LOCATION, SCALAR.
     *
     * ZK-ONLY EXTENDED MEMORY (checkEvalsConsistency): - low degree IPA
     *   challengePolyLagrange
     *   denominators
     *   batch inversion products
     */

    // {{ SECTION_START MEMORY_LAYOUT }}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                           VK INDICIES                                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant VK_CIRCUIT_SIZE_LOC = 0x1000;
uint256 internal constant VK_NUM_PUBLIC_INPUTS_LOC = 0x1020;
uint256 internal constant VK_PUB_INPUTS_OFFSET_LOC = 0x1040;
uint256 internal constant Q_M_X_LOC = 0x1060;
uint256 internal constant Q_M_Y_LOC = 0x1080;
uint256 internal constant Q_L_X_LOC = 0x10a0;
uint256 internal constant Q_L_Y_LOC = 0x10c0;
uint256 internal constant Q_R_X_LOC = 0x10e0;
uint256 internal constant Q_R_Y_LOC = 0x1100;
uint256 internal constant Q_O_X_LOC = 0x1120;
uint256 internal constant Q_O_Y_LOC = 0x1140;
uint256 internal constant Q_4_X_LOC = 0x1160;
uint256 internal constant Q_4_Y_LOC = 0x1180;
uint256 internal constant Q_C_X_LOC = 0x11a0;
uint256 internal constant Q_C_Y_LOC = 0x11c0;
uint256 internal constant Q_ARITH_X_LOC = 0x11e0;
uint256 internal constant Q_ARITH_Y_LOC = 0x1200;
uint256 internal constant SIGMA_1_X_LOC = 0x1220;
uint256 internal constant SIGMA_1_Y_LOC = 0x1240;
uint256 internal constant SIGMA_2_X_LOC = 0x1260;
uint256 internal constant SIGMA_2_Y_LOC = 0x1280;
uint256 internal constant SIGMA_3_X_LOC = 0x12a0;
uint256 internal constant SIGMA_3_Y_LOC = 0x12c0;
uint256 internal constant SIGMA_4_X_LOC = 0x12e0;
uint256 internal constant SIGMA_4_Y_LOC = 0x1300;
uint256 internal constant ID_1_X_LOC = 0x1320;
uint256 internal constant ID_1_Y_LOC = 0x1340;
uint256 internal constant ID_2_X_LOC = 0x1360;
uint256 internal constant ID_2_Y_LOC = 0x1380;
uint256 internal constant ID_3_X_LOC = 0x13a0;
uint256 internal constant ID_3_Y_LOC = 0x13c0;
uint256 internal constant ID_4_X_LOC = 0x13e0;
uint256 internal constant ID_4_Y_LOC = 0x1400;
uint256 internal constant LAGRANGE_FIRST_X_LOC = 0x1420;
uint256 internal constant LAGRANGE_FIRST_Y_LOC = 0x1440;
uint256 internal constant LAGRANGE_LAST_X_LOC = 0x1460;
uint256 internal constant LAGRANGE_LAST_Y_LOC = 0x1480;
uint256 internal constant Q_LOOKUP_X_LOC = 0x14a0;
uint256 internal constant Q_LOOKUP_Y_LOC = 0x14c0;
uint256 internal constant TABLE_1_X_LOC = 0x14e0;
uint256 internal constant TABLE_1_Y_LOC = 0x1500;
uint256 internal constant TABLE_2_X_LOC = 0x1520;
uint256 internal constant TABLE_2_Y_LOC = 0x1540;
uint256 internal constant TABLE_3_X_LOC = 0x1560;
uint256 internal constant TABLE_3_Y_LOC = 0x1580;
uint256 internal constant TABLE_4_X_LOC = 0x15a0;
uint256 internal constant TABLE_4_Y_LOC = 0x15c0;
uint256 internal constant Q_DELTA_RANGE_X_LOC = 0x15e0;
uint256 internal constant Q_DELTA_RANGE_Y_LOC = 0x1600;
uint256 internal constant Q_ELLIPTIC_X_LOC = 0x1620;
uint256 internal constant Q_ELLIPTIC_Y_LOC = 0x1640;
uint256 internal constant Q_MEMORY_X_LOC = 0x1660;
uint256 internal constant Q_MEMORY_Y_LOC = 0x1680;
uint256 internal constant Q_NNF_X_LOC = 0x16a0;
uint256 internal constant Q_NNF_Y_LOC = 0x16c0;
uint256 internal constant Q_POSEIDON_2_EXTERNAL_X_LOC = 0x16e0;
uint256 internal constant Q_POSEIDON_2_EXTERNAL_Y_LOC = 0x1700;
uint256 internal constant Q_POSEIDON_2_INTERNAL_X_LOC = 0x1720;
uint256 internal constant Q_POSEIDON_2_INTERNAL_Y_LOC = 0x1740;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                          PROOF INDICIES                                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant PAIRING_POINT_0_X_0_LOC = 0x1760;
uint256 internal constant PAIRING_POINT_0_X_1_LOC = 0x1780;
uint256 internal constant PAIRING_POINT_0_Y_0_LOC = 0x17a0;
uint256 internal constant PAIRING_POINT_0_Y_1_LOC = 0x17c0;
uint256 internal constant PAIRING_POINT_1_X_0_LOC = 0x17e0;
uint256 internal constant PAIRING_POINT_1_X_1_LOC = 0x1800;
uint256 internal constant PAIRING_POINT_1_Y_0_LOC = 0x1820;
uint256 internal constant PAIRING_POINT_1_Y_1_LOC = 0x1840;
uint256 internal constant GEMINI_MASKING_POLY_X_LOC = 0x1860;
uint256 internal constant GEMINI_MASKING_POLY_Y_LOC = 0x1880;
uint256 internal constant W_L_X_LOC = 0x18a0;
uint256 internal constant W_L_Y_LOC = 0x18c0;
uint256 internal constant W_R_X_LOC = 0x18e0;
uint256 internal constant W_R_Y_LOC = 0x1900;
uint256 internal constant W_O_X_LOC = 0x1920;
uint256 internal constant W_O_Y_LOC = 0x1940;
uint256 internal constant LOOKUP_READ_COUNTS_X_LOC = 0x1960;
uint256 internal constant LOOKUP_READ_COUNTS_Y_LOC = 0x1980;
uint256 internal constant LOOKUP_READ_TAGS_X_LOC = 0x19a0;
uint256 internal constant LOOKUP_READ_TAGS_Y_LOC = 0x19c0;
uint256 internal constant W_4_X_LOC = 0x19e0;
uint256 internal constant W_4_Y_LOC = 0x1a00;
uint256 internal constant LOOKUP_INVERSES_X_LOC = 0x1a20;
uint256 internal constant LOOKUP_INVERSES_Y_LOC = 0x1a40;
uint256 internal constant Z_PERM_X_LOC = 0x1a60;
uint256 internal constant Z_PERM_Y_LOC = 0x1a80;
uint256 internal constant LIBRA_CONCAT_X_LOC = 0x1aa0;
uint256 internal constant LIBRA_CONCAT_Y_LOC = 0x1ac0;
uint256 internal constant LIBRA_SUM_LOC = 0x1ae0;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                              PROOF INDICIES - SUMCHECK UNIVARIATES                               */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant SUMCHECK_UNIVARIATE_0_0_LOC = 0x1b00;
uint256 internal constant SUMCHECK_UNIVARIATE_0_1_LOC = 0x1b20;
uint256 internal constant SUMCHECK_UNIVARIATE_0_2_LOC = 0x1b40;
uint256 internal constant SUMCHECK_UNIVARIATE_0_3_LOC = 0x1b60;
uint256 internal constant SUMCHECK_UNIVARIATE_0_4_LOC = 0x1b80;
uint256 internal constant SUMCHECK_UNIVARIATE_0_5_LOC = 0x1ba0;
uint256 internal constant SUMCHECK_UNIVARIATE_0_6_LOC = 0x1bc0;
uint256 internal constant SUMCHECK_UNIVARIATE_0_7_LOC = 0x1be0;
uint256 internal constant SUMCHECK_UNIVARIATE_0_8_LOC = 0x1c00;
uint256 internal constant SUMCHECK_UNIVARIATE_1_0_LOC = 0x1c20;
uint256 internal constant SUMCHECK_UNIVARIATE_1_1_LOC = 0x1c40;
uint256 internal constant SUMCHECK_UNIVARIATE_1_2_LOC = 0x1c60;
uint256 internal constant SUMCHECK_UNIVARIATE_1_3_LOC = 0x1c80;
uint256 internal constant SUMCHECK_UNIVARIATE_1_4_LOC = 0x1ca0;
uint256 internal constant SUMCHECK_UNIVARIATE_1_5_LOC = 0x1cc0;
uint256 internal constant SUMCHECK_UNIVARIATE_1_6_LOC = 0x1ce0;
uint256 internal constant SUMCHECK_UNIVARIATE_1_7_LOC = 0x1d00;
uint256 internal constant SUMCHECK_UNIVARIATE_1_8_LOC = 0x1d20;
uint256 internal constant SUMCHECK_UNIVARIATE_2_0_LOC = 0x1d40;
uint256 internal constant SUMCHECK_UNIVARIATE_2_1_LOC = 0x1d60;
uint256 internal constant SUMCHECK_UNIVARIATE_2_2_LOC = 0x1d80;
uint256 internal constant SUMCHECK_UNIVARIATE_2_3_LOC = 0x1da0;
uint256 internal constant SUMCHECK_UNIVARIATE_2_4_LOC = 0x1dc0;
uint256 internal constant SUMCHECK_UNIVARIATE_2_5_LOC = 0x1de0;
uint256 internal constant SUMCHECK_UNIVARIATE_2_6_LOC = 0x1e00;
uint256 internal constant SUMCHECK_UNIVARIATE_2_7_LOC = 0x1e20;
uint256 internal constant SUMCHECK_UNIVARIATE_2_8_LOC = 0x1e40;
uint256 internal constant SUMCHECK_UNIVARIATE_3_0_LOC = 0x1e60;
uint256 internal constant SUMCHECK_UNIVARIATE_3_1_LOC = 0x1e80;
uint256 internal constant SUMCHECK_UNIVARIATE_3_2_LOC = 0x1ea0;
uint256 internal constant SUMCHECK_UNIVARIATE_3_3_LOC = 0x1ec0;
uint256 internal constant SUMCHECK_UNIVARIATE_3_4_LOC = 0x1ee0;
uint256 internal constant SUMCHECK_UNIVARIATE_3_5_LOC = 0x1f00;
uint256 internal constant SUMCHECK_UNIVARIATE_3_6_LOC = 0x1f20;
uint256 internal constant SUMCHECK_UNIVARIATE_3_7_LOC = 0x1f40;
uint256 internal constant SUMCHECK_UNIVARIATE_3_8_LOC = 0x1f60;
uint256 internal constant SUMCHECK_UNIVARIATE_4_0_LOC = 0x1f80;
uint256 internal constant SUMCHECK_UNIVARIATE_4_1_LOC = 0x1fa0;
uint256 internal constant SUMCHECK_UNIVARIATE_4_2_LOC = 0x1fc0;
uint256 internal constant SUMCHECK_UNIVARIATE_4_3_LOC = 0x1fe0;
uint256 internal constant SUMCHECK_UNIVARIATE_4_4_LOC = 0x2000;
uint256 internal constant SUMCHECK_UNIVARIATE_4_5_LOC = 0x2020;
uint256 internal constant SUMCHECK_UNIVARIATE_4_6_LOC = 0x2040;
uint256 internal constant SUMCHECK_UNIVARIATE_4_7_LOC = 0x2060;
uint256 internal constant SUMCHECK_UNIVARIATE_4_8_LOC = 0x2080;
uint256 internal constant SUMCHECK_UNIVARIATE_5_0_LOC = 0x20a0;
uint256 internal constant SUMCHECK_UNIVARIATE_5_1_LOC = 0x20c0;
uint256 internal constant SUMCHECK_UNIVARIATE_5_2_LOC = 0x20e0;
uint256 internal constant SUMCHECK_UNIVARIATE_5_3_LOC = 0x2100;
uint256 internal constant SUMCHECK_UNIVARIATE_5_4_LOC = 0x2120;
uint256 internal constant SUMCHECK_UNIVARIATE_5_5_LOC = 0x2140;
uint256 internal constant SUMCHECK_UNIVARIATE_5_6_LOC = 0x2160;
uint256 internal constant SUMCHECK_UNIVARIATE_5_7_LOC = 0x2180;
uint256 internal constant SUMCHECK_UNIVARIATE_5_8_LOC = 0x21a0;
uint256 internal constant SUMCHECK_UNIVARIATE_6_0_LOC = 0x21c0;
uint256 internal constant SUMCHECK_UNIVARIATE_6_1_LOC = 0x21e0;
uint256 internal constant SUMCHECK_UNIVARIATE_6_2_LOC = 0x2200;
uint256 internal constant SUMCHECK_UNIVARIATE_6_3_LOC = 0x2220;
uint256 internal constant SUMCHECK_UNIVARIATE_6_4_LOC = 0x2240;
uint256 internal constant SUMCHECK_UNIVARIATE_6_5_LOC = 0x2260;
uint256 internal constant SUMCHECK_UNIVARIATE_6_6_LOC = 0x2280;
uint256 internal constant SUMCHECK_UNIVARIATE_6_7_LOC = 0x22a0;
uint256 internal constant SUMCHECK_UNIVARIATE_6_8_LOC = 0x22c0;
uint256 internal constant SUMCHECK_UNIVARIATE_7_0_LOC = 0x22e0;
uint256 internal constant SUMCHECK_UNIVARIATE_7_1_LOC = 0x2300;
uint256 internal constant SUMCHECK_UNIVARIATE_7_2_LOC = 0x2320;
uint256 internal constant SUMCHECK_UNIVARIATE_7_3_LOC = 0x2340;
uint256 internal constant SUMCHECK_UNIVARIATE_7_4_LOC = 0x2360;
uint256 internal constant SUMCHECK_UNIVARIATE_7_5_LOC = 0x2380;
uint256 internal constant SUMCHECK_UNIVARIATE_7_6_LOC = 0x23a0;
uint256 internal constant SUMCHECK_UNIVARIATE_7_7_LOC = 0x23c0;
uint256 internal constant SUMCHECK_UNIVARIATE_7_8_LOC = 0x23e0;
uint256 internal constant SUMCHECK_UNIVARIATE_8_0_LOC = 0x2400;
uint256 internal constant SUMCHECK_UNIVARIATE_8_1_LOC = 0x2420;
uint256 internal constant SUMCHECK_UNIVARIATE_8_2_LOC = 0x2440;
uint256 internal constant SUMCHECK_UNIVARIATE_8_3_LOC = 0x2460;
uint256 internal constant SUMCHECK_UNIVARIATE_8_4_LOC = 0x2480;
uint256 internal constant SUMCHECK_UNIVARIATE_8_5_LOC = 0x24a0;
uint256 internal constant SUMCHECK_UNIVARIATE_8_6_LOC = 0x24c0;
uint256 internal constant SUMCHECK_UNIVARIATE_8_7_LOC = 0x24e0;
uint256 internal constant SUMCHECK_UNIVARIATE_8_8_LOC = 0x2500;
uint256 internal constant SUMCHECK_UNIVARIATE_9_0_LOC = 0x2520;
uint256 internal constant SUMCHECK_UNIVARIATE_9_1_LOC = 0x2540;
uint256 internal constant SUMCHECK_UNIVARIATE_9_2_LOC = 0x2560;
uint256 internal constant SUMCHECK_UNIVARIATE_9_3_LOC = 0x2580;
uint256 internal constant SUMCHECK_UNIVARIATE_9_4_LOC = 0x25a0;
uint256 internal constant SUMCHECK_UNIVARIATE_9_5_LOC = 0x25c0;
uint256 internal constant SUMCHECK_UNIVARIATE_9_6_LOC = 0x25e0;
uint256 internal constant SUMCHECK_UNIVARIATE_9_7_LOC = 0x2600;
uint256 internal constant SUMCHECK_UNIVARIATE_9_8_LOC = 0x2620;
uint256 internal constant SUMCHECK_UNIVARIATE_10_0_LOC = 0x2640;
uint256 internal constant SUMCHECK_UNIVARIATE_10_1_LOC = 0x2660;
uint256 internal constant SUMCHECK_UNIVARIATE_10_2_LOC = 0x2680;
uint256 internal constant SUMCHECK_UNIVARIATE_10_3_LOC = 0x26a0;
uint256 internal constant SUMCHECK_UNIVARIATE_10_4_LOC = 0x26c0;
uint256 internal constant SUMCHECK_UNIVARIATE_10_5_LOC = 0x26e0;
uint256 internal constant SUMCHECK_UNIVARIATE_10_6_LOC = 0x2700;
uint256 internal constant SUMCHECK_UNIVARIATE_10_7_LOC = 0x2720;
uint256 internal constant SUMCHECK_UNIVARIATE_10_8_LOC = 0x2740;
uint256 internal constant SUMCHECK_UNIVARIATE_11_0_LOC = 0x2760;
uint256 internal constant SUMCHECK_UNIVARIATE_11_1_LOC = 0x2780;
uint256 internal constant SUMCHECK_UNIVARIATE_11_2_LOC = 0x27a0;
uint256 internal constant SUMCHECK_UNIVARIATE_11_3_LOC = 0x27c0;
uint256 internal constant SUMCHECK_UNIVARIATE_11_4_LOC = 0x27e0;
uint256 internal constant SUMCHECK_UNIVARIATE_11_5_LOC = 0x2800;
uint256 internal constant SUMCHECK_UNIVARIATE_11_6_LOC = 0x2820;
uint256 internal constant SUMCHECK_UNIVARIATE_11_7_LOC = 0x2840;
uint256 internal constant SUMCHECK_UNIVARIATE_11_8_LOC = 0x2860;
uint256 internal constant SUMCHECK_UNIVARIATE_12_0_LOC = 0x2880;
uint256 internal constant SUMCHECK_UNIVARIATE_12_1_LOC = 0x28a0;
uint256 internal constant SUMCHECK_UNIVARIATE_12_2_LOC = 0x28c0;
uint256 internal constant SUMCHECK_UNIVARIATE_12_3_LOC = 0x28e0;
uint256 internal constant SUMCHECK_UNIVARIATE_12_4_LOC = 0x2900;
uint256 internal constant SUMCHECK_UNIVARIATE_12_5_LOC = 0x2920;
uint256 internal constant SUMCHECK_UNIVARIATE_12_6_LOC = 0x2940;
uint256 internal constant SUMCHECK_UNIVARIATE_12_7_LOC = 0x2960;
uint256 internal constant SUMCHECK_UNIVARIATE_12_8_LOC = 0x2980;
uint256 internal constant SUMCHECK_UNIVARIATE_13_0_LOC = 0x29a0;
uint256 internal constant SUMCHECK_UNIVARIATE_13_1_LOC = 0x29c0;
uint256 internal constant SUMCHECK_UNIVARIATE_13_2_LOC = 0x29e0;
uint256 internal constant SUMCHECK_UNIVARIATE_13_3_LOC = 0x2a00;
uint256 internal constant SUMCHECK_UNIVARIATE_13_4_LOC = 0x2a20;
uint256 internal constant SUMCHECK_UNIVARIATE_13_5_LOC = 0x2a40;
uint256 internal constant SUMCHECK_UNIVARIATE_13_6_LOC = 0x2a60;
uint256 internal constant SUMCHECK_UNIVARIATE_13_7_LOC = 0x2a80;
uint256 internal constant SUMCHECK_UNIVARIATE_13_8_LOC = 0x2aa0;
uint256 internal constant SUMCHECK_UNIVARIATE_14_0_LOC = 0x2ac0;
uint256 internal constant SUMCHECK_UNIVARIATE_14_1_LOC = 0x2ae0;
uint256 internal constant SUMCHECK_UNIVARIATE_14_2_LOC = 0x2b00;
uint256 internal constant SUMCHECK_UNIVARIATE_14_3_LOC = 0x2b20;
uint256 internal constant SUMCHECK_UNIVARIATE_14_4_LOC = 0x2b40;
uint256 internal constant SUMCHECK_UNIVARIATE_14_5_LOC = 0x2b60;
uint256 internal constant SUMCHECK_UNIVARIATE_14_6_LOC = 0x2b80;
uint256 internal constant SUMCHECK_UNIVARIATE_14_7_LOC = 0x2ba0;
uint256 internal constant SUMCHECK_UNIVARIATE_14_8_LOC = 0x2bc0;
uint256 internal constant SUMCHECK_UNIVARIATE_15_0_LOC = 0x2be0;
uint256 internal constant SUMCHECK_UNIVARIATE_15_1_LOC = 0x2c00;
uint256 internal constant SUMCHECK_UNIVARIATE_15_2_LOC = 0x2c20;
uint256 internal constant SUMCHECK_UNIVARIATE_15_3_LOC = 0x2c40;
uint256 internal constant SUMCHECK_UNIVARIATE_15_4_LOC = 0x2c60;
uint256 internal constant SUMCHECK_UNIVARIATE_15_5_LOC = 0x2c80;
uint256 internal constant SUMCHECK_UNIVARIATE_15_6_LOC = 0x2ca0;
uint256 internal constant SUMCHECK_UNIVARIATE_15_7_LOC = 0x2cc0;
uint256 internal constant SUMCHECK_UNIVARIATE_15_8_LOC = 0x2ce0;
uint256 internal constant SUMCHECK_UNIVARIATE_16_0_LOC = 0x2d00;
uint256 internal constant SUMCHECK_UNIVARIATE_16_1_LOC = 0x2d20;
uint256 internal constant SUMCHECK_UNIVARIATE_16_2_LOC = 0x2d40;
uint256 internal constant SUMCHECK_UNIVARIATE_16_3_LOC = 0x2d60;
uint256 internal constant SUMCHECK_UNIVARIATE_16_4_LOC = 0x2d80;
uint256 internal constant SUMCHECK_UNIVARIATE_16_5_LOC = 0x2da0;
uint256 internal constant SUMCHECK_UNIVARIATE_16_6_LOC = 0x2dc0;
uint256 internal constant SUMCHECK_UNIVARIATE_16_7_LOC = 0x2de0;
uint256 internal constant SUMCHECK_UNIVARIATE_16_8_LOC = 0x2e00;
uint256 internal constant SUMCHECK_UNIVARIATE_17_0_LOC = 0x2e20;
uint256 internal constant SUMCHECK_UNIVARIATE_17_1_LOC = 0x2e40;
uint256 internal constant SUMCHECK_UNIVARIATE_17_2_LOC = 0x2e60;
uint256 internal constant SUMCHECK_UNIVARIATE_17_3_LOC = 0x2e80;
uint256 internal constant SUMCHECK_UNIVARIATE_17_4_LOC = 0x2ea0;
uint256 internal constant SUMCHECK_UNIVARIATE_17_5_LOC = 0x2ec0;
uint256 internal constant SUMCHECK_UNIVARIATE_17_6_LOC = 0x2ee0;
uint256 internal constant SUMCHECK_UNIVARIATE_17_7_LOC = 0x2f00;
uint256 internal constant SUMCHECK_UNIVARIATE_17_8_LOC = 0x2f20;
uint256 internal constant SUMCHECK_UNIVARIATE_18_0_LOC = 0x2f40;
uint256 internal constant SUMCHECK_UNIVARIATE_18_1_LOC = 0x2f60;
uint256 internal constant SUMCHECK_UNIVARIATE_18_2_LOC = 0x2f80;
uint256 internal constant SUMCHECK_UNIVARIATE_18_3_LOC = 0x2fa0;
uint256 internal constant SUMCHECK_UNIVARIATE_18_4_LOC = 0x2fc0;
uint256 internal constant SUMCHECK_UNIVARIATE_18_5_LOC = 0x2fe0;
uint256 internal constant SUMCHECK_UNIVARIATE_18_6_LOC = 0x3000;
uint256 internal constant SUMCHECK_UNIVARIATE_18_7_LOC = 0x3020;
uint256 internal constant SUMCHECK_UNIVARIATE_18_8_LOC = 0x3040;
uint256 internal constant SUMCHECK_UNIVARIATE_19_0_LOC = 0x3060;
uint256 internal constant SUMCHECK_UNIVARIATE_19_1_LOC = 0x3080;
uint256 internal constant SUMCHECK_UNIVARIATE_19_2_LOC = 0x30a0;
uint256 internal constant SUMCHECK_UNIVARIATE_19_3_LOC = 0x30c0;
uint256 internal constant SUMCHECK_UNIVARIATE_19_4_LOC = 0x30e0;
uint256 internal constant SUMCHECK_UNIVARIATE_19_5_LOC = 0x3100;
uint256 internal constant SUMCHECK_UNIVARIATE_19_6_LOC = 0x3120;
uint256 internal constant SUMCHECK_UNIVARIATE_19_7_LOC = 0x3140;
uint256 internal constant SUMCHECK_UNIVARIATE_19_8_LOC = 0x3160;
uint256 internal constant SUMCHECK_UNIVARIATE_20_0_LOC = 0x3180;
uint256 internal constant SUMCHECK_UNIVARIATE_20_1_LOC = 0x31a0;
uint256 internal constant SUMCHECK_UNIVARIATE_20_2_LOC = 0x31c0;
uint256 internal constant SUMCHECK_UNIVARIATE_20_3_LOC = 0x31e0;
uint256 internal constant SUMCHECK_UNIVARIATE_20_4_LOC = 0x3200;
uint256 internal constant SUMCHECK_UNIVARIATE_20_5_LOC = 0x3220;
uint256 internal constant SUMCHECK_UNIVARIATE_20_6_LOC = 0x3240;
uint256 internal constant SUMCHECK_UNIVARIATE_20_7_LOC = 0x3260;
uint256 internal constant SUMCHECK_UNIVARIATE_20_8_LOC = 0x3280;
uint256 internal constant SUMCHECK_UNIVARIATE_21_0_LOC = 0x32a0;
uint256 internal constant SUMCHECK_UNIVARIATE_21_1_LOC = 0x32c0;
uint256 internal constant SUMCHECK_UNIVARIATE_21_2_LOC = 0x32e0;
uint256 internal constant SUMCHECK_UNIVARIATE_21_3_LOC = 0x3300;
uint256 internal constant SUMCHECK_UNIVARIATE_21_4_LOC = 0x3320;
uint256 internal constant SUMCHECK_UNIVARIATE_21_5_LOC = 0x3340;
uint256 internal constant SUMCHECK_UNIVARIATE_21_6_LOC = 0x3360;
uint256 internal constant SUMCHECK_UNIVARIATE_21_7_LOC = 0x3380;
uint256 internal constant SUMCHECK_UNIVARIATE_21_8_LOC = 0x33a0;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                              PROOF INDICIES - SUMCHECK EVALUATIONS                               */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant GEMINI_MASKING_EVAL_LOC = 0x33c0;
uint256 internal constant SIGMA1_EVAL_LOC = 0x33e0;
uint256 internal constant SIGMA2_EVAL_LOC = 0x3400;
uint256 internal constant SIGMA3_EVAL_LOC = 0x3420;
uint256 internal constant SIGMA4_EVAL_LOC = 0x3440;
uint256 internal constant ID1_EVAL_LOC = 0x3460;
uint256 internal constant ID2_EVAL_LOC = 0x3480;
uint256 internal constant ID3_EVAL_LOC = 0x34a0;
uint256 internal constant ID4_EVAL_LOC = 0x34c0;
uint256 internal constant LAGRANGE_FIRST_EVAL_LOC = 0x34e0;
uint256 internal constant LAGRANGE_LAST_EVAL_LOC = 0x3500;
uint256 internal constant QLOOKUP_EVAL_LOC = 0x3520;
uint256 internal constant TABLE1_EVAL_LOC = 0x3540;
uint256 internal constant TABLE2_EVAL_LOC = 0x3560;
uint256 internal constant TABLE3_EVAL_LOC = 0x3580;
uint256 internal constant TABLE4_EVAL_LOC = 0x35a0;
uint256 internal constant QM_EVAL_LOC = 0x35c0;
uint256 internal constant QR_EVAL_LOC = 0x35e0;
uint256 internal constant QO_EVAL_LOC = 0x3600;
uint256 internal constant QC_EVAL_LOC = 0x3620;
uint256 internal constant QL_EVAL_LOC = 0x3640;
uint256 internal constant Q4_EVAL_LOC = 0x3660;
uint256 internal constant QARITH_EVAL_LOC = 0x3680;
uint256 internal constant QRANGE_EVAL_LOC = 0x36a0;
uint256 internal constant QELLIPTIC_EVAL_LOC = 0x36c0;
uint256 internal constant QMEMORY_EVAL_LOC = 0x36e0;
uint256 internal constant QNNF_EVAL_LOC = 0x3700;
uint256 internal constant QPOSEIDON2_EXTERNAL_EVAL_LOC = 0x3720;
uint256 internal constant QPOSEIDON2_INTERNAL_EVAL_LOC = 0x3740;
uint256 internal constant W1_EVAL_LOC = 0x3760;
uint256 internal constant W2_EVAL_LOC = 0x3780;
uint256 internal constant W3_EVAL_LOC = 0x37a0;
uint256 internal constant W4_EVAL_LOC = 0x37c0;
uint256 internal constant Z_PERM_EVAL_LOC = 0x37e0;
uint256 internal constant LOOKUP_INVERSES_EVAL_LOC = 0x3800;
uint256 internal constant LOOKUP_READ_COUNTS_EVAL_LOC = 0x3820;
uint256 internal constant LOOKUP_READ_TAGS_EVAL_LOC = 0x3840;
uint256 internal constant W1_SHIFT_EVAL_LOC = 0x3860;
uint256 internal constant W2_SHIFT_EVAL_LOC = 0x3880;
uint256 internal constant W3_SHIFT_EVAL_LOC = 0x38a0;
uint256 internal constant W4_SHIFT_EVAL_LOC = 0x38c0;
uint256 internal constant Z_PERM_SHIFT_EVAL_LOC = 0x38e0;
uint256 internal constant LIBRA_EVALUATION_LOC = 0x3900;
uint256 internal constant LIBRA_GRAND_PRODUCT_X_LOC = 0x3920;
uint256 internal constant LIBRA_GRAND_PRODUCT_Y_LOC = 0x3940;
uint256 internal constant LIBRA_QUOTIENT_X_LOC = 0x3960;
uint256 internal constant LIBRA_QUOTIENT_Y_LOC = 0x3980;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                              PROOF INDICIES - GEMINI FOLDING COMMS                               */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant GEMINI_FOLD_UNIVARIATE_0_X_LOC = 0x39a0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_0_Y_LOC = 0x39c0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_1_X_LOC = 0x39e0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_1_Y_LOC = 0x3a00;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_2_X_LOC = 0x3a20;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_2_Y_LOC = 0x3a40;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_3_X_LOC = 0x3a60;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_3_Y_LOC = 0x3a80;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_4_X_LOC = 0x3aa0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_4_Y_LOC = 0x3ac0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_5_X_LOC = 0x3ae0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_5_Y_LOC = 0x3b00;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_6_X_LOC = 0x3b20;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_6_Y_LOC = 0x3b40;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_7_X_LOC = 0x3b60;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_7_Y_LOC = 0x3b80;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_8_X_LOC = 0x3ba0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_8_Y_LOC = 0x3bc0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_9_X_LOC = 0x3be0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_9_Y_LOC = 0x3c00;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_10_X_LOC = 0x3c20;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_10_Y_LOC = 0x3c40;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_11_X_LOC = 0x3c60;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_11_Y_LOC = 0x3c80;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_12_X_LOC = 0x3ca0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_12_Y_LOC = 0x3cc0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_13_X_LOC = 0x3ce0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_13_Y_LOC = 0x3d00;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_14_X_LOC = 0x3d20;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_14_Y_LOC = 0x3d40;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_15_X_LOC = 0x3d60;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_15_Y_LOC = 0x3d80;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_16_X_LOC = 0x3da0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_16_Y_LOC = 0x3dc0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_17_X_LOC = 0x3de0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_17_Y_LOC = 0x3e00;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_18_X_LOC = 0x3e20;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_18_Y_LOC = 0x3e40;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_19_X_LOC = 0x3e60;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_19_Y_LOC = 0x3e80;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_20_X_LOC = 0x3ea0;
uint256 internal constant GEMINI_FOLD_UNIVARIATE_20_Y_LOC = 0x3ec0;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           PROOF INDICIES - GEMINI FOLDING EVALUATIONS                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant GEMINI_A_EVAL_0 = 0x3ee0;
uint256 internal constant GEMINI_A_EVAL_1 = 0x3f00;
uint256 internal constant GEMINI_A_EVAL_2 = 0x3f20;
uint256 internal constant GEMINI_A_EVAL_3 = 0x3f40;
uint256 internal constant GEMINI_A_EVAL_4 = 0x3f60;
uint256 internal constant GEMINI_A_EVAL_5 = 0x3f80;
uint256 internal constant GEMINI_A_EVAL_6 = 0x3fa0;
uint256 internal constant GEMINI_A_EVAL_7 = 0x3fc0;
uint256 internal constant GEMINI_A_EVAL_8 = 0x3fe0;
uint256 internal constant GEMINI_A_EVAL_9 = 0x4000;
uint256 internal constant GEMINI_A_EVAL_10 = 0x4020;
uint256 internal constant GEMINI_A_EVAL_11 = 0x4040;
uint256 internal constant GEMINI_A_EVAL_12 = 0x4060;
uint256 internal constant GEMINI_A_EVAL_13 = 0x4080;
uint256 internal constant GEMINI_A_EVAL_14 = 0x40a0;
uint256 internal constant GEMINI_A_EVAL_15 = 0x40c0;
uint256 internal constant GEMINI_A_EVAL_16 = 0x40e0;
uint256 internal constant GEMINI_A_EVAL_17 = 0x4100;
uint256 internal constant GEMINI_A_EVAL_18 = 0x4120;
uint256 internal constant GEMINI_A_EVAL_19 = 0x4140;
uint256 internal constant GEMINI_A_EVAL_20 = 0x4160;
uint256 internal constant GEMINI_A_EVAL_21 = 0x4180;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                             PROOF INDICIES - LIBRA POLY EVALUATIONS                              */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant LIBRA_POLY_EVAL_0_LOC = 0x41a0;
uint256 internal constant LIBRA_POLY_EVAL_1_LOC = 0x41c0;
uint256 internal constant LIBRA_POLY_EVAL_2_LOC = 0x41e0;
uint256 internal constant LIBRA_POLY_EVAL_3_LOC = 0x4200;
uint256 internal constant SHPLONK_Q_X_LOC = 0x4220;
uint256 internal constant SHPLONK_Q_Y_LOC = 0x4240;
uint256 internal constant KZG_QUOTIENT_X_LOC = 0x4260;
uint256 internal constant KZG_QUOTIENT_Y_LOC = 0x4280;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                    PROOF INDICIES - COMPLETE                                     */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                            CHALLENGES                                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant ETA_CHALLENGE = 0x42a0;
uint256 internal constant ETA_TWO_CHALLENGE = 0x42c0;
uint256 internal constant ETA_THREE_CHALLENGE = 0x42e0;
uint256 internal constant BETA_CHALLENGE = 0x4300;
uint256 internal constant GAMMA_CHALLENGE = 0x4320;
uint256 internal constant RHO_CHALLENGE = 0x4340;
uint256 internal constant GEMINI_R_CHALLENGE = 0x4360;
uint256 internal constant SHPLONK_NU_CHALLENGE = 0x4380;
uint256 internal constant SHPLONK_Z_CHALLENGE = 0x43a0;
uint256 internal constant PUBLIC_INPUTS_DELTA_NUMERATOR_CHALLENGE = 0x43c0;
uint256 internal constant PUBLIC_INPUTS_DELTA_DENOMINATOR_CHALLENGE = 0x43e0;
uint256 internal constant ALPHA_CHALLENGE_0 = 0x4400;
uint256 internal constant ALPHA_CHALLENGE_1 = 0x4420;
uint256 internal constant ALPHA_CHALLENGE_2 = 0x4440;
uint256 internal constant ALPHA_CHALLENGE_3 = 0x4460;
uint256 internal constant ALPHA_CHALLENGE_4 = 0x4480;
uint256 internal constant ALPHA_CHALLENGE_5 = 0x44a0;
uint256 internal constant ALPHA_CHALLENGE_6 = 0x44c0;
uint256 internal constant ALPHA_CHALLENGE_7 = 0x44e0;
uint256 internal constant ALPHA_CHALLENGE_8 = 0x4500;
uint256 internal constant ALPHA_CHALLENGE_9 = 0x4520;
uint256 internal constant ALPHA_CHALLENGE_10 = 0x4540;
uint256 internal constant ALPHA_CHALLENGE_11 = 0x4560;
uint256 internal constant ALPHA_CHALLENGE_12 = 0x4580;
uint256 internal constant ALPHA_CHALLENGE_13 = 0x45a0;
uint256 internal constant ALPHA_CHALLENGE_14 = 0x45c0;
uint256 internal constant ALPHA_CHALLENGE_15 = 0x45e0;
uint256 internal constant ALPHA_CHALLENGE_16 = 0x4600;
uint256 internal constant ALPHA_CHALLENGE_17 = 0x4620;
uint256 internal constant ALPHA_CHALLENGE_18 = 0x4640;
uint256 internal constant ALPHA_CHALLENGE_19 = 0x4660;
uint256 internal constant ALPHA_CHALLENGE_20 = 0x4680;
uint256 internal constant ALPHA_CHALLENGE_21 = 0x46a0;
uint256 internal constant ALPHA_CHALLENGE_22 = 0x46c0;
uint256 internal constant ALPHA_CHALLENGE_23 = 0x46e0;
uint256 internal constant ALPHA_CHALLENGE_24 = 0x4700;
uint256 internal constant ALPHA_CHALLENGE_25 = 0x4720;
uint256 internal constant ALPHA_CHALLENGE_26 = 0x4740;
uint256 internal constant ALPHA_CHALLENGE_27 = 0x4760;
uint256 internal constant GATE_CHALLENGE_0 = 0x4780;
uint256 internal constant GATE_CHALLENGE_1 = 0x47a0;
uint256 internal constant GATE_CHALLENGE_2 = 0x47c0;
uint256 internal constant GATE_CHALLENGE_3 = 0x47e0;
uint256 internal constant GATE_CHALLENGE_4 = 0x4800;
uint256 internal constant GATE_CHALLENGE_5 = 0x4820;
uint256 internal constant GATE_CHALLENGE_6 = 0x4840;
uint256 internal constant GATE_CHALLENGE_7 = 0x4860;
uint256 internal constant GATE_CHALLENGE_8 = 0x4880;
uint256 internal constant GATE_CHALLENGE_9 = 0x48a0;
uint256 internal constant GATE_CHALLENGE_10 = 0x48c0;
uint256 internal constant GATE_CHALLENGE_11 = 0x48e0;
uint256 internal constant GATE_CHALLENGE_12 = 0x4900;
uint256 internal constant GATE_CHALLENGE_13 = 0x4920;
uint256 internal constant GATE_CHALLENGE_14 = 0x4940;
uint256 internal constant GATE_CHALLENGE_15 = 0x4960;
uint256 internal constant GATE_CHALLENGE_16 = 0x4980;
uint256 internal constant GATE_CHALLENGE_17 = 0x49a0;
uint256 internal constant GATE_CHALLENGE_18 = 0x49c0;
uint256 internal constant GATE_CHALLENGE_19 = 0x49e0;
uint256 internal constant GATE_CHALLENGE_20 = 0x4a00;
uint256 internal constant GATE_CHALLENGE_21 = 0x4a20;
uint256 internal constant LIBRA_CHALLENGE = 0x4a40;
uint256 internal constant SUM_U_CHALLENGE_0 = 0x4a60;
uint256 internal constant SUM_U_CHALLENGE_1 = 0x4a80;
uint256 internal constant SUM_U_CHALLENGE_2 = 0x4aa0;
uint256 internal constant SUM_U_CHALLENGE_3 = 0x4ac0;
uint256 internal constant SUM_U_CHALLENGE_4 = 0x4ae0;
uint256 internal constant SUM_U_CHALLENGE_5 = 0x4b00;
uint256 internal constant SUM_U_CHALLENGE_6 = 0x4b20;
uint256 internal constant SUM_U_CHALLENGE_7 = 0x4b40;
uint256 internal constant SUM_U_CHALLENGE_8 = 0x4b60;
uint256 internal constant SUM_U_CHALLENGE_9 = 0x4b80;
uint256 internal constant SUM_U_CHALLENGE_10 = 0x4ba0;
uint256 internal constant SUM_U_CHALLENGE_11 = 0x4bc0;
uint256 internal constant SUM_U_CHALLENGE_12 = 0x4be0;
uint256 internal constant SUM_U_CHALLENGE_13 = 0x4c00;
uint256 internal constant SUM_U_CHALLENGE_14 = 0x4c20;
uint256 internal constant SUM_U_CHALLENGE_15 = 0x4c40;
uint256 internal constant SUM_U_CHALLENGE_16 = 0x4c60;
uint256 internal constant SUM_U_CHALLENGE_17 = 0x4c80;
uint256 internal constant SUM_U_CHALLENGE_18 = 0x4ca0;
uint256 internal constant SUM_U_CHALLENGE_19 = 0x4cc0;
uint256 internal constant SUM_U_CHALLENGE_20 = 0x4ce0;
uint256 internal constant SUM_U_CHALLENGE_21 = 0x4d00;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                      CHALLENGES - COMPLETE                                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                    SUMCHECK - RUNTIME MEMORY                                     */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                             SUMCHECK - RUNTIME MEMORY - BARYCENTRIC                              */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_0_LOC = 0x4d20;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_1_LOC = 0x4d40;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_2_LOC = 0x4d60;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_3_LOC = 0x4d80;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_4_LOC = 0x4da0;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_5_LOC = 0x4dc0;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_6_LOC = 0x4de0;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_7_LOC = 0x4e00;
uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_8_LOC = 0x4e20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_0_LOC = 0x4e40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_1_LOC = 0x4e60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_2_LOC = 0x4e80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_3_LOC = 0x4ea0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_4_LOC = 0x4ec0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_5_LOC = 0x4ee0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_6_LOC = 0x4f00;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_7_LOC = 0x4f20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_0_8_LOC = 0x4f40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_0_LOC = 0x4f60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_1_LOC = 0x4f80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_2_LOC = 0x4fa0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_3_LOC = 0x4fc0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_4_LOC = 0x4fe0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_5_LOC = 0x5000;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_6_LOC = 0x5020;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_7_LOC = 0x5040;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_1_8_LOC = 0x5060;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_0_LOC = 0x5080;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_1_LOC = 0x50a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_2_LOC = 0x50c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_3_LOC = 0x50e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_4_LOC = 0x5100;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_5_LOC = 0x5120;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_6_LOC = 0x5140;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_7_LOC = 0x5160;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_2_8_LOC = 0x5180;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_0_LOC = 0x51a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_1_LOC = 0x51c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_2_LOC = 0x51e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_3_LOC = 0x5200;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_4_LOC = 0x5220;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_5_LOC = 0x5240;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_6_LOC = 0x5260;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_7_LOC = 0x5280;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_3_8_LOC = 0x52a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_0_LOC = 0x52c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_1_LOC = 0x52e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_2_LOC = 0x5300;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_3_LOC = 0x5320;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_4_LOC = 0x5340;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_5_LOC = 0x5360;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_6_LOC = 0x5380;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_7_LOC = 0x53a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_4_8_LOC = 0x53c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_0_LOC = 0x53e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_1_LOC = 0x5400;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_2_LOC = 0x5420;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_3_LOC = 0x5440;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_4_LOC = 0x5460;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_5_LOC = 0x5480;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_6_LOC = 0x54a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_7_LOC = 0x54c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_5_8_LOC = 0x54e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_0_LOC = 0x5500;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_1_LOC = 0x5520;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_2_LOC = 0x5540;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_3_LOC = 0x5560;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_4_LOC = 0x5580;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_5_LOC = 0x55a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_6_LOC = 0x55c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_7_LOC = 0x55e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_6_8_LOC = 0x5600;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_0_LOC = 0x5620;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_1_LOC = 0x5640;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_2_LOC = 0x5660;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_3_LOC = 0x5680;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_4_LOC = 0x56a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_5_LOC = 0x56c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_6_LOC = 0x56e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_7_LOC = 0x5700;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_7_8_LOC = 0x5720;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_0_LOC = 0x5740;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_1_LOC = 0x5760;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_2_LOC = 0x5780;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_3_LOC = 0x57a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_4_LOC = 0x57c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_5_LOC = 0x57e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_6_LOC = 0x5800;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_7_LOC = 0x5820;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_8_8_LOC = 0x5840;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_0_LOC = 0x5860;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_1_LOC = 0x5880;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_2_LOC = 0x58a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_3_LOC = 0x58c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_4_LOC = 0x58e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_5_LOC = 0x5900;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_6_LOC = 0x5920;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_7_LOC = 0x5940;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_9_8_LOC = 0x5960;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_0_LOC = 0x5980;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_1_LOC = 0x59a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_2_LOC = 0x59c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_3_LOC = 0x59e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_4_LOC = 0x5a00;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_5_LOC = 0x5a20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_6_LOC = 0x5a40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_7_LOC = 0x5a60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_10_8_LOC = 0x5a80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_0_LOC = 0x5aa0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_1_LOC = 0x5ac0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_2_LOC = 0x5ae0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_3_LOC = 0x5b00;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_4_LOC = 0x5b20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_5_LOC = 0x5b40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_6_LOC = 0x5b60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_7_LOC = 0x5b80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_11_8_LOC = 0x5ba0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_0_LOC = 0x5bc0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_1_LOC = 0x5be0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_2_LOC = 0x5c00;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_3_LOC = 0x5c20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_4_LOC = 0x5c40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_5_LOC = 0x5c60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_6_LOC = 0x5c80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_7_LOC = 0x5ca0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_12_8_LOC = 0x5cc0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_0_LOC = 0x5ce0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_1_LOC = 0x5d00;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_2_LOC = 0x5d20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_3_LOC = 0x5d40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_4_LOC = 0x5d60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_5_LOC = 0x5d80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_6_LOC = 0x5da0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_7_LOC = 0x5dc0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_13_8_LOC = 0x5de0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_0_LOC = 0x5e00;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_1_LOC = 0x5e20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_2_LOC = 0x5e40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_3_LOC = 0x5e60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_4_LOC = 0x5e80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_5_LOC = 0x5ea0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_6_LOC = 0x5ec0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_7_LOC = 0x5ee0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_14_8_LOC = 0x5f00;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_0_LOC = 0x5f20;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_1_LOC = 0x5f40;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_2_LOC = 0x5f60;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_3_LOC = 0x5f80;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_4_LOC = 0x5fa0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_5_LOC = 0x5fc0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_6_LOC = 0x5fe0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_7_LOC = 0x6000;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_15_8_LOC = 0x6020;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_0_LOC = 0x6040;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_1_LOC = 0x6060;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_2_LOC = 0x6080;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_3_LOC = 0x60a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_4_LOC = 0x60c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_5_LOC = 0x60e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_6_LOC = 0x6100;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_7_LOC = 0x6120;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_16_8_LOC = 0x6140;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_0_LOC = 0x6160;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_1_LOC = 0x6180;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_2_LOC = 0x61a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_3_LOC = 0x61c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_4_LOC = 0x61e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_5_LOC = 0x6200;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_6_LOC = 0x6220;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_7_LOC = 0x6240;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_17_8_LOC = 0x6260;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_0_LOC = 0x6280;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_1_LOC = 0x62a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_2_LOC = 0x62c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_3_LOC = 0x62e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_4_LOC = 0x6300;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_5_LOC = 0x6320;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_6_LOC = 0x6340;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_7_LOC = 0x6360;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_18_8_LOC = 0x6380;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_0_LOC = 0x63a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_1_LOC = 0x63c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_2_LOC = 0x63e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_3_LOC = 0x6400;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_4_LOC = 0x6420;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_5_LOC = 0x6440;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_6_LOC = 0x6460;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_7_LOC = 0x6480;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_19_8_LOC = 0x64a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_0_LOC = 0x64c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_1_LOC = 0x64e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_2_LOC = 0x6500;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_3_LOC = 0x6520;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_4_LOC = 0x6540;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_5_LOC = 0x6560;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_6_LOC = 0x6580;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_7_LOC = 0x65a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_20_8_LOC = 0x65c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_0_LOC = 0x65e0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_1_LOC = 0x6600;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_2_LOC = 0x6620;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_3_LOC = 0x6640;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_4_LOC = 0x6660;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_5_LOC = 0x6680;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_6_LOC = 0x66a0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_7_LOC = 0x66c0;
uint256 internal constant BARYCENTRIC_DENOMINATOR_INVERSES_21_8_LOC = 0x66e0;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         SUMCHECK - RUNTIME MEMORY - BARYCENTRIC COMPLETE                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       SUMCHECK - RUNTIME MEMORY - SUBRELATION EVALUATIONS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant SUBRELATION_EVAL_0_LOC = 0x6700;
uint256 internal constant SUBRELATION_EVAL_1_LOC = 0x6720;
uint256 internal constant SUBRELATION_EVAL_2_LOC = 0x6740;
uint256 internal constant SUBRELATION_EVAL_3_LOC = 0x6760;
uint256 internal constant SUBRELATION_EVAL_4_LOC = 0x6780;
uint256 internal constant SUBRELATION_EVAL_5_LOC = 0x67a0;
uint256 internal constant SUBRELATION_EVAL_6_LOC = 0x67c0;
uint256 internal constant SUBRELATION_EVAL_7_LOC = 0x67e0;
uint256 internal constant SUBRELATION_EVAL_8_LOC = 0x6800;
uint256 internal constant SUBRELATION_EVAL_9_LOC = 0x6820;
uint256 internal constant SUBRELATION_EVAL_10_LOC = 0x6840;
uint256 internal constant SUBRELATION_EVAL_11_LOC = 0x6860;
uint256 internal constant SUBRELATION_EVAL_12_LOC = 0x6880;
uint256 internal constant SUBRELATION_EVAL_13_LOC = 0x68a0;
uint256 internal constant SUBRELATION_EVAL_14_LOC = 0x68c0;
uint256 internal constant SUBRELATION_EVAL_15_LOC = 0x68e0;
uint256 internal constant SUBRELATION_EVAL_16_LOC = 0x6900;
uint256 internal constant SUBRELATION_EVAL_17_LOC = 0x6920;
uint256 internal constant SUBRELATION_EVAL_18_LOC = 0x6940;
uint256 internal constant SUBRELATION_EVAL_19_LOC = 0x6960;
uint256 internal constant SUBRELATION_EVAL_20_LOC = 0x6980;
uint256 internal constant SUBRELATION_EVAL_21_LOC = 0x69a0;
uint256 internal constant SUBRELATION_EVAL_22_LOC = 0x69c0;
uint256 internal constant SUBRELATION_EVAL_23_LOC = 0x69e0;
uint256 internal constant SUBRELATION_EVAL_24_LOC = 0x6a00;
uint256 internal constant SUBRELATION_EVAL_25_LOC = 0x6a20;
uint256 internal constant SUBRELATION_EVAL_26_LOC = 0x6a40;
uint256 internal constant SUBRELATION_EVAL_27_LOC = 0x6a60;
uint256 internal constant SUBRELATION_EVAL_28_LOC = 0x6a80;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                   SUMCHECK - RUNTIME MEMORY - SUBRELATION EVALUATIONS COMPLETE                   */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      SUMCHECK - RUNTIME MEMORY - SUBRELATION INTERMEDIATES                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant FINAL_ROUND_TARGET_LOC = 0x6aa0;
uint256 internal constant POW_PARTIAL_EVALUATION_LOC = 0x6ac0;
uint256 internal constant AUX_NON_NATIVE_FIELD_IDENTITY = 0x6ae0;
uint256 internal constant AUX_LIMB_ACCUMULATOR_IDENTITY = 0x6b00;
uint256 internal constant AUX_RAM_CONSISTENCY_CHECK_IDENTITY = 0x6b20;
uint256 internal constant AUX_ROM_CONSISTENCY_CHECK_IDENTITY = 0x6b40;
uint256 internal constant AUX_MEMORY_CHECK_IDENTITY = 0x6b60;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                               SUMCHECK - RUNTIME MEMORY - COMPLETE                               */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                    SHPLEMINI - RUNTIME MEMORY                                    */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            SHPLEMINI - POWERS OF EVALUATION CHALLENGE                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
/// {{ UNROLL_SECTION_START POWERS_OF_EVALUATION_CHALLENGE }}
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_0_LOC = 0x6b80;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_1_LOC = 0x6ba0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_2_LOC = 0x6bc0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_3_LOC = 0x6be0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_4_LOC = 0x6c00;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_5_LOC = 0x6c20;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_6_LOC = 0x6c40;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_7_LOC = 0x6c60;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_8_LOC = 0x6c80;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_9_LOC = 0x6ca0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_10_LOC = 0x6cc0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_11_LOC = 0x6ce0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_12_LOC = 0x6d00;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_13_LOC = 0x6d20;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_14_LOC = 0x6d40;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_15_LOC = 0x6d60;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_16_LOC = 0x6d80;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_17_LOC = 0x6da0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_18_LOC = 0x6dc0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_19_LOC = 0x6de0;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_20_LOC = 0x6e00;
uint256 internal constant POWERS_OF_EVALUATION_CHALLENGE_21_LOC = 0x6e20;
/// {{ UNROLL_SECTION_END POWERS_OF_EVALUATION_CHALLENGE }}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       SHPLEMINI - POWERS OF EVALUATION CHALLENGE COMPLETE                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            SHPLEMINI - RUNTIME MEMORY - BATCH SCALARS                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant BATCH_SCALAR_1_LOC = 0x6e40;
uint256 internal constant BATCH_SCALAR_2_LOC = 0x6e60;
uint256 internal constant BATCH_SCALAR_3_LOC = 0x6e80;
uint256 internal constant BATCH_SCALAR_4_LOC = 0x6ea0;
uint256 internal constant BATCH_SCALAR_5_LOC = 0x6ec0;
uint256 internal constant BATCH_SCALAR_6_LOC = 0x6ee0;
uint256 internal constant BATCH_SCALAR_7_LOC = 0x6f00;
uint256 internal constant BATCH_SCALAR_8_LOC = 0x6f20;
uint256 internal constant BATCH_SCALAR_9_LOC = 0x6f40;
uint256 internal constant BATCH_SCALAR_10_LOC = 0x6f60;
uint256 internal constant BATCH_SCALAR_11_LOC = 0x6f80;
uint256 internal constant BATCH_SCALAR_12_LOC = 0x6fa0;
uint256 internal constant BATCH_SCALAR_13_LOC = 0x6fc0;
uint256 internal constant BATCH_SCALAR_14_LOC = 0x6fe0;
uint256 internal constant BATCH_SCALAR_15_LOC = 0x7000;
uint256 internal constant BATCH_SCALAR_16_LOC = 0x7020;
uint256 internal constant BATCH_SCALAR_17_LOC = 0x7040;
uint256 internal constant BATCH_SCALAR_18_LOC = 0x7060;
uint256 internal constant BATCH_SCALAR_19_LOC = 0x7080;
uint256 internal constant BATCH_SCALAR_20_LOC = 0x70a0;
uint256 internal constant BATCH_SCALAR_21_LOC = 0x70c0;
uint256 internal constant BATCH_SCALAR_22_LOC = 0x70e0;
uint256 internal constant BATCH_SCALAR_23_LOC = 0x7100;
uint256 internal constant BATCH_SCALAR_24_LOC = 0x7120;
uint256 internal constant BATCH_SCALAR_25_LOC = 0x7140;
uint256 internal constant BATCH_SCALAR_26_LOC = 0x7160;
uint256 internal constant BATCH_SCALAR_27_LOC = 0x7180;
uint256 internal constant BATCH_SCALAR_28_LOC = 0x71a0;
uint256 internal constant BATCH_SCALAR_29_LOC = 0x71c0;
uint256 internal constant BATCH_SCALAR_30_LOC = 0x71e0;
uint256 internal constant BATCH_SCALAR_31_LOC = 0x7200;
uint256 internal constant BATCH_SCALAR_32_LOC = 0x7220;
uint256 internal constant BATCH_SCALAR_33_LOC = 0x7240;
uint256 internal constant BATCH_SCALAR_34_LOC = 0x7260;
uint256 internal constant BATCH_SCALAR_35_LOC = 0x7280;
uint256 internal constant BATCH_SCALAR_36_LOC = 0x72a0;
uint256 internal constant BATCH_SCALAR_37_LOC = 0x72c0;
uint256 internal constant BATCH_SCALAR_38_LOC = 0x72e0;
uint256 internal constant BATCH_SCALAR_39_LOC = 0x7300;
uint256 internal constant BATCH_SCALAR_40_LOC = 0x7320;
uint256 internal constant BATCH_SCALAR_41_LOC = 0x7340;
uint256 internal constant BATCH_SCALAR_42_LOC = 0x7360;
uint256 internal constant BATCH_SCALAR_43_LOC = 0x7380;
uint256 internal constant BATCH_SCALAR_44_LOC = 0x73a0;
uint256 internal constant BATCH_SCALAR_45_LOC = 0x73c0;
uint256 internal constant BATCH_SCALAR_46_LOC = 0x73e0;
uint256 internal constant BATCH_SCALAR_47_LOC = 0x7400;
uint256 internal constant BATCH_SCALAR_48_LOC = 0x7420;
uint256 internal constant BATCH_SCALAR_49_LOC = 0x7440;
uint256 internal constant BATCH_SCALAR_50_LOC = 0x7460;
uint256 internal constant BATCH_SCALAR_51_LOC = 0x7480;
uint256 internal constant BATCH_SCALAR_52_LOC = 0x74a0;
uint256 internal constant BATCH_SCALAR_53_LOC = 0x74c0;
uint256 internal constant BATCH_SCALAR_54_LOC = 0x74e0;
uint256 internal constant BATCH_SCALAR_55_LOC = 0x7500;
uint256 internal constant BATCH_SCALAR_56_LOC = 0x7520;
uint256 internal constant BATCH_SCALAR_57_LOC = 0x7540;
uint256 internal constant BATCH_SCALAR_58_LOC = 0x7560;
uint256 internal constant BATCH_SCALAR_59_LOC = 0x7580;
uint256 internal constant BATCH_SCALAR_60_LOC = 0x75a0;
uint256 internal constant BATCH_SCALAR_61_LOC = 0x75c0;
uint256 internal constant BATCH_SCALAR_62_LOC = 0x75e0;
uint256 internal constant BATCH_SCALAR_63_LOC = 0x7600;
uint256 internal constant BATCH_SCALAR_64_LOC = 0x7620;
uint256 internal constant BATCH_SCALAR_65_LOC = 0x7640;
uint256 internal constant BATCH_SCALAR_66_LOC = 0x7660;
uint256 internal constant BATCH_SCALAR_67_LOC = 0x7680;
uint256 internal constant BATCH_SCALAR_68_LOC = 0x76a0;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       SHPLEMINI - RUNTIME MEMORY - BATCH SCALARS COMPLETE                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                             SHPLEMINI - RUNTIME MEMORY - INVERSIONS                              */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant GEMINI_R_INV_LOC = 0x76c0;
uint256 internal constant LIBRA_SUBGROUP_DENOM_LOC = 0x76e0;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_0_LOC = 0x7700;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_1_LOC = 0x7720;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_2_LOC = 0x7740;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_3_LOC = 0x7760;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_4_LOC = 0x7780;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_5_LOC = 0x77a0;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_6_LOC = 0x77c0;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_7_LOC = 0x77e0;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_8_LOC = 0x7800;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_9_LOC = 0x7820;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_10_LOC = 0x7840;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_11_LOC = 0x7860;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_12_LOC = 0x7880;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_13_LOC = 0x78a0;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_14_LOC = 0x78c0;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_15_LOC = 0x78e0;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_16_LOC = 0x7900;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_17_LOC = 0x7920;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_18_LOC = 0x7940;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_19_LOC = 0x7960;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_20_LOC = 0x7980;
uint256 internal constant BATCH_EVALUATION_ACCUMULATOR_INVERSION_21_LOC = 0x79a0;

uint256 internal constant CONSTANT_TERM_ACCUMULATOR_LOC = 0x79c0;

uint256 internal constant POS_INVERTED_DENOMINATOR = 0x79e0;
uint256 internal constant NEG_INVERTED_DENOMINATOR = 0x7a00;

// LOG_N challenge pow minus u
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_0_LOC = 0x7a20;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_1_LOC = 0x7a40;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_2_LOC = 0x7a60;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_3_LOC = 0x7a80;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_4_LOC = 0x7aa0;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_5_LOC = 0x7ac0;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_6_LOC = 0x7ae0;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_7_LOC = 0x7b00;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_8_LOC = 0x7b20;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_9_LOC = 0x7b40;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_10_LOC = 0x7b60;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_11_LOC = 0x7b80;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_12_LOC = 0x7ba0;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_13_LOC = 0x7bc0;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_14_LOC = 0x7be0;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_15_LOC = 0x7c00;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_16_LOC = 0x7c20;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_17_LOC = 0x7c40;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_18_LOC = 0x7c60;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_19_LOC = 0x7c80;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_20_LOC = 0x7ca0;
uint256 internal constant INVERTED_CHALLENGE_POW_MINUS_U_21_LOC = 0x7cc0;

// LOG_N pos_inverted_off
uint256 internal constant POS_INVERTED_DENOM_0_LOC = 0x7ce0;
uint256 internal constant POS_INVERTED_DENOM_1_LOC = 0x7d00;
uint256 internal constant POS_INVERTED_DENOM_2_LOC = 0x7d20;
uint256 internal constant POS_INVERTED_DENOM_3_LOC = 0x7d40;
uint256 internal constant POS_INVERTED_DENOM_4_LOC = 0x7d60;
uint256 internal constant POS_INVERTED_DENOM_5_LOC = 0x7d80;
uint256 internal constant POS_INVERTED_DENOM_6_LOC = 0x7da0;
uint256 internal constant POS_INVERTED_DENOM_7_LOC = 0x7dc0;
uint256 internal constant POS_INVERTED_DENOM_8_LOC = 0x7de0;
uint256 internal constant POS_INVERTED_DENOM_9_LOC = 0x7e00;
uint256 internal constant POS_INVERTED_DENOM_10_LOC = 0x7e20;
uint256 internal constant POS_INVERTED_DENOM_11_LOC = 0x7e40;
uint256 internal constant POS_INVERTED_DENOM_12_LOC = 0x7e60;
uint256 internal constant POS_INVERTED_DENOM_13_LOC = 0x7e80;
uint256 internal constant POS_INVERTED_DENOM_14_LOC = 0x7ea0;
uint256 internal constant POS_INVERTED_DENOM_15_LOC = 0x7ec0;
uint256 internal constant POS_INVERTED_DENOM_16_LOC = 0x7ee0;
uint256 internal constant POS_INVERTED_DENOM_17_LOC = 0x7f00;
uint256 internal constant POS_INVERTED_DENOM_18_LOC = 0x7f20;
uint256 internal constant POS_INVERTED_DENOM_19_LOC = 0x7f40;
uint256 internal constant POS_INVERTED_DENOM_20_LOC = 0x7f60;
uint256 internal constant POS_INVERTED_DENOM_21_LOC = 0x7f80;

// LOG_N neg_inverted_off
uint256 internal constant NEG_INVERTED_DENOM_0_LOC = 0x7fa0;
uint256 internal constant NEG_INVERTED_DENOM_1_LOC = 0x7fc0;
uint256 internal constant NEG_INVERTED_DENOM_2_LOC = 0x7fe0;
uint256 internal constant NEG_INVERTED_DENOM_3_LOC = 0x8000;
uint256 internal constant NEG_INVERTED_DENOM_4_LOC = 0x8020;
uint256 internal constant NEG_INVERTED_DENOM_5_LOC = 0x8040;
uint256 internal constant NEG_INVERTED_DENOM_6_LOC = 0x8060;
uint256 internal constant NEG_INVERTED_DENOM_7_LOC = 0x8080;
uint256 internal constant NEG_INVERTED_DENOM_8_LOC = 0x80a0;
uint256 internal constant NEG_INVERTED_DENOM_9_LOC = 0x80c0;
uint256 internal constant NEG_INVERTED_DENOM_10_LOC = 0x80e0;
uint256 internal constant NEG_INVERTED_DENOM_11_LOC = 0x8100;
uint256 internal constant NEG_INVERTED_DENOM_12_LOC = 0x8120;
uint256 internal constant NEG_INVERTED_DENOM_13_LOC = 0x8140;
uint256 internal constant NEG_INVERTED_DENOM_14_LOC = 0x8160;
uint256 internal constant NEG_INVERTED_DENOM_15_LOC = 0x8180;
uint256 internal constant NEG_INVERTED_DENOM_16_LOC = 0x81a0;
uint256 internal constant NEG_INVERTED_DENOM_17_LOC = 0x81c0;
uint256 internal constant NEG_INVERTED_DENOM_18_LOC = 0x81e0;
uint256 internal constant NEG_INVERTED_DENOM_19_LOC = 0x8200;
uint256 internal constant NEG_INVERTED_DENOM_20_LOC = 0x8220;
uint256 internal constant NEG_INVERTED_DENOM_21_LOC = 0x8240;

uint256 internal constant FOLD_POS_EVALUATIONS_0_LOC = 0x8260;
uint256 internal constant FOLD_POS_EVALUATIONS_1_LOC = 0x8280;
uint256 internal constant FOLD_POS_EVALUATIONS_2_LOC = 0x82a0;
uint256 internal constant FOLD_POS_EVALUATIONS_3_LOC = 0x82c0;
uint256 internal constant FOLD_POS_EVALUATIONS_4_LOC = 0x82e0;
uint256 internal constant FOLD_POS_EVALUATIONS_5_LOC = 0x8300;
uint256 internal constant FOLD_POS_EVALUATIONS_6_LOC = 0x8320;
uint256 internal constant FOLD_POS_EVALUATIONS_7_LOC = 0x8340;
uint256 internal constant FOLD_POS_EVALUATIONS_8_LOC = 0x8360;
uint256 internal constant FOLD_POS_EVALUATIONS_9_LOC = 0x8380;
uint256 internal constant FOLD_POS_EVALUATIONS_10_LOC = 0x83a0;
uint256 internal constant FOLD_POS_EVALUATIONS_11_LOC = 0x83c0;
uint256 internal constant FOLD_POS_EVALUATIONS_12_LOC = 0x83e0;
uint256 internal constant FOLD_POS_EVALUATIONS_13_LOC = 0x8400;
uint256 internal constant FOLD_POS_EVALUATIONS_14_LOC = 0x8420;
uint256 internal constant FOLD_POS_EVALUATIONS_15_LOC = 0x8440;
uint256 internal constant FOLD_POS_EVALUATIONS_16_LOC = 0x8460;
uint256 internal constant FOLD_POS_EVALUATIONS_17_LOC = 0x8480;
uint256 internal constant FOLD_POS_EVALUATIONS_18_LOC = 0x84a0;
uint256 internal constant FOLD_POS_EVALUATIONS_19_LOC = 0x84c0;
uint256 internal constant FOLD_POS_EVALUATIONS_20_LOC = 0x84e0;
uint256 internal constant FOLD_POS_EVALUATIONS_21_LOC = 0x8500;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         SHPLEMINI RUNTIME MEMORY - INVERSIONS - COMPLETE                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                               SHPLEMINI RUNTIME MEMORY - COMPLETE                                */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

uint256 internal constant BARYCENTRIC_TEMP_0_LOC = 0x8520;
uint256 internal constant BARYCENTRIC_TEMP_1_LOC = 0x8540;
uint256 internal constant BARYCENTRIC_TEMP_2_LOC = 0x8560;
uint256 internal constant BARYCENTRIC_TEMP_3_LOC = 0x8580;
uint256 internal constant BARYCENTRIC_TEMP_4_LOC = 0x85a0;
uint256 internal constant BARYCENTRIC_TEMP_5_LOC = 0x85c0;
uint256 internal constant BARYCENTRIC_TEMP_6_LOC = 0x85e0;
uint256 internal constant BARYCENTRIC_TEMP_7_LOC = 0x8600;
uint256 internal constant BARYCENTRIC_TEMP_8_LOC = 0x8620;
uint256 internal constant BARYCENTRIC_TEMP_9_LOC = 0x8640;
uint256 internal constant BARYCENTRIC_TEMP_10_LOC = 0x8660;
uint256 internal constant BARYCENTRIC_TEMP_11_LOC = 0x8680;
uint256 internal constant BARYCENTRIC_TEMP_12_LOC = 0x86a0;
uint256 internal constant BARYCENTRIC_TEMP_13_LOC = 0x86c0;
uint256 internal constant BARYCENTRIC_TEMP_14_LOC = 0x86e0;
uint256 internal constant BARYCENTRIC_TEMP_15_LOC = 0x8700;
uint256 internal constant BARYCENTRIC_TEMP_16_LOC = 0x8720;
uint256 internal constant BARYCENTRIC_TEMP_17_LOC = 0x8740;
uint256 internal constant BARYCENTRIC_TEMP_18_LOC = 0x8760;
uint256 internal constant BARYCENTRIC_TEMP_19_LOC = 0x8780;
uint256 internal constant BARYCENTRIC_TEMP_20_LOC = 0x87a0;
uint256 internal constant BARYCENTRIC_TEMP_21_LOC = 0x87c0;
uint256 internal constant BARYCENTRIC_TEMP_22_LOC = 0x87e0;
uint256 internal constant BARYCENTRIC_TEMP_23_LOC = 0x8800;
uint256 internal constant BARYCENTRIC_TEMP_24_LOC = 0x8820;
uint256 internal constant BARYCENTRIC_TEMP_25_LOC = 0x8840;
uint256 internal constant BARYCENTRIC_TEMP_26_LOC = 0x8860;
uint256 internal constant BARYCENTRIC_TEMP_27_LOC = 0x8880;
uint256 internal constant BARYCENTRIC_TEMP_28_LOC = 0x88a0;
uint256 internal constant BARYCENTRIC_TEMP_29_LOC = 0x88c0;
uint256 internal constant BARYCENTRIC_TEMP_30_LOC = 0x88e0;
uint256 internal constant BARYCENTRIC_TEMP_31_LOC = 0x8900;
uint256 internal constant BARYCENTRIC_TEMP_32_LOC = 0x8920;
uint256 internal constant BARYCENTRIC_TEMP_33_LOC = 0x8940;
uint256 internal constant BARYCENTRIC_TEMP_34_LOC = 0x8960;
uint256 internal constant BARYCENTRIC_TEMP_35_LOC = 0x8980;
uint256 internal constant BARYCENTRIC_TEMP_36_LOC = 0x89a0;
uint256 internal constant BARYCENTRIC_TEMP_37_LOC = 0x89c0;
uint256 internal constant BARYCENTRIC_TEMP_38_LOC = 0x89e0;
uint256 internal constant BARYCENTRIC_TEMP_39_LOC = 0x8a00;
uint256 internal constant BARYCENTRIC_TEMP_40_LOC = 0x8a20;
uint256 internal constant BARYCENTRIC_TEMP_41_LOC = 0x8a40;
uint256 internal constant BARYCENTRIC_TEMP_42_LOC = 0x8a60;
uint256 internal constant BARYCENTRIC_TEMP_43_LOC = 0x8a80;
uint256 internal constant BARYCENTRIC_TEMP_44_LOC = 0x8aa0;
uint256 internal constant BARYCENTRIC_TEMP_45_LOC = 0x8ac0;
uint256 internal constant BARYCENTRIC_TEMP_46_LOC = 0x8ae0;
uint256 internal constant BARYCENTRIC_TEMP_47_LOC = 0x8b00;
uint256 internal constant BARYCENTRIC_TEMP_48_LOC = 0x8b20;
uint256 internal constant BARYCENTRIC_TEMP_49_LOC = 0x8b40;
uint256 internal constant BARYCENTRIC_TEMP_50_LOC = 0x8b60;
uint256 internal constant BARYCENTRIC_TEMP_51_LOC = 0x8b80;
uint256 internal constant BARYCENTRIC_TEMP_52_LOC = 0x8ba0;
uint256 internal constant BARYCENTRIC_TEMP_53_LOC = 0x8bc0;
uint256 internal constant BARYCENTRIC_TEMP_54_LOC = 0x8be0;
uint256 internal constant BARYCENTRIC_TEMP_55_LOC = 0x8c00;
uint256 internal constant BARYCENTRIC_TEMP_56_LOC = 0x8c20;
uint256 internal constant BARYCENTRIC_TEMP_57_LOC = 0x8c40;
uint256 internal constant BARYCENTRIC_TEMP_58_LOC = 0x8c60;
uint256 internal constant BARYCENTRIC_TEMP_59_LOC = 0x8c80;
uint256 internal constant BARYCENTRIC_TEMP_60_LOC = 0x8ca0;
uint256 internal constant BARYCENTRIC_TEMP_61_LOC = 0x8cc0;
uint256 internal constant BARYCENTRIC_TEMP_62_LOC = 0x8ce0;
uint256 internal constant BARYCENTRIC_TEMP_63_LOC = 0x8d00;
uint256 internal constant BARYCENTRIC_TEMP_64_LOC = 0x8d20;
uint256 internal constant BARYCENTRIC_TEMP_65_LOC = 0x8d40;
uint256 internal constant BARYCENTRIC_TEMP_66_LOC = 0x8d60;
uint256 internal constant BARYCENTRIC_TEMP_67_LOC = 0x8d80;
uint256 internal constant BARYCENTRIC_TEMP_68_LOC = 0x8da0;
uint256 internal constant BARYCENTRIC_TEMP_69_LOC = 0x8dc0;
uint256 internal constant BARYCENTRIC_TEMP_70_LOC = 0x8de0;
uint256 internal constant BARYCENTRIC_TEMP_71_LOC = 0x8e00;
uint256 internal constant BARYCENTRIC_TEMP_72_LOC = 0x8e20;
uint256 internal constant BARYCENTRIC_TEMP_73_LOC = 0x8e40;
uint256 internal constant BARYCENTRIC_TEMP_74_LOC = 0x8e60;
uint256 internal constant BARYCENTRIC_TEMP_75_LOC = 0x8e80;
uint256 internal constant BARYCENTRIC_TEMP_76_LOC = 0x8ea0;
uint256 internal constant BARYCENTRIC_TEMP_77_LOC = 0x8ec0;
uint256 internal constant BARYCENTRIC_TEMP_78_LOC = 0x8ee0;
uint256 internal constant BARYCENTRIC_TEMP_79_LOC = 0x8f00;
uint256 internal constant BARYCENTRIC_TEMP_80_LOC = 0x8f20;
uint256 internal constant BARYCENTRIC_TEMP_81_LOC = 0x8f40;
uint256 internal constant BARYCENTRIC_TEMP_82_LOC = 0x8f60;
uint256 internal constant BARYCENTRIC_TEMP_83_LOC = 0x8f80;
uint256 internal constant BARYCENTRIC_TEMP_84_LOC = 0x8fa0;
uint256 internal constant BARYCENTRIC_TEMP_85_LOC = 0x8fc0;
uint256 internal constant BARYCENTRIC_TEMP_86_LOC = 0x8fe0;
uint256 internal constant BARYCENTRIC_TEMP_87_LOC = 0x9000;
uint256 internal constant BARYCENTRIC_TEMP_88_LOC = 0x9020;
uint256 internal constant BARYCENTRIC_TEMP_89_LOC = 0x9040;
uint256 internal constant BARYCENTRIC_TEMP_90_LOC = 0x9060;
uint256 internal constant BARYCENTRIC_TEMP_91_LOC = 0x9080;
uint256 internal constant BARYCENTRIC_TEMP_92_LOC = 0x90a0;
uint256 internal constant BARYCENTRIC_TEMP_93_LOC = 0x90c0;
uint256 internal constant BARYCENTRIC_TEMP_94_LOC = 0x90e0;
uint256 internal constant BARYCENTRIC_TEMP_95_LOC = 0x9100;
uint256 internal constant BARYCENTRIC_TEMP_96_LOC = 0x9120;
uint256 internal constant BARYCENTRIC_TEMP_97_LOC = 0x9140;
uint256 internal constant BARYCENTRIC_TEMP_98_LOC = 0x9160;
uint256 internal constant BARYCENTRIC_TEMP_99_LOC = 0x9180;
uint256 internal constant BARYCENTRIC_TEMP_100_LOC = 0x91a0;
uint256 internal constant BARYCENTRIC_TEMP_101_LOC = 0x91c0;
uint256 internal constant BARYCENTRIC_TEMP_102_LOC = 0x91e0;
uint256 internal constant BARYCENTRIC_TEMP_103_LOC = 0x9200;
uint256 internal constant BARYCENTRIC_TEMP_104_LOC = 0x9220;
uint256 internal constant BARYCENTRIC_TEMP_105_LOC = 0x9240;
uint256 internal constant BARYCENTRIC_TEMP_106_LOC = 0x9260;
uint256 internal constant BARYCENTRIC_TEMP_107_LOC = 0x9280;
uint256 internal constant BARYCENTRIC_TEMP_108_LOC = 0x92a0;
uint256 internal constant BARYCENTRIC_TEMP_109_LOC = 0x92c0;
uint256 internal constant BARYCENTRIC_TEMP_110_LOC = 0x92e0;
uint256 internal constant BARYCENTRIC_TEMP_111_LOC = 0x9300;
uint256 internal constant BARYCENTRIC_TEMP_112_LOC = 0x9320;
uint256 internal constant BARYCENTRIC_TEMP_113_LOC = 0x9340;
uint256 internal constant BARYCENTRIC_TEMP_114_LOC = 0x9360;
uint256 internal constant BARYCENTRIC_TEMP_115_LOC = 0x9380;
uint256 internal constant BARYCENTRIC_TEMP_116_LOC = 0x93a0;
uint256 internal constant BARYCENTRIC_TEMP_117_LOC = 0x93c0;
uint256 internal constant BARYCENTRIC_TEMP_118_LOC = 0x93e0;
uint256 internal constant BARYCENTRIC_TEMP_119_LOC = 0x9400;
uint256 internal constant BARYCENTRIC_TEMP_120_LOC = 0x9420;
uint256 internal constant BARYCENTRIC_TEMP_121_LOC = 0x9440;
uint256 internal constant BARYCENTRIC_TEMP_122_LOC = 0x9460;
uint256 internal constant BARYCENTRIC_TEMP_123_LOC = 0x9480;
uint256 internal constant BARYCENTRIC_TEMP_124_LOC = 0x94a0;
uint256 internal constant BARYCENTRIC_TEMP_125_LOC = 0x94c0;
uint256 internal constant BARYCENTRIC_TEMP_126_LOC = 0x94e0;
uint256 internal constant BARYCENTRIC_TEMP_127_LOC = 0x9500;
uint256 internal constant BARYCENTRIC_TEMP_128_LOC = 0x9520;
uint256 internal constant BARYCENTRIC_TEMP_129_LOC = 0x9540;
uint256 internal constant BARYCENTRIC_TEMP_130_LOC = 0x9560;
uint256 internal constant BARYCENTRIC_TEMP_131_LOC = 0x9580;
uint256 internal constant BARYCENTRIC_TEMP_132_LOC = 0x95a0;
uint256 internal constant BARYCENTRIC_TEMP_133_LOC = 0x95c0;
uint256 internal constant BARYCENTRIC_TEMP_134_LOC = 0x95e0;
uint256 internal constant BARYCENTRIC_TEMP_135_LOC = 0x9600;
uint256 internal constant BARYCENTRIC_TEMP_136_LOC = 0x9620;
uint256 internal constant BARYCENTRIC_TEMP_137_LOC = 0x9640;
uint256 internal constant BARYCENTRIC_TEMP_138_LOC = 0x9660;
uint256 internal constant BARYCENTRIC_TEMP_139_LOC = 0x9680;
uint256 internal constant BARYCENTRIC_TEMP_140_LOC = 0x96a0;
uint256 internal constant BARYCENTRIC_TEMP_141_LOC = 0x96c0;
uint256 internal constant BARYCENTRIC_TEMP_142_LOC = 0x96e0;
uint256 internal constant BARYCENTRIC_TEMP_143_LOC = 0x9700;
uint256 internal constant BARYCENTRIC_TEMP_144_LOC = 0x9720;
uint256 internal constant BARYCENTRIC_TEMP_145_LOC = 0x9740;
uint256 internal constant BARYCENTRIC_TEMP_146_LOC = 0x9760;
uint256 internal constant BARYCENTRIC_TEMP_147_LOC = 0x9780;
uint256 internal constant BARYCENTRIC_TEMP_148_LOC = 0x97a0;
uint256 internal constant BARYCENTRIC_TEMP_149_LOC = 0x97c0;
uint256 internal constant BARYCENTRIC_TEMP_150_LOC = 0x97e0;
uint256 internal constant BARYCENTRIC_TEMP_151_LOC = 0x9800;
uint256 internal constant BARYCENTRIC_TEMP_152_LOC = 0x9820;
uint256 internal constant BARYCENTRIC_TEMP_153_LOC = 0x9840;
uint256 internal constant BARYCENTRIC_TEMP_154_LOC = 0x9860;
uint256 internal constant BARYCENTRIC_TEMP_155_LOC = 0x9880;
uint256 internal constant BARYCENTRIC_TEMP_156_LOC = 0x98a0;
uint256 internal constant BARYCENTRIC_TEMP_157_LOC = 0x98c0;
uint256 internal constant BARYCENTRIC_TEMP_158_LOC = 0x98e0;
uint256 internal constant BARYCENTRIC_TEMP_159_LOC = 0x9900;
uint256 internal constant BARYCENTRIC_TEMP_160_LOC = 0x9920;
uint256 internal constant BARYCENTRIC_TEMP_161_LOC = 0x9940;
uint256 internal constant BARYCENTRIC_TEMP_162_LOC = 0x9960;
uint256 internal constant BARYCENTRIC_TEMP_163_LOC = 0x9980;
uint256 internal constant BARYCENTRIC_TEMP_164_LOC = 0x99a0;
uint256 internal constant BARYCENTRIC_TEMP_165_LOC = 0x99c0;
uint256 internal constant BARYCENTRIC_TEMP_166_LOC = 0x99e0;
uint256 internal constant BARYCENTRIC_TEMP_167_LOC = 0x9a00;
uint256 internal constant BARYCENTRIC_TEMP_168_LOC = 0x9a20;
uint256 internal constant BARYCENTRIC_TEMP_169_LOC = 0x9a40;
uint256 internal constant BARYCENTRIC_TEMP_170_LOC = 0x9a60;
uint256 internal constant BARYCENTRIC_TEMP_171_LOC = 0x9a80;
uint256 internal constant BARYCENTRIC_TEMP_172_LOC = 0x9aa0;
uint256 internal constant BARYCENTRIC_TEMP_173_LOC = 0x9ac0;
uint256 internal constant BARYCENTRIC_TEMP_174_LOC = 0x9ae0;
uint256 internal constant BARYCENTRIC_TEMP_175_LOC = 0x9b00;
uint256 internal constant BARYCENTRIC_TEMP_176_LOC = 0x9b20;
uint256 internal constant BARYCENTRIC_TEMP_177_LOC = 0x9b40;
uint256 internal constant BARYCENTRIC_TEMP_178_LOC = 0x9b60;
uint256 internal constant BARYCENTRIC_TEMP_179_LOC = 0x9b80;
uint256 internal constant BARYCENTRIC_TEMP_180_LOC = 0x9ba0;
uint256 internal constant BARYCENTRIC_TEMP_181_LOC = 0x9bc0;
uint256 internal constant BARYCENTRIC_TEMP_182_LOC = 0x9be0;
uint256 internal constant BARYCENTRIC_TEMP_183_LOC = 0x9c00;
uint256 internal constant BARYCENTRIC_TEMP_184_LOC = 0x9c20;
uint256 internal constant BARYCENTRIC_TEMP_185_LOC = 0x9c40;
uint256 internal constant BARYCENTRIC_TEMP_186_LOC = 0x9c60;
uint256 internal constant BARYCENTRIC_TEMP_187_LOC = 0x9c80;
uint256 internal constant BARYCENTRIC_TEMP_188_LOC = 0x9ca0;
uint256 internal constant BARYCENTRIC_TEMP_189_LOC = 0x9cc0;
uint256 internal constant BARYCENTRIC_TEMP_190_LOC = 0x9ce0;
uint256 internal constant BARYCENTRIC_TEMP_191_LOC = 0x9d00;
uint256 internal constant BARYCENTRIC_TEMP_192_LOC = 0x9d20;
uint256 internal constant BARYCENTRIC_TEMP_193_LOC = 0x9d40;
uint256 internal constant BARYCENTRIC_TEMP_194_LOC = 0x9d60;
uint256 internal constant BARYCENTRIC_TEMP_195_LOC = 0x9d80;
uint256 internal constant BARYCENTRIC_TEMP_196_LOC = 0x9da0;
uint256 internal constant BARYCENTRIC_TEMP_197_LOC = 0x9dc0;
uint256 internal constant PUBLIC_INPUTS_DENOM_TEMP_LOC = 0x9de0;
uint256 internal constant GEMINI_R_INV_TEMP_LOC = 0x9e00;
uint256 internal constant LIBRA_SUBGROUP_DENOM_TEMP_LOC = 0x9e20;
uint256 internal constant BATCH_PRODUCT_TEMP_LOC = 0x9e40;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                         Temporary space                                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
uint256 internal constant TEMP_0_LOC = 0x9e60;
uint256 internal constant TEMP_1_LOC = 0x9e80;
uint256 internal constant TEMP_2_LOC = 0x9ea0;
uint256 internal constant TEMP_3_LOC = 0x9ec0;
uint256 internal constant TEMP_4_LOC = 0x9ee0;
uint256 internal constant TEMP_5_LOC = 0x9f00;
uint256 internal constant TEMP_6_LOC = 0x9f20;
uint256 internal constant TEMP_7_LOC = 0x9f40;
uint256 internal constant TEMP_8_LOC = 0x9f60;
uint256 internal constant TEMP_9_LOC = 0x9f80;
uint256 internal constant TEMP_10_LOC = 0x9fa0;
uint256 internal constant TEMP_11_LOC = 0x9fc0;
uint256 internal constant TEMP_12_LOC = 0x9fe0;
uint256 internal constant TEMP_13_LOC = 0xa000;
uint256 internal constant TEMP_14_LOC = 0xa020;
uint256 internal constant TEMP_15_LOC = 0xa040;
uint256 internal constant TEMP_16_LOC = 0xa060;
uint256 internal constant TEMP_17_LOC = 0xa080;
uint256 internal constant TEMP_18_LOC = 0xa0a0;
uint256 internal constant TEMP_19_LOC = 0xa0c0;
uint256 internal constant TEMP_20_LOC = 0xa0e0;
uint256 internal constant TEMP_21_LOC = 0xa100;
uint256 internal constant TEMP_22_LOC = 0xa120;
uint256 internal constant TEMP_23_LOC = 0xa140;
uint256 internal constant TEMP_24_LOC = 0xa160;
uint256 internal constant TEMP_25_LOC = 0xa180;
uint256 internal constant TEMP_26_LOC = 0xa1a0;
uint256 internal constant TEMP_27_LOC = 0xa1c0;
uint256 internal constant TEMP_28_LOC = 0xa1e0;
uint256 internal constant TEMP_29_LOC = 0xa200;
uint256 internal constant TEMP_30_LOC = 0xa220;
uint256 internal constant TEMP_31_LOC = 0xa240;
uint256 internal constant TEMP_32_LOC = 0xa260;
uint256 internal constant TEMP_33_LOC = 0xa280;
uint256 internal constant TEMP_34_LOC = 0xa2a0;
uint256 internal constant TEMP_35_LOC = 0xa2c0;
uint256 internal constant TEMP_36_LOC = 0xa2e0;
uint256 internal constant TEMP_37_LOC = 0xa300;
uint256 internal constant TEMP_38_LOC = 0xa320;
uint256 internal constant TEMP_39_LOC = 0xa340;
uint256 internal constant TEMP_40_LOC = 0xa360;
uint256 internal constant TEMP_41_LOC = 0xa380;
uint256 internal constant TEMP_42_LOC = 0xa3a0;
uint256 internal constant TEMP_43_LOC = 0xa3c0;
uint256 internal constant TEMP_44_LOC = 0xa3e0;
uint256 internal constant TEMP_45_LOC = 0xa400;
uint256 internal constant TEMP_46_LOC = 0xa420;
uint256 internal constant TEMP_47_LOC = 0xa440;
uint256 internal constant TEMP_48_LOC = 0xa460;
uint256 internal constant TEMP_49_LOC = 0xa480;
uint256 internal constant TEMP_50_LOC = 0xa4a0;
uint256 internal constant TEMP_51_LOC = 0xa4c0;
uint256 internal constant TEMP_52_LOC = 0xa4e0;
uint256 internal constant TEMP_53_LOC = 0xa500;
uint256 internal constant TEMP_54_LOC = 0xa520;
uint256 internal constant TEMP_55_LOC = 0xa540;
uint256 internal constant TEMP_56_LOC = 0xa560;
uint256 internal constant TEMP_57_LOC = 0xa580;
uint256 internal constant TEMP_58_LOC = 0xa5a0;
uint256 internal constant TEMP_59_LOC = 0xa5c0;
uint256 internal constant TEMP_60_LOC = 0xa5e0;
uint256 internal constant TEMP_61_LOC = 0xa600;
uint256 internal constant TEMP_62_LOC = 0xa620;
uint256 internal constant TEMP_63_LOC = 0xa640;
uint256 internal constant TEMP_64_LOC = 0xa660;
uint256 internal constant TEMP_65_LOC = 0xa680;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                        Small subgroup IPA                                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
// Allocate only the active challenge-poly prefix and the extra denominator/product slot
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_0 = 0xa6a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_1 = 0xa6c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_2 = 0xa6e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_3 = 0xa700;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_4 = 0xa720;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_5 = 0xa740;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_6 = 0xa760;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_7 = 0xa780;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_8 = 0xa7a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_9 = 0xa7c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_10 = 0xa7e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_11 = 0xa800;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_12 = 0xa820;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_13 = 0xa840;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_14 = 0xa860;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_15 = 0xa880;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_16 = 0xa8a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_17 = 0xa8c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_18 = 0xa8e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_19 = 0xa900;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_20 = 0xa920;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_21 = 0xa940;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_22 = 0xa960;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_23 = 0xa980;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_24 = 0xa9a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_25 = 0xa9c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_26 = 0xa9e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_27 = 0xaa00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_28 = 0xaa20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_29 = 0xaa40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_30 = 0xaa60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_31 = 0xaa80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_32 = 0xaaa0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_33 = 0xaac0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_34 = 0xaae0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_35 = 0xab00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_36 = 0xab20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_37 = 0xab40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_38 = 0xab60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_39 = 0xab80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_40 = 0xaba0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_41 = 0xabc0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_42 = 0xabe0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_43 = 0xac00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_44 = 0xac20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_45 = 0xac40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_46 = 0xac60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_47 = 0xac80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_48 = 0xaca0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_49 = 0xacc0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_50 = 0xace0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_51 = 0xad00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_52 = 0xad20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_53 = 0xad40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_54 = 0xad60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_55 = 0xad80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_56 = 0xada0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_57 = 0xadc0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_58 = 0xade0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_59 = 0xae00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_60 = 0xae20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_61 = 0xae40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_62 = 0xae60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_63 = 0xae80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_64 = 0xaea0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_65 = 0xaec0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_66 = 0xaee0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_67 = 0xaf00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_68 = 0xaf20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_69 = 0xaf40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_70 = 0xaf60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_71 = 0xaf80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_72 = 0xafa0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_73 = 0xafc0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_74 = 0xafe0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_75 = 0xb000;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_76 = 0xb020;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_77 = 0xb040;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_78 = 0xb060;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_79 = 0xb080;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_80 = 0xb0a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_81 = 0xb0c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_82 = 0xb0e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_83 = 0xb100;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_84 = 0xb120;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_85 = 0xb140;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_86 = 0xb160;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_87 = 0xb180;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_88 = 0xb1a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_89 = 0xb1c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_90 = 0xb1e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_91 = 0xb200;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_92 = 0xb220;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_93 = 0xb240;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_94 = 0xb260;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_95 = 0xb280;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_96 = 0xb2a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_97 = 0xb2c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_98 = 0xb2e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_99 = 0xb300;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_100 = 0xb320;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_101 = 0xb340;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_102 = 0xb360;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_103 = 0xb380;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_104 = 0xb3a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_105 = 0xb3c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_106 = 0xb3e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_107 = 0xb400;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_108 = 0xb420;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_109 = 0xb440;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_110 = 0xb460;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_111 = 0xb480;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_112 = 0xb4a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_113 = 0xb4c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_114 = 0xb4e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_115 = 0xb500;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_116 = 0xb520;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_117 = 0xb540;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_118 = 0xb560;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_119 = 0xb580;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_120 = 0xb5a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_121 = 0xb5c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_122 = 0xb5e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_123 = 0xb600;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_124 = 0xb620;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_125 = 0xb640;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_126 = 0xb660;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_127 = 0xb680;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_128 = 0xb6a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_129 = 0xb6c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_130 = 0xb6e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_131 = 0xb700;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_132 = 0xb720;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_133 = 0xb740;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_134 = 0xb760;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_135 = 0xb780;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_136 = 0xb7a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_137 = 0xb7c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_138 = 0xb7e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_139 = 0xb800;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_140 = 0xb820;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_141 = 0xb840;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_142 = 0xb860;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_143 = 0xb880;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_144 = 0xb8a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_145 = 0xb8c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_146 = 0xb8e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_147 = 0xb900;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_148 = 0xb920;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_149 = 0xb940;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_150 = 0xb960;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_151 = 0xb980;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_152 = 0xb9a0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_153 = 0xb9c0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_154 = 0xb9e0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_155 = 0xba00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_156 = 0xba20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_157 = 0xba40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_158 = 0xba60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_159 = 0xba80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_160 = 0xbaa0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_161 = 0xbac0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_162 = 0xbae0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_163 = 0xbb00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_164 = 0xbb20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_165 = 0xbb40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_166 = 0xbb60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_167 = 0xbb80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_168 = 0xbba0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_169 = 0xbbc0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_170 = 0xbbe0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_171 = 0xbc00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_172 = 0xbc20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_173 = 0xbc40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_174 = 0xbc60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_175 = 0xbc80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_176 = 0xbca0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_177 = 0xbcc0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_178 = 0xbce0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_179 = 0xbd00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_180 = 0xbd20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_181 = 0xbd40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_182 = 0xbd60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_183 = 0xbd80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_184 = 0xbda0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_185 = 0xbdc0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_186 = 0xbde0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_187 = 0xbe00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_188 = 0xbe20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_189 = 0xbe40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_190 = 0xbe60;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_191 = 0xbe80;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_192 = 0xbea0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_193 = 0xbec0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_194 = 0xbee0;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_195 = 0xbf00;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_196 = 0xbf20;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_197 = 0xbf40;
uint256 internal constant CHALLENGE_POLY_LAGRANGE_BASE_198 = 0xbf60;

uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_0 = 0xbf80;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_1 = 0xbfa0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_2 = 0xbfc0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_3 = 0xbfe0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_4 = 0xc000;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_5 = 0xc020;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_6 = 0xc040;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_7 = 0xc060;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_8 = 0xc080;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_9 = 0xc0a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_10 = 0xc0c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_11 = 0xc0e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_12 = 0xc100;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_13 = 0xc120;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_14 = 0xc140;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_15 = 0xc160;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_16 = 0xc180;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_17 = 0xc1a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_18 = 0xc1c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_19 = 0xc1e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_20 = 0xc200;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_21 = 0xc220;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_22 = 0xc240;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_23 = 0xc260;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_24 = 0xc280;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_25 = 0xc2a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_26 = 0xc2c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_27 = 0xc2e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_28 = 0xc300;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_29 = 0xc320;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_30 = 0xc340;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_31 = 0xc360;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_32 = 0xc380;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_33 = 0xc3a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_34 = 0xc3c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_35 = 0xc3e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_36 = 0xc400;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_37 = 0xc420;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_38 = 0xc440;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_39 = 0xc460;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_40 = 0xc480;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_41 = 0xc4a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_42 = 0xc4c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_43 = 0xc4e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_44 = 0xc500;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_45 = 0xc520;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_46 = 0xc540;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_47 = 0xc560;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_48 = 0xc580;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_49 = 0xc5a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_50 = 0xc5c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_51 = 0xc5e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_52 = 0xc600;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_53 = 0xc620;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_54 = 0xc640;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_55 = 0xc660;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_56 = 0xc680;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_57 = 0xc6a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_58 = 0xc6c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_59 = 0xc6e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_60 = 0xc700;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_61 = 0xc720;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_62 = 0xc740;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_63 = 0xc760;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_64 = 0xc780;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_65 = 0xc7a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_66 = 0xc7c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_67 = 0xc7e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_68 = 0xc800;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_69 = 0xc820;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_70 = 0xc840;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_71 = 0xc860;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_72 = 0xc880;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_73 = 0xc8a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_74 = 0xc8c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_75 = 0xc8e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_76 = 0xc900;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_77 = 0xc920;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_78 = 0xc940;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_79 = 0xc960;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_80 = 0xc980;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_81 = 0xc9a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_82 = 0xc9c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_83 = 0xc9e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_84 = 0xca00;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_85 = 0xca20;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_86 = 0xca40;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_87 = 0xca60;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_88 = 0xca80;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_89 = 0xcaa0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_90 = 0xcac0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_91 = 0xcae0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_92 = 0xcb00;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_93 = 0xcb20;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_94 = 0xcb40;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_95 = 0xcb60;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_96 = 0xcb80;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_97 = 0xcba0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_98 = 0xcbc0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_99 = 0xcbe0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_100 = 0xcc00;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_101 = 0xcc20;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_102 = 0xcc40;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_103 = 0xcc60;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_104 = 0xcc80;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_105 = 0xcca0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_106 = 0xccc0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_107 = 0xcce0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_108 = 0xcd00;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_109 = 0xcd20;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_110 = 0xcd40;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_111 = 0xcd60;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_112 = 0xcd80;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_113 = 0xcda0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_114 = 0xcdc0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_115 = 0xcde0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_116 = 0xce00;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_117 = 0xce20;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_118 = 0xce40;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_119 = 0xce60;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_120 = 0xce80;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_121 = 0xcea0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_122 = 0xcec0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_123 = 0xcee0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_124 = 0xcf00;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_125 = 0xcf20;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_126 = 0xcf40;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_127 = 0xcf60;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_128 = 0xcf80;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_129 = 0xcfa0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_130 = 0xcfc0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_131 = 0xcfe0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_132 = 0xd000;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_133 = 0xd020;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_134 = 0xd040;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_135 = 0xd060;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_136 = 0xd080;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_137 = 0xd0a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_138 = 0xd0c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_139 = 0xd0e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_140 = 0xd100;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_141 = 0xd120;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_142 = 0xd140;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_143 = 0xd160;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_144 = 0xd180;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_145 = 0xd1a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_146 = 0xd1c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_147 = 0xd1e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_148 = 0xd200;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_149 = 0xd220;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_150 = 0xd240;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_151 = 0xd260;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_152 = 0xd280;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_153 = 0xd2a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_154 = 0xd2c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_155 = 0xd2e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_156 = 0xd300;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_157 = 0xd320;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_158 = 0xd340;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_159 = 0xd360;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_160 = 0xd380;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_161 = 0xd3a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_162 = 0xd3c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_163 = 0xd3e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_164 = 0xd400;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_165 = 0xd420;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_166 = 0xd440;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_167 = 0xd460;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_168 = 0xd480;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_169 = 0xd4a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_170 = 0xd4c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_171 = 0xd4e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_172 = 0xd500;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_173 = 0xd520;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_174 = 0xd540;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_175 = 0xd560;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_176 = 0xd580;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_177 = 0xd5a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_178 = 0xd5c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_179 = 0xd5e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_180 = 0xd600;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_181 = 0xd620;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_182 = 0xd640;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_183 = 0xd660;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_184 = 0xd680;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_185 = 0xd6a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_186 = 0xd6c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_187 = 0xd6e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_188 = 0xd700;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_189 = 0xd720;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_190 = 0xd740;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_191 = 0xd760;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_192 = 0xd780;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_193 = 0xd7a0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_194 = 0xd7c0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_195 = 0xd7e0;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_196 = 0xd800;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_197 = 0xd820;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_198 = 0xd840;
uint256 internal constant CONSISTENCY_DENOMINATORS_BASE_199 = 0xd860;

uint256 internal constant CONSISTENCY_PRODUCTS_BASE_0 = 0xd880;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_1 = 0xd8a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_2 = 0xd8c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_3 = 0xd8e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_4 = 0xd900;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_5 = 0xd920;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_6 = 0xd940;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_7 = 0xd960;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_8 = 0xd980;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_9 = 0xd9a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_10 = 0xd9c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_11 = 0xd9e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_12 = 0xda00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_13 = 0xda20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_14 = 0xda40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_15 = 0xda60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_16 = 0xda80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_17 = 0xdaa0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_18 = 0xdac0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_19 = 0xdae0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_20 = 0xdb00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_21 = 0xdb20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_22 = 0xdb40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_23 = 0xdb60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_24 = 0xdb80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_25 = 0xdba0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_26 = 0xdbc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_27 = 0xdbe0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_28 = 0xdc00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_29 = 0xdc20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_30 = 0xdc40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_31 = 0xdc60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_32 = 0xdc80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_33 = 0xdca0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_34 = 0xdcc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_35 = 0xdce0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_36 = 0xdd00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_37 = 0xdd20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_38 = 0xdd40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_39 = 0xdd60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_40 = 0xdd80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_41 = 0xdda0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_42 = 0xddc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_43 = 0xdde0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_44 = 0xde00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_45 = 0xde20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_46 = 0xde40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_47 = 0xde60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_48 = 0xde80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_49 = 0xdea0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_50 = 0xdec0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_51 = 0xdee0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_52 = 0xdf00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_53 = 0xdf20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_54 = 0xdf40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_55 = 0xdf60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_56 = 0xdf80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_57 = 0xdfa0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_58 = 0xdfc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_59 = 0xdfe0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_60 = 0xe000;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_61 = 0xe020;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_62 = 0xe040;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_63 = 0xe060;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_64 = 0xe080;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_65 = 0xe0a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_66 = 0xe0c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_67 = 0xe0e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_68 = 0xe100;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_69 = 0xe120;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_70 = 0xe140;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_71 = 0xe160;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_72 = 0xe180;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_73 = 0xe1a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_74 = 0xe1c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_75 = 0xe1e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_76 = 0xe200;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_77 = 0xe220;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_78 = 0xe240;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_79 = 0xe260;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_80 = 0xe280;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_81 = 0xe2a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_82 = 0xe2c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_83 = 0xe2e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_84 = 0xe300;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_85 = 0xe320;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_86 = 0xe340;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_87 = 0xe360;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_88 = 0xe380;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_89 = 0xe3a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_90 = 0xe3c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_91 = 0xe3e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_92 = 0xe400;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_93 = 0xe420;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_94 = 0xe440;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_95 = 0xe460;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_96 = 0xe480;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_97 = 0xe4a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_98 = 0xe4c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_99 = 0xe4e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_100 = 0xe500;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_101 = 0xe520;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_102 = 0xe540;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_103 = 0xe560;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_104 = 0xe580;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_105 = 0xe5a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_106 = 0xe5c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_107 = 0xe5e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_108 = 0xe600;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_109 = 0xe620;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_110 = 0xe640;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_111 = 0xe660;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_112 = 0xe680;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_113 = 0xe6a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_114 = 0xe6c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_115 = 0xe6e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_116 = 0xe700;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_117 = 0xe720;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_118 = 0xe740;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_119 = 0xe760;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_120 = 0xe780;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_121 = 0xe7a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_122 = 0xe7c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_123 = 0xe7e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_124 = 0xe800;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_125 = 0xe820;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_126 = 0xe840;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_127 = 0xe860;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_128 = 0xe880;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_129 = 0xe8a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_130 = 0xe8c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_131 = 0xe8e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_132 = 0xe900;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_133 = 0xe920;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_134 = 0xe940;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_135 = 0xe960;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_136 = 0xe980;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_137 = 0xe9a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_138 = 0xe9c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_139 = 0xe9e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_140 = 0xea00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_141 = 0xea20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_142 = 0xea40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_143 = 0xea60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_144 = 0xea80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_145 = 0xeaa0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_146 = 0xeac0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_147 = 0xeae0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_148 = 0xeb00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_149 = 0xeb20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_150 = 0xeb40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_151 = 0xeb60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_152 = 0xeb80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_153 = 0xeba0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_154 = 0xebc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_155 = 0xebe0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_156 = 0xec00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_157 = 0xec20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_158 = 0xec40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_159 = 0xec60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_160 = 0xec80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_161 = 0xeca0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_162 = 0xecc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_163 = 0xece0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_164 = 0xed00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_165 = 0xed20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_166 = 0xed40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_167 = 0xed60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_168 = 0xed80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_169 = 0xeda0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_170 = 0xedc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_171 = 0xede0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_172 = 0xee00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_173 = 0xee20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_174 = 0xee40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_175 = 0xee60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_176 = 0xee80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_177 = 0xeea0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_178 = 0xeec0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_179 = 0xeee0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_180 = 0xef00;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_181 = 0xef20;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_182 = 0xef40;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_183 = 0xef60;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_184 = 0xef80;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_185 = 0xefa0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_186 = 0xefc0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_187 = 0xefe0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_188 = 0xf000;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_189 = 0xf020;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_190 = 0xf040;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_191 = 0xf060;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_192 = 0xf080;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_193 = 0xf0a0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_194 = 0xf0c0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_195 = 0xf0e0;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_196 = 0xf100;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_197 = 0xf120;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_198 = 0xf140;
uint256 internal constant CONSISTENCY_PRODUCTS_BASE_199 = 0xf160;

// LIBRA_UNIVARIATES_LENGTH = BATCHED_RELATION_PARTIAL_LENGTH = 9
uint256 internal constant LIBRA_UNIVARIATES_LENGTH = 0x9;
uint256 internal constant LIBRA_UNIVARIATES_LENGTH_MINUS_ONE = 0x8;
// 1/SUBGROUP_SIZE mod p (precomputed constant)
// 1/256 mod p, computed as pow(256, p-2, p) where p = BN254 scalar field modulus
// 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001
uint256 internal constant INV_SUBGROUP_SIZE = 0x3033ea246e506e898e97f570caffd704cb0bb460313fb720b29e139e5c100001;
uint256 internal constant LATER_SCRATCH_SPACE = 0xf180;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                    Temporary space - COMPLETE                                    */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

// Aliases for scratch space
// Scratch space aliases at 0x00-0x40
// Phase 1 (sumcheck rounds): CHALL_POW_LOC, SUMCHECK_U_LOC, GEMINI_A_LOC
// Phase 2 (shplemini batch scalars): SS_POS_INV_DENOM_LOC, SS_NEG_INV_DENOM_LOC, SS_GEMINI_EVALS_LOC
// These phases do not overlap in execution time.
uint256 internal constant CHALL_POW_LOC = 0;
uint256 internal constant SUMCHECK_U_LOC = 0x20;
uint256 internal constant GEMINI_A_LOC = 0x40;

uint256 internal constant SS_POS_INV_DENOM_LOC = 0;
uint256 internal constant SS_NEG_INV_DENOM_LOC = 0x20;
uint256 internal constant SS_GEMINI_EVALS_LOC = 0x40;



/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                                    SUMCHECK - MEMORY ALIASES                                     */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
// {{ SECTION_END MEMORY_LAYOUT }}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 SUMCHECK - MEMORY ALIASES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    uint256 internal constant EC_X_1 = W2_EVAL_LOC;
    uint256 internal constant EC_Y_1 = W3_EVAL_LOC;
    uint256 internal constant EC_X_2 = W1_SHIFT_EVAL_LOC;
    uint256 internal constant EC_Y_2 = W4_SHIFT_EVAL_LOC;
    uint256 internal constant EC_Y_3 = W3_SHIFT_EVAL_LOC;
    uint256 internal constant EC_X_3 = W2_SHIFT_EVAL_LOC;

    // Aliases for selectors (Elliptic curve gadget)
    uint256 internal constant EC_Q_SIGN = QL_EVAL_LOC;
    uint256 internal constant EC_Q_IS_DOUBLE = QM_EVAL_LOC;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTANTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    uint256 internal constant GRUMPKIN_CURVE_B_PARAMETER_NEGATED = 17; // -(-17)

    // Auxiliary relation constants
    // In the Non Native Field Arithmetic Relation, large field elements are broken up into 4 LIMBs of 68 `LIMB_SIZE` bits each.
    uint256 internal constant LIMB_SIZE = 0x100000000000000000; // 2<<68

    // In the Delta Range Check Relation, there is a range checking relation that can validate 14-bit range checks with only 1
    // extra relation in the execution trace.
    // For large range checks, we decompose them into a collection of 14-bit range checks.
    uint256 internal constant SUBLIMB_SHIFT = 0x4000; // 2<<14

    // Poseidon2 internal constants
    // https://github.com/HorizenLabs/poseidon2/blob/main/poseidon2_rust_params.sage - derivation code
    uint256 internal constant POS_INTERNAL_MATRIX_D_0 =
        0x10dc6e9c006ea38b04b1e03b4bd9490c0d03f98929ca1d7fb56821fd19d3b6e7;
    uint256 internal constant POS_INTERNAL_MATRIX_D_1 =
        0x0c28145b6a44df3e0149b3d0a30b3bb599df9756d4dd9b84a86b38cfb45a740b;
    uint256 internal constant POS_INTERNAL_MATRIX_D_2 =
        0x00544b8338791518b2c7645a50392798b21f75bb60e3596170067d00141cac15;
    uint256 internal constant POS_INTERNAL_MATRIX_D_3 =
        0x222c01175718386f2e2e82eb122789e352e105a3b8fa852613bc534433ee428b;

    // Constants inspecting proof components
    uint256 internal constant NUMBER_OF_UNSHIFTED_ENTITIES = 37;
    // Shifted columns are columes that are duplicates of existing columns but right-shifted by 1
    uint256 internal constant NUMBER_OF_SHIFTED_ENTITIES = 5;
    uint256 internal constant TOTAL_NUMBER_OF_ENTITIES = 42;

    // Constants for performing batch multiplication
    uint256 internal constant ACCUMULATOR = 0x00;
    uint256 internal constant ACCUMULATOR_2 = 0x40;
    uint256 internal constant G1_LOCATION = 0x60;
    uint256 internal constant G1_Y_LOCATION = 0x80;
    uint256 internal constant SCALAR_LOCATION = 0xa0;

    uint256 internal constant LOWER_127_MASK = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    // Group order
    uint256 internal constant Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583; // EC group order

    // Field order constants
    // -1/2 mod p
    uint256 internal constant NEG_HALF_MODULO_P = 0x183227397098d014dc2822db40c0ac2e9419f4243cdcb848a1f0fac9f8000000;
    uint256 internal constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant P_SUB_1 = 21888242871839275222246405745257275088548364400416034343698204186575808495616;
    uint256 internal constant P_SUB_2 = 21888242871839275222246405745257275088548364400416034343698204186575808495615;
    uint256 internal constant P_SUB_3 = 21888242871839275222246405745257275088548364400416034343698204186575808495614;

    // Barycentric evaluation constants
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_0 =
        0x0000000000000000000000000000000000000000000000000000000000009d80;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_1 =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffec51;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_2 =
        0x00000000000000000000000000000000000000000000000000000000000005a0;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_3 =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effffd31;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_4 =
        0x0000000000000000000000000000000000000000000000000000000000000240;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_5 =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effffd31;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_6 =
        0x00000000000000000000000000000000000000000000000000000000000005a0;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_7 =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffec51;
    uint256 internal constant BARYCENTRIC_LAGRANGE_DENOMINATOR_8 =
        0x0000000000000000000000000000000000000000000000000000000000009d80;

    // ZK-specific constants
    uint256 internal constant SUBGROUP_SIZE = 256;
    uint256 internal constant SUBGROUP_GENERATOR = 0x07b0c561a6148404f086204a9f36ffb0617942546750f230c893619174a57a76;
    uint256 internal constant SUBGROUP_GENERATOR_INVERSE = 0x204bd3277422fad364751ad938e2b5e6a54cf8c68712848a692c553d0329f5d6;
    uint256 internal constant LIBRA_COMMITMENTS = 3;
    uint256 internal constant LIBRA_EVALUATIONS = 4;
    uint256 internal constant SHIFTED_COMMITMENTS_START = 30;

    // Constants for computing public input delta
    uint256 internal constant PERMUTATION_ARGUMENT_VALUE_SEPARATOR = 1 << 28;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    // The errors match Errors.sol

    bytes4 internal constant VALUE_GE_LIMB_MAX_SELECTOR = 0xeb73e0bd;
    bytes4 internal constant VALUE_GE_GROUP_ORDER_SELECTOR = 0x607be13e;
    bytes4 internal constant VALUE_GE_FIELD_ORDER_SELECTOR = 0x20a33589;
    bytes4 internal constant SUMCHECK_FAILED_SELECTOR = 0x9fc3a218;
    bytes4 internal constant SHPLEMINI_FAILED_SELECTOR = 0xa5d82e8a;

    bytes4 internal constant PROOF_LENGTH_WRONG_WITH_LOG_N_SELECTOR = 0x59895a53;
    bytes4 internal constant PUBLIC_INPUTS_LENGTH_WRONG_SELECTOR = 0xfa066593;

    bytes4 internal constant MODEXP_FAILED_SELECTOR = 0xf442f163;
    bytes4 internal constant CONSISTENCY_CHECK_FAILED_SELECTOR = 0xa2a2ac83;
    bytes4 internal constant GEMINI_CHALLENGE_IN_SUBGROUP_SELECTOR = 0x835eb8f7;

    constructor() {}

    function verify(
        bytes calldata,
        /*proof*/
        bytes32[] calldata /*public_inputs*/
    )
        public
        view
        override
        returns (bool)
    {
        // Load the proof from calldata in one large chunk
        assembly {
            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*                   LOAD VERIFCATION KEY                     */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
            // Write the verification key into memory
            //
            // Although defined at the top of the file, it is used towards the end of the algorithm when batching in the commitment scheme.
            function loadVk() {
                mstore(Q_L_X_LOC, 0x0979e4b999f02ba1fe583342606cd5211ac0b411042eeb376941f07b8f5b5f41)
                mstore(Q_L_Y_LOC, 0x1558443b0a862128ac0bb0c2e84b84c6be12254614b0c4dd9eb6cfceeaf7e9ef)
                mstore(Q_R_X_LOC, 0x12f923ab2a8fd01cf271fc06a75eba8b31270629b1866aa613d7b93a6dcddc4b)
                mstore(Q_R_Y_LOC, 0x0b9fedae646415e620e0c00f11b952065ece79bd140d905d88060d81bf69e46e)
                mstore(Q_O_X_LOC, 0x1bf643be81c15256830f1f53a66d766e93d1ecdd239fcb2acf8ef0ebd67d967e)
                mstore(Q_O_Y_LOC, 0x2c98e8bb020d9bdf756328f1ba292d1c75f4bf7b676f5e8afa3d2a813840413a)
                mstore(Q_4_X_LOC, 0x276d5a27fe318d7d1bfc3f6ba4e19f21969682f68a0e89bc85104545dcfaa022)
                mstore(Q_4_Y_LOC, 0x27ba70e48b8d0064a9e1078e87589c013d7c3181dd974f5e896cba2703ea69b5)
                mstore(Q_M_X_LOC, 0x2894f364e355638dcb6d3effe6157535d2043e85aa5dfd42cf0718e7793c5565)
                mstore(Q_M_Y_LOC, 0x1f312713982d1872cfb22bf75a727db650cff7315f556f56ca4116d900bc78f2)
                mstore(Q_C_X_LOC, 0x1cf805eb1618d178b4d09cd43ef51ab78897668434909d4cb67a40a59fcc490f)
                mstore(Q_C_Y_LOC, 0x00f7b200e5878991af03ee42b3d5a51ab800536bb80941073c01724eeee0fa60)
                mstore(Q_LOOKUP_X_LOC, 0x1c31a0c97a6afe912cbbe506c20a19ccda519a3eba2afe28ab81394aee6bc024)
                mstore(Q_LOOKUP_Y_LOC, 0x23e2d0aa4f15d8452e06cbfb441f0f87137a705f1c15c8c9bd43cca837dfb6fc)
                mstore(Q_ARITH_X_LOC, 0x0b836e2c47143e4c5fcd28831ffad7b602f6d7c3dcdcbd2b45290579fa6d10a3)
                mstore(Q_ARITH_Y_LOC, 0x18f3f3b9bd064377abb850a26401a3ca6f9dca55ff765410abe17f4efcf83369)
                mstore(Q_DELTA_RANGE_X_LOC, 0x2a0845c3c08d4c404274b6d0e4013321ca6aa223c0c459f355af922c5c13d82f)
                mstore(Q_DELTA_RANGE_Y_LOC, 0x17ed501c7a498672203f5c8db7bf52c4e83182fb6224e6c509ab4541c86088f9)
                mstore(Q_ELLIPTIC_X_LOC, 0x0000000000000000000000000000000000000000000000000000000000000000)
                mstore(Q_ELLIPTIC_Y_LOC, 0x0000000000000000000000000000000000000000000000000000000000000000)
                mstore(Q_MEMORY_X_LOC, 0x274ae2431a6f2530745852c4d16f6d371b144bd8b2237721b0e990b5c408de34)
                mstore(Q_MEMORY_Y_LOC, 0x036ff3a822750252d39a68009eac357e878c15ff3f1f15ad19f2f4e27e2c7fde)
                mstore(Q_NNF_X_LOC, 0x0000000000000000000000000000000000000000000000000000000000000000)
                mstore(Q_NNF_Y_LOC, 0x0000000000000000000000000000000000000000000000000000000000000000)
                mstore(Q_POSEIDON_2_EXTERNAL_X_LOC, 0x290b75c7544b7cbed9ed28097027b2d26929425645eccacd17bf6de6cb0e2224)
                mstore(Q_POSEIDON_2_EXTERNAL_Y_LOC, 0x03326e03b216bd117ea9dd32c57ef023d8079637d852d0be6c76a4fc6b3d64b3)
                mstore(Q_POSEIDON_2_INTERNAL_X_LOC, 0x0249c7ec228696dfe9d4021e5f5995f935e0e0d40ca44022f73ce87548eecbe6)
                mstore(Q_POSEIDON_2_INTERNAL_Y_LOC, 0x153773f0d787788061a54ad4a694e523d07d10cca5e2cbb5d2f804a40514d1e8)
                mstore(SIGMA_1_X_LOC, 0x15e776bb3c5d65229180eeb7ab1e975311906b8f3aed6f4ffa5377ca136eb5ac)
                mstore(SIGMA_1_Y_LOC, 0x020ff3ad68154a74e3e915dc2c732d80db4bf271d2e855fc6ad6b2da22a5564b)
                mstore(SIGMA_2_X_LOC, 0x2a1a4bd162a0ff17238ca20befea38235d5ce8626593f977768676cec9bf027d)
                mstore(SIGMA_2_Y_LOC, 0x05c51a22652761d23be4e7cfb856d28f79a5fd3987dc15cb3eeaae2787af5c60)
                mstore(SIGMA_3_X_LOC, 0x04fd4a05559d8b0c7846ccabfcc06fad48c5dca10bca60613055f2ec42901302)
                mstore(SIGMA_3_Y_LOC, 0x077bdbcfeb184faf868f61ab53659ccb4dcdff2cb38bca785313b59a3659a0bf)
                mstore(SIGMA_4_X_LOC, 0x2f7503b116742b20b741ab84d038db2135fdbbe665af0e1fb31bd2d0c9c23e7b)
                mstore(SIGMA_4_Y_LOC, 0x0fe4c70485cd3e7bbfcfb9c7484bb9c8f06322b3200bf4c55f1a684af525a18e)
                mstore(TABLE_1_X_LOC, 0x294eebddbec5bea3d72a7c41f5c55ceb908c1084b64342e1cd178982884bea15)
                mstore(TABLE_1_Y_LOC, 0x254787e8b243c23529e327c8ef889c7d2f796c313bfa3e31188ed0865202f288)
                mstore(TABLE_2_X_LOC, 0x1352bedf7ff8b7680fcf2f154d6d19630785daae63e6ce1443c0a2f4761f8d2b)
                mstore(TABLE_2_Y_LOC, 0x042f1710c2f7e19193c8f12a21d16cc03335c93466a7810422c4e6e73e68d1e4)
                mstore(TABLE_3_X_LOC, 0x10b90a3a56235c5cb60333f7329dca7db3a27a3b5838a654db33688789a0b6b1)
                mstore(TABLE_3_Y_LOC, 0x06d4519107bb976a2f8e1e94ddba6b960ebc9d57616d18ff952337366fbedddb)
                mstore(TABLE_4_X_LOC, 0x07232d5febbd2d8aa350270a79d5b5d52d0c16dda9751782bbe94829a233825e)
                mstore(TABLE_4_Y_LOC, 0x1f82b86f9d9703757501caad462205b82b21263f0981a1692581bbcc26ceff37)
                mstore(ID_1_X_LOC, 0x2308834f135eb9d72d13fdba83bd81bb6bf59ec06f50b96473825febd82e7273)
                mstore(ID_1_Y_LOC, 0x2b45138e7d19098d731ccfcef4a70efe9df67b13587d10f4b6ff54e5c36d1e2a)
                mstore(ID_2_X_LOC, 0x19a6fd6a3ffbad84ae1579b57f2aa451ef7e30ff3d4072235017de9832b486ab)
                mstore(ID_2_Y_LOC, 0x1717a8aba763544e0ca9f3df8390f01d4a5974459c3996445c51974f3126a279)
                mstore(ID_3_X_LOC, 0x0f6e95ebf78da4e014d98c6fb117b392bb75983815b25a09e7d02d80f5e72771)
                mstore(ID_3_Y_LOC, 0x0e05a4c8b76331a3bd26335eb408c47ec637cc172ee00565717d1c2ac624d8f6)
                mstore(ID_4_X_LOC, 0x21d4a7d1f8c9201ba4879c1310d7c0c031477f24b1dc21c19427f7240ef5c5e9)
                mstore(ID_4_Y_LOC, 0x1ea3bea4a1563e1874a9af557a82b5024d479e4dabf838d38e6f9712ced8bf0d)
                mstore(LAGRANGE_FIRST_X_LOC, 0x2a56ce41f6b0be13b9c26747621b821eee81b23a887f299049b14c11e98460d6)
                mstore(LAGRANGE_FIRST_Y_LOC, 0x1aa98f2de3ddda547d8f6de4e725ded5827d6338c78656c0d12ca1aea6ef2c7c)
                mstore(LAGRANGE_LAST_X_LOC, 0x246cfd36dc01e94b6ade6cf97f2561afbafcf4a3e780ee95d8026484215977a0)
                mstore(LAGRANGE_LAST_Y_LOC, 0x0553407f8885a85372c4fd21e70574a1cbf0fb0617c7d9d9e3d3b370cf2e87a9)
            }

            // Prime field order - placing on the stack
            let p := P

            {
                let proof_ptr := add(calldataload(0x04), 0x24)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*              VALIDATE INPUT LENGTHS                      */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // Validate proof byte length matches expected size for this circuit's LOG_N (ZK variant).
                // ZK proof has: 9 witness G1 (18) + 3 libra G1 (6) + LOG_N*9 univariates + 42 evals
                //   + 2 (libraSum,libraEval) + LOG_N gemini evals + 4 libra poly evals
                //   + (LOG_N-1)*2 gemini fold G1 + 2*2 (shplonkQ,kzg) + 8 pairing = (82 + 12*LOG_N) * 32
                {
                    let expected_proof_size := mul(
                        add(
                            add(
                                add(24, mul(LOG_N, BATCHED_RELATION_PARTIAL_LENGTH)),
                                add(add(NUMBER_OF_ENTITIES, 2), mul(sub(LOG_N, 1), 2))
                            ),
                            add(add(LOG_N, LIBRA_EVALUATIONS), add(4, PAIRING_POINTS_SIZE))
                        ),
                        32
                    )
                    let proof_length := calldataload(add(calldataload(0x04), 0x04))
                    if iszero(eq(proof_length, expected_proof_size)) {
                        mstore(0x00, PROOF_LENGTH_WRONG_WITH_LOG_N_SELECTOR)
                        mstore(0x04, LOG_N)
                        mstore(0x24, proof_length)
                        mstore(0x44, expected_proof_size)
                        revert(0x00, 0x64)
                    }
                }
                // Validate public inputs array length matches expected count.
                {
                    let pi_count := calldataload(add(calldataload(0x24), 0x04))
                    if iszero(eq(pi_count, REAL_NUMBER_PUBLIC_INPUTS)) {
                        mstore(0x00, PUBLIC_INPUTS_LENGTH_WRONG_SELECTOR)
                        revert(0x00, 0x04)
                    }
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                    GENERATE CHALLENGES                     */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                /*
                 * Proof points (affine coordinates) in the proof are in the following format, where offset is
                 * the offset in the entire proof until the first bit of the x coordinate
                 * offset + 0x00: x
                 * offset + 0x20: y
                 */

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                   GENERATE ETA CHALLENGE                   */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                /* ZK Eta challenge participants
                 * - VK_HASH
                 * - public inputs
                 * - pairing point limbs (8)
                 * - geminiMaskingPoly (G1) <- ZK addition
                 * - w1, w2, w3 (G1)
                 */

                mstore(0x00, VK_HASH)

                let public_inputs_start := add(calldataload(0x24), 0x24)
                let public_inputs_size := mul(REAL_NUMBER_PUBLIC_INPUTS, 0x20)

                // Copy the public inputs into the eta buffer
                calldatacopy(0x20, public_inputs_start, public_inputs_size)

                // Copy Pairing points into eta buffer
                let public_inputs_end := add(0x20, public_inputs_size)

                calldatacopy(public_inputs_end, proof_ptr, 0x100)

                // 0x20 * 8 = 0x100 (8 pairing point limbs)
                // End of public inputs + pairing points
                // ZK: Copy geminiMaskingPoly(0x40) + w1,w2,w3(0xC0) = 0x100 bytes from proof after pairing
                calldatacopy(add(0x120, public_inputs_size), add(proof_ptr, 0x100), 0x100)

                // 0x220 = 0x20 (VK_HASH) + 0x100 (pairing) + 0x40 (geminiMaskingPoly) + 0xC0 (w1,w2,w3)
                let eta_input_length := add(0x220, public_inputs_size)

                // Get single eta challenge and compute powers (eta, eta², eta³)
                let prev_challenge := mod(keccak256(0x00, eta_input_length), p)
                mstore(0x00, prev_challenge)

                let eta := and(prev_challenge, LOWER_127_MASK)
                let eta_two := mulmod(eta, eta, p)
                let eta_three := mulmod(eta_two, eta, p)

                mstore(ETA_CHALLENGE, eta)
                mstore(ETA_TWO_CHALLENGE, eta_two)
                mstore(ETA_THREE_CHALLENGE, eta_three)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                  LOAD PROOF INTO MEMORY                    */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // As all of our proof points are written in contiguous parts of memory, we call use a single
                // calldatacopy to place all of our proof into the correct memory regions
                // We copy the entire proof into memory as we must hash each proof section for challenge
                // evaluation
                // The last item in the proof, and the first item in the proof (pairing point 0)
                let proof_size := sub(ETA_CHALLENGE, PAIRING_POINT_0_X_0_LOC)

                calldatacopy(PAIRING_POINT_0_X_0_LOC, proof_ptr, proof_size)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*               VALIDATE PROOF INPUTS                      */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // Validate all proof elements are within their expected ranges.
                // Pairing limbs: lo < 2^136, hi < 2^120. G1 coordinates < Q. Fr elements < P.
                {
                    let valid := true
                    let lo_limb_max := shl(136, 1)
                    let hi_limb_max := shl(120, 1)
                    let q_mod := Q

                    // 1. Pairing limbs: lo < 2^136, hi < 2^120 (4 pairs, stride 0x40)
                    let ptr := PAIRING_POINT_0_X_0_LOC
                    for {} lt(ptr, GEMINI_MASKING_POLY_X_LOC) { ptr := add(ptr, 0x40) } {
                        valid := and(valid, lt(mload(ptr), lo_limb_max))
                        valid := and(valid, lt(mload(add(ptr, 0x20)), hi_limb_max))
                    }
                    if iszero(valid) {
                        mstore(0x00, VALUE_GE_LIMB_MAX_SELECTOR)
                        revert(0x00, 0x04)
                    }

                    // 2. G1 coordinates: each < Q
                    //    - geminiMaskingPoly + witness commitments + libraConcat (20 slots)
                    for { ptr := GEMINI_MASKING_POLY_X_LOC } lt(ptr, LIBRA_SUM_LOC) { ptr := add(ptr, 0x20) } {
                        valid := and(valid, lt(mload(ptr), q_mod))
                    }
                    //    - Libra grand product + quotient (4 slots)
                    for { ptr := LIBRA_GRAND_PRODUCT_X_LOC } lt(ptr, GEMINI_FOLD_UNIVARIATE_0_X_LOC) {
                        ptr := add(ptr, 0x20)
                    } {
                        valid := and(valid, lt(mload(ptr), q_mod))
                    }
                    //    - Gemini fold commitments (28 slots)
                    for { ptr := GEMINI_FOLD_UNIVARIATE_0_X_LOC } lt(ptr, GEMINI_A_EVAL_0) { ptr := add(ptr, 0x20) } {
                        valid := and(valid, lt(mload(ptr), q_mod))
                    }
                    //    - Shplonk Q + KZG quotient (4 slots)
                    for { ptr := SHPLONK_Q_X_LOC } lt(ptr, ETA_CHALLENGE) { ptr := add(ptr, 0x20) } {
                        valid := and(valid, lt(mload(ptr), q_mod))
                    }
                    if iszero(valid) {
                        mstore(0x00, VALUE_GE_GROUP_ORDER_SELECTOR)
                        revert(0x00, 0x04)
                    }

                    // 2b. G1 points: identity (0,0) is accepted.
                    //     Polynomial commitments to identically-zero polynomials are
                    //     legitimately the identity, and the ecAdd/ecMul precompiles
                    //     treat (0,0) as the additive identity per EIP-196. Soundness
                    //     against (0,0) substitution for a non-zero commitment is upheld
                    //     by sumcheck/Shplemini downstream.

                    // 3. Fr elements: each < P
                    //    - libraSum + sumcheck univariates + evals + libraEvaluation (179 slots)
                    for { ptr := LIBRA_SUM_LOC } lt(ptr, LIBRA_GRAND_PRODUCT_X_LOC) {
                        ptr := add(ptr, 0x20)
                    } {
                        valid := and(valid, lt(mload(ptr), p))
                    }
                    //    - Gemini evaluations + libra poly evals (19 slots)
                    for { ptr := GEMINI_A_EVAL_0 } lt(ptr, SHPLONK_Q_X_LOC) { ptr := add(ptr, 0x20) } {
                        valid := and(valid, lt(mload(ptr), p))
                    }
                    if iszero(valid) {
                        mstore(0x00, VALUE_GE_FIELD_ORDER_SELECTOR)
                        revert(0x00, 0x04)
                    }
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*             GENERATE BETA and GAMMAA  CHALLENGE            */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

                // Generate Beta and Gamma Chalenges
                // - prevChallenge
                // - LOOKUP_READ_COUNTS
                // - LOOKUP_READ_TAGS
                // - W4
                mcopy(0x20, LOOKUP_READ_COUNTS_X_LOC, 0xc0)

                prev_challenge := mod(keccak256(0x00, 0xe0), p)
                mstore(0x00, prev_challenge)
                let beta := and(prev_challenge, LOWER_127_MASK)
                let gamma := shr(127, prev_challenge)

                mstore(BETA_CHALLENGE, beta)
                mstore(GAMMA_CHALLENGE, gamma)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                      ALPHA CHALLENGES                      */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // Generate Alpha challenges - non-linearise the gate contributions
                //
                // There are 26 total subrelations in this honk relation, we do not need to non linearise the first sub relation.
                // There are 25 total gate contributions, a gate contribution is analogous to
                // a custom gate, it is an expression which must evaluate to zero for each
                // row in the constraint matrix
                //
                // If we do not non-linearise sub relations, then sub relations which rely
                // on the same wire will interact with each other's sums.

                mcopy(0x20, LOOKUP_INVERSES_X_LOC, 0x80)

                // Generate single alpha challenge and compute its powers
                prev_challenge := mod(keccak256(0x00, 0xa0), p)
                mstore(0x00, prev_challenge)
                let alpha := and(prev_challenge, LOWER_127_MASK)
                mstore(ALPHA_CHALLENGE_0, alpha)

                // Compute powers of alpha: alpha^2, alpha^3, ..., alpha^27
                let alpha_off_set := ALPHA_CHALLENGE_1
                for {} lt(alpha_off_set, add(ALPHA_CHALLENGE_27, 0x20)) {} {
                    let prev_alpha := mload(sub(alpha_off_set, 0x20))
                    mstore(alpha_off_set, mulmod(prev_alpha, alpha, p))
                    alpha_off_set := add(alpha_off_set, 0x20)
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                       GATE CHALLENGES                      */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

                // Store the first gate challenge
                prev_challenge := mod(keccak256(0x00, 0x20), p)
                mstore(0x00, prev_challenge)
                let gate_challenge := and(prev_challenge, LOWER_127_MASK)
                mstore(GATE_CHALLENGE_0, gate_challenge)

                let gate_off := GATE_CHALLENGE_1
                for {} lt(gate_off, LIBRA_CHALLENGE) {} {
                    let prev := mload(sub(gate_off, 0x20))

                    mstore(gate_off, mulmod(prev, prev, p))
                    gate_off := add(gate_off, 0x20)
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                     LIBRA CHALLENGE                          */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // Generate Libra challenge: hash(prevChallenge, libraConcat.x, libraConcat.y, libraSum)
                // libraConcat (0x40) + libraSum (0x20) = 0x60 bytes of proof data
                mcopy(0x20, LIBRA_CONCAT_X_LOC, 0x60)

                prev_challenge := mod(keccak256(0x00, 0x80), p)
                mstore(0x00, prev_challenge)
                let libraChallenge := and(prev_challenge, LOWER_127_MASK)
                mstore(LIBRA_CHALLENGE, libraChallenge)

                // Sumcheck Univariate challenges (ZK variant)
                // The algebraic relations of the Honk protocol are max degree-7.
                // To prove satifiability, we multiply the relation by a random (POW) polynomial + masking.
                // As a result, in every round of sumcheck, the prover sends a degree-9 univariate polynomial.
                // 9 points are sent as it is enough to uniquely identify the polynomial.
                let read_off := SUMCHECK_UNIVARIATE_0_0_LOC
                let write_off := SUM_U_CHALLENGE_0
                for {} lt(read_off, GEMINI_MASKING_EVAL_LOC) {} {
                    // 0x20 * 9 = 0x120 bytes per round
                    mcopy(0x20, read_off, 0x120)

                    // Hash 0x120 + 0x20 (prev hash) = 0x140
                    prev_challenge := mod(keccak256(0x00, 0x140), p)
                    mstore(0x00, prev_challenge)

                    let sumcheck_u_challenge := and(prev_challenge, LOWER_127_MASK)
                    mstore(write_off, sumcheck_u_challenge)

                    // Progress read / write pointers
                    read_off := add(read_off, 0x120)
                    write_off := add(write_off, 0x20)
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                        RHO CHALLENGES                      */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // The RHO challenge is the hash of the evaluations of all of the wire values
                // As per usual, it includes the previous challenge
                // Evaluations of the following wires and their shifts (for relevant wires):
                // - QM
                // - QC
                // - Q1 (QL)
                // - Q2 (QR)
                // - Q3 (QO)
                // - Q4
                // - QLOOKUP
                // - QARITH
                // - QRANGE
                // - QELLIPTIC
                // - QMEMORY
                // - QNNF (NNF = Non Native Field)
                // - QPOSEIDON2_EXTERNAL
                // - QPOSEIDON2_INTERNAL
                // - SIGMA1
                // - SIGMA2
                // - SIGMA3
                // - SIGMA4
                // - ID1
                // - ID2
                // - ID3
                // - ID4
                // - TABLE1
                // - TABLE2
                // - TABLE3
                // - TABLE4
                // - W1 (WL)
                // - W2 (WR)
                // - W3 (WO)
                // - W4
                // - Z_PERM
                // - LOOKUP_INVERSES
                // - LOOKUP_READ_COUNTS
                // - LOOKUP_READ_TAGS
                // - W1_SHIFT
                // - W2_SHIFT
                // - W3_SHIFT
                // - W4_SHIFT
                // - Z_PERM_SHIFT
                //
                // Hash all evaluations + libraEvaluation + 2 libra commitments (G1)
                // ZK: 42 evals (GEMINI_MASKING_EVAL through Z_PERM_SHIFT) + libraEval + libraGrandProduct(G1) + libraQuotient(G1)
                // = 42*0x20 + 0x20 + 2*0x40 = 0x5e0 bytes
                mcopy(0x20, GEMINI_MASKING_EVAL_LOC, 0x5e0)
                prev_challenge := mod(keccak256(0x00, 0x600), p)
                mstore(0x00, prev_challenge)

                let rho := and(prev_challenge, LOWER_127_MASK)

                mstore(RHO_CHALLENGE, rho)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                      GEMINI R CHALLENGE                    */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // The Gemini R challenge contains a of all of commitments to all of the univariates
                // evaluated in the Gemini Protocol
                // So for multivariate polynomials in l variables, we will hash l - 1 commitments.
                // For this implementation, we have logN number of of rounds and thus logN - 1 committments
                // The format of these commitments are proof points, which are explained above
                // 0x40 * (logN - 1)

                mcopy(0x20, GEMINI_FOLD_UNIVARIATE_0_X_LOC, 0x540)

                prev_challenge := mod(keccak256(0x00, 0x560), p)
                mstore(0x00, prev_challenge)

                let geminiR := and(prev_challenge, LOWER_127_MASK)

                mstore(GEMINI_R_CHALLENGE, geminiR)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                    SHPLONK NU CHALLENGE                    */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // The shplonk nu challenge hashes gemini A evaluations + libra poly evaluations
                // ZK: 0x20 * (logN + 4) = 0x20 * 19 = 0x260

                mcopy(0x20, GEMINI_A_EVAL_0, 0x340)
                prev_challenge := mod(keccak256(0x00, 0x360), p)
                mstore(0x00, prev_challenge)

                let shplonkNu := and(prev_challenge, LOWER_127_MASK)
                mstore(SHPLONK_NU_CHALLENGE, shplonkNu)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                    SHPLONK Z CHALLENGE                    */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // Generate Shplonk Z
                // Hash of the single shplonk Q commitment
                mcopy(0x20, SHPLONK_Q_X_LOC, 0x40)
                prev_challenge := mod(keccak256(0x00, 0x60), p)

                let shplonkZ := and(prev_challenge, LOWER_127_MASK)
                mstore(SHPLONK_Z_CHALLENGE, shplonkZ)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                     CHALLENGES COMPLETE                    */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
            }

            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*                     PUBLIC INPUT DELTA                     */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
            /**
             * Generate public inputs delta
             *
             * The public inputs delta leverages plonk's copy constraints in order to
             * evaluate public inputs.
             *
             * For each row of the execution trace, the prover will calculate the following value
             * There are 4 witness wires, 4 id wires and 4 sigma wires in this instantiation of the proof system
             * So there will be 4 groups of wires (w_i, id_i and sigma_i)
             *
             *   (w_0 + β(id_0) + γ) * ∏(w_1 + β(id_1) + γ) * ∏(w_2 + β(id_2) + γ) * ∏(w_3 + β(id_3) + γ)
             * ∏------------------------------------------------------------------------------------------ * public_inputs_delta
             *   (w_0 + β(σ_0) + γ) * ∏(w_1 + β(σ_1) + γ) * ∏(w_2 + β(σ_2) + γ) * ∏(w_3 + β(σ_3) + γ)
             *
             * The above product is accumulated for all rows in the trace.
             *
             * The above equation enforces that for each cell in the trace, if the id and sigma pair are equal, then the
             * witness value in that cell is equal.
             *
             * We extra terms to add to this product that correspond to public input values.
             *
             * The values of id_i and σ_i polynomials are related to a generalized PLONK permutation argument, in the original paper, there
             * were no id_i polynomials.
             *
             * These are required under the multilinear setting as we cannot use cosets of the roots of unity to represent unique sets, rather
             * we just use polynomials that include unique values. In implementation, id_0 can be {0 .. n} and id_1 can be {n .. 2n} and so forth.
             *
             */
            {
                let beta := mload(BETA_CHALLENGE)
                let gamma := mload(GAMMA_CHALLENGE)
                let pub_off := PUBLIC_INPUTS_OFFSET

                let numerator_value := 1
                let denominator_value := 1

                let p_clone := p // move p to the front of the stack

                // Assume offset is less than p
                // numerator_acc = gamma + (beta * (PERMUTATION_ARGUMENT_VALUE_SEPARATOR + offset))
                let numerator_acc :=
                    addmod(gamma, mulmod(beta, add(PERMUTATION_ARGUMENT_VALUE_SEPARATOR, pub_off), p_clone), p_clone)
                // demonimator_acc = gamma - (beta * (offset + 1))
                let beta_x_off := mulmod(beta, add(pub_off, 1), p_clone)
                let denominator_acc := addmod(gamma, sub(p_clone, beta_x_off), p_clone)

                let valid_inputs := true
                // Load the starting point of the public inputs (jump over the selector and the length of public inputs [0x24])
                let public_inputs_ptr := add(calldataload(0x24), 0x24)

                // endpoint_ptr = public_inputs_ptr + num_inputs * 0x20. // every public input is 0x20 bytes
                let endpoint_ptr := add(public_inputs_ptr, mul(REAL_NUMBER_PUBLIC_INPUTS, 0x20))

                for {} lt(public_inputs_ptr, endpoint_ptr) { public_inputs_ptr := add(public_inputs_ptr, 0x20) } {
                    // Get public inputs from calldata
                    let input := calldataload(public_inputs_ptr)

                    valid_inputs := and(valid_inputs, lt(input, p_clone))

                    numerator_value := mulmod(numerator_value, addmod(numerator_acc, input, p_clone), p_clone)
                    denominator_value := mulmod(denominator_value, addmod(denominator_acc, input, p_clone), p_clone)

                    numerator_acc := addmod(numerator_acc, beta, p_clone)
                    denominator_acc := addmod(denominator_acc, sub(p_clone, beta), p_clone)
                }

                // Revert if not all public inputs are field elements (i.e. < p)
                if iszero(valid_inputs) {
                    mstore(0x00, VALUE_GE_FIELD_ORDER_SELECTOR)
                    revert(0x00, 0x04)
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*           PUBLIC INPUT DELTA - Pairing points accum        */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // Pairing points contribution to public inputs delta
                let pairing_points_ptr := PAIRING_POINT_0_X_0_LOC
                for {} lt(pairing_points_ptr, GEMINI_MASKING_POLY_X_LOC) { pairing_points_ptr := add(pairing_points_ptr, 0x20) } {
                    let input := mload(pairing_points_ptr)

                    numerator_value := mulmod(numerator_value, addmod(numerator_acc, input, p_clone), p_clone)
                    denominator_value := mulmod(denominator_value, addmod(denominator_acc, input, p_clone), p_clone)

                    numerator_acc := addmod(numerator_acc, beta, p_clone)
                    denominator_acc := addmod(denominator_acc, sub(p_clone, beta), p_clone)
                }

                mstore(PUBLIC_INPUTS_DELTA_NUMERATOR_CHALLENGE, numerator_value)
                mstore(PUBLIC_INPUTS_DELTA_DENOMINATOR_CHALLENGE, denominator_value)

                // PI delta denominator inversion is deferred to the barycentric
                // batch inversion below.
            }
            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*             PUBLIC INPUT DELTA - complete                  */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*                        SUMCHECK                            */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
            //
            // Sumcheck is used to prove that every relation 0 on each row of the witness.
            //
            // Given each of the columns of our trace is a multilinear polynomial 𝑃1,…,𝑃𝑁∈𝔽[𝑋0,…,𝑋𝑑−1]. We run sumcheck over the polynomial
            //
            //                         𝐹̃ (𝑋0,…,𝑋𝑑−1)=𝑝𝑜𝑤𝛽(𝑋0,…,𝑋𝑑−1)⋅𝐹(𝑃1(𝑋0,…,𝑋𝑑−1),…,𝑃𝑁(𝑋0,…,𝑋𝑑−1))
            //
            // The Pow polynomial is a random polynomial that allows us to ceritify that the relations sum to 0 on each row of the witness,
            // rather than the entire sum just targeting 0.
            //
            // Each polynomial P in our implementation are the polys in the proof and the verification key. (W_1, W_2, W_3, W_4, Z_PERM, etc....)
            //
            // We start with a LOG_N variate multilinear polynomial, each round fixes a variable to a challenge value.
            // Each round the prover sends a round univariate poly, since the degree of our honk relations is 7 + the pow polynomial the prover
            // sends a degree-8 univariate on each round.
            // This is sent efficiently by sending 8 values, enough to represent a unique polynomial.
            // Barycentric evaluation is used to evaluate the polynomial at any point on the domain, given these 8 unique points.
            //
            // In the sumcheck protocol, the target sum for each round is the sum of the round univariate evaluated on 0 and 1.
            //                                               𝜎𝑖=?𝑆̃ 𝑖(0)+𝑆̃ 𝑖(1)
            // This is efficiently checked as S(0) and S(1) are sent by the prover as values of the round univariate.
            //
            // We compute the next challenge by evaluating the round univariate at a random challenge value.
            //                                                  𝜎𝑖+1←𝑆̃ 𝑖(𝑢𝑖)
            // This evaluation is performed via barycentric evaluation.
            //
            // Once we have reduced the multilinear polynomials into single dimensional polys, we check the entire sumcheck relation matches the target sum.
            //
            // Below this is composed of 8 relations:
            // 1. Arithmetic relation - constrains arithmetic
            // 2. Permutaiton Relation - efficiently encodes copy constraints
            // 3. Log Derivative Lookup Relation - used for lookup operations
            // 4. Delta Range Relation - used for efficient range checks
            // 5. Memory Relation - used for efficient memory operations
            // 6. NNF Relation - used for efficient Non Native Field operations
            // 7. Poseidon2 External Relation - used for efficient in-circuit hashing
            // 8. Poseidon2 Internal Relation - used for efficient in-circuit hashing
            //
            // These are batched together and evaluated at the same time using the alpha challenges.
            //
            {
                // We write the barycentric domain values into memory
                // These are written once per program execution, and reused across all
                // sumcheck rounds
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_0_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_0)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_1_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_1)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_2_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_2)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_3_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_3)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_4_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_4)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_5_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_5)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_6_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_6)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_7_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_7)
                mstore(BARYCENTRIC_LAGRANGE_DENOMINATOR_8_LOC, BARYCENTRIC_LAGRANGE_DENOMINATOR_8)

                // Compute the target sums for each round of sumcheck
                {
                    // This requires the barycentric inverses to be computed for each round
                    // Write all of the non inverted barycentric denominators into memory
                    let accumulator := 1
                    let temp := FOLD_POS_EVALUATIONS_21_LOC // we use fold pos evaluations as we add 0x20 immediately to the pointer to get `BARYCENTRIC_TEMP_0_LOC`
                    let bary_centric_inverses_off := BARYCENTRIC_DENOMINATOR_INVERSES_0_0_LOC
                    {
                        let round_challenge_off := SUM_U_CHALLENGE_0
                        for { let round := 0 } lt(round, LOG_N) { round := add(round, 1) } {
                            let round_challenge := mload(round_challenge_off)
                            let bary_lagrange_denominator_off := BARYCENTRIC_LAGRANGE_DENOMINATOR_0_LOC

                            // Unrolled as this loop only has 9 iterations (ZK)
                            {
                                let bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                let pre_inv :=
                                    mulmod(
                                        bary_lagrange_denominator,
                                        addmod(round_challenge, p, p), // sub(p, 0) = p
                                        p
                                    )
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 1
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 1), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 2
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 2), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 3
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 3), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 4
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 4), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 5
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 5), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 6
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 6), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 7
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 7), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)

                                // barycentric_index = 8 (ZK)
                                bary_lagrange_denominator := mload(bary_lagrange_denominator_off)
                                pre_inv := mulmod(bary_lagrange_denominator, addmod(round_challenge, sub(p, 8), p), p)
                                mstore(bary_centric_inverses_off, pre_inv)
                                temp := add(temp, 0x20)
                                mstore(temp, accumulator)
                                accumulator := mulmod(accumulator, pre_inv, p)

                                // increase offsets
                                bary_lagrange_denominator_off := add(bary_lagrange_denominator_off, 0x20)
                                bary_centric_inverses_off := add(bary_centric_inverses_off, 0x20)
                            }
                            round_challenge_off := add(round_challenge_off, 0x20)
                        }
                    }

                    // Append PI delta denominator to the batch inversion
                    {
                        let pi_denom := mload(PUBLIC_INPUTS_DELTA_DENOMINATOR_CHALLENGE)
                        mstore(PUBLIC_INPUTS_DENOM_TEMP_LOC, accumulator)
                        accumulator := mulmod(accumulator, pi_denom, p)
                    }

                    // --- Phase 2: Shplemini forward pass ---
                    // Compute shplemini denominators and accumulate into the running product.
                    // Pre-inversion values stored at designated addresses (0x6800+),
                    // which don't overlap with barycentric storage.
                    {
                        // Compute powers of evaluation challenge: gemini_r^{2^i}
                        let cache := mload(GEMINI_R_CHALLENGE)
                        mstore(POWERS_OF_EVALUATION_CHALLENGE_0_LOC, cache)
                        /// {{ UNROLL_SECTION_START POWERS_OF_EVALUATION_COMPUTATION }}
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_1_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_2_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_3_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_4_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_5_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_6_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_7_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_8_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_9_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_10_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_11_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_12_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_13_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_14_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_15_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_16_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_17_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_18_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_19_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_20_LOC, cache)
                   cache := mulmod(cache, cache, p)
                   mstore(POWERS_OF_EVALUATION_CHALLENGE_21_LOC, cache)
/// {{ UNROLL_SECTION_END POWERS_OF_EVALUATION_COMPUTATION }}

                        // Element 0: gemini_r (seed)
                        {
                            let val := mload(GEMINI_R_CHALLENGE)
                            mstore(GEMINI_R_INV_TEMP_LOC, accumulator)
                            accumulator := mulmod(accumulator, val, p)
                        }

                        // Append Libra Subgroup Denominator calculation to batch inversion
                        {
                            let val := addmod(
                                mload(SHPLONK_Z_CHALLENGE),
                                sub(p, mulmod(SUBGROUP_GENERATOR, mload(GEMINI_R_CHALLENGE), p)),
                                p
                            )
                            mstore(LIBRA_SUBGROUP_DENOM_LOC, val)
                            mstore(LIBRA_SUBGROUP_DENOM_TEMP_LOC, accumulator)
                            accumulator := mulmod(accumulator, val, p)
                        }

                        // Elements 1..LOG_N: INVERTED_CHALLENGE_POW_MINUS_U
                        // Elements LOG_N+1..2*LOG_N: POS_INVERTED_DENOM
                        // Elements 2*LOG_N+1..3*LOG_N: NEG_INVERTED_DENOM
                        /// {{ UNROLL_SECTION_START ACCUMULATE_INVERSES }}
                       // INVERTED_CHALLENGE_POW_MINUS_U_0
                       {
                           let u := mload(SUM_U_CHALLENGE_0)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_0_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_0_LOC, val)
                           mstore(TEMP_0_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_1
                       {
                           let u := mload(SUM_U_CHALLENGE_1)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_1_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_1_LOC, val)
                           mstore(TEMP_1_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_2
                       {
                           let u := mload(SUM_U_CHALLENGE_2)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_2_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_2_LOC, val)
                           mstore(TEMP_2_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_3
                       {
                           let u := mload(SUM_U_CHALLENGE_3)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_3_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_3_LOC, val)
                           mstore(TEMP_3_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_4
                       {
                           let u := mload(SUM_U_CHALLENGE_4)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_4_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_4_LOC, val)
                           mstore(TEMP_4_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_5
                       {
                           let u := mload(SUM_U_CHALLENGE_5)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_5_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_5_LOC, val)
                           mstore(TEMP_5_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_6
                       {
                           let u := mload(SUM_U_CHALLENGE_6)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_6_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_6_LOC, val)
                           mstore(TEMP_6_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_7
                       {
                           let u := mload(SUM_U_CHALLENGE_7)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_7_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_7_LOC, val)
                           mstore(TEMP_7_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_8
                       {
                           let u := mload(SUM_U_CHALLENGE_8)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_8_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_8_LOC, val)
                           mstore(TEMP_8_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_9
                       {
                           let u := mload(SUM_U_CHALLENGE_9)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_9_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_9_LOC, val)
                           mstore(TEMP_9_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_10
                       {
                           let u := mload(SUM_U_CHALLENGE_10)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_10_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_10_LOC, val)
                           mstore(TEMP_10_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_11
                       {
                           let u := mload(SUM_U_CHALLENGE_11)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_11_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_11_LOC, val)
                           mstore(TEMP_11_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_12
                       {
                           let u := mload(SUM_U_CHALLENGE_12)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_12_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_12_LOC, val)
                           mstore(TEMP_12_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_13
                       {
                           let u := mload(SUM_U_CHALLENGE_13)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_13_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_13_LOC, val)
                           mstore(TEMP_13_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_14
                       {
                           let u := mload(SUM_U_CHALLENGE_14)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_14_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_14_LOC, val)
                           mstore(TEMP_14_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_15
                       {
                           let u := mload(SUM_U_CHALLENGE_15)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_15_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_15_LOC, val)
                           mstore(TEMP_15_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_16
                       {
                           let u := mload(SUM_U_CHALLENGE_16)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_16_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_16_LOC, val)
                           mstore(TEMP_16_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_17
                       {
                           let u := mload(SUM_U_CHALLENGE_17)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_17_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_17_LOC, val)
                           mstore(TEMP_17_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_18
                       {
                           let u := mload(SUM_U_CHALLENGE_18)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_18_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_18_LOC, val)
                           mstore(TEMP_18_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_19
                       {
                           let u := mload(SUM_U_CHALLENGE_19)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_19_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_19_LOC, val)
                           mstore(TEMP_19_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_20
                       {
                           let u := mload(SUM_U_CHALLENGE_20)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_20_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_20_LOC, val)
                           mstore(TEMP_20_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       // INVERTED_CHALLENGE_POW_MINUS_U_21
                       {
                           let u := mload(SUM_U_CHALLENGE_21)
                           let challPow := mload(POWERS_OF_EVALUATION_CHALLENGE_21_LOC)
                           let val := addmod(mulmod(challPow, addmod(1, sub(p, u), p), p), u, p)
                           mstore(INVERTED_CHALLENGE_POW_MINUS_U_21_LOC, val)
                           mstore(TEMP_21_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }

                     // Accumulate pos inverted denom
                       // Elements LOG_N+1..2*LOG_N: POS_INVERTED_DENOM
                       let eval_challenge := mload(SHPLONK_Z_CHALLENGE)
                    // POS_INVERTED_DENOM_0
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_0_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_0_LOC, val)
                        mstore(TEMP_22_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_1
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_1_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_1_LOC, val)
                        mstore(TEMP_23_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_2
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_2_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_2_LOC, val)
                        mstore(TEMP_24_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_3
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_3_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_3_LOC, val)
                        mstore(TEMP_25_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_4
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_4_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_4_LOC, val)
                        mstore(TEMP_26_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_5
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_5_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_5_LOC, val)
                        mstore(TEMP_27_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_6
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_6_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_6_LOC, val)
                        mstore(TEMP_28_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_7
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_7_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_7_LOC, val)
                        mstore(TEMP_29_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_8
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_8_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_8_LOC, val)
                        mstore(TEMP_30_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_9
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_9_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_9_LOC, val)
                        mstore(TEMP_31_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_10
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_10_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_10_LOC, val)
                        mstore(TEMP_32_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_11
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_11_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_11_LOC, val)
                        mstore(TEMP_33_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_12
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_12_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_12_LOC, val)
                        mstore(TEMP_34_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_13
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_13_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_13_LOC, val)
                        mstore(TEMP_35_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_14
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_14_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_14_LOC, val)
                        mstore(TEMP_36_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_15
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_15_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_15_LOC, val)
                        mstore(TEMP_37_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_16
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_16_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_16_LOC, val)
                        mstore(TEMP_38_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_17
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_17_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_17_LOC, val)
                        mstore(TEMP_39_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_18
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_18_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_18_LOC, val)
                        mstore(TEMP_40_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_19
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_19_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_19_LOC, val)
                        mstore(TEMP_41_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_20
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_20_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_20_LOC, val)
                        mstore(TEMP_42_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }
                    // POS_INVERTED_DENOM_21
                    {
                        let val := addmod(eval_challenge, sub(p, mload(POWERS_OF_EVALUATION_CHALLENGE_21_LOC))        , p)
                        mstore(POS_INVERTED_DENOM_21_LOC, val)
                        mstore(TEMP_43_LOC, accumulator)
                        accumulator := mulmod(accumulator, val, p)
                    }

                     // Accumulate neg inverted denom
                       // Elements 2*LOG_N+1..3*LOG_N: NEG_INVERTED_DENOM
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_0_LOC), p)
                           mstore(NEG_INVERTED_DENOM_0_LOC, val)
                           mstore(TEMP_44_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_1_LOC), p)
                           mstore(NEG_INVERTED_DENOM_1_LOC, val)
                           mstore(TEMP_45_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_2_LOC), p)
                           mstore(NEG_INVERTED_DENOM_2_LOC, val)
                           mstore(TEMP_46_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_3_LOC), p)
                           mstore(NEG_INVERTED_DENOM_3_LOC, val)
                           mstore(TEMP_47_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_4_LOC), p)
                           mstore(NEG_INVERTED_DENOM_4_LOC, val)
                           mstore(TEMP_48_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_5_LOC), p)
                           mstore(NEG_INVERTED_DENOM_5_LOC, val)
                           mstore(TEMP_49_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_6_LOC), p)
                           mstore(NEG_INVERTED_DENOM_6_LOC, val)
                           mstore(TEMP_50_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_7_LOC), p)
                           mstore(NEG_INVERTED_DENOM_7_LOC, val)
                           mstore(TEMP_51_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_8_LOC), p)
                           mstore(NEG_INVERTED_DENOM_8_LOC, val)
                           mstore(TEMP_52_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_9_LOC), p)
                           mstore(NEG_INVERTED_DENOM_9_LOC, val)
                           mstore(TEMP_53_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_10_LOC), p)
                           mstore(NEG_INVERTED_DENOM_10_LOC, val)
                           mstore(TEMP_54_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_11_LOC), p)
                           mstore(NEG_INVERTED_DENOM_11_LOC, val)
                           mstore(TEMP_55_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_12_LOC), p)
                           mstore(NEG_INVERTED_DENOM_12_LOC, val)
                           mstore(TEMP_56_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_13_LOC), p)
                           mstore(NEG_INVERTED_DENOM_13_LOC, val)
                           mstore(TEMP_57_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_14_LOC), p)
                           mstore(NEG_INVERTED_DENOM_14_LOC, val)
                           mstore(TEMP_58_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_15_LOC), p)
                           mstore(NEG_INVERTED_DENOM_15_LOC, val)
                           mstore(TEMP_59_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_16_LOC), p)
                           mstore(NEG_INVERTED_DENOM_16_LOC, val)
                           mstore(TEMP_60_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_17_LOC), p)
                           mstore(NEG_INVERTED_DENOM_17_LOC, val)
                           mstore(TEMP_61_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_18_LOC), p)
                           mstore(NEG_INVERTED_DENOM_18_LOC, val)
                           mstore(TEMP_62_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_19_LOC), p)
                           mstore(NEG_INVERTED_DENOM_19_LOC, val)
                           mstore(TEMP_63_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_20_LOC), p)
                           mstore(NEG_INVERTED_DENOM_20_LOC, val)
                           mstore(TEMP_64_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
                       {
                           let val := addmod(eval_challenge, mload(POWERS_OF_EVALUATION_CHALLENGE_21_LOC), p)
                           mstore(NEG_INVERTED_DENOM_21_LOC, val)
                           mstore(TEMP_65_LOC, accumulator)
                           accumulator := mulmod(accumulator, val, p)
                       }
/// {{ UNROLL_SECTION_END ACCUMULATE_INVERSES }}
                    }

                    // Invert all elements (barycentric + PI delta + shplemini) as a single batch
                    {
                        {
                            mstore(0, 0x20)
                            mstore(0x20, 0x20)
                            mstore(0x40, 0x20)
                            mstore(0x60, accumulator)
                            mstore(0x80, P_SUB_2)
                            mstore(0xa0, p)
                            if iszero(staticcall(gas(), 0x05, 0x00, 0xc0, 0x00, 0x20)) {
                                mstore(0x00, MODEXP_FAILED_SELECTOR)
                                revert(0x00, 0x04)
                            }
                            accumulator := mload(0x00)
                            if iszero(accumulator) {
                                mstore(0x00, MODEXP_FAILED_SELECTOR)
                                revert(0x00, 0x04)
                            }
                        }

                        // --- Shplemini backward pass ---
                        // Extract shplemini inverses in strict reverse order.
                        {
                        /// {{ UNROLL_SECTION_START COLLECT_INVERSES }}
                       // i = 22
                       // NEG_INVERTED_DENOM (LOG_N elements, reverse) -- last group appended
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_65_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_21_LOC), p)
                           mstore(NEG_INVERTED_DENOM_21_LOC, tmp)
                   }
            // i = 21
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_64_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_20_LOC), p)
                           mstore(NEG_INVERTED_DENOM_20_LOC, tmp)
                   }
            // i = 20
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_63_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_19_LOC), p)
                           mstore(NEG_INVERTED_DENOM_19_LOC, tmp)
                   }
            // i = 19
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_62_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_18_LOC), p)
                           mstore(NEG_INVERTED_DENOM_18_LOC, tmp)
                   }
            // i = 18
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_61_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_17_LOC), p)
                           mstore(NEG_INVERTED_DENOM_17_LOC, tmp)
                   }
            // i = 17
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_60_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_16_LOC), p)
                           mstore(NEG_INVERTED_DENOM_16_LOC, tmp)
                   }
            // i = 16
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_59_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_15_LOC), p)
                           mstore(NEG_INVERTED_DENOM_15_LOC, tmp)
                   }
            // i = 15
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_58_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_14_LOC), p)
                           mstore(NEG_INVERTED_DENOM_14_LOC, tmp)
                   }
            // i = 14
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_57_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_13_LOC), p)
                           mstore(NEG_INVERTED_DENOM_13_LOC, tmp)
                   }
            // i = 13
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_56_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_12_LOC), p)
                           mstore(NEG_INVERTED_DENOM_12_LOC, tmp)
                   }
            // i = 12
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_55_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_11_LOC), p)
                           mstore(NEG_INVERTED_DENOM_11_LOC, tmp)
                   }
            // i = 11
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_54_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_10_LOC), p)
                           mstore(NEG_INVERTED_DENOM_10_LOC, tmp)
                   }
            // i = 10
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_53_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_9_LOC), p)
                           mstore(NEG_INVERTED_DENOM_9_LOC, tmp)
                   }
            // i = 9
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_52_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_8_LOC), p)
                           mstore(NEG_INVERTED_DENOM_8_LOC, tmp)
                   }
            // i = 8
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_51_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_7_LOC), p)
                           mstore(NEG_INVERTED_DENOM_7_LOC, tmp)
                   }
            // i = 7
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_50_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_6_LOC), p)
                           mstore(NEG_INVERTED_DENOM_6_LOC, tmp)
                   }
            // i = 6
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_49_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_5_LOC), p)
                           mstore(NEG_INVERTED_DENOM_5_LOC, tmp)
                   }
            // i = 5
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_48_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_4_LOC), p)
                           mstore(NEG_INVERTED_DENOM_4_LOC, tmp)
                   }
            // i = 4
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_47_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_3_LOC), p)
                           mstore(NEG_INVERTED_DENOM_3_LOC, tmp)
                   }
            // i = 3
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_46_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_2_LOC), p)
                           mstore(NEG_INVERTED_DENOM_2_LOC, tmp)
                   }
            // i = 2
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_45_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_1_LOC), p)
                           mstore(NEG_INVERTED_DENOM_1_LOC, tmp)
                   }
            // i = 1
                       {
                           let tmp := mulmod(accumulator, mload(TEMP_44_LOC), p)
                           accumulator := mulmod(accumulator, mload(NEG_INVERTED_DENOM_0_LOC), p)
                           mstore(NEG_INVERTED_DENOM_0_LOC, tmp)
                   }

            // Unrolled for LOG_N = 22
            // i = 22
            {
                let tmp := mulmod(accumulator, mload(TEMP_43_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_21_LOC), p)
                mstore(POS_INVERTED_DENOM_21_LOC, tmp)
            }
            // i = 21
            {
                let tmp := mulmod(accumulator, mload(TEMP_42_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_20_LOC), p)
                mstore(POS_INVERTED_DENOM_20_LOC, tmp)
            }
            // i = 20
            {
                let tmp := mulmod(accumulator, mload(TEMP_41_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_19_LOC), p)
                mstore(POS_INVERTED_DENOM_19_LOC, tmp)
            }
            // i = 19
            {
                let tmp := mulmod(accumulator, mload(TEMP_40_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_18_LOC), p)
                mstore(POS_INVERTED_DENOM_18_LOC, tmp)
            }
            // i = 18
            {
                let tmp := mulmod(accumulator, mload(TEMP_39_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_17_LOC), p)
                mstore(POS_INVERTED_DENOM_17_LOC, tmp)
            }
            // i = 17
            {
                let tmp := mulmod(accumulator, mload(TEMP_38_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_16_LOC), p)
                mstore(POS_INVERTED_DENOM_16_LOC, tmp)
            }
            // i = 16
            {
                let tmp := mulmod(accumulator, mload(TEMP_37_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_15_LOC), p)
                mstore(POS_INVERTED_DENOM_15_LOC, tmp)
            }
            // i = 15
            {
                let tmp := mulmod(accumulator, mload(TEMP_36_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_14_LOC), p)
                mstore(POS_INVERTED_DENOM_14_LOC, tmp)
            }
            // i = 14
            {
                let tmp := mulmod(accumulator, mload(TEMP_35_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_13_LOC), p)
                mstore(POS_INVERTED_DENOM_13_LOC, tmp)
            }
            // i = 13
            {
                let tmp := mulmod(accumulator, mload(TEMP_34_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_12_LOC), p)
                mstore(POS_INVERTED_DENOM_12_LOC, tmp)
            }
            // i = 12
            {
                let tmp := mulmod(accumulator, mload(TEMP_33_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_11_LOC), p)
                mstore(POS_INVERTED_DENOM_11_LOC, tmp)
            }
            // i = 11
            {
                let tmp := mulmod(accumulator, mload(TEMP_32_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_10_LOC), p)
                mstore(POS_INVERTED_DENOM_10_LOC, tmp)
            }
            // i = 10
            {
                let tmp := mulmod(accumulator, mload(TEMP_31_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_9_LOC), p)
                mstore(POS_INVERTED_DENOM_9_LOC, tmp)
            }
            // i = 9
            {
                let tmp := mulmod(accumulator, mload(TEMP_30_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_8_LOC), p)
                mstore(POS_INVERTED_DENOM_8_LOC, tmp)
            }
            // i = 8
            {
                let tmp := mulmod(accumulator, mload(TEMP_29_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_7_LOC), p)
                mstore(POS_INVERTED_DENOM_7_LOC, tmp)
            }
            // i = 7
            {
                let tmp := mulmod(accumulator, mload(TEMP_28_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_6_LOC), p)
                mstore(POS_INVERTED_DENOM_6_LOC, tmp)
            }
            // i = 6
            {
                let tmp := mulmod(accumulator, mload(TEMP_27_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_5_LOC), p)
                mstore(POS_INVERTED_DENOM_5_LOC, tmp)
            }
            // i = 5
            {
                let tmp := mulmod(accumulator, mload(TEMP_26_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_4_LOC), p)
                mstore(POS_INVERTED_DENOM_4_LOC, tmp)
            }
            // i = 4
            {
                let tmp := mulmod(accumulator, mload(TEMP_25_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_3_LOC), p)
                mstore(POS_INVERTED_DENOM_3_LOC, tmp)
            }
            // i = 3
            {
                let tmp := mulmod(accumulator, mload(TEMP_24_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_2_LOC), p)
                mstore(POS_INVERTED_DENOM_2_LOC, tmp)
            }
            // i = 2
            {
                let tmp := mulmod(accumulator, mload(TEMP_23_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_1_LOC), p)
                mstore(POS_INVERTED_DENOM_1_LOC, tmp)
            }
            // i = 1
            {
                let tmp := mulmod(accumulator, mload(TEMP_22_LOC), p)
                accumulator := mulmod(accumulator, mload(POS_INVERTED_DENOM_0_LOC), p)
                mstore(POS_INVERTED_DENOM_0_LOC, tmp)
            }

            // i = 22
            {
                let tmp := mulmod(accumulator, mload(TEMP_21_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_21_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_21_LOC, tmp)
            }
            // i = 21
            {
                let tmp := mulmod(accumulator, mload(TEMP_20_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_20_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_20_LOC, tmp)
            }
            // i = 20
            {
                let tmp := mulmod(accumulator, mload(TEMP_19_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_19_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_19_LOC, tmp)
            }
            // i = 19
            {
                let tmp := mulmod(accumulator, mload(TEMP_18_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_18_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_18_LOC, tmp)
            }
            // i = 18
            {
                let tmp := mulmod(accumulator, mload(TEMP_17_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_17_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_17_LOC, tmp)
            }
            // i = 17
            {
                let tmp := mulmod(accumulator, mload(TEMP_16_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_16_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_16_LOC, tmp)
            }
            // i = 16
            {
                let tmp := mulmod(accumulator, mload(TEMP_15_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_15_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_15_LOC, tmp)
            }
            // i = 15
            {
                let tmp := mulmod(accumulator, mload(TEMP_14_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_14_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_14_LOC, tmp)
            }
            // i = 14
            {
                let tmp := mulmod(accumulator, mload(TEMP_13_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_13_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_13_LOC, tmp)
            }
            // i = 13
            {
                let tmp := mulmod(accumulator, mload(TEMP_12_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_12_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_12_LOC, tmp)
            }
            // i = 12
            {
                let tmp := mulmod(accumulator, mload(TEMP_11_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_11_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_11_LOC, tmp)
            }
            // i = 11
            {
                let tmp := mulmod(accumulator, mload(TEMP_10_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_10_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_10_LOC, tmp)
            }
            // i = 10
            {
                let tmp := mulmod(accumulator, mload(TEMP_9_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_9_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_9_LOC, tmp)
            }
            // i = 9
            {
                let tmp := mulmod(accumulator, mload(TEMP_8_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_8_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_8_LOC, tmp)
            }
            // i = 8
            {
                let tmp := mulmod(accumulator, mload(TEMP_7_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_7_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_7_LOC, tmp)
            }
            // i = 7
            {
                let tmp := mulmod(accumulator, mload(TEMP_6_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_6_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_6_LOC, tmp)
            }
            // i = 6
            {
                let tmp := mulmod(accumulator, mload(TEMP_5_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_5_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_5_LOC, tmp)
            }
            // i = 5
            {
                let tmp := mulmod(accumulator, mload(TEMP_4_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_4_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_4_LOC, tmp)
            }
            // i = 4
            {
                let tmp := mulmod(accumulator, mload(TEMP_3_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_3_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_3_LOC, tmp)
            }
            // i = 3
            {
                let tmp := mulmod(accumulator, mload(TEMP_2_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_2_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_2_LOC, tmp)
            }
            // i = 2
            {
                let tmp := mulmod(accumulator, mload(TEMP_1_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_1_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_1_LOC, tmp)
            }
            // i = 1
            {
                let tmp := mulmod(accumulator, mload(TEMP_0_LOC), p)
                accumulator := mulmod(accumulator, mload(INVERTED_CHALLENGE_POW_MINUS_U_0_LOC), p)
                mstore(INVERTED_CHALLENGE_POW_MINUS_U_0_LOC, tmp)
            }
/// {{ UNROLL_SECTION_END COLLECT_INVERSES }}

                            // libra subgroup denom
                            {
                                let tmp := mulmod(accumulator, mload(LIBRA_SUBGROUP_DENOM_TEMP_LOC), p)
                                accumulator := mulmod(accumulator, mload(LIBRA_SUBGROUP_DENOM_LOC), p)
                                mstore(LIBRA_SUBGROUP_DENOM_LOC, tmp)
                            }

                            // gemini_r inverse
                            {
                                let tmp := mulmod(accumulator, mload(GEMINI_R_INV_TEMP_LOC), p)
                                accumulator := mulmod(accumulator, mload(GEMINI_R_CHALLENGE), p)
                                mstore(GEMINI_R_INV_LOC, tmp)
                            }
                        }

                        // Extract PI delta denominator inverse from the batch
                        {
                            let pi_delta_inv := mulmod(accumulator, mload(PUBLIC_INPUTS_DENOM_TEMP_LOC), p)
                            accumulator := mulmod(accumulator, mload(PUBLIC_INPUTS_DELTA_DENOMINATOR_CHALLENGE), p)

                            // Finalize: public_inputs_delta = numerator * (1/denominator)
                            mstore(
                                PUBLIC_INPUTS_DELTA_NUMERATOR_CHALLENGE,
                                mulmod(mload(PUBLIC_INPUTS_DELTA_NUMERATOR_CHALLENGE), pi_delta_inv, p)
                            )
                        }

                        // Normalise as last loop will have incremented the offset
                        bary_centric_inverses_off := sub(bary_centric_inverses_off, 0x20)
                        for {} gt(bary_centric_inverses_off, BARYCENTRIC_LAGRANGE_DENOMINATOR_8_LOC) {
                            bary_centric_inverses_off := sub(bary_centric_inverses_off, 0x20)
                        } {
                            let tmp := mulmod(accumulator, mload(temp), p)
                            accumulator := mulmod(accumulator, mload(bary_centric_inverses_off), p)
                            mstore(bary_centric_inverses_off, tmp)

                            temp := sub(temp, 0x20)
                        }
                    }
                }

                let valid := true
                // ZK: initial round target = libraChallenge * libraSum
                let round_target := mulmod(mload(LIBRA_CHALLENGE), mload(LIBRA_SUM_LOC), p)
                let pow_partial_evaluation := 1
                let gate_challenge_off := GATE_CHALLENGE_0
                let round_univariates_off := SUMCHECK_UNIVARIATE_0_0_LOC

                let challenge_off := SUM_U_CHALLENGE_0
                let bary_inverses_off := BARYCENTRIC_DENOMINATOR_INVERSES_0_0_LOC

                for { let round := 0 } lt(round, LOG_N) { round := add(round, 1) } {
                    let round_challenge := mload(challenge_off)

                    // Total sum = u[0] + u[1]
                    let total_sum := addmod(mload(round_univariates_off), mload(add(round_univariates_off, 0x20)), p)
                    valid := and(valid, eq(total_sum, round_target))

                    // Compute next target sum (ZK: 9-element domain)
                    let numerator_value := round_challenge
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 1), p), p)
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 2), p), p)
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 3), p), p)
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 4), p), p)
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 5), p), p)
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 6), p), p)
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 7), p), p)
                    numerator_value := mulmod(numerator_value, addmod(round_challenge, sub(p, 8), p), p)

                    // // Compute the next round target
                    round_target := 0
                    for { let i := 0 } lt(i, BATCHED_RELATION_PARTIAL_LENGTH) { i := add(i, 1) } {
                        let term := mload(round_univariates_off)
                        let inverse := mload(bary_inverses_off)

                        term := mulmod(term, inverse, p)
                        round_target := addmod(round_target, term, p)
                        round_univariates_off := add(round_univariates_off, 0x20)
                        bary_inverses_off := add(bary_inverses_off, 0x20)
                    }

                    round_target := mulmod(round_target, numerator_value, p)

                    // Partially evaluate POW
                    let gate_challenge := mload(gate_challenge_off)
                    let gate_challenge_minus_one := sub(gate_challenge, 1)

                    let univariate_evaluation := addmod(1, mulmod(round_challenge, gate_challenge_minus_one, p), p)

                    pow_partial_evaluation := mulmod(pow_partial_evaluation, univariate_evaluation, p)

                    gate_challenge_off := add(gate_challenge_off, 0x20)
                    challenge_off := add(challenge_off, 0x20)
                }

                if iszero(valid) {
                    mstore(0x00, SUMCHECK_FAILED_SELECTOR)
                    revert(0x00, 0x04)
                }

                // The final sumcheck round; accumulating evaluations
                // Uses pow partial evaluation as the gate scaling factor

                mstore(POW_PARTIAL_EVALUATION_LOC, pow_partial_evaluation)
                mstore(FINAL_ROUND_TARGET_LOC, round_target)

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                        LOGUP RELATION                      */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                {
                    /**
                     * The basic arithmetic gate identity in standard plonk is as follows.
                     * (w_1 . w_2 . q_m) + (w_1 . q_1) + (w_2 . q_2) + (w_3 . q_3) + (w_4 . q_4) + q_c = 0
                     * However, for Ultraplonk, we extend this to support "passing" wires between rows (shown without alpha scaling below):
                     * q_arith * ( ( (-1/2) * (q_arith - 3) * q_m * w_1 * w_2 + q_1 * w_1 + q_2 * w_2 + q_3 * w_3 + q_4 * w_4 + q_c ) +
                     * (q_arith - 1)*( α * (q_arith - 2) * (w_1 + w_4 - w_1_omega + q_m) + w_4_omega) ) = 0
                     *
                     * This formula results in several cases depending on q_arith:
                     * 1. q_arith == 0: Arithmetic gate is completely disabled
                     *
                     * 2. q_arith == 1: Everything in the minigate on the right is disabled. The equation is just a standard plonk equation
                     * with extra wires: q_m * w_1 * w_2 + q_1 * w_1 + q_2 * w_2 + q_3 * w_3 + q_4 * w_4 + q_c = 0
                     *
                     * 3. q_arith == 2: The (w_1 + w_4 - ...) term is disabled. THe equation is:
                     * (1/2) * q_m * w_1 * w_2 + q_1 * w_1 + q_2 * w_2 + q_3 * w_3 + q_4 * w_4 + q_c + w_4_omega = 0
                     * It allows defining w_4 at next index (w_4_omega) in terms of current wire values
                     *
                     * 4. q_arith == 3: The product of w_1 and w_2 is disabled, but a mini addition gate is enabled. α allows us to split
                     * the equation into two:
                     *
                     * q_1 * w_1 + q_2 * w_2 + q_3 * w_3 + q_4 * w_4 + q_c + 2 * w_4_omega = 0
                     * and
                     * w_1 + w_4 - w_1_omega + q_m = 0  (we are reusing q_m here)
                     *
                     * 5. q_arith > 3: The product of w_1 and w_2 is scaled by (q_arith - 3), while the w_4_omega term is scaled by (q_arith - 1).
                     * The equation can be split into two:
                     *
                     * (q_arith - 3)* q_m * w_1 * w_ 2 + q_1 * w_1 + q_2 * w_2 + q_3 * w_3 + q_4 * w_4 + q_c + (q_arith - 1) * w_4_omega = 0
                     * and
                     * w_1 + w_4 - w_1_omega + q_m = 0
                     *
                     * The problem that q_m is used both in both equations can be dealt with by appropriately changing selector values at
                     * the next gate. Then we can treat (q_arith - 1) as a simulated q_6 selector and scale q_m to handle (q_arith - 3) at
                     * product.
                     */
                    let w1q1 := mulmod(mload(W1_EVAL_LOC), mload(QL_EVAL_LOC), p)
                    let w2q2 := mulmod(mload(W2_EVAL_LOC), mload(QR_EVAL_LOC), p)
                    let w3q3 := mulmod(mload(W3_EVAL_LOC), mload(QO_EVAL_LOC), p)
                    let w4q3 := mulmod(mload(W4_EVAL_LOC), mload(Q4_EVAL_LOC), p)

                    let q_arith := mload(QARITH_EVAL_LOC)
                    // w1w2qm := (w_1 . w_2 . q_m . (QARITH_EVAL_LOC - 3)) / 2
                    let w1w2qm :=
                        mulmod(
                            mulmod(
                                mulmod(mulmod(mload(W1_EVAL_LOC), mload(W2_EVAL_LOC), p), mload(QM_EVAL_LOC), p),
                                addmod(q_arith, P_SUB_3, p),
                                p
                            ),
                            NEG_HALF_MODULO_P,
                            p
                        )

                    // (w_1 . w_2 . q_m . (q_arith - 3)) / -2) + (w_1 . q_1) + (w_2 . q_2) + (w_3 . q_3) + (w_4 . q_4) + q_c
                    let identity :=
                        addmod(
                            mload(QC_EVAL_LOC),
                            addmod(w4q3, addmod(w3q3, addmod(w2q2, addmod(w1q1, w1w2qm, p), p), p), p),
                            p
                        )

                    // if q_arith == 3 we evaluate an additional mini addition gate (on top of the regular one), where:
                    // w_1 + w_4 - w_1_omega + q_m = 0
                    // we use this gate to save an addition gate when adding or subtracting non-native field elements
                    // α * (q_arith - 2) * (w_1 + w_4 - w_1_omega + q_m)
                    let extra_small_addition_gate_identity :=
                        mulmod(
                            addmod(q_arith, P_SUB_2, p),
                            addmod(
                                mload(QM_EVAL_LOC),
                                addmod(
                                    sub(p, mload(W1_SHIFT_EVAL_LOC)),
                                    addmod(mload(W1_EVAL_LOC), mload(W4_EVAL_LOC), p),
                                    p
                                ),
                                p
                            ),
                            p
                        )

                    // Split up the two relations
                    let contribution_0 :=
                        addmod(identity, mulmod(addmod(q_arith, P_SUB_1, p), mload(W4_SHIFT_EVAL_LOC), p), p)
                    contribution_0 := mulmod(mulmod(contribution_0, q_arith, p), mload(POW_PARTIAL_EVALUATION_LOC), p)
                    mstore(SUBRELATION_EVAL_6_LOC, contribution_0)

                    let contribution_1 := mulmod(extra_small_addition_gate_identity, addmod(q_arith, P_SUB_1, p), p)
                    contribution_1 := mulmod(contribution_1, q_arith, p)
                    contribution_1 := mulmod(contribution_1, mload(POW_PARTIAL_EVALUATION_LOC), p)
                    mstore(SUBRELATION_EVAL_7_LOC, contribution_1)
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                   PERMUTATION RELATION                     */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                {
                    let beta := mload(BETA_CHALLENGE)
                    let gamma := mload(GAMMA_CHALLENGE)

                    /**
                     * t1 = (W1 + gamma + beta * ID1) * (W2 + gamma + beta * ID2)
                     * t2 = (W3 + gamma + beta * ID3) * (W4 + gamma + beta * ID4)
                     * gp_numerator = t1 * t2
                     * t1 = (W1 + gamma + beta * sigma_1_eval) * (W2 + gamma + beta * sigma_2_eval)
                     * t2 = (W2 + gamma + beta * sigma_3_eval) * (W3 + gamma + beta * sigma_4_eval)
                     * gp_denominator = t1 * t2
                     */
                    let t1 :=
                        mulmod(
                            add(add(mload(W1_EVAL_LOC), gamma), mulmod(beta, mload(ID1_EVAL_LOC), p)),
                            add(add(mload(W2_EVAL_LOC), gamma), mulmod(beta, mload(ID2_EVAL_LOC), p)),
                            p
                        )
                    let t2 :=
                        mulmod(
                            add(add(mload(W3_EVAL_LOC), gamma), mulmod(beta, mload(ID3_EVAL_LOC), p)),
                            add(add(mload(W4_EVAL_LOC), gamma), mulmod(beta, mload(ID4_EVAL_LOC), p)),
                            p
                        )
                    let numerator := mulmod(t1, t2, p)
                    t1 := mulmod(
                        add(add(mload(W1_EVAL_LOC), gamma), mulmod(beta, mload(SIGMA1_EVAL_LOC), p)),
                        add(add(mload(W2_EVAL_LOC), gamma), mulmod(beta, mload(SIGMA2_EVAL_LOC), p)),
                        p
                    )
                    t2 := mulmod(
                        add(add(mload(W3_EVAL_LOC), gamma), mulmod(beta, mload(SIGMA3_EVAL_LOC), p)),
                        add(add(mload(W4_EVAL_LOC), gamma), mulmod(beta, mload(SIGMA4_EVAL_LOC), p)),
                        p
                    )
                    let denominator := mulmod(t1, t2, p)

                    {
                        let acc :=
                            mulmod(addmod(mload(Z_PERM_EVAL_LOC), mload(LAGRANGE_FIRST_EVAL_LOC), p), numerator, p)

                        acc := addmod(
                            acc,
                            sub(
                                p,
                                mulmod(
                                    addmod(
                                        mload(Z_PERM_SHIFT_EVAL_LOC),
                                        mulmod(
                                            mload(LAGRANGE_LAST_EVAL_LOC),
                                            mload(PUBLIC_INPUTS_DELTA_NUMERATOR_CHALLENGE),
                                            p
                                        ),
                                        p
                                    ),
                                    denominator,
                                    p
                                )
                            ),
                            p
                        )

                        acc := mulmod(acc, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        mstore(SUBRELATION_EVAL_0_LOC, acc)

                        acc := mulmod(
                            mulmod(mload(LAGRANGE_LAST_EVAL_LOC), mload(Z_PERM_SHIFT_EVAL_LOC), p),
                            mload(POW_PARTIAL_EVALUATION_LOC),
                            p
                        )
                        mstore(SUBRELATION_EVAL_1_LOC, acc)


                        // zperm initialization (lagrange_first * z_perm = 0)
                        acc := mulmod(
                            mulmod(
                                mload(LAGRANGE_FIRST_EVAL_LOC),
                                mload(Z_PERM_EVAL_LOC),
                                p),
                            mload(POW_PARTIAL_EVALUATION_LOC),
                            p)
                        mstore(SUBRELATION_EVAL_2_LOC, acc)
                    }
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                   LOGUP WIDGET EVALUATION                  */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                // Note: Using beta powers for column batching and gamma for offset ensures soundness
                // beta and gamma must be independent challenges (they come from splitting the same hash)
                {
                    let gamma := mload(GAMMA_CHALLENGE)
                    let beta := mload(BETA_CHALLENGE)
                    // Compute beta powers inline (β², β³) for lookup column batching
                    let beta_sqr := mulmod(beta, beta, p)
                    let beta_cube := mulmod(beta_sqr, beta, p)

                    // table_term = table_1 + γ + table_2 * β + table_3 * β² + table_4 * β³
                    let t0 :=
                        addmod(addmod(mload(TABLE1_EVAL_LOC), gamma, p), mulmod(mload(TABLE2_EVAL_LOC), beta, p), p)
                    let t1 :=
                        addmod(
                            mulmod(mload(TABLE3_EVAL_LOC), beta_sqr, p),
                            mulmod(mload(TABLE4_EVAL_LOC), beta_cube, p),
                            p
                        )
                    let table_term := addmod(t0, t1, p)

                    // lookup_term = derived_entry_1 + γ + derived_entry_2 * β + derived_entry_3 * β² + q_index * β³
                    t0 := addmod(
                        addmod(mload(W1_EVAL_LOC), gamma, p),
                        mulmod(mload(QR_EVAL_LOC), mload(W1_SHIFT_EVAL_LOC), p),
                        p
                    )
                    t1 := addmod(mload(W2_EVAL_LOC), mulmod(mload(QM_EVAL_LOC), mload(W2_SHIFT_EVAL_LOC), p), p)
                    let t2 := addmod(mload(W3_EVAL_LOC), mulmod(mload(QC_EVAL_LOC), mload(W3_SHIFT_EVAL_LOC), p), p)

                    let lookup_term := addmod(t0, mulmod(t1, beta, p), p)
                    lookup_term := addmod(lookup_term, mulmod(t2, beta_sqr, p), p)
                    lookup_term := addmod(lookup_term, mulmod(mload(QO_EVAL_LOC), beta_cube, p), p)

                    let lookup_inverse := mulmod(mload(LOOKUP_INVERSES_EVAL_LOC), table_term, p)
                    let table_inverse := mulmod(mload(LOOKUP_INVERSES_EVAL_LOC), lookup_term, p)

                    let inverse_exists_xor := addmod(mload(LOOKUP_READ_TAGS_EVAL_LOC), mload(QLOOKUP_EVAL_LOC), p)
                    inverse_exists_xor := addmod(
                        inverse_exists_xor,
                        sub(p, mulmod(mload(LOOKUP_READ_TAGS_EVAL_LOC), mload(QLOOKUP_EVAL_LOC), p)),
                        p
                    )

                    let accumulator_none := mulmod(mulmod(lookup_term, table_term, p), mload(LOOKUP_INVERSES_EVAL_LOC), p)
                    accumulator_none := addmod(accumulator_none, sub(p, inverse_exists_xor), p)
                    accumulator_none := mulmod(accumulator_none, mload(POW_PARTIAL_EVALUATION_LOC), p)

                    let accumulator_one := mulmod(mload(QLOOKUP_EVAL_LOC), lookup_inverse, p)
                    accumulator_one := addmod(
                        accumulator_one,
                        sub(p, mulmod(mload(LOOKUP_READ_COUNTS_EVAL_LOC), table_inverse, p)),
                        p
                    )

                    let read_tag := mload(LOOKUP_READ_TAGS_EVAL_LOC)
                    let read_tag_boolean_relation := mulmod(read_tag, addmod(read_tag, P_SUB_1, p), p)
                    read_tag_boolean_relation := mulmod(read_tag_boolean_relation, mload(POW_PARTIAL_EVALUATION_LOC), p)

                    mstore(SUBRELATION_EVAL_3_LOC, accumulator_none)
                    mstore(SUBRELATION_EVAL_4_LOC, accumulator_one)
                    mstore(SUBRELATION_EVAL_5_LOC, read_tag_boolean_relation)
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                   DELTA RANGE RELATION                     */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                {
                    let minus_one := P_SUB_1
                    let minus_two := P_SUB_2
                    let minus_three := P_SUB_3

                    let delta_1 := addmod(mload(W2_EVAL_LOC), sub(p, mload(W1_EVAL_LOC)), p)
                    let delta_2 := addmod(mload(W3_EVAL_LOC), sub(p, mload(W2_EVAL_LOC)), p)
                    let delta_3 := addmod(mload(W4_EVAL_LOC), sub(p, mload(W3_EVAL_LOC)), p)
                    let delta_4 := addmod(mload(W1_SHIFT_EVAL_LOC), sub(p, mload(W4_EVAL_LOC)), p)

                    {
                        let acc := delta_1
                        acc := mulmod(acc, addmod(delta_1, minus_one, p), p)
                        acc := mulmod(acc, addmod(delta_1, minus_two, p), p)
                        acc := mulmod(acc, addmod(delta_1, minus_three, p), p)
                        acc := mulmod(acc, mload(QRANGE_EVAL_LOC), p)
                        acc := mulmod(acc, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        mstore(SUBRELATION_EVAL_8_LOC, acc)
                    }

                    {
                        let acc := delta_2
                        acc := mulmod(acc, addmod(delta_2, minus_one, p), p)
                        acc := mulmod(acc, addmod(delta_2, minus_two, p), p)
                        acc := mulmod(acc, addmod(delta_2, minus_three, p), p)
                        acc := mulmod(acc, mload(QRANGE_EVAL_LOC), p)
                        acc := mulmod(acc, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        mstore(SUBRELATION_EVAL_9_LOC, acc)
                    }

                    {
                        let acc := delta_3
                        acc := mulmod(acc, addmod(delta_3, minus_one, p), p)
                        acc := mulmod(acc, addmod(delta_3, minus_two, p), p)
                        acc := mulmod(acc, addmod(delta_3, minus_three, p), p)
                        acc := mulmod(acc, mload(QRANGE_EVAL_LOC), p)
                        acc := mulmod(acc, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        mstore(SUBRELATION_EVAL_10_LOC, acc)
                    }

                    {
                        let acc := delta_4
                        acc := mulmod(acc, addmod(delta_4, minus_one, p), p)
                        acc := mulmod(acc, addmod(delta_4, minus_two, p), p)
                        acc := mulmod(acc, addmod(delta_4, minus_three, p), p)
                        acc := mulmod(acc, mload(QRANGE_EVAL_LOC), p)
                        acc := mulmod(acc, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        mstore(SUBRELATION_EVAL_11_LOC, acc)
                    }
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                    ELLIPTIC CURVE RELATION                 */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                {
                    // Contribution 10 point addition, x-coordinate check
                    // q_elliptic * (x3 + x2 + x1)(x2 - x1)(x2 - x1) - y2^2 - y1^2 + 2(y2y1)*q_sign = 0
                    let x_diff := addmod(mload(EC_X_2), sub(p, mload(EC_X_1)), p)
                    let y1_sqr := mulmod(mload(EC_Y_1), mload(EC_Y_1), p)
                    {
                        let y2_sqr := mulmod(mload(EC_Y_2), mload(EC_Y_2), p)
                        let y1y2 := mulmod(mulmod(mload(EC_Y_1), mload(EC_Y_2), p), mload(EC_Q_SIGN), p)
                        let x_add_identity := addmod(mload(EC_X_3), addmod(mload(EC_X_2), mload(EC_X_1), p), p)
                        x_add_identity := mulmod(mulmod(x_add_identity, x_diff, p), x_diff, p)
                        x_add_identity := addmod(x_add_identity, sub(p, y2_sqr), p)
                        x_add_identity := addmod(x_add_identity, sub(p, y1_sqr), p)
                        x_add_identity := addmod(x_add_identity, y1y2, p)
                        x_add_identity := addmod(x_add_identity, y1y2, p)

                        let eval := mulmod(x_add_identity, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        eval := mulmod(eval, mload(QELLIPTIC_EVAL_LOC), p)
                        eval := mulmod(eval, addmod(1, sub(p, mload(EC_Q_IS_DOUBLE)), p), p)
                        mstore(SUBRELATION_EVAL_12_LOC, eval)
                    }

                    {
                        let y1_plus_y3 := addmod(mload(EC_Y_1), mload(EC_Y_3), p)
                        let y_diff := mulmod(mload(EC_Y_2), mload(EC_Q_SIGN), p)
                        y_diff := addmod(y_diff, sub(p, mload(EC_Y_1)), p)
                        let y_add_identity := mulmod(y1_plus_y3, x_diff, p)
                        y_add_identity := addmod(
                            y_add_identity,
                            mulmod(addmod(mload(EC_X_3), sub(p, mload(EC_X_1)), p), y_diff, p),
                            p
                        )

                        let eval := mulmod(y_add_identity, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        eval := mulmod(eval, mload(QELLIPTIC_EVAL_LOC), p)
                        eval := mulmod(eval, addmod(1, sub(p, mload(EC_Q_IS_DOUBLE)), p), p)
                        mstore(SUBRELATION_EVAL_13_LOC, eval)
                    }

                    {
                        let x_pow_4 := mulmod(addmod(y1_sqr, GRUMPKIN_CURVE_B_PARAMETER_NEGATED, p), mload(EC_X_1), p)
                        let y1_sqr_mul_4 := addmod(y1_sqr, y1_sqr, p)
                        y1_sqr_mul_4 := addmod(y1_sqr_mul_4, y1_sqr_mul_4, p)

                        let x1_pow_4_mul_9 := mulmod(x_pow_4, 9, p)

                        let ep_x_double_identity := addmod(mload(EC_X_3), addmod(mload(EC_X_1), mload(EC_X_1), p), p)
                        ep_x_double_identity := mulmod(ep_x_double_identity, y1_sqr_mul_4, p)
                        ep_x_double_identity := addmod(ep_x_double_identity, sub(p, x1_pow_4_mul_9), p)

                        let acc := mulmod(ep_x_double_identity, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        acc := mulmod(mulmod(acc, mload(QELLIPTIC_EVAL_LOC), p), mload(EC_Q_IS_DOUBLE), p)
                        acc := addmod(acc, mload(SUBRELATION_EVAL_12_LOC), p)

                        // Add to existing contribution
                        mstore(SUBRELATION_EVAL_12_LOC, acc)
                    }

                    {
                        let x1_sqr_mul_3 :=
                            mulmod(addmod(addmod(mload(EC_X_1), mload(EC_X_1), p), mload(EC_X_1), p), mload(EC_X_1), p)
                        let y_double_identity :=
                            mulmod(x1_sqr_mul_3, addmod(mload(EC_X_1), sub(p, mload(EC_X_3)), p), p)
                        y_double_identity := addmod(
                            y_double_identity,
                            sub(
                                p,
                                mulmod(
                                    addmod(mload(EC_Y_1), mload(EC_Y_1), p),
                                    addmod(mload(EC_Y_1), mload(EC_Y_3), p),
                                    p
                                )
                            ),
                            p
                        )

                        let acc := mulmod(y_double_identity, mload(POW_PARTIAL_EVALUATION_LOC), p)
                        acc := mulmod(mulmod(acc, mload(QELLIPTIC_EVAL_LOC), p), mload(EC_Q_IS_DOUBLE), p)
                        acc := addmod(acc, mload(SUBRELATION_EVAL_13_LOC), p)

                        // Add to existing contribution
                        mstore(SUBRELATION_EVAL_13_LOC, acc)
                    }
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                    MEMORY RELATION                         */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                {
                    {
                        /**
                         * MEMORY
                         *
                         * A RAM memory record contains a tuple of the following fields:
                         *  * i: `index` of memory cell being accessed
                         *  * t: `timestamp` of memory cell being accessed (used for RAM, set to 0 for ROM)
                         *  * v: `value` of memory cell being accessed
                         *  * a: `access` type of record. read: 0 = read, 1 = write
                         *  * r: `record` of memory cell. record = access + index * eta + timestamp * eta_two + value * eta_three
                         *
                         * A ROM memory record contains a tuple of the following fields:
                         *  * i: `index` of memory cell being accessed
                         *  * v: `value1` of memory cell being accessed (ROM tables can store up to 2 values per index)
                         *  * v2:`value2` of memory cell being accessed (ROM tables can store up to 2 values per index)
                         *  * r: `record` of memory cell. record = index * eta + value2 * eta_two + value1 * eta_three
                         *
                         *  When performing a read/write access, the values of i, t, v, v2, a, r are stored in the following wires +
                         * selectors, depending on whether the gate is a RAM read/write or a ROM read
                         *
                         *  | gate type | i  | v2/t  |  v | a  | r  |
                         *  | --------- | -- | ----- | -- | -- | -- |
                         *  | ROM       | w1 | w2    | w3 | -- | w4 |
                         *  | RAM       | w1 | w2    | w3 | qc | w4 |
                         *
                         * (for accesses where `index` is a circuit constant, it is assumed the circuit will apply a copy constraint on
                         * `w2` to fix its value)
                         *
                         *
                         */

                        /**
                         * Memory Record Check
                         * Partial degree: 1
                         * Total degree: 4
                         *
                         * A ROM/ROM access gate can be evaluated with the identity:
                         *
                         * qc + w1 \eta + w2 \eta_two + w3 \eta_three - w4 = 0
                         *
                         * For ROM gates, qc = 0
                         */
                        /**
                         * memory_record_check = w_3 * eta_three;
                         * memory_record_check += w_2 * eta_two;
                         * memory_record_check += w_1 * eta;
                         * memory_record_check += q_c;
                         *
                         * partial_record_check = memory_record_check;
                         *
                         * memory_record_check -= w_4;
                         */
                        let memory_record_check := mulmod(mload(W3_EVAL_LOC), mload(ETA_THREE_CHALLENGE), p)
                        memory_record_check := addmod(
                            memory_record_check,
                            mulmod(mload(W2_EVAL_LOC), mload(ETA_TWO_CHALLENGE), p),
                            p
                        )
                        memory_record_check := addmod(
                            memory_record_check,
                            mulmod(mload(W1_EVAL_LOC), mload(ETA_CHALLENGE), p),
                            p
                        )
                        memory_record_check := addmod(memory_record_check, mload(QC_EVAL_LOC), p)

                        let partial_record_check := memory_record_check
                        memory_record_check := addmod(memory_record_check, sub(p, mload(W4_EVAL_LOC)), p)

                        mstore(AUX_MEMORY_CHECK_IDENTITY, memory_record_check)

                        /**
                         * ROM Consistency Check
                         * Partial degree: 1
                         * Total degree: 4
                         *
                         * For every ROM read, a set equivalence check is applied between the record witnesses, and a second set of
                         * records that are sorted.
                         *
                         * We apply the following checks for the sorted records:
                         *
                         * 1. w1, w2, w3 correctly map to 'index', 'v1, 'v2' for a given record value at w4
                         * 2. index values for adjacent records are monotonically increasing
                         * 3. if, at gate i, index_i == index_{i + 1}, then value1_i == value1_{i + 1} and value2_i == value2_{i + 1}
                         *
                         */
                        // index_delta = w_1_omega - w_1
                        let index_delta := addmod(mload(W1_SHIFT_EVAL_LOC), sub(p, mload(W1_EVAL_LOC)), p)

                        // record_delta = w_4_omega - w_4
                        let record_delta := addmod(mload(W4_SHIFT_EVAL_LOC), sub(p, mload(W4_EVAL_LOC)), p)

                        // index_is_monotonically_increasing = index_delta * (index_delta - 1)
                        let index_is_monotonically_increasing := mulmod(index_delta, addmod(index_delta, P_SUB_1, p), p)

                        // adjacent_values_match_if_adjacent_indices_match = record_delta * (1 - index_delta)
                        let adjacent_values_match_if_adjacent_indices_match :=
                            mulmod(record_delta, addmod(1, sub(p, index_delta), p), p)

                        mstore(
                            SUBRELATION_EVAL_15_LOC,
                            mulmod(
                                adjacent_values_match_if_adjacent_indices_match,
                                mulmod(
                                    mload(QL_EVAL_LOC),
                                    mulmod(
                                        mload(QR_EVAL_LOC),
                                        mulmod(mload(QMEMORY_EVAL_LOC), mload(POW_PARTIAL_EVALUATION_LOC), p),
                                        p
                                    ),
                                    p
                                ),
                                p
                            )
                        )

                        // ROM_CONSISTENCY_CHECK_2
                        mstore(
                            SUBRELATION_EVAL_16_LOC,
                            mulmod(
                                index_is_monotonically_increasing,
                                mulmod(
                                    mload(QL_EVAL_LOC),
                                    mulmod(
                                        mload(QR_EVAL_LOC),
                                        mulmod(mload(QMEMORY_EVAL_LOC), mload(POW_PARTIAL_EVALUATION_LOC), p),
                                        p
                                    ),
                                    p
                                ),
                                p
                            )
                        )

                        mstore(
                            AUX_ROM_CONSISTENCY_CHECK_IDENTITY,
                            mulmod(memory_record_check, mulmod(mload(QL_EVAL_LOC), mload(QR_EVAL_LOC), p), p)
                        )

                        {
                            /**
                             * RAM Consistency Check
                             *
                             * The 'access' type of the record is extracted with the expression `w_4 - ap.partial_record_check`
                             * (i.e. for an honest Prover `w1 * eta + w2 * eta^2 + w3 * eta^3 - w4 = access`.
                             * This is validated by requiring `access` to be boolean
                             *
                             * For two adjacent entries in the sorted list if _both_
                             *  A) index values match
                             *  B) adjacent access value is 0 (i.e. next gate is a READ)
                             * then
                             *  C) both values must match.
                             * The gate boolean check is
                             * (A && B) => C  === !(A && B) || C ===  !A || !B || C
                             *
                             * N.B. it is the responsibility of the circuit writer to ensure that every RAM cell is initialized
                             * with a WRITE operation.
                             */
                            /**
                             * next_gate_access_type = w_3_shift * eta_three;
                             * next_gate_access_type += (w_2_shift * eta_two);
                             * next_gate_access_type += (w_1_shift * eta);
                             * next_gate_access_type += w_4_shift;
                             * next_gate_access_type *= eta;
                             * next_gate_access_type = w_4_omega - next_gate_access_type;
                             */
                            let next_gate_access_type := mulmod(mload(W3_SHIFT_EVAL_LOC), mload(ETA_THREE_CHALLENGE), p)
                            next_gate_access_type := addmod(
                                next_gate_access_type,
                                mulmod(mload(W2_SHIFT_EVAL_LOC), mload(ETA_TWO_CHALLENGE), p),
                                p
                            )
                            next_gate_access_type := addmod(
                                next_gate_access_type,
                                mulmod(mload(W1_SHIFT_EVAL_LOC), mload(ETA_CHALLENGE), p),
                                p
                            )
                            next_gate_access_type := addmod(mload(W4_SHIFT_EVAL_LOC), sub(p, next_gate_access_type), p)

                            // value_delta = w_3_omega - w_3
                            let value_delta := addmod(mload(W3_SHIFT_EVAL_LOC), sub(p, mload(W3_EVAL_LOC)), p)
                            //  adjacent_values_match_if_adjacent_indices_match_and_next_access_is_a_read_operation = (1 - index_delta) * value_delta * (1 - next_gate_access_type);

                            let adjacent_values_match_if_adjacent_indices_match_and_next_access_is_a_read_operation :=
                                mulmod(
                                    addmod(1, sub(p, index_delta), p),
                                    mulmod(value_delta, addmod(1, sub(p, next_gate_access_type), p), p),
                                    p
                                )

                            // We can't apply the RAM consistency check identity on the final entry in the sorted list (the wires in the
                            // next gate would make the identity fail).  We need to validate that its 'access type' bool is correct. Can't
                            // do  with an arithmetic gate because of the  `eta` factors. We need to check that the *next* gate's access
                            // type is  correct, to cover this edge case
                            // deg 2 or 4
                            /**
                             * access_type = w_4 - partial_record_check
                             * access_check = access_type^2 - access_type
                             * next_gate_access_type_is_boolean = next_gate_access_type^2 - next_gate_access_type
                             */
                            let access_type := addmod(mload(W4_EVAL_LOC), sub(p, partial_record_check), p)
                            let access_check := mulmod(access_type, addmod(access_type, P_SUB_1, p), p)
                            let next_gate_access_type_is_boolean :=
                                mulmod(next_gate_access_type, addmod(next_gate_access_type, P_SUB_1, p), p)

                            // scaled_activation_selector = q_arith * q_aux * alpha
                            let scaled_activation_selector :=
                                mulmod(
                                    mload(QO_EVAL_LOC),
                                    mulmod(mload(QMEMORY_EVAL_LOC), mload(POW_PARTIAL_EVALUATION_LOC), p),
                                    p
                                )

                            mstore(
                                SUBRELATION_EVAL_17_LOC,
                                mulmod(
                                    adjacent_values_match_if_adjacent_indices_match_and_next_access_is_a_read_operation,
                                    scaled_activation_selector,
                                    p
                                )
                            )

                            mstore(
                                SUBRELATION_EVAL_18_LOC,
                                mulmod(index_is_monotonically_increasing, scaled_activation_selector, p)
                            )

                            mstore(
                                SUBRELATION_EVAL_19_LOC,
                                mulmod(next_gate_access_type_is_boolean, scaled_activation_selector, p)
                            )

                            mstore(AUX_RAM_CONSISTENCY_CHECK_IDENTITY, mulmod(access_check, mload(QO_EVAL_LOC), p))
                        }

                        {
                            // timestamp_delta = w_2_omega - w_2
                            let timestamp_delta := addmod(mload(W2_SHIFT_EVAL_LOC), sub(p, mload(W2_EVAL_LOC)), p)

                            // RAM_timestamp_check_identity = (1 - index_delta) * timestamp_delta - w_3
                            let RAM_TIMESTAMP_CHECK_IDENTITY :=
                                addmod(
                                    mulmod(timestamp_delta, addmod(1, sub(p, index_delta), p), p),
                                    sub(p, mload(W3_EVAL_LOC)),
                                    p
                                )

                            /**
                             * memory_identity = ROM_consistency_check_identity;
                             * memory_identity += RAM_timestamp_check_identity * q_4;
                             * memory_identity += memory_record_check * q_m;
                             * memory_identity *= q_1;
                             * memory_identity += (RAM_consistency_check_identity * q_arith);
                             *
                             * auxiliary_identity = memory_identity + non_native_field_identity + limb_accumulator_identity;
                             * auxiliary_identity *= q_aux;
                             * auxiliary_identity *= alpha_base;
                             */
                            let memory_identity := mload(AUX_ROM_CONSISTENCY_CHECK_IDENTITY)
                            memory_identity := addmod(
                                memory_identity,
                                mulmod(
                                    RAM_TIMESTAMP_CHECK_IDENTITY,
                                    mulmod(mload(Q4_EVAL_LOC), mload(QL_EVAL_LOC), p),
                                    p
                                ),
                                p
                            )

                            memory_identity := addmod(
                                memory_identity,
                                mulmod(
                                    mload(AUX_MEMORY_CHECK_IDENTITY),
                                    mulmod(mload(QM_EVAL_LOC), mload(QL_EVAL_LOC), p),
                                    p
                                ),
                                p
                            )
                            memory_identity := addmod(memory_identity, mload(AUX_RAM_CONSISTENCY_CHECK_IDENTITY), p)

                            memory_identity := mulmod(
                                memory_identity,
                                mulmod(mload(QMEMORY_EVAL_LOC), mload(POW_PARTIAL_EVALUATION_LOC), p),
                                p
                            )
                            mstore(SUBRELATION_EVAL_14_LOC, memory_identity)
                        }
                    }
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*               NON NATIVE FIELD RELATION                    */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                {
                    /**
                     * Non native field arithmetic gate 2
                     *             _                                                                               _
                     *            /   _                   _                               _       14                \
                     * q_2 . q_4 |   (w_1 . w_2) + (w_1 . w_2) + (w_1 . w_4 + w_2 . w_3 - w_3) . 2    - w_3 - w_4   |
                     *            \_                                                                               _/
                     *
                     * limb_subproduct = w_1 . w_2_shift + w_1_shift . w_2
                     * non_native_field_gate_2 = w_1 * w_4 + w_4 * w_3 - w_3_shift
                     * non_native_field_gate_2 = non_native_field_gate_2 * limb_size
                     * non_native_field_gate_2 -= w_4_shift
                     * non_native_field_gate_2 += limb_subproduct
                     * non_native_field_gate_2 *= q_4
                     * limb_subproduct *= limb_size
                     * limb_subproduct += w_1_shift * w_2
                     * non_native_field_gate_1 = (limb_subproduct + w_3 + w_4) * q_3
                     * non_native_field_gate_3 = (limb_subproduct + w_4 - (w_3_shift + w_4_shift)) * q_m
                     * non_native_field_identity = (non_native_field_gate_1 + non_native_field_gate_2 + non_native_field_gate_3) * q_2
                     */
                    let limb_subproduct :=
                        addmod(
                            mulmod(mload(W1_EVAL_LOC), mload(W2_SHIFT_EVAL_LOC), p),
                            mulmod(mload(W1_SHIFT_EVAL_LOC), mload(W2_EVAL_LOC), p),
                            p
                        )

                    let non_native_field_gate_2 :=
                        addmod(
                            addmod(
                                mulmod(mload(W1_EVAL_LOC), mload(W4_EVAL_LOC), p),
                                mulmod(mload(W2_EVAL_LOC), mload(W3_EVAL_LOC), p),
                                p
                            ),
                            sub(p, mload(W3_SHIFT_EVAL_LOC)),
                            p
                        )
                    non_native_field_gate_2 := mulmod(non_native_field_gate_2, LIMB_SIZE, p)
                    non_native_field_gate_2 := addmod(non_native_field_gate_2, sub(p, mload(W4_SHIFT_EVAL_LOC)), p)
                    non_native_field_gate_2 := addmod(non_native_field_gate_2, limb_subproduct, p)
                    non_native_field_gate_2 := mulmod(non_native_field_gate_2, mload(Q4_EVAL_LOC), p)

                    limb_subproduct := mulmod(limb_subproduct, LIMB_SIZE, p)
                    limb_subproduct := addmod(
                        limb_subproduct,
                        mulmod(mload(W1_SHIFT_EVAL_LOC), mload(W2_SHIFT_EVAL_LOC), p),
                        p
                    )

                    let non_native_field_gate_1 :=
                        mulmod(
                            addmod(limb_subproduct, sub(p, addmod(mload(W3_EVAL_LOC), mload(W4_EVAL_LOC), p)), p),
                            mload(QO_EVAL_LOC),
                            p
                        )

                    let non_native_field_gate_3 :=
                        mulmod(
                            addmod(
                                addmod(limb_subproduct, mload(W4_EVAL_LOC), p),
                                sub(p, addmod(mload(W3_SHIFT_EVAL_LOC), mload(W4_SHIFT_EVAL_LOC), p)),
                                p
                            ),
                            mload(QM_EVAL_LOC),
                            p
                        )
                    let non_native_field_identity :=
                        mulmod(
                            addmod(
                                addmod(non_native_field_gate_1, non_native_field_gate_2, p),
                                non_native_field_gate_3,
                                p
                            ),
                            mload(QR_EVAL_LOC),
                            p
                        )

                    mstore(AUX_NON_NATIVE_FIELD_IDENTITY, non_native_field_identity)
                }

                {
                    /**
                     * limb_accumulator_1 = w_2_omega;
                     * limb_accumulator_1 *= SUBLIMB_SHIFT;
                     * limb_accumulator_1 += w_1_omega;
                     * limb_accumulator_1 *= SUBLIMB_SHIFT;
                     * limb_accumulator_1 += w_3;
                     * limb_accumulator_1 *= SUBLIMB_SHIFT;
                     * limb_accumulator_1 += w_2;
                     * limb_accumulator_1 *= SUBLIMB_SHIFT;
                     * limb_accumulator_1 += w_1;
                     * limb_accumulator_1 -= w_4;
                     * limb_accumulator_1 *= q_4;
                     */
                    let limb_accumulator_1 := mulmod(mload(W2_SHIFT_EVAL_LOC), SUBLIMB_SHIFT, p)
                    limb_accumulator_1 := addmod(limb_accumulator_1, mload(W1_SHIFT_EVAL_LOC), p)
                    limb_accumulator_1 := mulmod(limb_accumulator_1, SUBLIMB_SHIFT, p)
                    limb_accumulator_1 := addmod(limb_accumulator_1, mload(W3_EVAL_LOC), p)
                    limb_accumulator_1 := mulmod(limb_accumulator_1, SUBLIMB_SHIFT, p)
                    limb_accumulator_1 := addmod(limb_accumulator_1, mload(W2_EVAL_LOC), p)
                    limb_accumulator_1 := mulmod(limb_accumulator_1, SUBLIMB_SHIFT, p)
                    limb_accumulator_1 := addmod(limb_accumulator_1, mload(W1_EVAL_LOC), p)
                    limb_accumulator_1 := addmod(limb_accumulator_1, sub(p, mload(W4_EVAL_LOC)), p)
                    limb_accumulator_1 := mulmod(limb_accumulator_1, mload(Q4_EVAL_LOC), p)

                    /**
                     * limb_accumulator_2 = w_3_omega;
                     * limb_accumulator_2 *= SUBLIMB_SHIFT;
                     * limb_accumulator_2 += w_2_omega;
                     * limb_accumulator_2 *= SUBLIMB_SHIFT;
                     * limb_accumulator_2 += w_1_omega;
                     * limb_accumulator_2 *= SUBLIMB_SHIFT;
                     * limb_accumulator_2 += w_4;
                     * limb_accumulator_2 *= SUBLIMB_SHIFT;
                     * limb_accumulator_2 += w_3;
                     * limb_accumulator_2 -= w_4_omega;
                     * limb_accumulator_2 *= q_m;
                     */
                    let limb_accumulator_2 := mulmod(mload(W3_SHIFT_EVAL_LOC), SUBLIMB_SHIFT, p)
                    limb_accumulator_2 := addmod(limb_accumulator_2, mload(W2_SHIFT_EVAL_LOC), p)
                    limb_accumulator_2 := mulmod(limb_accumulator_2, SUBLIMB_SHIFT, p)
                    limb_accumulator_2 := addmod(limb_accumulator_2, mload(W1_SHIFT_EVAL_LOC), p)
                    limb_accumulator_2 := mulmod(limb_accumulator_2, SUBLIMB_SHIFT, p)
                    limb_accumulator_2 := addmod(limb_accumulator_2, mload(W4_EVAL_LOC), p)
                    limb_accumulator_2 := mulmod(limb_accumulator_2, SUBLIMB_SHIFT, p)
                    limb_accumulator_2 := addmod(limb_accumulator_2, mload(W3_EVAL_LOC), p)
                    limb_accumulator_2 := addmod(limb_accumulator_2, sub(p, mload(W4_SHIFT_EVAL_LOC)), p)
                    limb_accumulator_2 := mulmod(limb_accumulator_2, mload(QM_EVAL_LOC), p)

                    let limb_accumulator_identity := addmod(limb_accumulator_1, limb_accumulator_2, p)
                    limb_accumulator_identity := mulmod(limb_accumulator_identity, mload(QO_EVAL_LOC), p)

                    let nnf_identity := addmod(mload(AUX_NON_NATIVE_FIELD_IDENTITY), limb_accumulator_identity, p)
                    nnf_identity := mulmod(
                        nnf_identity,
                        mulmod(mload(QNNF_EVAL_LOC), mload(POW_PARTIAL_EVALUATION_LOC), p),
                        p
                    )

                    mstore(SUBRELATION_EVAL_20_LOC, nnf_identity)
                }

                /*
                * Poseidon External Relation
                */
                {
                    let s1 := addmod(mload(W1_EVAL_LOC), mload(QL_EVAL_LOC), p)
                    let s2 := addmod(mload(W2_EVAL_LOC), mload(QR_EVAL_LOC), p)
                    let s3 := addmod(mload(W3_EVAL_LOC), mload(QO_EVAL_LOC), p)
                    let s4 := addmod(mload(W4_EVAL_LOC), mload(Q4_EVAL_LOC), p)

                    // u1 := s1 * s1 * s1 * s1 * s1;
                    let t0 := mulmod(s1, s1, p)
                    let u1 := mulmod(t0, mulmod(t0, s1, p), p)

                    // u2 := s2 * s2 * s2 * s2 * s2;
                    t0 := mulmod(s2, s2, p)
                    let u2 := mulmod(t0, mulmod(t0, s2, p), p)

                    // u3 := s3 * s3 * s3 * s3 * s3;
                    t0 := mulmod(s3, s3, p)
                    let u3 := mulmod(t0, mulmod(t0, s3, p), p)

                    // u4 := s4 * s4 * s4 * s4 * s4;
                    t0 := mulmod(s4, s4, p)
                    let u4 := mulmod(t0, mulmod(t0, s4, p), p)

                    // matrix mul v = M_E * u with 14 additions
                    t0 := addmod(u1, u2, p)
                    let t1 := addmod(u3, u4, p)

                    let t2 := addmod(u2, u2, p)
                    t2 := addmod(t2, t1, p)

                    let t3 := addmod(u4, u4, p)
                    t3 := addmod(t3, t0, p)

                    let v4 := addmod(t1, t1, p)
                    v4 := addmod(v4, v4, p)
                    v4 := addmod(v4, t3, p)

                    let v2 := addmod(t0, t0, p)
                    v2 := addmod(v2, v2, p)
                    v2 := addmod(v2, t2, p)

                    let v1 := addmod(t3, v2, p)
                    let v3 := addmod(t2, v4, p)

                    let q_pos_by_scaling :=
                        mulmod(mload(QPOSEIDON2_EXTERNAL_EVAL_LOC), mload(POW_PARTIAL_EVALUATION_LOC), p)

                    mstore(
                        SUBRELATION_EVAL_21_LOC,
                        mulmod(q_pos_by_scaling, addmod(v1, sub(p, mload(W1_SHIFT_EVAL_LOC)), p), p)
                    )

                    mstore(
                        SUBRELATION_EVAL_22_LOC,
                        mulmod(q_pos_by_scaling, addmod(v2, sub(p, mload(W2_SHIFT_EVAL_LOC)), p), p)
                    )

                    mstore(
                        SUBRELATION_EVAL_23_LOC,
                        mulmod(q_pos_by_scaling, addmod(v3, sub(p, mload(W3_SHIFT_EVAL_LOC)), p), p)
                    )

                    mstore(
                        SUBRELATION_EVAL_24_LOC,
                        mulmod(q_pos_by_scaling, addmod(v4, sub(p, mload(W4_SHIFT_EVAL_LOC)), p), p)
                    )
                }

                /*
                * Poseidon Internal Relation
                */
                {
                    let s1 := addmod(mload(W1_EVAL_LOC), mload(QL_EVAL_LOC), p)

                    // apply s-box round
                    let t0 := mulmod(s1, s1, p)
                    let u1 := mulmod(t0, mulmod(t0, s1, p), p)
                    let u2 := mload(W2_EVAL_LOC)
                    let u3 := mload(W3_EVAL_LOC)
                    let u4 := mload(W4_EVAL_LOC)

                    // matrix mul v = M_I * u 4 muls and 7 additions
                    let u_sum := addmod(u1, u2, p)
                    u_sum := addmod(u_sum, addmod(u3, u4, p), p)

                    let q_pos_by_scaling :=
                        mulmod(mload(QPOSEIDON2_INTERNAL_EVAL_LOC), mload(POW_PARTIAL_EVALUATION_LOC), p)

                    let v1 := addmod(mulmod(u1, POS_INTERNAL_MATRIX_D_0, p), u_sum, p)

                    mstore(
                        SUBRELATION_EVAL_25_LOC,
                        mulmod(q_pos_by_scaling, addmod(v1, sub(p, mload(W1_SHIFT_EVAL_LOC)), p), p)
                    )
                    let v2 := addmod(mulmod(u2, POS_INTERNAL_MATRIX_D_1, p), u_sum, p)

                    mstore(
                        SUBRELATION_EVAL_26_LOC,
                        mulmod(q_pos_by_scaling, addmod(v2, sub(p, mload(W2_SHIFT_EVAL_LOC)), p), p)
                    )
                    let v3 := addmod(mulmod(u3, POS_INTERNAL_MATRIX_D_2, p), u_sum, p)

                    mstore(
                        SUBRELATION_EVAL_27_LOC,
                        mulmod(q_pos_by_scaling, addmod(v3, sub(p, mload(W3_SHIFT_EVAL_LOC)), p), p)
                    )

                    let v4 := addmod(mulmod(u4, POS_INTERNAL_MATRIX_D_3, p), u_sum, p)
                    mstore(
                        SUBRELATION_EVAL_28_LOC,
                        mulmod(q_pos_by_scaling, addmod(v4, sub(p, mload(W4_SHIFT_EVAL_LOC)), p), p)
                    )
                }

                // Scale and batch subrelations by subrelation challenges
                // linear combination of subrelations
                let accumulator := mload(SUBRELATION_EVAL_0_LOC)

                // Below is an unrolled variant of the following loop
                // for (uint256 i = 1; i < NUMBER_OF_SUBRELATIONS; ++i) {
                //     accumulator = accumulator + evaluations[i] * subrelationChallenges[i - 1];
                // }

                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_1_LOC), mload(ALPHA_CHALLENGE_0), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_2_LOC), mload(ALPHA_CHALLENGE_1), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_3_LOC), mload(ALPHA_CHALLENGE_2), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_4_LOC), mload(ALPHA_CHALLENGE_3), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_5_LOC), mload(ALPHA_CHALLENGE_4), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_6_LOC), mload(ALPHA_CHALLENGE_5), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_7_LOC), mload(ALPHA_CHALLENGE_6), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_8_LOC), mload(ALPHA_CHALLENGE_7), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_9_LOC), mload(ALPHA_CHALLENGE_8), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_10_LOC), mload(ALPHA_CHALLENGE_9), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_11_LOC), mload(ALPHA_CHALLENGE_10), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_12_LOC), mload(ALPHA_CHALLENGE_11), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_13_LOC), mload(ALPHA_CHALLENGE_12), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_14_LOC), mload(ALPHA_CHALLENGE_13), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_15_LOC), mload(ALPHA_CHALLENGE_14), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_16_LOC), mload(ALPHA_CHALLENGE_15), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_17_LOC), mload(ALPHA_CHALLENGE_16), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_18_LOC), mload(ALPHA_CHALLENGE_17), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_19_LOC), mload(ALPHA_CHALLENGE_18), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_20_LOC), mload(ALPHA_CHALLENGE_19), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_21_LOC), mload(ALPHA_CHALLENGE_20), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_22_LOC), mload(ALPHA_CHALLENGE_21), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_23_LOC), mload(ALPHA_CHALLENGE_22), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_24_LOC), mload(ALPHA_CHALLENGE_23), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_25_LOC), mload(ALPHA_CHALLENGE_24), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_26_LOC), mload(ALPHA_CHALLENGE_25), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_27_LOC), mload(ALPHA_CHALLENGE_26), p),
                    p
                )
                accumulator := addmod(
                    accumulator,
                    mulmod(mload(SUBRELATION_EVAL_28_LOC), mload(ALPHA_CHALLENGE_27), p),
                    p
                )

                // ZK final check: grandHonkRelationSum * (1 - evaluation) + libraEvaluation * libraChallenge == roundTargetSum
                // where evaluation = product(u[2] * u[3] * ... * u[LOG_N - 1])
                {
                    // Row-disabling polynomial: 1 - ∏_{i≥2}(1 - u_i)
                    let evaluation := 1
                    let u_off := SUM_U_CHALLENGE_2
                    for { let i := 2 } lt(i, LOG_N) { i := add(i, 1) } {
                        // evaluation = evaluation * (1 - sumCheckUChallenges[i])
                        let one_minus_u := addmod(1, sub(p, mload(u_off)), p)
                        evaluation := mulmod(evaluation, one_minus_u, p)
                        u_off := add(u_off, 0x20)
                    }

                    // adjustedSum = accumulator * (1 - evaluation) + libraEvaluation * libraChallenge
                    let one_minus_eval := addmod(1, sub(p, evaluation), p)
                    let adjusted_sum := addmod(
                        mulmod(accumulator, one_minus_eval, p),
                        mulmod(mload(LIBRA_EVALUATION_LOC), mload(LIBRA_CHALLENGE), p),
                        p
                    )

                    let sumcheck_valid := eq(adjusted_sum, mload(FINAL_ROUND_TARGET_LOC))

                    if iszero(sumcheck_valid) {
                        mstore(0x00, SUMCHECK_FAILED_SELECTOR)
                        revert(0x00, 0x04)
                    }
                }
            }

            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*                 SUMCHECK -- Complete                       */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*                       SHPLEMINI                            */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

            // ============= SHPLEMINI INVERSES ==============
            // Inverses are already at their designated addresses from batch inversion.
            let unshifted_scalar := 0
            let shifted_scalar := 0
            {
                let gemini_r_inv := mload(GEMINI_R_INV_LOC)

                // Compute unshifted_scalar and shifted_scalar using the copied inverses
                let pos_inverted_denominator := mload(POS_INVERTED_DENOM_0_LOC)
                let neg_inverted_denominator := mload(NEG_INVERTED_DENOM_0_LOC)
                let shplonk_nu := mload(SHPLONK_NU_CHALLENGE)

                unshifted_scalar := addmod(pos_inverted_denominator, mulmod(shplonk_nu, neg_inverted_denominator, p), p)

                shifted_scalar := mulmod(
                    gemini_r_inv, // (1 / gemini_r_challenge)
                    // (inverse_vanishing_evals[0]) - (shplonk_nu * inverse_vanishing_evals[1])
                    addmod(
                        pos_inverted_denominator,
                        // - (shplonk_nu * inverse_vanishing_evals[1])
                        sub(p, mulmod(shplonk_nu, neg_inverted_denominator, p)),
                        p
                    ),
                    p
                )
            }

            // Commitment Accumulation (MSM via sequential ecAdd/ecMul):
            // For each commitment C_i with batch scalar s_i, we compute:
            //   accumulator += s_i * C_i
            // The commitments include: shplonk_Q, gemini_masking (ZK), VK points,
            // wire commitments, lookup commitments, Z_PERM, libra (ZK),
            // gemini fold univariates. The KZG quotient is handled separately.
            // The final accumulator is the LHS of the pairing equation.

            // Accumulators
            let batching_challenge := 1
            let batched_evaluation := 0

            let neg_unshifted_scalar := sub(p, unshifted_scalar)
            let neg_shifted_scalar := sub(p, shifted_scalar)

            let rho := mload(RHO_CHALLENGE)

            // Unrolled for the loop below - where NUMBER_UNSHIFTED = 37 (ZK: includes gemini_masking_poly)
            // For ZK: evaluations array is [gemini_masking_poly, qm, qc, ql, qr, ...]
            // for (uint256 i = 1; i <= NUMBER_UNSHIFTED; ++i) {
            //     scalars[i] = mem.unshiftedScalar.neg() * mem.batchingChallenge;
            //     mem.batchedEvaluation = mem.batchedEvaluation + (proof.sumcheckEvaluations[i - NUM_MASKING_POLYNOMIALS] * mem.batchingChallenge);
            //     mem.batchingChallenge = mem.batchingChallenge * tp.rho;
            // }

            // Calculate the scalars and batching challenge for the unshifted entities.
            // Iteration order matches UltraFlavor_Generated::EntityId. Scalar slot N+1 pairs with vk[N].
            // 0: GEMINI_MASKING_EVAL_LOC
            mstore(BATCH_SCALAR_1_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(GEMINI_MASKING_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 1: SIGMA1_EVAL_LOC
            mstore(BATCH_SCALAR_2_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(SIGMA1_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 2: SIGMA2_EVAL_LOC
            mstore(BATCH_SCALAR_3_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(SIGMA2_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 3: SIGMA3_EVAL_LOC
            mstore(BATCH_SCALAR_4_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(SIGMA3_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 4: SIGMA4_EVAL_LOC
            mstore(BATCH_SCALAR_5_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(SIGMA4_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 5: ID1_EVAL_LOC
            mstore(BATCH_SCALAR_6_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(ID1_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 6: ID2_EVAL_LOC
            mstore(BATCH_SCALAR_7_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(ID2_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 7: ID3_EVAL_LOC
            mstore(BATCH_SCALAR_8_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(ID3_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 8: ID4_EVAL_LOC
            mstore(BATCH_SCALAR_9_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(ID4_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 9: LAGRANGE_FIRST_EVAL_LOC
            mstore(BATCH_SCALAR_10_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(LAGRANGE_FIRST_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 10: LAGRANGE_LAST_EVAL_LOC
            mstore(BATCH_SCALAR_11_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(LAGRANGE_LAST_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 11: QLOOKUP_EVAL_LOC
            mstore(BATCH_SCALAR_12_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QLOOKUP_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 12: TABLE1_EVAL_LOC
            mstore(BATCH_SCALAR_13_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(TABLE1_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 13: TABLE2_EVAL_LOC
            mstore(BATCH_SCALAR_14_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(TABLE2_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 14: TABLE3_EVAL_LOC
            mstore(BATCH_SCALAR_15_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(TABLE3_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 15: TABLE4_EVAL_LOC
            mstore(BATCH_SCALAR_16_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(TABLE4_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 16: QM_EVAL_LOC
            mstore(BATCH_SCALAR_17_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QM_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 17: QR_EVAL_LOC
            mstore(BATCH_SCALAR_18_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QR_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 18: QO_EVAL_LOC
            mstore(BATCH_SCALAR_19_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QO_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 19: QC_EVAL_LOC
            mstore(BATCH_SCALAR_20_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QC_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 20: QL_EVAL_LOC
            mstore(BATCH_SCALAR_21_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QL_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 21: Q4_EVAL_LOC
            mstore(BATCH_SCALAR_22_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(Q4_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 22: QARITH_EVAL_LOC
            mstore(BATCH_SCALAR_23_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QARITH_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 23: QRANGE_EVAL_LOC
            mstore(BATCH_SCALAR_24_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QRANGE_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 24: QELLIPTIC_EVAL_LOC
            mstore(BATCH_SCALAR_25_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QELLIPTIC_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 25: QMEMORY_EVAL_LOC
            mstore(BATCH_SCALAR_26_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QMEMORY_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 26: QNNF_EVAL_LOC
            mstore(BATCH_SCALAR_27_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QNNF_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 27: QPOSEIDON2_EXTERNAL_EVAL_LOC
            mstore(BATCH_SCALAR_28_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QPOSEIDON2_EXTERNAL_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 28: QPOSEIDON2_INTERNAL_EVAL_LOC
            mstore(BATCH_SCALAR_29_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(QPOSEIDON2_INTERNAL_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 29: W1_EVAL_LOC
            mstore(BATCH_SCALAR_30_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W1_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 30: W2_EVAL_LOC
            mstore(BATCH_SCALAR_31_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W2_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 31: W3_EVAL_LOC
            mstore(BATCH_SCALAR_32_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W3_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 32: W4_EVAL_LOC
            mstore(BATCH_SCALAR_33_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W4_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 33: Z_PERM_EVAL_LOC
            mstore(BATCH_SCALAR_34_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(Z_PERM_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 34: LOOKUP_INVERSES_EVAL_LOC
            mstore(BATCH_SCALAR_35_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(LOOKUP_INVERSES_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 35: LOOKUP_READ_COUNTS_EVAL_LOC
            mstore(BATCH_SCALAR_36_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(LOOKUP_READ_COUNTS_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 36: LOOKUP_READ_TAGS_EVAL_LOC
            mstore(BATCH_SCALAR_37_LOC, mulmod(neg_unshifted_scalar, batching_challenge, p))
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(LOOKUP_READ_TAGS_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // Unrolled for NUMBER_OF_SHIFTED_ENTITIES = 5
            // for (uint256 i = NUMBER_UNSHIFTED + 1; i <= NUMBER_OF_ENTITIES; ++i) {
            //     scalars[i] = mem.shiftedScalar.neg() * mem.batchingChallenge;
            //     mem.batchedEvaluation = mem.batchedEvaluation + (proof.sumcheckEvaluations[i - 1] * mem.batchingChallenge);
            //     mem.batchingChallenge = mem.batchingChallenge * tp.rho;
            // }

            // Shifted entities: SHIFTED_COMMITMENTS_START = 30
            // scalars[scalarOff] += mem.shiftedScalar.neg() * mem.batchingChallenge
            // 30: W1 (shifted)
            mstore(
                BATCH_SCALAR_30_LOC,
                addmod(mload(BATCH_SCALAR_30_LOC), mulmod(neg_shifted_scalar, batching_challenge, p), p)
            )
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W1_SHIFT_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 31: W2 (shifted)
            mstore(
                BATCH_SCALAR_31_LOC,
                addmod(mload(BATCH_SCALAR_31_LOC), mulmod(neg_shifted_scalar, batching_challenge, p), p)
            )
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W2_SHIFT_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 32: W3 (shifted)
            mstore(
                BATCH_SCALAR_32_LOC,
                addmod(mload(BATCH_SCALAR_32_LOC), mulmod(neg_shifted_scalar, batching_challenge, p), p)
            )
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W3_SHIFT_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 33: W4 (shifted)
            mstore(
                BATCH_SCALAR_33_LOC,
                addmod(mload(BATCH_SCALAR_33_LOC), mulmod(neg_shifted_scalar, batching_challenge, p), p)
            )
            batched_evaluation := addmod(batched_evaluation, mulmod(mload(W4_SHIFT_EVAL_LOC), batching_challenge, p), p)
            batching_challenge := mulmod(batching_challenge, rho, p)

            // 34: Z_PERM (shifted)
            mstore(
                BATCH_SCALAR_34_LOC,
                addmod(mload(BATCH_SCALAR_34_LOC), mulmod(neg_shifted_scalar, batching_challenge, p), p)
            )
            batched_evaluation := addmod(
                batched_evaluation,
                mulmod(mload(Z_PERM_SHIFT_EVAL_LOC), batching_challenge, p),
                p
            )
            batching_challenge := mulmod(batching_challenge, rho, p)

            // Compute fold pos evaluations
            {
                mstore(CHALL_POW_LOC, POWERS_OF_EVALUATION_CHALLENGE_21_LOC)
                mstore(SUMCHECK_U_LOC, SUM_U_CHALLENGE_21)
                mstore(GEMINI_A_LOC, GEMINI_A_EVAL_21)

                // Inversion of this value was included in batch inversion above
                let inverted_chall_pow_minus_u_loc := INVERTED_CHALLENGE_POW_MINUS_U_21_LOC
                let fold_pos_off := FOLD_POS_EVALUATIONS_21_LOC

                let batchedEvalAcc := batched_evaluation
                for { let i := LOG_N } gt(i, 0) { i := sub(i, 1) } {
                    let chall_pow := mload(mload(CHALL_POW_LOC))
                    let sum_check_u := mload(mload(SUMCHECK_U_LOC))

                    // challengePower * batchedEvalAccumulator * 2
                    let batchedEvalRoundAcc := mulmod(chall_pow, mulmod(batchedEvalAcc, 2, p), p)
                    // (challengePower * (ONE - u) - u)
                    let chall_pow_times_1_minus_u := mulmod(chall_pow, addmod(1, sub(p, sum_check_u), p), p)

                    batchedEvalRoundAcc := addmod(
                        batchedEvalRoundAcc,
                        sub(
                            p,
                            mulmod(
                                mload(mload(GEMINI_A_LOC)),
                                addmod(chall_pow_times_1_minus_u, sub(p, sum_check_u), p),
                                p
                            )
                        ),
                        p
                    )

                    batchedEvalRoundAcc := mulmod(batchedEvalRoundAcc, mload(inverted_chall_pow_minus_u_loc), p)

                    batchedEvalAcc := batchedEvalRoundAcc
                    mstore(fold_pos_off, batchedEvalRoundAcc)

                    mstore(CHALL_POW_LOC, sub(mload(CHALL_POW_LOC), 0x20))
                    mstore(SUMCHECK_U_LOC, sub(mload(SUMCHECK_U_LOC), 0x20))
                    mstore(GEMINI_A_LOC, sub(mload(GEMINI_A_LOC), 0x20))
                    inverted_chall_pow_minus_u_loc := sub(inverted_chall_pow_minus_u_loc, 0x20)
                    fold_pos_off := sub(fold_pos_off, 0x20)
                }
            }

            let constant_term_acc := mulmod(mload(FOLD_POS_EVALUATIONS_0_LOC), mload(POS_INVERTED_DENOM_0_LOC), p)
            {
                let shplonk_nu := mload(SHPLONK_NU_CHALLENGE)

                constant_term_acc := addmod(
                    constant_term_acc,
                    mulmod(mload(GEMINI_A_EVAL_0), mulmod(shplonk_nu, mload(NEG_INVERTED_DENOM_0_LOC), p), p),
                    p
                )

                let shplonk_nu_sqr := mulmod(shplonk_nu, shplonk_nu, p)
                batching_challenge := shplonk_nu_sqr

                mstore(SS_POS_INV_DENOM_LOC, POS_INVERTED_DENOM_1_LOC)
                mstore(SS_NEG_INV_DENOM_LOC, NEG_INVERTED_DENOM_1_LOC)

                mstore(SS_GEMINI_EVALS_LOC, GEMINI_A_EVAL_1)
                let fold_pos_evals_loc := FOLD_POS_EVALUATIONS_1_LOC

                let scalars_loc := BATCH_SCALAR_38_LOC

                for { let i := 0 } lt(i, sub(LOG_N, 1)) { i := add(i, 1) } {
                    let scaling_factor_pos := mulmod(batching_challenge, mload(mload(SS_POS_INV_DENOM_LOC)), p)
                    let scaling_factor_neg :=
                        mulmod(batching_challenge, mulmod(shplonk_nu, mload(mload(SS_NEG_INV_DENOM_LOC)), p), p)

                    mstore(scalars_loc, addmod(sub(p, scaling_factor_neg), sub(p, scaling_factor_pos), p))

                    let accum_contribution := mulmod(scaling_factor_neg, mload(mload(SS_GEMINI_EVALS_LOC)), p)
                    accum_contribution := addmod(
                        accum_contribution,
                        mulmod(scaling_factor_pos, mload(fold_pos_evals_loc), p),
                        p
                    )

                    constant_term_acc := addmod(constant_term_acc, accum_contribution, p)

                    batching_challenge := mulmod(batching_challenge, shplonk_nu_sqr, p)

                    mstore(SS_POS_INV_DENOM_LOC, add(mload(SS_POS_INV_DENOM_LOC), 0x20))
                    mstore(SS_NEG_INV_DENOM_LOC, add(mload(SS_NEG_INV_DENOM_LOC), 0x20))
                    mstore(SS_GEMINI_EVALS_LOC, add(mload(SS_GEMINI_EVALS_LOC), 0x20))
                    fold_pos_evals_loc := add(fold_pos_evals_loc, 0x20)
                    scalars_loc := add(scalars_loc, 0x20)
                }
            }

            // Libra polynomial batching: five opening claims for (G, A, A, A, Q) at points {r, g*r, r, 1, r}.
            {
                let shplonk_nu := mload(SHPLONK_NU_CHALLENGE)

                let libra_denom_0 := mload(POS_INVERTED_DENOM_0_LOC)        // 1/(z - r)
                let libra_denom_1 := mload(LIBRA_SUBGROUP_DENOM_LOC)        // 1/(z - g*r)

                // 1/(z - 1): boundary denominator, computed inline via the modexp precompile.
                let shplonk_z := mload(SHPLONK_Z_CHALLENGE)
                mstore(0x00, 0x20)
                mstore(0x20, 0x20)
                mstore(0x40, 0x20)
                mstore(0x60, addmod(shplonk_z, sub(p, 1), p))
                mstore(0x80, sub(p, 2))
                mstore(0xa0, p)
                if iszero(staticcall(gas(), 0x05, 0x00, 0xc0, 0x00, 0x20)) {
                    mstore(0x00, MODEXP_FAILED_SELECTOR)
                    revert(0x00, 0x04)
                }
                let libra_denom_3 := mload(0x00)
                if iszero(libra_denom_3) {
                    mstore(0x00, MODEXP_FAILED_SELECTOR)
                    revert(0x00, 0x04)
                }

                // i=0: G(r)
                let scaling_factor := mulmod(libra_denom_0, batching_challenge, p)
                let libra_scalar_0 := sub(p, scaling_factor)
                constant_term_acc := addmod(constant_term_acc, mulmod(scaling_factor, mload(LIBRA_POLY_EVAL_0_LOC), p), p)
                batching_challenge := mulmod(batching_challenge, shplonk_nu, p)

                // i=1: A(g*r)
                scaling_factor := mulmod(libra_denom_1, batching_challenge, p)
                let libra_scalar_1 := sub(p, scaling_factor)
                constant_term_acc := addmod(constant_term_acc, mulmod(scaling_factor, mload(LIBRA_POLY_EVAL_1_LOC), p), p)
                batching_challenge := mulmod(batching_challenge, shplonk_nu, p)

                // i=2: A(r)
                scaling_factor := mulmod(libra_denom_0, batching_challenge, p)
                let libra_scalar_2 := sub(p, scaling_factor)
                constant_term_acc := addmod(constant_term_acc, mulmod(scaling_factor, mload(LIBRA_POLY_EVAL_2_LOC), p), p)
                batching_challenge := mulmod(batching_challenge, shplonk_nu, p)

                // i=3: A(1), boundary opening with hardcoded value 0.
                scaling_factor := mulmod(libra_denom_3, batching_challenge, p)
                let libra_scalar_3 := sub(p, scaling_factor)
                batching_challenge := mulmod(batching_challenge, shplonk_nu, p)

                // i=4: Q(r)
                scaling_factor := mulmod(libra_denom_0, batching_challenge, p)
                let libra_scalar_4 := sub(p, scaling_factor)
                constant_term_acc := addmod(constant_term_acc, mulmod(scaling_factor, mload(LIBRA_POLY_EVAL_3_LOC), p), p)

                // Group scalars by underlying commitment: [G], [A] (sum of three openings), [Q].
                mstore(BATCH_SCALAR_59_LOC, libra_scalar_0)
                mstore(BATCH_SCALAR_60_LOC, addmod(addmod(libra_scalar_1, libra_scalar_2, p), libra_scalar_3, p))
                mstore(BATCH_SCALAR_61_LOC, libra_scalar_4)
            }

            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*            ZK: checkEvalsConsistency                     */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
            // Validates Libra polynomial evaluations using small subgroup IPA
            {
                let gemini_r := mload(GEMINI_R_CHALLENGE)

                // Step 1: Compute vanishingPolyEval = geminiR^SUBGROUP_SIZE - 1
                // SUBGROUP_SIZE = 256 = 2^8, so 8 squarings instead of modexp precompile
                let v := mulmod(gemini_r, gemini_r, p) // r^2
                v := mulmod(v, v, p)                   // r^4
                v := mulmod(v, v, p)                   // r^8
                v := mulmod(v, v, p)                   // r^16
                v := mulmod(v, v, p)                   // r^32
                v := mulmod(v, v, p)                   // r^64
                v := mulmod(v, v, p)                   // r^128
                v := mulmod(v, v, p)                   // r^256
                let vanishing_poly_eval := addmod(v, sub(p, 1), p)

                // Require vanishingPolyEval != 0 (geminiR not in subgroup)
                if iszero(vanishing_poly_eval) {
                    mstore(0x00, GEMINI_CHALLENGE_IN_SUBGROUP_SELECTOR)
                    revert(0x00, 0x04)
                }

                // Step 2: Build challengePolyLagrange[0..255]
                // Memory layout: CHALLENGE_POLY_LAGRANGE_BASE + idx * 0x20
                // Zero-initialize all 256 entries (only 1 + 9*LOG_N = 136 will be non-zero)

                mstore(CHALLENGE_POLY_LAGRANGE_BASE_0, 1) // [0] = 1

                {
                    let u_loc := SUM_U_CHALLENGE_0
                    let challenge_base := CHALLENGE_POLY_LAGRANGE_BASE_1
                    // Upper bound of this loop is LIBRA_UNIVARIATES_LENGTH * LOG_N - this is inserted in code templating depending on LOG_N
                    for { } lt(challenge_base, CHALLENGE_POLY_LAGRANGE_BASE_198) { } {
                        let u_round := mload(u_loc)

                        // [currIdx] = 1
                        mstore(challenge_base, 1)
                        challenge_base := add(challenge_base, 0x20)

                        // Calc memory offset inner loop should break at
                        let loop_target := add(challenge_base, mul(0x20, LIBRA_UNIVARIATES_LENGTH_MINUS_ONE))

                        // [currIdx+1..currIdx+8] = u^1, u^2, ..., u^8
                        let prev_val := 1
                        for { } lt(challenge_base, loop_target) { } {
                            prev_val := mulmod(prev_val, u_round, p)
                            mstore(challenge_base, prev_val)
                            challenge_base := add(challenge_base, 0x20)
                        }

                        u_loc := add(u_loc, 0x20)
                    }
                }

                // Step 3: Compute the active challenge-poly denominators and L_|H|(r)'s denominator.
                {
                    let challenge_poly_denom_end := add(CONSISTENCY_DENOMINATORS_BASE_198, 0x20)
                    let root_power := 1
                    let consistency_base := CONSISTENCY_DENOMINATORS_BASE_0
                    for { } lt(consistency_base, challenge_poly_denom_end) { } {
                        let denom := addmod(mulmod(root_power, gemini_r, p), sub(p, 1), p)
                        mstore(consistency_base, denom)
                        root_power := mulmod(root_power, SUBGROUP_GENERATOR_INVERSE, p)
                        consistency_base := add(consistency_base, 0x20)
                    }
                    mstore(
                        challenge_poly_denom_end,
                        addmod(mulmod(SUBGROUP_GENERATOR, gemini_r, p), sub(p, 1), p)
                    )
                }

                // Step 4: Batch invert the active denominators plus L_|H|(r)'s denominator.
                {
                    let final_product_pointer := add(CONSISTENCY_PRODUCTS_BASE_198, 0x20)
                    let batch_product_end := add(final_product_pointer, 0x20)

                    // Forward pass: accumulate products
                    let product_pointer := CONSISTENCY_PRODUCTS_BASE_0
                    let next_product_pointer := CONSISTENCY_PRODUCTS_BASE_1
                    let denom_pointer := CONSISTENCY_DENOMINATORS_BASE_1
                    mstore(CONSISTENCY_PRODUCTS_BASE_0, mload(CONSISTENCY_DENOMINATORS_BASE_0))
                    for { } lt(next_product_pointer, batch_product_end) { } {
                        mstore(
                            next_product_pointer,
                            mulmod(
                                mload(product_pointer),
                                mload(denom_pointer),
                                p
                            )
                        )
                        product_pointer := next_product_pointer
                        next_product_pointer := add(next_product_pointer, 0x20)
                        denom_pointer := add(denom_pointer, 0x20)
                    }

                    // Invert the final product
                    let final_prod := mload(final_product_pointer)
                    mstore(0x00, 0x20)
                    mstore(0x20, 0x20)
                    mstore(0x40, 0x20)
                    mstore(0x60, final_prod)
                    mstore(0x80, sub(p, 2))
                    mstore(0xa0, p)
                    if iszero(staticcall(gas(), 5, 0x00, 0xc0, 0x00, 0x20)) {
                        mstore(0x00, CONSISTENCY_CHECK_FAILED_SELECTOR)
                        revert(0x00, 0x04)
                    }
                    let accumulator := mload(0x00)
                    if iszero(accumulator) {
                        mstore(0x00, MODEXP_FAILED_SELECTOR)
                        revert(0x00, 0x04)
                    }

                    // Backward pass: compute individual inverses
                    let products_pointer := CONSISTENCY_PRODUCTS_BASE_198
                    let denoms_pointer := add(CONSISTENCY_DENOMINATORS_BASE_198, 0x20)
                    for { } gt(denoms_pointer, CONSISTENCY_DENOMINATORS_BASE_0) { } {
                        let val := mulmod(
                            accumulator,
                            mload(products_pointer),
                            p
                        )
                        accumulator := mulmod(
                            accumulator,
                            mload(denoms_pointer),
                            p
                        )
                        mstore(denoms_pointer, val)

                        products_pointer := sub(products_pointer, 0x20)
                        denoms_pointer := sub(denoms_pointer, 0x20)
                    }
                    // idx=0: running_inv is the inverse of denom[0]
                    mstore(CONSISTENCY_DENOMINATORS_BASE_0, accumulator)
                }

                // Step 5: Compute challengePolyEval = sum(lagrange[i] * invDenom[i]) * numerator
                let challenge_poly_eval := 0
                let challenge_poly_lagrange_end := add(CHALLENGE_POLY_LAGRANGE_BASE_198, 0x20)
                let lagrange_pointer := CHALLENGE_POLY_LAGRANGE_BASE_0
                let denom_pointer := CONSISTENCY_DENOMINATORS_BASE_0
                for { } lt(lagrange_pointer, challenge_poly_lagrange_end) { } {
                    challenge_poly_eval := addmod(
                        challenge_poly_eval,
                        mulmod(
                            mload(lagrange_pointer),
                            mload(denom_pointer),
                            p
                        ),
                        p
                    )
                    lagrange_pointer := add(lagrange_pointer, 0x20)
                    denom_pointer := add(denom_pointer, 0x20)
                }

                // numerator = vanishingPolyEval / SUBGROUP_SIZE
                let numerator := mulmod(vanishing_poly_eval, INV_SUBGROUP_SIZE, p)
                challenge_poly_eval := mulmod(challenge_poly_eval, numerator, p)

                let lagrange_first := mulmod(mload(CONSISTENCY_DENOMINATORS_BASE_0), numerator, p)
                let lagrange_last := mulmod(
                    mload(CONSISTENCY_DENOMINATORS_BASE_199),
                    numerator,
                    p
                )

                // Step 6: Compute diff and verify == 0
                // diff = lagrangeFirst * libraPolyEvals[2]
                let diff := mulmod(lagrange_first, mload(LIBRA_POLY_EVAL_2_LOC), p)

                // diff += (geminiR - SUBGROUP_GENERATOR_INVERSE) *
                //         (libraPolyEvals[1] - libraPolyEvals[2] - libraPolyEvals[0] * challengePolyEval)
                {
                    let inner := addmod(
                        mload(LIBRA_POLY_EVAL_1_LOC),
                        sub(
                            p,
                            addmod(
                                mload(LIBRA_POLY_EVAL_2_LOC),
                                mulmod(mload(LIBRA_POLY_EVAL_0_LOC), challenge_poly_eval, p),
                                p
                            )
                        ),
                        p
                    )
                    let factor := addmod(gemini_r, sub(p, SUBGROUP_GENERATOR_INVERSE), p)
                    diff := addmod(diff, mulmod(factor, inner, p), p)
                }

                // diff += lagrangeLast * (libraPolyEvals[2] - libraEval)
                diff := addmod(
                    diff,
                    mulmod(
                        lagrange_last,
                        addmod(mload(LIBRA_POLY_EVAL_2_LOC), sub(p, mload(LIBRA_EVALUATION_LOC)), p),
                        p
                    ),
                    p
                )

                // diff -= vanishingPolyEval * libraPolyEvals[3]
                diff := addmod(
                    diff,
                    sub(p, mulmod(vanishing_poly_eval, mload(LIBRA_POLY_EVAL_3_LOC), p)),
                    p
                )

                if diff {
                    mstore(0x00, CONSISTENCY_CHECK_FAILED_SELECTOR)
                    revert(0x00, 0x04)
                }
            }

            let precomp_success_flag := 1
            let q := Q // EC group order
            {
                // The initial accumulator = 1 * shplonk_q
                mcopy(ACCUMULATOR, SHPLONK_Q_X_LOC, 0x40)
            }

            // Accumulate geminiMaskingPoly (ZK commitment[1])
            {
                mcopy(G1_LOCATION, GEMINI_MASKING_POLY_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_1_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )
            }

            // Accumulate vk points
            loadVk()
            {
                // VK batchMul order matches UltraFlavor_Generated::EntityId precomputed layout.
                // Note: ZK proof has gemini_masking_poly at sumcheckEvaluations[0] paired with SCALAR_1
                // (handled separately above), so the precomputed VK entries pair with SCALAR_2..SCALAR_29.

                // Accumulator = accumulator + scalar[2] * vk[0] (sigma_1)
                mcopy(G1_LOCATION, SIGMA_1_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_2_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[3] * vk[1] (sigma_2)
                mcopy(G1_LOCATION, SIGMA_2_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_3_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[4] * vk[2] (sigma_3)
                mcopy(G1_LOCATION, SIGMA_3_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_4_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[5] * vk[3] (sigma_4)
                mcopy(G1_LOCATION, SIGMA_4_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_5_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[6] * vk[4] (id_1)
                mcopy(G1_LOCATION, ID_1_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_6_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[7] * vk[5] (id_2)
                mcopy(G1_LOCATION, ID_2_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_7_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[8] * vk[6] (id_3)
                mcopy(G1_LOCATION, ID_3_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_8_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[9] * vk[7] (id_4)
                mcopy(G1_LOCATION, ID_4_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_9_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[10] * vk[8] (lagrange_first)
                mcopy(G1_LOCATION, LAGRANGE_FIRST_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_10_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[11] * vk[9] (lagrange_last)
                mcopy(G1_LOCATION, LAGRANGE_LAST_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_11_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[12] * vk[10] (q_lookup)
                mcopy(G1_LOCATION, Q_LOOKUP_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_12_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[13] * vk[11] (table_1)
                mcopy(G1_LOCATION, TABLE_1_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_13_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[14] * vk[12] (table_2)
                mcopy(G1_LOCATION, TABLE_2_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_14_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[15] * vk[13] (table_3)
                mcopy(G1_LOCATION, TABLE_3_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_15_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[16] * vk[14] (table_4)
                mcopy(G1_LOCATION, TABLE_4_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_16_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[17] * vk[15] (q_m)
                mcopy(G1_LOCATION, Q_M_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_17_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[18] * vk[16] (q_r)
                mcopy(G1_LOCATION, Q_R_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_18_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[19] * vk[17] (q_o)
                mcopy(G1_LOCATION, Q_O_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_19_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[20] * vk[18] (q_c)
                mcopy(G1_LOCATION, Q_C_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_20_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[21] * vk[19] (q_l)
                mcopy(G1_LOCATION, Q_L_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_21_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[22] * vk[20] (q_4)
                mcopy(G1_LOCATION, Q_4_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_22_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[23] * vk[21] (q_arith)
                mcopy(G1_LOCATION, Q_ARITH_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_23_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[24] * vk[22] (q_delta_range)
                mcopy(G1_LOCATION, Q_DELTA_RANGE_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_24_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[25] * vk[23] (q_elliptic)
                mcopy(G1_LOCATION, Q_ELLIPTIC_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_25_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[26] * vk[24] (q_memory)
                mcopy(G1_LOCATION, Q_MEMORY_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_26_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[27] * vk[25] (q_nnf)
                mcopy(G1_LOCATION, Q_NNF_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_27_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[28] * vk[26] (q_poseidon2_external)
                mcopy(G1_LOCATION, Q_POSEIDON_2_EXTERNAL_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_28_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[29] * vk[27] (q_poseidon2_internal)
                mcopy(G1_LOCATION, Q_POSEIDON_2_INTERNAL_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_29_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + constant_term_acc * G (generator)
                mstore(G1_LOCATION, 0x01)   // G1 generator x
                mstore(G1_Y_LOCATION, 0x02) // G1 generator y
                mstore(SCALAR_LOCATION, constant_term_acc)
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulate proof points
                // Accumulator = accumulator + scalar[29] * w_l
                mcopy(G1_LOCATION, W_L_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_30_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[30] * w_r
                mcopy(G1_LOCATION, W_R_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_31_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[31] * w_o
                mcopy(G1_LOCATION, W_O_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_32_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[32] * w_4
                mcopy(G1_LOCATION, W_4_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_33_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[33] * z_perm
                mcopy(G1_LOCATION, Z_PERM_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_34_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[34] * lookup_inverses
                mcopy(G1_LOCATION, LOOKUP_INVERSES_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_35_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[35] * lookup_read_counts
                mcopy(G1_LOCATION, LOOKUP_READ_COUNTS_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_36_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulator = accumulator + scalar[36] * lookup_read_tags
                mcopy(G1_LOCATION, LOOKUP_READ_TAGS_X_LOC, 0x40)
                mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_37_LOC))
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                )
                precomp_success_flag := and(
                    precomp_success_flag,
                    staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                )

                // Accumulate these LOG_N scalars with the gemini fold univariates
                {
                    {
                        /// {{ UNROLL_SECTION_START ACCUMULATE_GEMINI_FOLD_UNIVARIATE }}
                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_0_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_38_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_1_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_39_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_2_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_40_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_3_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_41_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_4_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_42_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_5_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_43_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_6_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_44_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_7_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_45_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_8_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_46_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_9_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_47_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_10_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_48_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_11_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_49_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_12_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_50_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_13_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_51_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_14_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_52_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_15_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_53_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_16_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_54_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_17_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_55_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_18_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_56_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_19_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_57_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))

                        mcopy(G1_LOCATION, GEMINI_FOLD_UNIVARIATE_20_X_LOC, 0x40)
                        mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_58_LOC))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40))
                        precomp_success_flag :=
                            and(precomp_success_flag, staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40))
/// {{ UNROLL_SECTION_END ACCUMULATE_GEMINI_FOLD_UNIVARIATE }}
                    }
                }

                // Accumulate libra commitments (ZK)
                {
                    // scalar[52] * libraConcat (libraCommitments[0])
                    mcopy(G1_LOCATION, LIBRA_CONCAT_X_LOC, 0x40)
                    mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_59_LOC))
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                    )
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                    )

                    // scalar[53] * libraGrandProduct (libraCommitments[1])
                    mcopy(G1_LOCATION, LIBRA_GRAND_PRODUCT_X_LOC, 0x40)
                    mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_60_LOC))
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                    )
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                    )

                    // scalar[54] * libraQuotient (libraCommitments[2])
                    mcopy(G1_LOCATION, LIBRA_QUOTIENT_X_LOC, 0x40)
                    mstore(SCALAR_LOCATION, mload(BATCH_SCALAR_61_LOC))
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                    )
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                    )
                }

                {
                    // Accumlate final quotient commitment into shplonk check
                    // Accumulator = accumulator + shplonkZ * quotient commitment
                    mcopy(G1_LOCATION, KZG_QUOTIENT_X_LOC, 0x40)

                    mstore(SCALAR_LOCATION, mload(SHPLONK_Z_CHALLENGE))
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 7, G1_LOCATION, 0x60, ACCUMULATOR_2, 0x40)
                    )
                    precomp_success_flag := and(
                        precomp_success_flag,
                        staticcall(gas(), 6, ACCUMULATOR, 0x80, ACCUMULATOR, 0x40)
                    )
                }

                // All G1 points were validated on-curve during input validation.
                // precomp_success_flag now only tracks ecAdd/ecMul precompile success.
                if iszero(precomp_success_flag) {
                    mstore(0x00, SHPLEMINI_FAILED_SELECTOR)
                    revert(0x00, 0x04)
                }

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                  SHPLEMINI - complete                      */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

                /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                /*                       PAIRING CHECK                        */
                /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                {
                    // P_1
                    mstore(0xc0, mload(KZG_QUOTIENT_X_LOC))
                    mstore(0xe0, sub(q, mload(KZG_QUOTIENT_Y_LOC)))

                    // p_0_agg
                    // 0x80 - p_0_agg x
                    // 0xa0 - p_0_agg y
                    mcopy(0x80, ACCUMULATOR, 0x40)

                    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                    /*                   PAIRING AGGREGATION                      */
                    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                    // Read the pairing encoded in the first 8 field elements of the proof (2 limbs per coordinate)
                    let p0_other_x := mload(PAIRING_POINT_0_X_0_LOC)
                    p0_other_x := or(shl(136, mload(PAIRING_POINT_0_X_1_LOC)), p0_other_x)

                    let p0_other_y := mload(PAIRING_POINT_0_Y_0_LOC)
                    p0_other_y := or(shl(136, mload(PAIRING_POINT_0_Y_1_LOC)), p0_other_y)

                    let p1_other_x := mload(PAIRING_POINT_1_X_0_LOC)
                    p1_other_x := or(shl(136, mload(PAIRING_POINT_1_X_1_LOC)), p1_other_x)

                    let p1_other_y := mload(PAIRING_POINT_1_Y_0_LOC)
                    p1_other_y := or(shl(136, mload(PAIRING_POINT_1_Y_1_LOC)), p1_other_y)

                    // Check if pairing points are default (all zero = infinity = no recursive verification)
                    let pairing_points_are_default := iszero(or(or(p0_other_x, p0_other_y), or(p1_other_x, p1_other_y)))

                    let success := 1
                    // Only aggregate if pairing points are non-default
                    if iszero(pairing_points_are_default) {
                        // Reconstructed coordinates must be < Q to prevent malleability
                        if iszero(and(
                            and(lt(p0_other_x, q), lt(p0_other_y, q)),
                            and(lt(p1_other_x, q), lt(p1_other_y, q))
                        )) {
                            mstore(0x00, VALUE_GE_GROUP_ORDER_SELECTOR)
                            revert(0x00, 0x04)
                        }

                        // Validate p_0_other not point of infinity
                        success := iszero(iszero(or(p0_other_x, p0_other_y)))
                        // Validate p_1_other not point of infinity
                        success := and(success, iszero(iszero(or(p1_other_x, p1_other_y))))

                        // p_0
                        mstore(0x00, p0_other_x)
                        mstore(0x20, p0_other_y)

                        // p_1
                        mstore(0x40, p1_other_x)
                        mstore(0x60, p1_other_y)

                        // p_1_agg is already in the correct location

                        let recursion_separator := keccak256(0x00, 0x100)

                        // Write separator back to scratch space
                        mstore(0x00, p0_other_x)

                        mstore(0x40, recursion_separator)
                        // recursion_separator * p_0_other
                        success := and(success, staticcall(gas(), 0x07, 0x00, 0x60, 0x00, 0x40))

                        // (recursion_separator * p_0_other) + p_0_agg
                        mcopy(0x40, 0x80, 0x40)
                        // p_0 = (recursion_separator * p_0_other) + p_0_agg
                        success := and(success, staticcall(gas(), 6, 0x00, 0x80, 0x00, 0x40))

                        mstore(0x40, p1_other_x)
                        mstore(0x60, p1_other_y)
                        mstore(0x80, recursion_separator)

                        success := and(success, staticcall(gas(), 7, 0x40, 0x60, 0x40, 0x40))

                        // Write p_1_agg back to scratch space
                        mcopy(0x80, 0xc0, 0x40)

                        // 0xc0 - (recursion_separator * p_1_other) + p_1_agg
                        success := and(success, staticcall(gas(), 6, 0x40, 0x80, 0xc0, 0x40))
                    }
                    // If default pairing points, use p_0_agg and p_1_agg directly (already at 0x80, 0xc0)
                    if pairing_points_are_default {
                        // Copy p_0_agg to 0x00 for pairing input
                        mcopy(0x00, 0x80, 0x40)
                        // p_1_agg stays at 0xc0
                    }

                    // G2 [1]
                    mstore(0x40, 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2)
                    mstore(0x60, 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed)
                    mstore(0x80, 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b)
                    mstore(0xa0, 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa)

                    // G2 [x]
                    mstore(0x100, 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1)
                    mstore(0x120, 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0)
                    mstore(0x140, 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4)
                    mstore(0x160, 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55)

                    let pairing_success := and(success, staticcall(gas(), 8, 0x00, 0x180, 0x00, 0x20))
                    if iszero(and(pairing_success, mload(0x00))) {
                        mstore(0x00, SHPLEMINI_FAILED_SELECTOR)
                        revert(0x00, 0x04)
                    }

                    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
                    /*                PAIRING CHECK - Complete                    */
                    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
                }
                {
                    mstore(0x00, 0x01)
                    return(0x00, 0x20) // Proof succeeded!
                }
            }
        }
    }
}
