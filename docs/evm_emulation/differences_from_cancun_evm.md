## General differences from Ethereum

- **We use our native gas (ergs) as input for transactions**.
- `JUMPDEST` analysis is simplified. We do not check that it is not part of `PUSH` instruction.
- During creation of EVM contract by EOA or EraVM contract, we do not charge additional `2` gas for every 32-byte chunk of `initcode` as specified in [EIP-3860](https://eips.ethereum.org/EIPS/eip-3860) (since we do not perform `JUMPDEST` analysis). This cost **is** charged if contract is created by another EVM contract (to keep gas equivalence).
- No force of call stack depth limit. It is implicitly implemented by 63/64 gas rule.
- We do not support access lists (EIP-2930)
- Our warm/cold accounts logic is a little bit different: Only those contracts that are accessed from an EVM environment become warm (including origin, sender, coinbase, precompiles). Anything that happens outside the EVM does not affect the warm/cold status of the accounts for EVM.
- When deploying contracts we do not destroy newly created account storage.
- We do not implement the gas refunds logic from EVM.
- Our “Intristic gas costs” are different from EVM.
- If the deployer's nonce is overflowed during contract deployment, we consume all passed gas. EVM refunds all passed gas to the caller frame.
- Nonces are limited by size of `u128`, not `u64`
- `GASLIMIT` opcode returns value in ergs (EraVM gas), not in EVM gas.
- `DELEGATECALL` to native EraVM contracts will be reverted.
- Calls to empty addresses in kernel space (address < 2^16) will fail.
- We do not charge EVM gas for tx calldata

### Unsupported opcodes

- CALLCODE
- SELFDESTRUCT
- BLOBHASH
- BLOBBASEFEE

### Precompiles

| **Precompile** | **Address** | **Supported using EVM emulator** |
| --- | --- | --- |
| ecRecover | 0x01 | **✅** |
| SHA2-256 | 0x02 | **✅** |
| RIPEMD-160 | 0x03 | **❌** |
| identity | 0x04 | **✅** |
| modexp | 0x05 | **❌ (WIP)** |
| ecAdd | 0x06 | **✅** |
| ecMul | 0x07 | **✅** |
| ecPairing | 0x08 | **✅** |
| blake2f | 0x09 | **❌** |
| kzg point evaluation | 0x0a | **❌** |