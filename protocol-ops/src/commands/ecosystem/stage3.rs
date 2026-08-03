//! `protocol-ops ecosystem stage3` — Phase 3: bridged-token registration.
//!
//! Runs `CoreUpgrade_v31.stage3(bridgehubProxy)` on the env's bridgehub:
//!   - registers ETH + every entry in the v31-bridged-tokens config in the
//!     NTV's `bridgedTokens` list;
//!   - populates the NTV's `bridgedOut` accounting from the pre-upgrade
//!     per-chain balances, without which every withdrawal of an L1-native
//!     asset reverts after the upgrade. Idempotent per asset, so an interrupted
//!     run is resumed by simply running the phase again.
//!
//! Sequencing: runs *before* the per-chain upgrades (Phase 4), so the NTV
//! `_requireRegistered(assetId)` gate is cleared before each chain's diamond
//! upgrade lands and its `v31UpgradeChainBatchNumber` gate opens — the two
//! gates clear back to back instead of leaving an extra registration freeze
//! afterwards.
//!
//! Any signer can run this — no governance privileges needed. The caller
//! must pass `--sender <EOA>`. We deliberately do not fall back to the
//! env's `owner_address` because on stage / mainnet that's the
//! ProtocolUpgradeHandler contract (governance), not a signable EOA.

use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::ICoreUpgradeV31Abi;
use crate::common::env_config::default_protocol_ops_out_dir;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::output::write_output_if_requested;
use crate::common::paths::resolve_l1_contracts_path;
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
    let l1_contracts_path = resolve_l1_contracts_path()?;

    // If a per-env tokens file exists under
    // `upgrade-envs/v0.31.0-interopB/<env>-bridged-tokens.toml` (produced by
    // `scripts/discover-legacy-bridged-tokens.ts`), point the forge script at
    // it via `UPGRADE_BRIDGED_TOKENS_INPUT_OVERRIDE`. That way the discovered
    // list flows into `registerBridgedTokensInNTV` without anyone hand-editing
    // the committed default. We only set the override when the file actually
    // exists so local fixtures still fall back to the committed
    // `upgrade-envs/v0.31.0-interopB/local-bridged-tokens.toml` default.
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
            "Bridged tokens input: upgrade-envs/v0.31.0-interopB/local-bridged-tokens.toml (committed default)",
        );
    }
    let mut script = runner
        .script_call(ICoreUpgradeV31Abi::stage3Call {
            bridgehubProxy: bridgehub,
        })
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
