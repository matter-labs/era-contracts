# ZKsync OS multi-proof verifiers

`MultiProofVerifier` selects between Airbender-only (type 2) and combined
Airbender + ZiSK (type 5) proofs according to the chain's switch. See
[proof-mode discovery and switch semantics](../../../../protocol-docs/multi-proof-verification.md). `ZiskVerifier`
is its range verifier: it pins three values, RECONSTRUCTS the 576-byte ZiSK
public values on-chain from those pins and the batch public inputs (the
self-contained seed-0 chain), and delegates the SNARK check to ZiSK's own
pilfflonk verifier, `PilfflonkVerifier`, through `IZiskSnarkVerifier`. The
public values are not carried in the proof, so there is nothing redundant to
cross-check and the cross-proof binding is inherent.

The public values are `aggregatorProgramVK(32) || guest publics(512) ||
rootCVadcopFinal(32)`. The guest-publics section is 64 little-endian u64
slots, one per guest public. A guest public holds a 32-bit value, so each
slot carries four significant bytes and four zero pad bytes. The aggregator
guest writes the binding digest into the first eight slots, bytes
`[32..96]`, and leaves the remaining slots zero.

The three pins are:

- `innerProgramVK` — the programVK of the inner state-transition guest ELF.
  It enters the binding digest
  `keccak256(innerProgramVK || rootCVadcopFinal || chainedPI)`, because the
  aggregator guest builds that digest from the inner proofs it ingests. The
  `rotate-program-vks` dispatch in the ZiSK repository publishes it.
- `aggregatorProgramVK` — the programVK of the aggregator guest ELF. The
  aggregated proof attests to that program, so this pin is public-values
  bytes `[0..32]`. The same `rotate-program-vks` dispatch publishes it.
- `rootCVadcopFinal` — the vadcop-final recursive-setup constant of the ZiSK
  release. One cargo-zisk setup produces the inner proofs and the aggregated
  proof, so a single pin serves both the digest and public-values bytes
  `[544..576]`.

Put the four limbs of each pin into `tools/verifier-gen/data/ZiSK_vk.json`
and regenerate the contract.

`verificationKeyHash()` is `keccak256` over the three pins in that order, so
a rotation of any pin rotates the hash.

The pins come from the move of the ZiSK lane to ZiSK
[v1.4.0-alpha](https://github.com/0xPolygonHermez/zisk/releases/tag/v1.4.0-alpha)
in [zksync-os-zisk#66](https://github.com/matter-labs/zksync-os-zisk/pull/66),
the ZKsync OS 0.6.0 guest on zksync-os-revm v0.4.0. That PR records both
reproducible ELF hashes, both program VKs and the vadcop-final root. The
combined verification-key hash is
`0x38afdbde9dffe0a1ef942e7214d59700b47319d225d4558bb6f166ef09a31dd7`.

The real-proof fixtures come from
[fixture-session run 41671348755](https://github.com/matter-labs/zksync-os-zisk/actions/runs/41671348755),
which reproduced both guest ELFs, proved four deterministic batches on the
pins, compared their commitments with native execution, and produced the
aggregated binding digest
`0x5afe2e89a27ddd841b343cff7fb3a9f3c0dc18b0d6bc7d685fbfa55af59c9bd0`.

## The SNARK verifier

`PilfflonkVerifier.sol` is ZiSK's generated verifier for the release's
Poseidon1 pilfflonk verification key (digest
`0xe8f7e04ba2ff5bedda661368eb890d4b70fa8c139cac772ef42cb30cac2f454b`). It is
upstream's `zisk-contracts/poseidon1/PilfflonkVerifier.sol` at ZiSK
v1.4.0-alpha (commit `64a1f1664184e76053686745d50c6b9aaa51b034`), copied
unmodified (sha256
`13a14c51355acc520ace141112bb6b97b42f8e6db6490a2f85173bfdce85646a`). Upstream
licenses it MIT OR Apache-2.0. Keep it byte-identical to upstream, so a review
of a key rotation is a diff of two upstream files, and so lint and formatting
skip it.

`verifyProof(bytes32[69], uint256[1])` takes the 2,208-byte proof as 69
big-endian words and the circuit's single public signal. It compiles to
9,767 bytes of runtime code.

The SNARK verifier changes only with the release's pilfflonk key. Guest program
changes rotate the three pins of `ZiskVerifier` and leave the SNARK verifier as
it is, so one deployed `PilfflonkVerifier` serves every `ZiskVerifier` of the
same ZiSK release.

## Generating the range verifier

From `tools/verifier-gen/`, regenerate our wrapper after updating the guest VKs:

```bash
cargo run -- --variant zisk \
  --zisk_vk_path data/ZiSK_vk.json \
  --zisk_output_path ../../l1-contracts/contracts/state-transition/verifiers/ZiskVerifier.sol
```

This command only generates `ZiskVerifier`.

## Deploying and wiring

With `multi_proof_verifier = true` in `config-deploy-ctm.toml`, `DeployCTM`
deploys `PilfflonkVerifier`, then `ZiskVerifier` over it, and wires
`ZiskVerifier` into `MultiProofVerifier`. The output records both, as
`zisk_snark_verifier_addr` and `zisk_verifier_addr`.

An operator may instead supply a range verifier of their own through
`zisk_range_verifier_addr`. Deployment rejects an address without code, and it
then deploys neither `PilfflonkVerifier` nor `ZiskVerifier`.

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
`ZiskVerifier.verify` over the vendored `PilfflonkVerifier`, so it exercises the
on-chain reconstruction and the real pairing together. It also checks a real
per-batch proof against its own signal, and that a tampered proof, public value
or range is rejected. It runs in every `yarn test:foundry`.

`MultiProofRangeVectorTest` pins the same aggregation vector against a
signal stand-in, which lets it assert the exact reconstructed signal and
reject near-misses. The remaining multi-proof tests use mocks.

These suites live in `test/foundry/l1/unit/concrete/Verifier/`, the path the
`test:foundry` script runs.
