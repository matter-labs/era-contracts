## Security issues

### 1. Incorrect decoding of Gateway → L1 upgrade message in `L1MessageRoot.saveV30UpgradeChainBatchNumberOnL1`

- **Severity**: Medium  
- **Impact**: The `v30UpgradeChainBatchNumber` stored on L1 for each chain is likely wrong (set to the chain ID instead of the intended upgrade batch number). This can break or subtly weaken any logic that assumes this value is correct (e.g. future-proofed L2→L1 verification, AssetTracker / Nullifier accounting or migration invariants), potentially leading to incorrect trust boundaries for post‑upgrade batches.

**Details**

In `L1MessageRoot.saveV30UpgradeChainBatchNumberOnL1`:

```solidity
function saveV30UpgradeChainBatchNumberOnL1(
    FinalizeL1DepositParams calldata _finalizeWithdrawalParams
) external {
    ...

    (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
    require(
        bytes4(functionSignature) == L2MessageRoot.sendV30UpgradeBlockNumberFromGateway.selector,
        IncorrectFunctionSignature()
    );

    // slither-disable-next-line unused-return
    (uint256 chainId, ) = UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset);
    // slither-disable-next-line unused-return
    (uint256 receivedV30UpgradeChainBatchNumber, ) = UnsafeBytes.readUint256(
        _finalizeWithdrawalParams.message,
        offset
    );
    require(v30UpgradeChainBatchNumber[chainId] == 0, V30UpgradeChainBatchNumberAlreadySet());
    v30UpgradeChainBatchNumber[chainId] = receivedV30UpgradeChainBatchNumber;
}
```

The second `readUint256` call reuses the same `offset` as the first, ignoring the new offset that `readUint256` returns. As a result:

- `chainId` is read from bytes `[4..35]` of the message (correct), but  
- `receivedV30UpgradeChainBatchNumber` is also read from `[4..35]` instead of `[36..67]`.

Given how `L2MessageRoot.sendV30UpgradeBlockNumberFromGateway` encodes the message:

```solidity
L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
    abi.encodeCall(this.sendV30UpgradeBlockNumberFromGateway, (_chainId, sentBlockNumber))
);
```

the second parameter (`sentBlockNumber`) is never correctly decoded on L1, and `receivedV30UpgradeChainBatchNumber` effectively equals the encoded `_chainId` value (modulo any ABI packing coincidences).

So on L1:

```solidity
v30UpgradeChainBatchNumber[chainId] = chainId;  // instead of sentBlockNumber
```

This means L1’s `v30UpgradeChainBatchNumber` will not match the settlement layer’s value and will not reflect the real “first post‑v30 batch” for that chain.

Because `v30UpgradeChainBatchNumber` is used to distinguish pre‑/post‑upgrade semantics (see comments in `MessageRootBase`), an incorrect value can:

- cause other components to treat pre‑upgrade batches as post‑upgrade (or vice versa);
- desynchronize L1’s view of when a chain moved to the new accounting rules, especially relevant for chains settling on Gateway.

The exact downstream impact depends on how other contracts (e.g. `L1Nullifier`, AssetTracker) consume this mapping; those are outside the provided scope, but the decoding bug is clear and should be corrected before any new logic relies on this number.

**Recommendation**

Decode the two parameters using the updated offset from the first `readUint256`:

```solidity
(uint32 functionSignature, uint256 offset) =
    UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
require(
    bytes4(functionSignature) == L2MessageRoot.sendV30UpgradeBlockNumberFromGateway.selector,
    IncorrectFunctionSignature()
);

(uint256 chainId, uint256 offset2) =
    UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset);
(uint256 receivedV30UpgradeChainBatchNumber, ) =
    UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset2);

require(v30UpgradeChainBatchNumber[chainId] == 0, V30UpgradeChainBatchNumberAlreadySet());
v30UpgradeChainBatchNumber[chainId] = receivedV30UpgradeChainBatchNumber;
```

Additionally, consider adding a sanity check that the received batch number is non‑zero and not equal to the special placeholder constants to avoid accidental misuse.


---

### 2. Misconfigured access control for `L2Bridgehub.registerChainForInterop` blocks the documented Bridgehub deposit path

