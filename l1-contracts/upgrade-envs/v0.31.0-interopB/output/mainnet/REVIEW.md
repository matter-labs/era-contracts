# Mainnet calldata candidate — 21 September 2026

Source: [generation and no-build handoff run 35621948305](https://github.com/matter-labs/era-contracts/actions/runs/35621948305), contracts commit `bfdd283e29c6a94fe6d3d4cb8c881076e8304b00`. This includes the reduced DSE configuration from #2522, root-frame hooks, canonical system-contract hashes and regenerated Era genesis. It supersedes the optnone candidate.

- Calldata artifact: `10650380490`.
- Deployment artifact: `10650510360`.
- Fork: Ethereum block `25925815`, before the September 7 deployment.
- Deployer: `0xaB75E283274247b43a1f220885850ebEFa399B88`.
- `ecosystem.toml` SHA-256: `3199bbbd08aa809833b75f8cd05196e43e6d3f953992fa2bceb5aaa02c7b0ba5`.
- Both CI jobs passed. All deployment-bundle file digests were checked, and its ecosystem TOML equals the calldata artifact's copy byte-for-byte.
- All 50 simulator entries match the artifact in every field. Stages contain 12, 23 and 7 calls. The other entries are prerequisites and smoke tests, not part of a single governance proposal.
- Relative to the previously committed candidate, only four entries change execution data: the Era CTM upgrade registration, Era chain-creation parameters, fresh Era chain smoke test and existing Era chain upgrade smoke test. Call ordering, targets, senders and values are unchanged.

## Remaining warnings and execution limits

PUVT reports ten warnings: nine chains have older protocol versions, and eleven indexed historical deployments lack explicit constructor-expectation coverage. The reused TransitionaryOwner is among them, so historical provenance still needs attention during the deployed-contract review; the warning is not waived.

This is a reviewed-generation candidate, not evidence that the changed contracts have been deployed on mainnet. The fork starts before the prior deployment so prepare can run with the original salts. Current live-state and delta-deployment verification remain separate requirements.

`transactions.txt` is retained unchanged as real-network deployment history. No fork transaction hashes were substituted for it. The verification command log describes this candidate, not a claim that every listed address is already deployed or Etherscan-verified.

The generated simulator JSON retains its two `emulateAllBatchesExecuted` flags for artifact fidelity. Do not run those storage overrides. A no-override simulation must report genuine batch-readiness failures and requires the candidate contracts to exist on its fork. The refreshed transaction-simulator scenario removes these two harness flags explicitly; governance call bytes are unchanged.

Review-ready is not rollout approval. Matching current-private-server/prover compatibility and performance validation remain separate gates; the old optnone cost measurement does not describe this DSE candidate. Verify actual deployed contracts against this exact bundle (including ownership/configuration and Etherscan status). Missing or changed deployments require a separately authorized delta broadcast. No governance execution is authorized by this file.
