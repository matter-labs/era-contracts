# ZKsync OS genesis

## Scope

./

## Description

Defines the genesis state for all new zksync os chains.

It is expected that all contracts that are present in the genesis are deployed as system proxies with the system proxy admin set as their proxy admin. 

The only components that are predeployed not as proxies are:
- `L2_GENESIS_UPGRADE`, because it is never anticipated to be upgraded and must be used only once.
- `L2_WRAPPED_BASE_TOKEN`, because it is the initial implementation of the wrapped base token. It is just an implementation and TUP for the wrapped token is expected to be deployed during the genesis.
- `SYSTEM_CONTRACT_PROXY_ADMIN`. It is expected that if we need to update the implementation of it, we'll just deploy a new one and transfer the ownership over the proxies to it.
- `DETERMINISTIC_CREATE2_ADDRESS`. It is standard EVM CREATE2 factory.

Any non-system-proxy predeploys need to be explicitly approved and mentioned here.

## Dependencies for this component

The components that this component depends on. Whenever these are changed, the component should get re-reviewed. When reviewing this component you can assume that the invariants provided here are correct, unless specified otherwise (e.g. when the relevant component change).

[todo add that genesis needs to deploy the tup]
[todo add that the system proxy admin should always allow to transfer adminship for the upgradeability of the system proxies]

## Dependencies on of this component

The components that depend on this one. When this component changes, if the invariants provided by this component are broken, these have to re-reviewed. The correctness of this component INCLUDES THESE INVARIANTS.
