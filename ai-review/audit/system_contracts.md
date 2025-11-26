## Security issues

### 1. DynamicIncrementalMerkle `clearMemory` writes out-of-bounds in memory trees

- **Severity**: Medium (potential, depends on usage)
- **Impact**: If any system contract uses the `Bytes32PushTree` *memory* variant and calls `clearMemory`, the function writes beyond the bounds of the `_zeros` and `_sides` arrays. This can corrupt adjacent in‑memory fields of the struct (e.g. other arrays / length fields), leading to incorrect Merkle roots or other corrupted data. If such roots are used as commitments for cross-chain messaging or state, this could break inclusion proofs and potentially allow forged or permanently unverifiable commitments.

**Details**

In `DynamicIncrementalMerkle.sol`:

```solidity
function clearMemory(Bytes32PushTree memory self) internal pure {
    self._nextLeafIndex = 0;
    uint256 length = self._zerosLengthMemory;
    for (uint256 i = length; 0 < i; --i) {
        self._zeros[i] = bytes32(0);
    }
    length = self._sidesLengthMemory;
    for (uint256 i = length; 0 < i; --i) {
        self._sides[i] = bytes32(0);
    }
}
```

Array indices for `bytes32[]` are valid only in `[0, self._zeros.length - 1]` and `[0, self._sides.length - 1]`.  
Given the library’s own usage patterns, `_zerosLengthMemory` and `_sidesLengthMemory` represent the *number of used levels* and are updated like:

```solidity
// In setupMemory
self._zerosLengthMemory = 1;
self._sidesLengthMemory = 1;

// In extendUntilEndMemory
self._sidesLengthMemory = self._sides.length;
self._zerosLengthMemory = self._zeros.length;
```

So in the common case `_zerosLengthMemory == self._zeros.length` and `_sidesLengthMemory == self._sides.length`. Then in `clearMemory` the first iteration executes with `i == length`, and accesses:

```solidity
self._zeros[length] = ...;
self._sides[length] = ...;
```

which is **one past the end** of each array. In memory, this writes into whatever word follows the arrays (likely other struct fields or unrelated local variables). The loop also never clears index `0` (it should clear indices `0..length-1`), so the “cleared” tree still contains old values at index 0.

This is a classic out‑of‑bounds memory write bug. Its concrete exploitability depends on how the memory-tree variant is used:

- If contracts only use the storage variant (`setup`, `push`, `root`, etc.) and never the memory variant, this won’t be hit on-chain.
- If any on-chain verification/messaging contract builds Merkle roots using the memory tree API and calls `clearMemory`, its internal tree state can become inconsistent, leading to wrong roots and therefore wrong commitments / proofs.

**Recommendation**

- Fix `clearMemory` to index correctly and clear the intended range:

```solidity
function clearMemory(Bytes32PushTree memory self) internal pure {
    self._nextLeafIndex = 0;
    uint256 length = self._zerosLengthMemory;
    for (uint256 i = 0; i < length; ++i) {
        self._zeros[i] = bytes32(0);
    }
    length = self._sidesLengthMemory;
    for (uint256 i = 0; i < length; ++i) {
        self._sides[i] = bytes32(0);
    }
    self._zerosLengthMemory = 0;
    self._sidesLengthMemory = 0;
}
```

- Audit all call sites of `DynamicIncrementalMerkle.Bytes32PushTree memory` (e.g. message-root related contracts) to ensure:
  - Arrays backing `_zeros` and `_sides` are allocated with sufficient length before calling `setupMemory`, `pushMemory`, etc.
  - `clearMemory` is either fixed or not used in security-critical paths.


### 2. `Compressor.publishCompressedBytecode` underflows dictionary length check and can read past the declared dictionary

- **Severity**: Low
- **Impact**: When the dictionary length in `_rawCompressedData` is zero, the index bounds check in `publishCompressedBytecode` underflows and becomes ineffective, allowing `readUint64` to read from outside the declared dictionary range. In practice, the function still verifies that the recomposed chunks equal the provided `_bytecode`, so this does **not** appear to let an attacker register a code hash without knowing its full bytecode, but it weakens format validation and relies on subtle calldata layout.

**Details**

In `Compressor.publishCompressedBytecode`:

```solidity
(bytes calldata dictionary, bytes calldata encodedData) = _decodeRawBytecode(_rawCompressedData);

...

for (uint256 encodedDataPointer = 0; encodedDataPointer < encodedData.length; encodedDataPointer += 2) {
    uint256 indexOfEncodedChunk = uint256(encodedData.readUint16(encodedDataPointer)) * 8;
    if (indexOfEncodedChunk > dictionary.length - 1) {
        revert IndexOutOfBounds();
    }

    uint64 encodedChunk = dictionary.readUint64(indexOfEncodedChunk);
    uint64 realChunk = _bytecode.readUint64(encodedDataPointer * 4);

    if (encodedChunk != realChunk) {
        revert EncodedAndRealBytecodeChunkNotEqual(realChunk, encodedChunk);
    }
}
```

