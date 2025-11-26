## Security issues

### 1. Missing check that zero placeholders actually correspond to real blobs in `BlobsL1DAValidatorZKsyncOS`

- **Severity**: Medium  
- **Impact**: A malicious or misconfigured operator can claim that certain pubdata chunks are stored in EIP‑4844 blobs without actually attaching those blobs to the L1 transaction. This can break data‑availability guarantees for the ZKsync OS + blobs path.

**Details**

In `BlobsL1DAValidatorZKsyncOS.checkDA`:

```solidity
for (uint256 index = 0; index < blobsProvided; ++index) {
    bytes32 versionedHash = bytes32(
        _operatorDAInput[BLOB_VERSIONED_HASH_SIZE * index:BLOB_VERSIONED_HASH_SIZE * (index + 1)]
    );
    if (versionedHash != bytes32(0)) {
        if (!isBlobAvailable(versionedHash)) {
            revert BlobNotPublished();
        }
    } else {
        versionedHash = _getBlobVersionedHash(versionedHashIndex);
        ++versionedHashIndex;
    }
    // write into publishedVersionedHashes...
}
...
// ensure no *extra* blobs
bytes32 nextVersionedHash = _getBlobVersionedHash(versionedHashIndex);
if (nextVersionedHash != bytes32(0)) {
    revert NonEmptyBlobVersionHash(versionedHashIndex);
}
```

Key points:

- `_operatorDAInput` contains concatenated versioned blob hashes.
- By design, a `bytes32(0)` value is a placeholder meaning “take the blob versioned hash from this transaction via `blobhash(versionedHashIndex)`”.
- However, **there is no check that `blobhash(versionedHashIndex)` returns a non‑zero hash**.
  - Per EIP‑4844, `blobhash(i)` returns `bytes32(0)` for `i ≥ number_of_blobs_in_tx`.
- The final `NonEmptyBlobVersionHash` check only ensures there are no *extra* blobs beyond those accounted for, but it does **not** ensure that each zero placeholder had a corresponding blob.

A malicious operator can therefore:

1. On L2, compute `_l2DAValidatorOutputHash` for a batch that assumes some blobs (using `0` placeholders).
2. On L1, call `checkDA` with `_operatorDAInput` containing zero hashes for those blobs, **without actually attaching the blobs** to the transaction.
3. Since `blobhash(versionedHashIndex)` returns `0` when no such blob exists and the contract never checks for non‑zero there, `publishedVersionedHashes` will contain zeros at those positions.
4. The keccak hash of `publishedVersionedHashes` will still match the L2‑produced `_l2DAValidatorOutputHash` (which also used zeros as placeholders), so `checkDA` passes.
5. No earlier `publishBlobs()` call is required for these zero entries, so there is no other on‑chain evidence that an EIP‑4844 blob was ever posted.

This is in contrast to the rollup path (`RollupL1DAValidator`), where new blobs go through `_getPublishedBlobCommitment` which explicitly reverts if `blobhash(_index)` returns zero:

```solidity
bytes32 blobVersionedHash = _getBlobVersionedHash(_index);

if (blobVersionedHash == bytes32(0)) {
    revert EmptyBlobVersionHash(_index);
}
```

So the rollup DA path correctly enforces that each claimed blob index has an actual blob; the ZKsync OS blobs path does not.

**Why this matters**

Depending on how the ZKsync OS L2 DA validator constructs `_l2DAValidatorOutputHash`, this can allow:

- Finalizing batches that internally used blob‑backed pubdata, **without** those blobs ever being posted to L1.
- Off‑chain verifiers relying on L1 + EIP‑4844 blobs to reconstruct state will fail for these batches, while the batch is considered valid by L1 contracts.

This is specifically a **data‑availability integrity** issue (not direct fund theft): the L1 contracts may accept a batch whose DA is not actually enforceable via blobs.

**Suggested fix**

Whenever a `0` placeholder is resolved via `blobhash`, add a non‑zero check, mirroring the rollup validator:

```solidity
if (versionedHash != bytes32(0)) {
    if (!isBlobAvailable(versionedHash)) {
        revert BlobNotPublished();
    }
} else {
    versionedHash = _getBlobVersionedHash(versionedHashIndex);
    if (versionedHash == bytes32(0)) {
        // Reuse existing custom error
        revert EmptyBlobVersionHash(versionedHashIndex);
    }
    ++versionedHashIndex;
}
```

This ensures that:

- Every zero placeholder stands for a real EIP‑4844 blob in the same transaction.
- There is no way to “pretend” a blob exists by keeping the placeholder zero and having `blobhash` also return zero.

**Note on context**

To fully confirm exploitability paths, one should also review:

- The ZKsync OS L2 DA validator implementation that computes `_l2DAValidatorOutputHash` for this scheme.
- The L1 `Executor` logic for the OS path (how `publishBlobs()` and `checkDA()` are orchestrated).

The missing check is clear in this contract; whether it can be abused in a given deployment depends on how strictly the L2 side uses placeholders and whether operators can influence them.


---

### 2. `AvailL1DAValidator` / `AvailAttestationLib` allow arbitrary callers to create/overwrite attestations

- **Severity**: Low  
- **Impact**: Any account with a valid Avail Merkle proof can write or overwrite entries in the `attestations` mapping. This can mislead off‑chain consumers that naively trust this mapping, though it does not let an attacker fabricate Avail inclusion without a valid proof.

**Details**

`AvailL1DAValidator.checkDA` is externally callable and unguarded:

