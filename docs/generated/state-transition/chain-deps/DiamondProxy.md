## DiamondProxy

### constructor

```solidity
constructor(uint256 _chainId, struct Diamond.DiamondCutData _diamondCut) public
```

### fallback

```solidity
fallback() external payable
```

_1. Find the facet for the function that is called.
2. Delegate the execution to the found facet via `delegatecall`._

