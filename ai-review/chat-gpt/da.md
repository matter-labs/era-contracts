## Security issues

### 1. `publishBlobs` is permissionless and `publishedBlobCommitments` is global (safe by design)

- **Severity**: Informational  
- **Impact**:  
  Any address can call `RollupL1DAValidator.publishBlobs` and mark arbitrary valid blob commitments as “published”, i.e.:

  ```solidity
  function publishBlobs(bytes calldata _pubdataCommitments) external {
      ...
      for (uint256 i = 0; i < _pubdataCommitments.length; i += PUBDATA_COMMITMENT_SIZE) {
          bytes32 blobCommitment = _getPublishedBlobCommitment(
              versionedHashIndex,
              _pubdataCommitments[i:i + PUBDATA_COMMITMENT_SIZE]
          );
          publishedBlobCommitments[blobCommitment] = block.number;
          ++versionedHashIndex;
      }
  }
  ```

  There is no access control on `publishBlobs`, and `publishedBlobCommitments` is a single global mapping.  

  However, `_getPublishedBlobCommitment` enforces that:
  - A real EIP‑4844 blob is present in the *current* transaction at the given index (via `blobhash(_index)`), and
  - The packed commitment/proof is valid with respect to that blob (via the point-evaluation precompile).

  So an attacker cannot mark a *fake* blob as published without actually supplying a valid blob + proof and paying blob gas.  

  **Security-wise, this is acceptable and appears intentional**: the DA protocol only requires that the data exist in *some* L1 blob within the freshness window, not that it was posted by a specific address. `checkDA` only uses `isBlobAvailable(prepublishedCommitment)` to enforce “there exists a fresh, valid blob with this commitment”; who posted it is irrelevant for DA guarantees.

  The main practical caveat is for off-chain tooling:
  - Tools must not interpret `publishedBlobCommitments` as “blobs for this particular rollup only”; it is effectively “all valid blobs anyone chose to publish via this helper”.  
  - If you need rollup-specific indexing, you must additionally track which commitments were actually referenced in that rollup’s `checkDA` calls.

---

### 2. `attestations` in `AvailAttestationLib` can be populated/overwritten by arbitrary callers

- **Severity**: Informational  
- **Impact**:  
  `AvailL1DAValidator.checkDA` is external and unprotected:

  ```solidity
  function checkDA(...) external returns (L1DAValidatorOutput memory output) {
      output.stateDiffHash = bytes32(operatorDAInput[:32]);
      IAvailBridge.MerkleProofInput memory input =
          abi.decode(operatorDAInput[32:], (IAvailBridge.MerkleProofInput));
      if (l2DAValidatorOutputHash != keccak256(abi.encodePacked(output.stateDiffHash, input.leaf)))
          revert InvalidValidatorOutputHash();
      _attest(input);
      ...
  }
  ```

  `_attest` writes to storage based on `msg.sender`:

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

  - Any address can call `AvailL1DAValidator.checkDA` directly with a valid `MerkleProofInput` and:
    - Create a new entry in `attestations[leaf]`, or  
    - Overwrite an existing one.
  - The stored `attester` will be that arbitrary caller, not necessarily the chain’s diamond, even though the comment says:
    > `/// @dev Address of the chain's diamond`

  **On‑chain DA correctness is not affected**:
  - The only value actually returned to the caller and used by the Executor is `stateDiffHash` and the (empty) blob arrays.
  - The `attestations` mapping is not read anywhere in this code path and so cannot influence DA verification or batch commitments.

  **Where this matters** is for off‑chain or recovery tooling that might treat `attestations` as canonical metadata:
  - Such tooling must filter entries by `attester` (i.e. known chain diamond address) and not assume the mapping is write‑protected.
  - If more strict semantics are desired (e.g. “only the chain diamond can ever create attestations”), an `onlyDiamond`‑style modifier on `checkDA` would be needed in a future revision.

---

### 3. Potential long‑term overflow of `blockNumber` in Avail attestations

- **Severity**: Informational  
- **Impact**:  
  `AttestationData.blockNumber` is a `uint32`:

  ```solidity
  struct AttestationData {
      address attester;
      uint32 blockNumber;    // Avail block number
      uint128 leafIndex;
  }
  ```

  Stored as:

  ```solidity
  attestations[input.leaf] = AttestationData(
      msg.sender,
      vectorx.rangeStartBlocks(input.rangeHash) + uint32(input.dataRootIndex) + 1,
      uint128(input.leafIndex)
  );
  ```

  Since Solidity 0.8+ has checked arithmetic, this will **revert** if the sum overflows 32 bits. If the underlying Avail chain ever uses block numbers approaching or exceeding `2^32 - 1` (≈4.29B), `_attest` will start reverting and `checkDA` will become unusable, halting DA attestations for Avail‑based chains.

  At current block number growth rates this is a long‑term liveness issue rather than an immediate vulnerability, but for a DA component that is supposed to be “forever recoverable”, a 32‑bit block counter is fragile.

  A more future‑proof design would:
  - Either store `blockNumber` as `uint64` or `uint256`, or  
  - Explicitly document that Avail block numbers are constrained to < 2^32 and that this contract will be redeployed/updated before overflow is possible.

