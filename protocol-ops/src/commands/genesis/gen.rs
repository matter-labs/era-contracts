use std::path::PathBuf;
use std::process::Command;

use clap::Parser;
use xshell::Shell;

use crate::common::logger;
use crate::utils::paths;

#[derive(Debug, Clone, Parser)]
pub struct GenesisGenArgs {
    /// Output file path for genesis.json
    #[clap(long, default_value = "genesis.json")]
    pub output_file: PathBuf,

    /// Execution version (default: 6 for v31)
    #[clap(long, default_value_t = 6)]
    pub execution_version: u32,
}

pub fn run(args: GenesisGenArgs, _shell: &Shell) -> anyhow::Result<()> {
    let root = paths::contracts_root();
    let genesis_gen_manifest = root.join("tools/zksync-os-genesis-gen/Cargo.toml");
    if !genesis_gen_manifest.exists() {
        anyhow::bail!(
            "zksync-os-genesis-gen not found at {}",
            genesis_gen_manifest.display()
        );
    }

    let output_path = if args.output_file.is_absolute() {
        args.output_file.clone()
    } else {
        root.join(&args.output_file)
    };

    logger::step("Generating genesis.json...");
    let status = Command::new("cargo")
        .args([
            "run",
            "--manifest-path",
            genesis_gen_manifest.to_str().unwrap(),
            "--",
            "--output-file",
            output_path.to_str().unwrap(),
            "--execution-version",
            &args.execution_version.to_string(),
        ])
        .current_dir(&root)
        .status()?;

    if !status.success() {
        anyhow::bail!("zksync-os-genesis-gen failed");
    }

    logger::info(format!("Genesis written to {}", output_path.display()));
    Ok(())
}
