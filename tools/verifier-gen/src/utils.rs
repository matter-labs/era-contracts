use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::bn256::Fr;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::pairing::ff::PrimeField;
use circuit_definitions::snark_wrapper::franklin_crypto::bellman::plonk::domains::Domain;
use serde_json::Value;
use std::collections::HashMap;

/// Evaluation-domain constants baked into a generated verifier.
///
/// `DOMAIN_SIZE` and the domain generator `OMEGA` are fully determined by the
/// wrapped circuit's degree `n` — both are functions of the smallest power of
/// two `>= n + 1`. They must never be hardcoded in the template: the airbender
/// 100-bit-security wrapper moved the SNARK from a 2^24 to a 2^25 domain, and a
/// verifier still baked with the old 2^24 constants silently rejects every valid
/// proof. Deriving them from the VK keeps the on-chain verifier correct for any
/// circuit size.
pub struct DomainParams {
    /// Domain size as a `0x`-prefixed hex literal, e.g. `0x2000000`.
    pub size_hex: String,
    /// log2 of the domain size, for the `// 2^N` comment.
    pub log2: u32,
    /// Domain generator omega as a `0x`-prefixed 32-byte hex literal.
    pub omega_hex: String,
}

/// Derive [`DomainParams`] from the VK degree `n`, matching bellman's own
/// verifier (`required_domain_size = n.next_power_of_two()`; `omega` is the
/// corresponding root of unity via [`Domain::new_for_size`]).
pub fn domain_params_from_n(n: u64) -> DomainParams {
    assert!(
        (n + 1).is_power_of_two(),
        "unexpected VK degree n = {n}; expected n + 1 to be a power of two"
    );
    let size = n.next_power_of_two();
    let domain = Domain::<Fr>::new_for_size(size)
        .expect("VK domain size exceeds the field's two-adicity");
    DomainParams {
        size_hex: format!("0x{:x}", domain.size),
        log2: domain.size.trailing_zeros(),
        // `{}` on the field's integer representation prints a 0x-prefixed,
        // fixed-width 32-byte hex string.
        omega_hex: format!("{}", domain.generator.into_repr()),
    }
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
