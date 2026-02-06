use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use chrono::{TimeZone, Utc};
use clap::Parser;
use protocol_ops_common::logger;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use xshell::Shell;

use crate::utils::runlog;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct RunsListArgs {}

pub async fn run(args: RunsListArgs, shell: &Shell) -> anyhow::Result<()> {
    let runs_root = runlog::default_runs_root();
    print_runs_list(&runs_root)?;
    Ok(())
}

/// Print the list of runs
pub fn print_runs_list(runs_dir: &Path) -> Result<()> {
    // Collect all run directories
    let mut runs: Vec<(i64, PathBuf)> = fs::read_dir(runs_dir)
        .with_context(|| format!("reading {}", runs_dir.display()))?
        .filter_map(|entry_res| {
            let entry = entry_res.ok()?;
            // Check if it's a directory
            if !entry.file_type().ok()?.is_dir() {
                return None;
            }
            // Parse timestamp from name
            let file_name = entry.file_name();
            let name_str = file_name.to_str()?;
            let ts_ms = parse_unix_ms_prefix(name_str)?;

            // Return the timestamp and path
            Some((ts_ms, entry.path()))
        })
        .collect();

    // Sort by timestamp in descending order
    runs.sort_by_key(|(ts_ms, _path)| std::cmp::Reverse(*ts_ms));

    // Print runs
    for (ts_ms, path) in runs {
        let dt = Utc.timestamp_millis_opt(ts_ms);
        println!("[{}] {}", dt.unwrap().to_rfc3339(), path.display());
    }
    Ok(())
}

fn parse_unix_ms_prefix(name: &str) -> Option<i64> {
    let ts_part = name.splitn(2, '-').next()?;
    ts_part.parse::<i64>().ok()
}
