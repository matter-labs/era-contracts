# GasBoundCaller

Starting from v24 On Era, the gas for pubdata is charged at the end of the execution of the entire transaction. This means that if a subcall is not trusted, it can consume a significant amount of pubdata during the process. While this may not be an issue for most contracts, there are use cases, e.g., for relayers, where it is crucial to ensure that the subcall will not spend more money than intended.

The `GasBoundCaller` is a contract with the following interface:

```solidity
function gasBoundCall(address _to, uint256 _maxTotalGas, bytes calldata _data) external payable
```

> Note that the amount of gas passed into this function should be less than or equal to `_maxTotalGas`. If the computational gas provided is higher than `_maxTotalGas`, the higher value will be used.

This contract will call the address `_to` with the entire execution gas passed to it, while ensuring that the total consumed gas does not exceed `_maxTotalGas` under any circumstances.

If the call to the `_to` address fails, the gas used on pubdata is considered zero, and the total gas used is fully equivalent to the gas consumed within the execution. The `GasBoundCaller` will relay the revert message as-is.

If the call to the `_to` address succeeds, the `GasBoundCaller` will ensure that the total consumed gas does not exceed `_maxTotalGas`. If it does, it will revert with a "Not enough gas for pubdata" error. If the total consumed gas is less than or equal to `_maxTotalGas`, the `GasBoundCaller` will return returndata equal to `abi.encode(bytes returndataFromSubcall, uint256 gasUsedForPubdata)`.

## Usage

Summing up the information from the previous chapter, the `GasBoundCaller` should be used in the following way:

```solidity
uint256 computeGasBefore = gasleft();

(bool success, bytes memory returnData) = address(0xc706EC7dfA5D4Dc87f29f859094165E8290530f5).call{gas: _gasToPass}(abi.encodeWithSelector(GasBoundCaller.gasBoundCall.selector, _to, _maxTotalGas, _data));

uint256 pubdataGasSpent;
if (success) {
    (returnData, pubdataGasSpent) = abi.decode(returnData, (bytes, uint256));
} else {
    // `returnData` is fully equal to the returndata, while `pubdataGasSpent` is equal to 0
}

uint256 computeGasAfter = gasleft();

// This is the total gas that the subcall made the transaction to be charged for
uint256 totalGasConsumed = computeGasBefore - computeGasAfter + pubdataGasSpent;
```

### Preserving `msg.sender`

Since `GasBoundCaller` would be the contract that calls the `_to` contract, the `msg.sender` will be equal to the `GasBoundCaller`'s address. To preserve the current `msg.sender`, this contract can be inherited from and used the same way, but instead of calling `GasBoundCaller.gasBoundCall`, `this.gasBoundCall` could be called.

## Deployed Address

It should be deployed via a built-in CREATE2 factory on each individual chain.

The current address on both sepolia testnet and mainnet for zkSync Era is `0xc706EC7dfA5D4Dc87f29f859094165E8290530f5`.
