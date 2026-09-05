pub mod call_list;
pub mod ctm_admin_calls;
pub mod deployed_addresses;
pub mod fixed_force_deployment;
pub mod governance_stage_calls;
pub mod initialize_data_new_chain;
pub mod protocol_version;
pub mod rpc_state;
pub mod set_new_version_upgrade;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum L1InteropHandlerPreparationMode {
    DeployAndWire,
    Reuse,
}

impl L1InteropHandlerPreparationMode {
    pub(crate) fn requires_proxy_deployment_provenance(self) -> bool {
        self == Self::DeployAndWire
    }
}
