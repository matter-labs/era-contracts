use crate::{test_count_tracer::TestCountTracer, tracer::BootloaderTestTracer};
use colored::Colorize;
use multivm::interface::{
    L1BatchEnv, L2BlockEnv, SystemEnv, TxExecutionMode, VmExecutionMode, VmInterface,
};
use multivm::vm_latest::{HistoryDisabled, ToTracerPointer, Vm};
use once_cell::sync::OnceCell;
use zksync_types::fee_model::BatchFeeInput;
use std::process;

use multivm::interface::{ExecutionResult, Halt};
use std::{env, sync::Arc};
use tracing_subscriber::fmt;
use tracing_subscriber::prelude::__tracing_subscriber_SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use zksync_contracts::{
    read_zbin_bytecode, BaseSystemContracts, ContractLanguage, SystemContractCode,
    SystemContractsRepo,
};
use zksync_state::{
    InMemoryStorage, StoragePtr, StorageView, IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID,
};
use zksync_types::system_contracts::get_system_smart_contracts_from_dir;
use zksync_types::{block::L2BlockHasher, Address, L1BatchNumber, L2BlockNumber, U256};
use zksync_types::{L2ChainId, Transaction};
use zksync_utils::bytecode::hash_bytecode;
use zksync_utils::{bytes_to_be_words, u256_to_h256};

mod hook;
mod test_count_tracer;
mod tracer;

// Executes bootloader unittests.
fn execute_internal_bootloader_test() {
    let test_location = env::current_dir()
        .unwrap()
        .join("../build/artifacts/bootloader_test.yul.zbin");
    println!("Current dir is {:?}", test_location);
    let bytecode = read_zbin_bytecode(test_location.as_path());
    let hash = hash_bytecode(&bytecode);
    let bootloader = SystemContractCode {
        code: bytes_to_be_words(bytecode),
        hash,
    };

    let repo = SystemContractsRepo {
        root: env::current_dir().unwrap().join("../../"),
    };

    let bytecode = repo.read_sys_contract_bytecode("", "DefaultAccount", ContractLanguage::Sol);
    let hash = hash_bytecode(&bytecode);
    let default_aa = SystemContractCode {
        code: bytes_to_be_words(bytecode),
        hash,
    };

    let base_system_contract = BaseSystemContracts {
        bootloader,
        default_aa,
    };

    let system_env = SystemEnv {
        zk_porter_available: false,
        version: zksync_types::ProtocolVersionId::latest(),
        base_system_smart_contracts: base_system_contract,
        bootloader_gas_limit: u32::MAX,
        execution_mode: TxExecutionMode::VerifyExecute,
        default_validation_computational_gas_limit: u32::MAX,
        chain_id: zksync_types::L2ChainId::from(299),
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
        },
    };

    // First - get the number of tests.
    let test_count = {
        let storage: StoragePtr<StorageView<InMemoryStorage>> =
            StorageView::new(InMemoryStorage::with_custom_system_contracts_and_chain_id(
                L2ChainId::from(IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID),
                hash_bytecode,
                get_system_smart_contracts_from_dir(env::current_dir().unwrap().join("../../")),
            ))
            .to_rc_ptr();

        let mut vm: Vm<_, HistoryDisabled> =
            Vm::new(l1_batch_env.clone(), system_env.clone(), storage.clone());

        let test_count = Arc::new(OnceCell::default());
        let custom_tracers = TestCountTracer::new(test_count.clone()).into_tracer_pointer();

        // We're using a TestCountTracer (and passing 0 as fee account) - this should cause the bootloader
        // test framework to report number of tests via VM hook.
        vm.inspect(custom_tracers.into(), VmExecutionMode::Bootloader);

        test_count.get().unwrap().clone()
    };
    println!(" ==== Running {} tests ====", test_count);

    let mut tests_failed: u32 = 0;

    // Now we iterate over the tests.
    for test_id in 1..=test_count {
        println!("\n === Running test {}", test_id);

        let storage: StoragePtr<StorageView<InMemoryStorage>> =
            StorageView::new(InMemoryStorage::with_custom_system_contracts_and_chain_id(
                L2ChainId::from(IN_MEMORY_STORAGE_DEFAULT_NETWORK_ID),
                hash_bytecode,
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

        // Let's insert transactions into slots. They are not executed, but the tests can run functions against them.
        let json_str = include_str!("test_transactions/0.json");
        let tx: Transaction = serde_json::from_str(json_str).unwrap();
        vm.push_transaction(tx);

        let result = vm.inspect(custom_tracers.into(), VmExecutionMode::Bootloader);
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
                            let reason = reason.strip_prefix("Assertion error: ").unwrap();
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

fn main() {
    tracing_subscriber::registry()
        .with(fmt::Layer::default())
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    execute_internal_bootloader_test();
}
