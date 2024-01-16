# Random Storage contracts

These contracts are a copy of some of openzeppelin's contracts.
We changed the storage slots of the variables so that we can add them to proxy-implementation contracts after deployment without changing
the storage layout. This means the upgradeability of the contracts was preserved.
Otherwise all the files should work as the original OZ ones.
