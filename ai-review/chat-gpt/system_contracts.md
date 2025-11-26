## Security issues

### 1. Reliance on VM to enforce `isSystemCall` flag cannot be set by user contracts  
**Severity**: Informational  
**Impact**: If the VM ever allowed non‑system contracts to set the `isSystemCall` flag, arbitrary user contracts could bypass `onlySystemCall` checks on system contracts (e.g. nonce and deployment functions), which would be a critical privilege escalation. In the current design this is prevented by the VM, but it’s an important invariant to preserve.

**Details**

Many privileged entry points in system contracts are guarded only by:

```solidity
// SystemContractBase.sol
modifier onlySystemCall() {
    if (!SystemContractHelper.isSystemCall() && !SystemContractHelper.isSystemContract(msg.sender)) {
        revert SystemCallFlagRequired();
    }
    _;
}
```

`isSystemCall()` consults the call flags (VM register), and `isSystemContract(msg.sender)` checks whether the caller’s address is in the kernel range (`<= MAX_SYSTEM_CONTRACT_ADDRESS`).

Examples of functions relying solely on `onlySystemCall`:

- `NonceHolder.increaseMinNonce`
- `NonceHolder.incrementMinNonceIfEquals`
- `NonceHolder.incrementMinNonceIfEqualsKeyed`
- `ContractDeployer.createAccount`
- `ContractDeployer.create2Account`
- `ContractDeployer.createEVM`
- `ContractDeployer.create2EVM`
- `ContractDeployer.updateAccountVersion`

At the same time, libraries such as `SystemContractsCaller` and `EfficientCall` can request system‑flagged calls:

```solidity
// SystemContractsCaller.systemCall
success := call(to, SYSTEM_CALL_CALL_ADDRESS, 0, 0, farCallAbi, 0, 0)

// EfficientCall.rawCall, value != 0 case
_loadFarCallABIIntoActivePtr(_gas, _data, false, true); // isSystemCall := true for call to MsgValueSimulator
...
success := call(msgValueSimulator, SYSTEM_CALL_BY_REF_CALL_ADDRESS, _value, _address, 0xFFFF, forwardMask, 0);
```

If user‑space contracts could invoke these primitives in a way that sets the `isSystem` bit on calls into system contracts, `onlySystemCall` would treat them as privileged even though `msg.sender` is not a system contract.

The docs and comments indicate the intended protection is at the VM level, e.g.:

- `EfficientCall.rawMimicCall`:  
  > “If called not in kernel mode, it will result in a revert (enforced by the VM)”
- `SystemContractsCaller` / `SystemContractHelper` docs: opcodes are “needed for the development of system contracts” and “some methods won’t work for non‑system contracts”.

**Why this is safe by design**

The model assumes:

- Kernel‑only opcodes or pseudo‑precompiles (`SYSTEM_CALL_CALL_ADDRESS`, `SYSTEM_CALL_BY_REF_CALL_ADDRESS`, etc.) can only be used successfully by system contracts.
- Non‑system contracts can’t cause `isSystemCall()` to return `true` on their own calls into system contracts.

Under those assumptions, `onlySystemCall` is equivalent to “caller is a system contract or another system contract made an explicit system call,” which is safe.

**Recommendation**

- Treat this VM invariant as *security‑critical*. Any change that exposes `SystemContractsCaller`/`EfficientCall` to user‑space without the kernel check would immediately make the above functions exploitable.
- Consider documenting this explicitly in the protocol spec: “`isSystemCall` can only be set by kernel contracts; user space cannot produce a system call into system contracts.”
- Optionally, for future designs, consider replacing `onlySystemCall` with stricter, address‑based checks where feasible for defense in depth (e.g. `onlyCallFromBootloader`/`onlyCallFromSystemContract`) where the caller set is known and fixed.


### 2. Unchecked multiplication of `maxFeePerGas` and `gasLimit` for fee and balance accounting  
**Severity**: Informational  
**Impact**: If the bootloader or transaction parser ever allowed unbounded `maxFeePerGas` or `gasLimit`, the product `maxFeePerGas * gasLimit` would overflow `uint256`. This would (a) under‑charge the fee actually paid to the bootloader and (b) cause `DefaultAccount`’s balance check to approve transactions that cannot truly cover their gas. Current protocol limits likely make this unreachable, but the safety relies on off‑chain/VM constraints rather than on‑chain checks.

