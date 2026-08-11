# Tool for generating verifier contracts using JSON verification keys

## Usage

The tool supports two variants for generating verifier contracts:

### 1. ZKsyncOS Variant

Generates the PLONK verifier used by ZKsync OS:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --variant zksync-os
```

This will:

- Use input file: `data/ZKsyncOS_plonk_scheduler_key.json`
- Generate output: `data/ZKsyncOSVerifierPlonk.sol`

### 2. Custom Variant (Default)

Allows specifying custom paths for both input and output files:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --variant custom --plonk_input_path /path/to/plonk_scheduler_verification_key.json --fflonk_input_path /path/to/fflonk_scheduler_verification_key.json --plonk_output_path /path/to/VerifierPlonk.sol --fflonk_output_path /path/to/VerifierFflonk.sol
```

Omitting the `--variant` flag defaults to `custom` behavior:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --plonk_input_path data/plonk_scheduler_key.json --fflonk_input_path data/fflonk_scheduler_key.json --plonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierPlonk.sol --fflonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierFflonk.sol
```
