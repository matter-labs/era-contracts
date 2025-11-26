## Security issues

### 1. Reentrancy guard likely makes the `receiveMessage` rescue path unusable

- **Title**: `nonReentrant` on `InteropHandler.receiveMessage` prevents intended internal calls
- **Severity**: Medium  
- **Impact**: For bundles that rely on the ERC‑7786 `receiveMessage` rescue path (which is the *default* unbundling setup from `InteropCenter`), unbundling or executing via that path will always revert if `ReentrancyGuard` is implemented in the standard way. In practice this can make some bundles impossible to unbundle/cancel or selectively execute, which can in turn prevent users from reclaiming funds associated with failed cross‑chain operations.

**Details**

1. **Default unbundler is on the *source* chain**

   In `InteropCenter`, if the caller does not explicitly set an `unbundlerAddress` attribute, it is defaulted to the *originating* chain:

   ```solidity
   // InteropCenter.sendMessage
   if (bundleAttributes.unbundlerAddress.length == 0) {
       bundleAttributes.unbundlerAddress = InteroperableAddress.formatEvmV1(block.chainid, msg.sender);
   }

   // InteropCenter.sendBundle
   if (bundleAttributes.unbundlerAddress.length == 0) {
       bundleAttributes.unbundlerAddress = InteroperableAddress.formatEvmV1(block.chainid, msg.sender);
   }
   ```

   On the **destination** chain, `InteropHandler.unbundleBundle` enforces:

   ```solidity
   (uint256 unbundlerChainId, address unbundlerAddress) = InteroperableAddress.parseEvmV1(
       interopBundle.bundleAttributes.unbundlerAddress
   );

   require(
       msg.sender == address(this) ||
           ((unbundlerChainId == block.chainid || unbundlerChainId == 0) && unbundlerAddress == msg.sender),
       UnbundlingNotAllowed(...)
   );
   ```

   With the default, `unbundlerChainId == sourceChainId`, so for a **cross‑L2** bundle (`destinationChainId != sourceChainId`) no EOA/contract on the destination chain satisfies this condition. The only allowed caller is `msg.sender == address(this)`, i.e. `InteropHandler` itself, via the ERC‑7786 rescue mechanism.

2. **Rescue mechanism is implemented via `receiveMessage`**

   The rescue entry point is:

   ```solidity
   function receiveMessage(
       bytes32 /* receiveId */,
       bytes calldata sender,
       bytes calldata payload
   ) external payable nonReentrant returns (bytes4) {
       // Verify that call to this function is a result of a call being executed
       require(msg.sender == address(this), Unauthorized(msg.sender));

       bytes4 selector = bytes4(payload[:4]);

       (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);

       if (selector == this.executeBundle.selector) {
           _handleExecuteBundle(payload, senderChainId, senderAddress, sender);
       } else if (selector == this.unbundleBundle.selector) {
           _handleUnbundleBundle(payload, senderChainId, senderAddress, sender);
       } else {
           revert InvalidSelector(selector);
       }

       return IERC7786Recipient.receiveMessage.selector;
   }
   ```

   `_handleUnbundleBundle` eventually calls:

   ```solidity
   this.unbundleBundle(sourceChainId, bundle, providedCallStatus);
   ```

3. **`executeBundle` / `unbundleBundle` also use `nonReentrant` and call into `receiveMessage`**

   Both top‑level entrypoints are guarded:

   ```solidity
   function executeBundle(...) public nonReentrant { ... }
   function verifyBundle(...) public nonReentrant { ... }
   function unbundleBundle(...) public nonReentrant { ... }
   ```

   They execute calls via `_executeCalls`:

   ```solidity
   function _executeCalls(...) internal {
       ...
       if (interopCall.value > 0) {
           L2_BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), interopCall.value);
       }
       bytes4 selector = IERC7786Recipient(interopCall.to).receiveMessage{value: interopCall.value}({
           receiveId: keccak256(abi.encodePacked(_bundleHash, i)),
           sender: InteroperableAddress.formatEvmV1(_sourceChainId, interopCall.from),
           payload: interopCall.data
       });
       require(selector == IERC7786Recipient.receiveMessage.selector, InvalidSelector(selector));
   }
   ```

   For the rescue case, the bundle is crafted so that one of the `InteropCall`s has `to == address(InteropHandler)`, so `_executeCalls` performs an external call to `InteropHandler.receiveMessage`.

