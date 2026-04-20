use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::Context;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use xshell::{cmd, Shell};

use super::script::{ForgeScript, ForgeScriptArg, ForgeScriptArgs};
// Forge is defined in the parent module (mod.rs); use the full path to avoid confusion.
use crate::common::forge::Forge;
use crate::common::{
    anvil::{self, AnvilInstance},
    cmd::{Cmd, CmdResult},
    ethereum::query_chain_id_sync,
    logger, paths,
    traits::{ReadConfig, SaveConfig},
    wallets::Wallet,
    SharedRunArgs,
};
use crate::config::forge_interface::script_params::ForgeScriptParams;

/// Result of a forge script execution containing the broadcast JSON payload.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ForgeScriptRun {
    pub script: PathBuf,
    pub broadcast_file: Option<PathBuf>,
    pub payload: Value,
    pub ts_ms: i64,
}

impl ForgeScriptRun {
    pub fn transactions(&self) -> Option<&[Value]> {
        self.payload
            .get("transactions")
            .and_then(|value| value.as_array())
            .map(|array| array.as_slice())
    }
}

/// Encapsulates the full execution environment for forge scripts:
/// shell, forge CLI args, target anvil-fork RPC, foundry path, and run history.
pub struct ForgeRunner {
    /// Shell used for file I/O and command execution.
    pub shell: Shell,
    /// User-supplied forge CLI flags (--verify, --verifier-url, etc.).
    pub forge_args: ForgeScriptArgs,
    /// Effective RPC URL (always the anvil fork — protocol-ops never
    /// broadcasts against real L1).
    pub rpc_url: String,
    /// Path to the `l1-contracts` foundry project root.
    pub foundry_scripts_path: PathBuf,
    /// Keeps the anvil instance alive while this runner exists.
    _anvil: AnvilInstance,
    runs: Vec<ForgeScriptRun>,
}

impl ForgeRunner {
    /// Create a new runner from the shared CLI args.
    ///
    /// Always forks `shared.l1_rpc_url` with anvil and targets the fork —
    /// protocol-ops is prepare-only and never touches real L1.
    pub fn new(shared: &SharedRunArgs) -> anyhow::Result<Self> {
        let shell = Shell::new().context("failed to create shell")?;

        logger::warn(format!(
            "[SIMULATION] Forking {} via anvil (no on-chain changes)",
            shared.l1_rpc_url
        ));
        let anvil = anvil::start_anvil_fork(&shared.l1_rpc_url)?;
        let rpc_url = anvil.rpc_url().to_string();

        Ok(ForgeRunner {
            shell,
            forge_args: shared.forge_args.clone(),
            rpc_url,
            foundry_scripts_path: paths::path_to_foundry_scripts(),
            _anvil: anvil,
            runs: Vec::new(),
        })
    }

    /// Fund `address` on the anvil fork via `anvil_setBalance`.
    ///
    /// Needed when the auto-resolved sender is a contract (e.g. Governance)
    /// or an EOA without ETH on the forked chain — forge's `--sender
    /// --unlocked` still requires the impersonated address to pay gas.
    pub async fn fund_sender(&self, address: ethers::types::Address) -> anyhow::Result<()> {
        anvil::set_balance(&self.rpc_url, address).await
    }

    /// Build a `Wallet` (private-key-less, unlocked) for `address` and fund
    /// it on the anvil fork. Convenience wrapper around
    /// `Wallet::parse(None, Some(address))` + `fund_sender`, since every
    /// prepare-shape command needs both.
    pub async fn prepare_sender(
        &self,
        address: ethers::types::Address,
    ) -> anyhow::Result<Wallet> {
        self.fund_sender(address).await?;
        Wallet::parse(None, Some(address))
    }

    /// Resolve the chain admin via `Bridgehub.getZKChain(chain_id).getAdmin()`
    /// and prepare it as a sender on the fork (fund + impersonate).
    pub async fn prepare_chain_admin(
        &self,
        bridgehub: ethers::types::Address,
        chain_id: u64,
    ) -> anyhow::Result<Wallet> {
        let admin =
            crate::common::l1_contracts::resolve_chain_admin(&self.rpc_url, bridgehub, chain_id)
                .await
                .context("resolving chain admin from L1")?;
        self.prepare_sender(admin).await
    }

