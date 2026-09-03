//! The v31 **deploy bundle**: the deployer calls a generation run computed on a fork,
//! packed with the provenance needed to broadcast and re-verify them elsewhere.
//!
//! Solidity output is not byte-stable across build environments, so the CREATE2 init
//! code inside `prepare/*.safe.json` — and with it every address and all governance
//! calldata — belongs to the machine that compiled it. The bundle is what transfers:
//! whoever broadcasts it deploys that exact bytecode. `bundle-metadata.json` records
//! where it came from and the SHA-256 of every other file, so a consumer can check it.
//!
//! Three commands:
//! - `rehearse-upgrade` (GENERATE): fork L1, `upgrade-prepare-all`, pack the bundle,
//!   replay every bundle under impersonation and run PUVT.
//! - `replay-bundle` (CONSUME): rehearse a packed bundle on a fresh fork, broadcast the
//!   deployer's bundles for real, or only run PUVT against an already-upgraded chain.
//! - `verify-bundle`: the integrity check on its own.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use alloy::primitives::{Address, Bytes, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::commands::ecosystem::broadcast::{self, UpgradeBroadcastArgs};
use crate::commands::ecosystem::upgrade::{self, UpgradePrepareAllArgs};
use crate::commands::ecosystem::verify_upgrade::{self, VerifyUpgradeArgs};
use crate::common::anvil::{send_impersonated_tx, set_balance};
use crate::common::env_config::{default_protocol_ops_out_dir, EnvConfig};
use crate::common::ethereum::get_provider;
use crate::common::private_key::pk_to_address;
use crate::common::{logger, paths};

// ─── Constants ───────────────────────────────────────────────────────────────────

pub const DEPLOY_BUNDLE_SCHEMA: &str = "zksync-ecosystem-upgrade-deploy-bundle/1";
const V31_UPGRADE_NAME: &str = "v0.31.0-interopB";
pub const BUNDLE_METADATA_FILE: &str = "bundle-metadata.json";
const MANIFEST_FILE: &str = "prepare/manifest.json";
/// Generation outputs a bundle must carry, besides the `prepare/*.safe.json` files the manifest names.
const REQUIRED_BUNDLE_FILES: [&str; 2] = [MANIFEST_FILE, "ecosystem.toml"];
/// Etherscan verification command logs; `gw-verification-logs.txt` only exists on gateway-enabled envs.
const OPTIONAL_BUNDLE_FILES: [&str; 2] =
    ["extra-verification-logs.txt", "gw-verification-logs.txt"];
/// The per-env real-network broadcast log, committed under `output/<env>/` and read by PUVT.
const TRANSACTIONS_LOG: &str = "transactions.txt";
const COMBINED_TRANSACTIONS_LOG: &str = "transactions.combined.txt";

/// Only stage brings up a gateway, so its RPC is the default for PUVT's gateway-side checks.
const DEFAULT_GATEWAY_RPC_URL: &str = "https://zksync-os-stage-gateway.zksync.dev";
/// The reviewed zk-governance commit for v31 (same default as the generate workflow input).
const DEFAULT_ZK_GOVERNANCE_COMMIT: &str = "9b06a16159cd58add109f25598e79731450d1772";

/// Anvil port of each env's generate fork; a replay of the same env uses port + 1, so a
/// replay can run next to a rehearsal of the same env.
const ENV_ANVIL_PORTS: [(&str, u16); 3] =
    [("stage", 29_545), ("testnet", 29_547), ("mainnet", 29_549)];
const REPLAY_PORT_OFFSET: u16 = 1;
const ANVIL_GAS_PRICE_WEI: u64 = 1_000_000_000;
const ANVIL_STARTUP_TIMEOUT_MS: u64 = 60_000;
const FORGE_MEMORY_LIMIT: &str = "--additional-args=--memory-limit=536870912";
const FUNDING_TX_GAS_LIMIT: u64 = 500_000;

/// Tracked paths whose modification changes the bytecode or calldata a generation run
/// produces. `contracts_worktree_dirty` is scoped to these, so the generated files the run
/// itself rewrites (`output/<env>/`, `zkstack-out/`) do not count.
const CONTRACT_SOURCE_PATHSPECS: [&str; 12] = [
    "*/foundry.toml",
    "AllContractsHashes.json",
    "SystemConfig.json",
    "configs/genesis",
    "da-contracts/contracts",
    "l1-contracts/contracts",
    "l1-contracts/deploy-scripts",
    "l1-contracts/upgrade-envs/permanent-values",
    "l1-contracts/upgrade-envs/v0.31.0-interopB/*.toml",
    "l2-contracts/contracts",
    "protocol-ops/src",
    "system-contracts/contracts",
];

alloy::sol! {
    #[sol(rpc)]
    contract IBridgehub {
        function assetRouter() external view returns (address);
    }
    #[sol(rpc)]
    contract IL1AssetRouter {
        function nativeTokenVault() external view returns (address);
    }
    #[sol(rpc)]
    contract INativeTokenVault {
        function tokenAddress(bytes32 assetId) external view returns (address);
    }
    contract IBridgedStandardERC20 {
        function bridgeMint(address account, uint256 amount) external;
    }
    contract IL1AssetTracker {
        function registerLegacyToken(bytes32 assetId) external;
    }
}

