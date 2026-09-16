Create a new version upgrade script following the ZK Stack upgrade architecture.

## Usage

Invoke with: `/upgrade-script <version_number>` (e.g., `/upgrade-script v36`)

## What this skill does

Creates the upgrade script files for a new protocol version. There is no single
`EcosystemUpgrade` artifact — the ecosystem upgrade is composed from the per-domain upgrade scripts
below, and `protocol-ops ecosystem upgrade-prepare-all` orchestrates running them together:

```
CoreUpgrade_v{N}    extends DefaultCoreUpgrade
CTMUpgrade_v{N}     extends DefaultCTMUpgrade
```

There is no per-version chain script: every chain crosses through
`AdminFunctions.upgradeChainFromCTM`, which picks the modern cut-reading call or the legacy
handed-cut call from the chain's own protocol version. `DefaultChainUpgrade` remains only as
the Foundry integration harness for the legacy edge.

## Steps

1. Read the base classes to understand current signatures:
   - `l1-contracts/deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol`

2. Read the most recent steady-state version as the template — `v35`, not `v34`:
   - `l1-contracts/deploy-scripts/upgrade/v35/CoreUpgrade_v35.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/v35/CTMUpgrade_v35.s.sol`

   `v34` is the one-shot registry bootstrap edge and carries a large amount of machinery
   (`RegistryBootstrapMigration`, the authored L2 plan, the declared bootstrap actions) that a
   normal version must NOT copy.

3. Create new version directory: `l1-contracts/deploy-scripts/upgrade/v{N}/`

4. Create the following files (minimal overrides, only add what's needed — a version that changes
   no ecosystem contracts needs an empty body, as `CTMUpgrade_v35` has):
   - `CoreUpgrade_v{N}.s.sol` - Override `deployNewEcosystemContractsL1()` for new L1 core contracts
   - `CTMUpgrade_v{N}.s.sol` - Override `deployNewCTMContracts()` for new chain-side contracts

5. Declare the release scope. `changedReleaseMembers()` lists the release members this version
   replaces; anything not listed is reused from the live release, and a member that changes without
   being declared makes the prepare fail. Override it whenever the version changes chain code.

6. Create the upgrade environment config directory under `l1-contracts/upgrade-envs/` (versioned name,
   e.g. `v0.35.0`)
   - Copy and adapt from the most recent version's config

7. Ask the user what new contracts or changes this upgrade introduces before filling in deployment logic.

## Key rules

- NEVER use try-catch or staticcall in upgrade scripts
- Use composition (not diamond inheritance) for ecosystem upgrades
- Three-stage governance: stage0 (pause), stage1 (upgrade), stage2 (unpause)
- Output paths follow pattern: `/script-out/v{N}-upgrade-{core|ctm|ecosystem}.toml`
- Test with `forge script` in simulation mode before broadcasting
