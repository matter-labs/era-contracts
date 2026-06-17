use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::env_config::default_protocol_ops_out_dir;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::config::forge_interface::script_params::ADMIN_FUNCTIONS_INVOCATION;

/// Chain-level CTM upgrade, prepare-only.
///
/// Drives `AdminFunctions.s.sol::upgradeChainFromCTM(chain, admin, acr)`
/// against a forked anvil (auto-impersonation), emits a Gnosis Safe
/// Transaction Builder JSON bundle via `--out`, and never broadcasts.
/// Replay the bundle via `protocol-ops dev execute-safe` (or any
/// Safe-bundle-aware executor) to apply it.
///
/// Pass `--chain-id` to target a single chain. Omit it to loop over every
/// chain registered on the bridgehub — each chain's bundle lands under
/// `<--out>/<chain-id>/` so the bundles don't collide. With `--env`, the
/// per-chain `<--out>` defaults to
/// `upgrade-envs/.../<env>/chain-upgrades/<chain-id>/`.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Target a single chain. Omit to loop over every registered chain on
    /// the bridgehub.
    #[clap(long)]
    pub chain_id: Option<u64>,

    /// AccessControlRestriction contract address. Defaults to `0x0…0` for
    /// Ownable ChainAdmin deployments; pass explicitly when the chain uses
    /// an ACR.
    #[clap(long, default_value = ZERO_ADDRESS)]
    pub access_control_restriction: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

#[derive(Serialize)]
struct ChainUpgradeOutputPayload {
    chain_address: Address,
    admin_address: Address,
    access_control_restriction: Address,
}

pub async fn run(args: ChainUpgradeArgs) -> anyhow::Result<()> {
    let bridgehub = args.topology.resolve()?;
    let env_cfg = args.topology.env_config()?;

    // Resolve the chain-id list up front: explicit `--chain-id` wins,
    // otherwise enumerate the bridgehub.
    let chain_ids: Vec<u64> = if let Some(id) = args.chain_id {
        vec![id]
    } else {
        let ids =
            crate::common::l1_contracts::resolve_all_chain_ids(&args.shared.l1_rpc_url, bridgehub)
                .await
                .context("listing chains for chain-upgrade loop")?;
        if ids.is_empty() {
            anyhow::bail!("no registered chains found on bridgehub {bridgehub:#x}");
        }
        logger::info(format!(
            "chain upgrade: targeting {} chain(s) on bridgehub {:#x}",
            ids.len(),
            bridgehub
        ));
        ids
    };

    for cid in chain_ids {
        // When looping, scope each chain's bundle under `<--out>/<cid>/` so
        // they don't collide. Single-chain mode honors `--out` unchanged.
        let mut shared = args.shared.clone();
        if shared.out.is_none() {
            if let Some(ref cfg) = env_cfg {
                shared.out = Some(
                    default_protocol_ops_out_dir(&cfg.env)?
                        .join("chain-upgrades")
                        .join(cid.to_string()),
                );
            }
        } else if args.chain_id.is_none() {
            // User passed --out for a multi-chain loop — append <cid>/ so
            // each chain's bundle gets its own subdir.
            let base = shared.out.as_ref().unwrap().clone();
            shared.out = Some(base.join(cid.to_string()));
        }

        run_one(bridgehub, cid, args.access_control_restriction, &shared)
            .await
            .with_context(|| format!("chain {cid} upgrade"))?;
    }

    Ok(())
}