// ─── Bundle metadata ─────────────────────────────────────────────────────────────

/// `bundle-metadata.json`: provenance plus the digest of every other file in the bundle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeployBundleMetadata {
    pub schema: String,
    pub upgrade: String,
    pub env: String,
    pub contracts_commit: String,
    pub contracts_worktree_dirty: bool,
    pub all_contracts_hashes_sha256: String,
    pub l1: L1Provenance,
    pub deployer_address: Option<Address>,
    pub zk_governance_commit: Option<String>,
    pub toolchain: Toolchain,
    pub generated_by: Option<GeneratedBy>,
    /// Bundle-relative POSIX path → SHA-256, for every file except this one.
    pub files: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct L1Provenance {
    pub chain_id: Option<u64>,
    /// The L1 height the bundles were computed against; replays fork there.
    pub forked_at_block: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Toolchain {
    pub forge: String,
    pub rustc: String,
    pub foundry_zksync: Option<String>,
}

/// The GitHub Actions run that packed the bundle; absent when packed by hand.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeneratedBy {
    pub workflow_run: String,
    pub runner_os: Option<String>,
}

/// `prepare/manifest.json` as `upgrade-prepare-all` writes it, as far as the bundle needs it.
#[derive(Debug, Deserialize)]
struct BundleManifest {
    bundles: Vec<ManifestBundle>,
}

#[derive(Debug, Deserialize)]
struct ManifestBundle {
    file: String,
    target: Address,
}

/// Facts about the generation run that the bundle records but cannot derive from its files.
#[derive(Debug, Default, Clone)]
pub struct BundleProvenance {
    pub deployer: Option<Address>,
    pub forked_at_block: Option<u64>,
    pub zk_governance_commit: Option<String>,
    pub foundry_zksync_version: Option<String>,
}

