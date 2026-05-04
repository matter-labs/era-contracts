use std::str::FromStr;

use anyhow::Context;
use ethers::types::Address;

use crate::upgrade_verification::{
    artifacts::{EcosystemUpgradeArtifact, GovernanceCalls},
    hex::decode_required_hex,
};

const ARTIFACT_NAME: &str = "ecosystem";
const OPTIONAL_HEX_FIELDS: &[&[&str]] = &[
    &["contracts_config", "diamond_cut_data"],
    &["contracts_config", "force_deployments_data"],
];
const ADDRESS_TABLES: &[&str] = &[
    "deployed_addresses",
    "upgrade_addresses",
    "state_transition",
];
const PROTOCOL_VERSION_FIELDS: &[&str] = &["old_protocol_version", "new_protocol_version"];

pub(crate) fn verify(artifact: &EcosystemUpgradeArtifact) -> anyhow::Result<()> {
    validate_ecosystem_artifact(artifact).context("validating ecosystem upgrade artifact")?;

    Ok(())
}

fn validate_ecosystem_artifact(artifact: &EcosystemUpgradeArtifact) -> anyhow::Result<()> {
    validate_ecosystem_table(&artifact.value)?;
    decode_required_hex(
        "chain_upgrade_diamond_cut",
        &artifact.chain_upgrade_diamond_cut,
    )?;
    validate_governance_calls(&artifact.governance_calls)?;
    validate_optional_hex_fields(&artifact.value)?;
    validate_address_fields(&artifact.value)?;
    validate_protocol_versions(&artifact.value)?;
    if let Some(contracts_config) = artifact.value.get("contracts_config") {
        validate_protocol_versions(contracts_config)?;
    }

    Ok(())
}

fn validate_governance_calls(calls: &GovernanceCalls) -> anyhow::Result<()> {
    decode_required_hex("governance_calls.stage0_calls", &calls.stage0_calls)?;
    decode_required_hex("governance_calls.stage1_calls", &calls.stage1_calls)?;
    decode_required_hex("governance_calls.stage2_calls", &calls.stage2_calls)?;

    Ok(())
}

fn validate_ecosystem_table(value: &toml::Value) -> anyhow::Result<()> {
    value
        .as_table()
        .ok_or_else(|| anyhow::anyhow!("{ARTIFACT_NAME} upgrade TOML must be a table"))?;

    Ok(())
}

fn validate_optional_hex_fields(value: &toml::Value) -> anyhow::Result<()> {
    for path in OPTIONAL_HEX_FIELDS {
        if let Some(hex_value) = optional_nested_string_field(value, path) {
            let field = path.join(".");
            decode_required_hex(&field, hex_value)?;
        }
    }

    Ok(())
}

fn validate_address_fields(value: &toml::Value) -> anyhow::Result<()> {
    validate_top_level_address_fields(value)?;
    for table_name in ADDRESS_TABLES {
        if let Some(address_table) = value.get(*table_name) {
            validate_address_table_fields(table_name, address_table)?;
        }
    }
    Ok(())
}

fn validate_top_level_address_fields(value: &toml::Value) -> anyhow::Result<()> {
    let Some(table) = value.as_table() else {
        return Ok(());
    };

    for (field, field_value) in table {
        if looks_like_top_level_address_field(field) {
            let Some(address) = field_value.as_str() else {
                anyhow::bail!("{ARTIFACT_NAME}.{field} must be an address string");
            };
            parse_address(field, address)?;
        }
    }
    Ok(())
}

fn validate_address_table_fields(path: &str, value: &toml::Value) -> anyhow::Result<()> {
    let table = value
        .as_table()
        .ok_or_else(|| anyhow::anyhow!("{ARTIFACT_NAME}.{path} must be a table"))?;

    for (field, field_value) in table {
        let field_path = format!("{path}.{field}");
        match field_value {
            toml::Value::String(address) => {
                parse_address(&field_path, address)?;
            }
            toml::Value::Table(_) => {
                validate_address_table_fields(&field_path, field_value)?;
            }
            _ => {}
        }
    }

    Ok(())
}

