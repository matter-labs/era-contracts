# ZKsync Interop Protocol

This document is the single source of truth for the protocol-level behaviour of the interop contracts under `l1-contracts/contracts/interop/`. Doc comments in the contracts are intentionally brief and reference this file.

## Overview

Interop is ZKsync's mechanism for sending messages and value between chains in the ecosystem. The `InteropCenter` (an L2 contract) is the primary entry point for communication between chains connected to interop, facilitating interactions between end users and bridges. As of v31 the `InteropCenter` is only deployed on L2s, not on L1. Interop was **not activated in v31**; the contracts here target v32+ and are expected to run on ZKsync OS chains only (the EraVM bootloader does not support the timestamp-carrying interop-root import entry points).

The lifecycle of an interop interaction is:

1. **Send** — on the source L2, `InteropCenter.sendMessage` (single call) or `InteropCenter.sendBundle` (multiple calls) forms an `InteropBundle` and publishes it as an L2→L1 message (or, for atomic bundles, appends its commit value to the interop IMT instead).
2. **Root import** — the destination chain's bootloader imports interop roots from other chains into `L2InteropRootStorage`.
3. **Receive** — on the destination chain, anyone with the right permissions calls the interop handler (`L2InteropHandler` on L2, `L1InteropHandler` on L1) to `verifyBundle` / `executeBundle` / `unbundleBundle`, proving the bundle's message inclusion against the imported roots.

## Core data structures (`common/Messaging.sol`)

### `InteropBundle`

A set of `InteropCall`s sent to a single destination chain:

