use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::admin_functions::IAdminFunctions::ChainUpgradeParams;
use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::env_config::default_protocol_ops_out_dir;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::types::{DAValidatorType, L2DACommitmentScheme, PubdataContent};

/// `PubdataPricingMode.Validium` — `getPubdataPricingMode()` on the chain's diamond.
const PRICING_MODE_VALIDIUM: u8 = 1;

/// First minor protocol version at which a validium-priced chain may publish its pubdata through
/// blobs or calldata. Below it, such a chain can only commit the empty no-DA scheme.
const MIN_MINOR_VERSION_WITH_VALIDIUM_DA: u64 = 33;

#[derive(Serialize)]
struct ChainUpgradeOutput {
    chain_address: Address,
    admin_address: Address,
    access_control_restriction: Address,
    /// What the upgrade changes about the chain's DA setup, if anything.
    da_move: DaMove,
}

/// The DA half of a chain upgrade: what the same `ChainAdmin.multicall` sets after the cut. The
/// two axes are independent here too — an upgrade may move where the pubdata goes, how much of it
/// there is, or both.
#[derive(Clone, Copy, Debug, Default, Serialize)]
struct DaMove {
    /// `None` leaves the chain's DA validator pair as it is.
    pair: Option<DaPair>,
    /// `None` leaves the chain's pubdata content as the upgrade leaves it. Always `None` on Era,
    /// which has no such axis.
    pubdata_content: Option<PubdataContent>,
}

/// The DA validator pair a chain commits through.
#[derive(Clone, Copy, Debug, Serialize)]
struct DaPair {
    l1_da_validator: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
}

/// Chain-level CTM upgrade, prepare-only.
///
/// Drives `AdminFunctions.s.sol::upgradeChainFromCTM(params)` against a forked
/// anvil (auto-impersonation), emits a Gnosis Safe Transaction Builder JSON
/// bundle via `--out`, and never broadcasts. Replay the bundle via
/// `protocol-ops dev execute-safe` (or any Safe-bundle-aware executor) to apply
/// it.
///
/// The bundle is a single `ChainAdmin.multicall`: the diamond cut, and — with
/// `--da-mode` — the DA validator pair and the pubdata content that mode implies. Keeping them in one transaction matters for a validium going to v33:
/// between the cut and a separate DA transaction the chain would commit batches
/// under a DA setup its new version no longer settles.
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

    /// What kind of chain this should be after the upgrade, as far as its pubdata is concerned.
    /// The delivery scheme and the pubdata content default from it and the chain's VM, and either
    /// can be named explicitly with the two flags below. Requires `--l1-da-validator`.
    ///
    /// For chains that settle on a gateway use `chain gateway migrate-to`: the schemes differ.
    #[clap(long, value_enum, requires = "l1_da_validator", help_heading = "DA")]
    pub da_mode: Option<DAValidatorType>,

    /// L1 DA validator to run after the upgrade — the one the ecosystem upgrade deployed for
    /// `--da-mode`. Only meaningful together with it.
    #[clap(long, requires = "da_mode", help_heading = "DA")]
    pub l1_da_validator: Option<Address>,

    /// How the chain's committed pubdata reaches L1 after the upgrade, when it is not the blobs
    /// `--da-mode` defaults to on ZKsync OS.
    #[clap(long, value_enum, help_heading = "DA")]
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,

    /// Take a validium-priced chain to v33 or beyond in a state that is not the recommended one:
    /// logs-only pubdata that the chain actually delivers. Without this, such an upgrade is
    /// refused rather than prepared.
    #[clap(long, default_value_t = false, help_heading = "DA")]
    pub acknowledge_unrecommended_noda: bool,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
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

        run_one(bridgehub, cid, &args, &shared)
            .await
            .with_context(|| format!("chain {cid} upgrade"))?;
    }

    Ok(())
}

async fn run_one(
    bridgehub: Address,
    chain_id: u64,
    args: &ChainUpgradeArgs,
    shared: &SharedRunArgs,
) -> anyhow::Result<()> {
    let access_control_restriction = args.access_control_restriction;
    let mut runner = ForgeRunner::new(shared)?;

    let chain_address =
        crate::common::l1_contracts::resolve_zk_chain(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain diamond proxy from L1")?;
    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    let da_move = resolve_da_move(&runner.rpc_url, bridgehub, chain_id, chain_address, args)
        .await
        .context("resolving the DA setup for the upgrade")?;

    // The Solidity helper executes through ChainAdmin, but broadcasts from
    // ChainAdmin.owner() or the AccessControlRestriction default admin inside adminExecuteCalls.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, access_control_restriction)
        .await?;

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
    logger::info(format!(
        "DA after the upgrade: pair {}, pubdata content {}",
        da_move
            .pair
            .map(|p| format!(
                "validator {:#x} + scheme {}",
                p.l1_da_validator, p.l2_da_commitment_scheme
            ))
            .unwrap_or_else(|| "unchanged".to_string()),
        da_move
            .pubdata_content
            .map(|c| c.to_string())
            .unwrap_or_else(|| "unchanged".to_string())
    ));

    // `--broadcast` against the anvil fork (applied inside the helper). In this
    // mode the target RPC is the anvil fork, so "broadcast" produces no
    // real-chain effect — it just records the tx in forge's run file so
    // protocol-ops can extract it into the Safe bundle. Without this the Safe
    // output would be empty.
    let script = runner
        .script_call(AdminFunctionsAbi::upgradeChainFromCTMCall {
            _params: ChainUpgradeParams {
                chainAddress: chain_address,
                adminAddr: admin_address,
                accessControlRestriction: access_control_restriction,
                l1DaValidator: da_move
                    .pair
                    .map(|p| p.l1_da_validator)
                    .unwrap_or(Address::ZERO),
                l2DaCommitmentScheme: da_move
                    .pair
                    .map(|p| p.l2_da_commitment_scheme)
                    .unwrap_or(L2DACommitmentScheme::None)
                    as u8,
                pubdataContent: da_move.pubdata_content.unwrap_or_default() as u8,
                shouldSetDaValidatorPair: da_move.pair.is_some(),
                shouldSetPubdataContent: da_move.pubdata_content.is_some(),
            },
        })
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
            da_move,
        },
    )
    .await?;

    logger::success(format!("Chain {chain_id} upgrade prepared"));
    Ok(())
}

