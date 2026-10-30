//! `ecosystem check-deployer-plan`: every call the deployer key would sign, held to the DEPLOY
//! checkout before anything is signed.
//!
//! `verify-bundle` only holds a bundle's files to the digests the bundle declares, and
//! `verify-bootstrap` reads deployed objects, not the transaction list, so neither stops an extra
//! call in a deployer Safe file. This check admits a deployer call only when
//!
//! * it sends no value;
//! * it is a CREATE2 deployment through the env's factory, under one of the env's declared salts,
//!   of a contract the deploy checkout's reviewed build produces at that address: a
//!   `[member_deployments]` record (creation code ++ recorded constructor arguments), an
//!   `[upgrade_executors]` record, an object the package names (creation code ++ constructor
//!   arguments that are exactly an ABI encoding of the constructor's parameters), the bootstrap
//!   sequence over the package's migration and core transition, or a reviewed proxy in front of a
//!   recorded implementation; or
//! * it matches an entry of [`ALLOWLIST`], at a target holding that entry's role in the package
//!   and with that entry's argument constraint.
//!
//! A role that belongs to one CTM is taken only from that CTM's `[ctms.<key>]` table, and the CTM
//! must be one the env declares. The CTM's ProxyAdmin, BytecodesSupplier and ValidatorTimelock are
//! also read from L1 ([`CtmFacts`]) before anything is signed, as is the ecosystem ProxyAdmin (the
//! EIP-1967 admin of the env's Bridgehub), so a bundle cannot name its own.
//!
//! What it does not establish: the package's other addresses and records come from the bundle.
//! The constructor arguments, a proxy's initializer and a published bytecode are not judged here;
//! `verify-bootstrap` holds the objects and members they build before governance signs.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Command;

use alloy::dyn_abi::{DynSolType, DynSolValue};
use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::Deserialize;

use crate::commands::ecosystem::bundle::{
    contract_source_pathspecs, verify_bundle_integrity, DeployBundleMetadata, MANIFEST_FILE,
};
use crate::common::env_config::{EnvConfig, DEFAULT_UPGRADE};
use crate::common::ethereum::get_provider;
use crate::common::forge::scripts::member_deployments::MemberDeployments;
use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::common::upgrade_descriptor::{validate_upgrade_name, UpgradeDescriptor};
use crate::common::{logger, paths};
use crate::upgrade_verification::constants::EIP1967_PROXY_ADMIN_SLOT;
use crate::upgrade_verification::contract_hashes::contract_hashes_path;
use crate::upgrade_verification::paths::repo_relative_path;
use crate::upgrade_verification::registry::construction::{
    constructor_args, ReviewedArtifact, ReviewedBuild, DETERMINISTIC_CREATE2_FACTORY,
    REVIEWED_PROXY,
};
use crate::upgrade_verification::registry::provenance::CodeIdentity;
use crate::upgrade_verification::registry::records;
use crate::upgrade_verification::registry::views::CtmView;

mod abi {
    alloy::sol! {
        struct Call {
            address target;
            uint256 value;
            bytes data;
        }
        function transferOwnership(address newOwner);
        function changeProxyAdmin(address proxy, address newAdmin);
        function publishEVMBytecodes(bytes[] _bytecodes);
        function multicall(Call[] _calls, bool _requireSuccess);
    }
}

/// The package's write-once objects by `[registry]` key, with the contract each must be.
const OBJECT_KEYS: [(&str, &str); 6] = [
    ("core_transition_addr", "ProxyUpgradeTransition"),
    (
        "ctm_infrastructure_transition_addr",
        "ProxyUpgradeTransition",
    ),
    ("ctm_transition_addr", "CTMTransition"),
    ("replacement_transition_addr", "CTMTransition"),
    ("ctm_release_addr", "CTMRelease"),
    ("bootstrap_migration_addr", "RegistryBootstrapMigration"),
];
const CORE_EXECUTOR: &str = "CoreUpgradeExecutor";
const CTM_EXECUTOR: &str = "CTMUpgradeExecutor";
const BOOTSTRAP_SEQUENCE: &str = "RegistryBootstrapSequence";
/// `[[external_actions]] phase` of the calls an admin (not governance) performs.
const ADMIN_PHASE: &str = "admin";
/// Where a `[ctms.<key>]` table names its CTM proxy.
const CTM_PROXY_PATH: [&str; 2] = ["state_transition", "chain_type_manager_proxy"];
/// Where the core prepare names the Bridgehub.
const BRIDGEHUB_PATH: [&str; 4] = [
    "core",
    "upgrade_addresses",
    "bridgehub",
    "bridgehub_proxy_addr",
];

/// What a call target must be in the package for an [`ALLOWLIST`] entry to admit it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Role {
    /// `[ctms.*.state_transition] chain_type_manager_proxy`.
    CtmProxy,
    /// `[ctms.*.state_transition] validator_timelock_addr`.
    ValidatorTimelock,
    /// `[ctms.*.deployed_addresses] transparent_proxy_admin`.
    CtmProxyAdmin,
    /// `[core.upgrade_addresses.shared] transparent_proxy_admin`.
    EcosystemProxyAdmin,
    /// `[ctms.*.state_transition] bytecodes_supplier_addr`.
    BytecodesSupplier,
    /// `[ctms.*.ctm_admin_calls] chain_admin`.
    ChainAdmin,
    /// The target of an `admin`-phase `[[external_actions]]` entry.
    AdminActionTarget,
}

impl Role {
    /// Whether the role belongs to one CTM, so that only a `[ctms.<key>]` table naming that CTM
    /// can grant it.
    fn per_ctm(self) -> bool {
        !matches!(self, Self::EcosystemProxyAdmin | Self::AdminActionTarget)
    }
}

impl fmt::Display for Role {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::CtmProxy => "the CTM proxy",
            Self::ValidatorTimelock => "the CTM's ValidatorTimelock",
            Self::CtmProxyAdmin => "the CTM-domain ProxyAdmin",
            Self::EcosystemProxyAdmin => "the ecosystem ProxyAdmin",
            Self::BytecodesSupplier => "the CTM's BytecodesSupplier",
            Self::ChainAdmin => "the ChainAdmin of the CTM admin calls",
            Self::AdminActionTarget => "the target of a declared admin action",
        })
    }
}

/// What an [`ALLOWLIST`] entry requires of the call's arguments.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Constraint {
    /// The new owner is the reviewed governance owner.
    NewOwnerIsGovernance,
    /// None: publishing bytecode is permissionless and moves no authority.
    Publication,
    /// The call is a declared admin action, and the authority it hands over lands on the CTM
    /// executor this plan deploys (owned by governance) or on the ProxyAdmin that administers that
    /// executor's CTM on L1.
    HandoverToPlannedExecutor,
    /// `multicall(calls, true)` whose every call sends no value and is admitted as
    /// [`Self::HandoverToPlannedExecutor`].
    HandoverMulticall,
}

/// One reviewed deployer call shape other than a CREATE2 deployment.
#[derive(Debug)]
pub(crate) struct AllowedCall {
    pub(crate) signature: &'static str,
    pub(crate) selector: [u8; 4],
    pub(crate) roles: &'static [Role],
    pub(crate) constraint: Constraint,
    /// Which prepare step emits it, as seen in the v35 bootstrap prepare's deployer bundle.
    pub(crate) source: &'static str,
}

/// Every deployer call besides CREATE2 deployments that the check admits.
pub(crate) const ALLOWLIST: &[AllowedCall] = &[
    AllowedCall {
        signature: "transferOwnership(address)",
        selector: abi::transferOwnershipCall::SELECTOR,
        roles: &[
            Role::CtmProxy,
            Role::ValidatorTimelock,
            Role::CtmProxyAdmin,
            Role::EcosystemProxyAdmin,
        ],
        constraint: Constraint::NewOwnerIsGovernance,
        source:
            "AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernance, when the deployer is the \
                 live owner",
    },
    AllowedCall {
        signature: "publishEVMBytecodes(bytes[])",
        selector: abi::publishEVMBytecodesCall::SELECTOR,
        roles: &[Role::BytecodesSupplier],
        constraint: Constraint::Publication,
        source: "BytecodePublisher.publishAndProcessFactoryDeps in the CTM prepare",
    },
    AllowedCall {
        signature: "multicall((address,uint256,bytes)[],bool)",
        selector: abi::multicallCall::SELECTOR,
        roles: &[Role::ChainAdmin],
        constraint: Constraint::HandoverMulticall,
        source: "AdminFunctions.executeOwnableCallsWithWraps through a ChainAdmin the deployer \
                 owns: the bootstrap's ServerNotifier handover",
    },
    AllowedCall {
        signature: "transferOwnership(address)",
        selector: abi::transferOwnershipCall::SELECTOR,
        roles: &[Role::AdminActionTarget],
        constraint: Constraint::HandoverToPlannedExecutor,
        source: "AdminFunctions.executeOwnableCallsWithWraps when the deployer owns the \
                 ServerNotifier: the bootstrap's ServerNotifier handover",
    },
    AllowedCall {
        signature: "changeProxyAdmin(address,address)",
        selector: abi::changeProxyAdminCall::SELECTOR,
        roles: &[Role::AdminActionTarget],
        constraint: Constraint::HandoverToPlannedExecutor,
        source: "AdminFunctions.executeOwnableCallsWithWraps when the deployer owns the \
                 ServerNotifier's old ProxyAdmin: the bootstrap's ServerNotifier handover",
    },
];

// ─── The package ────────────────────────────────────────────────────────────────

/// A call the package declares in `[[external_actions]]` with `phase = "admin"`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct AdminAction {
    target: Address,
    value: U256,
    data: Bytes,
    label: String,
}

/// An object the package names under a `[registry]` key.
#[derive(Debug, Clone)]
struct PackageObject {
    address: Address,
    contract: &'static str,
    location: String,
}

/// Where the package names a role holder, and the CTM of the `[ctms.<key>]` table that names it
/// (`None` for a role that is not [`Role::per_ctm`]).
#[derive(Debug, Clone)]
struct Holder {
    location: String,
    ctm: Option<Address>,
}

/// The parts of a merged prepare package (`ecosystem.toml`) the plan is held against.
#[derive(Debug, Default)]
pub(crate) struct PackageView {
    members: MemberDeployments,
    executors: UpgradeExecutorsRecord,
    objects: Vec<PackageObject>,
    /// Every non-zero address the package's tables name.
    named: BTreeSet<Address>,
    roles: BTreeMap<Role, BTreeMap<Address, Vec<Holder>>>,
    admin_actions: Vec<AdminAction>,
    /// Tables the check refuses outright.
    faults: Vec<String>,
    /// The Bridgehub the core prepare names, which stands in for the env's without one.
    bridgehub: Option<Address>,
}

/// A table a prepare output can sit at: the root, `[core]` or a `[ctms.<key>]`.
struct Scope<'a> {
    prefix: String,
    table: &'a toml::Value,
    is_ctm: bool,
}

fn scopes(root: &toml::Value) -> Vec<Scope<'_>> {
    let mut scopes = vec![Scope {
        prefix: String::new(),
        table: root,
        is_ctm: false,
    }];
    if let Some(core) = root.get("core") {
        scopes.push(Scope {
            prefix: "core.".to_string(),
            table: core,
            is_ctm: false,
        });
    }
    if let Some(ctms) = root.get("ctms").and_then(toml::Value::as_table) {
        for (key, ctm) in ctms {
            scopes.push(Scope {
                prefix: format!("ctms.{key}."),
                table: ctm,
                is_ctm: true,
            });
        }
    }
    scopes
}

/// The non-zero address at `path` under `table`, if any.
fn address_at(table: &toml::Value, path: &[&str]) -> anyhow::Result<Option<Address>> {
    let mut value = table;
    for key in path {
        match value.get(key) {
            Some(next) => value = next,
            None => return Ok(None),
        }
    }
    let raw = value
        .as_str()
        .with_context(|| format!("{} is not a string", path.join(".")))?;
    let address: Address = raw
        .parse()
        .with_context(|| format!("{} = {raw:?} is not an address", path.join(".")))?;
    Ok((address != Address::ZERO).then_some(address))
}

