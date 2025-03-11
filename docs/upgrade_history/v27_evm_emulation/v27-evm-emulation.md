# V27 EVM emulation upgrade

## Upgrade process

V27 upgrade will happen after the gateway preperation upgrade, but before the gateway is deployed. As such the ugprade process does not involve the Gateway parts ( upgrading the CTM on GW, pausing migrations, etc), it is an L1-only upgrade. 

Additionally this is not a bridge upgrade, as the bridge and ecosystem contracts don't have new features, so L1<>L2 bridging is not affected. This means that only the system components, the Verifiers, Facets and L2 contracts need to be upgraded.

The upgrade process is as follows: 

- deploy new contract implementations. 
- publish L2 bytecodes
- generate upgrade data
    - forceDeployments data on L2. Contains all new System and L2 contracts.
    - new genesis diamondCut (which contains facetCuts, and genesis forceDeployments, as well as init data)
    - upgradeCut (which contains facetCuts, and upgrade forceDeployments, as well as upgrade data)
- prepare ecosytem upgrade governance calls:
    - upgrade proxies for L1 contracts. 
    - CTM: 
        - set new ChainCreationParams (-> contains new genesis upgrade cut data)
        - set new version upgrade (-> contains new upgrade cut data)
    - start upgrade timer

Read more here: [Upgrade process document](../../chain_management/upgrade_process.md)

## Changes: 

### New features: 

- facets: EVM emulation, service transaction on Mailbox
- System contract and bootloader: evm emulation.
- verifiers: Fflonk and plonk Dual verifiers
- identity precompile
- ChainTypeManager: add setServerNotifier ( used for GW migration)

### Bug fixes: 

- GW send data to L1 bug in Executor
- safeCall tokenData on L2.
- Token registration
- Bridgehub: registerLegacy onlyL1 modifier

### Token registration: 

- L1Nullifier → small check added in token registration
- L1AssetRouter: → small check in token registration
- L1NTV: token registration
- L2AssetRouter: token registration check
- L2NTV: token registration

### Changed without need for upgrade: 

- AssetRouterBase → casting, no need
- L1ERC20Bridge → comment changes, don’t change
- CTMDeploymentTracker: changed error imports only, do not upgrade.
- Relayed SLDA validator version, deployed on GW, nothing to upgrade.
