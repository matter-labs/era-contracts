## Security issues

### 1. Unauthenticated cross‑L2 message entrypoint allows arbitrary minting of bridged tokens on L2

- **Severity**: Critical  
- **Impact**: Any attacker on an L2 chain can mint arbitrary amounts of existing bridged tokens (e.g. bridged USDC) without any burn on the source chain, breaking the 1:1 backing of bridged assets on that L2 and enabling theft from L2 protocols that treat those tokens as canonical.

#### Details

On L2, cross‑L2 interop messages are meant to arrive via the InteropCenter / InteropHandler and be delivered to the router through the ERC‑7786 `receiveMessage` entrypoint. The router then internally calls `finalizeDeposit`, which mints tokens via the NativeTokenVault (NTV).

However, `L2AssetRouter.receiveMessage` has **no access control on `msg.sender`**:

```solidity
function receiveMessage(
    bytes32 /* receiveId */,
    bytes calldata sender,
    bytes calldata payload
) external payable returns (bytes4) {
    (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);

    require((senderChainId != L1_CHAIN_ID && senderAddress == address(this)), Unauthorized(senderAddress));

    require(payload.length > 4, PayloadTooShort());
    require(
        bytes4(payload[0:4]) == AssetRouterBase.finalizeDeposit.selector,
        InvalidSelector(bytes4(payload[0:4]))
    );

    (bool success, ) = address(this).call(payload);
    require(success, ExecuteMessageFailed());
    return IERC7786Recipient.receiveMessage.selector;
}
```

Key points:

- **Anyone** (EOA or contract) on L2 can call `receiveMessage`.
- The only checks are on the **content of the `sender` bytes**, not on `msg.sender`. Those bytes are fully controlled by the caller.
- As long as `sender` encodes `senderAddress == address(this)` and any `senderChainId != L1_CHAIN_ID`, the `Unauthorized` check passes.

The `payload` is then executed via `address(this).call(payload)`, which invokes `L2AssetRouter.finalizeDeposit(...)` with `msg.sender == address(this)`.

`finalizeDeposit` is gated by:

