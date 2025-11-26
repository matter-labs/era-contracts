## Security issues

### 1. Missing access control on `L2AssetRouter.receiveMessage` allows arbitrary minting of bridged tokens and theft of L1‑backed assets  

- **Severity**: Critical  
- **Impact**:  
  Any account on an L2 chain can locally call `L2AssetRouter.receiveMessage` to forge arbitrary `finalizeDeposit` calls, mint bridged tokens from nothing on that L2, and then withdraw them to L1. This drains real L1 tokens from `L1NativeTokenVault` against the chain’s balance (stealing funds belonging to legitimate depositors) without any corresponding burn/lock on another chain.

#### Where

```solidity
// L2AssetRouter.sol
function receiveMessage(
    bytes32 /* receiveId */,
    bytes calldata sender,
    bytes calldata payload
) external payable returns (bytes4) {
    (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);

    require((senderChainId != L1_CHAIN_ID && senderAddress == address(this)), Unauthorized(senderAddress));

    require(payload.length > 4, PayloadTooShort());
    require(
        bytes4(payload[0:4]) == IAssetRouterBase.finalizeDeposit.selector,
        InvalidSelector(bytes4(payload[0:4]))
    );

    (bool success, ) = address(this).call(payload);
    require(success, ExecuteMessageFailed());
    return IERC7786Recipient.receiveMessage.selector;
}
```

Notably, `receiveMessage` has **no restriction on `msg.sender`** (no `onlyL2InteropCenter` or equivalent), even though the comments say this is the entrypoint for the InteropCenter.  

There is also no consistency check between:

- `senderChainId` encoded in the ERC‑7930 `sender` parameter, and  
- The `_originChainId` argument inside the `finalizeDeposit` call contained in `payload`.

#### Why this is exploitable

1. **Anyone can call `receiveMessage` directly on L2**  
   There is no `onlyL2InteropCenter` or similar modifier. The only check is on the *encoded* `sender` argument:

   ```solidity
   (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);
   require((senderChainId != L1_CHAIN_ID && senderAddress == address(this)), Unauthorized(senderAddress));
   ```

   An attacker can trivially satisfy this by passing a fabricated ERC‑7930 address:

   ```solidity
   // Pseudocode
   sender = InteroperableAddress.formatEvmV1(
       fakeChainId != L1_CHAIN_ID,
       L2_ASSET_ROUTER_ADDR   // senderAddress == address(this)
   );
   ```

   Since there is no link between `senderChainId` and any on-chain state, this check does **not** authenticate a real cross‑chain sender.

2. **`payload` is only constrained to call `finalizeDeposit`**  
   `payload` just needs to start with the `finalizeDeposit` selector:

   ```solidity
   require(
       bytes4(payload[0:4]) == IAssetRouterBase.finalizeDeposit.selector,
       InvalidSelector(bytes4(payload[0:4]))
   );
   ```

   So the attacker can choose arbitrary arguments for:

   ```solidity
   function finalizeDeposit(
       uint256 _originChainId,
       bytes32 _assetId,
       bytes calldata _transferData
   ) ...
   ```

3. **`address(this).call(payload)` bypasses cross‑chain access control**

   The internal call:

   ```solidity
   (bool success, ) = address(this).call(payload);
   ```

   calls `finalizeDeposit` with `msg.sender == address(this)`.

   The access modifier on `finalizeDeposit` is:

   ```solidity
   modifier onlyAssetRouterCounterpartOrSelf(uint256 _chainId) {
       if (_chainId == L1_CHAIN_ID) {
           if (
               (AddressAliasHelper.undoL1ToL2Alias(msg.sender) != L1_ASSET_ROUTER) &&
               msg.sender != address(this)
           ) {
               revert Unauthorized(msg.sender);
           }
       } else {
           if (msg.sender != address(this)) {
               revert Unauthorized(msg.sender);
           }
       }
       _;
   }
   ```

   Since `msg.sender == address(this)`, **this modifier always passes for any `_originChainId`**.  
   The intended “only L1 asset router or self” check is completely bypassed.