**Details**

Fee and required balance are computed as:

```solidity
// TransactionHelper.sol
function payToTheBootloader(Transaction calldata _transaction) internal returns (bool success) {
    address bootloaderAddr = BOOTLOADER_FORMAL_ADDRESS;
    uint256 amount = _transaction.maxFeePerGas * _transaction.gasLimit;  // unchecked mul

    assembly {
        success := call(gas(), bootloaderAddr, amount, 0, 0, 0, 0)
    }
}

// TransactionHelper.sol
function totalRequiredBalance(Transaction calldata _transaction) internal pure returns (uint256 requiredBalance) {
    if (address(uint160(_transaction.paymaster)) != address(0)) {
        requiredBalance = _transaction.value;
    } else {
        requiredBalance = _transaction.maxFeePerGas * _transaction.gasLimit + _transaction.value;  // unchecked mul
    }
}
```

`DefaultAccount._validateTransaction` uses this for pre‑execution balance checks:

```solidity
uint256 totalRequiredBalance = _transaction.totalRequiredBalance();
if (totalRequiredBalance > address(this).balance) {
    revert InsufficientFunds(totalRequiredBalance, address(this).balance);
}
```

If an attacker could submit a transaction where `maxFeePerGas * gasLimit >= 2^256`, the multiplication would wrap modulo 2²⁵⁶:

- The fee actually sent to the bootloader (`amount`) would be the wrapped product, likely orders of magnitude smaller than the intended gas cost.
- The `totalRequiredBalance` would also be too small, allowing transactions from accounts with insufficient funds according to the economic model.

In practice, the protocol restricts gas values:

- L2 `gasLimit` and fee fields are constrained by the VM and bootloader to reasonable ranges (e.g. fitting in native gas capacities, batch limits).
- With realistic limits, the product will never approach 2²⁵⁶, so no overflow occurs.

But this safety is enforced outside these contracts.

**Recommendation**

- Keep the existing off‑chain/VM bounds, but document them explicitly in the spec as a *security requirement* (e.g. “`maxFeePerGas * gasLimit` MUST fit into 256 bits” or stricter numeric limits).
- Optionally add an on‑chain sanity check to make the invariant self‑contained, for example:

  ```solidity
  function _mulFee(uint256 a, uint256 b) internal pure returns (uint256) {
      if (a == 0) return 0;
      uint256 c = a * b;
      if (c / a != b) revert Overflow();
      return c;
  }
  ```

  and use `_mulFee` instead of raw multiplication in `payToTheBootloader` and `totalRequiredBalance`.

  This would turn a silent under‑charge into an explicit revert if someone ever relaxes the VM‑side bounds.


### 3. `forcedSload` can permanently alter account state if misused in future upgrades  
**Severity**: Informational  
**Impact**: The `SystemContractHelper.forcedSload` utility force‑deploys temporary bytecode to arbitrary addresses and then restores the previous bytecode. As documented, this overwrites `AccountInfo` (nonce ordering / AA version) and relies on the previous code hash being “known”. A mistaken use of `forcedSload` against a custom account address in an upgrade script could silently change its AA settings or brick it.

**Details**

`forcedSload`:

```solidity
// SystemContractHelper.sol
function forcedSload(address _addr, bytes32 _key) internal returns (bytes32 result) {
    bytes32 sloadContractBytecodeHash;
    address sloadContractAddress = SLOAD_CONTRACT_ADDRESS;
    assembly {
        sloadContractBytecodeHash := extcodehash(sloadContractAddress)
    }

    if (KNOWN_CODE_STORAGE_CONTRACT.getMarker(sloadContractBytecodeHash) == 0) {
        revert SloadContractBytecodeUnknown();
    }

    bytes32 previoushHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(_addr);

    // Double-check previous bytecode is known
    if (KNOWN_CODE_STORAGE_CONTRACT.getMarker(previoushHash) == 0) {
        revert PreviousBytecodeUnknown();
    }

    // 1. Force-deploy SloadContract
    forceDeployNoConstructor(_addr, sloadContractBytecodeHash);
    // 2. Read storage
    result = SloadContract(_addr).sload(_key);
    // 3. Force-deploy previous bytecode back
    forceDeployNoConstructor(_addr, previoushHash);
}
```

