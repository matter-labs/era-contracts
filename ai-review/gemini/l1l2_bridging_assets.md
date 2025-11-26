Here is the security assessment for the provided L1/L2 bridging contracts.

## Security issues

### 1. L2-to-L2 ETH Bridging Fails Permanently (DoS/Stuck Funds)
- **Severity**: High
- **Impact**: Any attempt to bridge ETH (Base Token) between L2 chains via the Interop system will revert on the destination chain. Depending on the Interop Center's failure handling mechanism, these funds may be permanently stuck in transit or require complex recovery, as the transaction can never succeed.
- **Description**: 
    In `L2AssetRouter.sol`, the `receiveMessage` function handles incoming cross-chain messages. When receiving an Interop message carrying ETH (Base Token), the `msg.value` is received by `receiveMessage`. It then attempts to forward the execution to `finalizeDeposit` using a low-level call:
    ```solidity
    (bool success, ) = address(this).call(payload);
    ```
    However, this `call` does not propagate `msg.value` (i.e., it sends 0 ETH). 
    
    The payload targets `finalizeDeposit`, which calls `_finalizeDeposit`, and eventually `L2NativeTokenVault._bridgeMintNativeToken`. This function explicitly enforces that the amount matches the value:
    ```solidity
    require(_depositAmount == msg.value, ValueMismatch(_depositAmount, msg.value));
    ```
    Since `_depositAmount` (from the message) will be positive but `msg.value` (in the internal call) is 0, the transaction will always revert with `ValueMismatch`.

### 2. Griefing of Custom Asset Handler Registration
- **Severity**: Medium
- **Impact**: An attacker can force the Native Token Vault (NTV) to become the immutable handler for any unregistered L1 token. This prevents the legitimate token owner from deploying a Custom Asset Handler (e.g., for governance tokens or tokens requiring special bridging logic), forcing them to redeploy a new token or accept NTV's default behavior.
- **Description**:
    `L1NativeTokenVault.ensureTokenIsRegistered` is a public function that allows anyone to register a token. Internally, it calls `L1AssetRouter.setAssetHandlerAddressThisChain`, which sets the handler for the calculated `assetId` to the NTV address and sets the `assetDeploymentTracker` to the NTV.
    
    In `AssetRouterBase.sol`, the `setAssetHandlerAddressThisChain` logic restricts updates to the current tracker:
    ```solidity
    require(senderIsNTV || msg.sender == assetDeploymentTracker[assetId], Unauthorized(msg.sender));
    ```
    Once NTV is set as the tracker, only NTV can update the handler. Since NTV has no functionality to change or unregister handlers, the token is permanently locked to NTV. An attacker can front-run a project's Custom Asset Handler deployment by calling `ensureTokenIsRegistered` first.

### 3. Multiple Deposits to Gateway-Settled Chains in One L1 Transaction revert
- **Severity**: Low
- **Impact**: Batching multiple deposits to the same Gateway-settled chain in a single L1 transaction (e.g., via Multicall) will fail, causing potential integration issues or DoS for batchers.
- **Description**:
    `L1AssetTracker` uses transient storage to track balance changes for Gateway-settled chains via `_setTransientBalanceChange`. This function reverts if the slot is not empty (`TransientBalanceChangeAlreadySet`).
    The slot is only cleared when `consumeBalanceChange` is called by the Gateway's L1 Mailbox. If the `Bridgehub` or the surrounding system does not guarantee that the Gateway consumes the balance change *immediately* and *synchronously* before the next deposit in the batch is processed, subsequent deposits in the same transaction will revert.

### 4. Fee-on-Transfer Tokens Unsupported
- **Severity**: Informational
- **Impact**: Bridging ERC20 tokens with fee-on-transfer mechanics will revert.
- **Description**:
    `L1NativeTokenVault` explicitly enforces that the amount received equals the amount requested:
    ```solidity
    uint256 expectedDepositAmount = _depositFunds(...);
    require(_depositAmount == expectedDepositAmount, TokensWithFeesNotSupported());
    ```
    While this is safe by design to prevent accounting mismatches between L1 and L2, it limits compatibility with certain tokens (e.g., USDT if fees are enabled, PAXG).