    /// Resolve the chain admin's *owner* EOA (one Ownable hop past
    /// [`Self::prepare_chain_admin`]) and prepare it as a sender. Use this
    /// when the script's broadcast must come from a signable EOA — the
    /// ChainAdmin contract itself has no private key.
    pub async fn prepare_chain_admin_owner(
        &self,
        bridgehub: ethers::types::Address,
        chain_id: u64,
    ) -> anyhow::Result<Wallet> {
        let owner = crate::common::l1_contracts::resolve_chain_admin_owner(
            &self.rpc_url,
            bridgehub,
            chain_id,
        )
        .await
        .context("resolving chain admin owner EOA from L1")?;
        self.prepare_sender(owner).await
    }

    /// Resolve the governance contract's owner EOA via
    /// `Governance(bridgehub.owner()).owner()` and prepare it as a sender.
    pub async fn prepare_governance_owner(
        &self,
        bridgehub: ethers::types::Address,
    ) -> anyhow::Result<Wallet> {
        let owner =
            crate::common::l1_contracts::resolve_governance_owner(&self.rpc_url, bridgehub)
                .await
                .context("resolving governance owner EOA from L1")?;
        self.prepare_sender(owner).await
    }

    /// Run a forge script.
    pub fn run(&mut self, mut script: ForgeScript) -> anyhow::Result<()> {
        if script.needs_bridgehub_skip() {
            let skip_path: String = String::from("contracts/bridgehub/*");
            script.args.add_arg(ForgeScriptArg::Skip { skip_path });
        }

        let args = script.args.build();
        let pre_run_ts_ms = Utc::now().timestamp_millis();
        let command_result = self.execute(&script, &args, false)?;

        if command_result.proposal_error() {
            return Ok(());
        }

        if command_result.is_ok() {
            self.record_run(&script, pre_run_ts_ms)?;
        }
        Ok(command_result?)
    }

    /// Write `input` to the script's input path, run the script with `wallet` auth,
    /// then read and return the output. Handles the standard input→forge→output pattern.
    pub fn run_script<I: SaveConfig, O: ReadConfig>(
        &mut self,
        params: &ForgeScriptParams,
        input: &I,
        wallet: &Wallet,
    ) -> anyhow::Result<O> {
        let input_path = params.input(&self.foundry_scripts_path);
        input.save(&self.shell, &input_path)?;

        let forge = Forge::new(&self.foundry_scripts_path)
            .script(&params.script(), self.forge_args.clone())
            .with_ffi()
            .with_rpc_url(self.rpc_url.clone())
            .with_wallet(wallet);

        self.run(forge)?;

        let output_path = params.output(&self.foundry_scripts_path);
        O::read(&self.shell, output_path)
    }

    fn execute(
        &self,
        script: &ForgeScript,
        args: &[String],
        for_resume: bool,
    ) -> anyhow::Result<CmdResult<()>> {
        let script_path = script.script_name().as_os_str();
        let _dir_guard = self.shell.push_dir(script.base_path());
        let mut cmd = Cmd::new(cmd!(
            self.shell,
            "forge script {script_path} --legacy {args...}"
        ));
        for (key, value) in &script.envs {
            cmd = cmd.env(key, value);
        }
        if for_resume {
            cmd = cmd.with_piped_std_err();
        }
        Ok(cmd.run())
    }

    /// Record the broadcast run produced by `script`.
    /// Note, if script did not send any transactions, run-latest file won't be created.
    fn record_run(&mut self, script: &ForgeScript, pre_run_ts_ms: i64) -> anyhow::Result<()> {
        let script_name = script.script_name().to_path_buf();
        let ts_ms = Utc::now().timestamp_millis();

        let (broadcast_file, payload) = match self.find_run_latest_file(script)? {
            None => {
                // Assuming script did not send any transactions
                (None, serde_json::Value::Null)
            }
            Some(broadcast_file) => {
                let payload = read_json(&broadcast_file).with_context(|| {
                    format!(
                        "Failed to read JSON from broadcast file: {}",
                        broadcast_file.display()
                    )
                })?;
                let run_ts_raw = payload
                    .get("timestamp")
                    .and_then(|t| t.as_i64())
                    .unwrap_or(0);
                // Forge writes `timestamp` as whole seconds (`Utc::now().timestamp()`).
                // Compare at seconds precision on both sides: a pre-run captured mid-
                // second would otherwise falsely "beat" forge's truncated timestamp
                // for a fast run (cached build, small script) and we'd drop a live
                // broadcast file as stale. Normalize each side to seconds, treating
                // anything > 1e12 as already-ms (some older forge builds).
                let run_ts_s = if run_ts_raw > 1_000_000_000_000 {
                    run_ts_raw / 1000
                } else {
                    run_ts_raw
                };
                let pre_run_ts_s = pre_run_ts_ms / 1000;
                if run_ts_s < pre_run_ts_s {
                    // Broadcast file predates this run - likely a stale file from a previous invocation
                    (Some(broadcast_file), serde_json::Value::Null)
                } else {
                    (Some(broadcast_file), payload)
                }
            }
        };
        self.runs.push(ForgeScriptRun {
            script: script_name,
            broadcast_file,
            payload,
            ts_ms,
        });
        Ok(())
    }

