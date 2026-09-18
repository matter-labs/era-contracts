use crate::{
    test_count_tracer::TestCountTracer,
    tracer::{BootloaderTestTracer, Expectations},
};
use colored::Colorize;
use once_cell::sync::OnceCell;
use std::fs;
use std::process;
use std::{
    env,
    sync::{Arc, Mutex},
};
use zksync_multivm::interface::{
    InspectExecutionMode, L1BatchEnv, L2BlockEnv, SystemEnv, TxExecutionMode, VmFactory,
    VmInterface,
};
use zksync_multivm::vm_latest::{HistoryDisabled, ToTracerPointer, TracerDispatcher, Vm};
use zksync_state::interface::{
    InMemoryStorage, ReadStorage, StoragePtr, StorageView, WriteStorage,
    IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID,
};
use zksync_types::fee_model::BatchFeeInput;

use tracing_subscriber::fmt;
use tracing_subscriber::prelude::__tracing_subscriber_SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use zksync_contracts::{
    BaseSystemContracts, ContractLanguage, SystemContractCode, SystemContractsRepo,
};
use zksync_multivm::interface::{ExecutionResult, Halt, VmExecutionResultAndLogs};
use zksync_types::bytecode::BytecodeHash;
use zksync_types::system_contracts::get_system_smart_contracts_from_dir;
use zksync_types::{
    block::L2BlockHasher, get_address_mapping_key, h256_to_u256, settlement::SettlementLayer,
    u256_to_address, u256_to_h256, Address, L1BatchNumber, L2BlockNumber, SLChainId, H256, U256,
};
use zksync_types::{
    web3::keccak256, AccountTreeId, ExecuteTransactionCommon, L2ChainId, StorageKey, Transaction,
    BASE_TOKEN_HOLDER_ADDRESS, BOOTLOADER_ADDRESS, L2_ASSET_TRACKER_ADDRESS, L2_BASE_TOKEN_ADDRESS,
};

mod hook;
mod test_count_tracer;
mod tracer;
mod transaction_generator;

fn get_balance_key(address: Address) -> StorageKey {
    let account_id = AccountTreeId::new(L2_BASE_TOKEN_ADDRESS);
    let key = get_address_mapping_key(&address, Default::default());
    StorageKey::new(account_id, key)
}

/// `L2AssetTracker` slots, from `forge inspect L2AssetTracker storageLayout`. zksync-era's
/// `with_l1_base_token_minting` has the same, but the pinned rev predates it. Nothing ties them to
/// `AssetTrackerBase.sol`: a layout change surfaces as a bare `Failed to mint ether`.
const ASSET_TRACKER_IS_ASSET_REGISTERED_SLOT: u64 = 203;
const ASSET_TRACKER_L1_CHAIN_ID_SLOT: u64 = 204;
const ASSET_TRACKER_BASE_TOKEN_ASSET_ID_SLOT: u64 = 205;
/// Any non-zero id; the fixtures only need the base token registered.
const TEST_BASE_TOKEN_ASSET_ID_BYTE: u8 = 0x11;
/// Holder supply, comfortably above every fixture's `mintValue`.
const BASE_TOKEN_HOLDER_BALANCE: u64 = 10u64.pow(19);

/// Storage slots an L1->L2 transaction needs before the bootloader can mint its `mintValue`.
fn apply_l1_base_token_minting_slots(storage: &StoragePtr<StorageView<InMemoryStorage>>) {
    let base_token_asset_id = H256::repeat_byte(TEST_BASE_TOKEN_ASSET_ID_BYTE);

    let asset_tracker = AccountTreeId::new(L2_ASSET_TRACKER_ADDRESS);
    // `isAssetRegistered[base_token_asset_id]`, a mapping.
    let mut registered_key_input = [0u8; 64];
    registered_key_input[..32].copy_from_slice(base_token_asset_id.as_bytes());
    registered_key_input[32..]
        .copy_from_slice(H256::from_low_u64_be(ASSET_TRACKER_IS_ASSET_REGISTERED_SLOT).as_bytes());

    let slots = [
        (
            StorageKey::new(
                asset_tracker,
                H256::from_low_u64_be(ASSET_TRACKER_L1_CHAIN_ID_SLOT),
            ),
            H256::from_low_u64_be(1),
        ),
        (
            StorageKey::new(
                asset_tracker,
                H256::from_low_u64_be(ASSET_TRACKER_BASE_TOKEN_ASSET_ID_SLOT),
            ),
            base_token_asset_id,
        ),
        (
            StorageKey::new(asset_tracker, H256(keccak256(&registered_key_input))),
            H256::from_low_u64_be(1),
        ),
        (
            get_balance_key(BASE_TOKEN_HOLDER_ADDRESS),
            u256_to_h256(U256::from(BASE_TOKEN_HOLDER_BALANCE)),
        ),
    ];

    for (key, value) in slots {
        storage.borrow_mut().set_value(key, value);
    }
}

