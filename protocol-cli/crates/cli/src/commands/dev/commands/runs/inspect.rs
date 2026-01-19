use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::{TimeZone, Utc};
use clap::Parser;
use protocol_cli_common::logger;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use xshell::Shell;

use crate::utils::runlog;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct RunsInspectArgs {}

pub async fn run(args: RunsInspectArgs, shell: &Shell) -> anyhow::Result<()> {
    let runs_root = runlog::default_runs_root();
    print_latest_run_info(&runs_root)?;
    Ok(())
}

/// Print the details of the latest run
pub fn print_latest_run_info(runs_dir: &Path) -> Result<()> {
    let latest_dir = find_latest_run_dir(runs_dir)
        .context(format!("No runs found in {}", runs_dir.display()))?;
    let latest_file = latest_dir.join("transactions.json");

    let ts_ms = parse_unix_ms_prefix(&latest_dir.file_name().unwrap().to_str().unwrap())
        .ok_or_else(|| anyhow::anyhow!("invalid dir name"))?;
    let dt = Utc.timestamp_millis_opt(ts_ms);

    // Read JSON
    let raw = fs::read_to_string(&latest_file)
        .context(format!("failed to read {}", latest_file.display()))?;
    let json: Value = serde_json::from_str(&raw)
        .context(format!("failed to parse JSON in {}", latest_file.display()))?;
    let txs = json.as_array().unwrap();

    logger::info(format!("Latest run: {}", latest_dir.display()));
    logger::info(format!("Time (UTC): {}", dt.unwrap().to_rfc3339()));
    logger::info(format!("Number of transactions: {}", txs.len()));
    logger::outro("");
    // println!("Transactions:");
    // if txs.is_empty() {
    //     println!("  []");
    // } else {
    //     // Pretty-print each tx on its own line for readability
    //     for (i, tx) in txs.iter().enumerate() {
    //         println!("  {:02}: {}", i + 1, serde_json::to_string_pretty(tx)?);
    //     }
    // }

    Ok(())
}

/// Find directory with the largest numeric `ts`.
pub fn find_latest_run_dir(root: &Path) -> Result<PathBuf> {
    let mut best: Option<(i64, PathBuf)> = None;

    for entry in fs::read_dir(root).with_context(|| format!("reading {}", root.display()))? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let ts_ms = parse_unix_ms_prefix(&entry.file_name().to_str().unwrap())
            .ok_or_else(|| anyhow::anyhow!("invalid dir name"))?;
        match &mut best {
            None => best = Some((ts_ms, entry.path())),
            Some((best_ts, best_path)) => {
                if ts_ms > *best_ts {
                    *best_ts = ts_ms;
                    *best_path = entry.path();
                }
            }
        }
    }

    best.map(|(_, p)| p)
        .ok_or_else(|| anyhow::anyhow!("no session directories found in {}", root.display()))
}

fn parse_unix_ms_prefix(name: &str) -> Option<i64> {
    let ts_part = name.splitn(2, '-').next()?;
    ts_part.parse::<i64>().ok()
}
