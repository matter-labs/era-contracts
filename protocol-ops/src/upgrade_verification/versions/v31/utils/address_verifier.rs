use alloy::primitives::{map::HashMap, Address};

use super::super::elements::UpgradeOutput;

use super::{
    address_from_short_hex, apply_l2_to_l1_alias, bytecode_verifier::BytecodeVerifier,
    network_verifier::NetworkVerifier,
};

pub struct AddressVerifier {
    pub address_to_name: HashMap<Address, String>,
    pub name_to_address: HashMap<String, Address>,
}

impl AddressVerifier {
    pub async fn new(
        bridgehub_addr: Address,
        network_verifier: &NetworkVerifier,
        bytecode_verifier: &BytecodeVerifier,
        config: &UpgradeOutput,
    ) -> Self {
        let mut result = Self {
            address_to_name: Default::default(),
            name_to_address: Default::default(),
        };

        // Firstly, we initialize some constant addresses from the config.

        result.add_address(Address::ZERO, "zero");
        result.add_address(
            config.protocol_upgrade_handler_proxy_address,
            "protocol_upgrade_handler_proxy",
        );
        result.add_address(
            apply_l2_to_l1_alias(config.protocol_upgrade_handler_proxy_address),
            "aliased_protocol_upgrade_handler_proxy",
        );
        result.add_address(
            bytecode_verifier
                .compute_expected_address_for_file("l1-contracts/L2SharedBridgeLegacy"),
            "l2_shared_bridge_legacy_impl",
        );
        result.add_address(
            bytecode_verifier
                .compute_expected_address_for_file("l1-contracts/BridgedStandardERC20"),
            "erc20_bridged_standard",
        );
        result.add_address(
            bytecode_verifier.compute_expected_address_for_file("l2-contracts/RollupL2DAValidator"),
            "rollup_l2_da_validator",
        );
        result.add_address(
            bytecode_verifier
                .compute_expected_address_for_file("l2-contracts/ValidiumL2DAValidator"),
            "validium_l2_da_validator",
        );

        config.add_to_verifier(&mut result);
        result.add_address(
            network_verifier
                .get_proxy_admin(config.protocol_upgrade_handler_proxy_address)
                .await,
            "protocol_upgrade_handler_transparent_proxy_admin",
        );

        // Now, we append the bridgehub info
        let info = network_verifier.get_bridgehub_info(bridgehub_addr).await;

        result.add_address(bridgehub_addr, "bridgehub_proxy");
        result.add_address(info.stm_address, "state_transition_manager");
        result.add_address(info.transparent_proxy_admin, "transparent_proxy_admin");
        result.add_address(info.shared_bridge, "l1_asset_router_proxy");
        result.add_address(info.legacy_bridge, "legacy_erc20_bridge_proxy");
        result.add_address(info.validator_timelock, "old_validator_timelock");
        result.add_address(info.native_token_vault, "native_token_vault");

        result.add_address(info.l1_nullifier, "l1_nullifier_proxy_addr");
        result.add_address(info.l1_asset_router_proxy_addr, "l1_asset_router_proxy");

        result.add_address(info.gateway_base_token_addr, "gateway_base_token");

        result.add_address(address_from_short_hex("10002"), "l2_bridgehub");

        // Add gateway addresses
        result.add_address(
            config.gateway.gateway_state_transition.admin_facet_addr,
            "gateway_admin_facet_addr",
        );
        result.add_address(
            config
                .gateway
                .gateway_state_transition
                .chain_type_manager_implementation_addr,
            "gateway_chain_type_manager_implementation_addr",
        );
        result.add_address(
            config
                .gateway
                .gateway_state_transition
                .chain_type_manager_proxy,
            "gateway_chain_type_manager_proxy",
        );
        result.add_address(
            config.gateway.gateway_state_transition.diamond_init_addr,
            "gateway_diamond_init_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.default_upgrade_addr,
            "gateway_default_upgrade_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.executor_facet_addr,
            "gateway_executor_facet_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.genesis_upgrade_addr,
            "gateway_genesis_upgrade_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.getters_facet_addr,
            "gateway_getters_facet_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.mailbox_facet_addr,
            "gateway_mailbox_facet_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.verifier_addr,
            "gateway_verifier_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.verifier_fflonk_addr,
            "gateway_verifier_fflonk_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.verifier_plonk_addr,
            "gateway_verifier_plonk_addr",
        );
        result.add_address(
            config.gateway.gateway_state_transition.rollup_da_manager,
            "gateway_rollup_da_manager",
        );
        result.add_address(
            config
                .gateway
                .gateway_state_transition
                .rollup_l2_da_validator,
            "gateway_rollup_l2_da_validator",
        );

        result
    }

    pub fn reverse_lookup(&self, address: &Address) -> Option<&String> {
        self.address_to_name.get(address)
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
