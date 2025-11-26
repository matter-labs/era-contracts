## Security issues

### 1. `ForceDeployUpgrader.forceDeploy` is fully permissionless (relies on external system-contract access control)

- **Severity**: Informational  
- **Impact**: If the L2 Deployer system contract (`DEPLOYER_SYSTEM_CONTRACT`) does not correctly restrict `forceDeployOnAddresses`, any user could call `ForceDeployUpgrader.forceDeploy` and, through it, perform arbitrary force deployments on L2 (changing code at arbitrary addresses). With the current information this looks *safe by design*, but it is a single point of failure if the Deployer’s internal checks are ever relaxed or misconfigured.

**Details**

```solidity
contract ForceDeployUpgrader {
    /// @notice A function that performs force deploy
    /// @param _forceDeployments The force deployments to perform.
    function forceDeploy(ForceDeployment[] calldata _forceDeployments) external payable {
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);
    }
}
```

- There is **no access control** on `forceDeploy` itself.
- The comment indicates this is meant to be used as a base class by a “ComplexUpgrader”, but the function is `external` and will be inherited as-is.
- The only protection is whatever `IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses` enforces internally (e.g. `require(msg.sender == L2_FORCE_DEPLOYER_ADDR)` or “is system call” checks).

As long as the Deployer system contract correctly restricts `forceDeployOnAddresses` (as implied by the docs comment in `L2ContractAddresses.sol` about `L2_FORCE_DEPLOYER_ADDR`), this is safe by design. However, if:

- `forceDeployOnAddresses` is ever exposed as permissionless, or
- the Deployer’s access control is misconfigured on some chain,

then `ForceDeployUpgrader` becomes a direct, public entry point for arbitrary system re-deployment.

**Recommendation**

- Treat this dependency explicitly in specs: document that `forceDeployOnAddresses` MUST only be callable by the intended privileged address / system context for every deployment.
- Optionally harden `ForceDeployUpgrader` itself (e.g. add an `onlySystem` or `onlyOwner` modifier) so that even if the Deployer system contract changes, this contract cannot be used directly by unprivileged users.
- Add tests (or deployment-time assertions) that a call from an unprivileged address to `forceDeployOnAddresses` through this contract reverts.


### 2. Use of `UnsafeBytes` without pre-length checks in some decoders

- **Severity**: Informational  
- **Impact**: The functions will read from memory beyond the logical end of the bytes array if an extremely short message is passed. Today this results only in reading zero / uninitialized memory and then reverting on an explicit length check, but it contradicts the library’s stated contract and could become problematic if compiler or EVM semantics change.

**Details**

`UnsafeBytes` explicitly warns that its functions do **not** check bounds and callers must check `bytes.length` themselves.

```solidity
library UnsafeBytes {
    // WARNING! Functions don't check the length of the bytes array...
    function readUint32(bytes memory _bytes, uint256 _start) internal pure returns (uint32 result, uint256 offset) {
        assembly {
            offset := add(_start, 4)
            result := mload(add(_bytes, offset))
        }
    }
    ...
}
```

Some decoding helpers call `readUint32` **before** checking the length:

```solidity
function decodeBaseTokenFinalizeWithdrawalData(
    bytes memory _l2ToL1message
) internal pure returns (bytes4 functionSignature, address l1Receiver, uint256 amount) {
    (uint32 functionSignatureUint, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
    functionSignature = bytes4(functionSignatureUint);

    // Length check happens only here:
    require(_l2ToL1message.length >= 56, L2WithdrawalMessageWrongLength(_l2ToL1message.length));
    (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
    (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);
}
```

Similar patterns exist in:

- `decodeLegacyFinalizeWithdrawalData`
- `decodeAssetRouterFinalizeDepositData`
- `decodeTokenBalanceMigrationData`
- `getSelector`

**Why this is currently safe**

- For very short inputs (`length < 4`), `readUint32` will load from memory just past the encoded length word. This doesn’t access another contract’s memory or storage; it just reads whatever is in this contract’s memory (typically zero-initialized or prior scratch data).
- The subsequent `require`/`revert` based on the actual `_l2ToL1message.length` then fails, so no logic proceeds using that bogus selector.

So, there is no realistic exploit path with current EVM semantics, and in practice these functions are only called on well-formed L2→L1 messages produced by system contracts.

**Recommendation**

- For robustness and to align with `UnsafeBytes`’s contract, add a minimal pre-check before the first `readUint32`, e.g.:

  ```solidity
  if (_l2ToL1message.length < 4) {
      revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
  }
  ```

  and then keep the existing stricter `>= 56` / `== 76` / `>= 68` checks.

- This tightens the decoders against any future changes in how memory is managed or against accidental misuse elsewhere.


### 3. Merkle “memory” helpers rely on caller to respect preallocated size

