## Intro

The virtual machine we are currently using (EraVM) is different from the EVM. It has a different set of instructions and is different in design. For this reason, although Solidity and Vyper can be compiled to bytecode for EraVM, there are a number of peculiarities and differences in behavior. This sometimes forces developers to make changes in smart contracts and worsens DevEx due to differences in tooling.

As an option to unblock developers that depend on EVM bytecode support, we’ve added EVM execution mode as an emulation on top of EraVM:

- The core of the system is still EraVM. it will still be possible to deploy native EraVM contracts and the main unit of gas will remain EraVM one (technically we will call it ***ergs*** further so as not to confuse it with EVM gas).
- However, it is also possible to deploy and execute EVM contracts. These contracts’ bytecode hash is marked with a special marker. Whenever an EVM bytecode is invoked, instead of decommiting and executing EraVM bytecode, virtual machine uses fixed and predefined EvmEmulator bytecode. Internally, this emulator loads, interprets and executes EVM bytecode in accordance with the EVM rules (as close as possible).

The main invariant that we aim to preserve:

<aside>
💡

Behavior inside emulated EVM environment (i.e. not only within one contract, but during any sort of EVM <> EVM contracts interaction chain) is exactly same as it would’ve been on widespread EVM implementation (Geth, REVM, etc.)

</aside>

Note, that during EraVM <> EVM or EVM <> EraVM contract interaction can be different, but it is expected that this interaction does not break major security invariants. 

<aside>
💡

The EVM environment is agnostic about EraVM

</aside>

> ⚠️ This document is meant to cover the high level of the EVM emulation as well as some of its rough edges and is not meant to be a full specification of it. 

A proper understanding of the EVM emulation requires reading the corresponding comments in the contracts code.
> 

