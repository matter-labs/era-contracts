use crate::{test_count_tracer::TestCountTracer, tracer::BootloaderTestTracer};
use colored::Colorize;
use once_cell::sync::OnceCell;
use rlp::RlpStream;
use std::fs;
use std::process;
use std::{env, sync::Arc};
use zksync_multivm::interface::{
    InspectExecutionMode, L1BatchEnv, L2BlockEnv, SystemEnv, TxExecutionMode, VmFactory,
    VmInterface,
};
use zksync_multivm::vm_latest::{HistoryDisabled, ToTracerPointer, TracerDispatcher, Vm};
use zksync_state::interface::{
    InMemoryStorage, StorageView, WriteStorage, IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID,
};
use zksync_types::fee_model::BatchFeeInput;

use tracing_subscriber::fmt;
use tracing_subscriber::prelude::__tracing_subscriber_SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use zksync_contracts::{
    BaseSystemContracts, ContractLanguage, SystemContractCode, SystemContractsRepo,
};
use zksync_multivm::interface::{ExecutionResult, Halt};
use zksync_types::bytecode::BytecodeHash;
use zksync_types::fee::Fee;
use zksync_types::l2::L2Tx;
use zksync_types::system_contracts::get_system_smart_contracts_from_dir;
use zksync_types::transaction_request::{PaymasterParams, TransactionRequest};
use zksync_types::web3::Bytes;
use zksync_types::{
    block::L2BlockHasher, get_address_mapping_key, settlement::SettlementLayer, u256_to_h256,
    Address, H256, K256PrivateKey, L1BatchNumber, L2BlockNumber, Nonce, PackedEthSignature,
    SLChainId, EIP_1559_TX_TYPE, U256,
};
use zksync_types::{
    AccountTreeId, L2ChainId, L2_BASE_TOKEN_ADDRESS, StorageKey, Transaction,
};

mod example_tx;
mod hook;
mod test_count_tracer;
mod tracer;

fn get_balance_key(address: Address) -> StorageKey {
    let account_id = AccountTreeId::new(L2_BASE_TOKEN_ADDRESS);
    let key = get_address_mapping_key(&address, Default::default());
    StorageKey::new(account_id, key)
}

