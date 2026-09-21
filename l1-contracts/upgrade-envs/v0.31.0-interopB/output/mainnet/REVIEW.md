# Mainnet calldata candidate — 21 September 2026

Source: [generation and no-build handoff run 35585260195](https://github.com/matter-labs/era-contracts/actions/runs/35585260195), contracts commit `2df0098dc85a02ca31132b42c287f25dc5efed73`.

- Calldata artifact: `10632821639`.
- Deployment artifact: `10633145941`.
- Fork: Ethereum block `25925815`, before the September 7 deployment.
- Deployer: `0xaB75E283274247b43a1f220885850ebEFa399B88`.
- `ecosystem.toml` SHA-256: `571ddd5ac92a7c6a9b7ceb66e01a29f54673d74a366fa651030af179e5db861d`.
- Both CI jobs passed. All deployment-bundle file digests were checked, and its ecosystem TOML equals the calldata artifact's copy byte-for-byte.
- The 50 simulator entries match the artifact in every field except human descriptions, which were regenerated after remapping eight address labels by ecosystem TOML role. Stages contain 12, 23 and 7 calls. The other entries are prerequisites and smoke tests, not part of a single governance proposal.

## Remaining warnings and execution limits

PUVT reports ten warnings: nine chains have older protocol versions, and eleven indexed historical deployments lack explicit constructor-expectation coverage. None of those eleven addresses is a deployment in this new bundle. The reused TransitionaryOwner is among them, so historical provenance still needs attention during the deployed-contract review; the warning is not waived.

This is a reviewed-generation candidate, not evidence that the changed contracts have been deployed on mainnet. The fork starts before the prior deployment so prepare can run with the original salts. Current live-state and delta-deployment verification remain separate requirements.

`transactions.txt` is retained unchanged as real-network deployment history. No fork transaction hashes were substituted for it. The verification command log describes this candidate, not a claim that every listed address is already deployed or Etherscan-verified.

The generated simulator JSON retains its two `emulateAllBatchesExecuted` flags for artifact fidelity. Do not run those storage overrides. A no-override simulation must report genuine batch-readiness failures and requires the candidate contracts to exist on its fork. The refreshed transaction-simulator scenario removes these two harness flags explicitly; governance call bytes are unchanged.

Release sequence: finish the matching zksync-era compatibility checks, then verify actual deployed contracts against this exact bundle (including ownership/configuration and Etherscan status). Missing or changed deployments require a separately authorized delta broadcast. No governance execution is authorized by this file.
