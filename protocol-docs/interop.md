# ZKsync Interop Protocol

This document is the single source of truth for the protocol-level behaviour of the interop contracts under `l1-contracts/contracts/interop/`. Doc comments in the contracts are intentionally brief and reference this file.

## Overview

Interop is ZKsync's mechanism for sending messages and value between chains in the ecosystem. The `InteropCenter` (an L2 contract) is the primary entry point for communication between chains connected to interop, facilitating interactions between end users and bridges. As of v31 the `InteropCenter` is only deployed on L2s, not on L1. Interop was **not activated in v31**; the contracts here target v33+ and are expected to run on ZKsync OS chains only (the EraVM bootloader does not support the timestamp-carrying interop-root import entry points).

From v37 an L1 sends bundles too, through its own contract, the `L1InteropCenter`. Those bundles, and the
L2 -> L1 withdrawals, are **one-way bundles**: a single asset transfer proven by message inclusion, with no
atomic flow. They are described in [One-way bundles](#one-way-bundles); the rest of this document is about
the L2 `InteropCenter` unless it says otherwise.

The lifecycle of an interop interaction is:

1. **Prepare** — for L2 -> L2, preview every leg's bundle hash and construct the shared atomic-flow
   preimage. L2 -> L1 withdrawals need no atomic preimage.
2. **Send** — `sendMessage` (one call) or `sendBundle` (one or more calls) forms an `InteropBundle`,
   funds it, and either appends an atomic commit value or publishes the withdrawal to L1.
3. **Settle and import** — chain batch roots enter the settlement-layer `MessageRoot`; L2 bootloaders
   import dependency roots into `L2InteropRootStorage`, and batch execution double-checks them.
4. **Receive** — the destination handler verifies atomic IMT finality on L2 or message inclusion on L1,
   then executes the full bundle or marks it `Verified` for unbundling.

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
- `unbundlerAddress(bytes)` — ERC-7930 address allowed to unbundle the bundle. Unlike `executionAddress`, it is always non-empty in the final bundle: if the sender does not set it, `InteropCenter` defaults it to `(block.chainid, msg.sender)` on the **source** chain. On L2 -> L2 this can be exercised through the handler's `receiveMessage` rescue path (see below). The default deliberately pins the source chain rather than using the chain wildcard (chainId 0): a wildcard would let a same-address contract on another chain (e.g. a malicious clone) unbundle. The default is not reachable for an L2 -> L1 withdrawal because arbitrary L2 -> L1 rescue messages are unsupported; a sender that needs L1 unbundling must provide an explicit L1 or wildcard address. See {protocol-docs/atomicity/security.md#known-issues-and-accepted-limitations}.
- `useFixedFee(bool)` — fee mode selector, defaults to `false`. See [Fee model](#fee-model).
- `interopBundleSalt(bytes32)` — user-provided salt; see [Replay protection](#replay-protection-and-bundle-uniqueness).
- `atomicBundle(AtomicFlowPreimage, uint256 lowNullifierIndex)` — marks the bundle as an atomic-interop leg; see [Atomic bundles](#atomic-bundles). Its payload is deliberately **not** stored in `BundleAttributes` (i.e. not part of the cross-chain bundle): the bundle hash must not depend on the flowId preimage, because the preimage's `legBundleHashes` include this very bundle's hash — a circular dependency. It is parsed separately (`InteropAttributeParser.parseAtomicSend`) into the send-side-only `AtomicSend` struct.

## Direct vs indirect calls

- **Direct call**: the call starter directly becomes the `InteropCall` — `to`/`data` are used as-is, `from` is the original sender.
- **Indirect call**: the call starter's target is first invoked on the **source** chain via `IL2CrossChainSender.initiateIndirectCall{value: indirectCallMessageValue}(destinationChainId, sender, interopCallValue, data)`, and the _returned_ call starter forms the `InteropCall` (with `from` set to the indirect-call target — the L2 `AssetRouter`, the only allowed target for this release: `IndirectCallOnlyToAssetRouter`, see [Restrictions](#restrictions)). This is how interop token transfers work. The returned starter's `interopCallValue` must equal the requested one (`IndirectCallValueMismatch`). `interopCallValue` is always **zero** for an indirect call — `InteropCenter` rejects a non-zero one before the sender is ever invoked (`IndirectCallCannotCarryValue`, see [Restrictions](#restrictions)), so this is not a per-sender capability. For an indirect asset transfer the token amount rides in the `finalizeDeposit` burn/mint data, and `indirectCallMessageValue` is the separate **source-side** `msg.value` forwarded to the sender.

## Fee model

Every user of interop can choose between two fee options per bundle (via `useFixedFee`; all calls in a bundle share one mode). Fees are charged per call:

- **Dynamic base-token fee** (`useFixedFee = false`, default): `interopProtocolFee` (in the source chain's base token) per call, paid via `msg.value`. The fee value is fully operator-controlled — it is set by the bootloader as a system transaction (`setInteropFee`) and may be 0.
- **Fixed ZK fee** (`useFixedFee = true`): `ZK_INTEROP_FEE` in ZK tokens per call, pulled via ERC-20 `transferFrom`; no base-token fee is charged. This provides **Stage 1 protection**: users can pay fees independent of chain-operator settings, so interop keeps working even if the operator sets arbitrary dynamic fees. The default (`DEFAULT_ZK_INTEROP_FEE = 10 ZK`) is intentionally higher than the intended dynamic fee to incentivize users to use the dynamic path. `ZK_INTEROP_FEE` is not changeable at runtime; it is a storage variable (not a constant) only so a protocol upgrade can change the value without redeploying.
  - Requires the ZK token to already be bridged to the source chain (resolved from `ZK_TOKEN_ASSET_ID` via the NativeTokenVault and cached in `zkToken`); otherwise the send reverts with `ZKTokenNotAvailable`.
  - On chains where ZK is the base token, the NativeTokenVault maps the ZK asset to the base token system contract, which is not an ERC-20. There the fee token is the chain's wrapped base token (`L2NativeTokenVault.WETH_TOKEN`), so `useFixedFee = true` pulls wrapped ZK, while `useFixedFee = false` accepts native ZK via `msg.value`. This is intentional.
- **L2→L1 bundles are free**: they are withdrawals, not interop, so neither fee is charged.

Fees are **accumulated per `block.coinbase`** (`accumulatedProtocolFees` / `accumulatedZKFees`) rather than pushed, and later claimed by the coinbase via `claimProtocolFees` / `claimZKFees`. Accumulation (instead of direct transfer) prevents a malicious operator from failing sends by supplying a faulty coinbase, and avoids calls to untrusted contracts during a send.

Separately from these user fees, every call of an L2→L2 bundle counts as one interop fee unit, which governance can charge the chain operator for on L1 when the batch executes. See {protocol-docs/interop-fee.md}.

## Send flow

Both entry points (`sendMessage` and `sendBundle`, both `nonReentrant`) funnel through the internal `_sendBundle`, which:

1. **Validates destination** (see [Restrictions](#restrictions)) and, for atomic bundles, rejects L1 destinations before any burn.
2. **Enforces salt uniqueness** and marks the (sender, salt) pair used.
3. **Resolves `destinationBaseTokenAssetId`**: for an L2 destination, from the L2 `Bridgehub` registry (unregistered chains revert with `DestinationChainNotRegistered`, chains this chain's admin hasn't whitelisted with `DestinationChainNotAllowed`, see {protocol-docs/interop-gating.md#interop-peer-whitelist}); for a one-way destination (L1, or a chain with [interop counterparts](#counterpart-addressing)), the destination's native ETH asset ID — such a chain is not registered as an interop destination in the L2 Bridgehub, and its base token is ETH (which is not necessarily this L2's base token; they only coincide on ETH-based chains).
4. **Processes each call starter** (direct or indirect, applying the one-way restrictions) and accumulates two totals: `totalBurnedCallsValue` (sum of destination-side `interopCallValue`s) and `totalIndirectCallsValue` (sum of source-side `indirectCallMessageValue`s).
5. **Collects fixed ZK fees**, if `useFixedFee` and the bundle is not one-way.
6. **Collects and burns value** (`_ensureCorrectTotalValue`): `msg.value` must exactly match the expected total (`MsgValueMismatch`), where the expected total is:
   - same base token on both chains: `totalBurnedCallsValue + totalIndirectCallsValue + protocolFee`; the interop-call value is burned on the source chain via `L2_BASE_TOKEN_HOLDER.burnAndStartBridging` (notifying the L2AssetTracker);
   - different base tokens: `totalIndirectCallsValue + protocolFee`; the destination-chain value is instead deposited via `AssetRouter.bridgehubDepositBaseToken`.
7. **Dispatches the bundle** (`_dispatchBundle`): a one-way bundle (canonically an L2 -> L1 withdrawal) is
   ABI-encoded, prefixed with `BUNDLE_IDENTIFIER`, and sent through the `L2ToL1Messenger`; an atomic
   L2 -> L2 bundle is appended to the interop IMT via `AtomicFlowManager` and is **not** published as an
   L2 -> L1 message.
8. **Emits events**: one ERC-7786 `MessageSent` per call, plus one `InteropBundleSent(l2l1MsgHash, bundleHash, bundle)`.

There is intentionally **no settlement-mode requirement** on the send side. Route correctness is enforced
by the destination proof rather than by inspecting the sending chain's settlement configuration. An
atomic send does require the flow's declared `settlementLayerChainId` to equal L1
(`ManagerSettlementLayerNotL1`); that validates the flow parameter, not the sender's current settlement
configuration.

## Restrictions

- **No interop initiation on L1 through the `InteropCenter`**: it never runs on L1 (`CannotInitiateInteropOnL1`). An L1 sends through the `L1InteropCenter`, with the restrictions of [one-way bundles from an L1](#one-way-bundles-from-an-l1).
- **No interop to self** (`InteropToSelfNotSupported`): a chain can end up registered for interop on its own Bridgehub, and a self-destination bundle would burn value into an unsupported self-bridging accounting path.
- **`sendMessage` is strictly L2→L2** (`NotL2ToL2`); the L2→L1 path goes through `sendBundle` as a single-call bundle.
- **One-way destinations are restricted to single-call asset withdrawals** (for this release). A one-way destination is L1 or a chain this chain has [interop counterparts](#counterpart-addressing) for; the error names say L1 for both:
  - exactly one call (`MultiCallToL1NotSupported`);
  - the call must be **indirect** (`DirectCallToL1NotSupported`) and target the **L2 AssetRouter** (`InteropCallToL1NotToAssetRouter`) — `initiateIndirectCall` rewrites it into a call to the destination AssetRouter's `finalizeDeposit` (the L1 AssetRouter, or the counterparts' asset router). This keeps the L1-side attack surface to the asset router only, rather than allowing arbitrary L2→L1 calls to any `IERC7786Recipient`;
  - the call must carry **zero `interopCallValue`** (`NonZeroValueToL1NotSupported`): the withdrawn amount rides in the transfer data / indirect-call message value, and a value-bearing call could end up in an unfinalizable bundle;
  - an L1-destined bundle must **not be atomic** (`AtomicBundleToL1NotSupported`).
- **Indirect calls must target the L2 AssetRouter** (`IndirectCallOnlyToAssetRouter`) for this release: the atomic timeout-recovery hook (`recoverAtomicCall`) is dispatched to the asset router only, so pinning the starter guarantees every indirect burn is reachable by recovery. (For L1 destinations this is additionally enforced by the more specific `InteropCallToL1NotToAssetRouter` above.) Lifting the restriction requires first making `AtomicFlowManager._recoverBundle`'s dispatch generic (an indirect-call marker in the bundle encoding, or a registry of recoverable senders) — the manager silently skips any non-router `from`, so a second starter without a manager change would strand its burns.
- **Indirect calls may not carry `interopCallValue`** (`IndirectCallCannotCarryValue`): recovery returns native value to the call's `InteropCall.from`, which for an indirect call is the asset router rather than the payer, so the value could never reach the original sender. Direct calls may carry value — on timeout it is refunded via `bridgehubRecoverBaseToken`. Everything else is allowed (an atomic bundle may mix recoverable fund calls, e.g. asset-router deposits, with fund-free calls); timeout recovery is best-effort and refund safety of fund-moving legs is the flow author's responsibility.
- **`atomicBundle` is required on every L2→L2 send, `sendMessage` included.** `sendMessage` parses the attribute like any other send and wraps its single call into a one-leg atomic flow; `_sendBundle` then rejects a non-atomic L2→L2 send outright (`NonAtomicSendUnsupported`). So omitting the attribute on `sendMessage` reverts — it is not "a single-call send is never atomic". Conversely an L2→L1 send must **not** carry it (`AtomicBundleToL1NotSupported`), which makes the rule a biconditional: atomic ⟺ L2→L2, non-atomic ⟺ one-way. A chain with interop counterparts is never an allowed peer, so an atomic bundle to it reverts with `DestinationChainNotRegistered`, and `sendMessage` refuses a non-atomic send before looking at the destination.

## Replay protection and bundle uniqueness

The bundle hash commits to `interopBundleSalt = keccak256(abi.encodePacked(msg.sender, userProvidedSalt))`, where the user salt comes from the `interopBundleSalt` bundle attribute. `InteropCenter.isInteropBundleSaltUsed` enforces that each (sender, salt) pair is used at most once (`InteropBundleSaltAlreadyUsed`), which makes **every emitted bundle hash unique** even for identical bundle contents. Mixing in `msg.sender` ensures bundles from different senders can never collide; the user-controlled part lets a sender control uniqueness of its own bundles. What the protocol requires is only that the salt be **fresh** for the sender — a counter is as valid as a random value. Nothing about the salt provides confidentiality: the send calldata carries the inputs and `InteropBundleSent` emits the fully resolved `InteropBundle`, so a bundle's contents are public regardless. (Atomic senders must in fact be able to predict their own `bundleHash` before sending, in order to build the flow preimage — see [Atomic bundles](#atomic-bundles).) Omitting the attribute (salt `bytes32(0)`) is allowed but discouraged — it works at most once per sender.

(Historical note: the salt used to be derived from a per-sender nonce; the deprecated `__DEPRECATED_interopBundleNonce` mapping slot is retained only to preserve the storage layout.)

On the destination, replay is prevented by the bundle/call status machines. Full execution marks the
bundle and every call before external interaction and cannot be repeated. Unbundling may be invoked
more than once, but each call can transition out of `Unprocessed` only once; an `Executed` call can
never be cancelled or executed again.

## Bundle-hash preview

Atomic flow construction needs every leg's `bundleHash` before any real send, but the flow preimage
itself contains those hashes. `previewMessageHash` and `previewBundleHash` solve that dependency by
running the same bundle assembly as the corresponding send, including indirect-call processing, and
then **always reverting** with `InteropPreviewHash(bundleHash)`. They must be invoked through a static
`eth_call` / `callStatic`; the revert rolls back every intermediate state change and burn.

The preview accepts the send inputs without requiring `msg.value`, does not consume the sender's salt,
and stops before atomic append. The real send must use the same caller and every bundle-affecting input
(recipient/call starters, payload, salt, permissions, fee mode, and values), adding the `atomicBundle`
metadata derived from all previewed hashes. `AtomicFlowManager.append` recomputes the flow and requires
the actual bundle hash to be one of its correctly sourced legs, so a stale or inaccurate preview makes
the entire send revert, including its burns.

## Interop roots and message verification

### Root import (`L2InteropRootStorage`)

`L2InteropRootStorage` stores the message roots of other chains on the L2, keyed by `(chainId, blockOrBatchNumber)`. The roots of the settlement layer are imported **only by the bootloader** via `addSingleInteropRoot` / `addInteropRootsInBatch`, as full `(blockOrBatchNumber, root, timestamp)` tuples (`InteropRoot` → `StoredInteropRoot`); the roots of chains outside the ecosystem can be written by [interop root writers](#interop-root-writers):

- `blockOrBatchNumber` is the settlement layer's **block number**.
- `sides` currently must contain exactly one element — the root itself (`SidesLengthNotOne`). The array
  shape is reserved for possible future proof forms; pre-commit/parallel-building interop is not
  supported by this release.
- The imported tuple is double-checked on the settlement layer during batch execution (`ExecutorFacet._verifyDependencyInteropRoots`, against `MessageRoot.historicalRoot`), so time-sensitive proofs — e.g. the atomic-interop timeout protocol — can rely on the timestamp as much as on the root itself.
- Zero roots and zero timestamps are rejected on import, keeping the invariant structural: a zero stored timestamp only ever means "nothing imported at this key" (the atomic timeout path relies on this). A root for a given key can be set only once (`InteropRootAlreadyExists`).
- This logic is **not compatible with EraVM** (its bootloader does not support the timestamp-carrying import entry points); it is deployed on ZKsync OS chains only. No roots recorded under previous protocol versions exist, because interop was not activated in v31; the v31→v33 widening of the stored value from `bytes32` to a struct is storage-safe (the mapping was empty, and the struct's first member occupies the old slot).

### Interop root writers

From protocol version v0.36.0, a chain can also hold the roots of a source chain outside the ecosystem, written by an
address registered for that source chain: its **interop root writer**, for example an operator key or a light client
of the source chain that the chain's admin trusts. The writer can be any address; the protocol checks only who calls.

- `L2InteropRootStorage.addInteropRootFromWriter(InteropRoot)` adds a root of `interopRoot.chainId`. Only
  `interopRootWriter(chainId)` may call it, and only while the chain feature `INTEROP_ROOT_WRITERS_FEATURE`
  ({protocol-docs/interop-gating.md#chain-features}) is enabled in the chain's `L2Bridgehub`, so disabling the feature
  stops every writer at once. The root is stored under the same invariants as a bootloader import: `sides` holds
  exactly the root, the root and the timestamp are non-zero, a key is written once, and `latestInteropRootTimestamp`
  never decreases. `interopRoots` and `latestInteropRootTimestamp` read both kinds of root the same way. Atomic
  interop reads only the settlement layer's roots, under its chain id, for which no writer can be set.
- Writes emit `InteropRootAddedByWriter`, not `InteropRootAdded`. ZKsync OS folds every `InteropRootAdded` of
  `L2InteropRootStorage` (its interop-root event hook) into the batch's `dependencyRootsRollingHash`, and the
  settlement layer re-derives that hash only from its own message root
  ({protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}), so a written root would
  make the batch unexecutable (`CommitBasedInteropNotSupported`). A written root is therefore **not** checked by the
  settlement layer: it is exactly as trustworthy as the writer.
- A written root vouches only for its source chain's own messages. `L2MessageVerification` lets a proof name its
  chain's settlement layer, and trusts every settlement layer's roots for any chain settling there; it refuses a
  writer's source chain as the settlement layer of another chain (`SettlementLayerIsWriterSource`). Otherwise the
  writer, or whoever controls the source chain's roots, could prove messages of any ZK chain to this chain.
  `isWriterSource(chainId)` records that a writer was ever set for `chainId`, and stays true after the writer is
  removed, as its roots do.
- `setInteropRootWriter(sourceChainId, writer)` sets or (zero) removes a writer. It accepts only a service
  transaction, which `ChainRegistrationSender.setInteropRootWriter(chainId, sourceChainId, writer)` sends on L1, the
  same route as the peer whitelist and the chain features ({protocol-docs/interop-gating.md}):
  - the chain must run v0.36.0 or later (`INTEROP_ROOT_WRITERS_MIN_PROTOCOL_VERSION`, `InteropRootWritersNotSupported`
    otherwise), the first version whose `L2InteropRootStorage` has the writers. The chain's L2 runs its upgrade
    transaction before any later service transaction, so a chain that reports the version already has the setter;
  - setting a writer is up to the chain's admin, as the trust it adds is the chain's own, once the ecosystem enabled
    `INTEROP_ROOT_WRITERS_FEATURE` for the chain (`InteropRootWritersNotEnabled`);
  - removing one is also open to the owner and the Bridgehub admin;
  - a source chain belongs to one chain, which the ecosystem picks: the owner or the Bridgehub admin assigns it
    (`assignInteropRootSource(sourceChainId, chainId)`, recorded in `interopRootSourceChain`), and a writer (or
    [interop counterparts](#counterpart-addressing)) can be set only for a source assigned to the chain
    (`InteropRootSourceNotAssigned`). Asset ids are derived from the origin chain's id
    ({protocol-docs/bridging.md#asset-ids-asset-handlers-deployment-trackers}), so a second chain with its own
    writer for the same source id could mint, with a root of its own, the bridged tokens the first chain backs
    with real deposits, and move them to the first chain by an atomic flow. A chain admin does not pick its own
    sources, since first-come claims would let a chain take the id of another chain's source;
  - only a chain outside the ecosystem is assigned: not L1 and not a registered ZK chain
    (`InvalidInteropRootSource`), as their roots reach the chain through its settlement layer, and the bootloader
    and a writer never share a key space. The L2 rejects the chain itself as well. In turn the Bridgehub registers
    no chain under an assigned id (`ChainIdIsInteropRootSource`), so a source never becomes a ZK chain;
  - the first writer or counterparts the chain sets for a source make the assignment permanent
    (`isInteropRootSourceUsed`): whatever the chain minted from the source's roots stays on it, so the source can't
    move to another chain. Before that, the owner or the Bridgehub admin can undo a mistaken assignment
    (`releaseInteropRootSource`, `InteropRootSourceInUse` once used);
- Each setting or removal of a writer starts a new generation of the source's roots
  (`interopRootWriterGeneration`), and a written root records the generation it was written in.
  `isCurrentWriterRoot(chainId, blockNumber)` tells whether a root was written since the writer last changed;
  [one-way bundles](#executing-a-one-way-bundle-on-an-l2) count only such roots, so replacing a compromised writer
  drops what it wrote. A root can't be written twice for the same block, so the new writer vouches for the
  source's later roots; the source's message root is cumulative, and a later root proves the earlier messages too.
- The writer mapping and `isWriterSource` are appended to `L2InteropRootStorage`'s storage (slots 2 and 3, after
  `storedInteropRoots` and `latestInteropRootTimestamp`), so the built-in upgrades in place; both start empty. The
  generations follow them in v37; a root written before has generation zero, the first one.

### Message verification (`L2MessageVerification`)

`L2MessageVerification` proves generic L2 -> L1 message inclusion **on an L2**. It reuses the shared
recursive proof logic (`MessageVerification` / `MessageHashing`); the terminal step anchors the proof
to an imported L1 aggregate root in `L2InteropRootStorage`. Recursion depth is limited to one hop.
A proof may name any settlement layer whose roots the chain holds; the roots of a writer's source chain
serve only that chain's own messages ([interop root writers](#interop-root-writers)).
`L2InteropHandler` uses this path for [one-way bundles](#executing-a-one-way-bundle-on-an-l2) only: all
supported L2 -> L2 interop is atomic and authenticates each leg through `AtomicFlowManager` instead. L1
withdrawals use `L1InteropHandler` and the L1 `MessageRoot` directly.

## Destination-side processing (interop handlers)

`InteropHandlerBase` owns the proof-independent behavior: bundle decoding, destination-context checks,
execution/unbundling permissions, status transitions, call dispatch, and the `receiveMessage` rescue
path. The derived handlers authenticate a fresh bundle differently:

| Concern                                | L2 (`L2InteropHandler`)                           | L1 (`L1InteropHandler`)                               |
| -------------------------------------- | ------------------------------------------------- | ----------------------------------------------------- |
| supported route                        | atomic L2 -> L2                                   | L2 -> L1 withdrawal                                   |
| proof entry points                     | `executeAtomicBundle` / `verifyAtomicBundle`      | `executeBundle` / `verifyBundle`                      |
| proof                                  | `AtomicFinalityProof` through `AtomicFlowManager` | `MessageInclusionProof` through `MessageRoot`         |
| `_handleCallValue`                     | pulls value from the `BaseTokenHolder` (`give`)   | requires zero value (`InteropWithdrawalNonZeroValue`) |
| `_expectedDestinationBaseTokenAssetId` | NTV `BASE_TOKEN_ASSET_ID`                         | L1 ETH asset ID                                       |
| execution pause                        | none                                              | owner-controlled pausable gate                        |
| call target                            | bundle-selected ERC-7786 recipient                | canonical L1 asset router only                        |

`L2InteropHandler` has one more entry point, `executeBundle`, for the one-way bundles of the chains it has
interop counterparts for. It has its own rules, described in
[Executing a one-way bundle on an L2](#executing-a-one-way-bundle-on-an-l2), and shares only the status
machine and the call dispatch with the rows above.

Before verification or execution, `_validateBundleDestinationContext` checks
`destinationChainId == block.chainid` and the expected destination base-token asset ID. On L1 it also
binds `sourceChainId` to the proof's chain ID. On L2, source-chain authenticity comes from the atomic
proof's source-bound IMT paths; passing the bundle's own source ID into the common context check is
only a self-consistency step.

### Verification

Verification proves a bundle without executing it, changes `Unreceived` to `Verified`, and enables
unbundling. It is permissionless and does not move assets.

- `L2InteropHandler.verifyAtomicBundle` calls `AtomicFlowManager.requireFlowFinalized`, proving every
  leg of the flow committed in its declared source-chain tree before the deadline.
- `L1InteropHandler.verifyBundle` substitutes `BUNDLE_IDENTIFIER || bundle` into the supplied message,
  requires its sender to be `L2_INTEROP_CENTER_ADDR`, and proves inclusion through `MessageRoot`.

### Execution

`executeAtomicBundle` on L2 and `executeBundle` on L1 execute **all** calls atomically: if any call
fails, the transaction reverts. They accept `Unreceived` (prove inline) or `Verified` (reuse the prior
proof); any other status reverts with `BundleAlreadyProcessed`. If `executionAddress` is set, only that
address on this chain (or a chain-wildcard address), or the handler itself on the rescue path, may
execute. Empty means permissionless.

Following CEI, the handler marks the bundle `FullyExecuted` and every call `Executed` before any
external call. It delivers each call through `IERC7786Recipient.receiveMessage{value}` and requires the
correct selector. L2 obtains call value from `BaseTokenHolder`; L1 rejects non-zero call value.

### Unbundling (`unbundleBundle`)

A more flexible processing/cancellation path: the caller provides a desired `CallStatus[]` (same length as the bundle's calls — a guard against unintended unbundling), and per call requests `Executed` (only if currently `Unprocessed`), `Cancelled` (only if not already `Executed`; idempotent if already cancelled), or skip. It can be invoked multiple times until all calls are processed. Only allowed from status `Verified` or `Unbundled` — the first unbundling requires prior verification, which validates bundle correctness; no destination-context re-validation is needed afterwards because every context input is immutable once verified (chain IDs are committed in the bundle hash; the chain's base-token asset ID is set-once). Permission mirrors execution but uses `unbundlerAddress` (which is always non-empty).

### `receiveMessage` rescue path

The handler itself implements `IERC7786Recipient.receiveMessage`, callable **only by itself** (i.e. only as a call inside an executing bundle). Its purpose is a rescue mechanism for a contract executor/unbundler pinned to another chain: on the supported L2 -> L2 path it sends another atomic bundle whose call payload is `abi.encodeCall` of `executeAtomicBundle`, `verifyAtomicBundle`, or `unbundleBundle`. The handler validates the cross-chain sender against the bundle's `executionAddress`/`unbundlerAddress` (verification is permissionless) and then self-calls the target function, which skips its own permission check because `msg.sender == address(this)`. The L1 handler retains analogous selector dispatch for compatibility, but the current send restrictions provide no general L2 -> L1 rescue-message path. Previously supported selectors must remain stable so in-flight messages do not become unexecutable.

### L1 specifics (`L1InteropHandler`)

`L1InteropHandler` accepts exactly one asset-withdrawal call resolving to the canonical L1 asset
router's `finalizeDeposit`. The router target is pinned again during execution, even though the source
send path already enforces it. The handler is pausable so withdrawals can be halted; verification
remains available while paused because it only records a proof. The zero-value rule is likewise
enforced both at send (`NonZeroValueToL1NotSupported`) and receive
(`InteropWithdrawalNonZeroValue`).

## Atomic bundles

An atomic bundle is a leg of an **atomic interop flow** (L2↔L2 only), marked with the `atomicBundle` attribute. The atomic protocol itself (IMT commitments, proofs, timeout) is described in {protocol-docs/atomicity/README.md}; this section covers the interop-side integration:

- **Send side**: instead of publishing to L1, `_dispatchBundle` appends the bundle's commit value to the interop IMT via `AtomicFlowManager.append` (source-side funds are still collected by the normal send machinery — `initiateIndirectCall` burns for _indirect_ asset-transfer calls, while a direct call's `interopCallValue` is collected by `_ensureCorrectTotalValue` through the `BaseTokenHolder` or the asset router; a fund-free direct call burns nothing). The `AtomicSend` metadata (`AtomicFlowPreimage` = preimage `version`, deadline, settlement-layer chain ID, leg bundle hashes, leg source chain IDs; plus `lowNullifierIndex` and `isAtomic`) travels out-of-band and never enters the bundle, keeping `bundleHash` independent of the preimage. The `AtomicFlowManager` recomputes `flowId = keccak256(abi.encode(preimage))` and requires the sent bundle's hash to be one of its legs with this chain as the declared source — so if the hash obtained from `previewMessageHash` / `previewBundleHash` was wrong or went stale (e.g. an upgrade changed the bundle encoding), the whole send reverts and nothing is burned, instead of committing a leg under a `flowId` that could neither finalize nor be refunded.
- **Execution side**: `L2InteropHandler.executeAtomicBundle(bundle, AtomicFinalityProof)` mirrors `executeBundle`, but the L1-message inclusion proof is replaced by the **atomicity gate** `AtomicFlowManager.requireFlowFinalized`: proof that _every_ leg of the flow was committed in its source chain's IMT before the deadline, and that this bundle is one of the legs. Replay is prevented by marking `FullyExecuted` (CEI) before calls run. The source chain ID used for destination-context validation is the bundle's own field; the cross-chain binding comes from the IMT inclusion proofs.
- **Atomic verification**: `verifyAtomicBundle(bundle, AtomicFinalityProof)` runs the same atomicity gate without executing the calls, marking the bundle `Verified` and enabling the verify→unbundle flow. `executeAtomicBundle` therefore accepts a bundle that is already `Verified` and **skips** the gate in that case (it was checked at verify time) — the accepted statuses are `Unreceived` and `Verified`, not `Unreceived` alone. Note this is what makes an atomic bundle partially executable: once `Verified`, individual calls can be executed or `Cancelled` via [`unbundleBundle`](#unbundling-unbundlebundle), so the atomicity gate governs whether execution is _permitted_, not that every call runs (see {protocol-docs/atomicity/security.md#guarantees}).
- **Settlement layer**: the IMT proofs are authenticated against the imported interop root, but atomic interop is **L1-only in this release**: `AtomicFlowManager` rejects any flow whose `settlementLayerChainId` is not the L1 chain id (`ManagerSettlementLayerNotL1`) on send, finality and refund alike (see {protocol-docs/atomicity/security.md#trust-assumptions}).
- **Timeouts**: if a flow misses its deadline, recovery is best-effort via `AtomicFlowManager._recoverBundle` / `IAtomicRecoverable.recoverAtomicCall`. This is why _indirect_ calls may not carry `interopCallValue` (see [Restrictions](#restrictions)) — recovery returns value to `InteropCall.from`, the asset router for an indirect call, never the payer; direct calls may carry value and are refunded through `bridgehubRecoverBaseToken`. L1 destinations are banned because L1 has no atomic execution, so the only outcome would be a timeout refund, while L2→L1 withdrawal accounting must stay append-only and never revertable.

## One-way bundles

A one-way bundle is a non-atomic bundle with exactly one call: an asset transfer between the asset routers of
two chains, proven on the destination by the inclusion of the bundle's message in a root of the source. The
L2 -> L1 withdrawal has always been one. v37 adds two more routes with the same shape and the same code:

| Route                           | Sent by                        | Proven against                                                   | Executed by                      |
| ------------------------------- | ------------------------------ | ---------------------------------------------------------------- | -------------------------------- |
| L2 -> its L1                    | `InteropCenter.sendBundle`     | the chain's batch root in the L1 `MessageRoot`                   | `L1InteropHandler.executeBundle` |
| L1 -> an L2 that settles on it  | `L1InteropCenter.sendBundle`   | L1's root in `L2InteropRootStorage`, imported by the bootloader  | `L2InteropHandler.executeBundle` |
| writer source -> an L2          | the source's `L1InteropCenter` | the source's root in `L2InteropRootStorage`, written by a writer | `L2InteropHandler.executeBundle` |
| L2 -> a writer source of the L2 | `InteropCenter.sendBundle`     | the chain's batch root in the source's `MessageRoot`             | the source's `L1InteropHandler`  |

A **writer source** is a chain outside the ecosystem that runs the L1 contracts of this repository and whose
roots an L2 gets from an [interop root writer](#interop-root-writers). The L2 does not settle on it, so
nothing carries its state into the L2 except that writer: the trusted write happens on the L2, and everything
after it is proven. How the writer source learns the L2's batch roots, which the last route needs, is outside
this document; whoever appends them to its `MessageRoot` is trusted for what leaves its vault, up to what the
L2 deposited there ({protocol-docs/interop-gating.md#per-chain-balance-cap}).

Every route is off until it is configured, see {protocol-docs/interop-gating.md#one-way-bundles-from-an-l1}.

### One-way bundles from an L1

`L1InteropCenter` is a contract of the L1 core, behind a proxy, owned by governance and pausable. It is not
the L2 `InteropCenter` deployed on L1: that one is wired to L2 built-ins and has no room left in its code
size. `sendBundle` takes the arguments of `IInteropCenter.sendBundle` and forms the same `InteropBundle`:

1. **Destination.** It must be a chain of this Bridgehub other than L1 itself (`InteropToSelfNotSupported`,
   `DestinationChainNotRegistered`), settle on this L1 and take deposits (`ChainNotSettlingOnThisChain`), and be
   enabled by the owner with `setDestinationEnabled` (`DestinationChainNotAllowed`); the chain's admin can disable
   it too. A bundle mints like a deposit, so it follows the chain's `depositsPaused()`: no bundle during a
   migration or in the window before one, when the chain's balance may already be leaving this L1. That view is
   the center's only call into the chain's contract.
2. **The call.** Exactly one call starter (`OneWayBundleNotSingleCall`), indirect (`OneWayCallNotIndirect`),
   to this L1's asset router (`OneWayCallNotToAssetRouter`), with neither `interopCallValue` nor
   `indirectCallMessageValue` (`OneWayCallValueNotZero`). `sendBundle` is not payable.
3. **Attributes.** Only `interopBundleSalt` (`OneWayBundleAttributeNotSupported`). A one-way bundle is
   executed by anyone and never unbundled, so `executionAddress` and `unbundlerAddress` could only make it
   unexecutable; sends from L1 pay no interop fee; an atomic flow has no L1 leg.
4. **The asset.** `L1AssetRouter.initiateIndirectCall` takes the asset exactly as a deposit through the
   Bridgehub does ({protocol-docs/bridging.md#one-way-bundles-and-the-deposit-accounting}) and returns the
   call for the destination: `finalizeDeposit(l1ChainId, assetId, mintData)` to the destination's asset
   router. The call's `from` is this L1's asset router.
5. **The message.** The bundle, prefixed with `BUNDLE_IDENTIFIER`, is sent as a
   [local message](#proof-of-a-local-message) of the L1 `MessageRoot`. The center emits `MessageSent`,
   `InteropBundleSent` (with the message's hash) and `OneWayBundleSent` (with the local batch number, which
   the proof needs).

The bundle salt is `keccak256(l1InteropCenter, sender, salt)`, and a (sender, salt) pair is used once. The
center's address is in the salt because the center can be [replaced](#replacing-the-counterparts): a new
center starts with no used salts and must not repeat a bundle hash the destination already executed.

A one-way bundle from an L1 has **no refund path**. It does not fail: it waits, and anyone executes it at any
time. So what could never execute is refused when sent, as far as the L1 can tell: a zero receiver (the
bridged token can't mint to it) and the attributes above. What the L1 can't tell is not covered: a receiver
that a token native to the destination refuses, or counterparts that are not set on the destination yet. The
second is a matter of order: enable a destination only after its counterparts are set.

In v37 a bundle from an L1 carries assets of the native token vault only (ERC-20 tokens; a chain with interop
enabled may also use other asset handlers, {protocol-docs/interop-gating.md#asset-handler-restriction}), never
the destination's base token, and no ETH, since it carries no value. A chain that settles on another layer
can't receive one: `L2MessageVerification` allows one hop.

### Proof of a local message

The message is in the root every chain that settles on the L1 already imports, so nothing new carries it:
see {protocol-docs/message-root.md#local-messages} for where it sits. Its proof is an ordinary two-hop proof
({protocol-docs/message-root.md#proof-paths}) whose chain and settlement layer are both the L1:

```
MessageInclusionProof {
  chainId:        the L1's chain id
  l1BatchNumber:  the local batch number k from OneWayBundleSent
  l2MessageIndex: 0
  message:        { txNumberInBatch: 0, sender: the L1InteropCenter, data: (replaced by the handler) }
  proof: [
    metadata (version 1, 3 log-leaf siblings, d batch-leaf siblings, not final),
    0, keccak256(EMPTY_IMT_ROOT, EMPTY_IMT_ROOT), RESERVED_SUBTREE_NODE,
    the batch's timestamp, the batch-leaf mask k - 1, d siblings of batch k in the L1's own chain tree,
    (block << 128) | 0, the L1's chain id,
    metadata (version 1, shared-tree depth, 0, final), the shared-tree siblings of slot 0
  ]
}
```

It ends at `interopRoots(l1ChainId, block)` for any block at or after the send in which the L1's shared tree
changed: the chain tree only grows. The siblings must be those of the tree as that block's last root saw it.
Nothing in a node builds this proof today; it is built from the L1's `AppendedChainBatchRoot` events and
`getMerklePathForChain`.

### Counterpart addressing

A one-way bundle is authenticated by real addresses, with no alias:

| Check                             | Where                                 | Value                                                           |
| --------------------------------- | ------------------------------------- | --------------------------------------------------------------- |
| message sender of an L1's bundle  | `L2InteropHandler.executeBundle`      | the source's interop center (the message root wrote the sender) |
| call sender of its transfer       | `L2AssetRouter._isValidInteropSender` | the source's asset router                                       |
| target of its transfer            | the bundle, built on the L1           | the L2's asset router, the same built-in address on every chain |
| target of a transfer back         | `L2AssetRouter.initiateIndirectCall`  | the destination's asset router                                  |
| message sender of a transfer back | `L1InteropHandler`                    | the L2's `InteropCenter`, a built-in address                    |
| call sender of a transfer back    | `L1AssetRouter._isValidInteropSender` | the L2's asset router, a built-in address                       |

The L2 learns the two addresses of the other side from one registry:
`L2Bridgehub.interopCounterparts(chainId)` returns `InteropCounterparts {interopCenter, assetRouter}`, zero
for a chain the L2 exchanges no one-way bundles with. One entry kind serves both the chain's own L1 and a
writer source, so both run the same code, and clearing the entry stops both directions at once.

- Only service transactions write the registry (`setInteropCounterparts`), sent by `ChainRegistrationSender`
  on L1: `setL1InteropCounterparts(chainId, set)` sends this L1's own `L1InteropCenter` and asset router,
  nothing the caller supplies; `setInteropCounterparts(chainId, sourceChainId, interopCenter, assetRouter)`
  sends what the chain's admin names for a writer source. Who may call them is in
  {protocol-docs/interop-gating.md#one-way-bundles-from-an-l1}.
- An entry and `isPeerAllowed` exclude each other, and an entry never writes `baseTokenAssetId`
  (`InteropCounterpartsConflict`): a chain is an atomic peer or a one-way counterpart, never both. The rest of
  the protocol relies on it: an atomic flow has no leg on a counterpart, and a one-way bundle never comes from
  a peer.
- A counterpart other than L1 must be a writer source. `ChainRegistrationSender` requires a writer to be set
  first (`InteropRootWriterNotSet`), and the L2 requires `isWriterSource`. The asset tracker applies the
  [origin rule](#one-way-bundles-with-a-writer-source) to writer sources, so this is what makes every
  counterpart other than L1 subject to it.

### Executing a one-way bundle on an L2

`L2InteropHandler.executeBundle(bytes bundle, MessageInclusionProof proof)` has the signature and the selector
of `L1InteropHandler.executeBundle`. In order:

1. The usual checks of an execution: the bundle's `executionAddress`, if any, and its status, which must be
   `Unreceived` (`BundleAlreadyProcessed`).
2. The destination context: `bundle.sourceChainId == proof.chainId` (`WrongSourceChainId`), the destination is
   this chain and the base token is this chain's.
3. **The gate.** The L2 must have counterparts for `proof.chainId` (`InteropCounterpartsNotSet`). On a chain
   that never opted in the function stops here, before any proof. The chain feature behind the counterparts
   must still be enabled (`ChainFeatureNotEnabled`): `L1_TO_L2_INTEROP_FEATURE` for the chain's L1,
   `INTEROP_ROOT_WRITERS_FEATURE` for a writer source. For the chain's L1, the chain must currently settle on
   L1 (`NotSettlingOnL1`), which keeps the deposit accounting right
   ({protocol-docs/bridging.md#one-way-bundles-and-the-deposit-accounting}).
4. The message's sender must be the counterparts' interop center (`UnauthorizedMessageSender`).
5. **The shape.** One call (`OneWayBundleNotSingleCall`), to this chain's asset router
   (`OneWayCallNotToAssetRouter`), without value (`OneWayCallValueNotZero`). The L2 handler does not pin call
   targets on the atomic path and hands out base token for a call's value, so a one-way bundle is allowed
   neither.
6. **The proof.** `L2MessageVerification.proveL2MessageInclusionShared` over `BUNDLE_IDENTIFIER || bundle`
   (`MessageNotIncluded`), and then the proof must be **self-rooted**: the settlement layer it names is
   `proof.chainId` itself (`ProofNotSelfRooted`). A one-hop proof is refused: a stored root is a message root,
   never a batch root.
7. The bundle is marked `FullyExecuted` and its call runs. The asset router accepts it only from the
   counterparts' asset router.

There is no `verifyBundle` on this path, so `unbundleBundle`, which needs `Verified`, is unreachable for
these bundles: a single transfer has nothing to unbundle, and a cancelled transfer could never be refunded.

The self-rooted rule and `SettlementLayerIsWriterSource` close the same gap from its two sides. A writer's
root never proves a message of another chain, the chain's L1 included; and a message of a writer source is
never proven through the roots of L1, whatever chain L1 has under that chain id.

### One-way bundles with a writer source

With counterparts for a writer source `S`, an L2 does three things it does not do otherwise:

- It **executes `S`'s bundles**, as above. `S` runs the same `L1InteropCenter`, so the send, the leaf and the
  proof are those of an L1; only the root comes from the writer instead of the bootloader.
- Its `InteropCenter` **sends one-way bundles to `S`**, with the restrictions of a withdrawal to L1
  ([Restrictions](#restrictions)). `L2AssetRouter.initiateIndirectCall` targets `S`'s asset router from the
  counterparts, the bundle's `destinationBaseTokenAssetId` is `S`'s ETH asset id, the bundle is published
  with `sendToL1` and pays no interop fee. `S`'s unchanged `L1InteropHandler` executes it against the L2's
  batch root in `S`'s `MessageRoot`, with the proof of a withdrawal that ends at the batch root.
- Its asset tracker applies the **origin rule** to the link with `S`
  ({protocol-docs/bridging.md#l2-asset-tracker}): only assets native to `S` cross it, in both directions, and
  never the L2's base token (`OneWayAssetOriginNotAllowed`). An asset native to `S` does not go to L1 either,
  which could not release it. The rule lives in the native token vault's hooks, so `L2AssetRouter` keeps assets
  with any other handler off the link (`AssetHandlerNotAllowed`). A burn toward `S` is never recovered
  (`RecoveryToOneWayDestinationNotSupported`).

What the writer is trusted with follows from these rules. A root is exactly as trustworthy as its writer, and
a forged root is bounded as follows:

- it mints only bridged tokens of `S`'s own assets, through one pinned call: no base token, no other
  contract, no asset of L1 or of another chain, nothing from the L2's vault;
- the amount it mints is **not** bounded, and the minted tokens are the same tokens that real transfers from
  `S` mint. They can be sent to `S`, whose vault releases real funds up to what the L2 deposited there, and
  moved to other chains by atomic flows. So the writer has custody of everything `S` transferred to the L2;
- another chain that received `S`'s asset by an atomic flow can't tell that `S` is a writer source: a
  withdrawal of it to L1 from there burns it, and L1 releases nothing, since L1 holds no deposit of it.
  Clients must not offer that withdrawal.

Written roots can't be removed, but a one-way bundle executes only against a root written since the writer
last changed ([interop root writers](#interop-root-writers)). Replacing or removing a compromised writer
therefore stops every bundle not executed yet that is proven against its roots; clearing the counterparts or
disabling the feature stops execution at once. What already executed stays. Other readers of the roots, such
as `L2MessageVerification`, still accept the old roots.

### Replacing the counterparts

The counterparts can be replaced and removed at any time, by the chain's admin, and removed by the owner and
the Bridgehub admin. On the L1, `L1AssetRouter.setL1InteropCenter` replaces the interop center.

- Removing the counterparts stops the bundles already sent in both directions; setting the same counterparts
  again resumes them.
- Replacing the interop center of a source leaves behind every bundle the old center sent that was not
  executed yet: the handler checks the stored center. Those transfers are locked on the source for good, so
  in-flight bundles are executed first when the replacement is planned.
- Replacing the asset router of a source strands the transfers back to it the same way: they carry the old
  address as their target.

## Initialization and versioning notes

- `InteropCenter.initL2` is a one-shot initializer called by the complex upgrader. Because the `InteropCenter` is introduced in v31, it runs for both new chains (genesis) and chains upgraded to v31; in both cases storage is fresh (the SystemProxy is freshly deployed). After v31 it must never be called again (`reentrancyGuardInitializer` + `_disableInitializers` guards). It sets `L1_CHAIN_ID`, the owner, `ZK_TOKEN_ASSET_ID` (must be non-zero; anyone updating it later must also update the cached `zkToken` address) and the default `ZK_INTEROP_FEE`.
- `L2InteropHandler.initL2` only locks the reentrancy guard (the handler holds no configurable state); `L1InteropHandler` is initialized behind its proxy with an owner for pause control, and its implementation is locked in the constructor. `L1InteropCenter` is initialized the same way; its owner also enables destinations.
- The one-way routes of v37 add storage only by appending: `interopCounterparts` in `L2Bridgehub`, `isLocalMessageSender` in `L1MessageRoot`, `l1InteropCenter` in `L1AssetRouter`, the writer generations in `L2InteropRootStorage`, the counterparts in `ChainRegistrationSender`. All start empty, so the contracts upgrade in place.
- `L1_CHAIN_ID` always refers to the base-most L1, on whichever layer the contract is deployed.
- Deprecated storage slots retained for layout compatibility: `InteropCenter.__DEPRECATED_interopBundleNonce`, `InteropHandlerBase.__DEPRECATED_L1_CHAIN_ID` (the handler now operates on `block.chainid`).
- `InteropCenter` is not pausable: it keeps the `PausableUpgradeable` inheritance (and its storage) for potential future use, but exposes no `pause`/`unpause` and gates no entry point on it. An L2 chain is stopped through the L1 freezing mechanism instead (see the L2 pausability rule in `AGENTS.md`).
