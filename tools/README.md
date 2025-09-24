# Tool for generating Plonk & Fflonk verifier contracts using json verification keys

`cargo run --bin zksync_verifier_contract_generator --release -- --plonk_input_path /path/to/plonk_scheduler_verification_key.json --fflonk_input_path /path/to/fflonk_scheduler_verification_key.json --plonk_output_path /path/to/VerifierPlonk.sol --fflonk_output_path /path/to/VerifierFflonk.sol`

First, copy the keys into data directory:

```shell
cp ../../zksync-era/prover/data/keys/fflonk_verification_snark_key.json data/fflonk_scheduler_key.json
cp ../../zksync-era/prover/data/keys/verification_snark_key.json data/plonk_scheduler_key.json
```

To generate the verifier from the scheduler key in 'data' directory, just run:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --plonk_input_path data/plonk_scheduler_key.json --fflonk_input_path data/fflonk_scheduler_key.json --plonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierPlonk.sol --fflonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierFflonk.sol
```