- **Severity**: Low  
- **Impact**: The intended “normal deposit” path for chain registration via `ChainRegistrationSender.bridgehubDeposit` cannot successfully call `L2Bridgehub.registerChainForInterop`, because the `onlyChainRegistrationSender` modifier does not accept the alias of the L1 sender. This disables a documented registration path (registration with base token funding via Bridgehub), leaving only the service‑transaction path available. It does not directly endanger funds but breaks an advertised feature and can cause integration failures.

**Details**

`L2Bridgehub.registerChainForInterop` is guarded by:

```solidity
modifier onlyChainRegistrationSender() {
    if (
        msg.sender != AddressAliasHelper.undoL1ToL2Alias(chainRegistrationSender) &&
        msg.sender != SERVICE_TRANSACTION_SENDER
    ) {
        revert Unauthorized(msg.sender);
    }
    _;
}
```

Per `BridgehubBase`:

```solidity
/// @dev If the Bridgehub is on L2 the address is aliased.
address public chainRegistrationSender;
```

That is, on L2:
- `chainRegistrationSender` is expected to hold the **aliased** address of the L1 `ChainRegistrationSender`, i.e. `applyL1ToL2Alias(L1_CR_SENDER)`.

The two intended ways to reach `registerChainForInterop` are:

1. **Service transaction path (used by `ChainRegistrationSender.registerChain`)**

   - On L2, the call originates from the special `SERVICE_TRANSACTION_SENDER`.
   - This branch is correctly permitted by the modifier.

2. **Bridgehub “normal deposit” path (used by `ChainRegistrationSender.bridgehubDeposit`)**

   - L1: `Bridgehub.requestL2TransactionTwoBridges` is called with `secondBridgeAddress = ChainRegistrationSender`.
   - `ChainRegistrationSender.bridgehubDeposit` returns an `L2TransactionRequestTwoBridgesInner` with:
     ```solidity
     l2Contract = L2_BRIDGEHUB_ADDR;
     l2Calldata = abi.encodeCall(IL2Bridgehub.registerChainForInterop, (...));
     ```
   - The `BridgehubL2TransactionRequest.sender` is set to `secondBridgeAddress` (the L1 `ChainRegistrationSender`).
   - On L2, the canonical L2 sender will be `applyL1ToL2Alias(L1_CR_SENDER)`.

Therefore, on L2:

- `msg.sender` when executing `registerChainForInterop` via **deposit** is `applyL1ToL2Alias(L1_CR_SENDER)`,
- `chainRegistrationSender` is also expected to be `applyL1ToL2Alias(L1_CR_SENDER)`,

but the modifier checks:

```solidity
msg.sender == AddressAliasHelper.undoL1ToL2Alias(chainRegistrationSender)
```

so:

- `AddressAliasHelper.undoL1ToL2Alias(chainRegistrationSender)` gives back the **L1** address (`L1_CR_SENDER`),
- while `msg.sender` is its **aliased L2** form.

Thus, the check fails for the deposit path, and only `SERVICE_TRANSACTION_SENDER` can call `registerChainForInterop`. The documented usage in `ChainRegistrationSender.bridgehubDeposit`:

```solidity
/// @notice Registers a chain on the L2 via a normal deposit.
/// @notice this is can be called by anyone (via the bridgehub), but baseTokens need to be provided.
```

is effectively non‑functional under this access control.

**Recommendation**

Change the modifier to compare directly against the (aliased) `chainRegistrationSender` stored on L2, not its “unaliasing”:

```solidity
modifier onlyChainRegistrationSender() {
    if (
        msg.sender != chainRegistrationSender &&  // chainRegistrationSender is already aliased on L2
        msg.sender != SERVICE_TRANSACTION_SENDER
    ) {
        revert Unauthorized(msg.sender);
    }
    _;
}
```

Alternatively, if you prefer to store the **L1** address in `chainRegistrationSender` on L2, adjust the check to:

```solidity
if (
    msg.sender != AddressAliasHelper.applyL1ToL2Alias(chainRegistrationSender) &&
    msg.sender != SERVICE_TRANSACTION_SENDER
) { ... }
```

