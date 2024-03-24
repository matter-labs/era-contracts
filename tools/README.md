# Tool for generating `Verifier.sol` using json Verification key

`cargo run --bin zksync_verifier_contract_generator --release -- --input_path /path/to/scheduler_verification_key.json --output_path /path/to/Verifier.sol`

To generate the verifier from the scheduler key in 'data' directory, just run:

```shell
cargo run --bin zksync_verifier_contract_generator --release -- --input_path ../../prover/vk_setup_data_generator_server_fri/data/snark_verification_scheduler_key.json --output_path ../l1-contracts/contracts/zksync/Verifier.sol
```
