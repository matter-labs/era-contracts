# v0.34.0 — Era dual proofs (stage, testnet3, mainnet)

v34 moves an Era CTM from v0.33.0 to v0.34.0. From then on every Era batch needs a Boojum and an Airbender
proof; a testnet verifier still accepts an empty proof. It also ships an operator force-fail bit for L1→L2
transactions (new bootloader), a 15M gas cap on user L1→L2 transactions and an EVM emulator fix.

| Environment                   | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| stage (Sepolia, chain 499)    | Executed 2026-10-22 as one emergency proposal, without a timer. `output/stage/` is generate run [39414177988](https://github.com/matter-labs/era-contracts/actions/runs/39414177988); its input `stage.toml` is in git history at `93e2c5a7b`                                                                                                                                                                                                               |
| testnet3 (Sepolia, chain 312) | `output/testnet3/` is generate run [41594035218](https://github.com/matter-labs/era-contracts/actions/runs/41594035218) (Sepolia block 12018509); its deployer bundle was deployed by run [40849834276](https://github.com/matter-labs/era-contracts/actions/runs/40849834276), and the three contracts the base deployment flow added by run [41599475703](https://github.com/matter-labs/era-contracts/actions/runs/41599475703). Governance not executed |
| mainnet (chain 324)           | Not generated yet: generated on a mainnet fork once chain 324 is on v0.33.0 with its first v0.33.0 batch executed                                                                                                                                                                                                                                                                                                                                           |

## What changes

| Where          | Change                                                                                                                                                                                                                                                             |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Deployments    | The six facets and `DiamondInit`, `EraVerifierFflonk` and `AirbenderVerifierPlonk`, the multi-proof verifier over both, the EIP-7702 checker, `EraSettlementLayerV34Upgrade`, new CTM and ServerNotifier implementations, the governance timer and stage validator |
| Publication    | The L2 factory deps, into the CTM's BytecodesSupplier                                                                                                                                                                                                              |
| Governance     | Stage 0 pauses migrations and starts the timer. Stage 1 checks the deadline and the pause, upgrades the CTM proxy, then `setNewVersionUpgrade` and `setChainCreationParams`. Stage 2 checks that the CTM has the new version, unpauses, then checks the unpause    |
| ServerNotifier | Upgraded by the owner of its ProxyAdmin (the ecosystem admin), outside the stages                                                                                                                                                                                  |
| Per chain      | After stage 1, the upgrade timestamp; once the chain is drained, the upgrade (see "Executing it")                                                                                                                                                                  |

The L2 upgrade transaction is the same for every chain: `ContractDeployer.forceDeployOnAddresses` of the 31 system
contracts, of which only `L2BaseTokenEra` and `SystemContractProxyAdmin` change. Its factory deps start with the new
bootloader, the default account and the EVM emulator, which is how the node learns them. The L2 core contracts are
not redeployed: they hold live storage. New chains get the new facets and `DiamondInit` with the v34 genesis.

## Executing it

Follows `AGENTS.md`, "Executing Stage and Testnet Upgrades".

- **testnet3:** the PUH's normal path, one `UpgradeProposal` per stage, each an L2 vote on chain 312, with stage 1
  at least 20 minutes after stage 0. transaction-simulator holds the proposals; the L1 runbooks come from
  `protocol_ops dev execution-runbook` at execution time.
- **mainnet:** one Tally proposal per stage, with stage 1 at least 48 hours after stage 0.

The timer delays follow earlier upgrades. v34's stage 1 forces no chain to switch (v0.33.0 keeps an unlimited
deadline), so here the timer is a notice period. It also rules out an all-stages emergency proposal, and stage 1
can't take the emergency path on its own either: that path unpauses migrations before the proposal's calls, and
stage 1 checks that they are paused.

Each chain, once stage 1 has executed (`chain set-upgrade-timestamp` and `chain upgrade` below read what it
registered): its ChainAdmin's owner sets the upgrade timestamp, with the bundle
`protocol_ops chain set-upgrade-timestamp --env <env> --chain-id <id> --new-protocol-version 146028888064 --upgrade-timestamp <unix> --l1-rpc-url <rpc> --out <dir>`
writes; on testnets `1` means as soon as the node sees it, on mainnet it is a real future date. Once the chain is
drained:

1. **Server path (first choice):** the node's operator calls `ValidatorTimelock.upgradeChainFromVersion`, which
   needs `UPGRADER_ROLE` for the diamond. Mainnet's 324 has no holder; grant only that role with
   `protocol_ops chain grant-upgrader --env <env> --chain-id <id> --validator-address <operator> --l1-rpc-url <rpc> --out <dir>`.
   It simulates on a fork and writes a Safe bundle and `EXECUTE.md` for the ChainAdmin's owner. Afterwards require
   `cast call <timelock> 'hasRole(address,bytes32,address)(bool)' <diamond> $(cast keccak UPGRADER_ROLE) <operator>`
   to return `true`; a successful receipt is not enough.
2. **Fallback:** the ChainAdmin's owner sends the bundle
   `protocol_ops chain upgrade --env <env> --chain-id <id> --l1-rpc-url <rpc> --out <dir>` writes.

## Files

- `<env>.toml`: what the script can't read from `permanent-values/<env>.toml`, the chain or the v34 genesis: the
  verifier flavour, the timer delay, the salt and `use_v29_introspection = false`.
- `output/<env>/`: committed from the generate run. `output/stage/` keeps the layout stage was generated with; the
  others are in `DefaultCTMUpgrade.saveOutput`'s layout, where the zero addresses are fields v34 doesn't use and
  `admin.ecosystem_admin_addr` is the CTM owner (the PUH).
- `rehearse.sh`: the fork checks behind `upgrade.toml`'s `verify_fork` and `verify_chain`; its header says what it
  checks and how to run it alone.

Generating and deploying work as for every forge-script upgrade (`docs/ecosystem-upgrade-deploy.md`).

## Server side

- The node and prover must support v0.34.0 before any chain upgrades: from then on the chain needs both proofs.
- The new verifier's no-argument `verificationKeyHash()` returns the Boojum FFLONK key (`0xd89b…`), which the node
  stores as the version's snark wrapper VK hash.
- The chain's first post-upgrade batch executes the L2 upgrade transaction.
