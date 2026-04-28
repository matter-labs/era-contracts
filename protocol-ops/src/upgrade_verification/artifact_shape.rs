use std::str::FromStr;

use anyhow::Context;
use ethers::types::Address;

use crate::upgrade_verification::{
    artifacts::{ComponentUpgradeArtifact, EcosystemUpgradeArtifact, PreparedUpgradeArtifacts},
    governance_calls,
    hex::decode_required_hex,
};

const TOP_LEVEL_HEX_FIELDS: &[&str] = &["chain_upgrade_diamond_cut", "force_deployments_data"];
const NESTED_HEX_FIELDS: &[&[&str]] = &[&["contracts_config", "diamond_cut_data"]];
const ADDRESS_TABLES: &[&str] = &[
    "deployed_addresses",
    "upgrade_addresses",
    "state_transition",
];
const PROTOCOL_VERSION_FIELDS: &[&str] = &["old_protocol_version", "new_protocol_version"];

pub(crate) fn verify(artifacts: &PreparedUpgradeArtifacts) -> anyhow::Result<()> {
    validate_ecosystem_artifact(&artifacts.ecosystem)
        .context("validating ecosystem upgrade artifact")?;
    validate_component_artifact(&artifacts.core).with_context(|| {
        format!(
            "validating core upgrade artifact: {}",
            artifacts.core.path.display()
        )
    })?;
    validate_component_artifact(&artifacts.ctm).with_context(|| {
        format!(
            "validating CTM upgrade artifact: {}",
            artifacts.ctm.path.display()
        )
    })?;

    Ok(())
}

fn validate_ecosystem_artifact(artifact: &EcosystemUpgradeArtifact) -> anyhow::Result<()> {
    decode_required_hex(
        "chain_upgrade_diamond_cut",
        &artifact.chain_upgrade_diamond_cut,
    )?;
    governance_calls::validate(&artifact.governance_calls)?;

    Ok(())
}

fn validate_component_artifact(artifact: &ComponentUpgradeArtifact) -> anyhow::Result<()> {
    artifact
        .value
        .as_table()
        .ok_or_else(|| anyhow::anyhow!("{} upgrade TOML must be a table", artifact.name))?;

    validate_known_hex_fields(artifact)?;
    if let Some(calls) = governance_calls::from_value(artifact.name, &artifact.value)? {
        governance_calls::validate(&calls)?;
    }
    validate_address_fields(artifact.name, &artifact.value)?;
    validate_protocol_versions(&artifact.value)?;

    Ok(())
}

fn validate_known_hex_fields(artifact: &ComponentUpgradeArtifact) -> anyhow::Result<()> {
    for field in TOP_LEVEL_HEX_FIELDS {
        if let Some(hex_value) = optional_string_field(&artifact.value, field) {
            decode_required_hex(field, hex_value)?;
        }
    }

    for path in NESTED_HEX_FIELDS {
        if let Some(hex_value) = optional_nested_string_field(&artifact.value, path) {
            let field = path.join(".");
            decode_required_hex(&field, hex_value)?;
        }
    }

    Ok(())
}

fn validate_address_fields(artifact_name: &str, value: &toml::Value) -> anyhow::Result<()> {
    validate_top_level_address_fields(artifact_name, value)?;
    for table_name in ADDRESS_TABLES {
        if let Some(address_table) = value.get(*table_name) {
            validate_address_table_fields(artifact_name, table_name, address_table)?;
        }
    }
    Ok(())
}

fn validate_top_level_address_fields(
    artifact_name: &str,
    value: &toml::Value,
) -> anyhow::Result<()> {
    let Some(table) = value.as_table() else {
        return Ok(());
    };

    for (field, field_value) in table {
        if looks_like_top_level_address_field(field) {
            let Some(address) = field_value.as_str() else {
                anyhow::bail!("{artifact_name}.{field} must be an address string");
            };
            parse_address(artifact_name, field, address)?;
        }
    }
    Ok(())
}

fn validate_address_table_fields(
    artifact_name: &str,
    path: &str,
    value: &toml::Value,
) -> anyhow::Result<()> {
    let table = value
        .as_table()
        .ok_or_else(|| anyhow::anyhow!("{artifact_name}.{path} must be a table"))?;

    for (field, field_value) in table {
        let field_path = format!("{path}.{field}");
        match field_value {
            toml::Value::String(address) => {
                parse_address(artifact_name, &field_path, address)?;
            }
            toml::Value::Table(_) => {
                validate_address_table_fields(artifact_name, &field_path, field_value)?;
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

fn parse_address(artifact_name: &str, field: &str, address: &str) -> anyhow::Result<Address> {
    Address::from_str(address)
        .with_context(|| format!("{artifact_name}.{field} is not a valid address"))
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

fn optional_string_field<'a>(value: &'a toml::Value, field: &str) -> Option<&'a str> {
    value.get(field).and_then(toml::Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn validates_minimal_ecosystem_upgrade_output() {
        let toml = r#"
                        chain_upgrade_diamond_cut = "0x1234"

                        [governance_calls]
                        stage0_calls = "0x00"
                        stage1_calls = "0x0102"
                        stage2_calls = "0x030405"
                        "#;

        let output: EcosystemUpgradeArtifact = toml::from_str(toml).unwrap();

        validate_ecosystem_artifact(&output).unwrap();
    }

    #[test]
    fn validates_component_artifact_shape() {
        let toml = r#"
                        chain_admin_addr = "0x0000000000000000000000000000000000000001"
                        force_deployments_data = "0x1234"
                        old_protocol_version = 1
                        new_protocol_version = 2

                        [contracts_config]
                        diamond_cut_data = "0xabcd"

                        [deployed_addresses]
                        chain_admin = "0x0000000000000000000000000000000000000002"

                        [deployed_addresses.bridgehub]
                        bridgehub_proxy_addr = "0x0000000000000000000000000000000000000003"

                        [governance_calls]
                        stage0_calls = "0x00"
                        stage1_calls = "0x0102"
                        stage2_calls = "0x030405"
                        "#;

        let artifact = ComponentUpgradeArtifact {
            name: "core",
            path: PathBuf::from("core.toml"),
            value: toml::from_str(toml).unwrap(),
        };

        validate_component_artifact(&artifact).unwrap();
    }

    #[test]
    fn rejects_malformed_component_address_fields() {
        let toml = r#"
                        [deployed_addresses]
                        chain_admin = "not-an-address"
                        "#;

        let artifact = ComponentUpgradeArtifact {
            name: "core",
            path: PathBuf::from("core.toml"),
            value: toml::from_str(toml).unwrap(),
        };

        assert!(validate_component_artifact(&artifact).is_err());
    }
}
