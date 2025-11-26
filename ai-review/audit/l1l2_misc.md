## Security issues

### 1. Incorrect proof‑metadata detection disables settlement‑layer checks for new proof format

- **Severity**: High  
- **Impact**: For chains that use the new “recursive” proof format (e.g. chains settling on a gateway/settlement layer instead of directly on L1), `MessageHashing.parseProofMetadata` misclassifies proofs as the legacy flat format. As a result, `_getProofData` (and any `_proveL2LeafInclusionRecursive` implementation that uses it) will only verify inclusion of the L2 leaf in a single Merkle tree and will skip the additional proofs that the batch/chain roots were included on the settlement layer. This can weaken security of such chains to “direct L2→L1 settlement” and may allow acceptance of messages without properly proving their inclusion through the settlement layer.

**Technical details**

In `MessageHashing.sol`:

```solidity
function parseProofMetadata(bytes32[] calldata _proof) internal pure returns (ProofMetadata memory result) {
    bytes32 proofMetadata = _proof[0];

    // ...
    // We shift left by 4 bytes = 32 bits to remove the top 32 bits of the metadata.
    uint256 metadataAsUint256 = (uint256(proofMetadata) << 32);

    if (metadataAsUint256 == 0) {
        // It is the new version
        bytes1 metadataVersion = bytes1(proofMetadata);
        if (uint256(uint8(metadataVersion)) != SUPPORTED_PROOF_METADATA_VERSION) {
            revert UnsupportedProofMetadataVersion(uint256(uint8(metadataVersion)));
        }

        result.proofStartIndex = 1;
        result.logLeafProofLen = uint256(uint8(proofMetadata[1]));
        result.batchLeafProofLen = uint256(uint8(proofMetadata[2]));
        result.finalProofNode = uint256(uint8(proofMetadata[3])) != 0;
    } else {
        // It is the old version

        // The entire proof is a merkle path
        result.proofStartIndex = 0;
        result.logLeafProofLen = _proof.length;
        result.batchLeafProofLen = 0;
        result.finalProofNode = true;
    }
    if (result.finalProofNode && result.batchLeafProofLen != 0) {
        revert InvalidProofLengthForFinalNode();
    }
}
```

The intent (per comments) is:

- **Old format**: `_proof` is a plain Merkle path (no metadata).
- **New format**: `_proof[0]` is metadata:
  - byte 0: metadata version
  - byte 1: `logLeafProofLen`
  - byte 2: `batchLeafProofLen`
  - byte 3: `finalProofNode`
  - bytes 4–31: all zero

and they want to distinguish them “based on whether the last 28 bytes are zero”.

However, the actual check:

```solidity
uint256 metadataAsUint256 = (uint256(proofMetadata) << 32);
if (metadataAsUint256 == 0) { /* new */ } else { /* old */ }
```

is incorrect:

- Let `proofMetadata` be a proper new‑format metadata word: first 4 bytes non‑zero, last 28 bytes zero.  
  In big‑endian encoding this is e.g. `0xVVLLBBFF0000...00`. Interpreted as `uint256`, left‑shifting by 32 bits yields the 32‑bit header in the low bits, **not zero**.
- So `metadataAsUint256 == 0` is *never* true for a valid new‑format metadata word; it is only true when the entire 32‑byte word is zero.
- Therefore **all** realistic proofs, including new‑format ones, go through the “old version” branch:
  ```solidity
  result.proofStartIndex = 0;
  result.logLeafProofLen = _proof.length;
  result.batchLeafProofLen = 0;
  result.finalProofNode = true;
  ```
  i.e. the entire `_proof` is treated as a single flat Merkle path.

Downstream, `_getProofData` uses this metadata:

```solidity
ProofMetadata memory proofMetadata = MessageHashing.parseProofMetadata(_proof);
result.ptr = proofMetadata.proofStartIndex;

bytes32 batchSettlementRoot = Merkle.calculateRootMemory(
    extractSlice(_proof, result.ptr, result.ptr + proofMetadata.logLeafProofLen),
    _leafProofMask,
    _leaf
);
result.ptr += proofMetadata.logLeafProofLen;
result.batchSettlementRoot = batchSettlementRoot;
result.finalProofNode = proofMetadata.finalProofNode;

if (proofMetadata.finalProofNode) {
    return result;
}

// If not final, it should verify:
//   - the batch leaf in the settlement-layer tree
//   - the chainId leaf in the settlement-layer chain root
//   - settlement-layer batch linkage
// via `batchLeafProofLen`, `settlementLayerPackedBatchInfo`, etc.
```

Because `finalProofNode` is always `true` in the mis‑classified “old” branch, the function returns early and **never executes** the logic that:

- Uses `batchLeafProofLen` to verify the batch leaf against a settlement‑layer root.
- Extracts `settlementLayerChainId`, `settlementLayerBatchNumber`, and `settlementLayerBatchRootMask` to continue recursion.

