use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;

use alloy::primitives::{Address, B256};
use alloy::sol_types::SolCall;
use anyhow::Context;
use serde::{Deserialize, Serialize};

use crate::common::abi::{
    AdminFunctionsAbi, IDeployCTMAbi, IDeployL1CoreContractsAbi, IFinalizeChainInitAbi,
};
use crate::common::paths;
use crate::upgrade_verification::registry::genesis::ZKSYNC_OS_GENESIS_CONFIG_PATH;

pub mod deploy_ctm;
pub mod deploy_ecosystem;
pub mod member_deployments;
pub mod register_chain;
pub mod upgrade_executors;

pub const ADMIN_FUNCTIONS_SCRIPT_PATH: &str = "deploy-scripts/AdminFunctions.s.sol";
pub const FINALIZE_CHAIN_INIT_SCRIPT_PATH: &str = "deploy-scripts/chain/FinalizeChainInit.s.sol";

/// The release `configs/genesis/zksync-os/latest.json` is at: its upgrade-env directory, the one
/// `upgrade-envs/v<major>.<minor>.<patch>-<name>/`, and its core and CTM upgrade scripts under
/// `deploy-scripts/upgrade/v<minor>/`. The prepare defaults and `--env` resolution (`EnvConfig`) follow it;
/// another edge's scripts are selected with `--core-script-path` / `--ctm-script-path`.
#[derive(Debug)]
pub struct CurrentRelease {
    /// The upgrade-env directory's name under `upgrade-envs/`, `v<major>.<minor>.<patch>-<name>`.
    pub upgrade: String,
    pub core_script_path: String,
    pub ctm_script_path: String,
}

impl CurrentRelease {
    /// The upgrade-env directory, relative to `l1-contracts/`.
    pub fn env_dir(&self) -> String {
        format!("upgrade-envs/{}", self.upgrade)
    }

    /// The local upgrade input, the prepare's default `--upgrade-input-path`.
    pub fn local_input_path(&self) -> String {
        format!("/{}/local.toml", self.env_dir())
    }
}

/// The current release, read once per process.
pub fn current_release() -> anyhow::Result<&'static CurrentRelease> {
    static CURRENT: OnceLock<Result<CurrentRelease, String>> = OnceLock::new();
    CURRENT
        .get_or_init(|| read_current_release().map_err(|e| format!("{e:#}")))
        .as_ref()
        .map_err(|e| anyhow::anyhow!("cannot resolve the current release: {e}"))
}

fn read_current_release() -> anyhow::Result<CurrentRelease> {
    let l1_contracts = paths::resolve_l1_contracts_path()?;
    let genesis_path = l1_contracts
        .parent()
        .context("l1-contracts has no parent directory")?
        .join(ZKSYNC_OS_GENESIS_CONFIG_PATH);
    let genesis: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(&genesis_path)
            .with_context(|| format!("read {}", genesis_path.display()))?,
    )
    .with_context(|| format!("parse {}", genesis_path.display()))?;
    let version = |part: &str| {
        genesis["protocol_semantic_version"][part]
            .as_u64()
            .with_context(|| {
                format!(
                    "{} has no protocol_semantic_version.{part}",
                    genesis_path.display()
                )
            })
    };
    let (major, minor, patch) = (version("major")?, version("minor")?, version("patch")?);
    let prefix = format!("v{major}.{minor}.{patch}-");
    let envs_dir = l1_contracts.join("upgrade-envs");
    let mut dirs = Vec::new();
    for entry in fs::read_dir(&envs_dir).with_context(|| format!("read {}", envs_dir.display()))? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(&prefix) && entry.path().is_dir() {
            dirs.push(name);
        }
    }
    let [upgrade] = <[String; 1]>::try_from(dirs).map_err(|dirs| {
        anyhow::anyhow!(
            "{} is at v{major}.{minor}.{patch}, so {} must hold exactly one {prefix}<name> directory; found {dirs:?}",
            genesis_path.display(),
            envs_dir.display()
        )
    })?;
    Ok(CurrentRelease {
        upgrade,
        core_script_path: format!("deploy-scripts/upgrade/v{minor}/CoreUpgrade_v{minor}.s.sol"),
        ctm_script_path: format!("deploy-scripts/upgrade/v{minor}/CTMUpgrade_v{minor}.s.sol"),
    })
}

/// Core prepare output. Version-free: every release's prepare writes it.
pub const UPGRADE_CORE_OUTPUT_PATH: &str = "/script-out/upgrade-core.toml";
/// Per-CTM prepare output, `<prefix><ctm proxy>.toml` (lowercase hex). Version-free, like the core output.
pub const UPGRADE_CTM_OUTPUT_PATH_PREFIX: &str = "/script-out/upgrade-ctm-";

#[derive(Debug, Clone, Copy)]
pub struct ForgeScriptParams {
    input: &'static str,
    output: &'static str,
    script_path: &'static str,
    ffi: bool,
    rpc_url: bool,
}

impl ForgeScriptParams {
    pub const fn new(input: &'static str, output: &'static str, script_path: &'static str) -> Self {
        Self {
            input,
            output,
            script_path,
            ffi: false,
            rpc_url: false,
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
    AdminFunctionsAbi::executeChainAdminMulticallCall                   => ADMIN_FUNCTIONS_INVOCATION,
    // Other scripts
    IFinalizeChainInitAbi::finalizeChainInitCall                        => FINALIZE_CHAIN_INIT_INVOCATION,
    IDeployL1CoreContractsAbi::runInnerCall                             => DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION,
    // DeployCTM
    IDeployCTMAbi::runInnerCall                                         => DEPLOY_CTM_INVOCATION,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Create2Addresses {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: B256,
}
