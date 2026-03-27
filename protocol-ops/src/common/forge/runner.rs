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
};
use crate::config::forge_interface::script_params::ForgeScriptParams;

/// Result of a forge script execution containing the broadcast JSON payload.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ForgeScriptRun {
    pub script: PathBuf,
    pub broadcast_file: PathBuf,
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
/// shell, forge CLI args, target RPC, foundry path, simulation mode, and run history.
pub struct ForgeRunner {
    /// Shell used for file I/O and command execution.
    pub shell: Shell,
    /// User-supplied forge CLI flags (--verify, --verifier-url, etc.).
    pub forge_args: ForgeScriptArgs,
    /// Effective RPC URL (anvil URL when simulating, original URL otherwise).
    pub rpc_url: String,
    /// Whether this runner is in simulation mode (forked anvil, no real broadcast).
    pub simulate: bool,
    /// Path to the `l1-contracts` foundry project root.
    pub foundry_scripts_path: PathBuf,
    /// Keeps the anvil instance alive while this runner exists.
    _anvil: Option<AnvilInstance>,
    runs: Vec<ForgeScriptRun>,
}

impl ForgeRunner {
    /// Create a new runner.
    ///
    /// If `simulate` is true, forks `l1_rpc_url` with anvil and targets the fork.
    pub fn new(
        simulate: bool,
        l1_rpc_url: &str,
        forge_args: ForgeScriptArgs,
    ) -> anyhow::Result<Self> {
        let shell = Shell::new().context("failed to create shell")?;

        let (rpc_url, anvil) = if simulate {
            logger::warn(format!(
                "[SIMULATION] Forking {} via anvil (no on-chain changes)",
                l1_rpc_url
            ));
            let instance = anvil::start_anvil_fork(l1_rpc_url)?;
            let url = instance.rpc_url().to_string();
            (url, Some(instance))
        } else {
            (l1_rpc_url.to_string(), None)
        };

        Ok(ForgeRunner {
            shell,
            forge_args,
            rpc_url,
            foundry_scripts_path: paths::path_to_foundry_scripts(),
            simulate,
            _anvil: anvil,
            runs: Vec::new(),
        })
    }

    /// Run a forge script.
    pub fn run(&mut self, mut script: ForgeScript) -> anyhow::Result<()> {
        if script.needs_bridgehub_skip() {
            let skip_path: String = String::from("contracts/bridgehub/*");
            script.args.add_arg(ForgeScriptArg::Skip { skip_path });
        }

        let args = script.args.build();
        let command_result = self.execute(&script, &args, false)?;

        if command_result.proposal_error() {
            return Ok(());
        }

        if command_result.is_ok() {
            self.record_run_latest(&script)?;
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
            .with_broadcast()
            .with_slow()
            .with_wallet(wallet, self.simulate);

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

    fn record_run_latest(&mut self, script: &ForgeScript) -> anyhow::Result<()> {
        let broadcast_file = self.find_run_latest_file(script)?;
        let payload = read_json(&broadcast_file).with_context(|| {
            format!(
                "Failed to read JSON from broadcast file: {}",
                broadcast_file.display()
            )
        })?;
        let run = ForgeScriptRun {
            script: script.script_name().to_path_buf(),
            broadcast_file,
            payload,
            ts_ms: Utc::now().timestamp_millis(),
        };
        self.runs.push(run.clone());
        Ok(())
    }

    fn find_run_latest_file(&self, script: &ForgeScript) -> anyhow::Result<PathBuf> {
        let root = script.base_path().join("broadcast");
        if !root.exists() {
            return Err(anyhow::anyhow!(
                "Broadcast root directory not found at {}",
                root.display()
            ));
        }
        let Some(script_name) = script.script_name().file_name() else {
            return Err(anyhow::anyhow!(
                "Script name not found in {}",
                script.script_name().display()
            ));
        };
        let chain_id = query_chain_id_sync(&self.rpc_url)?;
        let mut script_dir = root.join(script_name).join(chain_id.to_string());
        if !script.is_broadcast() {
            script_dir = script_dir.join("dry-run");
        }
        if !script_dir.exists() {
            return Err(anyhow::anyhow!(
                "Broadcast script directory not found at {}",
                script_dir.display()
            ));
        }
        let run_latest_filename = derive_run_latest_filename(script.sig());
        let run_latest_path = script_dir.join(run_latest_filename);
        if run_latest_path.exists() {
            Ok(run_latest_path)
        } else {
            return Err(anyhow::anyhow!(
                "Broadcast run latest file not found at {}",
                run_latest_path.display()
            ));
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
                format!("{trimmed}-latest.json")
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
