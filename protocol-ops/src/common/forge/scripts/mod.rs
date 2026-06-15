use std::path::PathBuf;

use alloy::primitives::{Address, B256};
use serde::{Deserialize, Serialize};

pub mod admin;
pub mod deploy_ctm;
pub mod deploy_ecosystem;
pub mod deploy_l2_contracts;
pub mod register_chain;

pub const ADMIN_FUNCTIONS_SCRIPT_PATH: &str = "deploy-scripts/AdminFunctions.s.sol";
pub const FINALIZE_CHAIN_INIT_SCRIPT_PATH: &str = "deploy-scripts/chain/FinalizeChainInit.s.sol";
pub const CORE_UPGRADE_V31_SCRIPT_PATH: &str = "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
pub const CTM_UPGRADE_V31_SCRIPT_PATH: &str = "deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
pub const UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH: &str = "/upgrade-envs/v0.31.0-interopB/local.toml";
pub const UPGRADE_V31_CORE_OUTPUT_PATH: &str = "/script-out/v31-upgrade-core.toml";
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

    pub const fn with_gas_limit(mut self, gas_limit: u64) -> Self {
        self.gas_limit = Some(gas_limit);
        self
    }

    // Conventional input/output paths, relative to the l1-contracts root.
    // Absolute path resolution goes through `ForgeRunner::input_path` /
    // `output_path` so the per-run `--subdir` (if any) is always applied.
    pub(crate) fn input_rel(&self) -> &'static str {
        self.input
    }

    pub(crate) fn output_rel(&self) -> &'static str {
        self.output
    }

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
}

pub static DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/config-deploy-l1.toml",
    "script-out/output-deploy-l1.toml",
    "deploy-scripts/ecosystem/DeployL1CoreContracts.s.sol",
)
.with_ffi()
.with_rpc_url();

pub static DEPLOY_CTM_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/config-deploy-ctm.toml",
    "script-out/output-deploy-ctm.toml",
    "deploy-scripts/ctm/DeployCTM.s.sol",
)
.with_ffi()
.with_rpc_url();

pub static REGISTER_CTM_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/config-register-ctm-l1.toml",
    "script-out/register-ctm-l1.toml",
    "deploy-scripts/ecosystem/RegisterCTM.s.sol",
)
.with_ffi()
.with_rpc_url();

pub static ADMIN_FUNCTIONS_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/config-admin-functions.toml",
    "script-out/output-admin-functions.toml",
    ADMIN_FUNCTIONS_SCRIPT_PATH,
)
.with_ffi()
.with_rpc_url();

pub static FINALIZE_CHAIN_INIT_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/finalize-chain-init.toml",
    "script-out/finalize-chain-init.toml",
    FINALIZE_CHAIN_INIT_SCRIPT_PATH,
)
.with_ffi()
.with_rpc_url();

pub static GATEWAY_UTILS_INVOCATION: ForgeScriptParams =
    ForgeScriptParams::new("", "", GATEWAY_UTILS_SCRIPT_TARGET_PATH).with_rpc_url();

pub static DEPLOY_GATEWAY_TRANSACTION_FILTERER_INVOCATION: ForgeScriptParams =
    ForgeScriptParams::new(
        "",
        "",
        DEPLOY_GATEWAY_TRANSACTION_FILTERER_SCRIPT_TARGET_PATH,
    )
    .with_ffi()
    .with_rpc_url();

pub static GATEWAY_VOTE_PREPARATION_INVOCATION: ForgeScriptParams =
    ForgeScriptParams::new("", "", GATEWAY_VOTE_PREPARATION_SCRIPT_PATH)
        .with_ffi()
        .with_rpc_url();

pub static DEPLOY_L2_CONTRACTS_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/config-deploy-l2-contracts.toml",
    "script-out/output-deploy-l2-contracts.toml",
    "deploy-scripts/chain/DeployL2Contracts.sol",
)
.with_ffi()
.with_rpc_url();

pub static REGISTER_CHAIN_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/register-zk-chain.toml",
    "script-out/output-register-zk-chain.toml",
    "deploy-scripts/ctm/RegisterZKChain.s.sol",
)
.with_ffi()
.with_rpc_url();

pub static DEPLOY_PAYMASTER_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/config-deploy-paymaster.toml",
    "script-out/output-deploy-paymaster.toml",
    "deploy-scripts/chain/DeployPaymaster.s.sol",
)
.with_ffi()
.with_rpc_url();

pub static SETUP_LEGACY_BRIDGE_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/setup-legacy-bridge.toml",
    "script-out/setup-legacy-bridge.toml",
    "deploy-scripts/dev/SetupLegacyBridge.s.sol",
)
.with_ffi()
.with_rpc_url();

pub static ENABLE_EVM_EMULATOR_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/enable-evm-emulator.toml",
    "script-out/output-enable-evm-emulator.toml",
    "deploy-scripts/chain/EnableEvmEmulator.s.sol",
)
.with_ffi()
.with_rpc_url();

pub static REGISTER_ON_ALL_CHAINS_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/register-on-all-chains.toml",
    "script-out/output-register-on-all-chains.toml",
    "deploy-scripts/ecosystem/RegisterOnAllChains.s.sol",
)
.with_ffi()
.with_rpc_url();

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Create2Addresses {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: B256,
}
