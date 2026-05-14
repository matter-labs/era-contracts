//! `protocol-ops ecosystem stage3` — Phase 3: legacy-token registration.
//!
//! Runs `CoreUpgrade_v31.stage3(bridgehubProxy)` on the env's bridgehub:
//!   - registers ETH + every entry in the v31-bridged-tokens config in NTV's
//!     bridgedTokens list,
//!   - calls `registerLegacyToken` on the L1AssetTracker (moves chainBalances
//!     out of the NTV) for every token with non-zero balance.
//!
//! Sequencing: runs *before* the per-chain upgrades (Phase 4). The L1NTV
//! starts routing every withdrawal through the L1AssetTracker the moment
//! stage 1 of governance lands, so registering tokens early means each
//! chain's withdrawals unblock immediately when its diamond upgrade lands —
//! both `_requireRegistered(assetId)` (this phase) and
//! `v31UpgradeChainBatchNumber` (per-chain upgrade) gates are cleared back
//! to back instead of leaving an extra registration freeze afterwards.
//!
//! Any signer can run this — no governance privileges needed. The caller
//! must pass `--sender <EOA>`. We deliberately do not fall back to the
//! env's `owner_address` because on stage / mainnet that's the
//! ProtocolUpgradeHandler contract (governance), not a signable EOA.

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
    let l1_contracts_path = resolve_l1_contracts_path()?;

    // If a per-env tokens file exists under
    // `upgrade-envs/v0.31.0-interopB/<env>-bridged-tokens.toml` (produced by
    // `scripts/discover-legacy-bridged-tokens.ts`), point the forge script at
    // it via `UPGRADE_BRIDGED_TOKENS_INPUT_OVERRIDE`. That way the discovered
    // list flows into `registerBridgedTokensInNTV` without anyone hand-editing
    // `script-config/v31-bridged-tokens.toml`. We only set the override when
    // the file actually exists so local fixtures (which don't have a per-env
    // tokens file) still fall back to the committed `script-config/` default.
    let bridged_tokens_override = env_cfg.as_ref().and_then(|cfg| {
        let rel = format!(
            "/upgrade-envs/v0.31.0-interopB/{}-bridged-tokens.toml",
            cfg.env
        );
        let absolute = l1_contracts_path.join(rel.trim_start_matches('/'));
        absolute.exists().then_some(rel)
    });

    let mut runner = ForgeRunner::new(&args.shared)?;
    let sender = runner.prepare_sender(sender_address).await?;

    logger::step(format!(
        "ecosystem stage3 → CoreUpgrade_v31.stage3({:#x}) on bridgehub {bridgehub:#x}",
        bridgehub
    ));
    if let Some(ref rel) = bridged_tokens_override {
        logger::info(format!("Bridged tokens input (per-env override): {rel}"));
    } else {
        logger::info(
            "Bridged tokens input: script-config/v31-bridged-tokens.toml (committed default)",
        );
    }
    let script_rel = Path::new(STAGE3_SCRIPT);
    let mut script = runner
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
    if let Some(rel) = bridged_tokens_override {
        script = script.with_env("UPGRADE_BRIDGED_TOKENS_INPUT_OVERRIDE", rel);
    }
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
