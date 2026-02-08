use zksync_multivm::vm_latest::{
    constants::{get_vm_hook_start_position_latest, BOOTLOADER_HEAP_PAGE},
    HistoryMode, SimpleMemory,
};

use zksync_multivm::zk_evm_latest::{
    aux_structures::MemoryPage,
    tracing::{BeforeExecutionData, VmLocalStateData},
    zkevm_opcode_defs::{FatPointer, Opcode, UMAOpcode},
};

use zksync_types::{u256_to_h256, U256};

#[derive(Clone, Debug)]
pub(crate) enum TestVmHook {
    NoHook,
    TestLog(String, String),
    AssertEqFailed(String, String, String),
    RequestedAssert(String),
    RequestedTxFailure(String),
    TxExecutionResult {
        success: bool,
        revert_data_hex: Option<String>,
    },
    // Testing framework reporting the number of tests.
    TestCount(u32),
    // 104 - test start.
    TestStart(String),
}

// Number of 32-bytes slots that are reserved for test hooks (passing information between bootloader test code and the VM).
const TEST_HOOKS: u32 = 5;
const TEST_HOOK_ENUM_POSITION: u32 = get_vm_hook_start_position_latest() - 1;
const TEST_HOOK_START: u32 = TEST_HOOK_ENUM_POSITION - TEST_HOOKS;
const VM_HOOK_PARAMS: u32 = 3;
const VM_HOOK_PARAMS_START: u32 = TEST_HOOK_ENUM_POSITION + 1;
const VM_HOOK_ENUM_POSITION: u32 = VM_HOOK_PARAMS_START + VM_HOOK_PARAMS;

pub fn get_vm_hook_params<H: HistoryMode>(memory: &SimpleMemory<H>) -> Vec<U256> {
    memory.dump_page_content_as_u256_words(
        BOOTLOADER_HEAP_PAGE,
        TEST_HOOK_START..TEST_HOOK_ENUM_POSITION,
    )
}

pub fn get_operator_hook_params<H: HistoryMode>(memory: &SimpleMemory<H>) -> Vec<U256> {
    memory.dump_page_content_as_u256_words(
        BOOTLOADER_HEAP_PAGE,
        VM_HOOK_PARAMS_START..VM_HOOK_ENUM_POSITION,
    )
}

fn read_memory_word_at<H: HistoryMode>(
    memory: &SimpleMemory<H>,
    memory_page: u32,
    byte_offset: u32,
) -> Option<U256> {
    if byte_offset % 32 != 0 {
        return None;
    }
    let word_offset = byte_offset / 32;
    memory
        .dump_page_content_as_u256_words(memory_page, word_offset..word_offset + 1)
        .into_iter()
        .next()
}

fn extract_return_data_hex<H: HistoryMode>(
    memory: &SimpleMemory<H>,
    return_data_ptr: U256,
) -> Option<String> {
    let fat_ptr = FatPointer::from_u256(return_data_ptr);
    if fat_ptr.length == 0 {
        return None;
    }
    let data_len = fat_ptr.length as usize;
    let byte_offset = fat_ptr.start.saturating_add(fat_ptr.offset);
    let base_word_offset = byte_offset - (byte_offset % 32);
    let in_word_offset = (byte_offset % 32) as usize;

    let words_to_read = (in_word_offset + data_len).div_ceil(32);
    let mut buf = Vec::with_capacity(words_to_read * 32);
    for i in 0..words_to_read {
        let word_offset = base_word_offset + (i as u32) * 32;
        let word = read_memory_word_at(memory, fat_ptr.memory_page, word_offset)?;
        let bytes = u256_to_h256(word);
        buf.extend_from_slice(bytes.as_bytes());
    }

    let data = &buf[in_word_offset..in_word_offset + data_len];
    Some(hex::encode(data))
}

fn strip_trailing_zeros(input: &[u8]) -> &[u8] {
    // Find the position of the last non-zero byte.
    let end = input
        .iter()
        .rposition(|&byte| byte != 0)
        .map(|pos| pos + 1)
        .unwrap_or(0);

    // Return the byte slice up to the position found.
    &input[..end]
}

fn test_hook_as_string(hook_param: U256) -> String {
    let msg = u256_to_h256(hook_param).as_bytes().to_vec();

    String::from_utf8(strip_trailing_zeros(&msg).to_vec()).expect("Invalid debug message")
}

fn test_hook_as_int_or_hex(hook_param: U256) -> String {
    // For long data, it is better to use hex-encoding for greater readability
    if hook_param > U256::from(u64::max_value()) {
        let mut bytes = [0u8; 32];
        hook_param.to_big_endian(&mut bytes);
        format!("0x{}", hex::encode(bytes))
    } else {
        hook_param.to_string()
    }
}

const fn heap_page_from_base(base: MemoryPage) -> MemoryPage {
    MemoryPage(base.0 + 2)
}

impl TestVmHook {
    pub(crate) fn from_opcode_memory<H: HistoryMode>(
        state: &VmLocalStateData<'_>,
        data: &BeforeExecutionData,
        memory: &SimpleMemory<H>,
    ) -> Self {
        let opcode_variant = data.opcode.variant;
        let heap_page =
            heap_page_from_base(state.vm_local_state.callstack.current.base_memory_page).0;

        let src0_value = data.src0_value.value;

        let fat_ptr = FatPointer::from_u256(src0_value);

        let value = data.src1_value.value;

        // Only UMA opcodes in the bootloader serve for vm hooks
        if !matches!(opcode_variant.opcode, Opcode::UMA(UMAOpcode::HeapWrite))
            || heap_page != BOOTLOADER_HEAP_PAGE
        {
            return Self::NoHook;
        }

        match fat_ptr.offset {
            offset if offset == TEST_HOOK_ENUM_POSITION * 32 => {
                let vm_hook_params: Vec<U256> = get_vm_hook_params(memory);
                match value.as_u32() {
                    100 => Self::TestLog(
                        test_hook_as_string(vm_hook_params[0]),
                        test_hook_as_int_or_hex(vm_hook_params[1]),
                    ),
                    101 => Self::AssertEqFailed(
                        test_hook_as_int_or_hex(vm_hook_params[0]),
                        test_hook_as_int_or_hex(vm_hook_params[1]),
                        test_hook_as_string(vm_hook_params[2]),
                    ),
                    102 => Self::RequestedAssert(test_hook_as_string(vm_hook_params[0])),
                    105 => Self::RequestedTxFailure(test_hook_as_string(vm_hook_params[0])),
                    103 => Self::TestCount(vm_hook_params[0].as_u32()),
                    104 => Self::TestStart(test_hook_as_string(vm_hook_params[0])),
                    _ => Self::NoHook,
                }
            }
            offset if offset == VM_HOOK_ENUM_POSITION * 32 => {
                let vm_hook_params: Vec<U256> = get_operator_hook_params(memory);
                match value.as_u32() {
                    10 => {
                        let success = vm_hook_params[0] != U256::zero();
                        let revert_data_hex = if success {
                            None
                        } else {
                            extract_return_data_hex(memory, vm_hook_params[1])
                        };
                        Self::TxExecutionResult {
                            success,
                            revert_data_hex,
                        }
                    }
                    _ => Self::NoHook,
                }
            }
            _ => Self::NoHook,
        }
    }
}

#[cfg(test)]
mod tests {
    use zksync_types::U256;

    use crate::hook::test_hook_as_string;

    #[test]
    fn test_to_string() {
        let data: U256 =
            U256::from("0x77696c6c4661696c000000000000000000000000000000000000000000000000");
        assert_eq!("willFail", test_hook_as_string(data));
    }
}
