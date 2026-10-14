//! Per-env config loader.
//!
//! Most ecosystem and gov commands need the same per-env addresses (bridgehub,
//! CTM list with overrides, era chain id, deployer/owner, create2 factory).
//! Rather than asking the user to pass every flag explicitly, commands that
//! flatten an [`crate::common::EcosystemArgs`] expose `--env <name>` which
//! reads `upgrade-envs/permanent-values/<env>.toml` (and the release upgrade input
//! TOML for env-specific values like `era_chain_id` / `owner_address`) and
//! fills the missing args.
//!
//! Any explicit CLI flag still wins — `--env` is purely a defaults source.
//!
//! Layout (relative to `l1-contracts/`):
//!
//!   upgrade-envs/permanent-values/<env>.toml      (bridgehub, ctms, create2)
//!   <current upgrade-env dir>/<env>.toml          (owner, era_chain_id)
//!
//! Older releases' inputs contain unquoted hex literals (e.g. `old_protocol_version =
//! 0x1d…`) which `toml-rs` chokes on, so we parse it line-by-line for the
//! handful of fields we need.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use alloy::primitives::{Address, B256};
use anyhow::Context;
use serde::Deserialize;

use crate::common::forge::scripts::CURRENT_UPGRADE_ENV_DIR;
use crate::common::paths::resolve_l1_contracts_path;

/// The release's upgrade-env directory. Salts, per-env inputs and the canonical output
/// directory all live here. It is the same directory the prepare defaults use, so it moves with each
/// release rather than trailing an older one.
fn upgrade_env_dir() -> &'static str {
    CURRENT_UPGRADE_ENV_DIR.trim_start_matches('/')
}
const PERMANENT_VALUES_DIR: &str = "upgrade-envs/permanent-values";

#[derive(Debug, Deserialize)]
pub struct PermanentValues {
    #[serde(default)]
    pub zk_token_asset_id: Option<B256>,
    pub testnet_verifier: Option<bool>,
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
    /// Legacy single-CTM Era address. Only `anvil-interop` synthetic-state
    /// fixtures still read this flat field directly; every protocol-ops
    /// command consumes the multi-CTM `ctms` array below. TODO: thread the
    /// `[[ctm_contracts.ctms]]` shape through anvil-interop and remove this
    /// field so the legacy shape isn't carried in two places.
    #[serde(default)]
    pub ctm_proxy_addr: Option<Address>,
    /// Multi-CTM list — proxy + optional per-CTM address overrides. Every
    /// entry must be a ZKsync OS CTM; the prepare flow fails on anything else.
    #[serde(default, rename = "ctms")]
    pub ctms: Vec<CtmEntry>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CtmEntry {
    pub proxy: Address,
    /// Optional override; the prepare flow otherwise resolves it from a chain registered on the
    /// CTM. The bytecodes supplier has no counterpart here: the prepare script reads it off the
    /// CTM's own `L1_BYTECODES_SUPPLIER()` immutable, so a permanent-values entry for it would
    /// name a value nothing consumes.
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
    // (`<current upgrade-env dir>/<env>.toml [contracts] create2_factory_salt`)
    // alongside the rest of the per-regen inputs. See
    // `EnvConfig::create2_factory_salt_for_upgrade`.
}

/// Fields read from the upgrade input TOML (best-effort regex parse —
/// the file has unquoted hex literals that the TOML crate rejects).
///
/// CREATE2 salts are *not* stored here; `EnvConfig::create2_factory_salt_for_upgrade`
/// and `create2_factory_salt_for_upgrade_per_ctm` re-read them from
/// `upgrade_input_path` on demand. That way the salt-keyed entries are not
/// duplicated in Rust state — the TOML is the only source of truth.
#[derive(Debug, Default, Clone)]
pub struct UpgradeInputs {
    pub owner_address: Option<Address>,
    pub era_chain_id: Option<u64>,
    /// Whether THIS release replaces the ecosystem's governance set (a new
    /// `ProtocolUpgradeHandler` implementation plus Guardians / SecurityCouncil /
    /// EmergencyUpgradeBoard, wired in by four stage-0 calls — see
    /// [`crate::commands::ecosystem::zk_governance`]).
    ///
    /// Absent (the default) means no. `governance_kind = "puh"` is NOT this statement:
    /// it says the ecosystem HAS a PUH, which is a permanent property, true of every
    /// release prepared for that env. The redeploy is a one-off act of a particular
    /// release, so it is declared in that release's own env input — the directory
    /// moves with the release, so a later one omits the key and redeploys nothing.
    pub redeploy_zk_governance: bool,
}

/// Fully-resolved per-env config.
#[derive(Debug)]
pub struct EnvConfig {
    pub env: String,
    pub permanent_values_path: PathBuf,
    pub upgrade_input_path: PathBuf,
    pub permanent: PermanentValues,
    /// `None` when the release has no `<env>.toml`: the release-scoped accessors then fail closed.
    upgrade_input: Option<UpgradeInputs>,
    /// The upgrade-env directory the release values (input, salts, outputs) come from.
    upgrade_env_dir: PathBuf,
}

impl EnvConfig {
    /// Load `<l1-contracts>/upgrade-envs/permanent-values/<env>.toml` and the
    /// upgrade input TOML for the same env. Both files must exist.
    pub fn load(env: &str) -> anyhow::Result<Self> {
        Self::load_from_upgrade_env_dir(env, upgrade_env_dir())
    }