`forceDeployNoConstructor` uses `ContractDeployer.forceDeployOnAddresses` with `_callConstructor = false`. That in turn:

- Calls `_ensureBytecodeIsKnown` on the new bytecode.
- Writes a new `AccountInfo` for `_addr`:

  ```solidity
  AccountInfo memory newAccountInfo;
  newAccountInfo.supportedAAVersion = AccountAbstractionVersion.None;
  newAccountInfo.nonceOrdering = AccountNonceOrdering.KeyedSequential;
  _storeAccountInfo(_deployment.newAddress, newAccountInfo);
  ```

This means that after `forcedSload` returns, the account at `_addr` will have:

- Its original bytecode restored.
- But its `AccountInfo` reset to `(supportedAAVersion = None, nonceOrdering = KeyedSequential)`, regardless of what it had before.

The comment in `forcedSload` acknowledges this:

> “Note, that the function will overwrite the account states of the `_addr`, i.e. this function should NEVER be used against custom accounts.”

Currently, I don’t see any usage of `forcedSload` in the provided contracts, so this is only a latent risk for future upgrade logic.

**Recommendation**

- Keep `forcedSload` restricted to upgrade tooling and document *very clearly* that it must only ever target:
  - system contracts, or
  - non‑account contracts where `AccountInfo` is irrelevant.
- If you plan to call it from any new system contract, consider:
  - Asserting that `extendedAccountVersion(_addr) == AccountAbstractionVersion.None` (i.e. not an account), or
  - Asserting `NONCE_HOLDER_SYSTEM_CONTRACT.getRawNonce(_addr) == 0` to avoid touching live accounts.
- Optionally, extend `ContractDeployer.forceDeployOnAddress` with a flag to *preserve* existing `AccountInfo` when doing a no‑constructor force‑deploy, and use that path for `forcedSload`. This would reduce the blast radius if someone accidentally targets an AA contract.


## Open issues / areas needing more context

These are not reported as vulnerabilities because they depend on components outside the provided scope. To fully validate them, one would need to inspect the VM and bootloader implementation:

1. **VM semantics for system opcodes and `isSystemCall`**  
   - Confirm at VM level that:
     - Calls to `SYSTEM_CALL_CALL_ADDRESS`, `SYSTEM_CALL_BY_REF_CALL_ADDRESS`, `MIMIC_CALL_CALL_ADDRESS`, etc., revert or are disabled for non‑kernel contracts.
     - The `isSystemCall` flag observed via `SystemContractHelper.isSystemCall()` cannot be set by user‑space code.
   - Relevant files: VM opcode definitions and bootloader code (Yul/assembly), any docs describing kernel/user mode separation.

2. **Bootloader bounds on transaction gas fields**  
   - Verify that `Transaction.gasLimit` and `maxFeePerGas` are bounded such that `gasLimit * maxFeePerGas < 2²⁵⁶` always holds before these values reach `TransactionHelper.payToTheBootloader` and `totalRequiredBalance`.
   - Relevant files: bootloader implementation and transaction parsing / validation logic.

3. **DA validator interface and operator input format**  
   - `L1Messenger.publishPubdataAndClearState` and `L2DAValidator._validateOperatorData` assume a specific ABI layout for `_operatorInput` and `_operatorData`. A mismatch between those expectations and the actual L2DA validator contract on L1/L2 could lead to unintended behavior (e.g. some bytes not being committed).  
   - Relevant files: `IL2DAValidator` interface implementation(s), especially the concrete L2DA validator contract used in production.

Within the provided scope, the system contracts appear robust and carefully cross‑checked against the documented design, with no concrete exploitable issues identified.