```solidity
function checkDA(
    uint256, 
    uint256, 
    bytes32 l2DAValidatorOutputHash,
    bytes calldata operatorDAInput,
    uint256 maxBlobsSupported
) external returns (L1DAValidatorOutput memory output) {
    output.stateDiffHash = bytes32(operatorDAInput[:32]);

    IAvailBridge.MerkleProofInput memory input = abi.decode(operatorDAInput[32:], (IAvailBridge.MerkleProofInput));
    if (l2DAValidatorOutputHash != keccak256(abi.encodePacked(output.stateDiffHash, input.leaf)))
        revert InvalidValidatorOutputHash();
    _attest(input);
    ...
}
```

`_attest` stores an attestation keyed by the Avail leaf:

```solidity
function _attest(IAvailBridge.MerkleProofInput memory input) internal virtual {
    if (!bridge.verifyBlobLeaf(input)) revert InvalidAttestationProof();
    attestations[input.leaf] = AttestationData(
        msg.sender,
        vectorx.rangeStartBlocks(input.rangeHash) + uint32(input.dataRootIndex) + 1,
        uint128(input.leafIndex)
    );
}
```

Consequences:

- Anyone who can produce a valid `MerkleProofInput` (for example, any party monitoring Avail) can call `checkDA` directly and create or overwrite an `attestations[leaf]` entry.
- They control the `attester` field (set to `msg.sender`). Block number and leaf index are derived from the Avail bridge / VectorX contracts and remain correct if those are honest.

This does **not** let an attacker fabricate inclusion proofs, because `bridge.verifyBlobLeaf(input)` must still pass. However:

- Off‑chain tools that reconstruct state “from on‑chain data” and treat `attestations[leaf].attester` as *the* chain contract (without filtering or allow‑listing) can be misled into attributing a leaf to an arbitrary address.
- Future code that assumes “if there is an attestation for leaf L, then the chain’s diamond must have called `checkDA`” would be incorrect.

**Suggested mitigation**

If these attestations are intended to represent actions of a particular chain/diamond contract, restrict who can call `checkDA`:

- Add an immutable `address public immutable executor` (or similar) set at deployment, and require:

  ```solidity
  modifier onlyExecutor() {
      require(msg.sender == executor, "only executor");
      _;
  }
  ```

- Apply `onlyExecutor` to `checkDA`.

Alternatively, off‑chain consumers should explicitly validate that `attestations[leaf].attester` is in an allowed set of chain contracts and *not* trust arbitrary attestations.


---

### 3. `RollupL1DAValidator.checkDA` reads `l1DaInput[0]` without an explicit length check (safe but brittle)

- **Severity**: Informational  
- **Impact**: Malformed `_operatorDAInput` that passes the keccak check but omits `l1DaInput` would trigger a generic out‑of‑bounds panic instead of a clear DA‑related error. Under the current spec this appears unreachable, but it makes the code more brittle to future changes.

**Details**

In `RollupL1DAValidator.checkDA`:

```solidity
(
    bytes32 stateDiffHash,
    bytes32 fullPubdataHash,
    bytes32[] memory blobsLinearHashes,
    uint256 blobsProvided,
    bytes calldata l1DaInput
) = _processL2RollupDAValidatorOutputHash(_l2DAValidatorOutputHash, _maxBlobsSupported, _operatorDAInput);

uint8 pubdataSource = uint8(l1DaInput[0]);
```

- `_processL2RollupDAValidatorOutputHash` verifies that the prefix of `_operatorDAInput` up to `ptr = 65 + 32*blobsProvided` hashes to `_l2DAValidatorOutputHash`; the remaining `l1DaInput` is **not** included in that hash.
- There is no explicit check that `l1DaInput.length > 0` before reading `l1DaInput[0]`.

Under the intended protocol:

- The L2 DA validator always includes at least one byte of `l1DaInput` (the `PubdataSource` enum), so `l1DaInput[0]` is safe.
- An operator who tried to omit `l1DaInput` would need to find a second preimage for keccak in order to make `_l2DAValidatorOutputHash` match, which is infeasible.

So this is **safe by design today**, but fragile:

- If the spec for `_l2DAValidatorOutputHash` preimage ever changes to include more data (or to exclude the prefix length check), this `l1DaInput[0]` read could become a real issue.

**Suggested improvement**

Add an explicit check and a dedicated error to make the assumption clear and future‑proof:

```solidity
if (l1DaInput.length == 0) {
    revert OperatorDAInputTooSmall(_operatorDAInput.length, BLOB_DATA_OFFSET + 32 * blobsProvided + 1);
}
```

This keeps behavior unchanged under valid inputs, but gives a clean, protocol‑level revert reason for malformed ones and guards against future spec drift.


---

## Open questions / additional context needed

To fully validate and quantify the impact of issue 1, reviewing the following components would be helpful:

- **ZKsync OS L2 DA validator library** that computes `_l2DAValidatorOutputHash` for the `BlobsL1DAValidatorZKsyncOS` path:
  - Does it rely on zero placeholders for blob versioned hashes?
  - Does it ever enforce that each zero placeholder must correspond to an actual EIP‑4844 blob on L1?
- **L1 `Executor` / batch commitment logic** for the OS + blobs mode:
  - How and when are `publishBlobs()` and `checkDA()` invoked relative to `commitBatches` and `prove`?
  - Is there any additional enforcement that each zero placeholder has a corresponding blob in the same transaction?

The missing non‑zero check on `blobhash()` in `BlobsL1DAValidatorZKsyncOS` is clear from the code alone; the above components determine how easily a malicious operator could exploit it in practice.