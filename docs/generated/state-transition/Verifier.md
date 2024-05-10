## Verifier

Modified version of the Permutations over Lagrange-bases for Oecumenical Noninteractive arguments of
Knowledge (PLONK) verifier.
Modifications have been made to optimize the proof system for zkSync hyperchain circuits.

_It uses a custom memory layout inside the inline assembly block. Each reserved memory cell is declared in the
constants below.
For a better understanding of the verifier algorithm please refer to the following papers:
* Original Plonk Article: https://eprint.iacr.org/2019/953.pdf
* Original LookUp Article: https://eprint.iacr.org/2020/315.pdf
* Plonk for zkSync v1.1: https://github.com/matter-labs/solidity_plonk_verifier/raw/recursive/bellman_vk_codegen_recursive/RecursivePlonkUnrolledForEthereum.pdf
The notation used in the code is the same as in the papers._

### VK_GATE_SETUP_0_X_SLOT

```solidity
uint256 VK_GATE_SETUP_0_X_SLOT
```

### VK_GATE_SETUP_0_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_0_Y_SLOT
```

### VK_GATE_SETUP_1_X_SLOT

```solidity
uint256 VK_GATE_SETUP_1_X_SLOT
```

### VK_GATE_SETUP_1_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_1_Y_SLOT
```

### VK_GATE_SETUP_2_X_SLOT

```solidity
uint256 VK_GATE_SETUP_2_X_SLOT
```

### VK_GATE_SETUP_2_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_2_Y_SLOT
```

### VK_GATE_SETUP_3_X_SLOT

```solidity
uint256 VK_GATE_SETUP_3_X_SLOT
```

### VK_GATE_SETUP_3_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_3_Y_SLOT
```

### VK_GATE_SETUP_4_X_SLOT

```solidity
uint256 VK_GATE_SETUP_4_X_SLOT
```

### VK_GATE_SETUP_4_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_4_Y_SLOT
```

### VK_GATE_SETUP_5_X_SLOT

```solidity
uint256 VK_GATE_SETUP_5_X_SLOT
```

### VK_GATE_SETUP_5_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_5_Y_SLOT
```

### VK_GATE_SETUP_6_X_SLOT

```solidity
uint256 VK_GATE_SETUP_6_X_SLOT
```

### VK_GATE_SETUP_6_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_6_Y_SLOT
```

### VK_GATE_SETUP_7_X_SLOT

```solidity
uint256 VK_GATE_SETUP_7_X_SLOT
```

### VK_GATE_SETUP_7_Y_SLOT

```solidity
uint256 VK_GATE_SETUP_7_Y_SLOT
```

### VK_GATE_SELECTORS_0_X_SLOT

```solidity
uint256 VK_GATE_SELECTORS_0_X_SLOT
```

### VK_GATE_SELECTORS_0_Y_SLOT

```solidity
uint256 VK_GATE_SELECTORS_0_Y_SLOT
```

### VK_GATE_SELECTORS_1_X_SLOT

```solidity
uint256 VK_GATE_SELECTORS_1_X_SLOT
```

### VK_GATE_SELECTORS_1_Y_SLOT

```solidity
uint256 VK_GATE_SELECTORS_1_Y_SLOT
```

### VK_PERMUTATION_0_X_SLOT

```solidity
uint256 VK_PERMUTATION_0_X_SLOT
```

### VK_PERMUTATION_0_Y_SLOT

```solidity
uint256 VK_PERMUTATION_0_Y_SLOT
```

### VK_PERMUTATION_1_X_SLOT

```solidity
uint256 VK_PERMUTATION_1_X_SLOT
```

### VK_PERMUTATION_1_Y_SLOT

```solidity
uint256 VK_PERMUTATION_1_Y_SLOT
```

### VK_PERMUTATION_2_X_SLOT

```solidity
uint256 VK_PERMUTATION_2_X_SLOT
```

### VK_PERMUTATION_2_Y_SLOT

```solidity
uint256 VK_PERMUTATION_2_Y_SLOT
```

### VK_PERMUTATION_3_X_SLOT

```solidity
uint256 VK_PERMUTATION_3_X_SLOT
```

### VK_PERMUTATION_3_Y_SLOT

```solidity
uint256 VK_PERMUTATION_3_Y_SLOT
```

### VK_LOOKUP_SELECTOR_X_SLOT

```solidity
uint256 VK_LOOKUP_SELECTOR_X_SLOT
```

### VK_LOOKUP_SELECTOR_Y_SLOT

```solidity
uint256 VK_LOOKUP_SELECTOR_Y_SLOT
```

### VK_LOOKUP_TABLE_0_X_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_0_X_SLOT
```