4. **Standard `ReentrancyGuard` pattern will reject this nested call**

   `InteropHandler` inherits the project’s `ReentrancyGuard`:

   ```solidity
   contract InteropHandler is IInteropHandler, ReentrancyGuard {
       ...
   }
   ```

   If `ReentrancyGuard.nonReentrant` follows the standard pattern (single `_status` flag per contract set on entry and reset on exit), then the call graph:

   - `executeBundle` or `unbundleBundle` (`nonReentrant`)
     - `_executeCalls` (internal)
       - external call to `this.receiveMessage` (`nonReentrant`)

   will revert at the start of `receiveMessage` as a reentrant call.

   Because:

   - the default `unbundlerAddress` lives on the **source** chain, and
   - only `msg.sender == address(this)` can pass the permission check on the destination chain,

   this effectively means **there is no way to call `unbundleBundle` for default bundles** in a cross‑L2 scenario if `nonReentrant` behaves normally. The same reasoning applies to the `executeBundle` path via `receiveMessage`.

**Why this matters**

- Cancellation/unbundling is the documented way to recover from failed cross‑chain flows (e.g. cross‑chain swaps, fee‑payment bundles).
- For applications relying on the default unbundler behavior (most users), an inability to unbundle means:
  - they cannot selectively cancel/skip failing calls in a bundle,
  - they may not be able to trigger the “failed bundle” message that upstream components (bridges, asset routers) use to allow reclaiming locked funds.
- While this does not allow theft, it can lead to **permanent lock‑up of bridged assets** in failure scenarios.

**Recommendation**

- Confirm the actual implementation of `ReentrancyGuard` in `../common/ReentrancyGuard.sol`. If it is a standard, single‑flag guard (as is typical), then:
  - **Remove `nonReentrant` from `receiveMessage`**, relying instead on:
    - the strict `require(msg.sender == address(this))` check, and
    - the fact that only `executeBundle`/`unbundleBundle` call into `_executeCalls`.
  - Alternatively, refactor:
    - make `receiveMessage` a thin, *non‑guarded* external wrapper that immediately delegates to an internal function, and
    - call the internal function from `_executeCalls`.
- Consider also allowing an opt‑in default where `unbundlerAddress` is encoded with `chainId == 0` (wildcard) or the destination chain ID, to make direct destination‑chain unbundling possible without relying on the rescue path.


---

### 2. Recursion depth guard in `L2MessageVerification` is ineffective

- **Title**: `_depth` parameter in `_proveL2LeafInclusionRecursive` is not decremented, making `DepthMoreThanOneForRecursiveMerkleProof` unreachable
- **Severity**: Low  
- **Impact**: The intended safeguard against proofs that recurse through more settlement layers than supported (`DepthMoreThanOneForRecursiveMerkleProof`) is effectively non‑functional. As a result, a concatenated proof with more than the expected number of aggregation steps will not be rejected by this guard. Under current assumptions (only one settlement layer, all settlement layers trusted), this does not break security, but it weakens defense‑in‑depth and could hide misconfigurations if more layers are introduced.

**Details**

`L2MessageVerification` overrides an internal function from `MessageVerification`:

```solidity
function _proveL2LeafInclusionRecursive(
    uint256 _chainId,
    uint256 _blockOrBatchNumber,
    uint256 _leafProofMask,
    bytes32 _leaf,
    bytes32[] calldata _proof,
    uint256 _depth
) internal view override returns (bool) {
    ProofData memory proofData = MessageHashing._getProofData({ ... });

    if (proofData.finalProofNode) {
        bytes32 correctBatchRoot = L2_INTEROP_ROOT_STORAGE.interopRoots(_chainId, _blockOrBatchNumber);
        return correctBatchRoot == proofData.batchSettlementRoot && correctBatchRoot != bytes32(0);
    }
    if (_depth == 1) {
        revert DepthMoreThanOneForRecursiveMerkleProof();
    }

    return
        this.proveL2LeafInclusionShared({
            _chainId: proofData.settlementLayerChainId,
            _blockOrBatchNumber: proofData.settlementLayerBatchNumber,
            _leafProofMask: proofData.settlementLayerBatchRootMask,
            _leaf: proofData.chainIdLeaf,
            _proof: MessageHashing.extractSliceUntilEnd(_proof, proofData.ptr)
        });
}
```

