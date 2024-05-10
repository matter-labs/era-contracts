## VerifierTest

### test

```solidity
function test() internal virtual
```

### _loadVerificationKey

```solidity
function _loadVerificationKey() internal pure
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

