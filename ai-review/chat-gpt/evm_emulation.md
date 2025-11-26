## Security issues

No security issues with exploitable impact were identified in the reviewed `EvmEmulator` and `EvmGasManager` contracts, under the assumptions listed below. The emulator and gas manager appear internally consistent and aligned with the documented design (including known intentional deviations from strict EVM equivalence).

---

## Open issues / assumptions

The following points are not vulnerabilities in the code shown, but are *critical assumptions* for its security. Validating them would require additional sources beyond this scope:

1. **Correct tagging of “EVM contracts” via `versionedBytecodeHash`**

   - Code paths that gate privileged gas-manager functionality rely on treating an account as an EVM contract iff:
     ```yul
     let versionedCodeHash := $llvm_AlwaysInline_llvm$__getRawSenderCodeHash()
     isEVM := eq(shr(248, versionedCodeHash), 2)
     ```
   - This is used in `EvmGasManager.$llvm_AlwaysInline_llvm$_onlyEvmSystemCall()` to restrict:
     - `warmAccount` (selector 0)
     - `warmSlot` (selector 2)
     - `pushEVMFrame` (selector 3)
     - `consumeEvmFrame` (selector 4)
     - `resetEVMFrame` (selector 5)
   - **Assumption:**  
     Only correctly constructed EVM contracts are ever assigned `version == 2` in `versionedCodeHash`, and no other address can obtain this version via `AccountCodeStorage` / `ContractDeployer`.
   - **Required sources to validate:**
     - `AccountCodeStorage` system contract
     - `ContractDeployer` system contract
     - Any kernel logic that writes versioned bytecode hashes

2. **Semantics of `system_call`, `raw_call`, and `call_flags`**

   - `EvmGasManager` enforces that certain entry points can only be called via a *system* call:
     ```yul
     let callFlags := verbatim_0i_1o("get_global::call_flags")
     let notSystemCall := iszero(and(callFlags, 2))
     if notSystemCall { revert(...) }
     ```
   - The emulator uses the low-level verbatim opcodes:
     - `verbatim_6i_1o("system_call", ...)`
     - `verbatim_4i_1o("raw_call", ...)`
   - **Assumption:**  
     User / application contracts cannot craft `system_call` invocations or arbitrarily manipulate `call_flags` to bypass `_onlyEvmSystemCall`. Only kernel/system code (including the emulator) can do this.
   - **Required sources to validate:**
     - VM / assembler specification for `system_call`, `raw_call`, and `get_global::call_flags`
     - Bootloader and any kernel components that might issue such calls

3. **Correct transient storage semantics for `tstore` / `tload`**

   - `EvmGasManager` uses `tstore`/`tload` for:
     - Account warmth (`IS_ACCOUNT_WARM_PREFIX`)
     - Slot warmth and original value caching (`IS_SLOT_WARM_PREFIX`)
     - EVM frame metadata (`EVM_GAS_SLOT`, `EVM_AUX_DATA_SLOT`)
   - Security of gas accounting assumes:
     - Transient storage is **transaction-local**.
     - Transient storage changes roll back on revert/panic in the same way as normal storage, so failed calls cannot leave stale EVM-frame or warmness state behind.
   - **Required sources to validate:**
     - VM semantics of `tstore`/`tload` and their interaction with revert/panic
     - Any other system contracts using the same transient slots `4` and `5` (for EVM gas frame)

4. **Correct and safe behavior of other system contracts**

   The emulator trusts several system contracts:

   - `ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT` (0x8002)
   - `NONCE_HOLDER_SYSTEM_CONTRACT` (0x8003)
   - `DEPLOYER_SYSTEM_CONTRACT` (0x8006)
   - `MSG_VALUE_SYSTEM_CONTRACT` (0x8009)
   - `CODE_ORACLE_SYSTEM_CONTRACT` (0x8012)
   - `EVM_HASHES_STORAGE_CONTRACT` (0x8015)

   Misbehavior in these could break EVM ↔ EraVM equivalence, gas accounting, or value-transfer correctness, even if the emulator logic is sound.

   - **Required sources to validate:**
     - Implementations of the above system contracts
     - Their documented invariants (e.g. that `MSG_VALUE_SYSTEM_CONTRACT` enforces `msg.value` correctness)

5. **Intentional EVM-spec deviations (documented, not bugs)**

   These are worth being aware of when reasoning about EVM equivalence, but are explicitly documented in the provided specs:

   - **Deploy-time `CALLDATA` opcodes return zero**  
     In `EvmEmulator` (constructor side):
     ```yul
     function $llvm_AlwaysInline_llvm$_calldatasize() -> size { size := 0 }
     function $llvm_AlwaysInline_llvm$_calldatacopy(...) { $llvm_AlwaysInline_llvm$_memsetToZero(...) }
     function $llvm_AlwaysInline_llvm$_calldataload(...) -> res { res := 0 }
     ```
     Matches compiler docs: these opcodes are treated as zero in deploy code.  
     Contracts whose constructors explicitly rely on EVM’s deploy-time `CALLDATA` will not behave the same, but mainstream Solidity/Vyper do not generate such patterns.

   - **No full JUMPDEST-in-PUSH-data validation**  
     The emulator only checks that the target byte holds opcode `0x5B` and is within pointer bounds:
     ```yul
     // NOTE: We don't currently do full jumpdest validation
     let nextOpcode := $llvm_AlwaysInline_llvm$_readIP(ip)
     if iszero(eq(nextOpcode, 0x5B)) { panic() }
     ```
     It does not precompute “valid jumpdests” excluding PUSH data, unlike typical EVM implementations. This can cause divergence for hand-crafted bytecode that jumps into PUSH immediates, but is unlikely to be hit by compiler-generated code.

   - **Unsupported precompiles mapped to non-standard behavior**  
     Addresses `0x03` (RIPEMD-160), `0x09` (blake2f), and `0x0a` (KZG point evaluation) are not treated as EVM precompiles:
     ```yul
     case 0x03 { gasToCharge := 0 } // not supported
     case 0x09 { gasToCharge := 0 } // not supported
     case 0x0a { gasToCharge := 0 } // not supported
     ```
     Calls to these addresses are treated as normal contracts (or “empty” ones) rather than precompiles. This is intentional per docs but breaks strict precompile equivalence.

These assumptions should be explicitly documented at the protocol / system-contract level. If any of them are violated, the emulator and gas manager could become a source of subtle consensus or security issues, even though the code within this scope is internally sound.