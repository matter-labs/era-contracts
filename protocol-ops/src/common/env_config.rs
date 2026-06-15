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

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use alloy::primitives::{Address, B256, U256};
use anyhow::Context;
use serde::Deserialize;

use crate::common::paths::resolve_l1_contracts_path;

const V31_UPGRADE_DIR: &str = "upgrade-envs/v0.31.0-interopB";
const PERMANENT_VALUES_DIR: &str = "upgrade-envs/permanent-values";

#[derive(Debug, Deserialize)]
pub struct PermanentValues {
    /// L1 chain id (e.g. 11155111 for Sepolia, 1 for mainnet). PUVT reads
    /// this at startup and cross-checks `eth_chainId` against it as a basic
    /// "right network" sanity check.
    #[serde(default)]
    pub l1_chain_id: Option<u64>,
    #[serde(default)]
    pub zk_token_asset_id: Option<B256>,
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
    /// Historical gateway configuration for chains that settled on the legacy
    /// Gateway before v31.
    #[serde(default)]
    pub legacy_gateway: Option<LegacyGatewayConfig>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct LegacyGatewayConfig {
    pub chain_id: u64,
    /// Per-chain historical migration intervals that PUVT cross-checks against
    /// every `setHistoricalMigrationInterval` call in stage 2's decommission
    /// prefix. One TOML entry per call; order is preserved.
    #[serde(default)]
    pub chain_intervals: Vec<ChainInterval>,
}

/// Mirrors a `[[legacy_gateway.chain_intervals]]` entry in
/// `permanent-values/<env>.toml`. The Solidity struct
/// `MigrationInterval` ([IChainAssetHandler.sol]) is built from these fields
/// plus `settlementLayerChainId = legacy_gateway.chain_id` and
/// `isActive = false` (these are historical/completed intervals).
#[derive(Debug, Deserialize, Clone)]
pub struct ChainInterval {
    pub chain_id: u64,
    pub migrate_to_sl_batch: u64,
    pub migrate_from_sl_batch: u64,
    pub sl_batch_lower_bound: u64,
    pub sl_batch_upper_bound: u64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct NewGatewayConfig {
    /// Chain ID of the gateway being brought up (e.g. 2708 for stage).
    pub chain_id: u64,
    /// Initial `gatewaySettlementFee` (wrapped-ZK wei) to write to the GW's
    /// `GWAssetTracker.setGatewaySettlementFee` via L1→L2 priority tx.
    /// Quoted with a `0x` prefix in TOML — alloy's `U256` serde reads quoted
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
    /// Legacy single-CTM Era address. Only `anvil-interop` synthetic-state
    /// fixtures still read this flat field directly; every protocol-ops
    /// command consumes the multi-CTM `ctms` array below. TODO: thread the
    /// `[[ctm_contracts.ctms]]` shape through anvil-interop and remove this
    /// field so the legacy shape isn't carried in two places.
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
    // NOTE: `create2_factory_salt` deliberately does NOT live here. The salt
    // rotates every regen (the CREATE2 deployer would collide with previously
    // deployed addresses if reused), so it belongs in the v31 input TOML
    // (`upgrade-envs/v0.31.0-interopB/<env>.toml [contracts] create2_factory_salt`)
    // alongside the rest of the per-regen inputs. See
    // `EnvConfig::v31_create2_factory_salt`.
}

/// Fields read from the v31 upgrade input TOML (best-effort regex parse —
/// the file has unquoted hex literals that the TOML crate rejects).
///
/// CREATE2 salts are *not* stored here; `EnvConfig::v31_create2_factory_salt`
/// and `v31_create2_factory_salt_per_ctm` re-read them from
/// `v31_input_path` on demand. That way the salt-keyed entries are not
/// duplicated in Rust state — the TOML is the only source of truth.
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

    /// Per-upgrade-version CREATE2 salt from
    /// `upgrade-envs/v0.31.0-interopB/<env>.toml [contracts]
    /// create2_factory_salt`. Distinct from `create2_factory_salt()` (which
    /// reads the chain-permanent salt out of `permanent-values/`); this one
    /// is the salt used to deploy *this upgrade*'s implementations, recorded
    /// alongside the rest of the v31 inputs so re-prepares are reproducible.
    /// Re-reads the TOML each call rather than caching, so editing the file
    /// between commands is reflected without restarting the CLI.
    pub fn v31_create2_factory_salt(&self) -> anyhow::Result<Option<B256>> {
        if !self.v31_input_path.exists() {
            return Ok(None);
        }
        let content = fs::read_to_string(&self.v31_input_path)
            .with_context(|| format!("read {}", self.v31_input_path.display()))?;
        Ok(read_core_create2_salt(&content))
    }

