# L2 genesis upgrade implementation

## Scope

./L2GenesisUpgrade.sol

## Description

The implementation of the genesis upgrade to be executed on both Era and zksync os.

It should have the same behavior for Era and zksync os, the only exception being the fact that for Era we use force deployments, while for zksync os we should avoid it as much as possible. Force deployments should be used ONLY to deploy a transparent upgradeable proxy or its implementation and ONLY if the address there was empty.


