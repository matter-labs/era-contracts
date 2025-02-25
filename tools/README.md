# Tool for generating `Verifier.sol` using json Verification key

`cargo run --bin zksync_verifier_contract_generator --release -- --input_path /path/to/scheduler_verification_key.json --output_path /path/to/Verifier.sol`

To generate the verifier from the scheduler key in 'data' directory, just run:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --input_path data/scheduler_key.json --output_path ../l1-contracts/contracts/state-transition/Verifier.sol
```

## L2 mode

At the time of this writing, `modexp` precompile is not present on zkSync Era. In order to deploy the verifier on top of a ZK Chain, a different version has to be used with custom implementation of modular exponentiation.

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --input_path data/scheduler_key.json --output_path ../l2-contracts/contracts/verifier/Verifier.sol --l2_mode
```