    /// Per-regen salt for legacy `Governance.sol` ceremonies, read from
    /// `upgrade-envs/v0.31.0-interopB/<env>.toml [contracts] legacy_gov_salt`.
    /// Op ids in the legacy Gov state machine are content-addressed
    /// (`hash(targets, values, calldatas, predecessor, salt)`); rotating this
    /// salt every regen prevents the broadcaster from colliding with previously
    /// executed op ids that still sit in the on-chain `Done` map. When absent,
    /// returns `None` and the forge scripts default to `bytes32(0)`.
    pub fn v31_legacy_gov_salt(&self) -> anyhow::Result<Option<B256>> {
        if !self.v31_input_path.exists() {
            return Ok(None);
        }
        let content = fs::read_to_string(&self.v31_input_path)
            .with_context(|| format!("read {}", self.v31_input_path.display()))?;
        Ok(read_core_legacy_gov_salt(&content))
    }

    /// Per-CTM CREATE2 salts from
    /// `upgrade-envs/v0.31.0-interopB/<env>.toml [create2_factory_salts]`,
    /// keyed by CTM proxy. Empty if the env doesn't declare any (legacy
    /// local-fixture path — `v31_upgrade_inner` will fall back to random
    /// salts in that case). Re-reads the TOML each call (see
    /// `v31_create2_factory_salt`).
    pub fn v31_create2_factory_salt_per_ctm(&self) -> anyhow::Result<HashMap<Address, B256>> {
        if !self.v31_input_path.exists() {
            return Ok(HashMap::new());
        }
        let content = fs::read_to_string(&self.v31_input_path)
            .with_context(|| format!("read {}", self.v31_input_path.display()))?;
        Ok(read_create2_salts_per_ctm(&content))
    }

    pub fn owner_address(&self) -> Option<Address> {
        self.v31.owner_address
    }

    pub fn era_chain_id(&self) -> Option<u64> {
        self.v31.era_chain_id
    }

    /// Whether this is the mainnet ecosystem. Drives testnet-vs-real contract
    /// selection (e.g. the per-CTM verifier and the PUH redeploy: every
    /// non-mainnet env gets the zeroed-delay `TestnetProtocolUpgradeHandler`).
    pub fn is_mainnet(&self) -> bool {
        self.env == "mainnet"
    }

    pub fn legacy_gateway_chain_id(&self) -> Option<u64> {
        self.permanent.legacy_gateway.as_ref().map(|gw| gw.chain_id)
    }

    pub fn legacy_gateway_chain_intervals(&self) -> &[ChainInterval] {
        self.permanent
            .legacy_gateway
            .as_ref()
            .map(|gw| gw.chain_intervals.as_slice())
            .unwrap_or(&[])
    }

    pub fn l1_chain_id(&self) -> Option<u64> {
        self.permanent.l1_chain_id
    }

    pub fn ownable_proxies(&self) -> &[OwnableProxyEntry] {
        &self.permanent.ownable_proxies
    }

    pub fn governance_kind(&self) -> GovernanceKind {
        self.permanent.core_contracts.governance_kind
    }

