//! `protocol-ops ecosystem stage3` populates `L1NativeTokenVault.bridgedOut`
//! from legacy per-chain balances through `CoreUpgrade_v33.stage3`.
//!
//! Run after governance and before the per-chain upgrades. Any signable EOA
//! can call it; `--sender` is required because the environment's owner may be
//! a governance contract.

use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::ICoreUpgradeV33Abi;
use crate::common::env_config::default_protocol_ops_out_dir;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::output::write_output_if_requested;
use crate::common::SharedRunArgs;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct Stage3Args {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Sender for the stage-3 forge script. Required: any signable EOA
    /// works (no governance privileges needed). Pass the same EOA whose
    /// key you used for the deployer bundle, or any other holder.
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
    }
    let sender_address = args.sender.ok_or_else(|| {
        anyhow::anyhow!(
            "--sender is required. Stage 3 takes any signable EOA — pass the same address you \
             used for `--deployer-address` in `upgrade-prepare-all`, derived from your broadcast \
             signer's private key (`cast wallet address --private-key …`)."
        )
    })?;

    let bridgehub = args.topology.resolve()?;

    let mut runner = ForgeRunner::new(&args.shared)?;
    let sender = runner.prepare_sender(sender_address).await?;

    logger::step(format!(
        "ecosystem stage3 → the core upgrade script's stage3({:#x}) on bridgehub {bridgehub:#x}",
        bridgehub
    ));
    // No bridged-tokens input: v33's stage 3 only populates `L1NativeTokenVault.bridgedOut`. The
    // legacy bridged-token registration that consumed such a list was v31's, and is gone.
    let script = runner
        .script_call(ICoreUpgradeV33Abi::stage3Call {
            _bridgehubProxy: bridgehub,
        })
        .with_wallet(&sender);
    runner
        .run(script)
        .context("Failed to execute the core upgrade script's stage3 forge script")?;

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