This effectively disables the intended additional settlement‑layer checks for any proof that was encoded using the new metadata format.

**Why this is security‑relevant**

- For chains that **settle directly on L1**, the old flat format is sufficient; this bug just means the new format is ignored (and probably won’t be used).
- For chains that **settle via another layer** (e.g. a “Gateway/settlement layer” chain that itself posts roots/proofs to L1), the recursive format is required to prove that:
  1. The log was in an L2 batch;
  2. That batch was in the settlement‑layer tree;
  3. That settlement‑layer root was itself committed to L1 (possibly via another aggregation step).

  Skipping steps (2) and (3) downgrades the guarantee to: “this log is in *some* tree whose root equals the value passed in”, without ensuring that this root corresponds to a valid settlement‑layer batch. Depending on how `_proveL2LeafInclusionRecursive` is implemented in `Mailbox` / `L2MessageVerification`, this can:

  - Accept messages as proven **without ever checking** that the referenced settlement‑layer batch and chain were actually committed/verified; or
  - Cause all new‑format proofs to fail (if later checks expect `batchLeafProofLen > 0` or recursive calls).

Either case is serious for any deployment that intends to rely on multi‑layer settlement proofs.

**Recommendation**

Fix the metadata‑format detection to actually test whether the **lower 224 bits** (last 28 bytes) are zero, as the comments describe. Example fixes:

```solidity
function parseProofMetadata(bytes32[] calldata _proof) internal pure returns (ProofMetadata memory result) {
    bytes32 proofMetadata = _proof[0];

    // Mask out the top 32 bits (metadata header) and inspect the remaining 224 bits
    uint256 lower224 = uint256(proofMetadata) & ((uint256(1) << 224) - 1);

    if (lower224 == 0) {
        // New format
        bytes1 metadataVersion = proofMetadata[0];
        if (uint8(metadataVersion) != SUPPORTED_PROOF_METADATA_VERSION) {
            revert UnsupportedProofMetadataVersion(uint256(uint8(metadataVersion)));
        }

        result.proofStartIndex = 1;
        result.logLeafProofLen = uint8(proofMetadata[1]);
        result.batchLeafProofLen = uint8(proofMetadata[2]);
        result.finalProofNode = uint8(proofMetadata[3]) != 0;
    } else {
        // Legacy format
        result.proofStartIndex = 0;
        result.logLeafProofLen = _proof.length;
        result.batchLeafProofLen = 0;
        result.finalProofNode = true;
    }

    if (result.finalProofNode && result.batchLeafProofLen != 0) {
        revert InvalidProofLengthForFinalNode();
    }
}
```

or equivalently:

```solidity
if (uint224(uint256(proofMetadata)) == 0) { /* new */ } else { /* old */ }
```

Additionally:

- Add unit tests that:
  - Construct a properly formatted metadata word (version=1, non‑zero lengths, last 28 bytes zero) and check that the “new format” branch is taken and fields decoded correctly.
  - Confirm that a random 32‑byte hash is classified as “old format”.
- Consider **dropping the heuristic** and requiring an explicit version marker (e.g. high‑order byte = 0x01) once all old proofs are deprecated. This avoids any reliance on “hashes almost never have 28 trailing zero bytes”.

**Open context needed**

To fully characterize the exploitability and impact across the system, we would need to inspect:

- The concrete implementations of `_proveL2LeafInclusionRecursive` in:
  - L1 `Mailbox` / `MessageVerification`–derived contracts; and
  - L2 `L2MessageVerification` / interop contracts.
- The contracts that store and expose:
  - L2 batch/message roots per chain; and
  - Settlement‑layer chain/batch roots (e.g. Gateway / DA validators).

These will show exactly which invariants are skipped when the metadata is misparsed.

---

### 2. `ForceDeployUpgrader.forceDeploy` lacks local access control (safe by design but fragile)

- **Severity**: Informational  
- **Impact**: `ForceDeployUpgrader.forceDeploy` is `external` and has no access control. If the underlying `DEPLOYER_SYSTEM_CONTRACT.forceDeployOnAddresses` ever becomes callable by arbitrary senders (or if its access control changes to “trust this wrapper”), any L2 account could trigger force‑deploys and arbitrarily mutate contract bytecode. Currently, comments and existing architecture indicate that the system contract itself enforces `msg.sender == L2_FORCE_DEPLOYER_ADDR`, so this wrapper is safe **as long as** that invariant holds.

**Technical details**

```solidity
contract ForceDeployUpgrader {
    /// @notice A function that performs force deploy
    /// @param _forceDeployments The force deployments to perform.
    function forceDeploy(ForceDeployment[] calldata _forceDeployments) external payable {
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);
    }
}
```