// Executes bootloader unittests.
fn execute_internal_bootloader_test() {
    let artifacts_location_path = env::current_dir().unwrap().join("../build/artifacts");
    let artifacts_location = artifacts_location_path
        .to_str()
        .expect("Invalid path: {artifacts_location_path:?}");
    println!("Current dir is {:?}", artifacts_location);

    let repo = SystemContractsRepo {
        root: env::current_dir().unwrap().join("../../"),
    };

    let bytecode = repo.read_sys_contract_bytecode(
        artifacts_location,
        "bootloader_test",
        Some("Bootloader"),
        ContractLanguage::Yul,
    );
    let hash = BytecodeHash::for_bytecode(&bytecode).value();
    let bootloader = SystemContractCode {
        code: bytecode,
        hash,
    };

    let bytecode =
        repo.read_sys_contract_bytecode("", "DefaultAccount", None, ContractLanguage::Sol);
    let hash = BytecodeHash::for_bytecode(&bytecode).value();
    let default_aa = SystemContractCode {
        code: bytecode,
        hash,
    };

    let base_system_contract = BaseSystemContracts {
        bootloader,
        default_aa,
        evm_emulator: None,
    };

    // The chain_id MUST be the same everywhere: SystemEnv, InMemoryStorage (SystemContext),
    // and the transactions themselves. A mismatch causes EIP-712 signature verification
    // to fail because the bootloader reads the chain_id from SystemContext when computing
    // the domain separator.
    let chain_id = L2ChainId::from(IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID);

    let system_env = SystemEnv {
        zk_porter_available: false,
        version: zksync_types::ProtocolVersionId::latest(),
        base_system_smart_contracts: base_system_contract,
        bootloader_gas_limit: u32::MAX,
        execution_mode: TxExecutionMode::VerifyExecute,
        default_validation_computational_gas_limit: u32::MAX,
        chain_id,
    };

    let mut l1_batch_env = L1BatchEnv {
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

    // First - get the number of tests.
    let test_count = {
        let storage = StorageView::new(InMemoryStorage::with_custom_system_contracts_and_chain_id(
            chain_id,
            get_system_smart_contracts_from_dir(env::current_dir().unwrap().join("../../")),
        ))
        .to_rc_ptr();

        let mut vm: Vm<_, HistoryDisabled> =
            VmFactory::new(l1_batch_env.clone(), system_env.clone(), storage.clone());

        let test_count = Arc::new(OnceCell::default());
        let custom_tracers = TestCountTracer::new(test_count.clone()).into_tracer_pointer();

        // We're using a TestCountTracer (and passing 0 as fee account) - this should cause the bootloader
        // test framework to report number of tests via VM hook.
        let mut tracer_dispatcher = TracerDispatcher::from(custom_tracers);
        vm.inspect(&mut tracer_dispatcher, InspectExecutionMode::Bootloader);

        test_count.get().unwrap().clone()
    };
    println!(" ==== Running {} tests ====", test_count);

    let mut tests_failed: u32 = 0;

    // Now we iterate over the tests.
    for test_id in 1..=test_count {
        println!("\n === Running test {}", test_id);

        let storage = StorageView::new(InMemoryStorage::with_custom_system_contracts_and_chain_id(
            chain_id,
            get_system_smart_contracts_from_dir(env::current_dir().unwrap().join("../../")),
        ))
        .to_rc_ptr();

        // We are passing id of the test in location (0) where we normally put the operator.
        // This is then picked up by the testing framework.
        l1_batch_env.fee_account = zksync_types::H160::from(u256_to_h256(U256::from(test_id)));
        let mut vm: Vm<_, HistoryDisabled> =
            Vm::new(l1_batch_env.clone(), system_env.clone(), storage.clone());

        let test_result = Arc::new(OnceCell::default());
        let requested_assert = Arc::new(OnceCell::default());
        let test_name = Arc::new(OnceCell::default());

        let custom_tracers = BootloaderTestTracer::new(
            test_result.clone(),
            requested_assert.clone(),
            test_name.clone(),
        )
        .into_tracer_pointer();
        let mut tracer_dispatcher = TracerDispatcher::from(custom_tracers);

        // Let's insert transactions into slots. They are not executed, but the tests can run functions against them.
        let json_str = include_str!("test_transactions/0.json");
        let tx: Transaction = serde_json::from_str(json_str).unwrap();

        // Fund the sender so the transaction can pay fees.
        storage.borrow_mut().set_value(
            get_balance_key(tx.initiator_account()),
            u256_to_h256(U256::MAX),
        );

        vm.push_transaction(tx);

        let result = vm.inspect(&mut tracer_dispatcher, InspectExecutionMode::Bootloader);
        drop(tracer_dispatcher);

        let mut test_result = Arc::into_inner(test_result).unwrap().into_inner();
        let requested_assert = Arc::into_inner(requested_assert).unwrap().into_inner();
        let test_name = Arc::into_inner(test_name)
            .unwrap()
            .into_inner()
            .unwrap_or_default();

        if test_result.is_none() {
            test_result = Some(if let Some(requested_assert) = requested_assert {
                match &result.result {
                    ExecutionResult::Success { .. } => Err(format!(
                        "Should have failed with {}, but run successfully.",
                        requested_assert
                    )),
                    ExecutionResult::Revert { output } => Err(format!(
                        "Should have failed with {}, but run reverted with {}.",
                        requested_assert,
                        output.to_user_friendly_string()
                    )),
                    ExecutionResult::Halt { reason } => {
                        if let Halt::UnexpectedVMBehavior(reason) = reason {
                            let reason =
                                reason.strip_prefix("Assertion error: ").unwrap_or(&reason);
                            if reason == requested_assert {
                                Ok(())
                            } else {
                                Err(format!(
                                        "Should have failed with `{}`, but failed with different assert `{}`",
                                        requested_assert, reason
                                    ))
                            }
                        } else {
                            Err(format!(
                                "Should have failed with `{}`, but halted with`{}`",
                                requested_assert, reason
                            ))
                        }
                    }
                }
            } else {
                match &result.result {
                    ExecutionResult::Success { .. } => Ok(()),
                    ExecutionResult::Revert { output } => Err(output.to_user_friendly_string()),
                    ExecutionResult::Halt { reason } => Err(reason.to_string()),
                }
            });
        }

        match &test_result.unwrap() {
            Ok(_) => println!("{} {}", "[PASS]".green(), test_name),
            Err(error_info) => {
                tests_failed += 1;
                println!("{} {} {}", "[FAIL]".red(), test_name, error_info)
            }
        }
    }
    if tests_failed > 0 {
        println!("{}", format!("{} tests failed.", tests_failed).red());
        process::exit(1);
    } else {
        println!("{}", "ALL tests passed.".green())
    }
}

fn generate_eip712_transaction(key: &K256PrivateKey, chain_id: L2ChainId) -> Transaction {
    let contract_address = Address::from_low_u64_be(0x1234567890abcdef);
    let calldata = vec![0xa4, 0x13, 0x68, 0x62, 0x00, 0x01, 0x02, 0x03];
    let fee = Fee {
        gas_limit: U256::from(1_000_000u64),
        max_fee_per_gas: U256::from(250_000_000u64),
        max_priority_fee_per_gas: U256::zero(),
        gas_per_pubdata_limit: U256::from(50_000u64),
    };

    let l2tx = L2Tx::new_signed(
        Some(contract_address),
        calldata,
        Nonce(0),
        fee,
        U256::zero(),
        chain_id,
        key,
        vec![],
        PaymasterParams::default(),
    )
    .expect("Failed to create signed EIP-712 transaction");

    Transaction::from(l2tx)
}

fn generate_eip1559_transaction(key: &K256PrivateKey, chain_id: L2ChainId) -> Transaction {
    let address = key.address();
    let recipient = Address::from_low_u64_be(0xdeadbeef);

    let mut tx_request = TransactionRequest {
        nonce: U256::from(0u32),
        from: Some(address),
        to: Some(recipient),
        value: U256::from(1u64),
        gas_price: U256::from(250_000_000u64),
        max_priority_fee_per_gas: Some(U256::from(1u32)),
        gas: U256::from(1_000_000u64),
        input: Bytes(vec![]),
        transaction_type: Some(EIP_1559_TX_TYPE.into()),
        chain_id: Some(chain_id.as_u64()),
        access_list: Some(Vec::new()),
        ..Default::default()
    };

    // Step 1: RLP-encode unsigned tx, prepend type byte
    let mut rlp_stream = RlpStream::new();
    tx_request
        .rlp(&mut rlp_stream, None)
        .expect("Failed to RLP-encode unsigned EIP-1559 tx");
    let mut unsigned_data = rlp_stream.out().to_vec();
    unsigned_data.insert(0, EIP_1559_TX_TYPE);

    // Step 2: Hash via message_to_signed_bytes
    let msg = PackedEthSignature::message_to_signed_bytes(&unsigned_data);

    // Step 3: Sign via sign_raw
    let signature =
        PackedEthSignature::sign_raw(key, &msg).expect("Failed to sign EIP-1559 tx");
    tx_request.raw = Some(Bytes(unsigned_data));

    // Step 4: RLP-encode signed tx, prepend type byte
    let mut rlp_signed = RlpStream::new();
    tx_request
        .rlp(&mut rlp_signed, Some(&signature))
        .expect("Failed to RLP-encode signed EIP-1559 tx");
    let mut signed_data = rlp_signed.out().to_vec();
    signed_data.insert(0, EIP_1559_TX_TYPE);

    // Step 5: Decode via from_bytes_unverified
    let (req, hash) = TransactionRequest::from_bytes_unverified(&signed_data)
        .expect("Failed to decode signed EIP-1559 tx");

    // Step 6: Convert to L2Tx then Transaction
    let mut l2tx = L2Tx::from_request(req, usize::MAX, true)
        .expect("Failed to convert EIP-1559 request to L2Tx");
    l2tx.set_input(signed_data, hash);

    Transaction::from(l2tx)
}

fn write_transaction(dir: &str, index: usize, tx: &Transaction) {
    let json = serde_json::to_string_pretty(tx).expect("Failed to serialize transaction to JSON");

    // Round-trip verification
    let _roundtrip: Transaction =
        serde_json::from_str(&json).expect("Round-trip deserialization failed");

    let path = format!("{}/{}.json", dir, index);
    fs::write(&path, &json).unwrap_or_else(|e| panic!("Failed to write {}: {}", path, e));
    println!("Wrote {}", path);
}

fn generate_transactions() {
    let key = K256PrivateKey::from_bytes(H256([
        0xb5, 0xb1, 0x87, 0x0d, 0x4a, 0x32, 0x0e, 0x3a, 0x2b, 0x9c, 0x4f, 0x6e, 0x8d, 0x7a,
        0x1c, 0x5f, 0x3b, 0x6e, 0x2d, 0x9a, 0x8c, 0x7f, 0x1e, 0x4d, 0x6b, 0x3a, 0x5c, 0x9e,
        0x2f, 0x8d, 0x7b, 0x4a,
    ]))
    .expect("Invalid private key bytes");

    // Must match IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID so that the chain_id in the
    // signed transactions matches the SystemContext chain_id in the VM storage.
    let chain_id = L2ChainId::from(IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID);

    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/src/test_transactions");
    fs::create_dir_all(dir).expect("Failed to create test_transactions directory");

    println!("Generating test transactions into {}", dir);

    let tx0 = generate_eip712_transaction(&key, chain_id);
    write_transaction(dir, 0, &tx0);

    let tx1 = generate_eip1559_transaction(&key, chain_id);
    write_transaction(dir, 1, &tx1);

    println!("Done. Generated 2 test transactions.");
}

fn main() {
    tracing_subscriber::registry()
        .with(fmt::Layer::default())
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--example-tx") {
        example_tx::run();
    } else if args.iter().any(|a| a == "--generate-transactions") {
        generate_transactions();
    } else {
        execute_internal_bootloader_test();
    }
}
