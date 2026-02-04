//! Minimal example: generate a random transaction and execute it through the bootloader.
//!
//! Analogous to `test_default_aa_interaction` from zksync-era's multivm test suite,
//! adapted for the bootloader test infrastructure.
//!
//! Run with: cargo run -- --example-tx

use std::env;

use zksync_contracts::{ContractLanguage, SystemContractCode, SystemContractsRepo};
use zksync_multivm::interface::{
    InspectExecutionMode, L1BatchEnv, L2BlockEnv, SystemEnv, TxExecutionMode, VmFactory,
    VmInterface,
};
use zksync_multivm::vm_latest::{HistoryDisabled, Vm};
use zksync_state::interface::{
    InMemoryStorage, StorageView, WriteStorage, IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID,
};
use zksync_types::bytecode::BytecodeHash;
use zksync_types::fee::Fee;
use zksync_types::fee_model::BatchFeeInput;
use zksync_types::l2::L2Tx;
use zksync_types::system_contracts::get_system_smart_contracts_from_dir;
use zksync_types::transaction_request::PaymasterParams;
use zksync_types::{
    block::L2BlockHasher, get_address_mapping_key, settlement::SettlementLayer, u256_to_h256,
    AccountTreeId, Address, K256PrivateKey, L1BatchNumber, L2BlockNumber, L2ChainId,
    L2_BASE_TOKEN_ADDRESS, Nonce, SLChainId, StorageKey, Transaction, U256,
};

fn get_balance_key(address: Address) -> StorageKey {
    let account_id = AccountTreeId::new(L2_BASE_TOKEN_ADDRESS);
    let key = get_address_mapping_key(&address, Default::default());
    StorageKey::new(account_id, key)
}

pub fn run() {
    println!("=== Example: Execute a random transaction ===\n");

    // Use the same chain_id everywhere to avoid EIP-712 hash mismatches.
    // The storage's SystemContext is initialized with this chain_id, and the
    // bootloader reads it from there when computing the EIP-712 domain separator.
    // The transaction must be signed with the same chain_id.
    let chain_id = L2ChainId::from(IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID);

    // 1. Load system contracts (bootloader + DefaultAccount)
    let repo = SystemContractsRepo {
        root: env::current_dir().unwrap().join("../../"),
    };
    let artifacts_path = env::current_dir().unwrap().join("../build/artifacts");
    let artifacts = artifacts_path.to_str().expect("Invalid artifacts path");

    let bootloader_bytecode = repo.read_sys_contract_bytecode(
        artifacts,
        "proved_batch",
        Some("Bootloader"),
        ContractLanguage::Yul,
    );
    let bootloader = SystemContractCode {
        hash: BytecodeHash::for_bytecode(&bootloader_bytecode).value(),
        code: bootloader_bytecode,
    };

    let aa_bytecode =
        repo.read_sys_contract_bytecode("", "DefaultAccount", None, ContractLanguage::Sol);
    let default_aa = SystemContractCode {
        hash: BytecodeHash::for_bytecode(&aa_bytecode).value(),
        code: aa_bytecode,
    };

    // 2. Configure system and batch environments
    let system_env = SystemEnv {
        zk_porter_available: false,
        version: zksync_types::ProtocolVersionId::latest(),
        base_system_smart_contracts: zksync_contracts::BaseSystemContracts {
            bootloader,
            default_aa,
            evm_emulator: None,
        },
        bootloader_gas_limit: u32::MAX,
        execution_mode: TxExecutionMode::VerifyExecute,
        default_validation_computational_gas_limit: u32::MAX,
        chain_id,
    };

    let l1_batch_env = L1BatchEnv {
        previous_batch_hash: None,
        number: L1BatchNumber::from(1),
        timestamp: 14,
        fee_input: BatchFeeInput::sensible_l1_pegged_default(),
        fee_account: Address::default(),
        enforced_base_fee: None,
        first_l2_block: L2BlockEnv {
            number: 1,
            timestamp: 15,
            prev_block_hash: L2BlockHasher::legacy_hash(L2BlockNumber(0)),
            max_virtual_blocks_to_create: 1,
            interop_roots: vec![],
        },
        settlement_layer: SettlementLayer::L1(SLChainId(10)),
    };

    // 3. Create in-memory storage pre-loaded with system contracts.
    //    Use the same chain_id so SystemContext matches the signing chain_id.
    let storage = StorageView::new(InMemoryStorage::with_custom_system_contracts_and_chain_id(
        chain_id,
        get_system_smart_contracts_from_dir(env::current_dir().unwrap().join("../../")),
    ))
    .to_rc_ptr();

    // 4. Create VM
    let mut vm: Vm<_, HistoryDisabled> =
        Vm::new(l1_batch_env, system_env, storage.clone());

    // 5. Generate a random account and fund it
    let private_key = K256PrivateKey::random();
    let sender = private_key.address();
    println!("Sender:    {:?}", sender);

    storage
        .borrow_mut()
        .set_value(get_balance_key(sender), u256_to_h256(U256::MAX));

    // 6. Create and push a simple transfer transaction
    let recipient = Address::from_low_u64_be(0xdeadbeef);
    println!("Recipient: {:?}", recipient);

    let tx = create_transfer_tx(&private_key, chain_id, recipient);
    vm.push_transaction(tx);

    // 7. Execute through the bootloader
    let result = vm.inspect(&mut Default::default(), InspectExecutionMode::Bootloader);

    // 8. Verify success
    match &result.result {
        zksync_multivm::interface::ExecutionResult::Success { .. } => {
            println!("\n[SUCCESS] Transaction executed successfully.");
        }
        zksync_multivm::interface::ExecutionResult::Revert { output } => {
            panic!("[FAIL] Reverted: {}", output.to_user_friendly_string());
        }
        zksync_multivm::interface::ExecutionResult::Halt { reason } => {
            panic!("[FAIL] Halted: {}", reason);
        }
    }
}

fn create_transfer_tx(
    key: &K256PrivateKey,
    chain_id: L2ChainId,
    recipient: Address,
) -> Transaction {
    let fee = Fee {
        gas_limit: U256::from(1_000_000u64),
        max_fee_per_gas: U256::from(250_000_000u64),
        max_priority_fee_per_gas: U256::zero(),
        gas_per_pubdata_limit: U256::from(50_000u64),
    };

    let l2tx = L2Tx::new_signed(
        Some(recipient),
        vec![],
        Nonce(0),
        fee,
        U256::from(1u64),
        chain_id,
        key,
        vec![],
        PaymasterParams::default(),
    )
    .expect("Failed to create signed transaction");

    Transaction::from(l2tx)
}
