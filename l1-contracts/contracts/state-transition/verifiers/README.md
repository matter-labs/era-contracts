# ZKsync OS multi-proof verifiers

`MultiProofVerifier` selects between Airbender-only (type 2) and combined
Airbender + ZiSK (type 5) proofs according to the chain's switch. See
[proof-mode discovery and switch semantics](../../../../protocol-docs/multi-proof-verification.md). `ZiskVerifier`
is its range verifier: it pins three values, RECONSTRUCTS the 320-byte ZiSK
public values on-chain from those pins and the batch public inputs (the
self-contained seed-0 chain), and delegates the Plonk check to a standalone
snarkJS-generated verifier referenced through `IZiskSnarkPlonkVerifier`. The
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

The current pins come from [guest release 0.0.5](https://github.com/matter-labs/zksync-os-zisk/releases/tag/0.0.5),
using ZiSK 0.18.0. Its inner program VK is
`0xac3a6494410ce230354e5ffae7c97f94bb5488d6e1764818c9d75156ce1dc59e`
and combined verification key hash is
`0xb70fd0a92d1375cc2f2a4e5e6907aa9af3131da257843088374bb0d834c61141`.
The aggregator and SNARK setup keys are unchanged. The existing real proofs
use the previous inner guest: they still validate against the SNARK backend,
but the range verifier rejects them after this rotation. A fresh 0.0.5 proof
session is required to validate successful settlement with the current pins.

## Preparing the backend

Deployment requires a standalone backend implementing `IZiskSnarkPlonkVerifier`.
If one is already deployed for the selected verification key, use its address as
`zisk_plonk_verifier_addr`. Reuse that backend across guest VK updates: the
inner/aggregator program VKs and vadcop-final root are pinned in our
`ZiskVerifier` wrapper. A new backend is needed only when its final PLONK
circuit/setup verification key changes. Multiple wrappers on the same L1 can
use the same backend.

Backend preparation and optional deployment live in
[zk-deployer](https://github.com/matter-labs/zksync-os-integration-tests/blob/d1be31737c3d68346cf36495ec0991cefd5233e3/bin/zk-deployer/README.md).
It reads this checkout's `tools/verifier-gen/data/ZiSK_plonk_verification_key.json`,
fetches the pinned upstream dependencies, and builds outside Git checkouts.
The upstream source and notices are preserved; generated outputs retain their
upstream license and stay out of published packages.

To prepare, deploy, or test directly from a zk-deployer checkout:

```bash
node bin/zk-deployer/tools/zisk-backend/zisk-backend.js deploy /path/to/era-contracts -- \
  --rpc-url "$RPC_URL" --account deployer --broadcast
```

The helper prints `zisk_plonk_verifier_addr` for the deployment config. Its
`prepare` command only builds and prints the external artifact path.

## Generating the range verifier

From `tools/verifier-gen/`, regenerate our wrapper after updating the guest VKs:

```bash
cargo run -- --variant zisk \
  --zisk_vk_path data/ZiSK_vk.json \
  --zisk_output_path ../../l1-contracts/contracts/state-transition/verifiers/ZiskVerifier.sol
```

This command only generates `ZiskVerifier`; backend preparation is independent.

## Deploying and wiring

Set `zisk_plonk_verifier_addr` in `config-deploy-ctm.toml`. With
`multi_proof_verifier = true`, `DeployCTM` wires that backend into `ZiskVerifier`
and `MultiProofVerifier`. Deployment rejects an address without code; the
operator must select the backend for the intended verification key.

After a SNARK circuit change, update the committed Plonk verification key,
prepare/deploy the new backend, and redeploy `ZiskVerifier` with its address.

## The Airbender side

The same `multi_proof_verifier = true` deploy also deploys `ZKsyncOSVerifier`
and wires it as the Airbender inner verifier of `MultiProofVerifier`. That
verifier holds the PLONK
sub-verifier, and both multi-proof wrappers expose `PLONK_VERIFIER()` through
it, so the deployment and upgrade tooling reads a single sub-verifier.

`ZKsyncOSVerifier` parses its own header, so the Airbender sub-proof at
`proof[3 .. 3+N]` is the envelope that verifier expects: `proof[3]` is
`ZKSYNC_OS_PLONK_VERIFICATION_TYPE`, `proof[4]` is zero, and
`proof[5 .. 3+N]` are the Airbender Plonk proof words. `proof[4]` is the
carried-hash slot, which `ZKsyncOSVerifier.computeZKsyncOSHash` requires to be
zero.

## Tests

`ZiskVerifierRealProofTest` drives a real aggregated cargo-zisk proof through
`ZiskVerifier.verify`, so it exercises the on-chain reconstruction and the
real pairing together. Run the full Foundry suite with a locally prepared
backend from a zk-deployer checkout:

```bash
node bin/zk-deployer/tools/zisk-backend/zisk-backend.js test /path/to/era-contracts
```

Additional test flags may follow `--`, for example
`-- --match-contract ZiskVerifierRealProofTest`. The helper sets
`ZISK_PLONK_BYTECODE` from the prepared artifact and requires the real-proof
suite's prerequisite. CI checks out a pinned zk-deployer revision and uses the
same command without uploading the backend between jobs.

Ordinary `yarn test:foundry` runs skip the real-proof suite when
`ZISK_PLONK_BYTECODE` is unset. Invalid supplied bytecode fails setup.
`ZISK_REQUIRE_REAL_PROOFS=true` also makes absent bytecode fail setup.

`MultiProofRangeVectorTest` pins the same aggregation vector against a
signal stand-in, which lets it assert the exact reconstructed signal and
reject near-misses. The remaining multi-proof tests use mocks and run
unconditionally.

These suites live in `test/foundry/l1/unit/concrete/Verifier/`, the path the
`test:foundry` script runs.
