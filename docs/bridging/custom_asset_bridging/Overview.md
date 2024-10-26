#### Bridges

Bridges are completely separate contracts from the Diamond. They are a wrapper for L1 <-> L2 communication on contracts
on both L1 and L2. Upon locking assets on one layer, a request is sent to mint these bridged assets on the other layer.
Upon burning assets on one layer, a request is sent to unlock them on the other.

Unlike the native Ether bridging, all other assets can be bridged by the custom implementation relying on the trustless
L1 <-> L2 communication.

##### L1ERC20Bridge

The legacy implementation of the ERC20 token bridge. Works only with regular ERC20 tokens, i.e. not with
fee-on-transfer tokens or other custom logic for handling user balances. Only works for Era.

- `deposit` - lock funds inside the contract and send a request to mint bridged assets on L2.
- `claimFailedDeposit` - unlock funds if the deposit was initiated but then failed on L2.
- `finalizeWithdrawal` - unlock funds for the valid withdrawal request from L2.

##### L1AssetRouter

The "standard" implementation of the ERC20 and WETH token bridge. Works only with regular ERC20 tokens, i.e. not with
fee-on-transfer tokens or other custom logic for handling user balances.

- `deposit` - lock funds inside the contract and send a request to mint bridged assets on L2.
- `claimFailedDeposit` - unlock funds if the deposit was initiated but then failed on L2.
- `finalizeWithdrawal` - unlock funds for the valid withdrawal request from L2.

The bridge also handles WETH token deposits between the two domains. It is designed to streamline and
enhance the user experience for bridging WETH tokens by minimizing the number of transactions required and reducing
liquidity fragmentation thus improving efficiency and user experience.

This contract accepts WETH deposits on L1, unwraps them to ETH, and sends the ETH to the L2 WETH bridge contract, where
it is wrapped back into WETH and delivered to the L2 recipient.

Thus, the deposit is made in one transaction, and the user receives L2 WETH that can be unwrapped to ETH.

##### L2SharedBridge

The L2 counterpart of the L1 Shared bridge.

- `withdraw` - initiate a withdrawal by burning funds on the contract and sending a corresponding message to L1.
- `finalizeDeposit` - finalize the deposit and mint funds on L2.

For WETH withdrawals, the contract receives ETH from the L2 WETH bridge contract, wraps it into WETH, and sends the WETH to
the L1 recipient.