### VK_LOOKUP_TABLE_0_Y_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_0_Y_SLOT
```

### VK_LOOKUP_TABLE_1_X_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_1_X_SLOT
```

### VK_LOOKUP_TABLE_1_Y_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_1_Y_SLOT
```

### VK_LOOKUP_TABLE_2_X_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_2_X_SLOT
```

### VK_LOOKUP_TABLE_2_Y_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_2_Y_SLOT
```

### VK_LOOKUP_TABLE_3_X_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_3_X_SLOT
```

### VK_LOOKUP_TABLE_3_Y_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_3_Y_SLOT
```

### VK_LOOKUP_TABLE_TYPE_X_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_TYPE_X_SLOT
```

### VK_LOOKUP_TABLE_TYPE_Y_SLOT

```solidity
uint256 VK_LOOKUP_TABLE_TYPE_Y_SLOT
```

### VK_RECURSIVE_FLAG_SLOT

```solidity
uint256 VK_RECURSIVE_FLAG_SLOT
```

### PROOF_PUBLIC_INPUT

```solidity
uint256 PROOF_PUBLIC_INPUT
```

### PROOF_STATE_POLYS_0_X_SLOT

```solidity
uint256 PROOF_STATE_POLYS_0_X_SLOT
```

### PROOF_STATE_POLYS_0_Y_SLOT

```solidity
uint256 PROOF_STATE_POLYS_0_Y_SLOT
```

### PROOF_STATE_POLYS_1_X_SLOT

```solidity
uint256 PROOF_STATE_POLYS_1_X_SLOT
```

### PROOF_STATE_POLYS_1_Y_SLOT

```solidity
uint256 PROOF_STATE_POLYS_1_Y_SLOT
```

### PROOF_STATE_POLYS_2_X_SLOT

```solidity
uint256 PROOF_STATE_POLYS_2_X_SLOT
```

### PROOF_STATE_POLYS_2_Y_SLOT

```solidity
uint256 PROOF_STATE_POLYS_2_Y_SLOT
```

### PROOF_STATE_POLYS_3_X_SLOT

```solidity
uint256 PROOF_STATE_POLYS_3_X_SLOT
```

### PROOF_STATE_POLYS_3_Y_SLOT

```solidity
uint256 PROOF_STATE_POLYS_3_Y_SLOT
```

### PROOF_COPY_PERMUTATION_GRAND_PRODUCT_X_SLOT

```solidity
uint256 PROOF_COPY_PERMUTATION_GRAND_PRODUCT_X_SLOT
```

### PROOF_COPY_PERMUTATION_GRAND_PRODUCT_Y_SLOT

```solidity
uint256 PROOF_COPY_PERMUTATION_GRAND_PRODUCT_Y_SLOT
```

### PROOF_LOOKUP_S_POLY_X_SLOT

```solidity
uint256 PROOF_LOOKUP_S_POLY_X_SLOT
```

### PROOF_LOOKUP_S_POLY_Y_SLOT

```solidity
uint256 PROOF_LOOKUP_S_POLY_Y_SLOT
```

