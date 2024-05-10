## TestnetVerifier

Modified version of the main verifier contract for the testnet environment

_This contract is used to skip the zkp verification for the testnet environment.
If the proof is not empty, it will verify it using the main verifier contract,
otherwise, it will skip the verification._

### constructor

```solidity
constructor() public
```

### verify

```solidity
function verify(uint256[] _publicInputs, uint256[] _proof, uint256[] _recursiveAggregationInput) public view returns (bool)
```

_Verifies a zk-SNARK proof, skipping the verification if the proof is empty._

