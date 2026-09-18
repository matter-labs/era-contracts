use std::sync::{Arc, Mutex};

use colored::Colorize;
use once_cell::sync::OnceCell;

use zksync_multivm::tracers::dynamic::vm_1_5_2::DynTracer;

use zksync_multivm::interface::tracer::{TracerExecutionStatus, TracerExecutionStopReason};
use zksync_multivm::vm_latest::{
    BootloaderState, HistoryMode, SimpleMemory, VmTracer, ZkSyncVmState,
};
use zksync_multivm::zk_evm_latest::tracing::{BeforeExecutionData, VmLocalStateData};

use zksync_state::interface::{StoragePtr, WriteStorage};

use zksync_types::U256;

use crate::hook::TestVmHook;

/// What the runner verifies once the batch is done; test bodies run before the transaction loop.
#[derive(Default)]
pub struct Expectations {
    pub tx_failures_no_returndata: Vec<usize>,
    pub bootloader_logs: Vec<(U256, U256)>,
    pub balances: Vec<(U256, U256)>,
    pub forbidden_log_keys: Vec<U256>,
    /// Pairs that must not appear; unlike `forbidden_log_keys`, the key may be shared.
    pub forbidden_logs: Vec<(U256, U256)>,
    pub system_logs: Vec<(U256, U256)>,
    /// Result of every transaction the bootloader reported, in execution order.
    pub tx_results: Vec<(bool, Option<String>)>,
}

impl Expectations {
    pub fn any_registered(&self) -> bool {
        !self.tx_failures_no_returndata.is_empty()
            || !self.bootloader_logs.is_empty()
            || !self.forbidden_log_keys.is_empty()
            || !self.forbidden_logs.is_empty()
            || !self.system_logs.is_empty()
            || !self.balances.is_empty()
    }
}

/// Bootloader test tracer that is executing while the bootloader tests are running.
/// It can check the asserts, return information about the running tests (and amount of tests) etc.
pub struct BootloaderTestTracer {
    /// Set if the currently running test has failed.
    test_result: Arc<OnceCell<Result<(), String>>>,
    /// Set, if the currently running test should fail with a given assert.
    requested_assert: Arc<OnceCell<String>>,
    /// Set, if the currently running test expects tx-level failure with concrete returndata.
    requested_tx_failure: Arc<OnceCell<String>>,
    /// Full returndata hex of the latest failed tx execution captured via VM hook.
    tx_failure_data_hex: Arc<OnceCell<String>>,
    /// What the test registered for the runner to check, plus the data to check it against.
    expectations: Arc<Mutex<Expectations>>,

    test_name: Arc<OnceCell<String>>,
}

impl BootloaderTestTracer {
    pub fn new(
        test_result: Arc<OnceCell<Result<(), String>>>,
        requested_assert: Arc<OnceCell<String>>,
        requested_tx_failure: Arc<OnceCell<String>>,
        tx_failure_data_hex: Arc<OnceCell<String>>,
        expectations: Arc<Mutex<Expectations>>,
        test_name: Arc<OnceCell<String>>,
    ) -> Self {
        BootloaderTestTracer {
            test_result,
            requested_assert,
            requested_tx_failure,
            tx_failure_data_hex,
            expectations,
            test_name,
        }
    }
}

impl<S, H: HistoryMode> DynTracer<S, SimpleMemory<H>> for BootloaderTestTracer {
    fn before_execution(
        &mut self,
        state: VmLocalStateData<'_>,
        data: BeforeExecutionData,
        memory: &SimpleMemory<H>,
        _storage: StoragePtr<S>,
    ) {
        let hook = TestVmHook::from_opcode_memory(&state, &data, memory);

        if let TestVmHook::TestLog(msg, data_str) = &hook {
            println!("{} {} {}", "Test log".bold(), msg, data_str);
        }
        if let TestVmHook::AssertEqFailed(a, b, msg) = &hook {
            let result = format!("Assert failed: {} is not equal to {}: {}", a, b, msg);

            self.test_result.set(Err(result.clone())).unwrap();
        }
        if let TestVmHook::RequestedAssert(requested_assert) = &hook {
            let _ = self.requested_assert.set(requested_assert.clone());
        }
        if let TestVmHook::RequestedTxFailure(expected_revert_data) = &hook {
            let _ = self.requested_tx_failure.set(expected_revert_data.clone());
        }
        if let TestVmHook::TxExecutionResult {
            success,
            revert_data_hex,
        } = &hook
        {
            if !success {
                if let Some(data_hex) = revert_data_hex {
                    let _ = self.tx_failure_data_hex.set(data_hex.clone());
                }
            }
            self.expectations
                .lock()
                .unwrap()
                .tx_results
                .push((*success, revert_data_hex.clone()));
        }

        match &hook {
            TestVmHook::ExpectTxFailureNoReturndata(index) => {
                self.expectations
                    .lock()
                    .unwrap()
                    .tx_failures_no_returndata
                    .push(*index);
            }
            TestVmHook::ExpectBootloaderLog(key, value) => {
                self.expectations
                    .lock()
                    .unwrap()
                    .bootloader_logs
                    .push((*key, *value));
            }
            TestVmHook::ExpectBalance(account, balance) => {
                self.expectations
                    .lock()
                    .unwrap()
                    .balances
                    .push((*account, *balance));
            }
            TestVmHook::ExpectNoBootloaderLogKey(key) => {
                self.expectations
                    .lock()
                    .unwrap()
                    .forbidden_log_keys
                    .push(*key);
            }
            TestVmHook::ExpectNoBootloaderLog(key, value) => {
                self.expectations
                    .lock()
                    .unwrap()
                    .forbidden_logs
                    .push((*key, *value));
            }
            TestVmHook::ExpectSystemLog(key, value) => {
                self.expectations
                    .lock()
                    .unwrap()
                    .system_logs
                    .push((*key, *value));
            }
            _ => {}
        }

        if let TestVmHook::TestStart(test_name) = &hook {
            self.test_name
                .set(test_name.clone())
                .expect("Test already started");
        }
    }
}

impl<S: WriteStorage, H: HistoryMode> VmTracer<S, H> for BootloaderTestTracer {
    fn finish_cycle(
        &mut self,
        _state: &mut ZkSyncVmState<S, H>,
        _bootloader_state: &mut BootloaderState,
    ) -> TracerExecutionStatus {
        if let Some(Err(_)) = self.test_result.get() {
            TracerExecutionStatus::Stop(TracerExecutionStopReason::Finish)
        } else {
            TracerExecutionStatus::Continue
        }
    }
}