/// A test expecting the batch to fail has nothing for the hooks to read; skipping them silently
/// would let it pass with any expectation at all.
fn return_expectations_unreachable(test_name: &str) -> Result<(), String> {
    Err(format!(
        "`{}` registered `testing_expect*` expectations and also expects the batch to fail; \
         the expectations could never be checked.",
        test_name
    ))
}

/// Verifies the post-execution expectations a test registered through the `testing_expect*` hooks.
fn check_expectations(
    expectations: &Expectations,
    result: &VmExecutionResultAndLogs,
    storage: &StoragePtr<StorageView<InMemoryStorage>>,
) -> Result<(), String> {
    for index in &expectations.tx_panics {
        match expectations.tx_results.get(*index) {
            Some((false, None)) => {}
            Some((false, Some(data))) => {
                return Err(format!(
                    "tx {} should have failed with empty returndata, but returned `0x{}`.",
                    index, data
                ))
            }
            Some((true, _)) => {
                return Err(format!("tx {} should have failed, but succeeded.", index))
            }
            None => {
                return Err(format!(
                    "tx {} should have failed, but the bootloader reported no result for it.",
                    index
                ))
            }
        }
    }

    for (key, value) in &expectations.bootloader_logs {
        let expected_key = u256_to_h256(*key);
        let expected_value = u256_to_h256(*value);
        // Exactly one: a second log under the same canonical hash would prove the tx twice on L1.
        let matches = result
            .logs
            .user_l2_to_l1_logs
            .iter()
            .filter(|log| {
                log.0.sender == BOOTLOADER_ADDRESS
                    && log.0.key == expected_key
                    && log.0.value == expected_value
            })
            .count();
        if matches != 1 {
            return Err(format!(
                "Expected exactly one bootloader L2->L1 log with key {:?} and value {:?}, found {}. Logs sent: {:?}",
                expected_key, expected_value, matches, result.logs.user_l2_to_l1_logs
            ));
        }
    }

    for key in &expectations.forbidden_log_keys {
        let forbidden_key = u256_to_h256(*key);
        if let Some(log) = result
            .logs
            .user_l2_to_l1_logs
            .iter()
            .find(|log| log.0.sender == BOOTLOADER_ADDRESS && log.0.key == forbidden_key)
        {
            return Err(format!(
                "Bootloader sent an unexpected L2->L1 log under key {:?}: {:?}",
                forbidden_key, log
            ));
        }
    }

    for (key, value) in &expectations.forbidden_logs {
        let forbidden_key = u256_to_h256(*key);
        let forbidden_value = u256_to_h256(*value);
        if let Some(log) = result.logs.user_l2_to_l1_logs.iter().find(|log| {
            log.0.sender == BOOTLOADER_ADDRESS
                && log.0.key == forbidden_key
                && log.0.value == forbidden_value
        }) {
            return Err(format!("Bootloader sent a forbidden L2->L1 log {:?}", log));
        }
    }

    // Priority-queue accounting arrives as system logs.
    for (key, value) in &expectations.system_logs {
        let expected_key = u256_to_h256(*key);
        let expected_value = u256_to_h256(*value);
        let found = result.logs.system_l2_to_l1_logs.iter().any(|log| {
            log.0.sender == BOOTLOADER_ADDRESS
                && log.0.key == expected_key
                && log.0.value == expected_value
        });
        if !found {
            return Err(format!(
                "Missing bootloader system log with key {:?} and value {:?}. System logs sent: {:?}",
                expected_key, expected_value, result.logs.system_l2_to_l1_logs
            ));
        }
    }

    for (account, balance) in &expectations.balances {
        let account = u256_to_address(account);
        let actual = h256_to_u256(storage.borrow_mut().read_value(&get_balance_key(account)));
        if actual != *balance {
            return Err(format!(
                "Balance of {:?} is {}, expected {}.",
                account, actual, balance
            ));
        }
    }

    Ok(())
}

