use std::path::PathBuf;

use alloy::primitives::{Address, B256};
use alloy::sol_types::SolCall;
use serde::{Deserialize, Serialize};

use crate::common::abi::{
    AdminFunctionsAbi, IDeployCTMAbi, IDeployL1CoreContractsAbi, IFinalizeChainInitAbi,
    IRegisterOnAllChainsAbi,
};

pub mod deploy_ctm;
pub mod deploy_ecosystem;
pub mod register_chain;

pub const ADMIN_FUNCTIONS_SCRIPT_PATH: &str = "deploy-scripts/AdminFunctions.s.sol";
pub const FINALIZE_CHAIN_INIT_SCRIPT_PATH: &str = "deploy-scripts/chain/FinalizeChainInit.s.sol";

/// The current release's core and CTM upgrade scripts, the prepare defaults. `scripts/new-release.ts`
/// generates them as subclasses of `DefaultCoreUpgrade` / `DefaultCTMUpgrade` and moves these paths on a
/// release bump.
pub const CURRENT_CORE_UPGRADE_SCRIPT_PATH: &str =
    "deploy-scripts/upgrade/v35/CoreUpgrade_v35.s.sol";
pub const CURRENT_CTM_UPGRADE_SCRIPT_PATH: &str = "deploy-scripts/upgrade/v35/CTMUpgrade_v35.s.sol";
/// The current release's upgrade-env directory, relative to `l1-contracts/`. The prepare input default and
/// `--env` resolution (`EnvConfig`) derive from it. `scripts/new-release.ts` moves it on a release bump.
macro_rules! current_upgrade_env_dir {
    () => {
        "upgrade-envs/v0.35.0-upgrade-system"
    };
}
pub const CURRENT_UPGRADE_ENV_DIR: &str = concat!("/", current_upgrade_env_dir!());
pub const CURRENT_UPGRADE_LOCAL_INPUT_PATH: &str =
    concat!("/", current_upgrade_env_dir!(), "/local.toml");
/// Core prepare output. Version-free: every release's prepare writes it.
pub const UPGRADE_CORE_OUTPUT_PATH: &str = "/script-out/upgrade-core.toml";
/// Per-CTM prepare output, `<prefix><ctm proxy>.toml` (lowercase hex). Version-free, like the core output.
pub const UPGRADE_CTM_OUTPUT_PATH_PREFIX: &str = "/script-out/upgrade-ctm-";
pub const UPGRADE_V33_ENV_DIR: &str = "/upgrade-envs/v0.33.0-atomic-interop";

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

pub static REGISTER_CHAIN_INVOCATION: ForgeScriptParams = ForgeScriptParams::new(
    "script-config/register-zk-chain.toml",
    "script-out/output-register-zk-chain.toml",
    "deploy-scripts/ctm/RegisterZKChain.s.sol",
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

/// Links a typed [`SolCall`] to its [`ForgeScriptParams`] invocation.
/// Implemented via the [`script_calls!`] table — do not implement by hand.
pub trait ScriptCall: SolCall {
    fn invocation() -> &'static ForgeScriptParams;
}

macro_rules! script_calls {
    ($($call:ty => $inv:path),+ $(,)?) => {
        $(impl ScriptCall for $call {
            fn invocation() -> &'static ForgeScriptParams { &$inv }
        })+
    };
}

script_calls! {
    // AdminFunctions
    AdminFunctionsAbi::pauseDepositsBeforeInitiatingMigrationCall       => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::setDAValidatorPairCall                           => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::governanceExecuteCallsCall                       => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::adminScheduleUpgradeCall                         => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::governanceAcceptOwnerCall                        => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::chainAdminAcceptAdminCall                        => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::chainAdminAcceptOwnerCall                        => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::governanceAcceptOwnerConditionalCall             => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::governanceAcceptOwnerAggregatedCall              => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::ensureCtmsAndProxyAdminsOwnedByGovernanceWithWrapsCall => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::executeOwnableCallsWithWrapsCall                 => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::upgradeChainFromCTMCall                          => ADMIN_FUNCTIONS_INVOCATION,
    AdminFunctionsAbi::updateValidatorCall                              => ADMIN_FUNCTIONS_INVOCATION,
    // Other scripts
    IFinalizeChainInitAbi::finalizeChainInitCall                        => FINALIZE_CHAIN_INIT_INVOCATION,
    IRegisterOnAllChainsAbi::registerOnOtherChainsCall                  => REGISTER_ON_ALL_CHAINS_INVOCATION,
    IDeployL1CoreContractsAbi::runInnerCall                             => DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION,
    // DeployCTM
    IDeployCTMAbi::runInnerCall                                         => DEPLOY_CTM_INVOCATION,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Create2Addresses {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: B256,
}
