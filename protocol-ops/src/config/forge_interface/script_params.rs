use std::path::{Path, PathBuf};

use ethers::contract::BaseContract;
use lazy_static::lazy_static;

use crate::abi_contracts::{
    ADMIN_FUNCTIONS_CONTRACT, DEPLOY_CTM_CONTRACT, DEPLOY_GATEWAY_TRANSACTION_FILTERER_CONTRACT,
    DEPLOY_L2_CONTRACTS_CONTRACT, DEPLOY_PAYMASTER_CONTRACT, ENABLE_EVM_EMULATOR_CONTRACT,
    FINALIZE_CHAIN_INIT_CONTRACT, GATEWAY_UTILS_CONTRACT, GATEWAY_VOTE_PREPARATION_CONTRACT,
    REGISTER_CHAIN_CONTRACT, REGISTER_CTM_CONTRACT, REGISTER_ON_ALL_CHAINS_CONTRACT,
    SETUP_LEGACY_BRIDGE_CONTRACT,
};

pub const ADMIN_FUNCTIONS_SCRIPT_PATH: &str = "deploy-scripts/AdminFunctions.s.sol";
pub const FINALIZE_CHAIN_INIT_SCRIPT_PATH: &str = "deploy-scripts/chain/FinalizeChainInit.s.sol";
pub const ECOSYSTEM_UPGRADE_V31_SCRIPT_PATH: &str =
    "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
pub const UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH: &str = "/upgrade-envs/v0.31.0-interopB/local.toml";
pub const UPGRADE_V31_CORE_OUTPUT_PATH: &str = "/script-out/v31-upgrade-core.toml";
pub const UPGRADE_V31_CTM_OUTPUT_PATH: &str = "/script-out/v31-upgrade-ctm.toml";
pub const UPGRADE_V31_ECOSYSTEM_OUTPUT_PATH: &str = "/script-out/v31-upgrade-ecosystem.toml";
pub const GATEWAY_UTILS_SCRIPT_TARGET_PATH: &str =
    "deploy-scripts/gateway/GatewayUtils.s.sol:GatewayUtils";
pub const DEPLOY_GATEWAY_TRANSACTION_FILTERER_SCRIPT_TARGET_PATH: &str =
    "deploy-scripts/gateway/DeployGatewayTransactionFilterer.s.sol:DeployGatewayTransactionFilterer";
pub const GATEWAY_VOTE_PREPARATION_SCRIPT_PATH: &str =
    "deploy-scripts/gateway/GatewayVotePreparation.s.sol";

#[derive(Debug, Clone, Copy)]
pub struct FoundryScriptParams {
    input: &'static str,
    output: &'static str,
    script_path: &'static str,
    ffi: bool,
    rpc_url: bool,
    gas_limit: Option<u64>,
    abi: Option<&'static BaseContract>,
}

impl ForgeScriptParams {
    // Path to the input file for forge script
    pub fn input(&self, path_to_l1_foundry: &Path) -> PathBuf {
        path_to_l1_foundry.join(self.input)
    }

    // Path to the output file for forge script
    pub fn output(&self, path_to_l1_foundry: &Path) -> PathBuf {
        path_to_l1_foundry.join(self.output)
    }

    // Path to the script
    pub fn script(&self) -> PathBuf {
        PathBuf::from(self.script_path)
    }
}

pub const DEPLOY_CTM_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-deploy-ctm.toml",
    output: "script-out/output-deploy-ctm.toml",
    script_path: "deploy-scripts/ctm/DeployCTM.s.sol",
};

pub const DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-deploy-l1.toml",
    output: "script-out/output-deploy-l1.toml",
    script_path: "deploy-scripts/ecosystem/DeployL1CoreContracts.s.sol",
};

pub const REGISTER_CTM_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-register-ctm-l1.toml",
    output: "script-out/register-ctm-l1.toml",
    script_path: "deploy-scripts/ecosystem/RegisterCTM.s.sol",
};

pub const ADMIN_FUNCTIONS_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-admin-functions.toml",
    output: "script-out/output-admin-functions.toml",
    script_path: "deploy-scripts/AdminFunctions.s.sol",
};

pub const DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-deploy-l2-contracts.toml",
    output: "script-out/output-deploy-l2-contracts.toml",
    script_path: "deploy-scripts/chain/DeployL2Contracts.sol",
};

pub const REGISTER_CHAIN_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/register-zk-chain.toml",
    output: "script-out/output-register-zk-chain.toml",
    script_path: "deploy-scripts/ctm/RegisterZKChain.s.sol",
};

pub const DEPLOY_PAYMASTER_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-deploy-paymaster.toml",
    output: "script-out/output-deploy-paymaster.toml",
    script_path: "deploy-scripts/chain/DeployPaymaster.s.sol",
};

pub const SETUP_LEGACY_BRIDGE: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/setup-legacy-bridge.toml",
    output: "script-out/setup-legacy-bridge.toml",
    script_path: "deploy-scripts/dev/SetupLegacyBridge.s.sol",
};

pub const ENABLE_EVM_EMULATOR_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/enable-evm-emulator.toml",
    output: "script-out/output-enable-evm-emulator.toml",
    script_path: "deploy-scripts/chain/EnableEvmEmulator.s.sol",
};

pub const _REGISTER_ON_ALL_CHAINS_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/register-on-all-chains.toml",
    output: "script-out/output-register-on-all-chains.toml",
    script_path: "deploy-scripts/ecosystem/RegisterOnAllChains.s.sol",
};