- No `onlyOwner` / `onlySystem`‑style guard is applied here.
- Comments in `L2ContractAddresses.sol` and upstream system‑contracts specify that the Deployer system contract “allows changing bytecodes on any address if the `msg.sender` is this address [L2_FORCE_DEPLOYER_ADDR]”. This suggests the real guard is at the system‑contract level.

**Recommendation**

- From a defense‑in‑depth standpoint, consider adding an explicit check against the known upgrade sender, e.g.:

  ```solidity
  import {L2_FORCE_DEPLOYER_ADDR} from "./L2ContractHelper.sol";

  function forceDeploy(ForceDeployment[] calldata _forceDeployments) external payable {
      require(msg.sender == L2_FORCE_DEPLOYER_ADDR, "Only force deployer");
      IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);
  }
  ```

- Alternatively, make the contract `abstract` so it cannot be accidentally deployed standalone; and ensure any concrete upgrader adds its own access control.

Note: given the documented system‑contract guard, this is currently **safe by design**, but it is a fragile assumption that future refactors might unintentionally violate.

---

### 3. Dynamic Merkle tree memory helpers can silently revert if capacity misconfigured

- **Severity**: Informational  
- **Impact**: The in‑memory Merkle helper libraries (`DynamicIncrementalMerkleMemory`, `FullMerkleMemory`) assume the caller will not push more leaves than the tree was created to hold. If a caller misconfigures `_treeDepth` / `_maxLeafNumber` or pushes too many leaves (potentially under attacker control), out‑of‑bounds writes will cause a revert, leading to a DoS of the higher‑level operation that depends on these trees (e.g. message‑batch processing).

**Technical details**

Examples:

1. In `DynamicIncrementalMerkleMemory._pushInner`:

   ```solidity
   if (leafIndex == 1 << levels) {
       bytes32 zero = self._zeros[levels];
       bytes32 newZero = Merkle.efficientHash(zero, zero);
       self._zeros[self._zerosLengthMemory] = newZero;  // <-- can write past array end
       ++self._zerosLengthMemory;
       self._sides[self._sidesLengthMemory] = bytes32(0); // <-- can write past array end
       ++self._sidesLengthMemory;
       ++levels;
   }
   ```

   Arrays `_zeros` and `_sides` are allocated in `createTree` with fixed length `_treeDepth`. If the number of extensions causes `_zerosLengthMemory == _zeros.length`, another extension attempt will access index `== length`, which will revert.

2. In `FullMerkleMemory.pushNewLeaf`:

   ```solidity
   uint256 index = self._leafNumber++;
   // ...
   self._nodes[0][_index] = _itemHash; // will revert if _index >= self._nodes[0].length
   ```

   `createTree` sets `self._nodes[0].length == _maxLeafNumber`, but there is no explicit guard that `_leafNumber` never exceeds `_maxLeafNumber`.

In both cases, misusing the library (creating too small a tree or pushing too many leaves) will cause unexpected reverts in the calling code.

**Recommendation**

- At minimum, document clearly that:
  - `DynamicIncrementalMerkleMemory.createTree` must be called with a `_treeDepth` that is large enough for the *maximum* possible dynamic growth; and
  - Callers must never push more leaves than the precomputed capacity of the tree in `FullMerkleMemory`.
- For additional robustness (and clearer failure modes), consider adding explicit checks:
  - In `DynamicIncrementalMerkleMemory._pushInner`, before extending:
    ```solidity
    require(self._zerosLengthMemory < self._zeros.length, "Tree depth exceeded");
    ```
  - In `FullMerkleMemory.pushNewLeaf`, ensure:
    ```solidity
    require(index < self._nodes[0].length, "Max leaf number exceeded");
    ```

These checks turn what would otherwise be hard‑to‑debug “out of gas / invalid opcode” failures into clear, bounded error conditions.

---

## Open issues / missing context

The precise exploitability and systemic impact of Issue 1 (metadata parsing) depends on contracts and logic not included in this scope. To fully validate and quantify the risk, the following components should be reviewed:

1. **Implementations of `_proveL2LeafInclusionRecursive`**:
   - On L1 (e.g. Mailbox / MessageRoot / Bridgehub facets).
   - On L2 (`L2MessageVerification`, `InteropCenter`, or related contracts).

2. **Contracts that store and expose message/batch roots**:
   - How per‑chain `L2ToL1LogsRoot` / message roots are stored.
   - How settlement‑layer chain roots and batch roots are stored and linked to L1.

3. **End‑user entry points that rely on recursive proofs**:
   - Any finalize‑withdraw / cross‑chain message handlers which:
     - Accept `_proof` in the new metadata format, and
     - Expect the recursive proof path (via settlement layers) to be enforced.

Reviewing these will allow determining whether the current bug only makes new‑format proofs unusable (causing hard failures) or whether it actually allows “short‑circuiting” the settlement‑layer proof chain in a way that an attacker could exploit.