- `version` — `INTEROP_BUNDLE_VERSION` (`0x01`); checked on decode (`InvalidInteropBundleVersion`).
- `sourceChainId` / `destinationChainId` — origin and target EVM chain IDs.
- `destinationBaseTokenAssetId` — asset ID of the destination chain's base token. Committed into the bundle and re-checked on the destination, driving the same-vs-cross-base-token value handling.
- `interopBundleSalt` — see [Replay protection and bundle uniqueness](#replay-protection-and-bundle-uniqueness).
- `calls` — the `InteropCall` array.
- `bundleAttributes` — `BundleAttributes` (execution/unbundling permissions, fee mode, salt).

Messages are **always sent in bundles**, even when there is only one call (`sendMessage` wraps its single call into a bundle).

### `InteropCall`

A single call within a bundle:

- `version` — `INTEROP_CALL_VERSION` (`0x01`); checked per call at execution time (`InvalidInteropCallVersion`).
- `shadowAccount` — reserved, always `false`. ShadowAccount routing was removed; the slot is kept to preserve the on-wire `InteropBundle` encoding (bundle hash / event topics / pre-generated chain states) and may host a future feature.
- `to` / `from` — destination contract and original sender.
- `value` — base-token amount delivered with the call on the destination chain.
- `data` — calldata payload.

### Statuses

- `BundleStatus`: `Unreceived` → `Verified` → (`FullyExecuted` | `Unbundled`), but `Verified` is not a required stop: execution accepts `Unreceived` **or** `Verified` (`_requireExecutable`), so a bundle that proves inclusion inline goes straight `Unreceived` → `FullyExecuted`. `unbundleBundle` accepts `Verified` **or** `Unbundled`, so it may be called repeatedly — `Unbundled` is not terminal, and replay is prevented per call via `CallStatus`, not by capping the number of unbundle calls.
- `CallStatus` (per call, used by unbundling): `Unprocessed`, `Executed`, `Cancelled`.

### Identifiers and hashes

- Bundles are published to L1 prefixed with `BUNDLE_IDENTIFIER` (`0x01`).
- `bundleHash = keccak256(abi.encode(bundle))` (`InteropDataEncoding.encodeInteropBundleHash`, which hashes the encoded bundle bytes). It is chain-specific because `sourceChainId` is a field of `InteropBundle`, and unique for every bundle (guaranteed by the salt scheme).
- The ERC-7786 `sendId` / `receiveId` of call `i` is `keccak256(abi.encodePacked(bundleHash, i))`.

## ERC-7786 and ERC-7930 usage

- `InteropCenter` implements `IERC7786GatewaySource` (`sendMessage`, `supportsAttribute`, `MessageSent` event). One `MessageSent` event is emitted per call in a bundle, carrying the original (unparsed) attributes.
- Destination recipients implement `IERC7786Recipient.receiveMessage(receiveId, sender, payload)` and must return its selector. Attributes are not yet supported on the receive side.
- Addresses cross chains as **ERC-7930 interoperable addresses** (version 2 bytes + chainType 2 bytes + chainReferenceLength 1 byte + addressLength 1 byte = minimum length `ERC7930_V1_MIN_LENGTH = 0x06`), restricted to EVM/EIP-155 encodings (`InteroperableAddress.parseEvmV1`).
- Encoding conventions enforced at send time:
  - `sendBundle`'s `_destinationChainId` is an ERC-7930 address that MUST have an **empty address field** (it encodes only the chain).
  - Each `InteropCallStarter.to` MUST have an **empty ChainReference field** — the chain ID is always provided at the bundle level, so repeating it per call would be redundant.
  - A recipient that parses to `address(0)` (a chain-only encoding) is rejected in both entry points: such a call would collect value up-front yet never be executable and has no refund path.
- In permission checks (execution/unbundling), an ERC-7930 address whose chain ID is `0` acts as a **chain wildcard**: the address matches on any chain.

## Attributes

Attributes are ERC-7786 attribute byte strings (4-byte selector from `IERC7786Attributes` + ABI-encoded arguments, decoded by `AttributesDecoder`). `SUPPORTED_INTEROP_ATTRIBUTES = 7` selectors are supported. Each attribute may be passed at most once (`AttributeAlreadySet`); unknown selectors revert with `UnsupportedAttribute`. `InteropCenter.parseAttributes` enforces positional restrictions (`AttributeParsingRestrictions`): call-level attributes are only valid on calls, bundle-level attributes only on bundles; `sendMessage` accepts both kinds in its single attributes array.

### Call attributes (`CallAttributes`)

- `interopCallValue(uint256)` — base-token value **on the destination chain** delivered with the call.
- `indirectCall(uint256 indirectCallMessageValue)` — marks the call as indirect (see below); the argument is base-token value **on the source chain** forwarded to the indirect-call target. Default is a direct call.

### Bundle attributes (`BundleAttributes`)

- `executionAddress(bytes)` — ERC-7930 address allowed to execute the bundle on the destination. **Empty ⇒ execution is permissionless.**
- `unbundlerAddress(bytes)` — ERC-7930 address allowed to unbundle the bundle. Unlike `executionAddress`, it is always non-empty in the final bundle: if the sender does not set it, `InteropCenter` defaults it to `(block.chainid, msg.sender)` on the **source** chain, so unbundling stays possible (via the handler's `receiveMessage` rescue path, see below). The default deliberately pins the source chain rather than using the chain wildcard (chainId 0): a wildcard would let a same-address contract on another chain (e.g. a malicious clone) unbundle. Senders that want to unbundle directly on the destination can pass an explicit `unbundlerAddress`.
- `useFixedFee(bool)` — fee mode selector, defaults to `false`. See [Fee model](#fee-model).
- `interopBundleSalt(bytes32)` — user-provided salt; see [Replay protection](#replay-protection-and-bundle-uniqueness).
- `atomicBundle(AtomicFlowPreimage, uint256 lowNullifierIndex)` — marks the bundle as an atomic-interop leg; see [Atomic bundles](#atomic-bundles). Its payload is deliberately **not** stored in `BundleAttributes` (i.e. not part of the cross-chain bundle): the bundle hash must not depend on the flowId preimage, because the preimage's `legBundleHashes` include this very bundle's hash — a circular dependency. It is parsed separately (`InteropAttributeParser.parseAtomicSend`) into the send-side-only `AtomicSend` struct.

## Direct vs indirect calls

- **Direct call**: the call starter directly becomes the `InteropCall` — `to`/`data` are used as-is, `from` is the original sender.
- **Indirect call**: the call starter's target is first invoked on the **source** chain via `IL2CrossChainSender.initiateIndirectCall{value: indirectCallMessageValue}(destinationChainId, sender, interopCallValue, data)`, and the _returned_ call starter forms the `InteropCall` (with `from` set to the indirect-call target, e.g. the L2 `AssetRouter`). This is how interop token transfers work. The returned starter's `interopCallValue` must equal the requested one (`IndirectCallValueMismatch`). `interopCallValue` is always **zero** for an indirect call — `InteropCenter` rejects a non-zero one before the sender is ever invoked (`IndirectCallCannotCarryValue`, see [Restrictions](#restrictions)), so this is not a per-sender capability. For an indirect asset transfer the token amount rides in the `finalizeDeposit` burn/mint data, and `indirectCallMessageValue` is the separate **source-side** `msg.value` forwarded to the sender.

## Fee model

Every user of interop can choose between two fee options per bundle (via `useFixedFee`; all calls in a bundle share one mode). Fees are charged per call:

- **Dynamic base-token fee** (`useFixedFee = false`, default): `interopProtocolFee` (in the source chain's base token) per call, paid via `msg.value`. The fee value is fully operator-controlled — it is set by the bootloader as a system transaction (`setInteropFee`) and may be 0.
- **Fixed ZK fee** (`useFixedFee = true`): `ZK_INTEROP_FEE` in ZK tokens per call, pulled via ERC-20 `transferFrom`; no base-token fee is charged. This provides **Stage 1 protection**: users can pay fees independent of chain-operator settings, so interop keeps working even if the operator sets arbitrary dynamic fees. The default (`DEFAULT_ZK_INTEROP_FEE = 10 ZK`) is intentionally set sufficiently higher than the intended gateway settlement fee (and thus the intended dynamic fee) to incentivize users to use the dynamic path. `ZK_INTEROP_FEE` is not changeable at runtime; it is a storage variable (not a constant) only so a protocol upgrade can change the value without redeploying.
  - Requires the ZK token to already be bridged to the source chain (resolved from `ZK_TOKEN_ASSET_ID` via the NativeTokenVault and cached in `zkToken`); otherwise the send reverts with `ZKTokenNotAvailable`.
  - On chains where ZK is the base token, `useFixedFee = true` still requires wrapped ZK (ERC-20 transfer), while `useFixedFee = false` accepts native ZK via `msg.value`. This is intentional.
- **L2→L1 bundles are free**: they are withdrawals, not interop, so neither fee is charged.

Fees are **accumulated per `block.coinbase`** (`accumulatedProtocolFees` / `accumulatedZKFees`) rather than pushed, and later claimed by the coinbase via `claimProtocolFees` / `claimZKFees`. Accumulation (instead of direct transfer) prevents a malicious operator from failing sends by supplying a faulty coinbase, and avoids calls to untrusted contracts during a send.

## Send flow

Both entry points (`sendMessage` and `sendBundle`, both `whenNotPaused nonReentrant`) funnel through the internal `_sendBundle`, which:

1. **Validates destination** (see [Restrictions](#restrictions)) and, for atomic bundles, rejects L1 destinations before any burn.
2. **Enforces salt uniqueness** and marks the (sender, salt) pair used.
3. **Resolves `destinationBaseTokenAssetId`**: for an L2 destination, from the L2 `Bridgehub` registry (unregistered chains revert with `DestinationChainNotRegistered`); for an L1 destination, the L1-native ETH asset ID — the L1 chain is not registered as an interop destination in the L2 Bridgehub, and L1's base token is ETH (which is not necessarily this L2's base token; they only coincide on ETH-based chains).
4. **Processes each call starter** (direct or indirect, applying the L1-destination restrictions) and accumulates two totals: `totalBurnedCallsValue` (sum of destination-side `interopCallValue`s) and `totalIndirectCallsValue` (sum of source-side `indirectCallMessageValue`s).
5. **Collects fixed ZK fees**, if `useFixedFee` and the destination is not L1.
6. **Collects and burns value** (`_ensureCorrectTotalValue`): `msg.value` must exactly match the expected total (`MsgValueMismatch`), where the expected total is:
   - same base token on both chains: `totalBurnedCallsValue + totalIndirectCallsValue + protocolFee`; the interop-call value is burned on the source chain via `L2_BASE_TOKEN_HOLDER.burnAndStartBridging` (notifying the L2AssetTracker);
   - different base tokens: `totalIndirectCallsValue + protocolFee`; the destination-chain value is instead deposited via `AssetRouter.bridgehubDepositBaseToken`.
7. **Dispatches the bundle** (`_dispatchBundle`): a normal bundle is ABI-encoded, prefixed with `BUNDLE_IDENTIFIER`, and sent to L1 via the `L2ToL1Messenger`; an atomic bundle is instead appended to the interop IMT via the `AtomicFlowManager` and **not** published to L1.
8. **Emits events**: one ERC-7786 `MessageSent` per call, plus one `InteropBundleSent(l2l1MsgHash, bundleHash, bundle)`.

There is intentionally **no gateway-mode requirement** on the send side: interop bundles may be sent by chains settling directly on L1. Cross-layer correctness is enforced by the message-inclusion proof on the receiving side (or by per-leg IMT inclusion proofs for atomic bundles), not by inspecting the chain's configured gateway mode at send time. (An atomic send does check the flow's declared `settlementLayerChainId` against L1 — `ManagerSettlementLayerNotL1` — but that validates the flow's own parameter, not the sending chain's settlement configuration.)

## Restrictions

- **No interop initiation on L1**: bundles can only be initiated on an L2 (`CannotInitiateInteropOnL1`). The `InteropCenter` never runs on L1.
- **No interop to self** (`InteropToSelfNotSupported`): a chain can end up registered for interop on its own Bridgehub, and a self-destination bundle would burn value into an unsupported self-bridging accounting path.
- **`sendMessage` is strictly L2→L2** (`NotL2ToL2`); the L2→L1 path goes through `sendBundle` as a single-call bundle.
- **L1 destinations are restricted to single-call asset withdrawals** (for this release):
  - exactly one call (`MultiCallToL1NotSupported`);
  - the call must be **indirect** (`DirectCallToL1NotSupported`) and target the **L2 AssetRouter** (`InteropCallToL1NotToAssetRouter`) — `initiateIndirectCall` rewrites it into a call to the L1 AssetRouter's `finalizeDeposit`. This keeps the L1-side attack surface to the asset router only, rather than allowing arbitrary L2→L1 calls to any `IERC7786Recipient`;
  - the call must carry **zero `interopCallValue`** (`NonZeroValueToL1NotSupported`): the withdrawn amount rides in the transfer data / indirect-call message value, and a value-bearing call could end up in an unfinalizable bundle;
  - an L1-destined bundle must **not be atomic** (`AtomicBundleToL1NotSupported`).
- **Indirect calls may not carry `interopCallValue`** (`IndirectCallCannotCarryValue`): recovery returns native value to the call's `InteropCall.from`, which for an indirect call is the starter contract (the asset router for asset transfers) rather than the payer, so the value could never reach the original sender. Direct calls may carry value — on timeout it is refunded via `bridgehubRecoverBaseToken`. Everything else is allowed (an atomic bundle may mix recoverable fund calls, e.g. asset-router deposits, with fund-free calls); timeout recovery is best-effort and refund safety of fund-moving legs is the flow author's responsibility — in particular, only asset-router burns are reversed on timeout, see {protocol-docs/atomicity/security.md#known-issues-and-accepted-limitations}.
- **`atomicBundle` is required on every L2→L2 send, `sendMessage` included.** `sendMessage` parses the attribute like any other send and wraps its single call into a one-leg atomic flow; `_sendBundle` then rejects a non-atomic L2→L2 send outright (`NonAtomicSendUnsupported`). So omitting the attribute on `sendMessage` reverts — it is not "a single-call send is never atomic". Conversely an L2→L1 send must **not** carry it (`AtomicBundleToL1NotSupported`), which makes the rule a biconditional: atomic ⟺ L2→L2, non-atomic ⟺ L2→L1.

## Replay protection and bundle uniqueness

The bundle hash commits to `interopBundleSalt = keccak256(abi.encodePacked(msg.sender, userProvidedSalt))`, where the user salt comes from the `interopBundleSalt` bundle attribute. `InteropCenter.isInteropBundleSaltUsed` enforces that each (sender, salt) pair is used at most once (`InteropBundleSaltAlreadyUsed`), which makes **every emitted bundle hash unique** even for identical bundle contents. Mixing in `msg.sender` ensures bundles from different senders can never collide; the user-controlled part lets a sender control uniqueness of its own bundles. What the protocol requires is only that the salt be **fresh** for the sender — a counter is as valid as a random value. Nothing about the salt provides confidentiality: the send calldata carries the inputs and `InteropBundleSent` emits the fully resolved `InteropBundle`, so a bundle's contents are public regardless. (Atomic senders must in fact be able to predict their own `bundleHash` before sending, in order to build the flow preimage — see [Atomic bundles](#atomic-bundles).) Omitting the attribute (salt `bytes32(0)`) is allowed but discouraged — it works at most once per sender.

(Historical note: the salt used to be derived from a per-sender nonce; the deprecated `__DEPRECATED_interopBundleNonce` mapping slot is retained only to preserve the storage layout.)

On the destination, replay of a bundle is prevented by the `bundleStatus` state machine: execution/unbundling flips the status before any external call (CEI), so a bundle can be fully executed or unbundled only once.

## Interop roots and message verification

### Root import (`L2InteropRootStorage`)

`L2InteropRootStorage` stores the message roots of other chains on the L2, keyed by `(chainId, blockOrBatchNumber)`. Roots are imported **only by the bootloader** via `addSingleInteropRoot` / `addInteropRootsInBatch`, as full `(blockOrBatchNumber, root, timestamp)` tuples (`InteropRoot` → `StoredInteropRoot`):

- `blockOrBatchNumber` is a **block number** for proof-based interop and a **batch number** for commit-based interop, reflecting the implementation requirements of each finality form.
- `sides` currently must contain exactly one element — the root itself (`SidesLengthNotOne`). Once pre-commit interop is introduced, `sides` will include both the root and its associated tree sides.
- The imported tuple is double-checked on the settlement layer during batch execution (`ExecutorFacet._verifyDependencyInteropRoots`, against `MessageRoot.historicalRoot`), so time-sensitive proofs — e.g. the atomic-interop timeout protocol — can rely on the timestamp as much as on the root itself.
- Zero roots and zero timestamps are rejected on import, keeping the invariant structural: a zero stored timestamp only ever means "nothing imported at this key" (the atomic timeout path relies on this). A root for a given key can be set only once (`InteropRootAlreadyExists`).
- This logic is **not compatible with EraVM** (its bootloader does not support the timestamp-carrying import entry points); it is deployed on ZKsync OS chains only. No roots recorded under previous protocol versions exist, because interop was not activated in v31; the v31→v32 widening of the stored value from `bytes32` to a struct is storage-safe (the mapping was empty, and the struct's first member occupies the old slot).

### Message verification (`L2MessageVerification`)

`L2MessageVerification` proves L2→L1 message inclusion **on an L2**. It reuses the shared recursive proof-verification logic (`MessageVerification` / `MessageHashing`); the terminal (`finalProofNode`) step anchors the proof to the imported L1 aggregate interop root in `L2InteropRootStorage.interopRoots` — an L2 has no per-chain batch roots, unlike L1 where `MessageRootBase` terminates at its own `chainBatchRoots`. (In this release, L1 is the settlement layer of every chain.) Recursion depth is limited to one hop. The scheme assumes all settlement layers a chain has ever settled on are trustworthy — chains in the ecosystem trust that a message for a batch that never happened will not be accepted.

## Destination-side processing (interop handlers)

`InteropHandlerBase` contains the shared logic for executing, verifying and unbundling bundles. `L2InteropHandler` (an L2 system contract) and `L1InteropHandler` (behind a proxy on L1) supply environment-specific hooks:

| Hook                                   | L2 (`L2InteropHandler`)                                 | L1 (`L1InteropHandler`)                               |
| -------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------- |
| `_proveInclusion`                      | `L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared` | `MESSAGE_ROOT.proveL2MessageInclusionShared`          |
| `_handleCallValue`                     | pulls value from the `BaseTokenHolder` (`give`)         | requires zero value (`InteropWithdrawalNonZeroValue`) |
| `_expectedDestinationBaseTokenAssetId` | NTV `BASE_TOKEN_ASSET_ID`                               | L1 ETH asset ID                                       |
| `_ensureNotPaused`                     | no-op (L2 system contract is not pausable)              | pausable gate                                         |

### Verification (`verifyBundle`)

Proves that the message corresponding to the bundle was included on the source chain and marks the bundle `Verified`. The bundle is authenticated **solely** by message inclusion plus the message sender being the canonical `L2_INTEROP_CENTER_ADDR` (`UnauthorizedMessageSender`); asset correctness across chains is guaranteed by ZK proofs (assuming proofs are correct and chains are not malicious), so no on-chain per-chain balance reconciliation is performed. The provided proof's message data is substituted with `BUNDLE_IDENTIFIER || bundle` before verification. Verification is permissionless and intentionally not pausable — it only records inclusion and moves no assets.

Before verification/execution, `_validateBundleDestinationContext` checks that the bundle's `sourceChainId` matches the proof's chain ID, `destinationChainId == block.chainid`, and `destinationBaseTokenAssetId` matches this chain's expected base-token asset ID.

### Execution (`executeBundle`)

Executes **all** calls of a bundle atomically: if any call fails, the whole transaction reverts. Requires status `Unreceived` (verifying inline) or `Verified`; anything else reverts with `BundleAlreadyProcessed` — a whitelist approach, so any future status is explicitly rejected until explicitly allowed. If `executionAddress` is set, only that address (on this chain, or chain-agnostic via chainId 0) — or the handler itself, for the `receiveMessage` path — may execute; if empty, execution is permissionless. Following CEI, the bundle is marked `FullyExecuted` and every call `Executed` **before** any external call runs, so reentrancy hits the status check. Each call is delivered as `IERC7786Recipient.receiveMessage{value}` with the source-side base-token value handled by `_handleCallValue`, and must return the correct selector.

### Unbundling (`unbundleBundle`)

A more flexible processing/cancellation path: the caller provides a desired `CallStatus[]` (same length as the bundle's calls — a guard against unintended unbundling), and per call requests `Executed` (only if currently `Unprocessed`), `Cancelled` (only if not already `Executed`; idempotent if already cancelled), or skip. It can be invoked multiple times until all calls are processed. Only allowed from status `Verified` or `Unbundled` — the first unbundling requires prior verification, which validates bundle correctness; no destination-context re-validation is needed afterwards because every context input is immutable once verified (chain IDs are committed in the bundle hash; the chain's base-token asset ID is set-once). Permission mirrors execution but uses `unbundlerAddress` (which is always non-empty).

### `receiveMessage` rescue path

The handler itself implements `IERC7786Recipient.receiveMessage`, callable **only by itself** (i.e. only as a call inside an executing bundle). Its purpose is a rescue mechanism for the default-unbundler case: when the unbundler is a contract pinned to the source chain (the default), it cannot call `unbundleBundle` on the destination directly — instead it sends _another_ interop bundle whose call payload is `abi.encodeCall` of `executeBundle`, `verifyBundle`, or `unbundleBundle`. The handler validates the cross-chain sender against the bundle's `executionAddress`/`unbundlerAddress` (verify is permissionless) and then self-calls the target function, which skips its own permission check because `msg.sender == address(this)`. Legacy payload formats (selectors) must remain supported forever, otherwise previously sent messages would become unexecutable.

### L1 specifics (`L1InteropHandler`)

`L1InteropHandler` executes L2→L1 bundles through the same `executeBundle` interface, symmetric to L2. For this release such a bundle is exactly one asset withdrawal resolving to the L1 asset router's `finalizeDeposit`. It is pausable so withdrawals can be halted — the `whenNotPaused` gate that previously lived on `L1Nullifier.finalizeDeposit` now lives on the handler's call-executing entry points. The zero-value rule is enforced twice by design: at send time on L2 (`NonZeroValueToL1NotSupported`) and again on receive (`InteropWithdrawalNonZeroValue`), in case a malformed bundle ever reaches L1.

## Atomic bundles

An atomic bundle is a leg of an **atomic interop flow** (L2↔L2 only), marked with the `atomicBundle` attribute. The atomic protocol itself (IMT commitments, proofs, timeout) is described in {protocol-docs/atomicity/README.md}; this section covers the interop-side integration:

- **Send side**: instead of publishing to L1, `_dispatchBundle` appends the bundle's commit value to the interop IMT via `AtomicFlowManager.append` (source-side funds are still collected by the normal send machinery — `initiateIndirectCall` burns for _indirect_ asset-transfer calls, while a direct call's `interopCallValue` is collected by `_ensureCorrectTotalValue` through the `BaseTokenHolder` or the asset router; a fund-free direct call burns nothing). The `AtomicSend` metadata (`AtomicFlowPreimage` = preimage `version`, deadline, settlement-layer chain ID, leg bundle hashes, leg source chain IDs; plus `lowNullifierIndex` and `isAtomic`) travels out-of-band and never enters the bundle, keeping `bundleHash` independent of the preimage. The `AtomicFlowManager` recomputes `flowId = keccak256(abi.encode(preimage))` and requires the sent bundle's hash to be one of its legs with this chain as the declared source — so if the off-chain bundle-hash prediction (e.g. a `callStatic` preview) was wrong or went stale (e.g. an upgrade changed the bundle encoding), the whole send reverts and nothing is burned, instead of committing a leg under a `flowId` that could neither finalize nor be refunded.
- **Execution side**: `L2InteropHandler.executeAtomicBundle(bundle, AtomicFinalityProof)` mirrors `executeBundle`, but the L1-message inclusion proof is replaced by the **atomicity gate** `AtomicFlowManager.requireFlowFinalized`: proof that _every_ leg of the flow was committed in its source chain's IMT before the deadline, and that this bundle is one of the legs. Replay is prevented by marking `FullyExecuted` (CEI) before calls run. The source chain ID used for destination-context validation is the bundle's own field; the cross-chain binding comes from the IMT inclusion proofs.
- **Atomic verification**: `verifyAtomicBundle(bundle, AtomicFinalityProof)` runs the same atomicity gate without executing the calls, marking the bundle `Verified` and enabling the verify→unbundle flow. `executeAtomicBundle` therefore accepts a bundle that is already `Verified` and **skips** the gate in that case (it was checked at verify time) — the accepted statuses are `Unreceived` and `Verified`, not `Unreceived` alone. Note this is what makes an atomic bundle partially executable: once `Verified`, individual calls can be executed or `Cancelled` via [`unbundleBundle`](#unbundling-unbundlebundle), so the atomicity gate governs whether execution is _permitted_, not that every call runs (see {protocol-docs/atomicity/security.md#guarantees}).
- **Settlement layer**: the IMT proofs are authenticated against the imported interop root, so mechanically they carry no gateway-settlement requirement — but atomic interop is **L1-only in this release**: `AtomicFlowManager` rejects any flow whose `settlementLayerChainId` is not the L1 chain id (`ManagerSettlementLayerNotL1`) on send, finality and refund alike (see {protocol-docs/atomicity/security.md#trust-assumptions}).
- **Timeouts**: if a flow misses its deadline, recovery is best-effort via `AtomicFlowManager._recoverBundle` / `IAtomicRecoverable.recoverAtomicCall`. This is why _indirect_ calls may not carry `interopCallValue` (see [Restrictions](#restrictions)) — recovery returns value to `InteropCall.from`, the starter contract for an indirect call (the asset router for router-produced calls), never the payer; direct calls may carry value and are refunded through `bridgehubRecoverBaseToken`. L1 destinations are banned because L1 has no atomic execution, so the only outcome would be a timeout refund, but L2→L1 withdrawal accounting (`totalWithdrawalsToL1`, consumed once during the L1→GW migration) must stay append-only and never revertable.

## Initialization and versioning notes

- `InteropCenter.initL2` is a one-shot initializer called by the complex upgrader. Because the `InteropCenter` is introduced in v31, it runs for both new chains (genesis) and chains upgraded to v31; in both cases storage is fresh (the SystemProxy is freshly deployed). After v31 it must never be called again (`reentrancyGuardInitializer` + `_disableInitializers` guards). It sets `L1_CHAIN_ID`, the owner, `ZK_TOKEN_ASSET_ID` (must be non-zero; anyone updating it later must also update the cached `zkToken` address) and the default `ZK_INTEROP_FEE`.
- `L2InteropHandler.initL2` only locks the reentrancy guard (the handler holds no configurable state); `L1InteropHandler` is initialized behind its proxy with an owner for pause control, and its implementation is locked in the constructor.
- `L1_CHAIN_ID` always refers to the base-most L1, on whichever layer the contract is deployed.
- `InteropCenter.forwardTransactionOnGateway` is a Gateway-relay function (callable only by `SETTLEMENT_LAYER_RELAY_SENDER`) forwarding an L1-originated transaction to a chain's mailbox; `_canonicalTxHash` is chain-provided and must not be trusted to be unique, while the other fields are populated by the Gateway's `Mailbox`. Its `_expirationTimestamp` parameter is deprecated (always 0).
- Deprecated storage slots retained for layout compatibility: `InteropCenter.__DEPRECATED_interopBundleNonce`, `InteropHandlerBase.__DEPRECATED_L1_CHAIN_ID` (the handler now operates on `block.chainid`).
- `InteropCenter` is pausable by its owner (`pause`/`unpause` gate both send entry points).