### PROOF_LOOKUP_GRAND_PRODUCT_X_SLOT

```solidity
uint256 PROOF_LOOKUP_GRAND_PRODUCT_X_SLOT
```

### PROOF_LOOKUP_GRAND_PRODUCT_Y_SLOT

```solidity
uint256 PROOF_LOOKUP_GRAND_PRODUCT_Y_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_0_X_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_0_X_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_0_Y_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_0_Y_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_1_X_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_1_X_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_1_Y_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_1_Y_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_2_X_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_2_X_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_2_Y_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_2_Y_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_3_X_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_3_X_SLOT
```

### PROOF_QUOTIENT_POLY_PARTS_3_Y_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_PARTS_3_Y_SLOT
```

### PROOF_STATE_POLYS_0_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_STATE_POLYS_0_OPENING_AT_Z_SLOT
```

### PROOF_STATE_POLYS_1_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_STATE_POLYS_1_OPENING_AT_Z_SLOT
```

### PROOF_STATE_POLYS_2_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_STATE_POLYS_2_OPENING_AT_Z_SLOT
```

### PROOF_STATE_POLYS_3_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_STATE_POLYS_3_OPENING_AT_Z_SLOT
```

### PROOF_STATE_POLYS_3_OPENING_AT_Z_OMEGA_SLOT

```solidity
uint256 PROOF_STATE_POLYS_3_OPENING_AT_Z_OMEGA_SLOT
```

### PROOF_GATE_SELECTORS_0_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_GATE_SELECTORS_0_OPENING_AT_Z_SLOT
```

### PROOF_COPY_PERMUTATION_POLYS_0_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_COPY_PERMUTATION_POLYS_0_OPENING_AT_Z_SLOT
```

### PROOF_COPY_PERMUTATION_POLYS_1_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_COPY_PERMUTATION_POLYS_1_OPENING_AT_Z_SLOT
```

### PROOF_COPY_PERMUTATION_POLYS_2_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_COPY_PERMUTATION_POLYS_2_OPENING_AT_Z_SLOT
```

### PROOF_COPY_PERMUTATION_GRAND_PRODUCT_OPENING_AT_Z_OMEGA_SLOT

```solidity
uint256 PROOF_COPY_PERMUTATION_GRAND_PRODUCT_OPENING_AT_Z_OMEGA_SLOT
```

### PROOF_LOOKUP_S_POLY_OPENING_AT_Z_OMEGA_SLOT

```solidity
uint256 PROOF_LOOKUP_S_POLY_OPENING_AT_Z_OMEGA_SLOT
```

### PROOF_LOOKUP_GRAND_PRODUCT_OPENING_AT_Z_OMEGA_SLOT

```solidity
uint256 PROOF_LOOKUP_GRAND_PRODUCT_OPENING_AT_Z_OMEGA_SLOT
```

### PROOF_LOOKUP_T_POLY_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_LOOKUP_T_POLY_OPENING_AT_Z_SLOT
```

### PROOF_LOOKUP_T_POLY_OPENING_AT_Z_OMEGA_SLOT

```solidity
uint256 PROOF_LOOKUP_T_POLY_OPENING_AT_Z_OMEGA_SLOT
```

### PROOF_LOOKUP_SELECTOR_POLY_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_LOOKUP_SELECTOR_POLY_OPENING_AT_Z_SLOT
```

### PROOF_LOOKUP_TABLE_TYPE_POLY_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_LOOKUP_TABLE_TYPE_POLY_OPENING_AT_Z_SLOT
```