/// Every non-zero address-shaped string below `value`.
fn collect_addresses(value: &toml::Value, into: &mut BTreeSet<Address>) {
    match value {
        toml::Value::String(raw) if raw.len() == 42 && raw.starts_with("0x") => {
            if let Ok(address) = raw.parse::<Address>() {
                if address != Address::ZERO {
                    into.insert(address);
                }
            }
        }
        toml::Value::Array(items) => items.iter().for_each(|v| collect_addresses(v, into)),
        toml::Value::Table(table) => table.values().for_each(|v| collect_addresses(v, into)),
        _ => {}
    }
}

impl PackageView {
    pub(crate) fn load(path: &Path) -> anyhow::Result<Self> {
        let raw =
            std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        let root: toml::Value =
            toml::from_str(&raw).with_context(|| format!("parse {} as TOML", path.display()))?;
        Self::from_toml(&root, &path.display().to_string())
    }

    pub(crate) fn from_toml(root: &toml::Value, source: &str) -> anyhow::Result<Self> {
        let mut view = PackageView {
            members: records::member_records_in(root, source)?,
            executors: records::records_in(root, source)?,
            bridgehub: address_at(root, &BRIDGEHUB_PATH)
                .with_context(|| format!("{source}: {}", BRIDGEHUB_PATH.join(".")))?,
            ..Self::default()
        };
        collect_addresses(root, &mut view.named);
        let role_paths: [(Role, &[&str]); 6] = [
            (Role::CtmProxy, &CTM_PROXY_PATH),
            (
                Role::ValidatorTimelock,
                &["state_transition", "validator_timelock_addr"],
            ),
            (
                Role::CtmProxyAdmin,
                &["deployed_addresses", "transparent_proxy_admin"],
            ),
            (
                Role::EcosystemProxyAdmin,
                &["upgrade_addresses", "shared", "transparent_proxy_admin"],
            ),
            (
                Role::BytecodesSupplier,
                &["state_transition", "bytecodes_supplier_addr"],
            ),
            (Role::ChainAdmin, &["ctm_admin_calls", "chain_admin"]),
        ];
        let location_of = |prefix: &str, path: &[&str]| {
            format!(
                "[{prefix}{}] {}",
                path[..path.len() - 1].join("."),
                path[path.len() - 1]
            )
        };
        for Scope {
            prefix,
            table,
            is_ctm,
        } in scopes(root)
        {
            for (key, contract) in OBJECT_KEYS {
                let location = format!("[{prefix}registry] {key}");
                if let Some(address) = address_at(table, &["registry", key])
                    .with_context(|| format!("{source}: {location}"))?
                {
                    view.objects.push(PackageObject {
                        address,
                        contract,
                        location,
                    });
                }
            }
            let ctm = address_at(table, &CTM_PROXY_PATH)
                .with_context(|| format!("{source}: {}", location_of(&prefix, &CTM_PROXY_PATH)))?;
            for (role, path) in role_paths {
                let location = location_of(&prefix, path);
                let Some(address) =
                    address_at(table, path).with_context(|| format!("{source}: {location}"))?
                else {
                    continue;
                };
                // A CTM's role counts only in that CTM's own table, and the ecosystem ProxyAdmin
                // only outside every CTM's; anywhere else the address holds no role.
                if role.per_ctm() != is_ctm {
                    continue;
                }
                if is_ctm && ctm.is_none() {
                    view.faults.push(format!(
                        "{location} names {role}, but its table names no chain_type_manager_proxy"
                    ));
                    continue;
                }
                view.roles
                    .entry(role)
                    .or_default()
                    .entry(address)
                    .or_default()
                    .push(Holder {
                        location,
                        ctm: if is_ctm { ctm } else { None },
                    });
            }
        }
        for (i, action) in root
            .get("external_actions")
            .and_then(toml::Value::as_array)
            .into_iter()
            .flatten()
            .enumerate()
        {
            if action.get("phase").and_then(toml::Value::as_str) != Some(ADMIN_PHASE) {
                continue;
            }
            let field = |key: &str| {
                action
                    .get(key)
                    .and_then(toml::Value::as_str)
                    .with_context(|| format!("{source}: external_actions[{i}] has no {key}"))
            };
            let target: Address = field("target")?
                .parse()
                .with_context(|| format!("{source}: external_actions[{i}].target"))?;
            let admin_action = AdminAction {
                target,
                value: field("value")?
                    .parse()
                    .with_context(|| format!("{source}: external_actions[{i}].value"))?,
                data: field("data")?
                    .parse()
                    .with_context(|| format!("{source}: external_actions[{i}].data"))?,
                label: field("label").unwrap_or("(no label)").to_string(),
            };
            view.roles
                .entry(Role::AdminActionTarget)
                .or_default()
                .entry(target)
                .or_default()
                .push(Holder {
                    location: format!("admin action `{}`", admin_action.label),
                    ctm: None,
                });
            view.admin_actions.push(admin_action);
        }
        Ok(view)
    }

    /// Every address holding `role`, with each place the package names it.
    fn holders(&self, role: Role) -> impl Iterator<Item = (&Address, &Vec<Holder>)> {
        self.roles.get(&role).into_iter().flatten()
    }

    /// Each place the package names `address` as holding `role`.
    fn holders_of(&self, role: Role, address: Address) -> &[Holder] {
        self.roles
            .get(&role)
            .and_then(|holders| holders.get(&address))
            .map_or(&[], Vec::as_slice)
    }

    /// The CTM proxies the package's `[ctms.<key>]` tables drive.
    pub(crate) fn ctms(&self) -> BTreeSet<Address> {
        self.holders(Role::CtmProxy).map(|(ctm, _)| *ctm).collect()
    }
}

// ─── The plan ───────────────────────────────────────────────────────────────────

/// One call of a deployer Safe file.
#[derive(Debug, Clone)]
pub(crate) struct PlanCall {
    /// 1-based, across every deployer bundle in manifest order.
    pub(crate) index: usize,
    pub(crate) file: String,
    /// 1-based within `file`.
    pub(crate) tx: usize,
    pub(crate) to: Address,
    pub(crate) value: U256,
    pub(crate) data: Bytes,
}

impl PlanCall {
    fn selector(&self) -> String {
        match self.data.get(..4) {
            Some(selector) => format!("0x{}", hex::encode(selector)),
            None if self.data.is_empty() => "none (empty calldata)".to_string(),
            None => format!("none ({} bytes of calldata)", self.data.len()),
        }
    }
}

impl fmt::Display for PlanCall {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "call {} ({} tx {}): target {}, selector {}, value {} wei",
            self.index,
            self.file,
            self.tx,
            self.to,
            self.selector(),
            self.value
        )
    }
}

#[derive(Debug, Deserialize)]
struct Manifest {
    bundles: Vec<ManifestEntry>,
}

#[derive(Debug, Deserialize)]
struct ManifestEntry {
    index: u32,
    file: String,
    target: Address,
}

#[derive(Debug, Deserialize)]
struct SafeFile {
    transactions: Vec<SafeTx>,
}

#[derive(Debug, Deserialize)]
struct SafeTx {
    to: Address,
    value: String,
    data: Bytes,
}

/// Every call of the manifest's bundles whose signer is `deployer`, in broadcast order (the
/// manifest's `index`, as `upgrade-broadcast` sends them), and how many bundles other signers sign.
pub(crate) fn deployer_calls(
    manifest_path: &Path,
    deployer: Address,
) -> anyhow::Result<(Vec<PlanCall>, usize)> {
    let mut manifest: Manifest = crate::common::files::read_json_file(manifest_path)?;
    manifest.bundles.sort_by_key(|bundle| bundle.index);
    let dir = manifest_path
        .parent()
        .context("the manifest path has no parent directory")?;
    let mut calls = Vec::new();
    let mut other_signers = 0;
    for bundle in &manifest.bundles {
        if bundle.target != deployer {
            other_signers += 1;
            continue;
        }
        anyhow::ensure!(
            Path::new(&bundle.file)
                .file_name()
                .map(|n| n == bundle.file.as_str())
                == Some(true),
            "{}: bundle file {:?} is not a bare file name",
            manifest_path.display(),
            bundle.file
        );
        let safe: SafeFile = crate::common::files::read_json_file(dir.join(&bundle.file))?;
        for (i, tx) in safe.transactions.into_iter().enumerate() {
            let value: U256 = tx.value.parse().with_context(|| {
                format!(
                    "{} tx {}: value {:?} is not a number",
                    bundle.file,
                    i + 1,
                    tx.value
                )
            })?;
            calls.push(PlanCall {
                index: calls.len() + 1,
                file: bundle.file.clone(),
                tx: i + 1,
                to: tx.to,
                value,
                data: tx.data,
            });
        }
    }
    Ok((calls, other_signers))
}

/// What L1 says about a CTM, read before anything is signed: the bundle cannot name these.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CtmFacts {
    /// The CTM proxy's EIP-1967 admin.
    pub(crate) proxy_admin: Address,
    /// `L1_BYTECODES_SUPPLIER()`, where the CTM reads published bytecode.
    pub(crate) bytecodes_supplier: Address,
    /// `validatorTimelockPostV29()`, the CTM's ValidatorTimelock.
    pub(crate) validator_timelock: Address,
}

/// The reviewed inputs the plan is held against, from the deploy checkout's env config, the
/// reviewer's flags and L1 — never from the bundle.
#[derive(Debug, Clone)]
pub(crate) struct ReviewedInputs {
    pub(crate) factory: Address,
    pub(crate) salts: BTreeSet<B256>,
    pub(crate) governance: Address,
    /// The env's CTM proxies; every CTM the package drives must be one. `None` without an env,
    /// when the package's own CTMs stand in.
    pub(crate) env_ctms: Option<BTreeSet<Address>>,
    /// [`CtmFacts`] of every CTM in [`Self::env_ctms`] (or the package's).
    pub(crate) ctm_facts: BTreeMap<Address, CtmFacts>,
    /// The EIP-1967 admin on L1 of the env's Bridgehub (without an env, the package's), which
    /// the package's ecosystem ProxyAdmin must be. `None` when no Bridgehub is known, which
    /// leaves no ecosystem ProxyAdmin to admit.
    pub(crate) ecosystem_proxy_admin: Option<Address>,
}

/// What a deployment of the plan put where.
#[derive(Debug, Clone)]
enum Deployed {
    Member {
        contract: String,
    },
    CoreExecutor,
    /// Governance-owned, so authority handed to it stays governance's.
    CtmExecutor {
        chain_type_manager: Address,
        ctm_proxy_admin: Address,
    },
    Object {
        contract: &'static str,
        location: String,
    },
    BootstrapSequence,
    Proxy {
        logic: Address,
    },
}

impl fmt::Display for Deployed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Member { contract } => write!(f, "the recorded member deployment of {contract}"),
            Self::CoreExecutor => write!(f, "the recorded {CORE_EXECUTOR}, owned by governance"),
            Self::CtmExecutor { .. } => {
                write!(f, "the recorded {CTM_EXECUTOR}, owned by governance")
            }
            Self::Object { contract, location } => write!(f, "the {contract} at {location}"),
            Self::BootstrapSequence => write!(
                f,
                "the {BOOTSTRAP_SEQUENCE} over the package's migration and core transition"
            ),
            Self::Proxy { logic } => {
                write!(
                    f,
                    "a {} in front of the recorded implementation {logic}",
                    REVIEWED_PROXY.1
                )
            }
        }
    }
}

/// The verdict on a plan: one line per admitted call, one per refused call (or package fault).
#[derive(Debug, Default)]
pub(crate) struct PlanVerdict {
    pub(crate) admitted: Vec<String>,
    pub(crate) refused: Vec<String>,
}

/// Whether `args` is exactly an ABI encoding of `artifact`'s constructor parameters, and the
/// decoded values when it is.
fn strict_constructor_args(artifact: &ReviewedArtifact, args: &[u8]) -> Option<Vec<DynSolValue>> {
    let types = artifact
        .constructor_inputs()
        .iter()
        .map(|(_, ty)| ty.clone())
        .collect();
    match DynSolType::Tuple(types).abi_decode_params(args) {
        Ok(value) if value.abi_encode_params() == args => match value {
            DynSolValue::Tuple(values) => Some(values),
            _ => None,
        },
        _ => None,
    }
}

