use std::collections::HashMap;
use serde_json::{Value};

pub fn format_mstore(hex_value: &str, slot: &str) -> String {
    format!("            mstore({}, 0x{})\n", slot, hex_value)
}

pub fn format_const(hex_value: &str, slot_name: &str) -> String {
    let hex_value = hex_value.trim_start_matches('0');
    let formatted_hex_value = if hex_value.len() < 64 && !hex_value.is_empty() {
        format!("0{}", hex_value)
    } else {
        String::from(hex_value)
    };
    format!(
        "    uint256 internal constant {} = 0x{};\n",
        slot_name, formatted_hex_value
    )
}

pub fn convert_list_to_hexadecimal(numbers: &Vec<Value>) -> String {
    numbers
        .iter()
        .map(|v| format!("{:01$x}", v.as_u64().expect("Failed to parse as u64"), 16))
        .rev()
        .collect::<String>()
}

pub fn create_hash_map<Type: Copy>(
    key_value_pairs: &[(&'static str, Type)],
) -> HashMap<&'static str, Type> {
    let mut hash_map = HashMap::new();
    for &(key, value) in key_value_pairs {
        hash_map.insert(key, value);
    }
    hash_map
}

pub fn get_modexp_function(l2_mode: bool) -> String {
    if l2_mode {
        r#"function modexp(value, power) -> res {
                res := 1
                for {

                } gt(power, 0) {

                } {
                    if mod(power, 2) {
                        res := mulmod(res, value, R_MOD)
                    }
                    value := mulmod(value, value, R_MOD)
                    power := shr(1, power)
                }
            }"#.to_string()
    } else {
        r#"function modexp(value, power) -> res {
                mstore(0x00, 0x20)
                mstore(0x20, 0x20)
                mstore(0x40, 0x20)
                mstore(0x60, value)
                mstore(0x80, power)
                mstore(0xa0, R_MOD)
                if iszero(staticcall(gas(), 5, 0, 0xc0, 0x00, 0x20)) {
                    revertWithMessage(24, "modexp precompile failed")
                }
                res := mload(0x00)
            }"#.to_string()
    }
}
