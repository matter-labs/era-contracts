# Tool for generating Plonk & Fflonk verifier contracts using json verification keys

## Usage

The tool supports three variants for generating verifier contracts:

### 1. Era Variant

Automatically uses Era-prefixed key files and generates Era-prefixed output files:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --variant era
```

This will:

- Use input files: `data/Era_plonk_scheduler_key.json`, `data/Era_fflonk_scheduler_key.json`
- Generate outputs: `data/EraVerifierPlonk.sol`, `data/EraVerifierFflonk.sol`

### 2. ZKsyncOS Variant

Automatically uses ZKsyncOS-prefixed key files and generates ZKsyncOS-prefixed output files:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --variant zksync-os
```

This will:

- Use input files: `data/ZKsyncOS_plonk_scheduler_key.json`, `data/ZKsyncOS_fflonk_scheduler_key.json`
- Generate outputs: `data/ZKsyncOSVerifierPlonk.sol`, `data/ZKsyncOSVerifierFflonk.sol`

### 3. Airbender Variant

Generates only the PLONK verifier for the Airbender (RISC-V) FRI proof wrapped into a PLONK SNARK. Airbender has no
FFLONK wrapper today, so no FFLONK contract is produced. Its verification key (`data/airbender_snark_vk.json`) is the
`snark_vk.json` published with the verifier release — the same key the prover server proves against — so the two must be
regenerated together. The verifier now releases from the private `zksync-protocol-private` monorepo, on its own
`eravm-airbender-verifier-v*` tag line, so downloading the key needs `gh` authenticated against that repository.

Use the wrapper script, which downloads the key from the pinned release and runs codegen:

```shell
./regenerate-airbender-verifier.sh                                   # uses the default pinned tag
./regenerate-airbender-verifier.sh eravm-airbender-verifier-v31.2.0  # or an explicit tag
```

This will:

- Download `snark_vk.json` into `data/airbender_snark_vk.json` (gitignored).
- Generate `data/AirbenderVerifierPlonk.sol` (contract `AirbenderVerifierPlonk`).
- Copy it to `../l1-contracts/contracts/state-transition/verifiers/AirbenderVerifierPlonk.sol`.

The pinned tag **must** match the `zksync_airbender_verifier` tag in `airbender_prover_server/Cargo.toml`; otherwise the
on-chain verifier and the prover's VK drift and proofs will not verify. To run codegen directly against an
already-downloaded key:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --variant airbender
```

### 4. Custom Variant (Default)

Allows specifying custom paths for both input and output files:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --variant custom --plonk_input_path /path/to/plonk_scheduler_verification_key.json --fflonk_input_path /path/to/fflonk_scheduler_verification_key.json --plonk_output_path /path/to/VerifierPlonk.sol --fflonk_output_path /path/to/VerifierFflonk.sol
```

Omitting the `--variant` flag defaults to `custom` behavior:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --plonk_input_path data/plonk_scheduler_key.json --fflonk_input_path data/fflonk_scheduler_key.json --plonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierPlonk.sol --fflonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierFflonk.sol
```