    /// `load` against an explicit upgrade-env directory (relative to `l1-contracts/`) instead of the
    /// current release's. Used when a historical preparation selects another release's input.
    pub fn load_from_upgrade_env_dir(env: &str, upgrade_env_dir: &str) -> anyhow::Result<Self> {
        let l1 = resolve_l1_contracts_path()?;
        let permanent_values_path = l1.join(PERMANENT_VALUES_DIR).join(format!("{env}.toml"));
        let upgrade_env_dir = l1.join(upgrade_env_dir);
        let upgrade_input_path = upgrade_env_dir.join(format!("{env}.toml"));

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

        // Loading succeeds without the release input: commands that only need the permanent values (e.g. the
        // bridgehub) still work. Reading a release value from a missing input is an error (`release_input`).
        let upgrade_input = if upgrade_input_path.exists() {
            Some(parse_upgrade_input(&fs::read_to_string(
                &upgrade_input_path,
            )?))
        } else {
            None
        };

        Ok(EnvConfig {
            env: env.to_string(),
            permanent_values_path,
            upgrade_input_path,
            permanent,
            upgrade_input,
            upgrade_env_dir,
        })
    }

    /// This env's protocol-ops output dir inside the release directory it was loaded from, e.g.
    /// `<upgrade-env dir>/output/<env>/`. Outputs land directly under the env dir, so the artifacts a
    /// reviewer expects for stage / mainnet are immediately visible.
    pub fn protocol_ops_out_dir(&self) -> PathBuf {
        self.upgrade_env_dir.join("output").join(&self.env)
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
    /// `<current upgrade-env dir>/<env>.toml [contracts]
    /// create2_factory_salt`. Distinct from `create2_factory_salt()` (which
    /// reads the chain-permanent salt out of `permanent-values/`); this one
    /// is the salt used to deploy *this upgrade*'s implementations, recorded
    /// alongside the rest of the v31 inputs so re-prepares are reproducible.
    /// Re-reads the TOML each call rather than caching, so editing the file
    /// between commands is reflected without restarting the CLI.
    pub fn create2_factory_salt_for_upgrade(&self) -> anyhow::Result<Option<B256>> {
        Ok(read_core_create2_salt(&self.release_input_contents()?))
    }

    /// Per-regen salt for legacy `Governance.sol` ceremonies, read from
    /// `<current upgrade-env dir>/<env>.toml [contracts] legacy_gov_salt`.
    /// Op ids in the legacy Gov state machine are content-addressed
    /// (`hash(targets, values, calldatas, predecessor, salt)`); rotating this
    /// salt every regen prevents the broadcaster from colliding with previously
    /// executed op ids that still sit in the on-chain `Done` map. When absent,
    /// returns `None` and the forge scripts default to `bytes32(0)`.
    pub fn legacy_gov_salt_for_upgrade(&self) -> anyhow::Result<Option<B256>> {
        Ok(read_core_legacy_gov_salt(&self.release_input_contents()?))
    }

    /// Per-CTM CREATE2 salts from
    /// `<current upgrade-env dir>/<env>.toml [create2_factory_salts]`,
    /// keyed by CTM proxy. Empty if the env doesn't declare any (legacy
    /// local-fixture path — `upgrade_inner` will fall back to random
    /// salts in that case). Re-reads the TOML each call (see
    /// `create2_factory_salt_for_upgrade`).
    pub fn create2_factory_salt_for_upgrade_per_ctm(
        &self,
    ) -> anyhow::Result<HashMap<Address, B256>> {
        Ok(read_create2_salts_per_ctm(&self.release_input_contents()?))
    }

    /// The env's `owner_address` from the release input. Errors when the release has no input for this env,
    /// so a caller cannot silently fall back to another owner (e.g. the deployer).
    pub fn owner_address(&self) -> anyhow::Result<Option<Address>> {
        Ok(self.release_input()?.owner_address)
    }

    /// The env's `era_chain_id` from the release input; errors like [`Self::owner_address`].
    pub fn era_chain_id(&self) -> anyhow::Result<Option<u64>> {
        Ok(self.release_input()?.era_chain_id)
    }

    /// Whether this release replaces the ecosystem's governance set — see
    /// [`UpgradeInputs::redeploy_zk_governance`]; errors like [`Self::owner_address`].
    pub fn redeploys_zk_governance(&self) -> anyhow::Result<bool> {
        Ok(self.release_input()?.redeploy_zk_governance)
    }

    fn missing_release_input(&self) -> anyhow::Error {
        anyhow::anyhow!(
            "no release upgrade input for --env {} at {}. Add it (copy the previous release's, with fresh salts; \
             `yarn new-release` does this) or select another release with --upgrade-env-dir",
            self.env,
            self.upgrade_input_path.display()
        )
    }

    fn release_input(&self) -> anyhow::Result<&UpgradeInputs> {
        self.upgrade_input
            .as_ref()
            .ok_or_else(|| self.missing_release_input())
    }

    /// Re-reads the release input each call, so editing the file between commands is reflected.
    fn release_input_contents(&self) -> anyhow::Result<String> {
        if self.upgrade_input.is_none() {
            return Err(self.missing_release_input());
        }
        fs::read_to_string(&self.upgrade_input_path)
            .with_context(|| format!("read {}", self.upgrade_input_path.display()))
    }

    /// Whether this is the mainnet ecosystem. Drives testnet-vs-real contract
    /// selection (e.g. the per-CTM verifier and the PUH redeploy: every
    /// non-mainnet env gets the zeroed-delay `TestnetProtocolUpgradeHandler`).
    pub fn is_mainnet(&self) -> bool {
        self.env == "mainnet"
    }

    pub fn ownable_proxies(&self) -> &[OwnableProxyEntry] {
        &self.permanent.ownable_proxies
    }

    pub fn governance_kind(&self) -> GovernanceKind {
        self.permanent.core_contracts.governance_kind
    }

    /// Whether this environment's CTM verifier is the testnet one, which accepts unproven batches.
    /// Declared per env — true everywhere except mainnet — and passed to the CTM upgrade script
    /// rather than read there, so the decision lives in one place.
    pub fn testnet_verifier(&self) -> Option<bool> {
        self.permanent.testnet_verifier
    }

    pub fn zk_token_asset_id(&self) -> Option<B256> {
        self.permanent.zk_token_asset_id
    }

    /// The env's `zk_token_asset_id`, which a named env must declare: there is no canonical
    /// network-wide value to fall back to.
    pub fn require_zk_token_asset_id(&self) -> anyhow::Result<B256> {
        self.zk_token_asset_id().ok_or_else(|| {
            anyhow::anyhow!(
                "{} is missing top-level `zk_token_asset_id`; a named env must declare it, since \
                 there is no canonical network-wide value",
                self.permanent_values_path.display()
            )
        })
    }
}

fn parse_upgrade_input(content: &str) -> UpgradeInputs {
    let mut out = UpgradeInputs::default();
    for line in content.lines() {
        let line = line.trim();
        if let Some(addr) = match_quoted_address(line, "owner_address") {
            out.owner_address = Some(addr);
        } else if let Some(id) = match_unquoted_uint(line, "era_chain_id") {
            out.era_chain_id = Some(id);
        } else if let Some(flag) = match_unquoted_bool(line, "redeploy_zk_governance") {
            out.redeploy_zk_governance = flag;
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

fn match_unquoted_bool(line: &str, key: &str) -> Option<bool> {
    let prefix = format!("{key} = ");
    if !line.starts_with(&prefix) {
        return None;
    }
    // Strip optional trailing comment.
    line[prefix.len()..].split('#').next()?.trim().parse().ok()
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

    /// The governance redeploy is a RELEASE's declaration, not a property of the env: absent means
    /// no, whatever `governance_kind` says. Without this, every recurring preparation on a
    /// PUH-governed env redeployed the whole governance set.
    #[test]
    fn zk_governance_redeploy_defaults_to_off() {
        assert!(!parse_upgrade_input("era_chain_id = 270\n").redeploy_zk_governance);
        assert!(!parse_upgrade_input("redeploy_zk_governance = false\n").redeploy_zk_governance);
        assert!(parse_upgrade_input("redeploy_zk_governance = true\n").redeploy_zk_governance);
        assert!(
            parse_upgrade_input("redeploy_zk_governance = true # the bootstrap release\n")
                .redeploy_zk_governance
        );
    }

    /// The v35 release is the one that replaces the governance set, on both PUH-governed envs.
    /// A later release's directory simply omits the key.
    #[test]
    fn v35_env_inputs_declare_the_governance_redeploy() {
        for env in ["stage", "mainnet"] {
            let cfg = EnvConfig::load(env).unwrap_or_else(|e| panic!("load {env}: {e}"));
            assert_eq!(cfg.governance_kind(), GovernanceKind::Puh, "{env}");
            assert!(cfg.redeploys_zk_governance().unwrap(), "{env}");
        }
    }

    /// Smoke-tests that `permanent-values/stage.toml` deserializes into `PermanentValues`
    /// end-to-end. Catches any future TOML drift before it shows up as a runtime parse error
    /// from `protocol-ops ecosystem upgrade-prepare-all --env stage`.
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
        let ctms = pv
            .ctm_contracts
            .expect("permanent-values/stage.toml must carry [ctm_contracts]");
        assert_eq!(ctms.ctms.len(), 1, "stage upgrades a single (Atlas) CTM");
        assert_eq!(pv.ownable_proxies.len(), 2);
    }

    /// The salt readers run on the current release's real per-env inputs, so these also guard that the
    /// release ships them with distinct per-CTM salts.
    fn load_current(env: &str) -> EnvConfig {
        EnvConfig::load(env).expect("load env config")
    }

    /// A release without `<env>.toml` fails closed on every release value instead of handing back
    /// empty defaults (which let `init` fall back to the deployer as owner, or the prepare to random salts).
    /// `--env <name>` pairs `<current release dir>/<name>.toml` with `permanent-values/<name>.toml`: every
    /// release input must have its permanent values, so no env loads half its config.
    #[test]
    fn every_current_release_input_has_its_permanent_values() {
        let l1 = resolve_l1_contracts_path().unwrap();
        let release_dir = l1.join(upgrade_env_dir());
        let mut envs = 0;
        for entry in fs::read_dir(&release_dir).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|e| e.to_str()) != Some("toml") {
                continue;
            }
            let env = path.file_stem().unwrap().to_str().unwrap().to_string();
            assert!(
                l1.join(PERMANENT_VALUES_DIR)
                    .join(format!("{env}.toml"))
                    .exists(),
                "{} has no permanent-values/{env}.toml",
                path.display()
            );
            EnvConfig::load(&env).unwrap();
            envs += 1;
        }
        assert!(envs > 0, "no release inputs in {}", release_dir.display());
    }

    /// Every env declares `testnet_verifier`, and only mainnet runs the production verifier: the flag decides
    /// whether an upgrade installs a verifier that accepts unproven batches.
    #[test]
    fn every_env_declares_testnet_verifier_and_only_mainnet_is_production() {
        let dir = resolve_l1_contracts_path()
            .unwrap()
            .join(PERMANENT_VALUES_DIR);
        let mut saw_mainnet = false;
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|e| e.to_str()) != Some("toml") {
                continue;
            }
            let env = path.file_stem().unwrap().to_str().unwrap();
            let values: PermanentValues =
                toml::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
            assert_eq!(
                values.testnet_verifier,
                Some(env != "mainnet"),
                "{env} has a missing or wrong testnet_verifier"
            );
            saw_mainnet |= env == "mainnet";
        }
        assert!(saw_mainnet, "no mainnet permanent values");
    }