### PROOF_QUOTIENT_POLY_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_QUOTIENT_POLY_OPENING_AT_Z_SLOT
```

### PROOF_LINEARISATION_POLY_OPENING_AT_Z_SLOT

```solidity
uint256 PROOF_LINEARISATION_POLY_OPENING_AT_Z_SLOT
```

### PROOF_OPENING_PROOF_AT_Z_X_SLOT

```solidity
uint256 PROOF_OPENING_PROOF_AT_Z_X_SLOT
```

### PROOF_OPENING_PROOF_AT_Z_Y_SLOT

```solidity
uint256 PROOF_OPENING_PROOF_AT_Z_Y_SLOT
```

### PROOF_OPENING_PROOF_AT_Z_OMEGA_X_SLOT

```solidity
uint256 PROOF_OPENING_PROOF_AT_Z_OMEGA_X_SLOT
```

### PROOF_OPENING_PROOF_AT_Z_OMEGA_Y_SLOT

```solidity
uint256 PROOF_OPENING_PROOF_AT_Z_OMEGA_Y_SLOT
```

### PROOF_RECURSIVE_PART_P1_X_SLOT

```solidity
uint256 PROOF_RECURSIVE_PART_P1_X_SLOT
```

### PROOF_RECURSIVE_PART_P1_Y_SLOT

```solidity
uint256 PROOF_RECURSIVE_PART_P1_Y_SLOT
```

### PROOF_RECURSIVE_PART_P2_X_SLOT

```solidity
uint256 PROOF_RECURSIVE_PART_P2_X_SLOT
```

### PROOF_RECURSIVE_PART_P2_Y_SLOT

```solidity
uint256 PROOF_RECURSIVE_PART_P2_Y_SLOT
```

### TRANSCRIPT_BEGIN_SLOT

```solidity
uint256 TRANSCRIPT_BEGIN_SLOT
```

### TRANSCRIPT_DST_BYTE_SLOT

```solidity
uint256 TRANSCRIPT_DST_BYTE_SLOT
```

### TRANSCRIPT_STATE_0_SLOT

```solidity
uint256 TRANSCRIPT_STATE_0_SLOT
```

### TRANSCRIPT_STATE_1_SLOT

```solidity
uint256 TRANSCRIPT_STATE_1_SLOT
```

### TRANSCRIPT_CHALLENGE_SLOT

```solidity
uint256 TRANSCRIPT_CHALLENGE_SLOT
```

### STATE_ALPHA_SLOT

```solidity
uint256 STATE_ALPHA_SLOT
```

### STATE_BETA_SLOT

```solidity
uint256 STATE_BETA_SLOT
```

### STATE_GAMMA_SLOT

```solidity
uint256 STATE_GAMMA_SLOT
```

### STATE_POWER_OF_ALPHA_2_SLOT

```solidity
uint256 STATE_POWER_OF_ALPHA_2_SLOT
```

### STATE_POWER_OF_ALPHA_3_SLOT

```solidity
uint256 STATE_POWER_OF_ALPHA_3_SLOT
```

### STATE_POWER_OF_ALPHA_4_SLOT

```solidity
uint256 STATE_POWER_OF_ALPHA_4_SLOT
```

### STATE_POWER_OF_ALPHA_5_SLOT

```solidity
uint256 STATE_POWER_OF_ALPHA_5_SLOT
```

### STATE_POWER_OF_ALPHA_6_SLOT

```solidity
uint256 STATE_POWER_OF_ALPHA_6_SLOT
```

### STATE_POWER_OF_ALPHA_7_SLOT

```solidity
uint256 STATE_POWER_OF_ALPHA_7_SLOT
```

### STATE_POWER_OF_ALPHA_8_SLOT

```solidity
uint256 STATE_POWER_OF_ALPHA_8_SLOT
```

### STATE_ETA_SLOT

```solidity
uint256 STATE_ETA_SLOT
```

### STATE_BETA_LOOKUP_SLOT

```solidity
uint256 STATE_BETA_LOOKUP_SLOT
```

### STATE_GAMMA_LOOKUP_SLOT

```solidity
uint256 STATE_GAMMA_LOOKUP_SLOT
```

### STATE_BETA_PLUS_ONE_SLOT

```solidity
uint256 STATE_BETA_PLUS_ONE_SLOT
```

### STATE_BETA_GAMMA_PLUS_GAMMA_SLOT

```solidity
uint256 STATE_BETA_GAMMA_PLUS_GAMMA_SLOT
```

### STATE_V_SLOT

```solidity
uint256 STATE_V_SLOT
```

### STATE_U_SLOT

```solidity
uint256 STATE_U_SLOT
```

### STATE_Z_SLOT

```solidity
uint256 STATE_Z_SLOT
```

### STATE_Z_MINUS_LAST_OMEGA_SLOT

```solidity
uint256 STATE_Z_MINUS_LAST_OMEGA_SLOT
```

### STATE_L_0_AT_Z_SLOT

```solidity
uint256 STATE_L_0_AT_Z_SLOT
```

### STATE_L_N_MINUS_ONE_AT_Z_SLOT

```solidity
uint256 STATE_L_N_MINUS_ONE_AT_Z_SLOT
```

### STATE_Z_IN_DOMAIN_SIZE

```solidity
uint256 STATE_Z_IN_DOMAIN_SIZE
```

### QUERIES_BUFFER_POINT_SLOT

```solidity
uint256 QUERIES_BUFFER_POINT_SLOT
```

### QUERIES_AT_Z_0_X_SLOT

```solidity
uint256 QUERIES_AT_Z_0_X_SLOT
```

### QUERIES_AT_Z_0_Y_SLOT

```solidity
uint256 QUERIES_AT_Z_0_Y_SLOT
```

### QUERIES_AT_Z_1_X_SLOT

```solidity
uint256 QUERIES_AT_Z_1_X_SLOT
```

### QUERIES_AT_Z_1_Y_SLOT

```solidity
uint256 QUERIES_AT_Z_1_Y_SLOT
```

### QUERIES_T_POLY_AGGREGATED_X_SLOT

```solidity
uint256 QUERIES_T_POLY_AGGREGATED_X_SLOT
```

### QUERIES_T_POLY_AGGREGATED_Y_SLOT

```solidity
uint256 QUERIES_T_POLY_AGGREGATED_Y_SLOT
```

### AGGREGATED_AT_Z_X_SLOT

```solidity
uint256 AGGREGATED_AT_Z_X_SLOT
```

### AGGREGATED_AT_Z_Y_SLOT

```solidity
uint256 AGGREGATED_AT_Z_Y_SLOT
```

### AGGREGATED_AT_Z_OMEGA_X_SLOT

```solidity
uint256 AGGREGATED_AT_Z_OMEGA_X_SLOT
```

### AGGREGATED_AT_Z_OMEGA_Y_SLOT

```solidity
uint256 AGGREGATED_AT_Z_OMEGA_Y_SLOT
```

### AGGREGATED_OPENING_AT_Z_SLOT

```solidity
uint256 AGGREGATED_OPENING_AT_Z_SLOT
```

### AGGREGATED_OPENING_AT_Z_OMEGA_SLOT

```solidity
uint256 AGGREGATED_OPENING_AT_Z_OMEGA_SLOT
```

### PAIRING_BUFFER_POINT_X_SLOT

```solidity
uint256 PAIRING_BUFFER_POINT_X_SLOT
```

### PAIRING_BUFFER_POINT_Y_SLOT

```solidity
uint256 PAIRING_BUFFER_POINT_Y_SLOT
```

### PAIRING_PAIR_WITH_GENERATOR_X_SLOT

```solidity
uint256 PAIRING_PAIR_WITH_GENERATOR_X_SLOT
```

### PAIRING_PAIR_WITH_GENERATOR_Y_SLOT

```solidity
uint256 PAIRING_PAIR_WITH_GENERATOR_Y_SLOT
```

### PAIRING_PAIR_WITH_X_X_SLOT

```solidity
uint256 PAIRING_PAIR_WITH_X_X_SLOT
```

### PAIRING_PAIR_WITH_X_Y_SLOT

```solidity
uint256 PAIRING_PAIR_WITH_X_Y_SLOT
```

### COPY_PERMUTATION_FIRST_AGGREGATED_COMMITMENT_COEFF

```solidity
uint256 COPY_PERMUTATION_FIRST_AGGREGATED_COMMITMENT_COEFF
```

### LOOKUP_GRAND_PRODUCT_FIRST_AGGREGATED_COMMITMENT_COEFF

```solidity
uint256 LOOKUP_GRAND_PRODUCT_FIRST_AGGREGATED_COMMITMENT_COEFF
```

### LOOKUP_S_FIRST_AGGREGATED_COMMITMENT_COEFF

```solidity
uint256 LOOKUP_S_FIRST_AGGREGATED_COMMITMENT_COEFF
```

### OMEGA

```solidity
uint256 OMEGA
```

### DOMAIN_SIZE

```solidity
uint256 DOMAIN_SIZE
```

### Q_MOD

```solidity
uint256 Q_MOD
```

### R_MOD

```solidity
uint256 R_MOD
```

### FR_MASK

```solidity
uint256 FR_MASK
```

_flip of 0xe000000000000000000000000000000000000000000000000000000000000000;_

### NON_RESIDUES_0

```solidity
uint256 NON_RESIDUES_0
```

### NON_RESIDUES_1

```solidity
uint256 NON_RESIDUES_1
```

### NON_RESIDUES_2

```solidity
uint256 NON_RESIDUES_2
```

### G2_ELEMENTS_0_X1

```solidity
uint256 G2_ELEMENTS_0_X1
```

### G2_ELEMENTS_0_X2

```solidity
uint256 G2_ELEMENTS_0_X2
```

### G2_ELEMENTS_0_Y1

```solidity
uint256 G2_ELEMENTS_0_Y1
```

### G2_ELEMENTS_0_Y2

```solidity
uint256 G2_ELEMENTS_0_Y2
```

### G2_ELEMENTS_1_X1

```solidity
uint256 G2_ELEMENTS_1_X1
```

### G2_ELEMENTS_1_X2

```solidity
uint256 G2_ELEMENTS_1_X2
```

### G2_ELEMENTS_1_Y1

```solidity
uint256 G2_ELEMENTS_1_Y1
```

### G2_ELEMENTS_1_Y2

```solidity
uint256 G2_ELEMENTS_1_Y2
```

### verificationKeyHash

```solidity
function verificationKeyHash() external pure returns (bytes32 vkHash)
```

Calculates a keccak256 hash of the runtime loaded verification keys.

| Name | Type | Description |
| ---- | ---- | ----------- |
| vkHash | bytes32 | vkHash The keccak256 hash of the loaded verification keys. |

### _loadVerificationKey

```solidity
function _loadVerificationKey() internal pure virtual
```

Load verification keys to memory in runtime.

_The constants are loaded into memory in a specific layout declared in the constants starting from
`VK_` prefix.
NOTE: Function may corrupt the memory state if some memory was used before this function was called.
The VK consists of commitments to setup polynomials:
[q_a], [q_b], [q_c], [q_d],                  - main gate setup commitments
[q_{d_next}], [q_ab], [q_ac], [q_const]      /
[main_gate_selector], [custom_gate_selector] - gate selectors commitments
[sigma_0], [sigma_1], [sigma_2], [sigma_3]   - permutation polynomials commitments
[lookup_selector]                            - lookup selector commitment
[col_0], [col_1], [col_2], [col_3]           - lookup columns commitments
[table_type]                                 - lookup table type commitment_

### verify

```solidity
function verify(uint256[], uint256[], uint256[]) public view virtual returns (bool)
```

_Verifies a zk-SNARK proof._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | A boolean value indicating whether the zk-SNARK proof is valid. Note: The function may revert execution instead of returning false in some cases. |

