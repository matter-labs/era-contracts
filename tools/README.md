# Tool for generating Plonk & Fflonk verifier contracts using json verification keys

`cargo run --bin zksync_verifier_contract_generator --release -- --plonk_input_path /path/to/plonk_scheduler_verification_key.json --fflonk_input_path /path/to/fflonk_scheduler_verification_key.json --plonk_output_path /path/to/VerifierPlonk.sol --fflonk_output_path /path/to/VerifierFflonk.sol`

To generate the verifier from the scheduler key in 'data' directory, just run:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --plonk_input_path data/plonk_scheduler_key.json --fflonk_input_path data/fflonk_scheduler_key.json --plonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierPlonk.sol --fflonk_output_path ../l1-contracts/contracts/state-transition/verifiers/VerifierFflonk.sol
```

## L2 mode

At the time of this writing, `modexp` precompile is not present on zkSync Era. In order to deploy the verifier on top of a ZK Chain, a different version has to be used with custom implementation of modular exponentiation.

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --input_path data/scheduler_key.json --output_path ../l2-contracts/contracts/verifier/Verifier.sol --l2_mode
```
