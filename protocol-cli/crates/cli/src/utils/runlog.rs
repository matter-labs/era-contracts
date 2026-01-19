use std::fs;
use std::path::PathBuf;

const RUNS_ROOT_ENV: &str = "PROTOCOL_RUNS_ROOT";
use protocol_cli_common::{forge::ForgeRunner, logger};

/// Default root: ~/.zksync/protocol-cli/runs
pub fn default_runs_root() -> PathBuf {
    if let Ok(path) = std::env::var(RUNS_ROOT_ENV) {
        PathBuf::from(path)
    } else {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        home.join(".zksync").join("protocol-cli").join("runs")
    }
}

/// Create the session directory (UTC timestamp + command label) and dump runs into it.
/// Returns the created directory path.
pub fn persist_runner_session(
    runner: &ForgeRunner,
    command_label: &str,
) -> anyhow::Result<PathBuf> {
    let root: PathBuf = default_runs_root();
    if runner.runs().is_empty() {
        return Err(anyhow::anyhow!("No runs to persist"));
    }
    fs::create_dir_all(&root)?;
    let ts_ms = runner.runs()[0].ts_ms;
    let dir_name = format!("{}-{}", ts_ms, command_label);
    let session_dir = root.join(dir_name);
    runner.dump_to_dir(&session_dir)?;
    Ok(session_dir)
}
