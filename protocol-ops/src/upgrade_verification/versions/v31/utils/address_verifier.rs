use alloy::{
    hex::FromHex,
    primitives::{map::HashMap, Address},
};
use anyhow::Context;

use crate::upgrade_verification::artifacts::EcosystemUpgradeArtifact;

pub struct AddressVerifier {
    pub address_to_name: HashMap<Address, String>,
    pub name_to_address: HashMap<String, Address>,
}

const V31_ADDRESS_TABLES: &[&str] = &[
    "deployed_addresses",
    "upgrade_addresses",
    "state_transition",
];

const V31_ADDRESS_ALIASES: &[(&[&str], &str)] = &[
    (
        &["deployed_addresses", "l1_governance_upgrade_timer"],
        "upgrade_timer",
    ),
    (
        &["deployed_addresses", "native_token_vault_addr"],
        "native_token_vault",
    ),
    (
        &["upgrade_addresses", "native_token_vault_addr"],
        "native_token_vault",
    ),
    (
        &["deployed_addresses", "bridgehub", "bridgehub_proxy_addr"],
        "bridgehub_proxy",
    ),
    (
        &[
            "deployed_addresses",
            "bridgehub",
            "l1_asset_tracker_proxy_addr",
        ],
        "asset_tracker_proxy",
    ),
    (
        &[
            "deployed_addresses",
            "bridgehub",
            "chain_asset_handler_proxy_addr",
        ],
        "chain_asset_handler_proxy",
    ),
    (
        &[
            "deployed_addresses",
            "bridgehub",
            "chain_registration_sender_implementation_addr",
        ],
        "chain_registration_sender_implementation_addr",
    ),
    (
        &[
            "deployed_addresses",
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
        ],
        "ctm_deployment_tracker_proxy",
    ),
    (
        &["deployed_addresses", "bridgehub", "message_root_proxy_addr"],
        "message_root_proxy",
    ),
    (
        &["deployed_addresses", "bridgehub", "message_root_proxy_addr"],
        "l1_message_root",
    ),
    (
        &[
            "deployed_addresses",
            "bridges",
            "l1_asset_router_proxy_addr",
        ],
        "l1_asset_router_proxy",
    ),
    (
        &["deployed_addresses", "bridges", "l1_nullifier_proxy_addr"],
        "l1_nullifier_proxy",
    ),
    (
        &["state_transition", "default_upgrade_addr"],
        "default_upgrade",
    ),
    (
        &["state_transition", "chain_type_manager_proxy"],
        "chain_type_manager_proxy",
    ),
    (
        &["state_transition", "chain_type_manager_proxy_addr"],
        "chain_type_manager_proxy",
    ),
    (&["state_transition", "admin_facet_addr"], "admin_facet"),
    (
        &["state_transition", "executor_facet_addr"],
        "executor_facet",
    ),
    (&["state_transition", "getters_facet_addr"], "getters_facet"),
    (&["state_transition", "mailbox_facet_addr"], "mailbox_facet"),
    (
        &["state_transition", "migrator_facet_addr"],
        "migrator_facet",
    ),
    (
        &["state_transition", "committer_facet_addr"],
        "committer_facet",
    ),
    (&["state_transition", "diamond_init_addr"], "diamond_init"),
    (&["state_transition", "verifier_addr"], "verifier"),
    (
        &["state_transition", "eip7702_checker_addr"],
        "eip7702_checker_addr",
    ),
    (
        &["state_transition", "permissionless_validator_addr"],
        "permissionless_validator_addr",
    ),
];

impl AddressVerifier {
    pub fn new_v31_from_artifact(artifact: &EcosystemUpgradeArtifact) -> anyhow::Result<Self> {
        let mut result = Self {
            address_to_name: Default::default(),
            name_to_address: Default::default(),
        };

        result.add_address(Address::ZERO, "zero");
        add_addresses_from_artifact(&mut result, artifact)?;
        add_v31_address_aliases(&mut result, artifact)?;

        Ok(result)
    }

    pub(crate) fn address_from_artifact(
        artifact: &EcosystemUpgradeArtifact,
        path: &[&str],
    ) -> anyhow::Result<Address> {
        let path_name = path.join(".");
        let address = optional_nested_string_field(&artifact.value, path)
            .ok_or_else(|| anyhow::anyhow!("{path_name} is required"))?;
        parse_alloy_address(&path_name, address)
    }

    pub fn reverse_lookup(&self, address: &Address) -> Option<&String> {
        self.address_to_name.get(address)
    }

    pub fn get_by_name(&self, name: &str) -> Option<Address> {
        self.name_to_address.get(name).copied()
    }

    pub fn name_or_unknown(&self, address: &Address) -> String {
        match self.address_to_name.get(address) {
            Some(name) => name.clone(),
            None => format!("Unknown {}", address),
        }
    }

    pub fn add_address(&mut self, address: Address, name: &str) {
        self.name_to_address.insert(name.to_string(), address);
        self.address_to_name.insert(address, name.to_string());
    }
}

fn add_addresses_from_artifact(
    address_verifier: &mut AddressVerifier,
    artifact: &EcosystemUpgradeArtifact,
) -> anyhow::Result<()> {
    for table_name in V31_ADDRESS_TABLES {
        if let Some(table) = artifact.value.get(*table_name) {
            add_addresses_from_value(address_verifier, table_name, table)?;
        }
    }
    Ok(())
}

fn add_addresses_from_value(
    address_verifier: &mut AddressVerifier,
    path: &str,
    value: &toml::Value,
) -> anyhow::Result<()> {
    let table = value
        .as_table()
        .ok_or_else(|| anyhow::anyhow!("{path} must be a table"))?;

    for (field, field_value) in table {
        let field_path = format!("{path}.{field}");
        match field_value {
            toml::Value::String(address) => {
                let parsed = parse_alloy_address(&field_path, address)?;
                address_verifier.add_address(parsed, field);
            }
            toml::Value::Table(_) => {
                add_addresses_from_value(address_verifier, &field_path, field_value)?;
            }
            _ => {}
        }
    }

    Ok(())
}

fn add_v31_address_aliases(
    address_verifier: &mut AddressVerifier,
    artifact: &EcosystemUpgradeArtifact,
) -> anyhow::Result<()> {
    for (path, alias) in V31_ADDRESS_ALIASES {
        if let Some(address) = optional_nested_string_field(&artifact.value, path) {
            address_verifier.add_address(parse_alloy_address(&path.join("."), address)?, alias);
        }
    }
    Ok(())
}

fn optional_nested_string_field<'a>(value: &'a toml::Value, path: &[&str]) -> Option<&'a str> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    current.as_str()
}

fn parse_alloy_address(field: &str, address: &str) -> anyhow::Result<Address> {
    Address::from_hex(address).with_context(|| format!("{field} is not a valid address"))
}