/// A call decoded as `C`, refusing calldata that is not exactly its encoding.
fn decode_strict<C: SolCall>(data: &[u8]) -> Option<C> {
    C::abi_decode(data)
        .ok()
        .filter(|call| call.abi_encode() == data)
}

struct PlanChecker<'a> {
    build: &'a ReviewedBuild,
    package: &'a PackageView,
    inputs: &'a ReviewedInputs,
    /// The env's CTMs, or the package's without an env.
    admitted_ctms: BTreeSet<Address>,
}

impl PlanChecker<'_> {
    fn artifact(&self, contract: &str) -> Result<&ReviewedArtifact, String> {
        self.build.get(contract).map_err(|why| {
            format!("the reviewed build has no {contract} to compare against: {why}")
        })
    }

    fn facts_of(&self, ctm: Address) -> Result<&CtmFacts, String> {
        self.inputs
            .ctm_facts
            .get(&ctm)
            .ok_or_else(|| format!("no L1 facts were read for the CTM {ctm}"))
    }

    /// Holds a holder of a role L1 also fixes to what L1 says about its CTM, or about the
    /// Bridgehub.
    fn bound_on_l1(&self, role: Role, target: Address, holder: &Holder) -> Result<(), String> {
        if role == Role::EcosystemProxyAdmin {
            return match self.inputs.ecosystem_proxy_admin {
                Some(on_l1) if on_l1 == target => Ok(()),
                Some(on_l1) => Err(format!(
                    "{target} is not the EIP-1967 admin of the Bridgehub on L1, which is {on_l1}"
                )),
                None => Err(format!(
                    "{target} cannot be held to the Bridgehub's admin on L1: the package names no \
                     [core.upgrade_addresses.bridgehub] bridgehub_proxy_addr"
                )),
            };
        }
        let (fact, what): (fn(&CtmFacts) -> Address, &str) = match role {
            Role::CtmProxyAdmin => (|facts| facts.proxy_admin, "EIP-1967 admin"),
            Role::BytecodesSupplier => {
                (|facts| facts.bytecodes_supplier, "L1_BYTECODES_SUPPLIER()")
            }
            Role::ValidatorTimelock => (
                |facts| facts.validator_timelock,
                "validatorTimelockPostV29()",
            ),
            _ => return Ok(()),
        };
        let ctm = holder
            .ctm
            .ok_or_else(|| format!("{} names no CTM", holder.location))?;
        let on_l1 = fact(self.facts_of(ctm)?);
        if on_l1 == target {
            Ok(())
        } else {
            Err(format!(
                "{target} is not the {what} of the CTM {ctm} on L1, which is {on_l1}"
            ))
        }
    }

    /// Judges a call to the CREATE2 factory: `salt ++ init code`.
    fn deployment(&self, call: &PlanCall) -> Result<(Address, Deployed), String> {
        if call.data.len() < 32 {
            return Err(format!(
                "calls the CREATE2 factory with {} bytes of calldata, not a salt and init code",
                call.data.len()
            ));
        }
        let salt = B256::from_slice(&call.data[..32]);
        let init = &call.data[32..];
        if !self.inputs.salts.contains(&salt) {
            return Err(format!(
                "deploys under CREATE2 salt {salt}, which is not a declared salt ({})",
                self.inputs
                    .salts
                    .iter()
                    .map(B256::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        let address = self.inputs.factory.create2(salt, keccak256(init));
        let exactly = |contract: &str, args: &[u8]| -> Result<(), String> {
            let artifact = self.artifact(contract)?;
            let creation = artifact.creation_code();
            if init.len() == creation.len() + args.len()
                && init.starts_with(creation)
                && &init[creation.len()..] == args
            {
                Ok(())
            } else {
                Err(format!(
                    "deploys {address}, which the package records as {contract}, but its init code \
                     is not the reviewed creation code of {contract} ({}) followed by the recorded \
                     constructor arguments",
                    artifact.artifact_file()
                ))
            }
        };

        if let Some(record) = self.package.members.get(&address) {
            if record.create2_factory != self.inputs.factory || record.create2_salt != salt {
                return Err(format!(
                    "deploys {address}, but its [member_deployments] record names factory {} and \
                     salt {}, not the call's factory {} and salt {salt}",
                    record.create2_factory, record.create2_salt, self.inputs.factory
                ));
            }
            exactly(&record.contract, &record.constructor_args)?;
            return Ok((
                address,
                Deployed::Member {
                    contract: record.contract.clone(),
                },
            ));
        }
        if let Some(record) = self
            .package
            .executors
            .core_executor
            .as_ref()
            .filter(|record| record.address == address)
        {
            self.executor_owner(address, record.create2_salt, salt, record.initial_owner)?;
            exactly(
                CORE_EXECUTOR,
                &constructor_args::core_upgrade_executor(record.initial_owner, record.proxy_admin),
            )?;
            return Ok((address, Deployed::CoreExecutor));
        }
        if let Some(record) = self
            .package
            .executors
            .ctm_executor
            .as_ref()
            .filter(|record| record.address == address)
        {
            self.executor_owner(address, record.create2_salt, salt, record.initial_owner)?;
            if !self.admitted_ctms.contains(&record.chain_type_manager) {
                return Err(format!(
                    "deploys the CTM executor {address} for the CTM {}, which is not one of {}",
                    record.chain_type_manager,
                    self.admitted_ctms_label()
                ));
            }
            exactly(
                CTM_EXECUTOR,
                &constructor_args::ctm_upgrade_executor(
                    record.initial_owner,
                    record.chain_type_manager,
                    record.ctm_proxy_admin,
                ),
            )?;
            return Ok((
                address,
                Deployed::CtmExecutor {
                    chain_type_manager: record.chain_type_manager,
                    ctm_proxy_admin: record.ctm_proxy_admin,
                },
            ));
        }
        if let Some(object) = self.package.objects.iter().find(|o| o.address == address) {
            let artifact = self.artifact(object.contract)?;
            let creation = artifact.creation_code();
            let well_formed = init.starts_with(creation)
                && strict_constructor_args(artifact, &init[creation.len()..]).is_some();
            if !well_formed {
                return Err(format!(
                    "deploys {address}, the package's {} ({}), but its init code is not the \
                     reviewed creation code of {} ({}) followed by an exact ABI encoding of its \
                     constructor arguments",
                    object.location,
                    object.contract,
                    object.contract,
                    artifact.artifact_file()
                ));
            }
            return Ok((
                address,
                Deployed::Object {
                    contract: object.contract,
                    location: object.location.clone(),
                },
            ));
        }
        for migration in self.objects_of("RegistryBootstrapMigration") {
            for core_transition in self.objects_at("core_transition_addr") {
                let args =
                    constructor_args::registry_bootstrap_sequence(migration, core_transition);
                let artifact = self.artifact(BOOTSTRAP_SEQUENCE)?;
                let mut expected = artifact.creation_code().to_vec();
                expected.extend_from_slice(&args);
                if expected == init {
                    return Ok((address, Deployed::BootstrapSequence));
                }
            }
        }
        if let Ok(proxy) = self.build.get(REVIEWED_PROXY.1) {
            if init.starts_with(proxy.creation_code()) && self.package.named.contains(&address) {
                return self.proxy(address, proxy, &init[proxy.creation_code().len()..]);
            }
        }
        Err(format!(
            "deploys {address} under salt {salt}: it is neither a [member_deployments] record nor an \
             executor, object or proxy the package names"
        ))
    }

    fn executor_owner(
        &self,
        address: Address,
        recorded_salt: B256,
        salt: B256,
        initial_owner: Address,
    ) -> Result<(), String> {
        if recorded_salt != salt {
            return Err(format!(
                "deploys the executor {address} under salt {salt}, but its record names salt \
                 {recorded_salt}"
            ));
        }
        if initial_owner != self.inputs.governance {
            return Err(format!(
                "deploys the executor {address} for owner {initial_owner}, not for governance {}",
                self.inputs.governance
            ));
        }
        Ok(())
    }

    fn admitted_ctms_label(&self) -> &'static str {
        if self.inputs.env_ctms.is_some() {
            "the env's [[ctm_contracts.ctms]]"
        } else {
            "the CTMs the package's [ctms.<key>] tables drive"
        }
    }

    fn objects_of(&self, contract: &str) -> Vec<Address> {
        self.package
            .objects
            .iter()
            .filter(|o| o.contract == contract)
            .map(|o| o.address)
            .collect()
    }

    fn objects_at(&self, key: &str) -> Vec<Address> {
        self.package
            .objects
            .iter()
            .filter(|o| o.location.ends_with(&format!("] {key}")))
            .map(|o| o.address)
            .collect()
    }

    /// A reviewed proxy the package names, over a recorded implementation and a package
    /// ProxyAdmin. Its initializer is the package's to review.
    fn proxy(
        &self,
        address: Address,
        proxy: &ReviewedArtifact,
        args: &[u8],
    ) -> Result<(Address, Deployed), String> {
        let shape = || {
            format!(
                "deploys {address}, a {} the package names, but",
                REVIEWED_PROXY.1
            )
        };
        let Some(values) = strict_constructor_args(proxy, args) else {
            return Err(format!(
                "{} its constructor arguments are not an exact ABI encoding of (address, address, \
                 bytes)",
                shape()
            ));
        };
        let (Some(logic), Some(admin)) = (
            values.first().and_then(DynSolValue::as_address),
            values.get(1).and_then(DynSolValue::as_address),
        ) else {
            return Err(format!(
                "{} its constructor takes no (logic, admin) pair",
                shape()
            ));
        };
        if !self.package.members.contains_key(&logic) {
            return Err(format!(
                "{} its implementation {logic} is not a [member_deployments] record",
                shape()
            ));
        }
        let ecosystem_admin = self
            .package
            .holders_of(Role::EcosystemProxyAdmin, admin)
            .iter()
            .any(|holder| {
                self.bound_on_l1(Role::EcosystemProxyAdmin, admin, holder)
                    .is_ok()
            });
        let ctm_admin = self
            .package
            .holders_of(Role::CtmProxyAdmin, admin)
            .iter()
            .any(|holder| self.bound_on_l1(Role::CtmProxyAdmin, admin, holder).is_ok());
        if !ecosystem_admin && !ctm_admin {
            return Err(format!(
                "{} its admin {admin} is neither the ecosystem ProxyAdmin nor the ProxyAdmin of \
                 one of its CTMs on L1",
                shape()
            ));
        }
        Ok((address, Deployed::Proxy { logic }))
    }

    /// Judges a call other than a deployment against [`ALLOWLIST`].
    fn allowlisted(
        &self,
        target: Address,
        data: &[u8],
        planned: &BTreeMap<Address, Deployed>,
        roles: &[Role],
    ) -> Result<String, String> {
        let Some(selector) = data.get(..4) else {
            return Err(
                "carries no function selector: not an allowlisted deployer call".to_string(),
            );
        };
        let entries: Vec<&AllowedCall> = ALLOWLIST
            .iter()
            .filter(|entry| {
                entry.selector == selector && entry.roles.iter().any(|r| roles.contains(r))
            })
            .collect();
        if entries.is_empty() {
            return Err(format!(
                "selector 0x{} is not on the deployer allowlist",
                hex::encode(selector)
            ));
        }
        let mut reasons = Vec::new();
        for entry in &entries {
            let held: Vec<(Role, &Holder)> = entry
                .roles
                .iter()
                .filter(|role| roles.contains(role))
                .flat_map(|role| {
                    self.package
                        .holders_of(*role, target)
                        .iter()
                        .map(move |holder| (*role, holder))
                })
                .collect();
            if held.is_empty() {
                let allowed = entry
                    .roles
                    .iter()
                    .filter(|role| roles.contains(role))
                    .map(|role| {
                        let holders = self
                            .package
                            .holders(*role)
                            .map(|(a, _)| a.to_string())
                            .collect::<Vec<_>>();
                        if holders.is_empty() {
                            format!("{role} (the package names none)")
                        } else {
                            format!("{role} ({})", holders.join(", "))
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                reasons.push(format!(
                    "{} is admitted only on {allowed}, and {target} is none of them",
                    entry.signature
                ));
                continue;
            }
            for (role, holder) in held {
                let at = &holder.location;
                let outcome = self
                    .bound_on_l1(role, target, holder)
                    .and_then(|()| self.constraint(entry, target, data, planned));
                match outcome {
                    Ok(what) => return Ok(format!("{} on {role} ({at}): {what}", entry.signature)),
                    Err(why) => {
                        reasons.push(format!("{} on {role} ({at}): {why}", entry.signature))
                    }
                }
            }
        }
        Err(reasons.join("; "))
    }

    fn constraint(
        &self,
        entry: &AllowedCall,
        target: Address,
        data: &[u8],
        planned: &BTreeMap<Address, Deployed>,
    ) -> Result<String, String> {
        match entry.constraint {
            Constraint::NewOwnerIsGovernance => {
                let call = decode_strict::<abi::transferOwnershipCall>(data)
                    .ok_or("the calldata is not exactly transferOwnership(address)")?;
                if call.newOwner == self.inputs.governance {
                    Ok("hands it to governance".to_string())
                } else {
                    Err(format!(
                        "hands it to {}, not to governance {}",
                        call.newOwner, self.inputs.governance
                    ))
                }
            }
            Constraint::Publication => {
                let call = decode_strict::<abi::publishEVMBytecodesCall>(data)
                    .ok_or("the calldata is not exactly publishEVMBytecodes(bytes[])")?;
                Ok(format!("publishes {} bytecode(s)", call._bytecodes.len()))
            }
            Constraint::HandoverToPlannedExecutor => self.handover(target, data, planned),
            Constraint::HandoverMulticall => {
                let call = decode_strict::<abi::multicallCall>(data).ok_or(
                    "the calldata is not exactly multicall((address,uint256,bytes)[],bool)",
                )?;
                if !call._requireSuccess {
                    return Err("does not require every call to succeed".to_string());
                }
                if call._calls.is_empty() {
                    return Err("carries no call".to_string());
                }
                let mut admitted = Vec::new();
                for (i, inner) in call._calls.iter().enumerate() {
                    if !inner.value.is_zero() {
                        return Err(format!("its call {i} sends {} wei", inner.value));
                    }
                    let what = self
                        .allowlisted(
                            inner.target,
                            &inner.data,
                            planned,
                            &[Role::AdminActionTarget],
                        )
                        .map_err(|why| format!("its call {i} to {}: {why}", inner.target))?;
                    admitted.push(what);
                }
                Ok(format!("runs {}", admitted.join("; ")))
            }
        }
    }

    /// A declared admin action that hands authority to the CTM executor this plan deploys, or to
    /// the ProxyAdmin that administers that executor's CTM on L1. The executor's own
    /// `ctm_proxy_admin` record is the bundle's, so it is held to L1 too.
    fn handover(
        &self,
        target: Address,
        data: &[u8],
        planned: &BTreeMap<Address, Deployed>,
    ) -> Result<String, String> {
        let Some(action) = self
            .package
            .admin_actions
            .iter()
            .find(|a| a.target == target && a.value.is_zero() && a.data[..] == *data)
        else {
            return Err(format!(
                "it is not one of the package's declared admin actions on {target}"
            ));
        };
        let executors: Vec<(Address, Address, Address)> = planned
            .iter()
            .filter_map(|(address, deployed)| match deployed {
                Deployed::CtmExecutor {
                    chain_type_manager,
                    ctm_proxy_admin,
                } => Some((*address, *chain_type_manager, *ctm_proxy_admin)),
                _ => None,
            })
            .collect();
        if let Some(call) = decode_strict::<abi::transferOwnershipCall>(data) {
            return match executors.iter().find(|(e, _, _)| *e == call.newOwner) {
                Some(_) => Ok(format!(
                    "`{}` nominates the CTM executor this plan deploys",
                    action.label
                )),
                None => Err(format!(
                    "`{}` nominates {}, which is not a CTM executor this plan deploys",
                    action.label, call.newOwner
                )),
            };
        }
        if let Some(call) = decode_strict::<abi::changeProxyAdminCall>(data) {
            let Some((_, ctm, _)) = executors
                .iter()
                .find(|(_, _, admin)| *admin == call.newAdmin)
            else {
                return Err(format!(
                    "`{}` moves {} under {}, which is not the ProxyAdmin of a CTM executor this \
                     plan deploys",
                    action.label, call.proxy, call.newAdmin
                ));
            };
            let on_l1 = self.facts_of(*ctm)?.proxy_admin;
            return if on_l1 == call.newAdmin {
                Ok(format!(
                    "`{}` moves {} under the ProxyAdmin that administers the planned CTM \
                     executor's CTM {ctm} on L1",
                    action.label, call.proxy
                ))
            } else {
                Err(format!(
                    "`{}` moves {} under {}, which the planned CTM executor's record names, but \
                     the CTM {ctm} is administered by {on_l1} on L1",
                    action.label, call.proxy, call.newAdmin
                ))
            };
        }
        Err(format!(
            "`{}` is neither transferOwnership(address) nor changeProxyAdmin(address,address)",
            action.label
        ))
    }
}

/// Holds every deployer call to the reviewed build, the package and the reviewed inputs.
pub(crate) fn check_plan(
    build: &ReviewedBuild,
    package: &PackageView,
    inputs: &ReviewedInputs,
    calls: &[PlanCall],
) -> PlanVerdict {
    let checker = PlanChecker {
        build,
        package,
        inputs,
        admitted_ctms: inputs.env_ctms.clone().unwrap_or_else(|| package.ctms()),
    };
    let mut verdict = PlanVerdict {
        refused: package.faults.clone(),
        ..PlanVerdict::default()
    };
    if let Some(env_ctms) = &inputs.env_ctms {
        for (ctm, holders) in package.holders(Role::CtmProxy) {
            if !env_ctms.contains(ctm) {
                for holder in holders {
                    verdict.refused.push(format!(
                        "the package's CTM {ctm} ({}) is not one of the env's \
                         [[ctm_contracts.ctms]]",
                        holder.location
                    ));
                }
            }
        }
    }
    // Deployments first: a handover is admitted only toward the CTM executor the plan deploys.
    // `None` marks a call still to be held against the allowlist.
    let mut planned = BTreeMap::new();
    let mut outcomes: Vec<Option<Result<String, String>>> = Vec::with_capacity(calls.len());
    for call in calls {
        outcomes.push(if !call.value.is_zero() {
            Some(Err(format!(
                "sends {} wei; the deployer sends no value",
                call.value
            )))
        } else if call.to == inputs.factory {
            Some(checker.deployment(call).map(|(address, deployed)| {
                let line = format!("deploys {address}: {deployed}");
                planned.insert(address, deployed);
                line
            }))
        } else {
            None
        });
    }
    let all_roles = [
        Role::CtmProxy,
        Role::ValidatorTimelock,
        Role::CtmProxyAdmin,
        Role::EcosystemProxyAdmin,
        Role::BytecodesSupplier,
        Role::ChainAdmin,
        Role::AdminActionTarget,
    ];
    for (call, outcome) in calls.iter().zip(outcomes) {
        let outcome = outcome
            .unwrap_or_else(|| checker.allowlisted(call.to, &call.data, &planned, &all_roles));
        match outcome {
            Ok(line) => verdict.admitted.push(format!("{call}: {line}")),
            Err(why) => verdict.refused.push(format!("{call}: {why}")),
        }
    }
    verdict
}

// ─── Reviewed inputs ────────────────────────────────────────────────────────────

/// The factory, salts, governance owner and CTMs `env` declares. The CTM facts are read from L1
/// separately ([`read_ctm_facts`]).
fn env_inputs(env_cfg: &EnvConfig) -> anyhow::Result<ReviewedInputs> {
    // `deploy_puh_guardians` deploys under its own salt from zk-governance artifacts, neither of
    // which the check knows.
    anyhow::ensure!(
        !env_cfg.redeploys_zk_governance()?,
        "{} declares `redeploy_zk_governance = true`, but the deployer plan check does not cover \
         the PUH/Guardians redeploy: a bundle that carries it cannot be signed",
        env_cfg.upgrade_input_path.display()
    );
    let factory = env_cfg.create2_factory().with_context(|| {
        format!(
            "{} declares no create2_factory_addr",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let governance = env_cfg.owner_address()?.with_context(|| {
        format!(
            "{} declares no owner_address: the governance owner is a reviewed input of the \
             deployer plan check",
            env_cfg.upgrade_input_path.display()
        )
    })?;
    let salts: BTreeSet<B256> = env_cfg
        .create2_factory_salt_for_upgrade()?
        .into_iter()
        .chain(
            env_cfg
                .create2_factory_salt_for_upgrade_per_ctm()?
                .into_values(),
        )
        .collect();
    Ok(ReviewedInputs {
        factory,
        salts,
        governance,
        env_ctms: Some(env_cfg.ctms().iter().map(|ctm| ctm.proxy).collect()),
        ctm_facts: BTreeMap::new(),
        ecosystem_proxy_admin: None,
    })
}

fn validate_inputs(inputs: &ReviewedInputs) -> anyhow::Result<()> {
    anyhow::ensure!(
        inputs.factory == DETERMINISTIC_CREATE2_FACTORY,
        "the CREATE2 factory {} is not the deterministic deployment proxy {}: every record and \
         object derives through that one",
        inputs.factory,
        DETERMINISTIC_CREATE2_FACTORY
    );
    anyhow::ensure!(
        !inputs.salts.is_empty(),
        "no CREATE2 salt is declared: the env's [contracts] create2_factory_salt and \
         [create2_factory_salts], or --create2-salt"
    );
    Ok(())
}

/// The EIP-1967 admin of `proxy` on L1.
async fn read_proxy_admin<P: Provider>(provider: &P, proxy: Address) -> anyhow::Result<Address> {
    let word = provider
        .get_storage_at(proxy, EIP1967_PROXY_ADMIN_SLOT.into())
        .await
        .with_context(|| format!("read the EIP-1967 admin slot of {proxy}"))?;
    Ok(Address::from_word(word.into()))
}

/// [`CtmFacts`] of each of `ctms`, read from L1 before anything is signed.
pub(crate) async fn read_ctm_facts<P: Provider>(
    provider: &P,
    ctms: &BTreeSet<Address>,
) -> anyhow::Result<BTreeMap<Address, CtmFacts>> {
    let mut facts = BTreeMap::new();
    for &ctm in ctms {
        let proxy_admin = read_proxy_admin(provider, ctm).await?;
        let view = CtmView::new(ctm, provider);
        let bytecodes_supplier = view
            .L1_BYTECODES_SUPPLIER()
            .call()
            .await
            .with_context(|| format!("read L1_BYTECODES_SUPPLIER() of the CTM {ctm}"))?;
        let validator_timelock = view
            .validatorTimelockPostV29()
            .call()
            .await
            .with_context(|| format!("read validatorTimelockPostV29() of the CTM {ctm}"))?;
        facts.insert(
            ctm,
            CtmFacts {
                proxy_admin,
                bytecodes_supplier,
                validator_timelock,
            },
        );
    }
    Ok(facts)
}

/// Refuses an RPC on another chain than `expected`: the CTM facts must be the signing chain's.
async fn ensure_rpc_chain<P: Provider>(provider: &P, expected: u64) -> anyhow::Result<()> {
    let actual = provider
        .get_chain_id()
        .await
        .context("eth_chainId on --l1-rpc-url")?;
    anyhow::ensure!(
        actual == expected,
        "--l1-rpc-url reports chain id {actual}, but the reviewed env is on chain id {expected}"
    );
    Ok(())
}

/// Runs the check on `calls` and reports it; an error names every refused call.
fn report(
    build: &ReviewedBuild,
    package: &PackageView,
    inputs: &ReviewedInputs,
    calls: &[PlanCall],
) -> anyhow::Result<()> {
    validate_inputs(inputs)?;
    for entry in ALLOWLIST {
        let roles = entry
            .roles
            .iter()
            .map(Role::to_string)
            .collect::<Vec<_>>()
            .join(" / ");
        logger::info(format!(
            "  allowlist: {} on {roles} ({:?}); emitted by {}",
            entry.signature, entry.constraint, entry.source
        ));
    }
    let verdict = check_plan(build, package, inputs, calls);
    for line in &verdict.admitted {
        logger::info(line);
    }
    if !verdict.refused.is_empty() {
        anyhow::bail!(
            "deployer plan check failed: {} refusal(s), nothing may be signed:\n  - {}",
            verdict.refused.len(),
            verdict.refused.join("\n  - ")
        );
    }
    logger::success(format!(
        "Deployer plan: all {} call(s) admitted",
        verdict.admitted.len()
    ));
    Ok(())
}

/// The deployer's calls in `manifest`; `None` when it signs nothing, which needs no check.
fn plan_to_check(manifest: &Path, deployer: Address) -> anyhow::Result<Option<Vec<PlanCall>>> {
    let (calls, other_signers) = deployer_calls(manifest, deployer)?;
    if calls.is_empty() {
        logger::warn(format!(
            "{} names no call for the deployer {deployer} ({other_signers} bundle(s) of other \
             signers): the deployer signs nothing",
            manifest.display()
        ));
        return Ok(None);
    }
    logger::step(format!(
        "Deployer plan: {} call(s) the deployer {deployer} signs ({other_signers} bundle(s) of \
         other signers are not the deployer's)",
        calls.len()
    ));
    Ok(Some(calls))
}

fn reviewed_build(contract_hashes: Option<&Path>) -> anyhow::Result<ReviewedBuild> {
    let path = contract_hashes_path(contract_hashes);
    Ok(ReviewedBuild::load(CodeIdentity::from_hashes_file(&path)?))
}

/// The build of the checkout at `repository_root`, held to that checkout's
/// `AllContractsHashes.json`. The reviewed build reads `l1-contracts/out` relative to the
/// working directory, so a working directory inside another checkout is refused.
fn reviewed_build_of(repository_root: &Path) -> anyhow::Result<ReviewedBuild> {
    let expected = repository_root.join("l1-contracts").join("out");
    let read = repo_relative_path("l1-contracts/out");
    let canonical = |path: &Path| {
        std::fs::canonicalize(path).with_context(|| {
            format!(
                "{} not found: build the contracts of this checkout first (`yarn l1 \
                 build:foundry`)",
                path.display()
            )
        })
    };
    anyhow::ensure!(
        canonical(&read)? == canonical(&expected)?,
        "the reviewed build would be read from {}, not from this checkout's {}: run from inside \
         {}",
        read.display(),
        expected.display(),
        repository_root.display()
    );
    let hashes = repository_root.join("AllContractsHashes.json");
    Ok(ReviewedBuild::load(CodeIdentity::from_hashes_file(
        &hashes,
    )?))
}

/// The env config of the upgrade a bundle names, from this checkout: `prepare-all` is the
/// release's own directory, and a `forge-script` upgrade declares the salts and owner its
/// deployer calls are held to in its own `upgrade-envs/<upgrade>/<env>.toml`.
fn upgrade_env(metadata: &DeployBundleMetadata) -> anyhow::Result<EnvConfig> {
    validate_upgrade_name(&metadata.upgrade)?;
    let descriptor = UpgradeDescriptor::load(&metadata.upgrade)?;
    anyhow::ensure!(
        !matches!(descriptor, UpgradeDescriptor::PrepareAll {})
            || metadata.upgrade == DEFAULT_UPGRADE,
        "the bundle was generated for {}, but `prepare-all` here is the {DEFAULT_UPGRADE} flow: \
         check it with the protocol_ops of the line that generated it",
        metadata.upgrade
    );
    EnvConfig::load_from_upgrade_env_dir(
        &metadata.env,
        &format!("upgrade-envs/{}", metadata.upgrade),
    )
}

/// The chain both the env and the bundle are on. The bundle's `l1.chain_id` picks the key and
/// RPC, so an env on another chain would hold the plan to the wrong chain's reviewed inputs.
fn ensure_env_chain(
    env_chain_id: Option<u64>,
    bundle_chain_id: Option<u64>,
) -> anyhow::Result<u64> {
    match (env_chain_id, bundle_chain_id) {
        (Some(env), Some(bundle)) if env == bundle => Ok(env),
        _ => anyhow::bail!(
            "the env's permanent values put it on L1 chain id {env_chain_id:?}, but the bundle \
             records l1.chain_id {bundle_chain_id:?}: the plan would be held to one chain's \
             reviewed inputs and signed for another"
        ),
    }
}

/// The check on a deploy bundle, with the env of the upgrade the bundle names loaded from this
/// checkout and the CTM facts read over `l1_rpc_url`. The caller has verified the bundle's
/// integrity.
pub(crate) async fn check_bundle(
    bundle_dir: &Path,
    metadata: &DeployBundleMetadata,
    l1_rpc_url: &str,
) -> anyhow::Result<()> {
    let deployer = metadata
        .deployer_address
        .context("bundle metadata has no deployer_address")?;
    if metadata.contracts_worktree_dirty {
        logger::warn(
            "the bundle was generated from a dirty worktree; signing it is refused \
             (contracts_worktree_dirty)",
        );
    }
    let Some(calls) = plan_to_check(&bundle_dir.join(MANIFEST_FILE), deployer)? else {
        return Ok(());
    };
    let env_cfg = upgrade_env(metadata)?;
    let chain_id = ensure_env_chain(env_cfg.l1_chain_id(), metadata.l1.chain_id)?;
    let mut inputs = env_inputs(&env_cfg)?;
    let provider = get_provider(l1_rpc_url)?;
    ensure_rpc_chain(&provider, chain_id).await?;
    let env_ctms = env_cfg.ctms().iter().map(|ctm| ctm.proxy).collect();
    inputs.ctm_facts = read_ctm_facts(&provider, &env_ctms).await?;
    inputs.ecosystem_proxy_admin = Some(read_proxy_admin(&provider, env_cfg.bridgehub()).await?);
    report(
        &reviewed_build_of(&paths::contracts_root())?,
        &PackageView::load(&bundle_dir.join("ecosystem.toml"))?,
        &inputs,
        &calls,
    )
}

/// Refuses to sign unless the contracts checkout is exactly the generation's: at the bundle's
/// `contracts_commit`, with no change to the contract sources and reviewed inputs
/// (`contract_source_pathspecs`), from a bundle generated from a clean worktree. Signing runs the
/// checkout's reviewed inputs (env salts and owner, the allowlist, the build) against the plan.
pub(crate) fn require_checkout_at(
    repository_root: &Path,
    metadata: &DeployBundleMetadata,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        !metadata.contracts_worktree_dirty,
        "the bundle was generated from a worktree whose contract sources differed from {} \
         (contracts_worktree_dirty): it cannot be signed. Generate it again from a clean checkout",
        metadata.contracts_commit
    );
    let git = |args: &[&str]| -> anyhow::Result<String> {
        let output = Command::new("git")
            .args(args)
            .current_dir(repository_root)
            .output()
            .with_context(|| format!("run git {} in {}", args[0], repository_root.display()))?;
        anyhow::ensure!(
            output.status.success(),
            "git {} failed in {}: {}",
            args[0],
            repository_root.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    };
    ensure_same_commit(&git(&["rev-parse", "HEAD"])?, &metadata.contracts_commit)?;
    let pathspecs = contract_source_pathspecs(&metadata.upgrade);
    let status_args: Vec<&str> = ["status", "--porcelain", "--"]
        .into_iter()
        .chain(pathspecs.iter().map(String::as_str))
        .collect();
    let status = git(&status_args)?;
    anyhow::ensure!(
        status.is_empty(),
        "this checkout's contract sources or reviewed inputs differ from {}:\n{status}\nSigning \
         holds the plan to them: discard or commit the changes, rebuild, and run again",
        metadata.contracts_commit
    );
    Ok(())
}

fn ensure_same_commit(head: &str, bundle_commit: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        head == bundle_commit,
        "this checkout is at {head}, but the bundle was generated from {bundle_commit}. Signing \
         must run from the generation commit, whose build the plan is held against: `git checkout \
         {bundle_commit}`, rebuild, and run again (a --fork-url rehearsal does not require it)"
    );
    Ok(())
}

// ─── CLI ────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Parser)]
pub struct CheckDeployerPlanArgs {
    /// An unpacked deploy bundle: its manifest, `ecosystem.toml`, deployer and env are used, the
    /// env's reviewed inputs come from this checkout, and the checkout must be the bundle's
    /// `contracts_commit` with clean contract sources.
    #[clap(long, conflicts_with_all = ["manifest", "ecosystem_toml", "deployer", "env", "contract_hashes"])]
    pub bundle: Option<PathBuf>,
    /// The L1 the plan would be signed for: each CTM's ProxyAdmin, BytecodesSupplier and
    /// ValidatorTimelock, and the Bridgehub's ProxyAdmin, are read from it.
    #[clap(long)]
    pub l1_rpc_url: String,
    /// A prepare output's `manifest.json` (instead of `--bundle`).
    #[clap(long, requires_all = ["ecosystem_toml", "deployer"])]
    pub manifest: Option<PathBuf>,
    /// The merged prepare package (`ecosystem.toml`) of `--manifest`.
    #[clap(long)]
    pub ecosystem_toml: Option<PathBuf>,
    /// The deployer EOA whose bundles are checked.
    #[clap(long)]
    pub deployer: Option<Address>,
    /// The env whose factory, salts, owner, CTMs and Bridgehub are the reviewed inputs.
    #[clap(long)]
    pub env: Option<String>,
    /// The reviewed governance owner, instead of the env's `owner_address`.
    #[clap(long)]
    pub governance: Option<Address>,
    /// A declared CREATE2 salt, repeatable; added to the env's.
    #[clap(long = "create2-salt")]
    pub create2_salts: Vec<B256>,
    /// The hashes file the local build is held against instead of the committed
    /// `AllContractsHashes.json` (as `verify-bootstrap --contract-hashes`).
    #[clap(long)]
    pub contract_hashes: Option<PathBuf>,
}

pub async fn run(args: CheckDeployerPlanArgs) -> anyhow::Result<()> {
    if let Some(bundle) = &args.bundle {
        anyhow::ensure!(
            args.governance.is_none() && args.create2_salts.is_empty(),
            "--bundle takes its reviewed inputs from the env the bundle names"
        );
        let bundle_dir = std::fs::canonicalize(bundle)
            .with_context(|| format!("deploy bundle not found: {}", bundle.display()))?;
        let metadata = verify_bundle_integrity(&bundle_dir)?;
        require_checkout_at(&paths::contracts_root(), &metadata)?;
        return check_bundle(&bundle_dir, &metadata, &args.l1_rpc_url).await;
    }
    let (Some(manifest), Some(ecosystem_toml), Some(deployer)) =
        (&args.manifest, &args.ecosystem_toml, args.deployer)
    else {
        anyhow::bail!("pass --bundle <dir>, or --manifest, --ecosystem-toml and --deployer");
    };
    let Some(calls) = plan_to_check(manifest, deployer)? else {
        return Ok(());
    };
    let provider = get_provider(&args.l1_rpc_url)?;
    let package = PackageView::load(ecosystem_toml)?;
    let (mut inputs, bridgehub) = match &args.env {
        Some(env) => {
            let env_cfg = EnvConfig::load(env)?;
            ensure_rpc_chain(
                &provider,
                env_cfg
                    .l1_chain_id()
                    .with_context(|| format!("the env {env} declares no l1_chain_id"))?,
            )
            .await?;
            (env_inputs(&env_cfg)?, Some(env_cfg.bridgehub()))
        }
        None => (
            ReviewedInputs {
                factory: DETERMINISTIC_CREATE2_FACTORY,
                salts: BTreeSet::new(),
                governance: args.governance.context(
                    "pass --governance or --env: the governance owner is a reviewed input",
                )?,
                env_ctms: None,
                ctm_facts: BTreeMap::new(),
                ecosystem_proxy_admin: None,
            },
            package.bridgehub,
        ),
    };
    if let Some(governance) = args.governance {
        inputs.governance = governance;
    }
    inputs.salts.extend(args.create2_salts.iter().copied());
    let ctms = inputs.env_ctms.clone().unwrap_or_else(|| package.ctms());
    inputs.ctm_facts = read_ctm_facts(&provider, &ctms).await?;
    if let Some(bridgehub) = bridgehub {
        inputs.ecosystem_proxy_admin = Some(read_proxy_admin(&provider, bridgehub).await?);
    }
    report(
        &reviewed_build(args.contract_hashes.as_deref())?,
        &package,
        &inputs,
        &calls,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::sol_types::SolValue;

    const SALT: B256 = B256::repeat_byte(0x5A);
    const OTHER_SALT: B256 = B256::repeat_byte(0x77);
    const GOVERNANCE: Address = Address::repeat_byte(0x60);
    const DEPLOYER: Address = Address::repeat_byte(0xD0);
    const SUPPLIER: Address = Address::repeat_byte(0xB5);
    const VALIDATOR_TIMELOCK: Address = Address::repeat_byte(0x7C);
    const CTM: Address = Address::repeat_byte(0xC7);
    const CTM_PROXY_ADMIN: Address = Address::repeat_byte(0xCA);
    const ECOSYSTEM_PROXY_ADMIN: Address = Address::repeat_byte(0xEA);
    const NOTIFIER: Address = Address::repeat_byte(0x9E);
    const OLD_NOTIFIER_ADMIN: Address = Address::repeat_byte(0x6B);
    const CHAIN_ADMIN: Address = Address::repeat_byte(0x16);
    const STRANGER: Address = Address::repeat_byte(0xEE);

    fn creation(name: &str) -> Vec<u8> {
        format!("creation code of {name}").into_bytes()
    }

    fn build() -> ReviewedBuild {
        ReviewedBuild::from_parts(&[
            ("Admin.sol", "AdminFacet", creation("AdminFacet")),
            ("CTMRelease.sol", "CTMRelease", creation("CTMRelease")),
            (
                "CTMUpgradeExecutor.sol",
                "CTMUpgradeExecutor",
                creation("CTMUpgradeExecutor"),
            ),
            (
                REVIEWED_PROXY.0,
                REVIEWED_PROXY.1,
                creation(REVIEWED_PROXY.1),
            ),
        ])
        .with_constructor(
            "AdminFacet",
            &[("_l1ChainId", "uint256"), ("_rollupDAManager", "address")],
        )
        .with_constructor("CTMRelease", &[("_manifest", "(uint256,address[])")])
        .with_constructor(
            REVIEWED_PROXY.1,
            &[
                ("_logic", "address"),
                ("admin_", "address"),
                ("_data", "bytes"),
            ],
        )
    }

    fn landing(salt: B256, init: &[u8]) -> Address {
        DETERMINISTIC_CREATE2_FACTORY.create2(salt, keccak256(init))
    }

    fn admin_args() -> Vec<u8> {
        (U256::from(1), Address::repeat_byte(0x27)).abi_encode_params()
    }

    fn admin_init() -> Vec<u8> {
        [creation("AdminFacet"), admin_args()].concat()
    }

    fn release_init() -> Vec<u8> {
        let manifest = (U256::from(35), vec![Address::repeat_byte(1)]);
        [creation("CTMRelease"), (manifest,).abi_encode_params()].concat()
    }

    /// The CTM executor an honest plan deploys: for [`CTM`], upgrading through its live
    /// ProxyAdmin.
    const HONEST: Executor = Executor {
        ctm: CTM,
        proxy_admin: CTM_PROXY_ADMIN,
    };

    /// What a CTM executor record names: its CTM and the ProxyAdmin it upgrades that CTM through.
    #[derive(Clone, Copy)]
    struct Executor {
        ctm: Address,
        proxy_admin: Address,
    }

    fn executor_init_for(executor: Executor) -> Vec<u8> {
        [
            creation("CTMUpgradeExecutor"),
            constructor_args::ctm_upgrade_executor(GOVERNANCE, executor.ctm, executor.proxy_admin),
        ]
        .concat()
    }

    fn deploy(salt: B256, init: &[u8]) -> (Address, Bytes) {
        (
            DETERMINISTIC_CREATE2_FACTORY,
            Bytes::from([salt.as_slice(), init].concat()),
        )
    }

    fn calldata(call: impl SolCall) -> Bytes {
        Bytes::from(call.abi_encode())
    }

    fn handover_to(owner: Address) -> Bytes {
        calldata(abi::transferOwnershipCall { newOwner: owner })
    }

    fn change_admin_to(new_admin: Address) -> Bytes {
        calldata(abi::changeProxyAdminCall {
            proxy: NOTIFIER,
            newAdmin: new_admin,
        })
    }

    fn package_toml() -> String {
        package_toml_for(HONEST)
    }

    /// The bootstrap package of [`clean_plan_for`]`(executor)`.
    fn package_toml_for(executor_record: Executor) -> String {
        let executor = landing(SALT, &executor_init_for(executor_record));
        format!(
            r#"
[core]
create2_factory_salt = "{SALT}"

[ctms.zksync_os]
create2_factory_salt = "{SALT}"

[ctms.zksync_os.member_deployments.{admin}]
contract = "AdminFacet"
create2_factory = "{factory}"
create2_salt = "{SALT}"
constructor_args = "0x{admin_args}"

[ctms.zksync_os.registry]
ctm_release_addr = "{release}"
ctm_transition_addr = "0x0000000000000000000000000000000000000000"
ctm_upgrade_executor_addr = "{executor}"

[ctms.zksync_os.upgrade_executors.ctm_executor]
address = "{executor}"
create2_salt = "{SALT}"
initial_owner = "{GOVERNANCE}"
chain_type_manager = "{executor_ctm}"
ctm_proxy_admin = "{executor_admin}"

[ctms.zksync_os.state_transition]
chain_type_manager_proxy = "{CTM}"
bytecodes_supplier_addr = "{SUPPLIER}"
validator_timelock_addr = "{VALIDATOR_TIMELOCK}"

[ctms.zksync_os.deployed_addresses]
transparent_proxy_admin = "{CTM_PROXY_ADMIN}"

[ctms.zksync_os.ctm_admin_calls]
chain_admin = "{CHAIN_ADMIN}"

[[external_actions]]
phase = "admin"
label = "move the notifier under the CTM ProxyAdmin"
authority = "the live owner"
target = "{OLD_NOTIFIER_ADMIN}"
value = "0"
data = "{change_admin}"

[[external_actions]]
phase = "admin"
label = "nominate the CTM executor"
authority = "the live owner"
target = "{NOTIFIER}"
value = "0"
data = "{nominate}"
"#,
            admin = landing(SALT, &admin_init()),
            factory = DETERMINISTIC_CREATE2_FACTORY,
            admin_args = hex::encode(admin_args()),
            release = landing(SALT, &release_init()),
            executor_ctm = executor_record.ctm,
            executor_admin = executor_record.proxy_admin,
            change_admin = change_admin_to(executor_record.proxy_admin),
            nominate = handover_to(executor),
        )
    }

    fn package() -> PackageView {
        package_from(&package_toml())
    }

    fn package_from(toml: &str) -> PackageView {
        PackageView::from_toml(&toml::from_str(toml).unwrap(), "test.toml").unwrap()
    }

    /// What L1 says about [`CTM`]: it is administered by [`CTM_PROXY_ADMIN`], reads published
    /// bytecode from [`SUPPLIER`] and runs [`VALIDATOR_TIMELOCK`].
    fn live_ctm() -> CtmFacts {
        CtmFacts {
            proxy_admin: CTM_PROXY_ADMIN,
            bytecodes_supplier: SUPPLIER,
            validator_timelock: VALIDATOR_TIMELOCK,
        }
    }

    fn inputs() -> ReviewedInputs {
        ReviewedInputs {
            factory: DETERMINISTIC_CREATE2_FACTORY,
            salts: [SALT].into(),
            governance: GOVERNANCE,
            env_ctms: Some([CTM].into()),
            ctm_facts: [(CTM, live_ctm())].into(),
            ecosystem_proxy_admin: Some(ECOSYSTEM_PROXY_ADMIN),
        }
    }

    /// The shapes of the v35 bootstrap prepare's deployer bundle: deployments of a recorded
    /// member, an object and an executor, an ownership normalization, a bytecode publication and
    /// the ServerNotifier handover through the ChainAdmin and directly.
    fn clean_plan() -> Vec<(Address, U256, Bytes)> {
        clean_plan_for(HONEST)
    }

    /// [`clean_plan`] with the CTM executor `executor` names, and the ServerNotifier handed to it
    /// and to the ProxyAdmin its record names.
    fn clean_plan_for(executor: Executor) -> Vec<(Address, U256, Bytes)> {
        let multicall = abi::multicallCall {
            _calls: vec![abi::Call {
                target: OLD_NOTIFIER_ADMIN,
                value: U256::ZERO,
                data: change_admin_to(executor.proxy_admin),
            }],
            _requireSuccess: true,
        };
        let (factory, admin) = deploy(SALT, &admin_init());
        let (_, release) = deploy(SALT, &release_init());
        let (_, executor_deploy) = deploy(SALT, &executor_init_for(executor));
        let executor = landing(SALT, &executor_init_for(executor));
        vec![
            (CTM_PROXY_ADMIN, U256::ZERO, handover_to(GOVERNANCE)),
            (factory, U256::ZERO, admin),
            (factory, U256::ZERO, release),
            (factory, U256::ZERO, executor_deploy),
            (
                SUPPLIER,
                U256::ZERO,
                calldata(abi::publishEVMBytecodesCall {
                    _bytecodes: vec![Bytes::from_static(b"bytecode")],
                }),
            ),
            (CHAIN_ADMIN, U256::ZERO, calldata(multicall)),
            (NOTIFIER, U256::ZERO, handover_to(executor)),
        ]
    }

    fn calls(plan: Vec<(Address, U256, Bytes)>) -> Vec<PlanCall> {
        plan.into_iter()
            .enumerate()
            .map(|(i, (to, value, data))| PlanCall {
                index: i + 1,
                file: "01_test.safe.json".to_string(),
                tx: i + 1,
                to,
                value,
                data,
            })
            .collect()
    }

    fn verdict_of(plan: Vec<(Address, U256, Bytes)>) -> PlanVerdict {
        check_plan(&build(), &package(), &inputs(), &calls(plan))
    }

    fn refusal_of(plan: Vec<(Address, U256, Bytes)>) -> String {
        let verdict = verdict_of(plan);
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        verdict.refused[0].clone()
    }

    #[test]
    fn a_clean_plan_passes() {
        let verdict = verdict_of(clean_plan());
        assert!(verdict.refused.is_empty(), "{:#?}", verdict.refused);
        assert_eq!(verdict.admitted.len(), clean_plan().len());
        assert!(verdict.admitted[1].contains("recorded member deployment of AdminFacet"));
        assert!(verdict.admitted[2].contains("CTMRelease"));
        assert!(verdict.admitted[3].contains("CTMUpgradeExecutor"));
    }

    #[test]
    fn an_appended_eth_transfer_fails() {
        let mut plan = clean_plan();
        plan.push((
            STRANGER,
            U256::from(10u64).pow(U256::from(18u8)),
            Bytes::new(),
        ));
        let refusal = refusal_of(plan);
        assert!(
            refusal.contains("call 8 (01_test.safe.json tx 8)"),
            "{refusal}"
        );
        assert!(refusal.contains(&format!("target {STRANGER}")), "{refusal}");
        assert!(
            refusal.contains("selector none (empty calldata)"),
            "{refusal}"
        );
        assert!(
            refusal.contains("value 1000000000000000000 wei"),
            "{refusal}"
        );
        assert!(refusal.contains("the deployer sends no value"), "{refusal}");
    }

    #[test]
    fn a_zero_value_call_off_the_allowlist_fails() {
        let mut plan = clean_plan();
        plan.push((
            STRANGER,
            U256::ZERO,
            Bytes::from_static(&[0xde, 0xad, 0xbe, 0xef]),
        ));
        let refusal = refusal_of(plan);
        assert!(
            refusal.contains("selector 0xdeadbeef is not on the deployer allowlist"),
            "{refusal}"
        );
    }

    #[test]
    fn an_undeclared_salt_fails() {
        let mut plan = clean_plan();
        plan[1] = {
            let (to, data) = deploy(OTHER_SALT, &admin_init());
            (to, U256::ZERO, data)
        };
        let refusal = refusal_of(plan);
        assert!(
            refusal.contains(&format!("salt {OTHER_SALT}, which is not a declared salt")),
            "{refusal}"
        );
    }

    #[test]
    fn an_unrecorded_factory_deploy_fails() {
        let mut plan = clean_plan();
        let (to, data) = deploy(SALT, b"some other contract");
        plan.push((to, U256::ZERO, data));
        let refusal = refusal_of(plan);
        assert!(
            refusal
                .contains("neither a [member_deployments] record nor an executor, object or proxy"),
            "{refusal}"
        );
    }

    /// Changing the init code moves the CREATE2 address off the record; re-keying the record to
    /// the new address still fails, because the init code is not the reviewed creation code plus
    /// the recorded arguments.
    #[test]
    fn tampered_init_code_fails() {
        let mut tampered = admin_init();
        *tampered.last_mut().unwrap() ^= 1;
        let mut plan = clean_plan();
        plan[1] = {
            let (to, data) = deploy(SALT, &tampered);
            (to, U256::ZERO, data)
        };
        assert!(refusal_of(plan.clone()).contains("neither a [member_deployments] record"));

        let rekeyed = package_toml().replace(
            &landing(SALT, &admin_init()).to_string(),
            &landing(SALT, &tampered).to_string(),
        );
        let package = PackageView::from_toml(&toml::from_str(&rekeyed).unwrap(), "t").unwrap();
        let verdict = check_plan(&build(), &package, &inputs(), &calls(plan));
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        assert!(verdict.refused[0].contains("is not the reviewed creation code of AdminFacet"));
    }

    #[test]
    fn an_object_with_loosely_encoded_arguments_fails() {
        let mut plan = clean_plan();
        let init = [release_init(), vec![0u8; 32]].concat();
        let package = package_toml().replace(
            &landing(SALT, &release_init()).to_string(),
            &landing(SALT, &init).to_string(),
        );
        plan[2] = {
            let (to, data) = deploy(SALT, &init);
            (to, U256::ZERO, data)
        };
        let package = PackageView::from_toml(&toml::from_str(&package).unwrap(), "t").unwrap();
        let verdict = check_plan(&build(), &package, &inputs(), &calls(plan));
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        assert!(verdict.refused[0].contains("exact ABI encoding of its constructor arguments"));
    }

    #[test]
    fn an_executor_built_for_someone_else_fails() {
        let toml = package_toml().replace(
            &format!("initial_owner = \"{GOVERNANCE}\""),
            &format!("initial_owner = \"{STRANGER}\""),
        );
        let package = PackageView::from_toml(&toml::from_str(&toml).unwrap(), "t").unwrap();
        let verdict = check_plan(&build(), &package, &inputs(), &calls(clean_plan()));
        assert!(
            verdict
                .refused
                .iter()
                .any(|r| r.contains(&format!("for owner {STRANGER}, not for governance"))),
            "{:#?}",
            verdict.refused
        );
    }

    #[test]
    fn an_allowed_selector_on_the_wrong_target_fails() {
        let mut plan = clean_plan();
        plan.push((
            STRANGER,
            U256::ZERO,
            calldata(abi::publishEVMBytecodesCall { _bytecodes: vec![] }),
        ));
        let refusal = refusal_of(plan);
        assert!(
            refusal.contains(
                "publishEVMBytecodes(bytes[]) is admitted only on the CTM's BytecodesSupplier"
            ),
            "{refusal}"
        );
        assert!(
            refusal.contains(&format!("{STRANGER} is none of them")),
            "{refusal}"
        );

        let mut plan = clean_plan();
        plan.push((STRANGER, U256::ZERO, handover_to(GOVERNANCE)));
        let refusal = refusal_of(plan);
        assert!(
            refusal.contains("transferOwnership(address) is admitted only on"),
            "{refusal}"
        );
    }

    #[test]
    fn ownership_handed_to_anyone_but_governance_fails() {
        let mut plan = clean_plan();
        plan[0] = (CTM_PROXY_ADMIN, U256::ZERO, handover_to(STRANGER));
        let refusal = refusal_of(plan);
        assert!(
            refusal.contains(&format!("hands it to {STRANGER}, not to governance")),
            "{refusal}"
        );
    }

    /// The handover is admitted only as the declared admin action and only toward the executor
    /// the plan itself deploys.
    #[test]
    fn a_handover_must_be_declared_and_land_on_the_planned_executor() {
        let mut plan = clean_plan();
        let last = plan.len() - 1;
        plan[last] = (NOTIFIER, U256::ZERO, handover_to(STRANGER));
        assert!(refusal_of(plan).contains("not one of the package's declared admin actions"));

        let mut plan = clean_plan();
        plan.remove(3);
        let verdict = verdict_of(plan);
        assert!(
            verdict
                .refused
                .iter()
                .any(|r| r.contains("not a CTM executor this plan deploys")),
            "{:#?}",
            verdict.refused
        );

        let mut plan = clean_plan();
        let sneaky = abi::multicallCall {
            _calls: vec![abi::Call {
                target: CTM,
                value: U256::ZERO,
                data: handover_to(STRANGER),
            }],
            _requireSuccess: true,
        };
        plan[5] = (CHAIN_ADMIN, U256::ZERO, calldata(sneaky));
        assert!(refusal_of(plan).contains("its call 0 to"));
    }

    #[test]
    fn a_package_ctm_the_env_does_not_name_fails() {
        let mut inputs = inputs();
        inputs.env_ctms = Some([STRANGER].into());
        let verdict = check_plan(&build(), &package(), &inputs, &calls(clean_plan()));
        assert!(
            verdict.refused[0].contains(&format!(
                "the package's CTM {CTM} ([ctms.zksync_os.state_transition] \
                 chain_type_manager_proxy) is not one of the env's"
            )),
            "{:#?}",
            verdict.refused
        );
        // The executor for that CTM, and the handover to it, go with it.
        assert!(
            verdict
                .refused
                .iter()
                .any(|r| r.contains("deploys the CTM executor") && r.contains(&CTM.to_string())),
            "{:#?}",
            verdict.refused
        );
    }

    /// The executor record's `ctm_proxy_admin` is the bundle's: a ProxyAdmin the deployer owns
    /// named there would take the ServerNotifier (or any proxy) through the declared handover.
    /// The handover lands only on the ProxyAdmin that administers the executor's CTM on L1.
    #[test]
    fn a_handover_to_a_proxy_admin_l1_does_not_name_fails() {
        let foreign = Executor {
            ctm: CTM,
            proxy_admin: STRANGER,
        };
        let verdict = check_plan(
            &build(),
            &package_from(&package_toml_for(foreign)),
            &inputs(),
            &calls(clean_plan_for(foreign)),
        );
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        let refusal = &verdict.refused[0];
        assert!(refusal.starts_with("call 6 "), "{refusal}");
        assert!(
            refusal.contains(&format!(
                "moves {NOTIFIER} under {STRANGER}, which the planned CTM executor's record \
                 names, but the CTM {CTM} is administered by {CTM_PROXY_ADMIN} on L1"
            )),
            "{refusal}"
        );

        // Without the CTM's L1 facts nothing binds the record, so the handover is refused too.
        let mut unread = inputs();
        unread.ctm_facts.clear();
        let verdict = check_plan(&build(), &package(), &unread, &calls(clean_plan()));
        assert!(
            verdict
                .refused
                .iter()
                .any(|r| r.contains(&format!("no L1 facts were read for the CTM {CTM}"))),
            "{:#?}",
            verdict.refused
        );
    }

    #[test]
    fn an_executor_for_a_ctm_the_env_does_not_name_fails() {
        let elsewhere = Executor {
            ctm: STRANGER,
            proxy_admin: CTM_PROXY_ADMIN,
        };
        let verdict = check_plan(
            &build(),
            &package_from(&package_toml_for(elsewhere)),
            &inputs(),
            &calls(clean_plan_for(elsewhere)),
        );
        assert!(
            verdict.refused.iter().any(|r| r.contains(&format!(
                "for the CTM {STRANGER}, which is not one of the env's [[ctm_contracts.ctms]]"
            ))),
            "{:#?}",
            verdict.refused
        );
    }

    /// A CTM's roles count only in a `[ctms.<key>]` table that names its CTM; a table naming them
    /// without one is refused, and the supplier, ProxyAdmin and ValidatorTimelock are also held to
    /// L1.
    #[test]
    fn ctm_roles_come_only_from_a_ctm_table_and_agree_with_l1() {
        let orphan = format!(
            "{}\n[ctms.evil.state_transition]\nbytecodes_supplier_addr = \"{STRANGER}\"\n",
            package_toml()
        );
        let mut plan = clean_plan();
        plan.push((
            STRANGER,
            U256::ZERO,
            calldata(abi::publishEVMBytecodesCall { _bytecodes: vec![] }),
        ));
        let verdict = check_plan(&build(), &package_from(&orphan), &inputs(), &calls(plan));
        assert_eq!(verdict.refused.len(), 2, "{:#?}", verdict.refused);
        assert!(verdict.refused[0].contains(
            "[ctms.evil.state_transition] bytecodes_supplier_addr names the CTM's \
             BytecodesSupplier, but its table names no chain_type_manager_proxy"
        ));
        assert!(verdict.refused[1].contains(&format!("{STRANGER} is none of them")));

        // The ecosystem ProxyAdmin's key inside a CTM table grants no role.
        let misplaced = format!(
            "{}\n[ctms.zksync_os.upgrade_addresses.shared]\ntransparent_proxy_admin = \"{STRANGER}\"\n",
            package_toml()
        );
        let mut plan = clean_plan();
        plan.push((STRANGER, U256::ZERO, handover_to(GOVERNANCE)));
        let refusal = {
            let verdict = check_plan(&build(), &package_from(&misplaced), &inputs(), &calls(plan));
            assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
            verdict.refused[0].clone()
        };
        assert!(
            refusal.contains(&format!("{STRANGER} is none of them")),
            "{refusal}"
        );

        // L1 says the CTM reads bytecode elsewhere: the package's supplier is not it.
        let mut moved = inputs();
        moved.ctm_facts.insert(
            CTM,
            CtmFacts {
                bytecodes_supplier: STRANGER,
                ..live_ctm()
            },
        );
        let verdict = check_plan(&build(), &package(), &moved, &calls(clean_plan()));
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        assert!(verdict.refused[0].contains(&format!(
            "{SUPPLIER} is not the L1_BYTECODES_SUPPLIER() of the CTM {CTM} on L1, which is \
             {STRANGER}"
        )));

        // And it is administered by another ProxyAdmin: the ownership normalization of the
        // package's CTM ProxyAdmin is refused.
        let mut readmin = inputs();
        readmin.ctm_facts.insert(
            CTM,
            CtmFacts {
                proxy_admin: STRANGER,
                ..live_ctm()
            },
        );
        let verdict = check_plan(&build(), &package(), &readmin, &calls(clean_plan()));
        assert!(
            verdict.refused.iter().any(|r| r.starts_with("call 1 ")
                && r.contains(&format!(
                    "{CTM_PROXY_ADMIN} is not the EIP-1967 admin of the CTM {CTM} on L1"
                ))),
            "{:#?}",
            verdict.refused
        );

        // The ValidatorTimelock is handed to governance only while it is the CTM's on L1.
        let mut plan = clean_plan();
        plan.push((VALIDATOR_TIMELOCK, U256::ZERO, handover_to(GOVERNANCE)));
        let verdict = check_plan(&build(), &package(), &inputs(), &calls(plan.clone()));
        assert!(verdict.refused.is_empty(), "{:#?}", verdict.refused);
        let mut replaced = inputs();
        replaced.ctm_facts.insert(
            CTM,
            CtmFacts {
                validator_timelock: STRANGER,
                ..live_ctm()
            },
        );
        let verdict = check_plan(&build(), &package(), &replaced, &calls(plan));
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        assert!(
            verdict.refused[0].contains(&format!(
                "{VALIDATOR_TIMELOCK} is not the validatorTimelockPostV29() of the CTM {CTM} on \
                 L1, which is {STRANGER}"
            )),
            "{}",
            verdict.refused[0]
        );
    }

    /// The package's ecosystem ProxyAdmin is held to the EIP-1967 admin of the env's Bridgehub.
    #[test]
    fn the_ecosystem_proxy_admin_agrees_with_l1() {
        let named = format!(
            "{}\n[core.upgrade_addresses.shared]\ntransparent_proxy_admin = \"{ECOSYSTEM_PROXY_ADMIN}\"\n",
            package_toml()
        );
        let mut plan = clean_plan();
        plan.push((ECOSYSTEM_PROXY_ADMIN, U256::ZERO, handover_to(GOVERNANCE)));
        let verdict = check_plan(
            &build(),
            &package_from(&named),
            &inputs(),
            &calls(plan.clone()),
        );
        assert!(verdict.refused.is_empty(), "{:#?}", verdict.refused);
        assert!(verdict
            .admitted
            .last()
            .unwrap()
            .contains("on the ecosystem ProxyAdmin ([core.upgrade_addresses.shared]"));

        let mut moved = inputs();
        moved.ecosystem_proxy_admin = Some(STRANGER);
        let verdict = check_plan(
            &build(),
            &package_from(&named),
            &moved,
            &calls(plan.clone()),
        );
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        assert!(
            verdict.refused[0].contains(&format!(
                "{ECOSYSTEM_PROXY_ADMIN} is not the EIP-1967 admin of the Bridgehub on L1, which \
                 is {STRANGER}"
            )),
            "{}",
            verdict.refused[0]
        );

        // Without an env, a package naming no Bridgehub has nothing to hold its admin to.
        let mut unknown = inputs();
        unknown.ecosystem_proxy_admin = None;
        let verdict = check_plan(&build(), &package_from(&named), &unknown, &calls(plan));
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        assert!(
            verdict.refused[0].contains("the package names no [core.upgrade_addresses.bridgehub]"),
            "{}",
            verdict.refused[0]
        );
    }

    /// A proxy the package names, in front of a recorded implementation, is admitted under the
    /// ecosystem ProxyAdmin only while that is the Bridgehub's admin on L1.
    #[test]
    fn a_proxy_under_the_ecosystem_proxy_admin_agrees_with_l1() {
        let logic = landing(SALT, &admin_init());
        let init = [
            creation(REVIEWED_PROXY.1),
            (logic, ECOSYSTEM_PROXY_ADMIN, Bytes::new()).abi_encode_params(),
        ]
        .concat();
        let named = format!(
            "{}\n[core.upgrade_addresses.shared]\ntransparent_proxy_admin = \"{ECOSYSTEM_PROXY_ADMIN}\"\n\n\
             [core.deployed_addresses]\nproxy_addr = \"{}\"\n",
            package_toml(),
            landing(SALT, &init)
        );
        let mut plan = clean_plan();
        plan.push((
            DETERMINISTIC_CREATE2_FACTORY,
            U256::ZERO,
            deploy(SALT, &init).1,
        ));
        let verdict = check_plan(
            &build(),
            &package_from(&named),
            &inputs(),
            &calls(plan.clone()),
        );
        assert!(verdict.refused.is_empty(), "{:#?}", verdict.refused);
        assert!(verdict.admitted.last().unwrap().contains(&format!(
            "a TransparentUpgradeableProxy in front of the recorded implementation {logic}"
        )));

        let mut moved = inputs();
        moved.ecosystem_proxy_admin = Some(STRANGER);
        let verdict = check_plan(&build(), &package_from(&named), &moved, &calls(plan));
        assert_eq!(verdict.refused.len(), 1, "{:#?}", verdict.refused);
        assert!(
            verdict.refused[0].contains(&format!(
                "its admin {ECOSYSTEM_PROXY_ADMIN} is neither the ecosystem ProxyAdmin nor the \
                 ProxyAdmin of one of its CTMs on L1"
            )),
            "{}",
            verdict.refused[0]
        );
    }

    #[test]
    fn a_plan_the_deployer_signs_nothing_of_needs_no_check() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("manifest.json"),
            format!(
                r#"{{"bundles":[{{"index":1,"file":"01.safe.json","target":"{GOVERNANCE}"}}]}}"#
            ),
        )
        .unwrap();
        assert!(plan_to_check(&dir.path().join("manifest.json"), DEPLOYER)
            .unwrap()
            .is_none());
    }

    #[test]
    fn the_env_must_be_on_the_bundles_chain() {
        assert_eq!(ensure_env_chain(Some(1), Some(1)).unwrap(), 1);
        for (env, bundle) in [(Some(11155111), Some(1)), (None, None), (Some(1), None)] {
            let error = ensure_env_chain(env, bundle).unwrap_err().to_string();
            assert!(error.contains("signed for another"), "{error}");
        }
    }

    /// Signing needs the generation commit, its contract sources and reviewed inputs unchanged,
    /// and a bundle generated from a clean worktree.
    #[test]
    fn signing_requires_the_clean_generation_checkout() {
        use crate::commands::ecosystem::bundle::{L1Provenance, Toolchain};
        let repo = tempfile::tempdir().unwrap();
        let git = |args: &[&str]| {
            let output = Command::new("git")
                .args(args)
                .current_dir(repo.path())
                .output()
                .unwrap();
            assert!(output.status.success(), "git {args:?}");
            String::from_utf8(output.stdout).unwrap().trim().to_string()
        };
        let source = repo.path().join("protocol-ops/src/allowlist.rs");
        std::fs::create_dir_all(source.parent().unwrap()).unwrap();
        std::fs::write(&source, "reviewed\n").unwrap();
        git(&["init", "-q"]);
        git(&["add", "."]);
        git(&[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "fixture",
        ]);
        let mut metadata = DeployBundleMetadata {
            schema: String::new(),
            upgrade: DEFAULT_UPGRADE.to_string(),
            env: "stage".to_string(),
            contracts_commit: git(&["rev-parse", "HEAD"]),
            contracts_worktree_dirty: false,
            all_contracts_hashes_sha256: String::new(),
            l1: L1Provenance {
                chain_id: Some(11155111),
                forked_at_block: None,
            },
            deployer_address: Some(DEPLOYER),
            zk_governance_commit: None,
            toolchain: Toolchain {
                forge: String::new(),
                rustc: String::new(),
                foundry_zksync: None,
            },
            generated_by: None,
            files: BTreeMap::new(),
        };
        require_checkout_at(repo.path(), &metadata).unwrap();

        std::fs::write(&source, "edited after review\n").unwrap();
        let error = require_checkout_at(repo.path(), &metadata)
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("contract sources or reviewed inputs differ"),
            "{error}"
        );
        assert!(error.contains("protocol-ops/src/allowlist.rs"), "{error}");
        std::fs::write(&source, "reviewed\n").unwrap();

        metadata.contracts_worktree_dirty = true;
        let error = require_checkout_at(repo.path(), &metadata)
            .unwrap_err()
            .to_string();
        assert!(error.contains("contracts_worktree_dirty"), "{error}");

        metadata.contracts_worktree_dirty = false;
        metadata.contracts_commit = "0".repeat(40);
        let error = require_checkout_at(repo.path(), &metadata)
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("but the bundle was generated from"),
            "{error}"
        );
    }

    /// The CTM facts are the CTM proxy's EIP-1967 admin slot, its `L1_BYTECODES_SUPPLIER()` and its
    /// `validatorTimelockPostV29()`.
    #[tokio::test]
    async fn ctm_facts_are_read_from_the_admin_slot_and_the_ctm_getters() {
        use alloy::providers::ProviderBuilder;
        use alloy::transports::mock::Asserter;
        let asserter = Asserter::new();
        asserter.push_success(&CTM_PROXY_ADMIN.into_word());
        asserter.push_success(&Bytes::from(SUPPLIER.abi_encode()));
        asserter.push_success(&Bytes::from(VALIDATOR_TIMELOCK.abi_encode()));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter);
        let facts = read_ctm_facts(&provider, &[CTM].into()).await.unwrap();
        assert_eq!(facts, [(CTM, live_ctm())].into());
    }

    #[test]
    fn every_allowlist_selector_is_its_signature() {
        for entry in ALLOWLIST {
            assert_eq!(
                entry.selector,
                keccak256(entry.signature.as_bytes())[..4],
                "{}",
                entry.signature
            );
        }
    }

    #[test]
    fn deployer_calls_are_read_in_manifest_order_and_skip_other_signers() {
        let dir = tempfile::tempdir().unwrap();
        let safe = |txs: &str| format!(r#"{{"version":"1.0","transactions":[{txs}]}}"#);
        let tx = |to: Address, value: &str| {
            format!(r#"{{"to":"{to}","value":"{value}","data":"0x01","contractMethod":null}}"#)
        };
        std::fs::write(dir.path().join("02.safe.json"), safe(&tx(SUPPLIER, "0"))).unwrap();
        std::fs::write(dir.path().join("03.safe.json"), safe(&tx(STRANGER, "0"))).unwrap();
        std::fs::write(
            dir.path().join("01.safe.json"),
            safe(&[tx(CTM, "0"), tx(STRANGER, "0x10")].join(",")),
        )
        .unwrap();
        std::fs::write(
            dir.path().join("manifest.json"),
            format!(
                r#"{{"bundles":[
                    {{"index":2,"file":"02.safe.json","target":"{DEPLOYER}"}},
                    {{"index":3,"file":"03.safe.json","target":"{GOVERNANCE}"}},
                    {{"index":1,"file":"01.safe.json","target":"{DEPLOYER}"}}]}}"#
            ),
        )
        .unwrap();
        let (calls, others) = deployer_calls(&dir.path().join("manifest.json"), DEPLOYER).unwrap();
        assert_eq!(others, 1);
        let shape: Vec<_> = calls
            .iter()
            .map(|c| (c.index, c.file.as_str(), c.tx, c.to, c.value))
            .collect();
        assert_eq!(
            shape,
            [
                (1, "01.safe.json", 1, CTM, U256::ZERO),
                (2, "01.safe.json", 2, STRANGER, U256::from(16)),
                (3, "02.safe.json", 1, SUPPLIER, U256::ZERO),
            ]
        );
    }

    #[test]
    fn a_broadcast_requires_the_generation_commit() {
        ensure_same_commit("abc", "abc").unwrap();
        let error = ensure_same_commit("abc", "def").unwrap_err().to_string();
        assert!(error.contains("this checkout is at abc"), "{error}");
        assert!(error.contains("generated from def"), "{error}");
    }

    /// The envs a deploy bundle is generated for declare every input the check holds a plan to:
    /// the deterministic factory, the governance owner, a core salt and a salt for each CTM the
    /// prepare drives (without one the CTM prepare draws a random salt, which the check refuses).
    #[test]
    fn every_deployed_env_declares_the_reviewed_inputs() {
        for env in ["stage", "testnet", "mainnet"] {
            let cfg = match EnvConfig::load(env) {
                Ok(cfg) => cfg,
                // no checkout around the test binary
                Err(_) if crate::common::paths::resolve_l1_contracts_path().is_err() => return,
                Err(e) => panic!("{env}: {e:#}"),
            };
            let inputs = env_inputs(&cfg).unwrap();
            validate_inputs(&inputs).unwrap();
            assert!(
                cfg.create2_factory_salt_for_upgrade().unwrap().is_some(),
                "{env}"
            );
            let per_ctm = cfg.create2_factory_salt_for_upgrade_per_ctm().unwrap();
            for ctm in inputs.env_ctms.unwrap() {
                assert!(per_ctm.contains_key(&ctm), "{env}: no salt for CTM {ctm}");
            }
        }
    }

    /// The PUH/Guardians redeploy deploys under a salt and from artifacts the check does not know.
    #[test]
    fn a_release_redeploying_the_governance_set_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("stage.toml"),
            "redeploy_zk_governance = true\n",
        )
        .unwrap();
        let cfg = match EnvConfig::load_from_upgrade_env_dir("stage", dir.path().to_str().unwrap())
        {
            Ok(cfg) => cfg,
            // no checkout around the test binary
            Err(_) if crate::common::paths::resolve_l1_contracts_path().is_err() => return,
            Err(e) => panic!("{e:#}"),
        };
        let error = env_inputs(&cfg).unwrap_err().to_string();
        assert!(
            error.contains("declares `redeploy_zk_governance = true`, but the deployer plan check"),
            "{error}"
        );
    }

    #[test]
    fn missing_reviewed_inputs_are_refused() {
        let mut no_salt = inputs();
        no_salt.salts.clear();
        assert!(validate_inputs(&no_salt).is_err());
        let mut other_factory = inputs();
        other_factory.factory = STRANGER;
        assert!(validate_inputs(&other_factory).is_err());
        validate_inputs(&inputs()).unwrap();
    }
}