    /// Every env declares a non-zero `zk_token_asset_id`: the prepare pins it in every release's
    /// force deployments, and `verify-bootstrap --env` holds those against it.
    #[test]
    fn every_env_declares_a_zk_token_asset_id() {
        let dir = resolve_l1_contracts_path()
            .unwrap()
            .join(PERMANENT_VALUES_DIR);
        let mut envs = 0;
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|e| e.to_str()) != Some("toml") {
                continue;
            }
            let env = path.file_stem().unwrap().to_str().unwrap();
            let cfg = EnvConfig::load(env).unwrap_or_else(|e| panic!("load {env}: {e}"));
            let zk_token_asset_id = cfg
                .require_zk_token_asset_id()
                .unwrap_or_else(|e| panic!("{e}"));
            assert_ne!(zk_token_asset_id, B256::ZERO, "{env}");
            envs += 1;
        }
        assert!(envs > 0, "no permanent values in {}", dir.display());
    }

    /// An env without `zk_token_asset_id` names the file and the key it lacks.
    #[test]
    fn a_missing_zk_token_asset_id_names_the_file_and_the_key() {
        let permanent_values_path = PathBuf::from("upgrade-envs/permanent-values/scratch.toml");
        let cfg = EnvConfig {
            env: "scratch".to_string(),
            permanent_values_path: permanent_values_path.clone(),
            upgrade_input_path: PathBuf::from("scratch.toml"),
            permanent: toml::from_str(
                "[core_contracts]\n\
                 bridgehub_proxy_addr = \"0x0000000000000000000000000000000000000001\"\n",
            )
            .unwrap(),
            upgrade_input: None,
            upgrade_env_dir: PathBuf::new(),
        };
        let message = cfg.require_zk_token_asset_id().unwrap_err().to_string();
        assert!(
            message.contains(&permanent_values_path.display().to_string()),
            "{message}"
        );
        assert!(message.contains("`zk_token_asset_id`"), "{message}");
    }

    #[test]
    fn missing_release_input_fails_closed() {
        // This line's copy of the v33 release dir has no testnet input (release/v0.33.0-atomic-interop does).
        let cfg =
            EnvConfig::load_from_upgrade_env_dir("testnet", "upgrade-envs/v0.33.0-atomic-interop")
                .expect("permanent values alone still load");
        assert_ne!(cfg.bridgehub(), Address::ZERO);
        assert!(cfg.owner_address().is_err());
        assert!(cfg.era_chain_id().is_err());
        assert!(cfg.create2_factory_salt_for_upgrade().is_err());
        assert!(cfg.create2_factory_salt_for_upgrade_per_ctm().is_err());
    }

    /// Confirms `EnvConfig`'s on-demand readers pick up the
    /// `[create2_factory_salts]` table and `[contracts] create2_factory_salt`
    /// — gov-replay relies on distinct per-CTM salts to keep
    /// `GovernanceUpgradeTimer` deploys at different CREATE2 addresses
    /// across Era and ZKsyncOS CTMs.
    #[test]
    fn stage_env_config_reads_create2_salts() {
        let cfg = load_current("stage");

        let core_salt = cfg
            .create2_factory_salt_for_upgrade()
            .expect("read core salt")
            .expect("stage.toml must declare [contracts] create2_factory_salt");
        assert_ne!(core_salt, B256::ZERO);

        let per_ctm = cfg
            .create2_factory_salt_for_upgrade_per_ctm()
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
        let cfg = load_current("mainnet");

        let core_salt = cfg
            .create2_factory_salt_for_upgrade()
            .expect("read core salt")
            .expect("mainnet.toml must declare [contracts] create2_factory_salt");
        assert_ne!(core_salt, B256::ZERO);

        let per_ctm = cfg
            .create2_factory_salt_for_upgrade_per_ctm()
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
