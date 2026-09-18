use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::env_config::default_protocol_ops_out_dir;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::types::L2DACommitmentScheme;

/// DA validator pair to set atomically in the same multicall as the upgrade.
#[derive(Debug, Clone, Copy)]
struct DaValidatorPair {
    l1_da_validator: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
}

#[derive(Serialize)]
struct ChainUpgradeOutput {
    chain_address: Address,
    admin_address: Address,
    access_control_restriction: Address,
    /// Present only when the upgrade atomically set the DA validator pair.
    #[serde(skip_serializing_if = "Option::is_none")]
    l1_da_validator: Option<Address>,
    /// Present only when the upgrade atomically set the DA validator pair.
    #[serde(skip_serializing_if = "Option::is_none")]
    l2_da_commitment_scheme: Option<L2DACommitmentScheme>,
}

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
///
/// To atomically re-set the chain's DA validator pair right after the upgrade
/// (required for Era: the v31 upgrade resets the chain's L1 DA validator), pass
/// both `--l1-da-validator` and `--l2-da-commitment-scheme`. Both calls land in
/// a single `ChainAdmin.multicall`, so the chain is never left upgraded but
/// without a DA validator pair. This requires a single `--chain-id`.
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

    /// L1 DA validator to set atomically in the same multicall as the upgrade.
    /// Requires `--l2-da-commitment-scheme` and a single `--chain-id`. The
    /// post-upgrade `RollupL1DAValidator` (or analogous) for the chain's CTM.
    #[clap(long, requires = "l2_da_commitment_scheme")]
    pub l1_da_validator: Option<Address>,

    /// L2 DA commitment scheme to set alongside `--l1-da-validator`. For Era
    /// v31+ rollup (EraVM): `blobs-and-pubdata-keccak256`.
    #[clap(long, value_enum, requires = "l1_da_validator")]
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainUpgradeArgs) -> anyhow::Result<()> {
    let bridgehub = args.topology.resolve()?;
    let env_cfg = args.topology.env_config()?;

    // Optional DA validator pair to set atomically with the upgrade. clap's
    // `requires` guarantees the two flags appear together, so a present
    // `l1_da_validator` implies a present `l2_da_commitment_scheme`.
    let da_validator_pair = match (args.l1_da_validator, args.l2_da_commitment_scheme) {
        (Some(l1_da_validator), Some(l2_da_commitment_scheme)) => {
            // The DA validator pair is chain-specific, so it makes no sense to
            // apply the same pair across a multi-chain loop.
            if args.chain_id.is_none() {
                anyhow::bail!(
                    "--l1-da-validator / --l2-da-commitment-scheme require a single --chain-id \
                     (the DA pair is chain-specific and cannot be applied across all chains)"
                );
            }
            Some(DaValidatorPair {
                l1_da_validator,
                l2_da_commitment_scheme,
            })
        }
        _ => None,
    };

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

        run_one(
            bridgehub,
            cid,
            args.access_control_restriction,
            da_validator_pair,
            &shared,
        )
        .await
        .with_context(|| format!("chain {cid} upgrade"))?;
    }

    Ok(())
}

async fn run_one(
    bridgehub: Address,
    chain_id: u64,
    access_control_restriction: Address,
    da_validator_pair: Option<DaValidatorPair>,
    shared: &SharedRunArgs,
) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(shared)?;

    let chain_address =
        crate::common::l1_contracts::resolve_zk_chain(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain diamond proxy from L1")?;
    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    // The Solidity helper executes through ChainAdmin, but broadcasts from
    // ChainAdmin.owner() or the AccessControlRestriction default admin inside adminExecuteCalls.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, access_control_restriction)
        .await?;

    let step_label = if da_validator_pair.is_some() {
        "upgradeChainFromCTMAndSetDAValidatorPair"
    } else {
        "upgradeChainFromCTM"
    };
    logger::step(format!(
        "chain {chain_id}: {step_label} Safe bundle (simulation)"
    ));
    logger::info(format!("Chain address: {:#x}", chain_address));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        access_control_restriction
    ));
    if let Some(pair) = da_validator_pair {
        logger::info(format!("L1 DA validator: {:#x}", pair.l1_da_validator));
        logger::info(format!(
            "L2 DA commitment scheme: {} ({})",
            pair.l2_da_commitment_scheme, pair.l2_da_commitment_scheme as u8,
        ));
    }
    logger::info(format!("RPC URL: {}", shared.l1_rpc_url));

    // `--broadcast` against the anvil fork (applied inside the helper). In this
    // mode the target RPC is the anvil fork, so "broadcast" produces no
    // real-chain effect — it just records the tx in forge's run file so
    // protocol-ops can extract it into the Safe bundle. Without this the Safe
    // output would be empty.
    //
    // When a DA validator pair is supplied, drive the combined entrypoint so the
    // upgrade and `setDAValidatorPair` execute in one `ChainAdmin.multicall`
    // (one atomic L1 tx) instead of two separate Safe transactions.
    let script = match da_validator_pair {
        Some(pair) => runner.script_call(
            AdminFunctionsAbi::upgradeChainFromCTMAndSetDAValidatorPairCall {
                _chainAddress: chain_address,
                _adminAddr: admin_address,
                _accessControlRestriction: access_control_restriction,
                _l1DaValidator: pair.l1_da_validator,
                _l2DaCommitmentScheme: pair.l2_da_commitment_scheme as u8,
            },
        ),
        None => runner.script_call(AdminFunctionsAbi::upgradeChainFromCTMCall {
            _chainAddress: chain_address,
            _adminAddr: admin_address,
            _accessControlRestriction: access_control_restriction,
        }),
    }
    .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
    .with_wallet(&sender);
    runner
        .run(script)
        .context("Failed to execute forge script for chain upgrade")?;

    crate::common::output::write_output_if_requested(
        "chain.upgrade",
        shared,
        &runner,
        &serde_json::json!({}),
        &ChainUpgradeOutput {
            chain_address,
            admin_address,
            access_control_restriction,
            l1_da_validator: da_validator_pair.map(|p| p.l1_da_validator),
            l2_da_commitment_scheme: da_validator_pair.map(|p| p.l2_da_commitment_scheme),
        },
    )
    .await?;

    logger::success(format!("Chain {chain_id} upgrade prepared"));
    Ok(())
}
