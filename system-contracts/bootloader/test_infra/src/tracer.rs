use std::sync::Arc;

use colored::Colorize;
use once_cell::sync::OnceCell;

use multivm::interface::{
    dyn_tracers::vm_1_5_0::DynTracer,
    tracer::{TracerExecutionStatus, TracerExecutionStopReason},
};
use multivm::vm_latest::{BootloaderState, HistoryMode, SimpleMemory, VmTracer, ZkSyncVmState};
use multivm::zk_evm_latest::tracing::{BeforeExecutionData, VmLocalStateData};

use zksync_state::{StoragePtr, WriteStorage};

use crate::hook::TestVmHook;

/// Bootloader test tracer that is executing while the bootloader tests are running.
/// It can check the asserts, return information about the running tests (and amount of tests) etc.
pub struct BootloaderTestTracer {
    /// Set if the currently running test has failed.
    test_result: Arc<OnceCell<Result<(), String>>>,
    /// Set, if the currently running test should fail with a given assert.
    requested_assert: Arc<OnceCell<String>>,

    test_name: Arc<OnceCell<String>>,
}

impl BootloaderTestTracer {
    pub fn new(
        test_result: Arc<OnceCell<Result<(), String>>>,
        requested_assert: Arc<OnceCell<String>>,
        test_name: Arc<OnceCell<String>>,
    ) -> Self {
        BootloaderTestTracer {
            test_result,
            requested_assert,
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
