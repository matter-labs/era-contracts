//! Per-env config loader.
//!
//! Most ecosystem and gov commands need the same per-env addresses (bridgehub,
//! CTM list with overrides, era chain id, deployer/owner, create2 factory).
//! Rather than asking the user to pass every flag explicitly, commands that
//! flatten an [`crate::common::EcosystemArgs`] expose `--env <name>` which
//! reads `upgrade-envs/permanent-values/<env>.toml` (and the v31 upgrade input
//! TOML for env-specific values like `era_chain_id` / `owner_address`) and
//! fills the missing args.
//!
//! Any explicit CLI flag still wins — `--env` is purely a defaults source.
//!
//! Layout (relative to `l1-contracts/`):
//!
//!   upgrade-envs/permanent-values/<env>.toml      (bridgehub, ctms, create2)
//!   upgrade-envs/v0.31.0-interopB/<env>.toml      (owner, era_chain_id)
//!
//! The latter contains unquoted hex literals (e.g. `old_protocol_version =
//! 0x1d…`) which `toml-rs` chokes on, so we parse it line-by-line for the
//! handful of fields we need.

use std::fs;
use std::path::PathBuf;

use anyhow::Context;
use ethers::types::{Address, H256};
use serde::Deserialize;

use crate::common::paths::resolve_l1_contracts_path;

const V31_UPGRADE_DIR: &str = "upgrade-envs/v0.31.0-interopB";
const PERMANENT_VALUES_DIR: &str = "upgrade-envs/permanent-values";

#[derive(Debug, Deserialize)]
pub struct PermanentValues {
    pub core_contracts: CoreContracts,
    #[serde(default)]
    pub ctm_contracts: Option<CtmContracts>,
    #[serde(default)]
    pub permanent_contracts: Option<PermanentContracts>,
    /// Per-env registry of contract owners that own a CTM / ProxyAdmin and
    /// must have ownership-transfer calls *wrapped* through them (since they
    /// have no private key). Mirrors `OwnerWrap` in `IAdminFunctions.sol`.
    /// Empty/absent on envs where every current owner is already an EOA.
    #[serde(default, rename = "ownable_proxies")]
    pub ownable_proxies: Vec<OwnableProxyEntry>,
}