    /// Returns the path to the run latest file for `script` or `None` if doesn't exist.
    fn find_run_latest_file(&self, script: &ForgeScript) -> anyhow::Result<Option<PathBuf>> {
        let root = script.base_path().join("broadcast");
        if !root.exists() {
            return Ok(None);
        }
        let Some(raw_script_name) = script.script_name().file_name() else {
            return Err(anyhow::anyhow!(
                "Script name not found in {}",
                script.script_name().display()
            ));
        };
        // Forge accepts `path.sol:Contract` to disambiguate contracts but names
        // the broadcast directory after the file only. `:` isn't a Unix path
        // separator, so `file_name()` preserves the suffix — strip it.
        let script_name_str = raw_script_name
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("Script name contains invalid UTF-8"))?;
        let script_name = script_name_str.split(':').next().unwrap_or(script_name_str);
        let chain_id = query_chain_id_sync(&self.rpc_url)?;
        let mut script_dir = root.join(script_name).join(chain_id.to_string());
        if !script.is_broadcast() {
            script_dir = script_dir.join("dry-run");
        }
        if !script_dir.exists() {
            return Ok(None);
        }
        let run_latest_filename = derive_run_latest_filename(script.sig());
        let run_latest_path = script_dir.join(run_latest_filename);
        if run_latest_path.exists() {
            Ok(Some(run_latest_path))
        } else {
            Ok(None)
        }
    }

    /// Read-only access to accumulated runs in this runner session.
    pub fn runs(&self) -> &[ForgeScriptRun] {
        &self.runs
    }
}

// Trait for handling forge errors. Required for implementing method for CmdResult
pub(crate) trait ForgeErrorHandler {
    // Catch the error if upgrade tx has already been processed. We do execute much of
    // txs using upgrade mechanism and if this particular upgrade has already been processed we could assume
    // it as a success
    fn proposal_error(&self) -> bool;
}

impl ForgeErrorHandler for CmdResult<()> {
    fn proposal_error(&self) -> bool {
        let text = "revert: Operation with this proposal id already exists";
        check_error(self, text)
    }
}

fn check_error(cmd_result: &CmdResult<()>, error_text: &str) -> bool {
    if let Err(cmd_error) = &cmd_result {
        if let Some(stderr) = &cmd_error.stderr {
            return stderr.contains(error_text);
        }
    }
    false
}

/// Derive the *-latest.json filename from an optional --sig value:
/// 1) no sig          -> "run-latest.json"
/// 2) hex sig         -> "<first8hex>-latest.json" (strip 0x)
/// 3) non-hex sig     -> "<sig>-latest.json"
fn derive_run_latest_filename(sig: Option<String>) -> String {
    fn is_hex_like(s: &str) -> bool {
        let s = s.strip_prefix("0x").unwrap_or(s);
        !s.is_empty() && s.chars().all(|c| c.is_ascii_hexdigit())
    }

    match sig {
        None => "run-latest.json".to_string(),
        Some(raw) => {
            let trimmed = raw.trim();
            if is_hex_like(trimmed) {
                let no_prefix = trimmed.strip_prefix("0x").unwrap_or(trimmed);
                let lower = no_prefix.to_ascii_lowercase();
                let prefix8 = &lower[..lower.len().min(8)];
                format!("{prefix8}-latest.json")
            } else {
                let fname = trimmed.split('(').next().unwrap_or(trimmed);
                format!("{fname}-latest.json")
            }
        }
    }
}

fn read_json(path: &Path) -> anyhow::Result<Value> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("failed to read forge broadcast file {}", path.display()))?;
    serde_json::from_str(&content).with_context(|| {
        format!(
            "failed to parse forge broadcast file {} as JSON",
            path.display()
        )
    })
}
