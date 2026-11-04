use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::bn256::Fr;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::plonk::domains::Domain;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::{PrimeField, PrimeFieldRepr};
use serde_json::Value;
use std::collections::HashMap;

/// `DOMAIN_SIZE`/`OMEGA` for a VK with `n = domain_size - 1`, via the same `Domain`
/// construction the Rust verifier uses. These must come from the VK: the wrapper domain
/// differs per proof system, and `verificationKeyHash()` does not cover these constants,
/// so a hardcoded mismatch passes the hash check yet rejects every valid proof.
pub fn get_domain_constants(n: u64) -> (u64, u32, String) {
    let domain_size = n + 1;
    let domain: Domain<Fr> = Domain::new_for_size(domain_size).expect("invalid domain size");
    assert_eq!(domain.size, domain_size, "vk n + 1 must be a power of two");
    let mut omega_be = Vec::new();
    domain
        .generator
        .into_repr()
        .write_be(&mut omega_be)
        .expect("failed to serialize omega");
    (
        domain_size,
        domain_size.trailing_zeros(),
        format!("0x{}", hex::encode(omega_be)),
    )
}

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

pub fn get_modexp_function() -> String {
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
            }"#
    .to_string()
}