`_decodeRawBytecode` sets:

```solidity
uint256 dictionaryLen = uint256(_rawCompressedData.readUint16(0));
dictionary = _rawCompressedData[2:2 + dictionaryLen * 8];
encodedData = _rawCompressedData[2 + dictionaryLen * 8:];
```

If `dictionaryLen == 0`, then `dictionary.length == 0` and in the `unchecked` context `dictionary.length - 1` underflows to `2**256 - 1`. As a result, the bounds check:

```solidity
if (indexOfEncodedChunk > dictionary.length - 1) revert;
```

never triggers, even though **any non-zero index is out-of-bounds for a zero-length dictionary**.

Then `dictionary.readUint64(indexOfEncodedChunk)` uses `UnsafeBytesCalldata`:

```solidity
function readUint64(bytes calldata _bytes, uint256 _start) internal pure returns (uint64 result) {
    assembly {
        let offset := sub(_bytes.offset, 24)
        result := calldataload(add(offset, _start))
    }
}
```

This reads from the underlying calldata at `dictionary.offset - 24 + _start`, regardless of `dictionary.length`. With `dictionaryLen == 0`, `dictionary.offset` points at `_rawCompressedData[2]`, so reads for `indexOfEncodedChunk > 0` pull bytes from what the compressor intended as `encodedData` or even beyond the compressed buffer, instead of the (non-existent) dictionary.

The function then compares `encodedChunk` against the chunk from `_bytecode`. An attacker controlling both `_bytecode` and `_rawCompressedData` can always choose `_rawCompressedData` such that these comparisons pass, even though the compressed format is malformed (no dictionary, indices pointing outside it).

**Why this is (mostly) safe today**

- The **hash actually registered** in `KnownCodesStorage` is `Utils.hashL2Bytecode(_bytecode)`, which is computed over the full `_bytecode` parameter, not over the decompressed `_rawCompressedData`.  
- `publishCompressedBytecode` never uses the dictionary/indices to generate code that will be executed; it only checks consistency and then:
  - Sends `_rawCompressedData` to L1 via `L1_MESSENGER_CONTRACT.sendToL1`, and
  - Marks `hashL2Bytecode(_bytecode)` as known.

So as long as `_bytecode` is what the L2 operator actually used for execution, the code hash is still registered with its correct preimage, and an attacker can’t make a different bytecode appear under that hash.

However:

- The compressed format is supposed to be canonical and verifiable on L1. This bug means the L2 side accepts a compressed stream with indices that are invalid per the stated format (no dictionary / OOB indices).  
- If the L1 decompression/verification contracts implement stricter checks (e.g. require `index < dictionaryLen`), a malicious operator could choose malformed compressed data that passes the L2 check but fails verification on L1, breaking the “publicly restorable from L1 DA” property for that bytecode.

**Recommendation**

- Harden the bounds check and explicitly reject zero-length dictionaries:

```solidity
if (dictionary.length == 0) {
    revert DictionaryDividedByEightNotGreaterThanEncodedDividedByTwo(); // or a dedicated error
}
...
if (indexOfEncodedChunk >= dictionary.length) {
    revert IndexOutOfBounds();
}
```

- Consider adding an explicit invariant that `dictionaryLen > 0` whenever `_bytecode.length > 0` to align with the documented compression algorithm.
- Review the L1-side decompression / verification contract for compressed bytecodes to:
  - Ensure it has **strict** index/bounds checking.
  - Keep its format checks aligned with the L2-side checks after this fix.


## Open issues / missing context

These items look relevant but require inspection of additional contracts not included in the current scope to assess exploitability:

1. **Usage of `DynamicIncrementalMerkle` memory APIs**
   - To fully evaluate Issue 1’s impact, we need to see all contracts that use:
     - `DynamicIncrementalMerkle.setupMemory`
     - `DynamicIncrementalMerkle.pushMemory` / `pushLazyMemory`
     - `DynamicIncrementalMerkle.clearMemory`
     - `DynamicIncrementalMerkle.extendUntilEndMemory` / `rootMemory`
   - In particular, any L2 message root / interop-related contracts (e.g. `MessageRoot`, `L2MessageRoot`) that rely on these memory trees for Merkle root calculation should be reviewed.

2. **L1-side compressed bytecode handling**
   - To fully understand the safety of the `publishCompressedBytecode` format checks, we need the L1 contracts or off-chain logic that:
     - Receive `_rawCompressedData` sent by `L1_MESSENGER_CONTRACT.sendToL1`.
     - Decompress it and verify that `Utils.hashL2Bytecode(decompressed)` equals the registered `bytecodeHash`.
   - Specifically, we should confirm whether the L1 implementation:
     - Enforces `index < dictionaryLen` strictly, and
     - Allows or forbids zero-length dictionaries.

If you can provide the relevant L1 decompression contracts and any system contracts that use `DynamicIncrementalMerkle`’s memory variant, I can refine the severity and exploitability assessment accordingly.