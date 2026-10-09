# Mainnet calldata candidate — 29 September 2026

Source: [generation and no-build handoff run 36548947871](https://github.com/matter-labs/era-contracts/actions/runs/36548947871), contracts commit `cb4aa6a65a67ca05652e265c52b79b84097f777b`. Same sources as the 21 September DSE candidate (reduced DSE configuration from #2522, root-frame hooks, canonical system-contract hashes), with the Era target relabelled from v0.32.2 to **v0.33.0**. Stage receives this bootloader as its own v0.33.0 (#2538), so the same version means the same bootloader on both. The Era genesis values are unchanged: the protocol version only selects the batch-commitment layout, which 32 and 33 share. ZKsync OS stays on v0.31.2.

- Calldata artifact: `11024460808`.
- Deployment artifact: `11024755218`.
- Fork: Ethereum block `25925815`, before the September 7 deployment.
- Deployer: `0xaB75E283274247b43a1f220885850ebEFa399B88`.
- `ecosystem.toml` SHA-256: `cb41c09526663bd2951d5a50ba8ba42ae5d787cd4a2e8cd961678ee097cfd46d`.
- Both CI jobs passed, including PUVT with the Era target v0.33.0.
- Relative to the 21 September candidate, the Era target version, the upgrade cut and the calls that carry them change. Five simulator entries change: the Era CTM upgrade registration and the existing Era chain upgrade smoke test carry the new cut, and the three Era UpgradeStageValidator checks target the validator's new address. Call ordering, senders and values are unchanged, and ZKsync OS is untouched.
- **One more deployment.** The Era UpgradeStageValidator takes the target version in its constructor, so its CREATE2 address changes to `0x5906c8F5aCD9054B6F288aa1B9010ea61354c71a`. In the deployment bundle it is transaction 24 of the first deployer bundle; every other deployment transaction is identical to the previous candidate.
- The simulator JSON matches the artifact in every field except the three validator checks' descriptions. `sim-descriptions.toml` still labelled the old validator address; with the label updated, `governance-toml-to-simulator` produces the committed file.

## Remaining warnings and execution limits

PUVT reports ten warnings: nine chains have older protocol versions, and eleven indexed historical deployments lack explicit constructor-expectation coverage. The reused TransitionaryOwner is among them, so historical provenance still needs attention during the deployed-contract review; the warning is not waived.

This is a reviewed-generation candidate, not evidence that the changed contracts have been deployed on mainnet. The fork starts before the prior deployment so prepare can run with the original salts. Current live-state and delta-deployment verification remain separate requirements.

`transactions.txt` is retained unchanged as real-network deployment history. No fork transaction hashes were substituted for it. The verification command log describes this candidate, not a claim that every listed address is already deployed or Etherscan-verified.

The generated simulator JSON retains its two `emulateAllBatchesExecuted` flags for artifact fidelity. Do not run those storage overrides. A no-override simulation must report genuine batch-readiness failures and requires the candidate contracts to exist on its fork. The refreshed transaction-simulator scenario removes these two harness flags explicitly; governance call bytes are unchanged.

Review-ready is not rollout approval. Matching current-private-server/prover compatibility and performance validation remain separate gates; the old optnone cost measurement does not describe this DSE candidate. Verify actual deployed contracts against this exact bundle (including ownership/configuration and Etherscan status). Missing or changed deployments require a separately authorized delta broadcast. No governance execution is authorized by this file.