---

### 4. Dummy Avail bridge bypasses DA proof verification (test‑only, but dangerous if mis‑configured)

- **Severity**: Informational  
- **Impact**:  
  `DummyAvailBridge` implements the `IAvailBridge` interface but:

  ```solidity
  function verifyBlobLeaf(MerkleProofInput calldata) external view returns (bool) {
      return true;
  }
  ```

  Since `AvailAttestationLib._attest` relies entirely on `bridge.verifyBlobLeaf(input)` for correctness:

  ```solidity
  if (!bridge.verifyBlobLeaf(input)) revert InvalidAttestationProof();
  ```

  wiring a `DummyAvailBridge` instance into a production `AvailL1DAValidator` would mean:
  - Every `MerkleProofInput` is accepted as valid, regardless of whether it corresponds to any real Avail DA state.
  - `attestations` would record arbitrary (stateDiffHash, leaf) pairs as if they were properly proven, completely disabling DA guarantees for that configuration.

  This is clearly intended as a testing stub, but:
  - There is no on‑chain guardrail preventing an admin from accidentally configuring it in the actual chain configuration.
  - If misused, it silently degrades DA verification to a trust‑me stub.

  Strong documentation and deployment‑time checks are required to ensure `DummyAvailBridge` is never referenced from a live chain’s configuration.

---

## Open issues / areas needing more context

The following aspects relate to DA soundness but cannot be fully validated from the provided sources alone. They should be reviewed together with the missing components.

1. **Link between L2 pubdata and L1 blob commitments for rollup DA**

   - On L2, the `L2DAValidator` library (not in scope) computes:
     - `l2DAValidatorOutputHash = keccak256(uncompressedStateDiffHash || keccak256(pubdata) || uint8(numBlobs) || blobLinearHashes)`.
   - On L1, `RollupL1DAValidator`:
     - Reconstructs `stateDiffHash`, `fullPubdataHash`, `blobsLinearHashes`, and `blobsProvided` from `operatorDAInput` and checks that `keccak256(preimage) == _l2DAValidatorOutputHash`.
     - For `PubdataSource.Blob`, it verifies KZG commitments for blobs present in the current tx or previously published blobs via `publishBlobs` + `isBlobAvailable`.
   - What is *not visible* in these contracts is the exact way the following are tied together:
     - The `blobLinearHashes` coming from L2,
     - The actual EIP‑4844 blob contents on L1,
     - The commitments (`blobCommitments`) used as public inputs in the ZK proof.

   To fully assess whether a malicious operator could post blobs with data that diverges from the L2‑committed `pubdata` while still passing both L1 and ZK verification, we would need to inspect:

   - `L2DAValidator` implementation,  
   - `PubdataChunkPublisher` system contract,  
   - The exact ZK circuit/public‑input wiring for `blobHash` / `blobCommitments`,  
   - `Executor` facet code that plumbs `L1DAValidatorOutput` into the batch commitment and verifier.

2. **Correctness of Avail DA integration**

   - `AvailL1DAValidator` assumes that:
     - `l2DAValidatorOutputHash == keccak256(stateDiffHash || input.leaf)`, and
     - `IAvailBridge.verifyBlobLeaf(input)` implies that `input.leaf` corresponds to a correct inclusion of the chain’s pubdata in Avail.
   - The contract itself does not inspect the contents of the Avail leaf or enforce any additional structure.

   To be confident there is no way for a malicious operator or bridge to attest to incorrect or unrelated Avail data while still satisfying the constraints checked here, we would need:

   - The Avail‑side specification of the leaf format and what is committed there,  
   - The Solidity (or other) implementation of `IAvailBridge.verifyBlobLeaf`,  
   - The `L2DAValidator` variant that generates `l2DAValidatorOutputHash` for Avail.

3. **Interface definition of `IL1DAValidator`**

   - Both `RollupL1DAValidator` and `AvailL1DAValidator` claim to implement `IL1DAValidator`, but the interface itself is not provided.
   - To be sure there is no inconsistency in mutability (`view` vs non‑view) or argument semantics that could cause subtle integration bugs when the Executor facet calls `checkDA`, the exact `IL1DAValidator` definition and its usage in the Executor facet should be checked.

These open issues are cross‑component consistency questions rather than flaws in the DA contracts themselves, but they are critical to end‑to‑end DA security.