fn load_test_transactions() -> Vec<Transaction> {
    let transactions_dir = env::current_dir().unwrap().join("src/test_transactions");

    let mut fixture_files: Vec<(usize, std::path::PathBuf)> = fs::read_dir(&transactions_dir)
        .unwrap_or_else(|e| {
            panic!(
                "Failed to read test transactions directory {:?}: {}",
                transactions_dir, e
            )
        })
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            let extension = path.extension()?.to_str()?;
            if extension != "json" {
                return None;
            }

            let index = path.file_stem()?.to_str()?.parse::<usize>().ok()?;
            Some((index, path))
        })
        .collect();

    fixture_files.sort_by_key(|(index, _)| *index);
    assert!(
        !fixture_files.is_empty(),
        "No JSON fixtures found in {:?}",
        transactions_dir
    );

    fixture_files
        .into_iter()
        .map(|(_, path)| {
            let json_str = fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("Failed to read fixture {:?}: {}", path, e));
            serde_json::from_str(&json_str)
                .unwrap_or_else(|e| panic!("Failed to decode fixture {:?}: {}", path, e))
        })
        .collect()
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

    let bytecode = repo.read_sys_contract_bytecode("", "EvmEmulator", None, ContractLanguage::Yul);
    let hash = BytecodeHash::for_bytecode(&bytecode).value();
    let evm_emulator = SystemContractCode {
        code: bytecode,
        hash,
    };

    let base_system_contract = BaseSystemContracts {
        bootloader,
        default_aa,
        evm_emulator: Some(evm_emulator),
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
        interop_fee: U256::zero(),
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
        apply_l1_base_token_minting_slots(&storage);

        // We are passing id of the test in location (0) where we normally put the operator.
        // This is then picked up by the testing framework.
        l1_batch_env.fee_account = zksync_types::H160::from(u256_to_h256(U256::from(test_id)));
        let mut vm: Vm<_, HistoryDisabled> =
            Vm::new(l1_batch_env.clone(), system_env.clone(), storage.clone());

        let test_result = Arc::new(OnceCell::default());
        let requested_assert = Arc::new(OnceCell::default());
        let requested_tx_failure = Arc::new(OnceCell::default());
        let tx_failure_data_hex = Arc::new(OnceCell::default());
        let expectations = Arc::new(Mutex::new(Expectations::default()));
        let test_name = Arc::new(OnceCell::default());

        let custom_tracers = BootloaderTestTracer::new(
            test_result.clone(),
            requested_assert.clone(),
            requested_tx_failure.clone(),
            tx_failure_data_hex.clone(),
            expectations.clone(),
            test_name.clone(),
        )
        .into_tracer_pointer();
        let mut tracer_dispatcher = TracerDispatcher::from(custom_tracers);

        // Insert all fixture transactions into slots in numeric filename order.
        for tx in load_test_transactions() {
            // An L1->L2 sender is funded by the bootloader's mint, which `U256::MAX` would
            // overflow — and it would mask the balances the force-fail tests assert.
            if matches!(tx.common_data, ExecuteTransactionCommon::L2(_)) {
                storage.borrow_mut().set_value(
                    get_balance_key(tx.initiator_account()),
                    u256_to_h256(U256::MAX),
                );
            }

            vm.push_transaction(tx);
        }

        let result = vm.inspect(&mut tracer_dispatcher, InspectExecutionMode::Bootloader);
        drop(tracer_dispatcher);

        let expectations = Arc::into_inner(expectations).unwrap().into_inner().unwrap();
        let mut test_result = Arc::into_inner(test_result).unwrap().into_inner();
        let requested_assert = Arc::into_inner(requested_assert).unwrap().into_inner();
        let requested_tx_failure = Arc::into_inner(requested_tx_failure).unwrap().into_inner();
        let tx_failure_data_hex = Arc::into_inner(tx_failure_data_hex).unwrap().into_inner();
        let test_name = Arc::into_inner(test_name)
            .unwrap()
            .into_inner()
            .unwrap_or_default();

        // An `INT_TEST_*` runs the whole batch, so one that registers nothing passes vacuously.
        let asserted_something = requested_assert.is_some()
            || requested_tx_failure.is_some()
            || expectations.any_registered();

        if test_result.is_none() {
            test_result = Some(if let Some(requested_tx_failure) = requested_tx_failure {
                let expected_data_hex = requested_tx_failure
                    .trim()
                    .trim_start_matches("0x")
                    .to_ascii_lowercase();
                if tx_failure_data_hex.as_deref() == Some(expected_data_hex.as_str()) {
                    // `tx_failure_data_hex` latches on the first failure, so without this a later
                    // transaction taking the batch down is reported as a pass.
                    match &result.result {
                        ExecutionResult::Success { .. } => {
                            check_expectations(&expectations, &result, &storage)
                        }
                        ExecutionResult::Revert { output } => Err(format!(
                            "tx failed with the expected returndata, but the batch reverted with `{}`.",
                            output.to_user_friendly_string()
                        )),
                        ExecutionResult::Halt { reason } => Err(format!(
                            "tx failed with the expected returndata, but the batch halted with `{}`.",
                            reason
                        )),
                    }
                } else if tx_failure_data_hex.is_none() {
                    match &result.result {
                        ExecutionResult::Success { .. } => Err(format!(
                            "Should have failed with returndata `0x{}`, but transaction executed successfully.",
                            expected_data_hex
                        )),
                        ExecutionResult::Revert { output } => Err(format!(
                            "Should have failed with returndata `0x{}`, but reverted with `{}` and no tx failure returndata was captured.",
                            expected_data_hex,
                            output.to_user_friendly_string()
                        )),
                        ExecutionResult::Halt { reason } => Err(format!(
                            "Should have failed with returndata `0x{}`, but halted with `{}` and no tx failure returndata was captured.",
                            expected_data_hex, reason
                        )),
                    }
                } else {
                    Err(format!(
                        "Should have failed with returndata `0x{}`, but got `0x{}`.",
                        expected_data_hex,
                        tx_failure_data_hex.unwrap_or_else(|| "none".to_string())
                    ))
                }
            } else if let Some(requested_assert) = requested_assert {
                if expectations.any_registered() {
                    return_expectations_unreachable(&test_name)
                } else {
                    match &result.result {
                        ExecutionResult::Success { .. } => Err(format!(
                            "Should have failed with {}, but run successfully.",
                            requested_assert
                        )),
                        ExecutionResult::Revert { output } => {
                            let reason = output.to_user_friendly_string();
                            if reason.contains(&requested_assert) {
                                Ok(())
                            } else {
                                Err(format!(
                                    "Should have failed with `{}`, but run reverted with `{}`.",
                                    requested_assert, reason
                                ))
                            }
                        }
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
                }
            } else {
                match &result.result {
                    ExecutionResult::Success { .. } => {
                        check_expectations(&expectations, &result, &storage)
                    }
                    ExecutionResult::Revert { output } => Err(output.to_user_friendly_string()),
                    ExecutionResult::Halt { reason } => Err(reason.to_string()),
                }
            });
        }

        if matches!(test_result, Some(Ok(())))
            && test_name.starts_with("INT_TEST")
            && !asserted_something
        {
            test_result = Some(Err(
                "Integration test registered no assertion: it runs the batch and checks nothing."
                    .to_string(),
            ));
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

fn main() {
    tracing_subscriber::registry()
        .with(fmt::Layer::default())
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--generate-transactions") {
        transaction_generator::generate_transactions();
    } else {
        execute_internal_bootloader_test();
    }
}