fn sha256_file(path: &Path) -> anyhow::Result<String> {
    let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn read_manifest(path: &Path) -> anyhow::Result<BundleManifest> {
    let manifest: BundleManifest = crate::common::files::read_json_file(path)?;
    anyhow::ensure!(
        !manifest.bundles.is_empty(),
        "{} lists no bundles",
        path.display()
    );
    for bundle in &manifest.bundles {
        anyhow::ensure!(
            Path::new(&bundle.file)
                .file_name()
                .map(|n| n == bundle.file.as_str())
                == Some(true),
            "{}: bundle file {:?} is not a bare file name",
            path.display(),
            bundle.file
        );
    }
    Ok(manifest)
}

fn stays_inside_bundle(relative: &str) -> bool {
    !relative.is_empty()
        && !Path::new(relative).is_absolute()
        && !relative.split('/').any(|segment| segment == "..")
}

/// Trimmed stdout of a command, or `None` when it cannot run or exits non-zero.
fn try_capture(command: &str, args: &[&str], cwd: &Path) -> Option<String> {
    let output = Command::new(command)
        .args(args)
        .current_dir(cwd)
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn github_run_provenance() -> Option<GeneratedBy> {
    let server = std::env::var("GITHUB_SERVER_URL").ok()?;
    let repository = std::env::var("GITHUB_REPOSITORY").ok()?;
    let run_id = std::env::var("GITHUB_RUN_ID").ok()?;
    Some(GeneratedBy {
        workflow_run: format!("{server}/{repository}/actions/runs/{run_id}"),
        runner_os: std::env::var("RUNNER_OS").ok(),
    })
}

/// Every regular file below `directory`, as directory-relative POSIX paths.
fn list_files(directory: &Path, prefix: &str, out: &mut Vec<String>) -> anyhow::Result<()> {
    for entry in fs::read_dir(directory).with_context(|| format!("list {}", directory.display()))? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if entry.file_type()?.is_dir() {
            list_files(&entry.path(), &format!("{prefix}{name}/"), out)?;
        } else {
            out.push(format!("{prefix}{name}"));
        }
    }
    Ok(())
}

/// Copy a generation run's deployer calls, `ecosystem.toml` and verification logs from
/// `output_dir` into `bundle_dir` and write `bundle-metadata.json` next to them.
pub fn pack_deploy_bundle(
    env_cfg: &EnvConfig,
    output_dir: &Path,
    bundle_dir: &Path,
    repository_root: &Path,
    provenance: &BundleProvenance,
) -> anyhow::Result<DeployBundleMetadata> {
    for relative in REQUIRED_BUNDLE_FILES {
        let path = output_dir.join(relative);
        anyhow::ensure!(
            path.is_file(),
            "generation output not found: {}",
            path.display()
        );
    }
    let manifest = read_manifest(&output_dir.join(MANIFEST_FILE))?;

    if bundle_dir.exists() {
        fs::remove_dir_all(bundle_dir)
            .with_context(|| format!("clear {}", bundle_dir.display()))?;
    }
    fs::create_dir_all(bundle_dir.join("prepare"))?;
    let bundle_files = manifest
        .bundles
        .iter()
        .map(|bundle| format!("prepare/{}", bundle.file));
    for relative in REQUIRED_BUNDLE_FILES
        .into_iter()
        .map(str::to_string)
        .chain(bundle_files)
    {
        fs::copy(output_dir.join(&relative), bundle_dir.join(&relative))
            .with_context(|| format!("copy {relative} into the bundle"))?;
    }
    for relative in OPTIONAL_BUNDLE_FILES {
        let source = output_dir.join(relative);
        if source.is_file() && fs::metadata(&source)?.len() > 0 {
            fs::copy(&source, bundle_dir.join(relative))
                .with_context(|| format!("copy {relative}"))?;
        }
    }

    let mut relative_paths = Vec::new();
    list_files(bundle_dir, "", &mut relative_paths)?;
    relative_paths.sort();
    let files = relative_paths
        .iter()
        .map(|relative| Ok((relative.clone(), sha256_file(&bundle_dir.join(relative))?)))
        .collect::<anyhow::Result<BTreeMap<_, _>>>()?;

    let source_status = try_capture(
        "git",
        &[
            &["status", "--porcelain", "--"][..],
            &CONTRACT_SOURCE_PATHSPECS[..],
        ]
        .concat(),
        repository_root,
    );
    let metadata = DeployBundleMetadata {
        schema: DEPLOY_BUNDLE_SCHEMA.to_string(),
        upgrade: V31_UPGRADE_NAME.to_string(),
        env: env_cfg.env.clone(),
        contracts_commit: try_capture("git", &["rev-parse", "HEAD"], repository_root)
            .unwrap_or_else(|| "unknown".to_string()),
        contracts_worktree_dirty: source_status
            .as_deref()
            .is_none_or(|status| !status.is_empty()),
        all_contracts_hashes_sha256: sha256_file(&repository_root.join("AllContractsHashes.json"))?,
        l1: L1Provenance {
            chain_id: env_cfg.l1_chain_id(),
            forked_at_block: provenance.forked_at_block,
        },
        deployer_address: provenance.deployer,
        zk_governance_commit: provenance.zk_governance_commit.clone(),
        toolchain: Toolchain {
            forge: try_capture("forge", &["--version"], repository_root)
                .and_then(|out| out.lines().next().map(str::to_string))
                .unwrap_or_else(|| "unknown".to_string()),
            rustc: try_capture("rustc", &["--version"], repository_root)
                .unwrap_or_else(|| "unknown".to_string()),
            foundry_zksync: provenance.foundry_zksync_version.clone(),
        },
        generated_by: github_run_provenance(),
        files,
    };
    let json = serde_json::to_string_pretty(&metadata)? + "\n";
    fs::write(bundle_dir.join(BUNDLE_METADATA_FILE), json).context("write bundle-metadata.json")?;

    verify_bundle_integrity(bundle_dir)?;
    logger::success(format!("Deploy bundle packed: {}", bundle_dir.display()));
    Ok(metadata)
}

/// Check a deploy bundle against its own metadata: every listed file must be present with
/// the recorded SHA-256, the manifest and `ecosystem.toml` must be among them, and every
/// bundle file the manifest names must be covered. The metadata is the root of trust; the
/// (digest-protected) manifest is the source of truth for what gets broadcast.
pub fn verify_bundle_integrity(bundle_dir: &Path) -> anyhow::Result<DeployBundleMetadata> {
    let fail = |message: String| anyhow::anyhow!("deploy bundle integrity check failed: {message}");
    let metadata_path = bundle_dir.join(BUNDLE_METADATA_FILE);
    let metadata: DeployBundleMetadata = crate::common::files::read_json_file(&metadata_path)
        .map_err(|error| fail(format!("{error:#}")))?;
    if metadata.schema != DEPLOY_BUNDLE_SCHEMA {
        return Err(fail(format!("unsupported schema {:?}", metadata.schema)));
    }
    for required in REQUIRED_BUNDLE_FILES {
        if !metadata.files.contains_key(required) {
            return Err(fail(format!("metadata.files does not include {required}")));
        }
    }
    for (relative, expected) in &metadata.files {
        if !stays_inside_bundle(relative) {
            return Err(fail(format!(
                "{relative}: path must stay inside the bundle"
            )));
        }
        let path = bundle_dir.join(relative);
        if !path.is_file() {
            return Err(fail(format!(
                "{relative} is listed in the metadata but missing"
            )));
        }
        let actual = sha256_file(&path)?;
        if &actual != expected {
            return Err(fail(format!(
                "SHA-256 mismatch for {relative}: expected {expected}, got {actual}"
            )));
        }
    }
    let manifest = read_manifest(&bundle_dir.join(MANIFEST_FILE))
        .map_err(|error| fail(format!("{error:#}")))?;
    for bundle in &manifest.bundles {
        let relative = format!("prepare/{}", bundle.file);
        if !metadata.files.contains_key(&relative) {
            return Err(fail(format!(
                "{relative} is in the manifest but not in the metadata"
            )));
        }
    }
    logger::info(format!(
        "Deploy bundle integrity: OK ({} bundle(s), {} file(s))",
        manifest.bundles.len(),
        metadata.files.len()
    ));
    Ok(metadata)
}

// ─── Fork helpers ────────────────────────────────────────────────────────────────

fn anvil_port(env: &str) -> anyhow::Result<u16> {
    ENV_ANVIL_PORTS
        .iter()
        .find(|(name, _)| *name == env)
        .map(|(_, port)| *port)
        .ok_or_else(|| {
            anyhow::anyhow!("no anvil port assigned to env '{env}'; add one to ENV_ANVIL_PORTS")
        })
}

/// Start an anvil fork of `fork_url` on `port`, pinned to `fork_block` when given, with every
/// account impersonatable. The fork is stopped when the returned instance is dropped.
fn start_fork(
    port: u16,
    fork_url: &str,
    fork_block: Option<u64>,
) -> anyhow::Result<alloy::node_bindings::AnvilInstance> {
    let mut anvil = alloy::node_bindings::Anvil::new()
        .port(port)
        .fork(fork_url)
        .arg("--auto-impersonate")
        .arg("--disable-block-gas-limit")
        .arg("--gas-price")
        .arg(ANVIL_GAS_PRICE_WEI.to_string())
        .timeout(ANVIL_STARTUP_TIMEOUT_MS);
    if let Some(block) = fork_block {
        anvil = anvil.fork_block_number(block);
    }
    anvil.try_spawn().with_context(|| {
        format!("spawn anvil fork on port {port} (is the port free and anvil installed?)")
    })
}

/// Pin the next block's base fee to the gas price the bundles were priced at, so the
/// EIP-1559 escalation cannot make priority deposits fail with `MsgValueTooLow`.
async fn pin_base_fee(rpc_url: &str) -> anyhow::Result<()> {
    get_provider(rpc_url)?
        .raw_request::<_, serde_json::Value>(
            "anvil_setNextBlockBaseFeePerGas".into(),
            serde_json::json!([format!("{ANVIL_GAS_PRICE_WEI:#x}")]),
        )
        .await
        .context("anvil_setNextBlockBaseFeePerGas")?;
    Ok(())
}

/// Give every bundle signer ETH for gas and ZK for base-token burns, and pre-register the
/// ZK asset id so the gateway priority deposits in the bundles pass `_requireRegistered`
/// (in production that registration is a governance stage-2 call, which replays later).
/// Fork only: every call is impersonated.
async fn fund_bundle_targets(
    rpc_url: &str,
    env_cfg: &EnvConfig,
    deployer: Address,
    manifest_path: &Path,
    ecosystem_toml_path: &Path,
) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    let asset_router = IBridgehub::new(env_cfg.bridgehub(), provider.clone())
        .assetRouter()
        .call()
        .await
        .context("Bridgehub.assetRouter()")?;
    let native_token_vault = IL1AssetRouter::new(asset_router, provider.clone())
        .nativeTokenVault()
        .call()
        .await
        .context("L1AssetRouter.nativeTokenVault()")?;
    let zk_asset_id = env_cfg.zk_token_asset_id().ok_or_else(|| {
        anyhow::anyhow!(
            "{} has no zk_token_asset_id",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let zk_token = INativeTokenVault::new(native_token_vault, provider.clone())
        .tokenAddress(zk_asset_id)
        .call()
        .await
        .context("NativeTokenVault.tokenAddress(zk)")?;
    logger::info(format!(
        "Asset router {asset_router:#x} | NTV {native_token_vault:#x} | ZK token {zk_token:#x}"
    ));
    set_balance(rpc_url, native_token_vault).await?;

    let manifest = read_manifest(manifest_path)?;
    let targets: BTreeSet<Address> = manifest
        .bundles
        .iter()
        .map(|bundle| bundle.target)
        .collect();
    // Gateway-enabled envs burn ZK (the new gateway's base token) in a priority tx, so the
    // mint must succeed there; elsewhere the ZK token is L1-native and the NTV cannot mint it,
    // which is fine because nothing burns it.
    let has_gateway = env_cfg.new_gateway().is_some();
    let zk_funding = U256::from(10u8).pow(U256::from(30u8));
    for target in &targets {
        set_balance(rpc_url, *target).await?;
        let mint = IBridgedStandardERC20::bridgeMintCall {
            account: *target,
            amount: zk_funding,
        }
        .abi_encode();
        logger::info(format!(
            "  bridgeMint({target:#x}){}",
            if has_gateway { "" } else { " [best-effort]" }
        ));
        let minted = send_impersonated_tx(
            rpc_url,
            native_token_vault,
            zk_token,
            Bytes::from(mint),
            FUNDING_TX_GAS_LIMIT,
        )
        .await;
        if has_gateway {
            minted.context("ZK funding is required on a gateway-enabled env")?;
        }
    }

    let ecosystem: toml::Value = crate::common::files::read_toml_file(ecosystem_toml_path)?;
    let Some(asset_tracker) = ecosystem
        .get("asset_tracker_proxy_addr")
        .and_then(toml::Value::as_str)
        .and_then(|value| value.parse::<Address>().ok())
    else {
        logger::warn(format!(
            "asset_tracker_proxy_addr not found in {} — skipping registerLegacyToken",
            ecosystem_toml_path.display()
        ));
        return Ok(());
    };
    logger::info(format!(
        "  registerLegacyToken({zk_asset_id:#x}) on {asset_tracker:#x}"
    ));
    let register = IL1AssetTracker::registerLegacyTokenCall {
        assetId: zk_asset_id,
    }
    .abi_encode();
    // Already registered on this fork is fine.
    let _ = send_impersonated_tx(
        rpc_url,
        deployer,
        asset_tracker,
        Bytes::from(register),
        FUNDING_TX_GAS_LIMIT,
    )
    .await;
    Ok(())
}

/// Where a run reads the manifest and `ecosystem.toml`, and where it writes its own state.
struct BundlePaths {
    manifest: PathBuf,
    ecosystem_toml: PathBuf,
    work_dir: PathBuf,
}

/// Replay the whole manifest under impersonation (fork only).
async fn broadcast_impersonated(rpc_url: &str, paths: &BundlePaths) -> anyhow::Result<()> {
    logger::step("upgrade-broadcast (impersonated)");
    fs::create_dir_all(&paths.work_dir)?;
    pin_base_fee(rpc_url).await?;
    let args = [
        "upgrade-broadcast".to_string(),
        "--manifest".into(),
        paths.manifest.display().to_string(),
        "--l1-rpc-url".into(),
        rpc_url.to_string(),
        "--unlocked".into(),
        "--out".into(),
        paths.work_dir.join("executed.json").display().to_string(),
    ];
    broadcast::run(UpgradeBroadcastArgs::try_parse_from(args)?).await
}

/// Run PUVT against `rpc_url`. It resolves CREATE2 deployments from transaction hashes, so
/// the committed real-network log and this run's own log are fed to it together.
async fn verify_upgrade(
    env_cfg: &EnvConfig,
    rpc_url: &str,
    gateway_rpc_url: &str,
    zk_governance_commit: &str,
    paths: &BundlePaths,
) -> anyhow::Result<()> {
    logger::step("verify-upgrade (PUVT)");
    let mut combined = Vec::new();
    for log in [
        default_protocol_ops_out_dir(&env_cfg.env)?.join(TRANSACTIONS_LOG),
        paths.work_dir.join(TRANSACTIONS_LOG),
    ] {
        if log.is_file() {
            combined.extend(fs::read(&log)?);
        }
    }
    fs::create_dir_all(&paths.work_dir)?;
    let combined_path = paths.work_dir.join(COMBINED_TRANSACTIONS_LOG);
    fs::write(&combined_path, combined)?;
    let args = [
        "verify-upgrade".to_string(),
        "--env".into(),
        env_cfg.env.clone(),
        "--ecosystem-toml".into(),
        paths.ecosystem_toml.display().to_string(),
        "--l1-rpc-url".into(),
        rpc_url.to_string(),
        "--gw-rpc-url".into(),
        gateway_rpc_url.to_string(),
        "--transactions-log".into(),
        combined_path.display().to_string(),
        "--zk-governance-commit".into(),
        zk_governance_commit.to_string(),
    ];
    verify_upgrade::run(VerifyUpgradeArgs::try_parse_from(args)?).await
}

// ─── rehearse-upgrade ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Parser)]
pub struct RehearseUpgradeArgs {
    /// Environment: basename of the config pair `permanent-values/<env>.toml` + `v0.31.0-interopB/<env>.toml`.
    #[clap(long)]
    pub env: String,
    /// L1 RPC to fork. Nothing is signed and nothing touches this chain.
    #[clap(long)]
    pub fork_url: String,
    /// The EOA whose bundles are the deployer's. Impersonated on the fork; it is also baked
    /// into the init code of some deployments, so whoever broadcasts must be this account.
    #[clap(long)]
    pub deployer_address: Address,
    /// Pin the fork to this L1 height (blank = tip). Needed once the upgrade is live, when
    /// ownership has moved off the deployer and a tip fork would revert.
    #[clap(long)]
    pub fork_block: Option<u64>,
    /// Gateway RPC for PUVT's read-only gateway checks (gateway-enabled envs only).
    #[clap(long, default_value = DEFAULT_GATEWAY_RPC_URL)]
    pub gw_rpc_url: String,
    /// zk-governance commit PUVT verifies the governance bytecodes against; recorded in the bundle.
    #[clap(long, default_value = DEFAULT_ZK_GOVERNANCE_COMMIT)]
    pub zk_governance_commit: String,
    /// foundry-zksync version used for the build; recorded in the bundle (part of the bytecode identity).
    #[clap(long)]
    pub foundry_zksync_version: Option<String>,
}

/// Fork L1, prepare the upgrade, pack the deploy bundle, replay it and run PUVT.
pub async fn run_rehearse_upgrade(args: RehearseUpgradeArgs) -> anyhow::Result<()> {
    let env_cfg = EnvConfig::load(&args.env)?;
    let output_dir = default_protocol_ops_out_dir(&env_cfg.env)?;
    logger::info(format!(
        "Env {} | bridgehub {:#x} | gateway {} | deployer {:#x} (impersonated)",
        env_cfg.env,
        env_cfg.bridgehub(),
        if env_cfg.new_gateway().is_some() {
            "yes"
        } else {
            "no"
        },
        args.deployer_address
    ));

    // Wipe the previous run's output, keeping only the committed real-network transaction log.
    fs::create_dir_all(&output_dir)?;
    for entry in fs::read_dir(&output_dir)? {
        let entry = entry?;
        if entry.file_name() != TRANSACTIONS_LOG {
            let path = entry.path();
            if path.is_dir() {
                fs::remove_dir_all(&path)?;
            } else {
                fs::remove_file(&path)?;
            }
        }
    }
    let paths = BundlePaths {
        manifest: output_dir.join(MANIFEST_FILE),
        ecosystem_toml: output_dir.join("ecosystem.toml"),
        work_dir: output_dir.join("fork-rehearsal"),
    };

    let anvil = start_fork(anvil_port(&env_cfg.env)?, &args.fork_url, args.fork_block)?;
    let rpc_url = anvil.endpoint();
    let forked_at_block = get_provider(&rpc_url)?
        .get_block_number()
        .await
        .context("eth_blockNumber")?;
    logger::info(format!("Forked L1 at block {forked_at_block} on {rpc_url}"));

    logger::step("upgrade-prepare-all (this takes ~12 min)");
    let prepare_args = [
        "upgrade-prepare-all".to_string(),
        "--env".into(),
        env_cfg.env.clone(),
        "--l1-rpc-url".into(),
        rpc_url.clone(),
        "--deployer-address".into(),
        format!("{:#x}", args.deployer_address),
        "--out".into(),
        output_dir.join("prepare").display().to_string(),
        FORGE_MEMORY_LIMIT.into(),
    ];
    upgrade::run_upgrade_prepare_all(UpgradePrepareAllArgs::try_parse_from(prepare_args)?).await?;

    logger::step("pack the deploy bundle");
    pack_deploy_bundle(
        &env_cfg,
        &output_dir,
        &output_dir.join("deploy-bundle"),
        &paths::contracts_root(),
        &BundleProvenance {
            deployer: Some(args.deployer_address),
            forked_at_block: Some(forked_at_block),
            zk_governance_commit: Some(args.zk_governance_commit.clone()),
            foundry_zksync_version: args.foundry_zksync_version.clone(),
        },
    )?;

    logger::step("fund every bundle signer");
    fund_bundle_targets(
        &rpc_url,
        &env_cfg,
        args.deployer_address,
        &paths.manifest,
        &paths.ecosystem_toml,
    )
    .await?;
    broadcast_impersonated(&rpc_url, &paths).await?;
    verify_upgrade(
        &env_cfg,
        &rpc_url,
        &args.gw_rpc_url,
        &args.zk_governance_commit,
        &paths,
    )
    .await?;
    drop(anvil);
    logger::success("Done");
    Ok(())
}

// ─── replay-bundle ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Parser)]
pub struct ReplayBundleArgs {
    /// The unpacked deploy bundle directory.
    #[clap(long)]
    pub bundle: PathBuf,
    /// Rehearse: fork this L1 RPC at the bundle's recorded height and replay every bundle under impersonation.
    #[clap(long, conflicts_with_all = ["rpc", "key", "verify_only"])]
    pub fork_url: Option<String>,
    /// Use this chain as-is: with `--key` broadcast the deployer's bundles for real, with `--verify-only` just run PUVT.
    #[clap(long, requires = "rpc_mode")]
    pub rpc: Option<String>,
    /// Deployer private key for a real broadcast; only its bundles are sent (`--skip-unkeyed`).
    #[clap(long, group = "rpc_mode", requires = "rpc")]
    pub key: Option<String>,
    /// Run PUVT only, against a chain the bundle was already broadcast to.
    #[clap(long, group = "rpc_mode", requires = "rpc")]
    pub verify_only: bool,
    /// Gateway RPC for PUVT's read-only gateway checks (gateway-enabled envs only).
    #[clap(long, default_value = DEFAULT_GATEWAY_RPC_URL)]
    pub gw_rpc_url: String,
    /// zk-governance commit for PUVT; defaults to the one recorded in the bundle.
    #[clap(long)]
    pub zk_governance_commit: Option<String>,
}

/// How a deploy bundle is consumed.
enum ReplayMode {
    Rehearse {
        fork_url: String,
    },
    Broadcast {
        rpc_url: String,
        key: String,
        signer: Address,
    },
    Verify {
        rpc_url: String,
    },
}

fn replay_mode(args: &ReplayBundleArgs) -> anyhow::Result<ReplayMode> {
    match (&args.fork_url, &args.rpc, &args.key, args.verify_only) {
        (Some(fork_url), None, None, false) => Ok(ReplayMode::Rehearse { fork_url: fork_url.clone() }),
        (None, Some(rpc_url), Some(key), false) => Ok(ReplayMode::Broadcast {
            rpc_url: rpc_url.clone(),
            key: key.clone(),
            signer: pk_to_address(key).context("--key is not a valid private key")?,
        }),
        (None, Some(rpc_url), None, true) => Ok(ReplayMode::Verify { rpc_url: rpc_url.clone() }),
        _ => anyhow::bail!(
            "pass exactly one of: --fork-url <l1-rpc> | --rpc <l1-rpc> --key <0xhex> | --rpc <l1-rpc> --verify-only"
        ),
    }
}

pub async fn run_replay_bundle(args: ReplayBundleArgs) -> anyhow::Result<()> {
    let mode = replay_mode(&args)?;
    let bundle_dir = fs::canonicalize(&args.bundle)
        .with_context(|| format!("deploy bundle not found: {}", args.bundle.display()))?;
    let metadata = verify_bundle_integrity(&bundle_dir)?;
    let env_cfg = EnvConfig::load(&metadata.env)?;
    let deployer = metadata
        .deployer_address
        .ok_or_else(|| anyhow::anyhow!("bundle metadata has no deployer_address"))?;
    if let ReplayMode::Broadcast { signer, .. } = &mode {
        anyhow::ensure!(
            *signer == deployer,
            "the supplied private key belongs to {signer:#x}, not the bundle deployer {deployer:#x}"
        );
    }
    // PUVT recognises deployed code through the checkout's AllContractsHashes.json.
    let local_hashes = sha256_file(&paths::contracts_root().join("AllContractsHashes.json"))?;
    anyhow::ensure!(
        local_hashes == metadata.all_contracts_hashes_sha256,
        "AllContractsHashes.json differs from the bundle's (bundle {}, commit {}; local {}). \
         PUVT will not recognise the deployed bytecode: check out {} first.",
        metadata.all_contracts_hashes_sha256,
        metadata.contracts_commit,
        local_hashes,
        metadata.contracts_commit
    );
    let zk_governance_commit = args
        .zk_governance_commit
        .clone()
        .or(metadata.zk_governance_commit.clone())
        .unwrap_or_else(|| DEFAULT_ZK_GOVERNANCE_COMMIT.to_string());
    // Replay state goes next to the env's other outputs, never into the bundle (the handoff artifact).
    let paths = BundlePaths {
        manifest: bundle_dir.join(MANIFEST_FILE),
        ecosystem_toml: bundle_dir.join("ecosystem.toml"),
        work_dir: default_protocol_ops_out_dir(&env_cfg.env)?.join("replay"),
    };
    logger::info(format!(
        "Env {} | bundle {} | deployer {deployer:#x}",
        env_cfg.env,
        bundle_dir.display()
    ));

    match mode {
        ReplayMode::Rehearse { fork_url } => {
            if metadata.l1.forked_at_block.is_none() {
                logger::warn("the bundle records no fork height; forking at the chain tip, which reverts if the upgrade is live");
            }
            let anvil = start_fork(
                anvil_port(&env_cfg.env)? + REPLAY_PORT_OFFSET,
                &fork_url,
                metadata.l1.forked_at_block,
            )?;
            let rpc_url = anvil.endpoint();
            logger::step("fund every bundle signer");
            fund_bundle_targets(
                &rpc_url,
                &env_cfg,
                deployer,
                &paths.manifest,
                &paths.ecosystem_toml,
            )
            .await?;
            broadcast_impersonated(&rpc_url, &paths).await?;
            verify_upgrade(
                &env_cfg,
                &rpc_url,
                &args.gw_rpc_url,
                &zk_governance_commit,
                &paths,
            )
            .await?;
            drop(anvil);
        }
        ReplayMode::Broadcast { rpc_url, key, .. } => {
            logger::step("upgrade-broadcast (signing the deployer's bundles)");
            fs::create_dir_all(&paths.work_dir)?;
            let broadcast_args = [
                "upgrade-broadcast".to_string(),
                "--manifest".into(),
                paths.manifest.display().to_string(),
                "--l1-rpc-url".into(),
                rpc_url.clone(),
                "--key".into(),
                format!("{deployer:#x}={key}"),
                "--skip-unkeyed".into(),
                "--out".into(),
                paths.work_dir.join("executed.json").display().to_string(),
            ];
            broadcast::run(UpgradeBroadcastArgs::try_parse_from(broadcast_args)?).await?;
            verify_upgrade(
                &env_cfg,
                &rpc_url,
                &args.gw_rpc_url,
                &zk_governance_commit,
                &paths,
            )
            .await?;
        }
        ReplayMode::Verify { rpc_url } => {
            verify_upgrade(
                &env_cfg,
                &rpc_url,
                &args.gw_rpc_url,
                &zk_governance_commit,
                &paths,
            )
            .await?;
        }
    }
    logger::success("Done");
    Ok(())
}

// ─── verify-bundle ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Parser)]
pub struct VerifyBundleArgs {
    /// The unpacked deploy bundle directory.
    pub bundle: PathBuf,
}

pub fn run_verify_bundle(args: VerifyBundleArgs) -> anyhow::Result<()> {
    verify_bundle_integrity(&args.bundle).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TARGET: &str = "0x0000000000000000000000000000000000000002";

    fn write(path: &Path, content: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, content).unwrap();
    }

    /// A metadata file whose digests match what is on disk under `bundle`.
    fn write_metadata(bundle: &Path, files: &[&str]) -> DeployBundleMetadata {
        let metadata = DeployBundleMetadata {
            schema: DEPLOY_BUNDLE_SCHEMA.to_string(),
            upgrade: V31_UPGRADE_NAME.to_string(),
            env: "stage".to_string(),
            contracts_commit: "test".to_string(),
            contracts_worktree_dirty: false,
            all_contracts_hashes_sha256: "0".repeat(64),
            l1: L1Provenance {
                chain_id: Some(1),
                forked_at_block: Some(1),
            },
            deployer_address: Some(TARGET.parse().unwrap()),
            zk_governance_commit: None,
            toolchain: Toolchain {
                forge: "test".into(),
                rustc: "test".into(),
                foundry_zksync: None,
            },
            generated_by: None,
            files: files
                .iter()
                .map(|file| (file.to_string(), sha256_file(&bundle.join(file)).unwrap()))
                .collect(),
        };
        write(
            &bundle.join(BUNDLE_METADATA_FILE),
            &serde_json::to_string_pretty(&metadata).unwrap(),
        );
        metadata
    }

    fn valid_bundle() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        write(
            &dir.path().join("prepare/01.safe.json"),
            r#"{"transactions":[]}"#,
        );
        write(
            &dir.path().join(MANIFEST_FILE),
            &format!(r#"{{"bundles":[{{"index":1,"file":"01.safe.json","target":"{TARGET}"}}]}}"#),
        );
        write(
            &dir.path().join("ecosystem.toml"),
            "old_protocol_version = 1\n",
        );
        write_metadata(
            dir.path(),
            &["ecosystem.toml", "prepare/01.safe.json", MANIFEST_FILE],
        );
        dir
    }

    fn error_of(result: anyhow::Result<DeployBundleMetadata>) -> String {
        format!(
            "{:#}",
            result.expect_err("expected the integrity check to fail")
        )
    }

    #[test]
    fn accepts_a_bundle_whose_files_match_their_digests() {
        let dir = valid_bundle();
        let metadata = verify_bundle_integrity(dir.path()).unwrap();
        assert_eq!(metadata.files.len(), 3);
    }

    #[test]
    fn rejects_modified_transaction_bytes() {
        let dir = valid_bundle();
        write(
            &dir.path().join("prepare/01.safe.json"),
            r#"{"transactions":[] }"#,
        );
        assert!(error_of(verify_bundle_integrity(dir.path()))
            .contains("SHA-256 mismatch for prepare/01.safe.json"));
    }

    #[test]
    fn rejects_a_manifest_naming_a_file_the_metadata_does_not_cover() {
        let dir = valid_bundle();
        write(
            &dir.path().join(MANIFEST_FILE),
            &format!(r#"{{"bundles":[{{"index":1,"file":"02.safe.json","target":"{TARGET}"}}]}}"#),
        );
        write_metadata(
            dir.path(),
            &["ecosystem.toml", "prepare/01.safe.json", MANIFEST_FILE],
        );
        assert!(error_of(verify_bundle_integrity(dir.path()))
            .contains("prepare/02.safe.json is in the manifest but not in the metadata"));
    }

    #[test]
    fn rejects_files_outside_the_bundle() {
        let dir = valid_bundle();
        let mut metadata = write_metadata(
            dir.path(),
            &["ecosystem.toml", "prepare/01.safe.json", MANIFEST_FILE],
        );
        metadata
            .files
            .insert("../outside.txt".to_string(), "0".repeat(64));
        write(
            &dir.path().join(BUNDLE_METADATA_FILE),
            &serde_json::to_string(&metadata).unwrap(),
        );
        assert!(error_of(verify_bundle_integrity(dir.path()))
            .contains("path must stay inside the bundle"));
    }

    #[test]
    fn packs_the_generation_output_with_a_digest_for_every_file() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("output");
        let repo = dir.path().join("repository");
        write(&repo.join("AllContractsHashes.json"), "[]");
        write(&output.join("ecosystem.toml"), "old_protocol_version = 1\n");
        write(
            &output.join("prepare/01.safe.json"),
            r#"{"transactions":[]}"#,
        );
        write(
            &output.join(MANIFEST_FILE),
            &format!(r#"{{"bundles":[{{"index":1,"file":"01.safe.json","target":"{TARGET}"}}]}}"#),
        );
        let Ok(env_cfg) = EnvConfig::load("stage") else {
            return; // no checkout around the test binary
        };
        let provenance = BundleProvenance {
            deployer: Some(TARGET.parse().unwrap()),
            forked_at_block: Some(42),
            ..BundleProvenance::default()
        };
        let bundle = dir.path().join("packed");
        let metadata = pack_deploy_bundle(&env_cfg, &output, &bundle, &repo, &provenance).unwrap();

        let files: Vec<_> = metadata.files.keys().cloned().collect();
        assert_eq!(
            files,
            ["ecosystem.toml", "prepare/01.safe.json", MANIFEST_FILE]
        );
        assert_eq!(metadata.l1.forked_at_block, Some(42));
        assert!(
            metadata.contracts_worktree_dirty,
            "a non-git directory must count as dirty"
        );
        assert!(bundle.join(BUNDLE_METADATA_FILE).is_file());
        verify_bundle_integrity(&bundle).unwrap();
    }

    #[test]
    fn replay_mode_requires_exactly_one_target() {
        let base = ReplayBundleArgs {
            bundle: PathBuf::from("."),
            fork_url: None,
            rpc: Some("http://localhost:8545".into()),
            key: None,
            verify_only: false,
            gw_rpc_url: String::new(),
            zk_governance_commit: None,
        };
        assert!(replay_mode(&base).is_err(), "--rpc alone must be rejected");
        assert!(replay_mode(&ReplayBundleArgs {
            verify_only: true,
            ..base.clone()
        })
        .is_ok());
    }
}