    pub fn zk_token_asset_id(&self) -> Option<B256> {
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

/// Read `[contracts] create2_factory_salt` from a v31 input TOML.
fn read_core_create2_salt(content: &str) -> Option<B256> {
    read_h256_under_contracts(content, "create2_factory_salt")
}

fn read_core_legacy_gov_salt(content: &str) -> Option<B256> {
    read_h256_under_contracts(content, "legacy_gov_salt")
}

fn read_h256_under_contracts(content: &str, key: &str) -> Option<B256> {
    let mut in_contracts = false;
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(section) = parse_section_header(line) {
            in_contracts = section == "contracts";
            continue;
        }
        if in_contracts {
            if let Some(h) = match_quoted_h256(line, key) {
                return Some(h);
            }
        }
    }
    None
}

/// Read every `"0x<addr>" = "0x<h256>"` entry under `[create2_factory_salts]`.
fn read_create2_salts_per_ctm(content: &str) -> HashMap<Address, B256> {
    let mut out = HashMap::new();
    let mut current_section: Option<String> = None;
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(section) = parse_section_header(line) {
            current_section = Some(section);
            continue;
        }
        if current_section.as_deref() == Some("create2_factory_salts") {
            if let Some((addr, salt)) = match_addr_keyed_h256(line) {
                out.insert(addr, salt);
            }
        }
    }
    out
}

fn parse_section_header(line: &str) -> Option<String> {
    let line = line.split('#').next()?.trim();
    if !line.starts_with('[') || !line.ends_with(']') {
        return None;
    }
    Some(line[1..line.len() - 1].trim().to_string())
}

/// Match a TOML line of the form `"0x<addr>" = "0x<h256>"` (with optional
/// trailing comment). Returns the parsed address + salt.
fn match_addr_keyed_h256(line: &str) -> Option<(Address, B256)> {
    let line = line.split('#').next()?.trim();
    if !line.starts_with('"') {
        return None;
    }
    let rest = &line[1..];
    let key_end = rest.find('"')?;
    let key = &rest[..key_end];
    let after_key = rest[key_end + 1..].trim_start();
    let after_eq = after_key.strip_prefix('=')?.trim_start();
    let after_quote = after_eq.strip_prefix('"')?;
    let val_end = after_quote.find('"')?;
    let val = &after_quote[..val_end];
    let addr: Address = key.parse().ok()?;
    let salt: B256 = val.parse().ok()?;
    Some((addr, salt))
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

fn match_quoted_h256(line: &str, key: &str) -> Option<B256> {
    let prefix = format!("{key} = \"");
    if !line.starts_with(&prefix) {
        return None;
    }
    let rest = &line[prefix.len()..];
    let end = rest.find('"')?;
    rest[..end].parse().ok()
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
        let raw =
            fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
        let pv: PermanentValues =
            toml::from_str(&raw).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()));
        let ng = pv
            .new_gateway
            .expect("permanent-values/stage.toml must carry [new_gateway]");
        let legacy_gateway = pv
            .legacy_gateway
            .expect("permanent-values/stage.toml must carry [legacy_gateway]");
        assert_eq!(legacy_gateway.chain_id, 123);
        assert_eq!(ng.chain_id, 2709);
        // 0.2 ZK = 2e17 wei, sized for ~$0.01 per interop call at ZK ≈ $0.05.
        assert_eq!(ng.settlement_fee, U256::from(200_000_000_000_000_000u128));
        // GW 2708 is a ZKsync OS chain → CTM source is Atlas (witness 2702).
        assert_eq!(ng.ctm_representative_chain_id, 2702);
    }

    /// Confirms `EnvConfig`'s on-demand readers pick up the
    /// `[create2_factory_salts]` table and `[contracts] create2_factory_salt`
    /// — gov-replay relies on distinct per-CTM salts to keep
    /// `GovernanceUpgradeTimer` deploys at different CREATE2 addresses
    /// across Era and ZKsyncOS CTMs.
    #[test]
    fn stage_env_config_reads_create2_salts() {
        let cfg = EnvConfig::load("stage").expect("load stage env config");

        let core_salt = cfg
            .v31_create2_factory_salt()
            .expect("read core salt")
            .expect("stage.toml must declare [contracts] create2_factory_salt");
        assert_ne!(core_salt, B256::ZERO);

        let per_ctm = cfg
            .v31_create2_factory_salt_per_ctm()
            .expect("read per-CTM salts");
        assert_eq!(per_ctm.len(), 2);
        let era: Address = "0x8b448ac7cd0f18F3d8464E2645575772a26A3b6b"
            .parse()
            .unwrap();
        let atlas: Address = "0x73bee414c6e006525f3cceedf6d8004c0370502e"
            .parse()
            .unwrap();
        let era_salt = per_ctm.get(&era).expect("Era CTM salt");
        let atlas_salt = per_ctm.get(&atlas).expect("ZKsyncOS CTM salt");
        assert_ne!(era_salt, atlas_salt, "per-CTM salts must be distinct");
    }

    /// Same as `stage_env_config_reads_create2_salts` but for mainnet —
    /// without per-CTM entries the prepare falls back to random salts and
    /// the regen stops being reproducible.
    #[test]
    fn mainnet_env_config_reads_create2_salts() {
        let cfg = EnvConfig::load("mainnet").expect("load mainnet env config");

        let core_salt = cfg
            .v31_create2_factory_salt()
            .expect("read core salt")
            .expect("mainnet.toml must declare [contracts] create2_factory_salt");
        assert_ne!(core_salt, H256::zero());

        let per_ctm = cfg
            .v31_create2_factory_salt_per_ctm()
            .expect("read per-CTM salts");
        assert_eq!(per_ctm.len(), 2);
        let era: Address = "0xc2eE6b6af7d616f6e27ce7F4A451Aedc2b0F5f5C"
            .parse()
            .unwrap();
        let atlas: Address = "0x1adf137f59949c9081157d5dE1e002D1c992071F"
            .parse()
            .unwrap();
        let era_salt = per_ctm.get(&era).expect("Era CTM salt");
        let atlas_salt = per_ctm.get(&atlas).expect("ZKsyncOS CTM salt");
        assert_ne!(era_salt, atlas_salt, "per-CTM salts must be distinct");
    }
}
