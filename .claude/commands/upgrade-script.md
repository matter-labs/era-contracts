Create a new version upgrade script following the ZK Stack upgrade architecture.

## Usage
Invoke with: `/upgrade-script <version_number>` (e.g., `/upgrade-script v32`)

## What this skill does

Creates a complete set of upgrade script files for a new protocol version, following the established inheritance pattern:

```
EcosystemUpgrade_v{N}
    extends DefaultEcosystemUpgrade
        creates CoreUpgrade_v{N} (extends DefaultCoreUpgrade)
        creates CTMUpgrade_v{N} (extends DefaultCTMUpgrade)

ChainUpgrade_v{N}
    extends DefaultChainUpgrade

GatewayUpgrade_v{N} (optional)
    extends DefaultGatewayUpgrade
```

## Steps

1. Read the base classes to understand current signatures:
   - `l1-contracts/deploy-scripts/upgrade/default-upgrade/DefaultEcosystemUpgrade.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/default-upgrade/DefaultChainUpgrade.s.sol`

2. Read the most recent version upgrade (e.g., v31) as a template:
   - `l1-contracts/deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/v31/ChainUpgrade_v31.s.sol`

3. Create new version directory: `l1-contracts/deploy-scripts/upgrade/v{N}/`

4. Create the following files (minimal overrides, only add what's needed):
   - `EcosystemUpgrade_v{N}.s.sol` - Override `createCoreUpgrade()`, `createCTMUpgrade()`, output paths, and `run()`
   - `CoreUpgrade_v{N}.s.sol` - Override `deployNewEcosystemContractsL1()` and stage governance calls
   - `CTMUpgrade_v{N}.s.sol` - Override `deployNewCTMContracts()` and stage governance calls
   - `ChainUpgrade_v{N}.s.sol` - Override per-chain upgrade logic

5. Create upgrade environment config directory: `l1-contracts/upgrade-envs/v{N}/`
   - Copy and adapt from the most recent version's config

6. Ask the user what new contracts or changes this upgrade introduces before filling in deployment logic.

## Key rules
- NEVER use try-catch or staticcall in upgrade scripts
- Use composition (not diamond inheritance) for ecosystem upgrades
- Three-stage governance: stage0 (pause), stage1 (upgrade), stage2 (unpause)
- Output paths follow pattern: `/script-out/v{N}-upgrade-{core|ctm|ecosystem}.toml`
- Test with `forge script` in simulation mode before broadcasting