/// Work out what the upgrade should do to the chain's DA setup.
///
/// `--da-mode` names the target and everything else follows from it and the chain's VM, so the
/// pair and the content cannot end up disagreeing. Without it the upgrade leaves the DA setup
/// alone — except for a validium-priced chain crossing into a version that requires it to publish,
/// which is refused rather than upgraded into a state where its batches stop proving.
async fn resolve_da_move(
    l1_rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
    chain_address: Address,
    args: &ChainUpgradeArgs,
) -> anyhow::Result<DaMove> {
    let ctm = crate::common::l1_contracts::resolve_ctm_proxy(l1_rpc_url, bridgehub, chain_id)
        .await
        .context("resolving CTM from L1")?;
    let vm_type = crate::common::l1_contracts::resolve_vm_type(l1_rpc_url, ctm)
        .await
        .context("resolving the chain's VM from the CTM")?;

    let pair = match args.da_mode {
        Some(da_mode) => Some(DaPair {
            l1_da_validator: args
                .l1_da_validator
                .context("--da-mode requires --l1-da-validator")?,
            l2_da_commitment_scheme: args
                .l2_da_commitment_scheme
                .unwrap_or_else(|| L2DACommitmentScheme::from_da_and_vm_types(da_mode, vm_type)),
        }),
        None => None,
    };
    // Follows from the kind of chain `--da-mode` says it now is; it has no knob of its own.
    let pubdata_content = args
        .da_mode
        .and_then(|da_mode| PubdataContent::from_da_and_vm_types(da_mode, vm_type));

    let da_move = DaMove {
        pair,
        pubdata_content,
    };
    guard_unrecommended_validium_state(l1_rpc_url, ctm, chain_id, chain_address, &da_move, args)
        .await?;
    Ok(da_move)
}

/// Refuse to prepare an upgrade that leaves a validium-priced chain in an unrecommended state
/// from [`MIN_MINOR_VERSION_WITH_VALIDIUM_DA`] on.
///
/// The recommended state is the one such a chain can operate in: it commits only the log region
/// ([`PubdataContent::LogsOnly`]) and actually delivers it, through blobs or a keccak256 scheme.
/// The two ways to miss it differ in how badly:
///
/// - committing full pubdata while delivering nothing is not merely unrecommended, it does not
///   prove — the content and the scheme are both in the batch's chain-config hash;
/// - committing the log region while delivering nothing does prove, but nothing the chain
///   committed can be read back from L1, its interop commitment tree leaves included.
///
/// Both are refused unless the caller acknowledges the second one with
/// `--acknowledge-unrecommended-noda`.
async fn guard_unrecommended_validium_state(
    l1_rpc_url: &str,
    ctm: Address,
    chain_id: u64,
    chain_address: Address,
    da_move: &DaMove,
    args: &ChainUpgradeArgs,
) -> anyhow::Result<()> {
    let pricing_mode =
        crate::common::l1_contracts::resolve_pubdata_pricing_mode(l1_rpc_url, chain_address)
            .await?;
    if pricing_mode != PRICING_MODE_VALIDIUM {
        return Ok(());
    }
    let new_minor =
        crate::common::l1_contracts::resolve_ctm_minor_protocol_version(l1_rpc_url, ctm).await?;
    if new_minor < MIN_MINOR_VERSION_WITH_VALIDIUM_DA {
        return Ok(());
    }

    // What the chain runs once this upgrade lands: what the bundle sets, or what it already has
    // where the bundle sets nothing. A chain arriving at the version that introduces the pubdata
    // content gets that version's default, `FULL_PUBDATA`.
    let scheme = match da_move.pair {
        Some(pair) => pair.l2_da_commitment_scheme,
        None => {
            crate::common::l1_contracts::resolve_l2_da_commitment_scheme(l1_rpc_url, chain_address)
                .await?
        }
    };
    let content = da_move
        .pubdata_content
        .unwrap_or(PubdataContent::FullPubdata);
    let delivers = !matches!(
        scheme,
        L2DACommitmentScheme::EmptyNoDA | L2DACommitmentScheme::None
    );

    if content == PubdataContent::LogsOnly && delivers {
        return Ok(());
    }
    anyhow::ensure!(
        content == PubdataContent::LogsOnly,
        "this upgrade would take chain {chain_id} to v{new_minor} committing {content} while its \
         DA scheme is {scheme} — batches in that state do not prove. Pass \
         `--da-mode logs-only-validium --l1-da-validator <address>` so it commits the log region \
         and delivers it"
    );
    anyhow::ensure!(
        args.acknowledge_unrecommended_noda,
        "this upgrade would take chain {chain_id} to v{new_minor} committing {content} but \
         delivering nothing ({scheme}), so nothing it commits can be read back from L1 — its \
         interop commitment tree leaves included. Give it a delivering scheme (blobs is what \
         `--da-mode logs-only-validium` derives), or pass \
         `--acknowledge-unrecommended-noda` to prepare it anyway"
    );
    Ok(())
}