#[derive(Debug, Deserialize, Clone, Copy)]
pub struct OwnableProxyEntry {
    pub addr: Address,
    pub kind: OwnableProxyKind,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OwnableProxyKind {
    /// Legacy ZKsync `Governance.sol` (Ownable2Step + delay-gated). Wrap as
    /// `scheduleTransparent(op, 0)` + `executeInstant(op)` from the EOA owner.
    LegacyGovernance,
    /// OZ `ChainAdmin` (Ownable2Step). Wrap as `multicall([call], true)`
    /// from the EOA owner.
    OzChainAdmin,
}

impl OwnableProxyKind {
    /// Mirrors the `OWNER_KIND_*` constants in
    /// `l1-contracts/contracts/script-interfaces/IAdminFunctions.sol`.
    pub fn to_solidity_u8(self) -> u8 {
        match self {
            Self::LegacyGovernance => 1,
            Self::OzChainAdmin => 2,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct CoreContracts {
    pub bridgehub_proxy_addr: Address,
    /// Which governance contract sits at `bridgehub.owner()`. Drives the
    /// fork-replay path (`v31 governance`):
    ///   - `legacy` (default): legacy ZKsync `Governance.sol` Ownable2Step
    ///     timelock. Replay goes through `Utils.executeCalls` (scheduleTransparent
    ///     + execute, signed by the Ownable owner).
    ///   - `puh`: `ProtocolUpgradeHandler` (no `Ownable.owner()`, real-chain
    ///     execution requires guardians + security council EIP-712 sigs).
    ///     Fork replay short-circuits via `governanceExecuteCallsDirect` —
    ///     anvil impersonates the handler and forwards each call.
    #[serde(default)]
    pub governance_kind: GovernanceKind,
}

#[derive(Debug, Deserialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GovernanceKind {
    #[default]
    Legacy,
    Puh,
}

#[derive(Debug, Deserialize)]
pub struct CtmContracts {
    /// Legacy single-CTM Era address (kept for anvil-interop). New consumers
    /// should read the `ctms` array.
    #[serde(default)]
    pub ctm_proxy_addr: Option<Address>,
    /// v31 multi-CTM list — proxy + per-CTM overrides for pre-v31 envs.
    #[serde(default, rename = "ctms")]
    pub ctms: Vec<CtmEntry>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CtmEntry {
    pub proxy: Address,
    #[serde(default)]
    pub is_zk_sync_os: Option<bool>,
    #[serde(default)]
    pub bytecodes_supplier: Option<Address>,
    #[serde(default)]
    pub rollup_da_manager: Option<Address>,
}

#[derive(Debug, Deserialize)]
pub struct PermanentContracts {
    #[serde(default)]
    pub create2_factory_addr: Option<Address>,
    #[serde(default)]
    pub create2_factory_salt: Option<H256>,
}

/// Fields read from the v31 upgrade input TOML (best-effort regex parse —
/// the file has unquoted hex literals that the TOML crate rejects).
#[derive(Debug, Default, Clone)]
pub struct V31UpgradeInputs {
    pub owner_address: Option<Address>,
    pub era_chain_id: Option<u64>,
}

/// Fully-resolved per-env config.
#[derive(Debug)]
pub struct EnvConfig {
    pub env: String,
    pub permanent_values_path: PathBuf,
    pub v31_input_path: PathBuf,
    pub permanent: PermanentValues,
    pub v31: V31UpgradeInputs,
}

impl EnvConfig {
    /// Load `<l1-contracts>/upgrade-envs/permanent-values/<env>.toml` and the
    /// v31 upgrade input TOML for the same env. Both files must exist.
    pub fn load(env: &str) -> anyhow::Result<Self> {
        let l1 = resolve_l1_contracts_path()?;
        let permanent_values_path = l1.join(PERMANENT_VALUES_DIR).join(format!("{env}.toml"));
        let v31_input_path = l1.join(V31_UPGRADE_DIR).join(format!("{env}.toml"));

        let pv_content = fs::read_to_string(&permanent_values_path).with_context(|| {
            format!(
                "Failed to read permanent-values TOML: {}",
                permanent_values_path.display()
            )
        })?;
        let permanent: PermanentValues = toml::from_str(&pv_content).with_context(|| {
            format!(
                "Failed to parse permanent-values TOML: {}",
                permanent_values_path.display()
            )
        })?;

        let v31 = if v31_input_path.exists() {
            parse_v31_upgrade_input(&fs::read_to_string(&v31_input_path)?)
        } else {
            V31UpgradeInputs::default()
        };

        Ok(EnvConfig {
            env: env.to_string(),
            permanent_values_path,
            v31_input_path,
            permanent,
            v31,
        })
    }

    pub fn bridgehub(&self) -> Address {
        self.permanent.core_contracts.bridgehub_proxy_addr
    }

    pub fn ctms(&self) -> &[CtmEntry] {
        match &self.permanent.ctm_contracts {
            Some(c) => &c.ctms,
            None => &[],
        }
    }

    pub fn create2_factory(&self) -> Option<Address> {
        self.permanent
            .permanent_contracts
            .as_ref()
            .and_then(|p| p.create2_factory_addr)
    }

    pub fn create2_factory_salt(&self) -> Option<H256> {
        self.permanent
            .permanent_contracts
            .as_ref()
            .and_then(|p| p.create2_factory_salt)
    }

    pub fn owner_address(&self) -> Option<Address> {
        self.v31.owner_address
    }

    pub fn era_chain_id(&self) -> Option<u64> {
        self.v31.era_chain_id
    }

    pub fn ownable_proxies(&self) -> &[OwnableProxyEntry] {
        &self.permanent.ownable_proxies
    }

    pub fn governance_kind(&self) -> GovernanceKind {
        self.permanent.core_contracts.governance_kind
    }
}

/// Default output dir for an env, e.g.
/// `upgrade-envs/v0.31.0-interopB/output/<env>/protocol-ops/`.
pub fn default_protocol_ops_out_dir(env: &str) -> anyhow::Result<PathBuf> {
    Ok(resolve_l1_contracts_path()?
        .join(V31_UPGRADE_DIR)
        .join("output")
        .join(env)
        .join("protocol-ops"))
}

fn parse_v31_upgrade_input(content: &str) -> V31UpgradeInputs {
    let mut out = V31UpgradeInputs::default();
    for line in content.lines() {
        let line = line.trim();
        if let Some(addr) = match_quoted_address(line, "owner_address") {
            out.owner_address = Some(addr);
        } else if let Some(id) = match_unquoted_uint(line, "era_chain_id") {
            out.era_chain_id = Some(id);
        }
    }
    out
}

fn match_quoted_address(line: &str, key: &str) -> Option<Address> {
    let prefix = format!("{key} = \"");
    if !line.starts_with(&prefix) {
        return None;
    }
    let rest = &line[prefix.len()..];
    let end = rest.find('"')?;
    rest[..end].parse().ok()
}

fn match_unquoted_uint(line: &str, key: &str) -> Option<u64> {
    let prefix = format!("{key} = ");
    if !line.starts_with(&prefix) {
        return None;
    }
    let rest = &line[prefix.len()..];
    // Strip optional trailing comment.
    let value = rest.split('#').next()?.trim();
    value.parse().ok()
}