but the current combination (storing an aliased address and then `undo`‑ing it) is inconsistent with the actual sender in the deposit path.


---

### 3. `saveV30UpgradeChainBatchNumberOnL1` pre‑condition likely inconsistent with initialization scheme

- **Severity**: Low (correctness / upgradeability footgun)  
- **Impact**: Depending on how the L1 `MessageRoot` proxy is initialized in production, `saveV30UpgradeChainBatchNumberOnL1` may always revert due to `v30UpgradeChainBatchNumber[chainId]` being non‑zero from `_v30InitializeInner`. This would prevent Gateway from ever recording v30 upgrade points on L1, undermining the upgrade protocol for chains settling on Gateway. Whether this manifests depends on deployment sequence and proxy usage.

**Details**

`L1MessageRoot.saveV30UpgradeChainBatchNumberOnL1` contains:

```solidity
require(v30UpgradeChainBatchNumber[chainId] == 0, V30UpgradeChainBatchNumberAlreadySet());
v30UpgradeChainBatchNumber[chainId] = receivedV30UpgradeChainBatchNumber;
```

But `MessageRootBase._v30InitializeInner` (called from several initializers) sets **non‑zero placeholders** for each chain:

```solidity
function _v30InitializeInner(uint256[] memory _allZKChains) internal {
    uint256 allZKChainsLength = _allZKChains.length;
    for (uint256 i = 0; i < allZKChainsLength; ++i) {
        uint256 batchNumberToWrite = V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY;
        if (IBridgehubBase(_bridgehub()).settlementLayer(_allZKChains[i]) == L1_CHAIN_ID()) {
            /// If we are settling on L1.
            batchNumberToWrite = V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1;
        }
        v30UpgradeChainBatchNumber[_allZKChains[i]] = batchNumberToWrite;
    }
}
```

On L2 (Gateway), this placeholder is later replaced via `saveV30UpgradeChainBatchNumber`. On L1, however:

- Depending on whether `_v30InitializeInner` is invoked via the constructor or `initializeL1V30Upgrade`, `v30UpgradeChainBatchNumber[chainId]` may already be non‑zero before `saveV30UpgradeChainBatchNumberOnL1` is called,
- In that case, `require(v30UpgradeChainBatchNumber[chainId] == 0, ...)` will always revert and the function can never succeed.

Given the complexity of the upgrade path (implementation constructor vs proxy initializers), it’s easy for this to be mis‑configured during deployment and for the L1 side of the v30 sync protocol to silently break.

**Recommendation**

Align the pre‑condition with the placeholder logic, e.g.:

- Require that the current value equals the appropriate placeholder instead of `0`, and  
- Optionally verify that L1 and Gateway values match after update.

Example:

```solidity
uint256 current = v30UpgradeChainBatchNumber[chainId];
require(
    current == 0 ||
    current == V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1,
    V30UpgradeChainBatchNumberAlreadySet()
);
v30UpgradeChainBatchNumber[chainId] = receivedV30UpgradeChainBatchNumber;
```

Also ensure deployment / upgrade docs clearly state which initializer is called on the proxy so that `v30UpgradeChainBatchNumber` starts from the expected placeholder state.


---

## Open points / dependencies outside current scope

Some of the above findings involve values that are consumed by other components not included in the scope (e.g. `L1Nullifier`, AssetTracker, CTM logic). To fully validate the runtime impact, the following contracts / files would be useful:

- `IL1Nullifier` implementation and its use of `IMessageRoot.v30UpgradeChainBatchNumber` and `currentChainBatchNumber`.
- AssetTracker contracts on L1 and Gateway, especially any logic that gates withdrawals or balance accounting based on `v30UpgradeChainBatchNumber`.
- ZKChain (Diamond) `ExecutorFacet` / `MailboxFacet` implementation of `bridgehubRequestL2Transaction` to fully sanity‑check aliasing and sender semantics (though current usage appears consistent with docs).
- Deployment scripts / configuration showing how `L1MessageRoot` and `L2Bridgehub` proxies are initialized in production.

From the code alone, the identified bugs are real and should be fixed, but the exact exploitability (particularly of issues 1 and 3) depends on how these external components use the affected mappings and how the system is deployed.