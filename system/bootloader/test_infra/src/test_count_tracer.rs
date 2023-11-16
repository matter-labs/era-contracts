use std::sync::Arc;

use once_cell::sync::OnceCell;
use vm::{
    DynTracer, ExecutionEndTracer, ExecutionProcessing, HistoryMode, SimpleMemory,
    VmExecutionResultAndLogs, VmTracer,
};
use zksync_state::{StoragePtr, WriteStorage};
use zksync_types::zkevm_test_harness::zk_evm::tracing::{BeforeExecutionData, VmLocalStateData};

use crate::hook::TestVmHook;

/// Tracer that returns number of tests in the bootloader test file.
pub struct TestCountTracer {
    /// Returns number of tests in the yul file.
    pub test_count: Arc<OnceCell<u32>>,
}

impl TestCountTracer {
    /// Creates the tracer that should also report the amount of tests in a file.
    pub fn new(test_count_result: Arc<OnceCell<u32>>) -> Self {
        TestCountTracer {
            test_count: test_count_result,
        }
    }
}

impl<S, H: HistoryMode> DynTracer<S, H> for TestCountTracer {
    fn before_execution(
        &mut self,
        state: VmLocalStateData<'_>,
        data: BeforeExecutionData,
        memory: &SimpleMemory<H>,
        _storage: StoragePtr<S>,
    ) {
        if let TestVmHook::TestCount(test_count) =
            TestVmHook::from_opcode_memory(&state, &data, memory)
        {
            self.test_count.set(test_count).unwrap();
        }
    }
}

impl<H: HistoryMode> ExecutionEndTracer<H> for TestCountTracer {}

impl<S: WriteStorage, H: HistoryMode> ExecutionProcessing<S, H> for TestCountTracer {}

impl<S: WriteStorage, H: HistoryMode> VmTracer<S, H> for TestCountTracer {
    fn save_results(&mut self, _result: &mut VmExecutionResultAndLogs) {}
}