4. **Forged deposits mint real bridged tokens on L2 without any burn/lock elsewhere**

   Inside `finalizeDeposit` on L2:

   ```solidity
   require(_assetId != BASE_TOKEN_ASSET_ID, AssetIdNotSupported(BASE_TOKEN_ASSET_ID));
   _finalizeDeposit(_originChainId, _assetId, _transferData, L2_NATIVE_TOKEN_VAULT_ADDR);
   ```

   `_finalizeDeposit` calls the asset handler’s `bridgeMint` — for NTV‑managed assets, this is:

   ```solidity
   IAssetHandler(L2_NATIVE_TOKEN_VAULT_ADDR).bridgeMint(_originChainId, _assetId, _transferData);
   ```

   In `L2NativeTokenVault` / `NativeTokenVaultBase`:

   ```solidity
   function bridgeMint(
       uint256 _chainId,
       bytes32 _assetId,
       bytes calldata _data
   ) external onlyAssetRouter requireZeroValue(msg.value) {
       if (originChainId[_assetId] == block.chainid) {
           (receiver, amount) = _bridgeMintNativeToken(...); // native
       } else {
           (receiver, amount) = _bridgeMintBridgedToken(...); // non-native
       }
   }
   ```

   For **non‑native (L1‑origin) tokens** (e.g. USDC, WETH on L1), `_bridgeMintBridgedToken` executes:

   ```solidity
   (, receiver, originToken, amount, erc20Data) = DataEncoding.decodeBridgeMintData(_data);

   if (token == address(0)) {
       token = _ensureAndSaveTokenDeployed(_assetId, originToken, erc20Data);
   }

   _handleBridgeFromChain(_chainId, _assetId, amount); // on L2: just informs L2AssetTracker
   IBridgedStandardToken(token).bridgeMint(receiver, amount);
   ```

   Crucially:
   - There is **no check** that this mint corresponds to a real burn/lock on `_originChainId`.
   - For already‑registered assets (`token != address(0)`), `_ensureAndSaveTokenDeployed` is not called, so no `assetIdCheck` or origin validation happens here.
   - The L2 AssetTracker does **not** track `chainBalance` for non‑native tokens (per docs and code), so this mint is effectively unbacked.

5. **Attacker can then legitimately withdraw forged tokens to L1 and steal from the L1 vault**

   With forged bridged tokens on L2, the attacker can use the normal withdrawal flow:

   ```solidity
   L2AssetRouter.withdraw(_assetId, assetData);
   ```

   - This calls `_withdrawSender` → `_burn` → `L2NativeTokenVault.bridgeBurn` for `_assetId`.
   - For non‑native tokens, `_bridgeBurnBridgedToken` burns the L2 bridged tokens and calls:

     ```solidity
     _handleBridgeToChain(L1_CHAIN_ID, _assetId, amount);
     ```

     which on L2 is:

     ```solidity
     L2_ASSET_TRACKER.handleInitiateBridgingOnL2(_assetId, amount, originChainId[_assetId]);
     ```

     For non‑native tokens, this **does not** decrease any `chainBalance` on L2 (by design).

   - `_withdrawSender` then sends an L2→L1 message:

     ```solidity
     message = _getAssetRouterWithdrawMessage(_assetId, l1bridgeMintData);
     // selector = IAssetRouterBase.finalizeDeposit.selector
     L2ContractHelper.sendMessageToL1(message);
     ```

   On L1, `L1Nullifier.finalizeDeposit` verifies the L2→L1 proof and forwards to `L1AssetRouter.finalizeDeposit`, which in turn calls `L1NativeTokenVault.bridgeMint`:

   ```solidity
   // originChainId[_assetId] == block.chainid for L1-native tokens
   (receiver, amount) = _bridgeMintNativeToken(...);
   // inside _bridgeMintNativeToken:
   _handleBridgeFromChain(_chainId, _assetId, amount); // L1AssetTracker.decreaseChainBalance(...)
   _withdrawFunds(_assetId, receiver, token, amount);  // transfer real L1 tokens/ETH
   ```

   So for L1‑native assets (USDC, standard ERC20s, ETH via NTV), the attacker’s forged withdraw:

   - **Reduces** `L1AssetTracker.chainBalance[attackedL2ChainId][_assetId]` by `amount`, and  
   - **Sends real L1 tokens** from `L1NativeTokenVault` to the attacker.

   The L1 tracker has no way to distinguish these withdrawals from legitimate ones, because the message proof and format are both valid.

6. **Who loses?**

   - `chainBalance[attackedL2][assetId]` represents the aggregate L1‑side escrow for that L2’s users.
   - Honest users who had deposited from L1 to that L2 (thus increasing this `chainBalance`) will subsequently find their L2->L1 withdrawals reverted with `InsufficientChainBalance`, because the attacker has pre‑emptively drained the vault using forged deposits → withdrawals.
   - The attacker never locked/burned any real tokens on any chain.

#### Attack sketch

On L2 chain `B`:

1. Choose a popular L1‑native token bridged via NTV (e.g. USDC).
2. Look up its `assetId` and L2 token address via `L2NativeTokenVault.assetId(l2Token)` or via SDK.
3. Forged deposit on L2:
   ```solidity
   bytes memory transferData = DataEncoding.encodeBridgeMintData(
       fakeOriginalCaller,
       attackerL2Address,
       originTokenL1Address,
       amount,
       fakeErc20Metadata
   );

   bytes memory payload = abi.encodeWithSelector(
       IAssetRouterBase.finalizeDeposit.selector,
       /* _originChainId */ someL2orL1Id,
       assetId,
       transferData
   );

   bytes memory sender = InteroperableAddress.formatEvmV1(
       /* senderChainId */ 1234,       // != L1_CHAIN_ID
       address(L2_ASSET_ROUTER_ADDR)  // satisfies senderAddress == address(this)
   );

   L2AssetRouter(receiveMessageContract).receiveMessage(
       0xdead,  // receiveId ignored
       sender,
       payload
   );
   ```
   Result: `amount` bridged tokens minted to `attackerL2Address`, with **no backing on any other chain**.

4. Withdraw forged tokens to L1 via standard API:
   ```solidity
   // assetData encodes (amount, l1Receiver, l2Token)
   L2AssetRouter.withdraw(assetId, assetData);
   ```
   After L2 batch is proved on L1, attacker calls `L1Nullifier.finalizeDeposit` with the L2 message proof and receives `amount` real L1 tokens from `L1NativeTokenVault`.

5. Repeat until `L1AssetTracker.chainBalance[B][assetId]` is 0. All further honest withdrawals for this token from chain `B` will fail.

#### Why this is not mitigated elsewhere

- L2 `Pausable`:
  - `receiveMessage` is **not** guarded by `whenNotPaused`.
  - `finalizeDeposit` is `nonReentrant` but that does not limit who can trigger it.
- L2 AssetTracker:
  - Only tracks `chainBalance` for **native** tokens on the L2. Non‑native tokens (L1 origin) are expected to use L1/Gateway accounting, so forged mints are not caught.
- L1 Nullifier / AssetTracker / NTV:
  - They correctly verify L2→L1 message proofs and enforce chainBalance limits, but once there is some legitimate `chainBalance` for a chain+asset, any withdrawal with a valid L2 message will be honored, including forged ones coming from this exploit.

#### Recommendation

Apply strict access control on `receiveMessage`:

```solidity
function receiveMessage(
    bytes32 receiveId,
    bytes calldata sender,
    bytes calldata payload
) external payable onlyL2InteropCenter returns (bytes4) {
    ...
}
```

Where:

```solidity
modifier onlyL2InteropCenter() {
    require(msg.sender == L2_INTEROP_CENTER_ADDR, Unauthorized(msg.sender));
    _;
}
```

Additionally, for defense‑in‑depth:

- Validate that `senderChainId` from the ERC‑7930 `sender` matches the `_originChainId` in the `finalizeDeposit` payload when it is an L2→L2 transfer.  
- Consider also marking `receiveMessage` as `nonReentrant` to match other sensitive entrypoints.

This bug should be considered **critical** because it enables direct, permissionless theft of L1‑backed assets and permanent denial of service for honest users’ withdrawals from affected L2 chains, without any need to compromise validators or proof systems.

---

## Open assumptions / not fully validated

The analysis above assumes the following components behave according to their specifications, but their implementations were not in scope here:

1. **Bridgehub (L1 & L2)**  
   - Correctly sets `_amount` and `msg.value` for `bridgehubDepositBaseToken`.  
   - Correctly sets the L2 `msg.sender` (aliased L1AssetRouter) when calling `L2AssetRouter.finalizeDeposit` for L1→L2 deposits, making the `onlyAssetRouterCounterpartOrSelf` check meaningful.

2. **InteropCenter / IInteropHandler**  
   - Always calls `L2AssetRouter.receiveMessage` as part of ERC‑7786 flows with correctly formed `sender` and `payload`.  
   - No other contracts are expected to call `receiveMessage` in normal operation, so adding `onlyL2InteropCenter` should not break intended functionality.

3. **MessageRoot / proof verification**  
   - Correctly verifies inclusion of L2→L1 messages so that an attacker cannot forge L2 logs or proofs; the exploit above relies only on the ability to produce valid L2 logs by calling public functions on L2, which is by design.

If Bridgehub or Interop semantics differ substantially from the documentation (e.g. if they already enforce that only InteropCenter can call `receiveMessage` via precompiles), this may mitigate part of the risk, but based solely on the provided contracts, that protection is missing at the L2AssetRouter level.