```solidity
function finalizeDeposit(
    uint256 _originChainId,
    bytes32 _assetId,
    bytes calldata _transferData
) public payable override onlyAssetRouterCounterpartOrSelf(_originChainId) nonReentrant {
    require(_assetId != BASE_TOKEN_ASSET_ID, AssetIdNotSupported(BASE_TOKEN_ASSET_ID));
    _finalizeDeposit(_originChainId, _assetId, _transferData, L2_NATIVE_TOKEN_VAULT_ADDR);
    ...
}

modifier onlyAssetRouterCounterpartOrSelf(uint256 _chainId) {
    if (_chainId == L1_CHAIN_ID) {
        if (
            (AddressAliasHelper.undoL1ToL2Alias(msg.sender) != address(L1_ASSET_ROUTER)) &&
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

- When called via `receiveMessage`, `msg.sender == address(this)`, so `onlyAssetRouterCounterpartOrSelf` passes for **any** `_originChainId` the attacker encodes in `payload`.

Inside `_finalizeDeposit`, the router calls the asset handler (NTV on L2):

```solidity
function _finalizeDeposit(
    uint256 _chainId,
    bytes32 _assetId,
    bytes calldata _transferData,
    address _nativeTokenVault
) internal {
    address assetHandler = assetHandlerAddress[_assetId];

    if (assetHandler != address(0)) {
        IAssetHandler(assetHandler).bridgeMint{value: msg.value}(_chainId, _assetId, _transferData);
    } else {
        _setAssetHandler(_assetId, _nativeTokenVault);
        IAssetHandler(_nativeTokenVault).bridgeMint{value: msg.value}(_chainId, _assetId, _transferData);
    }
}
```

On L2, for standard bridged ERC‑20s, `assetHandlerAddress[_assetId] == L2_NATIVE_TOKEN_VAULT_ADDR`, and `bridgeMint` in `NativeTokenVaultBase` eventually does:

```solidity
function _bridgeMintBridgedToken(
    uint256 _chainId,
    bytes32 _assetId,
    bytes calldata _data
) internal returns (address receiver, uint256 amount) {
    address token = tokenAddress[_assetId];
    bytes memory erc20Metadata;
    address originToken;
    (, receiver, originToken, amount, erc20Metadata) = DataEncoding.decodeBridgeMintData(_data);

    if (token == address(0)) {
        token = _ensureAndSaveTokenDeployed(_assetId, originToken, erc20Metadata);
        // _ensureAndSaveTokenDeployed does assetIdCheck only *when deploying* a new token
    }

    _handleBridgeFromChain({_chainId: _chainId, _assetId: _assetId, _amount: amount});
    IBridgedStandardToken(token).bridgeMint(receiver, amount);
}
```

**Crucially**:

- For **already‑registered bridged assets** (where `tokenAddress[_assetId] != address(0)`), the vault **does not** call `assetIdCheck` or consult any off‑chain proof. It trusts the `_assetId` and `_data` fields as given.
- That means if you know an existing `assetId` (e.g. for bridged USDC), you can bypass all L1 / Interop checks and directly mint in the canonical bridged token contract on this L2.

#### Exploit sketch

On any L2:

1. Find a bridged token’s `assetId` and NTV mapping:
   - Read `tokenAddress[assetId]` from `L2NativeTokenVault` to get the canonical bridged token contract (e.g. bridged USDC).
   - Confirm `assetHandlerAddress[assetId] == L2_NATIVE_TOKEN_VAULT_ADDR` in `L2AssetRouter`.

2. Prepare arbitrary mint data:
   - Choose any amount `A` and victim receiver `victim`.
   - Build `_transferData = DataEncoding.encodeBridgeMintData(
       _originalCaller = attacker,
       _remoteReceiver = victim,
       _originToken = arbitrary,         // ignored in this path
       _amount = A,
       _erc20Metadata = arbitrary
     );`

3. Call `L2AssetRouter.receiveMessage` directly:

   ```solidity
   bytes memory sender = InteroperableAddress.formatEvmV1(
       fakeSourceChainId,       // any != L1_CHAIN_ID
       address(L2_ASSET_ROUTER) // required by the contract, but attacker controls this encoding
   );

   bytes memory payload = abi.encodeWithSelector(
       AssetRouterBase.finalizeDeposit.selector,
       fakeOriginChainId,       // any value
       assetId,                 // existing bridged assetId
       _transferData
   );

   L2AssetRouter(L2_ASSET_ROUTER_ADDR).receiveMessage(
       bytes32(0), // receiveId, unused
       sender,
       payload
   );
   ```

4. `receiveMessage` passes its internal checks and calls `finalizeDeposit`, which calls NTV’s `bridgeMint`, which:
   - Does **no proof verification** for this existing `assetId`.
   - Calls the bridged token’s `bridgeMint`, minting `A` tokens directly to `victim`.

This can be repeated to mint unlimited unbacked supply of any bridged token whose `assetId` is already registered on this L2.

Because L1 and Gateway accounting (`L1AssetTracker`, `GWAssetTracker`) are **not** involved in this forged path, these tokens are not redeemable back to L1 — but they are indistinguishable from legitimate bridged tokens on this L2. Any L2 protocol (DEX, lending, etc.) that trusts these tokens as canonical can be drained.

#### Why proofs and the Bootloader don’t save this

- No L1 proof or Interop bundle inclusion is checked in this path.
- The only “authentication” is the content of the `sender` bytes, which are provided by the attacker, not by a system contract.
- The Bootloader / message root are not consulted at all in `receiveMessage`; they are only used inside the InteropHandler / MessageRoot flow, which this function bypasses.

#### Recommendation

- Restrict `receiveMessage` so that it can only be called by the **InteropCenter / InteropHandler system contract** for the chain, e.g.:

  ```solidity
  modifier onlyL2InteropCenter() {
      require(msg.sender == L2_INTEROP_CENTER_ADDR, Unauthorized(msg.sender));
      _;
  }

  function receiveMessage(...) external payable onlyL2InteropCenter returns (bytes4) {
      ...
  }
  ```

  or an equivalent check (`msg.sender == L2_INTEROP_HANDLER_ADDR` depending on architecture).

- Optionally, further harden by:
  - Validating that the `sender` bytes’ `senderChainId` / `senderAddress` are consistent with an expected mapping that is only configurable by governance.
  - Adding a defensive `assetIdCheck` even for already‑registered assets in `_bridgeMintBridgedToken`:

    ```solidity
    if (token != address(0)) {
        (, , originToken, , erc20Metadata) = DataEncoding.decodeBridgeMintData(_data);
        (uint256 originChainId, , , ) = DataEncoding.decodeTokenData(erc20Metadata);
        DataEncoding.assetIdCheck(originChainId, _assetId, originToken);
    }
    ```

- Perform a one‑off review of existing L2 deployments to check whether any anomalous minting has occurred through this path (e.g. by diffing totalSupply changes against legitimate L1 deposits).

---

### 2. L2AssetRouter pause does not cover base‑token deposits from InteropCenter

- **Severity**: Low  
- **Impact**: On L2, `pause()` on `L2AssetRouter` does not stop `bridgehubDepositBaseToken` calls from the InteropCenter, so base‑token (gas token) deposits via Interop may remain active even when bridging of other tokens is paused. This is more an operational / emergency‑response issue than a direct exploit.

#### Details

`AssetRouterBase` is `PausableUpgradeable`; `L2AssetRouter` inherits it and uses `whenNotPaused` in some internal flows:

```solidity
function _bridgehubDeposit(
    uint256 _chainId,
    address _originalCaller,
    uint256 _value,
    bytes calldata _data,
    address _nativeTokenVault
) internal virtual whenNotPaused returns (L2TransactionRequestTwoBridgesInner memory request) { ... }