- **Severity**: Informational  
- **Impact**: If the caller of `DynamicIncrementalMerkleMemory` or `FullMerkleMemory` pushes more leaves than the preallocated capacity, these libraries will write past the end of their `bytes32[]` arrays in memory. This does not corrupt contract storage and reverts only if the caller later uses the corrupted memory in an unsafe way, but it is a potential footgun for future code using these libraries.

**Details**

In `FullMerkleMemory`:

```solidity
function createTree(FullTree memory self, uint256 _maxLeafNumber) internal view {
    ...
    bytes32[][] memory nodes = new bytes32[][](height + 1);
    nodes[0] = new bytes32[](_maxLeafNumber);
    ...
    self._nodes = nodes;
    self._height = height;
    self._leafNumber = 0;
}

function pushNewLeaf(FullTree memory self, bytes32 _leaf) internal view returns (bytes32 newRoot) {
    uint256 index = self._leafNumber++;

    if (index == 1 << self._height) {
        // Extends tree beyond originally allocated height:
        uint256 newHeight = self._height.uncheckedInc();
        self._height = newHeight;
        ...
        self._zeros[self._zerosLengthMemory] = newZero;          // writes at index height+1
        ...
        self._nodes[self._nodesLengthMemory] = newLevelZero;      // writes at index height+1
    }
    ...
}
```

- `createTree` allocates `nodes` and `zeros` with length `height + 1`, where `height` is computed from `_maxLeafNumber`.
- If more than `_maxLeafNumber` leaves are pushed, `index == 1 << self._height` may become true, and the library will treat the tree as growable, writing into `self._zeros[self._zerosLengthMemory]` and `self._nodes[self._nodesLengthMemory]` beyond their allocated lengths.
- Similar assumptions exist in `DynamicIncrementalMerkleMemory` about `createTree(self, _treeDepth)`.

This is **not** a storage corruption bug (everything lives in memory), but it is easy to misuse these helpers if they are treated as “automatically growable” trees in new code.

**Recommendation**

- Make the “capacity” contract explicit in comments and docs: callers must ensure they never push more than `_maxLeafNumber` leaves (for `FullMerkleMemory`) or more than the depth implied by `_treeDepth` (for `DynamicIncrementalMerkleMemory`).
- Optionally add explicit runtime checks before growing (`if (self._zerosLengthMemory == self._zeros.length) revert;`) in debug / test builds to catch misuse early.
- When choosing where to use these memory variants vs. the storage-backed `DynamicIncrementalMerkle` / `FullMerkle`, prefer the storage-backed versions where capacity may evolve.


## Open issues / missing context

The following areas depend on components that are not in the provided scope; they should be reviewed together to rule out deeper issues:

1. **Deployer system contract access control (critical for ForceDeployUpgrader)**  
   - Missing sources:  
     - `@matterlabs/zksync-contracts/contracts/system-contracts/ContractDeployer.sol` (or equivalent implementation of `IContractDeployer`)  
     - Any wrapper that deploys or configures `DEPLOYER_SYSTEM_CONTRACT` on L2  
   - Questions to answer:  
     - Is `forceDeployOnAddresses` restricted to a specific `msg.sender` (e.g. `L2_FORCE_DEPLOYER_ADDR`) or `isSystemCall` context?  
     - Are there any deployment paths where this restriction could be bypassed?

2. **End-to-end L1↔L2 message inclusion and proof verification**  
   - Libraries here (`Merkle`, `MessageHashing`, `MessageVerification`) are correct in isolation, but security depends on how they’re used.  
   - Missing sources:  
     - L1 Mailbox / MessageRoot contracts and any `MessageVerification` concrete implementations (L1 and L2)  
     - L2 `L2ToL1Messenger` and `MessageRoot` implementations  
   - Questions to answer:  
     - Do callers always enforce the expected Merkle tree depth / proof length, as recommended in `Merkle.calculateRoot` comments, to avoid shorter/longer path misuse?  
     - Is recursive settlement-layer proof handling via `ProofData` used correctly (no skipped links, correct `finalProofNode` semantics)?

3. **Bridging and NTV accounting around `DataEncoding.encodeTxDataHash`**  
   - The hashing and assetId checks appear internally consistent, but we can’t verify cross-contract invariants.  
   - Missing sources:  
     - L1/L2 `AssetRouter`, `NativeTokenVault`, and their L2 counterparts (`L2NativeTokenVault*`)  
     - Any code using `encodeTxDataHash`, `assetIdCheck`, `decodeBaseTokenFinalizeWithdrawalData`, `decodeLegacyFinalizeWithdrawalData`.  
   - Questions to answer:  
     - Is the same encoding used consistently on both L1 and L2 for deposit / withdrawal hashing?  
     - Are there any paths where conflicting `encodingVersion` or unexpected `_nativeTokenVault` values could break accounting?

Overall, within the provided files and scope, there are no clear exploitable vulnerabilities; the noted items are mainly about reliance on external components’ security properties and avoiding future misuse of low-level helpers.