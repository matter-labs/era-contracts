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
pub const CORE_UPGRADE_V31_SCRIPT_PATH: &str = "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
pub const CTM_UPGRADE_V31_SCRIPT_PATH: &str = "deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
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
pub struct ForgeScriptParams {
    input: &'static str,
    output: &'static str,
    script_path: &'static str,
    ffi: bool,
    rpc_url: bool,
    gas_limit: Option<u64>,
    abi: Option<&'static BaseContract>,
}

impl ForgeScriptParams {
    pub const fn new(input: &'static str, output: &'static str, script_path: &'static str) -> Self {
        Self {
            input,
            output,
            script_path,
            ffi: false,
            rpc_url: false,
            gas_limit: None,
            abi: None,
        }
    }

    pub const fn with_ffi(mut self) -> Self {
        self.ffi = true;
        self
    }

    pub const fn with_rpc_url(mut self) -> Self {
        self.rpc_url = true;
        self
    }

    pub const fn with_abi(mut self, abi: &'static BaseContract) -> Self {
        self.abi = Some(abi);
        self
    }

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

    pub fn ffi(&self) -> bool {
        self.ffi
    }

    pub fn rpc_url(&self) -> bool {
        self.rpc_url
    }

    pub fn gas_limit(&self) -> Option<u64> {
        self.gas_limit
    }

    pub fn abi(&self) -> Option<&'static BaseContract> {
        self.abi
    }
}

pub const DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION: ForgeScriptParams =
    ForgeScriptParams::new(
        "script-config/config-deploy-l1.toml",
        "script-out/output-deploy-l1.toml",
        "deploy-scripts/ecosystem/DeployL1CoreContracts.s.sol",
    )
    .with_ffi()
    .with_rpc_url();

lazy_static! {
    pub static ref DEPLOY_CTM_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/config-deploy-ctm.toml",
        "script-out/output-deploy-ctm.toml",
        "deploy-scripts/ctm/DeployCTM.s.sol",
    )
    .with_abi(&DEPLOY_CTM_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref REGISTER_CTM_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/config-register-ctm-l1.toml",
        "script-out/register-ctm-l1.toml",
        "deploy-scripts/ecosystem/RegisterCTM.s.sol",
    )
    .with_abi(&REGISTER_CTM_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref ADMIN_FUNCTIONS_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/config-admin-functions.toml",
        "script-out/output-admin-functions.toml",
        ADMIN_FUNCTIONS_SCRIPT_PATH,
    )
    .with_abi(&ADMIN_FUNCTIONS_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref FINALIZE_CHAIN_INIT_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/finalize-chain-init.toml",
        "script-out/finalize-chain-init.toml",
        FINALIZE_CHAIN_INIT_SCRIPT_PATH,
    )
    .with_abi(&FINALIZE_CHAIN_INIT_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref GATEWAY_UTILS_INVOCATION: ForgeScriptParams =
        ForgeScriptParams::new("", "", GATEWAY_UTILS_SCRIPT_TARGET_PATH)
            .with_abi(&GATEWAY_UTILS_CONTRACT)
            .with_rpc_url();
    pub static ref DEPLOY_GATEWAY_TRANSACTION_FILTERER_INVOCATION: ForgeScriptParams =
        ForgeScriptParams::new(
            "",
            "",
            DEPLOY_GATEWAY_TRANSACTION_FILTERER_SCRIPT_TARGET_PATH,
        )
        .with_abi(&DEPLOY_GATEWAY_TRANSACTION_FILTERER_CONTRACT)
        .with_ffi()
        .with_rpc_url();
    pub static ref GATEWAY_VOTE_PREPARATION_INVOCATION: ForgeScriptParams =
        ForgeScriptParams::new("", "", GATEWAY_VOTE_PREPARATION_SCRIPT_PATH)
            .with_abi(&GATEWAY_VOTE_PREPARATION_CONTRACT)
            .with_ffi()
            .with_rpc_url();
    pub static ref DEPLOY_L2_CONTRACTS_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/config-deploy-l2-contracts.toml",
        "script-out/output-deploy-l2-contracts.toml",
        "deploy-scripts/chain/DeployL2Contracts.sol",
    )
    .with_abi(&DEPLOY_L2_CONTRACTS_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref REGISTER_CHAIN_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/register-zk-chain.toml",
        "script-out/output-register-zk-chain.toml",
        "deploy-scripts/ctm/RegisterZKChain.s.sol",
    )
    .with_abi(&REGISTER_CHAIN_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref DEPLOY_PAYMASTER_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/config-deploy-paymaster.toml",
        "script-out/output-deploy-paymaster.toml",
        "deploy-scripts/chain/DeployPaymaster.s.sol",
    )
    .with_abi(&DEPLOY_PAYMASTER_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref SETUP_LEGACY_BRIDGE_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/setup-legacy-bridge.toml",
        "script-out/setup-legacy-bridge.toml",
        "deploy-scripts/dev/SetupLegacyBridge.s.sol",
    )
    .with_abi(&SETUP_LEGACY_BRIDGE_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref ENABLE_EVM_EMULATOR_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
        "script-config/enable-evm-emulator.toml",
        "script-out/output-enable-evm-emulator.toml",
        "deploy-scripts/chain/EnableEvmEmulator.s.sol",
    )
    .with_abi(&ENABLE_EVM_EMULATOR_CONTRACT)
    .with_ffi()
    .with_rpc_url();
    pub static ref REGISTER_ON_ALL_CHAINS_INVOCATION: ForgeScriptParams =
        ForgeScriptParams::new(
            "script-config/register-on-all-chains.toml",
            "script-out/output-register-on-all-chains.toml",
            "deploy-scripts/ecosystem/RegisterOnAllChains.s.sol",
        )
        .with_abi(&REGISTER_ON_ALL_CHAINS_CONTRACT)
        .with_ffi()
        .with_rpc_url();
}