function initiateIndirectCall(
    uint256 _chainId,
    address _originalCaller,
    uint256 _value,
    bytes calldata _data
) external payable onlyL2InteropCenter returns (InteropCallStarter memory) {
    L2TransactionRequestTwoBridgesInner memory request = _bridgehubDeposit({ ... });
    ...
}
```

So **token deposits via interop** go through `_bridgehubDeposit` and are paused correctly.

However, base‑token deposits use a different entrypoint:

```solidity
function bridgehubDepositBaseToken(
    uint256 _chainId,
    bytes32 _assetId,
    address _originalCaller,
    uint256 _amount
) public payable virtual override onlyL2InteropCenter {
    _bridgehubDepositBaseToken(_chainId, _assetId, _originalCaller, _amount);
}
```

- `_bridgehubDepositBaseToken` in `AssetRouterBase` does **not** have `whenNotPaused`.
- `bridgehubDepositBaseToken` in `L2AssetRouter` also lacks `whenNotPaused`.

Thus, calling `pause()` on `L2AssetRouter`:

- Blocks `_bridgehubDeposit` (and therefore `initiateIndirectCall` for ERC‑20s).
- **Does not block** `bridgehubDepositBaseToken` from `L2_INTEROP_CENTER_ADDR`.

If operators rely on `pause()` for emergency response and believe it affects all bridging, they may mistakenly think base‑token interop is halted while it is still allowed.

#### Recommendation

- Consider adding `whenNotPaused` to the L2 base‑token path for consistency and operational safety, for example:

  ```solidity
  function bridgehubDepositBaseToken(
      uint256 _chainId,
      bytes32 _assetId,
      address _originalCaller,
      uint256 _amount
  ) public payable override onlyL2InteropCenter whenNotPaused {
      _bridgehubDepositBaseToken(_chainId, _assetId, _originalCaller, _amount);
  }
  ```

- If, for design reasons, base‑token deposits are intended to remain operational even when the router is paused, document this explicitly so operators do not overestimate the protection provided by `pause()`.

---

## Open questions / areas needing external context

These are not flagged as vulnerabilities but would benefit from confirmation against components outside this scope:

1. **Bridgehub / InteropCenter behavior assumptions**  
   - We assumed that:
     - Bridgehub never sends non‑zero `msg.value` to `_bridgehubDepositNonBaseTokenAsset` (only `_value`).
     - InteropCenter always calls `L2AssetRouter.receiveMessage` on behalf of other chains.
   - If Bridgehub or InteropCenter deviate from these assumptions, it may affect value‑accounting and pause behavior; reviewing their implementations would fully validate these paths.

2. **Bootloader and system contract trust model**  
   - `GWAssetTracker.processLogsAndMessages` and migration code assume that:
     - System contracts like `L2_BOOTLOADER_ADDRESS`, `L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR`, `L2_INTEROP_CENTER_ADDR`, and others behave according to the spec.
   - A review of those system contracts and the Bootloader is needed to complete the malicious‑operator analysis, but nothing in the current code obviously weakens those assumptions beyond the `receiveMessage` issue already reported.