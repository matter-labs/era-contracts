## Security issues

### 1. Missing JUMPDEST Validation allows Control Flow Hijacking
- **Severity**: High
- **Impact**: Arbitrary code execution and control flow bypass within the emulator. An attacker can deploy bytecode where a `PUSH` instruction contains the byte `0x5B` (JUMPDEST) as data, and then perform a `JUMP` to that offset. This causes the emulator to interpret the subsequent bytes of the PUSH data as executable opcodes, bypassing the intended control flow and static analysis guarantees of the EVM.
- **Evidence**:
  In `system-contracts/contracts/EvmEmulator.yul`, the `OP_JUMP` (0x56) and `OP_JUMPI` (0x57) implementations explicitly state they lack full validation:
  ```yul
  case 0x56 { // OP_JUMP
      // ...
      // NOTE: We don't currently do full jumpdest validation
      // (i.e. validating a jumpdest isn't in PUSH data)
      
      // ...
      ip := counter

      // Check next opcode is JUMPDEST
      let nextOpcode := $llvm_AlwaysInline_llvm$_readIP(ip)
      if iszero(eq(nextOpcode, 0x5B)) {
          panic()
      }

      // execute JUMPDEST immediately
      ip := add(ip, 1)
  }
  ```
  The code checks if the destination byte is `0x5B` but fails to verify if that byte is a valid instruction boundary (i.e., not inside the immediate data of a previous `PUSH` instruction).

### 2. Non-Standard ModExp Precompile Input Size Limit causing DoS
- **Severity**: Medium
- **Impact**: The `ModExp` (0x05) precompile implementation restricts input parameters (`B`, `E`, `M`) to a maximum of 32 bytes (256 bits). Standard EVM applications, particularly those using RSA signatures (requiring 2048-bit or larger inputs), will fail. This creates a Denial of Service for any contract migrating to ZKsync that relies on standard cryptographic verification (e.g., DNSSEC, specific bridges).
- **Evidence**:
  In `system-contracts/contracts/EvmEmulator.yul`, function `modexpGasCost`:
  ```yul
  function MAX_MODEXP_INPUT_FIELD_SIZE() -> ret {
      ret := 32 // 256 bits
  }
  
  // ...
  
  let inputIsTooBig := or(
      gt(bSize, MAX_MODEXP_INPUT_FIELD_SIZE()), 
      or(gt(eSize, MAX_MODEXP_INPUT_FIELD_SIZE()), gt(mSize, MAX_MODEXP_INPUT_FIELD_SIZE()))
  )

  // ...

  switch inputIsTooBig
  case 1 {
      gasToCharge := MAX_UINT64() // Skip calculation, not supported or unpayable
  }
  ```
  If `gasToCharge` is set to `MAX_UINT64()`, the `callPrecompile` function will effectively consume all gas and return empty data (treated as failure/OOG), making the call fail for inputs > 32 bytes.

### 3. Unsupported Precompiles Return Success (Silent Failure)
- **Severity**: Medium
- **Impact**: Calls to unsupported precompiles (`RIPEMD-160`, `blake2f`, `kzg_point_evaluation`) are assigned a gas cost of 0 and executed as standard calls. Since these addresses (0x03, 0x09, 0x0A) likely do not have associated bytecode in EraVM, the calls return "success" with empty return data. This deviates from EVM behavior where these are active precompiles. Contracts relying on these hash functions (e.g., for data verification) will receive zeroed/empty results instead of the expected hash, which may lead to incorrect logic execution (e.g., treating a hash mismatch as a match if the comparison is against zero) or silent data corruption.
- **Evidence**:
  In `system-contracts/contracts/EvmEmulator.yul`, function `getGasForPrecompiles`:
  ```yul
  case 0x03 { // RIPEMD-160
      // We do not support RIPEMD-160
      gasToCharge := 0
  }
  // ...
  case 0x09 { // blake2f
      // We do not support blake2f
      gasToCharge := 0
  }
  case 0x0a { // kzg point evaluation
      // We do not support kzg point evaluation
      gasToCharge := 0
  }
  ```
  The `callPrecompile` function will then proceed to `rawCall` these addresses with the user provided gas (since `gasToPass < 0` is false). If the addresses are empty, the call succeeds with 0 output bytes.