Key observations:

- `_depth` is only checked against `1` and **never decremented**.
- The recursive step calls `this.proveL2LeafInclusionShared(...)`, i.e. the external wrapper, *not* `_proveL2LeafInclusionRecursive` directly. That wrapper in `MessageVerification` will again call `_proveL2LeafInclusionRecursive` with the **original max depth constant**, not `_depth - 1`.

Consequences:

- If the wrapper passes, say, `_depth = 2` on first entry (to allow one aggregation layer), then every recursive call also starts with `_depth = 2`; the `if (_depth == 1)` branch is never taken.
- A proof that encodes more than one level of settlement layer recursion will still be processed; depth is effectively unbounded at this guard.

Today, this is mitigated by:

- The project’s design and documentation explicitly assuming all settlement layers are trusted,
- Only a single settlement layer (Gateway or L1) being used in production.

So this is currently a correctness / maintainability issue rather than a live exploit vector.

**Recommendation**

- If the goal is to limit the number of recursive settlement‑layer hops:

  - Change the recursive call to use the internal function and decrement `_depth`:

    ```solidity
    return _proveL2LeafInclusionRecursive(
        proofData.settlementLayerChainId,
        proofData.settlementLayerBatchNumber,
        proofData.settlementLayerBatchRootMask,
        proofData.chainIdLeaf,
        MessageHashing.extractSliceUntilEnd(_proof, proofData.ptr),
        _depth - 1
    );
    ```

  - Or, have the external `proveL2LeafInclusionShared` accept a depth parameter and forward `_depth - 1`.

- If multiple layers are intentionally allowed and fully trusted, consider removing `_depth` and the `DepthMoreThanOneForRecursiveMerkleProof` error to avoid confusion, or document clearly that the guard is intentionally disabled.


---

## Open issues / missing context

The following aspects could not be fully validated with the provided snippets and would benefit from reviewing additional sources:

1. **`ReentrancyGuard` implementation**

   - File needed: `l1-contracts/contracts/common/ReentrancyGuard.sol`
   - Reason: To confirm that `nonReentrant` indeed behaves as a standard single‑flag guard (and thus that the `receiveMessage` nested call truly reverts). If `ReentrancyGuard` has special handling that allows nested calls from `address(this)`, the impact of Issue 1 would be reduced or eliminated.

2. **`MessageVerification` base contract details**

   - File needed: `l1-contracts/contracts/common/MessageVerification.sol`
   - Reason: To confirm how `proveL2LeafInclusionShared` sets the initial `_depth` value and whether there are any additional constraints on recursion depth that might mitigate Issue 2.

3. **`L2InteropRootStorage` / `L2_INTEROP_ROOT_STORAGE` invariants**

   - File(s) needed: implementation of `L2_INTEROP_ROOT_STORAGE` (likely `L2MessageRootStorage` or similar in `system-contracts`) and relevant bootloader logic.
   - Reason: To fully validate that `interopRoots(chainId, blockOrBatchNumber)` can only be updated in a way consistent with the settlement layer’s `MessageRoot` and that malicious bootloader behavior cannot inject arbitrary roots.

4. **GW asset tracking and base‑token accounting**

   - Files needed (not provided here): contracts behind `GW_ASSET_TRACKER`, `L2_BASE_TOKEN_SYSTEM_CONTRACT`, `L2_ASSET_ROUTER`, and the relevant Gateway/L1 bridge contracts.
   - Reason: While `_ensureCorrectTotalValue` and `_executeCalls` look consistent locally, full end‑to‑end conservation of base tokens across chains (especially when base tokens differ between source and destination) depends on these components’ behavior.