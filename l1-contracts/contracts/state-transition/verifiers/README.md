# ZKsync OS multi-proof verifiers

`MultiProofVerifier` accepts a combined proof (type 5) and requires BOTH an
Airbender SNARK and a ZiSK SNARK for every state transition. `ZiskVerifier`
is its inner ZiSK verifier: it pins the guest `programVK` and
`rootCVadcopFinal`, checks the 320-byte public values, and delegates the
Plonk check to a standalone snarkJS-generated verifier referenced through
`ISnarkPlonkVerifier`.

## Generating the snarkJS Plonk verifier

The Plonk verifier is machine-generated from the ZiSK SNARK setup and is
regenerated whenever the circuit changes, so it is built and deployed as a
standalone contract.

1. Install the ZiSK toolchain and SNARK setup (`ziskup`, then
   `ziskup setup_snark -y`). This produces the verifier source at
   `~/.zisk/provingKeySnark/final/PlonkVerifier.sol`.
2. From `tools/`, adapt it for this repository (pragma + contract name) and
   generate the `ZiskVerifier` wrapper for the current guest VKs:

   ```bash
   cargo run -- --variant zisk \
     --zisk_vk_path data/ZiSK_vk.json \
     --zisk_output_path ../l1-contracts/contracts/state-transition/verifiers/ZiskVerifier.sol \
     --zisk_plonk_input_path ~/.zisk/provingKeySnark/final/PlonkVerifier.sol
   ```

   The adapted verifier lands at
   `l1-contracts/contracts/dev-contracts/generated/ZiskSnarkPlonkVerifier.sol`
   (a gitignored path that `forge build` compiles when present).
3. Validate the result: for cargo-zisk v0.18.0 setups the adapted source's
   SHA-256 is
   `40681992af6add425d6400b541ee2989e330495e09e8680604111a83ce031e2d`.

## Deploying and wiring

1. Deploy the generated verifier:

   ```bash
   forge create contracts/dev-contracts/generated/ZiskSnarkPlonkVerifier.sol:ZiskSnarkPlonkVerifier \
     --rpc-url $RPC_URL --private-key $DEPLOYER_KEY
   ```

2. Put the deployed address into the deploy config
   (`zisk_plonk_verifier_addr` in `config-deploy-l1.toml`). With
   `multi_proof_verifier = true`, `DeployCTM` deploys `ZiskVerifier` with
   that address and wires it into `MultiProofVerifier`.

To rotate the Plonk verifier after a circuit regeneration, repeat both
steps and redeploy `ZiskVerifier` with the new address (its own pins are
constants baked at generation time by the `tools/` flow).

## Tests

`ZiskVerifierRealProofTest` verifies a real cargo-zisk proof end-to-end and
runs whenever the generated verifier artifact is present (step 2 above);
otherwise the suite reports as skipped. The remaining multi-proof tests use
mocks and run unconditionally.
