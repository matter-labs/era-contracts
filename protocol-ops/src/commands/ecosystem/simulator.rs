use std::fs;
use std::path::PathBuf;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use ethers::utils::hex;
use serde::{Deserialize, Serialize};

use crate::common::governance_calls::decode_calls;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct GovernanceTomlToSimulatorArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Path to a protocol-ops governance TOML. Defaults to
    /// `upgrade-envs/v0.31.0-interopB/output/<env>/protocol-ops/prepare/governance.toml`
    /// when `--env` is set.
    #[clap(long)]
    pub governance_toml: Option<PathBuf>,

    /// Transaction-simulator network name. Defaults to `mainnet` for
    /// `--env mainnet`, otherwise `sepolia`.
    #[clap(long)]
    pub network: Option<String>,

    /// Sender to put into every transaction. Defaults to the env's
    /// `owner_address` from `upgrade-envs/v0.31.0-interopB/<env>.toml`.
    #[clap(long)]
    pub from: Option<Address>,

    /// Optional output JSON path. When omitted, JSON is printed to stdout.
    #[clap(long)]
    pub out: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct GovernanceCallsToml {
    governance_calls: GovernanceCalls,
}

#[derive(Debug, Deserialize)]
struct GovernanceCalls {
    stage0_calls: String,
    stage1_calls: String,
    stage2_calls: String,
}

#[derive(Debug, Serialize)]
struct SimulatorTransaction {
    description: String,
    network: String,
    from: String,
    to: String,
    data: String,
    value: String,
    #[serde(rename = "valueToMint", skip_serializing_if = "Option::is_none")]
    value_to_mint: Option<String>,
    tag: String,
}

pub async fn run(args: GovernanceTomlToSimulatorArgs) -> anyhow::Result<()> {
    let env_cfg = args.topology.env_config()?;

    let governance_toml = match args.governance_toml {
        Some(path) => path,
        None => {
            let cfg = env_cfg.as_ref().ok_or_else(|| {
                anyhow::anyhow!("--governance-toml is required unless --env is set")
            })?;
            crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)?
                .join("prepare")
                .join("governance.toml")
        }
    };

    let network = args.network.unwrap_or_else(|| {
        env_cfg
            .as_ref()
            .filter(|cfg| cfg.env == "mainnet")
            .map(|_| "mainnet".to_string())
            .unwrap_or_else(|| "sepolia".to_string())
    });

    let from = match args.from {
        Some(addr) => addr,
        None => env_cfg
            .as_ref()
            .and_then(|cfg| cfg.owner_address())
            .ok_or_else(|| {
                anyhow::anyhow!("--from is required unless --env resolves an owner_address")
            })?,
    };

    let transactions = governance_toml_to_simulator_transactions(&governance_toml, &network, from)
        .with_context(|| {
            format!(
                "failed to convert governance TOML {}",
                governance_toml.display()
            )
        })?;
    let body = serde_json::to_string_pretty(&transactions)?;

    if let Some(out) = args.out {
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create output dir {}", parent.display()))?;
        }
        fs::write(&out, format!("{body}\n"))
            .with_context(|| format!("failed to write {}", out.display()))?;
    } else {
        println!("{body}");
    }

    Ok(())
}

fn governance_toml_to_simulator_transactions(
    path: &PathBuf,
    network: &str,
    from: Address,
) -> anyhow::Result<Vec<SimulatorTransaction>> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let parsed: GovernanceCallsToml =
        toml::from_str(&content).with_context(|| format!("failed to parse {}", path.display()))?;

    let stages = [
        (0u8, parsed.governance_calls.stage0_calls.as_str()),
        (1u8, parsed.governance_calls.stage1_calls.as_str()),
        (2u8, parsed.governance_calls.stage2_calls.as_str()),
    ];
    let mut out = Vec::new();
    let mut should_fund_sender = true;
    for (stage, encoded_calls) in stages {
        let calls = decode_calls(encoded_calls)
            .with_context(|| format!("failed to decode stage{stage}_calls"))?;
        for (idx, call) in calls.into_iter().enumerate() {
            let value_to_mint = should_fund_sender.then(|| "1".to_string());
            should_fund_sender = false;
            out.push(SimulatorTransaction {
                description: format!("protocol-ops governance stage{stage} call {}", idx + 1),
                network: network.to_string(),
                from: format!("{from:#x}"),
                to: format!("{:#x}", call.target),
                data: format!("0x{}", hex::encode(call.data)),
                value: call.value.to_string(),
                value_to_mint,
                tag: format!("stage{stage}"),
            });
        }
    }
    Ok(out)
}
