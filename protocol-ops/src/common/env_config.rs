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
use ethers::types::{Address, H256, U256};
use serde::Deserialize;

use crate::common::paths::resolve_l1_contracts_path;

const V31_UPGRADE_DIR: &str = "upgrade-envs/v0.31.0-interopB";
const PERMANENT_VALUES_DIR: &str = "upgrade-envs/permanent-values";

#[derive(Debug, Deserialize)]
pub struct PermanentValues {
    #[serde(default)]
    pub zk_token_asset_id: Option<H256>,
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
    /// Optional new-Gateway bring-up block. When present, the v31 ecosystem
    /// prepare flow runs `GatewayVotePreparation.s.sol` against this gateway
    /// and folds its `governance_calls_to_execute` into the merged stage-2
    /// hex — that single bundle whitelists the GW on L1, registers the GW
    /// CTM, wires asset handlers, accepts ownership of the GW RollupDAManager
    /// + ServerNotifier, and sets the initial interop settlement fee.
    #[serde(default)]
    pub new_gateway: Option<NewGatewayConfig>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct NewGatewayConfig {
    /// Chain ID of the gateway being brought up (e.g. 2708 for stage).
    pub chain_id: u64,
    /// Initial `gatewaySettlementFee` (wrapped-ZK wei) to write to the GW's
    /// `GWAssetTracker.setGatewaySettlementFee` via L1→L2 priority tx.
    /// Quoted with a `0x` prefix in TOML — ethers's `U256` serde reads quoted
    /// strings as hex (raw decimal in quotes is treated as a hex literal),
    /// so the TOML value must look like `settlement_fee = "0x3b9aca00"`.
    pub settlement_fee: U256,
    /// Where unused L1→L2 priority-tx gas is refunded. EOAs work as-is
    /// (`AddressAliasHelper` is a no-op on them), so the natural default is
    /// the deployer EOA that publishes the call on L1 — `prepare_new_gateway`
    /// applies that default when this field is absent. Override here only
    /// when you specifically want refunds to land somewhere else (e.g. a
    /// chain-admin Safe).
    ///
    /// NOTE: setting this to a contract (e.g. governance / PUH) makes refunds
    /// land at the aliased contract address on L2, which is generally
    /// uncontrolled — funds get stuck.
    #[serde(default)]
    pub refund_recipient: Option<Address>,
    /// Chain ID whose registered CTM `GatewayVotePreparation` should treat as
    /// the "source" — the deployed GW CTM is a variant of this CTM. Pick the
    /// chain whose CTM is the one the new gateway will host (typically Era).
    pub ctm_representative_chain_id: u64,
    /// Optional pre-deployed server notifier address. When present, the
    /// `GatewayVotePreparation` skips the redeploy + ownership-transfer
    /// preamble. Leave absent on first GW bring-up.
    #[serde(default)]
    pub server_notifier: Option<Address>,
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

    pub fn zk_token_asset_id(&self) -> Option<H256> {
        self.permanent.zk_token_asset_id
    }

    pub fn new_gateway(&self) -> Option<&NewGatewayConfig> {
        self.permanent.new_gateway.as_ref()
    }
}

/// Default output dir for an env, e.g.
/// `upgrade-envs/v0.31.0-interopB/output/<env>/`. Outputs land directly under
/// the env dir — no `protocol-ops/` subfolder — so the artifacts a reviewer
/// expects to find for stage / mainnet are immediately visible.
pub fn default_protocol_ops_out_dir(env: &str) -> anyhow::Result<PathBuf> {
    Ok(resolve_l1_contracts_path()?
        .join(V31_UPGRADE_DIR)
        .join("output")
        .join(env))
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Smoke-tests that `permanent-values/stage.toml` (which is the env used
    /// for the v31 prepare-all rehearsal on Sepolia stage) deserializes into
    /// `PermanentValues` end-to-end — including the optional `[new_gateway]`
    /// block and its U256 hex literal. Catches any future TOML drift before
    /// it shows up as a runtime parse error from `protocol-ops ecosystem
    /// upgrade-prepare-all --env stage`.
    #[test]
    fn stage_permanent_values_parses() {
        let path = resolve_l1_contracts_path()
            .expect("resolve l1-contracts")
            .join(PERMANENT_VALUES_DIR)
            .join("stage.toml");
        let raw = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
        let pv: PermanentValues = toml::from_str(&raw)
            .unwrap_or_else(|e| panic!("parse {}: {e}", path.display()));
        let ng = pv
            .new_gateway
            .expect("permanent-values/stage.toml must carry [new_gateway]");
        assert_eq!(ng.chain_id, 2708);
        // 0.2 ZK = 2e17 wei, sized for ~$0.01 per interop call at ZK ≈ $0.05.
        assert_eq!(
            ng.settlement_fee,
            U256::from(200_000_000_000_000_000u128)
        );
        // GW 2708 is a ZKsync OS chain → CTM source is Atlas (witness 2702).
        assert_eq!(ng.ctm_representative_chain_id, 2702);
    }
}
