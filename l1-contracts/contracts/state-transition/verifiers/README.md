# ZKsync OS multi-proof verifiers

`MultiProofVerifier` accepts a combined proof (type 5) and requires BOTH an
Airbender SNARK and a ZiSK SNARK for every state transition. `ZiskVerifier`
is its range verifier: it pins three values, RECONSTRUCTS the 320-byte ZiSK
public values on-chain from those pins and the batch public inputs (the
self-contained seed-0 chain), and delegates the Plonk check to a standalone
snarkJS-generated verifier referenced through `ISnarkPlonkVerifier`. The
public values are not carried in the proof, so there is nothing redundant to
cross-check and the cross-proof binding is inherent.

The three pins are:

- `innerProgramVK` — the programVK of the inner state-transition guest ELF.
  It enters the binding digest
  `keccak256(innerProgramVK || rootCVadcopFinal || chainedPI)`, because the
  aggregator guest builds that digest from the inner proofs it ingests.
- `aggregatorProgramVK` — the programVK of the aggregator guest ELF. The
  aggregated proof attests to that program, so this pin is public-values
  bytes `[0..32]`. Run `cargo-zisk rom-setup` on the aggregator ELF to get
  it, put the four limbs into `tools/verifier-gen/data/ZiSK_vk.json`, and regenerate the
  contract.
- `rootCVadcopFinal` — the vadcop-final recursive-setup constant of the ZiSK
  release. One cargo-zisk setup produces the inner proofs and the aggregated
  proof, so a single pin serves both the digest and public-values bytes
  `[288..320]`.

`verificationKeyHash()` is `keccak256` over the three pins in that order, so
a rotation of any pin rotates the hash.

## Generating the snarkJS Plonk verifier

The Plonk verifier is machine-generated from the ZiSK SNARK setup and is
regenerated whenever the circuit changes, so it is built and deployed as a
standalone contract.

The Plonk verification key of the current ZiSK release is committed at
`tools/verifier-gen/data/ZiSK_plonk_verification_key.json`, so the two steps below run
from a clean checkout and CI runs them on every push. Refresh that key when
the SNARK circuit changes: every `cargo-zisk prove --plonk` output file
embeds it (the file is bincode of zisk-common's `Proof`, whose Plonk body
carries the snarkJS key verbatim, and the `zksync-os-zisk` prover crate
mirrors those struct shapes), and the `ziskup setup_snark -y` proving key
holds the same key.

1. From `tools/verifier-gen/`, render the snarkJS Plonk verifier from the committed key.
   This is the template render that `snarkjs zkey export solidityverifier`
   runs on the key it reads out of a `.zkey`:

   ```bash
   npm ci
   node render_plonk_verifier.js data/ZiSK_plonk_verification_key.json data/PlonkVerifier.sol
   ```

2. From `tools/verifier-gen/`, adapt it for this repository (pragma + contract name) and
   generate the `ZiskVerifier` wrapper for the current guest VKs:

   ```bash
   cargo run -- --variant zisk \
     --zisk_vk_path data/ZiSK_vk.json \
     --zisk_output_path ../../l1-contracts/contracts/state-transition/verifiers/ZiskVerifier.sol \
     --zisk_plonk_input_path data/PlonkVerifier.sol
   ```

   The adapted verifier lands at
   `l1-contracts/contracts/dev-contracts/generated/ZiskSnarkPlonkVerifier.sol`
   (a gitignored path that `forge build` compiles when present).

3. Validate the result. For the cargo-zisk v0.18.0 key the adapted source's
   SHA-256 is
   `e21103887543396795edef162cbcba38c1c4cc0522686f6e109885f93e065735`. The
   behavioral check is `forge test --match-contract ZiskVerifierRealProofTest`,
   which drives real proofs through a real pairing.

## Deploying and wiring

1. Deploy the generated verifier:

   ```bash
   forge create contracts/dev-contracts/generated/ZiskSnarkPlonkVerifier.sol:ZiskSnarkPlonkVerifier \
     --rpc-url $RPC_URL --private-key $DEPLOYER_KEY
   ```

2. Put the deployed address into the deploy config
   (`zisk_plonk_verifier_addr` in `config-deploy-ctm.toml`). With
   `multi_proof_verifier = true`, `DeployCTM` deploys `ZiskVerifier` with
   that address and wires it into `MultiProofVerifier`.

To rotate the Plonk verifier after a circuit regeneration, repeat both
steps and redeploy `ZiskVerifier` with the new address (its own pins are
constants baked at generation time by the `tools/verifier-gen/` flow).

## The Airbender side

The same `multi_proof_verifier = true` deploy also deploys the ZKsync OS dual
verifier and wires it as the Airbender inner verifier of
`MultiProofVerifier`. The lane therefore needs `is_zk_sync_os = true`. That
dual verifier holds the versioned FFLONK and PLONK sub-verifier registry, and
both multi-proof wrappers expose the registry getters through it, so the
deployment and upgrade tooling reads a single registry.

The dual verifier parses its own header, so the Airbender sub-proof at
`proof[3 .. 3+N]` is the envelope that verifier expects: `proof[3]` is
`2 | (verifier_version << 8)` for a version the dual verifier holds a
sub-verifier for, `proof[4]` is zero, and `proof[5 .. 3+N]` are the Airbender
Plonk proof words. `proof[4]` seeds a chain over the single already-chained
value `MultiProofVerifier` hands over, so only zero keeps that chaining the
identity.

## Tests

`ZiskVerifierRealProofTest` drives a real aggregated cargo-zisk proof through
`ZiskVerifier.verify`, so it exercises the on-chain reconstruction and the
real pairing together. It runs whenever the generated verifier artifact is
present (step 2 above); otherwise the suite reports as skipped. CI generates
that artifact in the verifier-generator job and hands it to the foundry job
through the build cache, so the suite runs there too.
`MultiProofRangeVectorTest` pins the same aggregation vector against a
signal stand-in, which lets it assert the exact reconstructed signal and
reject near-misses. The remaining multi-proof tests use mocks and run
unconditionally.

These suites live in `test/foundry/l1/unit/concrete/Verifier/`, the path the
`test:foundry` script runs.
