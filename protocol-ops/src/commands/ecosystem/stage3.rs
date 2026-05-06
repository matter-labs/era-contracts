//! `protocol-ops ecosystem stage3` — Phase 4: post-governance bridged-token
//! migration.
//!
//! Runs `CoreUpgrade_v31.stage3(bridgehubProxy)` on the env's bridgehub:
//!   - registers ETH + every entry in the v31-bridged-tokens config in NTV's
//!     bridgedTokens list,
//!   - migrates non-zero `chainBalance` entries into the L1AssetTracker.
//!
//! Any signer can run this (no governance privileges needed); we default to
//! the env's `owner_address` since that EOA is the one already used for the
//! deployer phase.

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::commands::output::write_output_if_requested;
use crate::common::env_config::default_protocol_ops_out_dir;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::paths::resolve_l1_contracts_path;
use crate::common::SharedRunArgs;

const STAGE3_SCRIPT: &str = "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol:CoreUpgrade_v31";

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Stage3Args {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Sender for the stage-3 forge script. Defaults to the env's
    /// `owner_address`.
    #[clap(long)]
    pub sender: Option<Address>,
}

#[derive(Serialize)]
struct Stage3Output {
    bridgehub: String,
    sender: String,
}

pub async fn run(mut args: Stage3Args) -> anyhow::Result<()> {
    // ── env preset auto-fills ────────────────────────────────────────
    let env_cfg = args.topology.env_config()?;
    if let Some(ref cfg) = env_cfg {
        if args.shared.out.is_none() {
            args.shared.out = Some(default_protocol_ops_out_dir(&cfg.env)?.join("stage3"));
        }
        if args.sender.is_none() {
            args.sender = cfg.owner_address();
        }
    }
    let sender_address = args.sender.ok_or_else(|| {
        anyhow::anyhow!(
            "--sender (or --env <name> with owner_address in the v31 input TOML) is required"
        )
    })?;

    let bridgehub = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let sender = runner.prepare_sender(sender_address).await?;

    logger::step(format!(
        "ecosystem stage3 → CoreUpgrade_v31.stage3({:#x}) on bridgehub {bridgehub:#x}",
        bridgehub
    ));
    let l1_contracts_path = resolve_l1_contracts_path()?;
    let script_rel = Path::new(STAGE3_SCRIPT);
    let script = runner
        .script_path_from_root(&l1_contracts_path, script_rel)
        .with_contract_call(
            &crate::abi_contracts::CORE_UPGRADE_V31_CONTRACT,
            "stage3",
            (bridgehub,),
        )?
        .with_broadcast()
        .with_ffi()
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(&sender);
    runner
        .run(script)
        .context("Failed to execute CoreUpgrade_v31.stage3 forge script")?;

    let out_payload = Stage3Output {
        bridgehub: format!("{bridgehub:#x}"),
        sender: format!("{sender_address:#x}"),
    };
    write_output_if_requested(
        "ecosystem.stage3",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &out_payload,
    )
    .await?;

    logger::outro("ecosystem stage3 complete.");
    Ok(())
}