**era-contracts** branch: [**stable/evm-emulator**](https://github.com/matter-labs/era-contracts/tree/stable/evm-emulator)

## Prerequisites

This document requires that the reader is aware of how zkSync Era works internally *including* 1.5.0 upgrade. 

General docs: https://docs.zksync.io/build/developer-reference

Legacy docs for the 1.5.0 upgrade here: https://github.com/code-423n4/2024-03-zksync/tree/main/docs

<aside>
💡

Important: any kind of EVM_STIPEND is expected to be removed from EraVM with the launch of EVM emulator functionality

</aside>

The emulator related changes actively use some features of EraVM, including:

- **Kernel space and user space addresses.** Everything with address < 2^16 (kernel space) is considered as system contract with some special capabilities.
- **Difference between system and non-system calls**. Call to the contract in kernel space can be explicitly marked as system call. Some methods in system contracts allow only system calls to prevent accidental use of various system functions.
- **Fat pointers**. EraVM has different memory model, actively using pointers instead of copying memory. So calldata / returndata usually not a copy, but just sort of immutable pointer to some region of memory. These pointers can be manipulated (but not the memory behind them) - for example, by shrinking the memory area or clearing the pointer completely.
- **Verbatim instructions and other compiler-specific instructions.** In some cases we want to use some EraVM-specific functionality in Solidity or Yul. These languages do not have suitable instructions, and for this reason we use `verbatim` instructions (**note**: it has different meaning compared to usual Yul) or pseudocalls to predefined system addresses. In both cases, our compiler replaces these instructions with the corresponding functionality.

The target version of our EVM is **Cancun.**

[EVM emulator: differences from EVM  (Cancun)](https://www.notion.so/EVM-emulator-differences-from-EVM-Cancun-10ba48363f2380c1a112e29f1a03e88c?pvs=21) 

# Deploying EVM contract

EVM contracts can be deployed from EraVM environment using **system** call to the following functions in ContractDeployer system contract:

- `createEVM` - `CREATE`-like behavior
- `create2EVM`  - `CREATE2`-like behavior

They use the same address derivation flows as EVM analogs. To derive the deployed contract’s address for EOAs we use the main nonce for this operation, while for contracts we use their deployment nonce. You can read more about the two types of nonces in the [NonceHolder system contract’s documentation](https://docs.zksync.io/build/developer-reference/era-contracts/system-contracts#nonceholder).

<aside>
💡

Note, that these two functions are not used (and can’t be used!) from `EvmEmulator` itself. EVM smart contracts can’t perform **system** calls. 

</aside>

EvmEmulator internally uses `precreateEvmAccountFromEmulator` and `createEvmFromEmulator` functions to guarantee the same creation flow as in EVM.

Once the address for the deployed EVM contract is derived, next steps are:

1. Set the dummy bytecode hash, marked as EVM one, onto the derived address. This will ensure that the `EvmEmulator` bytecode will be invoked during the constructor call.
2. Execute the constructor branch of the `EvmEmulator`. After obtaining the initCode from the calldata, the interpreter interprets it as a normal EVM bytecode.
3. EvmEmulator constructor returns to the ContractDeployer EVM gas left and final bytecode, which should be deployed.

After creation, the `deployedBytecode` is saved and any call to the created contract will use the EVM emulator, which loads and executes the corresponding EVM bytecode.

### New type of code hash

In EraVM we use special *versioned hash* format for interacting with bytecodes: it is a 32-byte value with the following structure (indexed in bytes):

- hash[0] — version (0x01 for EraVM)
- hash[1] — whether the contract is being constructed
- hash[2..3] — big endian length of the bytecode in **32-byte words**. This number must be odd.
- hash[4..31] — the last 28 bytes of the sha256 hash of the bytecode.

For each native EraVM contract with address `A` this version hash is stored under the key `A` inside the `AccountCodeStorage` system contract. Whenever a call is performed to an address `A`, the EraVM will read its versioned bytecode hash, check its correct versioned format and “unpack” the bytecode that corresponds to that versioned hash inside the code memory page.

 Also that versioned hash value is used as `extcodehash` value in EraVM context.

In order to support EVM bytecode, we introduced a new versioned hash format for EVM version (0x02):

- hash[0] — version (0x02 for EVM)
- hash[1] — whether the contract is being constructed
- hash[2..3] — big endian length of the **padded** (more info in the next section) bytecode in **bytes**.
- hash[4..31] — the last 28 bytes of the sha256 hash of the bytecode.

Versioned hash value is **not** used as `extcodehash` value of EVM contracts in EVM context.

Besides the version, these formats are different in the fact that the first version stored the length of the bytecode in *32-byte words,* while the second one does it *bytes*. This was done mostly for historical reasons during the development of this version. However, it perfectly fits the maximal allowed bytecode size for an EVM contract (i.e. 24,576 bytes can easily fit into the 2^16 - 1 bytes).

EraVM now has the following logic whenever a contract with address `A` is called: 

The first 3 steps are the same as pre-EVM emulator:

1. It reads the versioned hash of the bytecode under the key `A` inside the AccountCodeStorage system contract.
2. If it is empty, it invokes DefaultAccount.
3. If it has version 1, it treats it as a native EraVM contract, and uses the preimage for this versioned hash as EraVM bytecode for the contract.

But now we have the new path:

1. If it has version 2, it interprets it as a EVM contract, and uses the bytecode of `EvmEmulator` as the EraVM bytecode of the contract. 

Note, that while for native contracts the knowledge of the preimage for the versioned hash is crucial (since it is *the* bytecode that will be used), for bytecodes with version 2 it does not really matter since `EvmEmulator` is the bytecode that will be used. This is why when we are constructing a contract, we put a temporary “dummy” versioned hash, the job of which is only to ensure that the `EvmEmulator` is the one executing its logic.

### Prefixing and padding the EVM bytecode

Note, that due to certain crypto side limitations, it is required that the length of the bytecode has an odd number of 32-byte words, or, in other words, it is congruent to 32 (mod 64). For native contracts (version 1) this is enforced during deployment (it is not allowed to store any bytecodes with non-odd number of words). 

While the knowledge of the preimage of the versioned hash is not *strictly* needed to execute an EVM contract, in order to obtain EVM bytecodes in an efficient manner we use  `CodeOracle` precompile. It can be read more on in the original EraVM@1.5.0 docs linked in the prerequisites, but it is a small precompile that, given a versioned hash, can return the preimage to it. For `CodeOracle` to work the same invariant should be held there.

While for EraVM zksolc compiler always produces bytecodes of correct length, for EVM contracts, the situation is a bit harder. We need to both:

- Store the padded value under the hash
- Be able to determine the correct bytecode size for the purposes of `extcodecopy` / code interpretation, etc.

That’s why instead of the “original” EVM bytecodes, under the second versioned hash we store the following:

- first 32 bytes: ABI-encoded length of the “original” EVM bytecode in bytes.
- Next, there is “original” EVM bytecode.
- Then, there is a zero pad to ensure that the full preimage has odd number of 32-byte words.

### Support for null `to` address in transactions

Before we did not allow `null` to be a valid address for type 0-2 transactions. This was not needed since EVM-like CREATE was not supported. With EVM emulator project, we allow CREATE operations from EOA, similar to Ethereum. These have `_transaction.reserved[1]` field as non-zero.

# EraVM → EVM calls overview

Whenever a EraVM contract calls an EVM one (note that, the first contract to be ever executed is bootloader written in EraVM code, so execution of EVM contracts always starts by being called by a EraVM one), the following steps happen:

1. Once the EraVM sees that the callee has versioned hash with version 2, it uses `EvmEmulator` as the “EraVM” bytecode for this contract’s frame. Note, that `this` address is the address of the contract itself, i.e. all the `sstore` operations will be performed against the storage of the interpreted contract.
2. The only public function provided by `EvmEmulator` is fallback, so the execution will start there. 
3. We calculate the amount of EVM gas that is given to this frame. Note, that since each EVM opcode has to be emulated by EraVM, each EVM gas necessarily costs several EraVM one (ergs). We currently use a linear ratio to calculate the amount of received EVM gas.
4. Then, the simulation starts as usual and the `returndata` is returned via standard EraVM means.

# EVM → EraVM calls overview

Whenever a EVM contract calls an EraVM one it is treated as simple native EraVM call. The EVM gas passed from EVM environment is converted into ergs using a fixed ratio.

# Ensuring the same behavior within EVM context.

In the previous sections we’ve discussed on how to deploy an EVM contract and how to call one. Next we will discuss some special aspects of emulation.

<aside>
💡

remember, that our EVM is emulated and for each EVM frame there is a corresponding EraVM one

</aside>

## Static calls

The `isStatic` context is set off by EraVM for calls to EVM contracts. Emulator gets info wether context is static or non-static from call flags. This is needed because `EvmGasManager` need to perform writes to transient storage to emulate cold/warm access mechanics for accounts and storage slots. 

Thus, it is entirely up to the emulator to ensure that no other state changes occur in the static execution mode.

## Context parameters

While most of the context parameters (`this`/`msg.sender`/`msg.value`, etc) are used as is, some have to be explicitly maintained by the `EvmEmulator`:

- `gas` (as EVM gas rules need to be applied)
- `is_static` (more on it in the section about static context)
- The entire set of warm/cold slots and addresses is maintained by the `EvmGasManager` system contract.

## Managing storage

For managing storage we reuse the same primitivies that EraVM provides:

- `SSTORE`/`SLOAD` , `TSTORE`/`TLOAD` are done using the same opcodes as EraVM
- Whenever there is a need to revert a frame, we reuse the same `REVERT` opcode as used by EraVM.

## `EvmGasManager`

### Managing hot/cold storage slots & accounts

Whenever an account is accessed for the first time on EVM, the users are charged extra for the I/O costs incurred by it. Also, additional costs are incurred for state growth (when a slot goes from 0 to some other values). 

To support the same behavior as on EVM, we maintain a registry of whether a slot or account is warm or cold. This registry is located in the `EvmGasManager` system contract. In order to ensure that this registry gets erased after each transaction, transient storage is used for it. 

By default, the following addresses are considered hot:

- Called EVM contract
- Msg.sender (caller of the EVM contract)
- tx.origin
- coinbase
- precompiles

### EVMFrames

As already mentioned, for warm/cold storage/account management to work, the `isStatic` context has to be put off. However, we need to somehow preserve the knowledge about the fact that the context is static. Also, we need to ensure that EVM contracts get the exact correct gas amount if called by an EVM contract.

Thus, whenever an EVM call happens, the following functions in `EvmGasManager` are called by the emulator:

1. (Parent frame, before the call) `EvmGasManager.pushEVMFrame`. It sets info about new EVM frame to the transient storage including amount of EVM `gas` in that frame as well as the `isStatic` context.
2. (Child frame, start of the execution) Whenever an EVM contract is called, it calls`EvmGasManager.consumeEvmFrame`. If new EVM frame was pushed previously, it will return info about that frame and mark it as consumed. Returned info contains EVM gas and `isStatic` flag.
3. In case of revert. (Parent frame, right after the call) When an EVM call finishes with revert, `EvmGasManager.resetEVMFrame` is used. Note, that if there is a revert of the parent frame for some reason before/during `EvmGasManager.resetEVMFrame`, the frame will be “popped” implicitly since all the changes of the parent frame will be reverted, including `EvmGasManager.pushEVMFrame`.

Just like the registry of hot/cold accounts, transient storage is used there. Here it is less of a requirement, but it helps to ensure that the frames will be cleared after the transaction just in case.

## Calldata & returndata

### EVM <> EraVM

EraVM contracts are expected to know nothing about the EVM simulation and so when a EraVM contract calls an EVM one, it provides just normal calldata “as-is”. The same happens when an EVM contract finishes the call when the caller was a EraVM contract: the returndata is returned “as-is” without any further modifications.

### EVM <> EVM

Whenever an EVM contract calls another one, it passes the calldata “as-is”. The “correct” EVM `gas` and the `isStatic` flags are passed via the EVMFrames inside the `EVMGasManager` as mentioned above.

However, returning data is more complicated. Whenever an EVM contract needs to return the data and the caller was another EVM contract, the tuple of `(gas_left, true_returndata)` is returned.

This raises a question: why can’t we use the same approach in both cases?

1. **Why can’t we use `EVMGasManager` for returndata?**

Let’s imagine that we decide to use **`EVMGasManager`** to pass the returned gas. At the end of the execution, the child frame calls the **`EVMGasManager`** to supply the returned gas.

Let’s say that we need to execute the `REVERT` EVM opcode. Since we rely on using the standard EraVM frame revert to roll back the state changes, it will also roll back the changes made to the **`EVMGasManager`**. This could be handled in some ways, but current solution is simpler and safer.

2. **Okay, why can’t we pass `gas` and `isStatic` inside `calldata` then? Similar to how `gas` is passed inside returndata.**

Here the answer is more subtle. Our EVM contract needs to somehow know whether the first 32 bytes of the calldata correspond to `gas` or they are just part of calldata during EraVM → EVM call. In other words, we need to somehow *reliably* detect whether the true caller is an EVM or a EraVM contract. 

So, while this again could be handled in some ways, we would still need to use  **`EVMGasManager`** to detect whether the “true” caller is an EVM one, i.e. at least via a simple boolean variable. Since we already need the **`EVMGasManager`**, ****we could just as well use it to pass the `gas`/`isStatic` variables. This makes code easier since it allows us to reuse the `calldatacopy/calldataload` from EraVM.

## Out-of-ergs situation

The actual cost of executing instructions differs from the fixed ratio between the EVM gas and the EraVM gas. For this reason, situations are possible in which emulator has enough EVM gas to continue execution, but encounters `out-of-ergs` panic. In this case we simply propagate special internal kind of panic and revert the **whole** EVM frames chain.

<aside>
💡

EVM emulation can only be executed completely, up to returning from the EVM context (incl. EVM reverts), or completely rolled back.

</aside>

This does not happen when calling native contracts. For this reason, the possible `out-of-ergs` panic must be taken into account when calling native contracts from EVM environment. Technically, this problem is one of the versions of classic gas-griefing vulnerabilities in EVM contracts, if not handled appropriately.

## Caveats about EVM contract deployment

We want to support the same logic for EVM contract deployment as Ethereum. This, for instance, includes that a failed deploy should still increase the nonce of a contract, which is not the case on Era EraVM: https://docs.zksync.io/build/developer-reference/differences-with-ethereum.html#nonces.

For this, for EVM<>EVM deployments have two big steps: precheck and deploy. 

The flow of EVM <> EVM deployment is the following:

1.  The EVM emulator checks the memory offsets are valid. Also it checks that size of initCode is valid and charges dynamic gas costs.  In case of error creator frame is reverted consuming all remaining EVM gas.
2. The EVM emulator checks that the `value` is valid. Otherwise creation considered as failed, all passed EVM gas refunded. Caller frame is not reverted.
3. The EVM emulator calls the `ContractDeployer.precreateEvmAccountFromEmulator`. This call derives new contract address and performs collision check. If it fails, creation is considered as failed, all passed EVM gas consumed. Caller frame is not reverted.
4. The EVM emulator creates a new `EVMFrame`, and calls the `ContractDeployer.createEvmFromEmulator`. This call should fail only if constructor of the new contract was reverted.
5. The `ContractDeployer` sets a dummy version 2 hash on the deployed address to ensure that when it will be called, the `EvmEmulator` will be activated.
6. The `EvmEmulator`'s constructor is invoked. The initCode is passed inside the calldata. 

Then, there are three cases

1. If the execution of the initCode is successful, the `EvmEmulator`  will pad the new bytecode to the correct form for the code oracle and return to the ContractDeployer system contract together with remaining EVM gas. This will publish the deployed contract’s bytecode and set the correct code hash for the account.
2. If the execution is not successful, the standard `revert` will be used and propagated. If the deployer is an EVM contract, the pair of `(gas_left, returndata)` will be returned.
3. If the execution failed due to `out-of-ergs`, aborting panic will be propagated.

# Notes on the architecture of the EvmEmulator

## Memory layout

The EVM emulator has the following areas in memory:

- First 23 slots are used as scratch space. They are dedicated for temporary data, e.g. when emulator needs to make a call to some other contract.
- Next 9 slots are used to cache fixed context values.
- Next slot is used to store the size of the last returndata
- Next 1024 slots are dedicated for the EVM stack.
- Next slot is used to store the bytecode size of executing contract
- Next `MAX_POSSIBLE_ACTIVE_BYTECODE` bytes are used to store active bytecode. This value is 24576 for deployed contracts and 24576*2 for initCode in constructor.
- Next slot is empty. It is needed to simplify PUSH N opcodes
- Next slot is used to store the size of memory used in EVM
- All the memory after that is dedicated to the EVM memory, i.e. all `mload/mstore` operations that are done by the user are performed at that location.

For returndata we keep returned fat pointer as active and copy from it if needed.

## Managing returndata & calldata

For calldata we just reuse the standard calldata available inside the interpreter.

However for returndata the situation is a bit harder. Let’s imagine the following scenario:

- The EVM contract performs a call to some contract. Now the returndata is `R`.
- Then the user tries to read a storage slot. This means that the interpreter will have to call `EvmGasManager.warmSlot`. Now, as far as the EraVM code of the interpreter is concerned, the returndata is `R2`.

If a user inside the EVM will ask to provide the returndata, we need to provide `R` and not `R2`. That’s why we use the active pointer feature of the zksolc compiler and we store the “correct” EVM returndata in the active pointer, allowing us to ensure that the returndata will always behave the same as on EVM.

## Aborting the whole EVM execution frames chain

If any EVM emulator frame returns with unexpected amount of returndata (e.g. `revert(0, 0)` or `out-of-ergs`) it will be treated by caller EVM frame as abort signal and propagated. Thus, the whole EVM calls chain should revert.

# Limitations

## EraVM <> EVM interaction

Calls between EraVM and EVM calls are supported, but delegatecalls are not. Since it would compromise the features that only should be allowed for the interpreter itself (e.g. warming slots). Our VM limitations doesn’t allow us to enable cross-VM delegate calls at this step.