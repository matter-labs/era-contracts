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
    /// The DA setup the upgrade puts the chain on, when it moves it at all.
    da_move: Option<DaMove>,
}

/// The DA half of a chain upgrade: what the same `ChainAdmin.multicall` sets after the cut.
#[derive(Clone, Copy, Debug, Serialize)]
struct DaMove {
    l1_da_validator: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
    /// `None` on Era, which has no pubdata-content axis.
    pubdata_content: Option<PubdataContent>,
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
/// `--da-mode` — the DA validator pair and pubdata content the chain runs after
/// it. Keeping them in one transaction matters for a validium going to v33:
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

    /// Where the chain's pubdata goes after the upgrade. Set it to move the chain's DA setup as
    /// part of the upgrade; the L2 commitment scheme and the pubdata content then default from it
    /// and the chain's VM, and either can be named explicitly with the two flags below — the two
    /// axes are independent. Requires `--l1-da-validator`.
    ///
    /// For chains that settle on a gateway use `chain gateway migrate-to`: the schemes differ.
    #[clap(long, value_enum, requires = "l1_da_validator", help_heading = "DA")]
    pub da_mode: Option<DAValidatorType>,

    /// L1 DA validator to run after the upgrade — the one the ecosystem upgrade deployed for
    /// `--da-mode`. Only meaningful together with it.
    #[clap(long, requires = "da_mode", help_heading = "DA")]
    pub l1_da_validator: Option<Address>,

    /// The L2 DA commitment scheme, when it is not the one `--da-mode` defaults to — a chain on
    /// the rollup validator that publishes through commit-tx calldata rather than blobs takes
    /// `blobs-and-pubdata-keccak256`.
    #[clap(long, value_enum, help_heading = "DA")]
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,

    /// How much pubdata the chain commits after the upgrade, when it is not what `--da-mode`
    /// defaults to. Any combination of the two is allowed: a chain publishing through blobs may
    /// commit `logs-only`, and one publishing nothing may still commit `full-pubdata`.
    #[clap(long, value_enum, help_heading = "DA")]
    pub pubdata_content: Option<PubdataContent>,

    /// Upgrade a validium-priced chain past the version that requires it to publish its pubdata,
    /// leaving its DA setup alone. Such a chain stops producing provable batches — pass this only
    /// when the move is applied by other means, or deliberately.
    #[clap(long, default_value_t = false, help_heading = "DA")]
    pub keep_da_setup: bool,

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
    match da_move {
        Some(m) => logger::info(format!(
            "DA after the upgrade: validator {:#x}, scheme {}, pubdata content {}",
            m.l1_da_validator,
            m.l2_da_commitment_scheme,
            m.pubdata_content
                .map(|c| c.to_string())
                .unwrap_or_else(|| "unchanged".to_string())
        )),
        None => logger::info("DA setup: unchanged".to_string()),
    }

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
                l1DaValidator: da_move.map(|m| m.l1_da_validator).unwrap_or(Address::ZERO),
                l2DaCommitmentScheme: da_move
                    .map(|m| m.l2_da_commitment_scheme)
                    .unwrap_or(L2DACommitmentScheme::None)
                    as u8,
                pubdataContent: da_move.and_then(|m| m.pubdata_content).unwrap_or_default() as u8,
                shouldSetDaValidatorPair: da_move.is_some(),
                shouldSetPubdataContent: da_move.is_some_and(|m| m.pubdata_content.is_some()),
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
) -> anyhow::Result<Option<DaMove>> {
    let ctm = crate::common::l1_contracts::resolve_ctm_proxy(l1_rpc_url, bridgehub, chain_id)
        .await
        .context("resolving CTM from L1")?;
    let vm_type = crate::common::l1_contracts::resolve_vm_type(l1_rpc_url, ctm)
        .await
        .context("resolving the chain's VM from the CTM")?;

    let Some(da_mode) = args.da_mode else {
        guard_validium_without_da(l1_rpc_url, ctm, chain_id, chain_address, args).await?;
        return Ok(None);
    };

    let l1_da_validator = args
        .l1_da_validator
        .context("--da-mode requires --l1-da-validator")?;
    Ok(Some(DaMove {
        l1_da_validator,
        l2_da_commitment_scheme: args
            .l2_da_commitment_scheme
            .unwrap_or_else(|| L2DACommitmentScheme::from_da_and_vm_types(da_mode, vm_type)),
        pubdata_content: args
            .pubdata_content
            .or_else(|| PubdataContent::from_da_and_vm_types(da_mode, vm_type)),
    }))
}

/// Refuse to take a validium-priced chain past [`MIN_MINOR_VERSION_WITH_VALIDIUM_DA`] while its
/// DA setup is left untouched. Such a chain lands on the version's default pubdata content while
/// publishing nothing, which is the configuration whose batches were observed not to prove; and
/// its L2->L1 log region — the interop commitment tree leaves included — never reaches L1.
async fn guard_validium_without_da(
    l1_rpc_url: &str,
    ctm: Address,
    chain_id: u64,
    chain_address: Address,
    args: &ChainUpgradeArgs,
) -> anyhow::Result<()> {
    if args.keep_da_setup {
        return Ok(());
    }

    let pricing_mode =
        crate::common::l1_contracts::resolve_pubdata_pricing_mode(l1_rpc_url, chain_address)
            .await?;
    if pricing_mode != PRICING_MODE_VALIDIUM {
        return Ok(());
    }

    let new_minor =
        crate::common::l1_contracts::resolve_ctm_minor_protocol_version(l1_rpc_url, ctm).await?;
    anyhow::ensure!(
        new_minor < MIN_MINOR_VERSION_WITH_VALIDIUM_DA,
        "chain {chain_id} is validium-priced and this upgrade takes it to v{new_minor}, which \
         gives it a pubdata content it does not publish — a configuration whose batches do not \
         settle. Pass `--da-mode`/`--pubdata-content` (with `--l1-da-validator`) to name its DA \
         setup as part of the upgrade, or `--keep-da-setup` to leave it alone deliberately"
    );
    Ok(())
}