fn validate_protocol_versions(value: &toml::Value) -> anyhow::Result<()> {
    for field in PROTOCOL_VERSION_FIELDS {
        let Some(version) = value.get(*field) else {
            continue;
        };
        version
            .as_integer()
            .ok_or_else(|| anyhow::anyhow!("{field} must be an integer"))?;
    }
    Ok(())
}

fn parse_address(field: &str, address: &str) -> anyhow::Result<Address> {
    Address::from_str(address)
        .with_context(|| format!("{ARTIFACT_NAME}.{field} is not a valid address"))
}

fn looks_like_top_level_address_field(field: &str) -> bool {
    field.ends_with("_addr") || field.ends_with("_address")
}

fn optional_nested_string_field<'a>(value: &'a toml::Value, path: &[&str]) -> Option<&'a str> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    current.as_str()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_minimal_ecosystem_upgrade_output() {
        let toml = r#"
                        chain_upgrade_diamond_cut = "0x1234"

                        [governance_calls]
                        stage0_calls = "0x00"
                        stage1_calls = "0x0102"
                        stage2_calls = "0x030405"
                        "#;

        validate_ecosystem_artifact(&ecosystem_artifact(toml)).unwrap();
    }

    #[test]
    fn validates_ecosystem_artifact_shape() {
        let toml = r#"
                        chain_admin_addr = "0x0000000000000000000000000000000000000001"
                        chain_upgrade_diamond_cut = "0x1234"
                        old_protocol_version = 1
                        new_protocol_version = 2

                        [contracts_config]
                        diamond_cut_data = "0xabcd"
                        force_deployments_data = "0x1234"

                        [deployed_addresses]
                        chain_admin = "0x0000000000000000000000000000000000000002"

                        [deployed_addresses.bridgehub]
                        bridgehub_proxy_addr = "0x0000000000000000000000000000000000000003"

                        [governance_calls]
                        stage0_calls = "0x00"
                        stage1_calls = "0x0102"
                        stage2_calls = "0x030405"
                        "#;

        validate_ecosystem_artifact(&ecosystem_artifact(toml)).unwrap();
    }

    #[test]
    fn rejects_malformed_ecosystem_address_fields() {
        let toml = r#"
                        chain_upgrade_diamond_cut = "0x1234"

                        [governance_calls]
                        stage0_calls = "0x00"
                        stage1_calls = "0x0102"
                        stage2_calls = "0x030405"

                        [deployed_addresses]
                        chain_admin = "not-an-address"
                        "#;

        assert!(validate_ecosystem_artifact(&ecosystem_artifact(toml)).is_err());
    }

    fn ecosystem_artifact(toml: &str) -> EcosystemUpgradeArtifact {
        let value: toml::Value = toml::from_str(toml).unwrap();
        let chain_upgrade_diamond_cut = value
            .get("chain_upgrade_diamond_cut")
            .and_then(toml::Value::as_str)
            .unwrap()
            .to_string();
        let governance_call_value = value.get("governance_calls").unwrap();
        let governance_calls = crate::upgrade_verification::artifacts::GovernanceCalls {
            stage0_calls: governance_call_value
                .get("stage0_calls")
                .and_then(toml::Value::as_str)
                .unwrap()
                .to_string(),
            stage1_calls: governance_call_value
                .get("stage1_calls")
                .and_then(toml::Value::as_str)
                .unwrap()
                .to_string(),
            stage2_calls: governance_call_value
                .get("stage2_calls")
                .and_then(toml::Value::as_str)
                .unwrap()
                .to_string(),
        };

        EcosystemUpgradeArtifact {
            value,
            chain_upgrade_diamond_cut,
            governance_calls,
        }
    }
}
