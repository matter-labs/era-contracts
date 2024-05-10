## DiamondInit

_The contract is used only once to initialize the diamond proxy.
The deployment process takes care of this contract's initialization._

### constructor

```solidity
constructor() public
```

_Initialize the implementation to prevent any possibility of a Parity hack._

### initialize

```solidity
function initialize(struct InitializeData _initializeData) external returns (bytes32)
```

hyperchain diamond contract initialization

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy initializer |