async fn run_one(
    bridgehub: Address,
    chain_id: u64,
    access_control_restriction: Address,
    shared: &SharedRunArgs,
) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(shared)?;

    let chain_address =
        crate::common::l1_contracts::resolve_zk_chain(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain diamond proxy from L1")?;

    // Read-only pre-flights before generating the upgrade calldata. These catch
    // two failure modes that otherwise surface as cryptic, late errors:
    //
    //   - committed == executed: the v31 migration (SettlementLayerV31UpgradeBase)
    //     assumes no committed-but-unexecuted batches at upgrade time.
    //   - source-version readiness: the CTM must hold an upgrade cut for the
    //     chain's *current* protocol version, else `upgradeChainFromVersion`
    //     reverts with an opaque `NoLogsFound`.
    let (committed, executed) =
        crate::common::l1_contracts::resolve_total_batches_committed_executed(
            &runner.rpc_url,
            chain_address,
        )
        .await
        .context("reading batch counters for chain-upgrade pre-flight")?;
    anyhow::ensure!(
        committed == executed,
        "chain {chain_id}: cannot upgrade with unexecuted batches \
         (committed={committed}, executed={executed}); wait until committed == executed \
         (chain diamond {chain_address:#x})"
    );

    let ctm = crate::common::l1_contracts::resolve_ctm_proxy(&runner.rpc_url, bridgehub, chain_id)
        .await
        .context("resolving CTM for chain-upgrade source-version pre-flight")?;
    let source_version =
        crate::common::l1_contracts::resolve_chain_protocol_version(&runner.rpc_url, chain_address)
            .await
            .context("reading chain protocol version for chain-upgrade pre-flight")?;
    let cut_hash = crate::common::l1_contracts::resolve_ctm_upgrade_cut_hash(
        &runner.rpc_url,
        ctm,
        source_version,
    )
    .await
    .context("reading CTM upgrade-cut hash for chain-upgrade pre-flight")?;
    anyhow::ensure!(
        cut_hash != [0u8; 32],
        "chain {chain_id}: CTM {ctm:#x} has no upgrade cut registered for the chain's current \
         protocol version {source_version} — the chain is on an unsupported source version and \
         must be caught up (run the prior-version upgrade) before the v31 upgrade"
    );

    // ZKsync OS chains need a manual post-upgrade backfill. The v31
    // migration sets `baseTokenHasTotalSupply` automatically only for
    // non-ZKsync-OS chains; for ZKsync OS it stays false until the chain admin
    // runs `setZKsyncOSPreV31TotalSupply`. Without it `totalSupply()` reverts and
    // L1→Gateway token-balance migration is blocked. There is no tooling that
    // computes the value, so surface the requirement explicitly here.
    if crate::common::l1_contracts::resolve_is_zksync_os(&runner.rpc_url, ctm).await? {
        logger::warn(format!(
            "chain {chain_id} is a ZKsync OS chain: AFTER this upgrade executes, the chain admin \
             MUST run SetZkosPreV31TotalSupply (Admin.setZKsyncOSPreV31TotalSupply) with the \
             pre-v31 base-token total supply — derive it off-chain as \
             totalSuccessfulDepositsFromL1 - totalWithdrawalsToL1 at the upgrade boundary. \
             Skipping it permanently blocks totalSupply()/token-balance migration on this chain."
        ));
    }

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    // The Solidity helper executes through ChainAdmin, but broadcasts from
    // ChainAdmin.owner() or the AccessControlRestriction default admin inside adminExecuteCalls.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, access_control_restriction)
        .await?;

    let forge = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "upgradeChainFromCTM",
            (chain_address, admin_address, access_control_restriction),
        )?
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        // `--broadcast` against the anvil fork. In this mode the
        // target RPC is the anvil fork, so "broadcast" produces no real-chain
        // effect — it just records the tx in forge's run file so protocol-ops can
        // extract it into the Safe bundle. Without this the Safe output would be
        // empty.
        .with_wallet(&sender);

    logger::step(format!(
        "chain {chain_id}: upgradeChainFromCTM Safe bundle (simulation)"
    ));
    logger::info(format!("Chain address: {:#x}", chain_address));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        access_control_restriction
    ));
    logger::info(format!("RPC URL: {}", shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to execute forge script for chain upgrade")?;

    let empty_input = serde_json::json!({});
    let out_payload = ChainUpgradeOutputPayload {
        chain_address,
        admin_address,
        access_control_restriction,
    };
    write_output_if_requested("chain.upgrade", shared, &runner, &empty_input, &out_payload).await?;

    logger::success(format!("Chain {chain_id} upgrade prepared"));
    Ok(())
}
