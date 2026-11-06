use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::admin_functions::IAdminFunctions::ChainUpgradeParams;
use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::types::{DAValidatorType, L2DACommitmentScheme, PubdataContent};

/// `PubdataPricingMode.Validium` — `getPubdataPricingMode()` on the chain's diamond.
const PRICING_MODE_VALIDIUM: u8 = 1;

/// First minor protocol version whose diamond stores the pubdata content (`getPubdataContent()`).
/// From it on, a batch committing full pubdata it does not deliver does not prove, and a
/// validium-priced chain may publish its pubdata through blobs or calldata. Below it, such a chain
/// can only commit the empty no-DA scheme.
const MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT: u64 = 33;

#[derive(Serialize)]
struct ChainUpgradeOutput {
    chain_id: u64,
    chain_address: Address,
    admin_address: Address,
    /// The ChainAdmin's owner, who sends the bundle; absent when an AccessControlRestriction
    /// admin sends it instead. Read by the execution runbook (`EXECUTE.md`).
    #[serde(skip_serializing_if = "Option::is_none")]
    chain_admin_owner: Option<Address>,
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
    /// `None` leaves the chain's pubdata content as the upgrade leaves it.
    pubdata_content: Option<PubdataContent>,
}

impl DaMove {
    /// `self` without a pubdata content write that would leave the chain's `live` content as it
    /// is. `setPubdataContent` reverts on a permanent rollup even for an unchanged value, and
    /// requires every committed batch to be verified.
    fn skipping_unchanged_content(self, live: PubdataContent) -> Self {
        Self {
            pubdata_content: self.pubdata_content.filter(|content| *content != live),
            ..self
        }
    }
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
/// `--da-mode` — the DA validator pair and, when it differs from the chain's, the pubdata content
/// that mode implies. Keeping them in one transaction matters for a validium going to v33:
/// between the cut and a separate DA transaction the chain would commit batches
/// under a DA setup its new version no longer settles.
///
/// From v33 on, the upgrade is refused when the chain would run a DA setup — what the bundle
/// sets, the chain's live one where it sets nothing — that commits full pubdata and delivers
/// nothing (it does not prove), that commits full pubdata through an L1 DA validator that does not
/// check its delivery, that commits the log region and delivers nothing L1 checks (unless
/// `--acknowledge-unrecommended-noda`), or that commits full pubdata on a validium-priced chain.
/// An L1 DA validator checks a blobs or calldata scheme when the chain's `RollupDAManager` allows
/// the pair; for `pubdata-keccak256` any external DA validator is taken on trust, except a rollup
/// one or the no-DA validator the chain runs today.
///
/// Pass `--chain-id` to target a single chain. Omit it to loop over every
/// chain registered on the bridgehub (not with `--da-mode`, which describes one
/// chain) — each chain's bundle lands under
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
    /// The pubdata content follows from it (and is set only when it differs from the chain's);
    /// the delivery scheme defaults from it and can be named with `--l2-da-commitment-scheme`.
    /// Requires `--l1-da-validator`. Omitted, the bundle leaves the chain's DA setup as it is.
    #[clap(long, value_enum, requires = "l1_da_validator", help_heading = "DA")]
    pub da_mode: Option<DAValidatorType>,

    /// L1 DA validator to run after the upgrade — the one the ecosystem upgrade deployed for
    /// `--da-mode`. Only meaningful together with it. On an upgrade to v33 or later it must check
    /// the scheme's delivery: for blobs and calldata schemes, a pair the chain's `RollupDAManager`
    /// allows; for `pubdata-keccak256`, an external DA validator.
    #[clap(long, requires = "da_mode", help_heading = "DA")]
    pub l1_da_validator: Option<Address>,

    /// How the chain's committed pubdata reaches L1 after the upgrade, when it is not the scheme
    /// `--da-mode` defaults to. Requires `--da-mode`: the scheme is set together with the L1 DA
    /// validator that checks it. `none` is refused (the chain cannot be set to it). On an upgrade
    /// to v33 or later, `discouraged-empty-no-da` is refused with full pubdata (it does not prove)
    /// and, with logs-only pubdata, unless `--acknowledge-unrecommended-noda` is passed.
    #[clap(long, value_enum, requires = "da_mode", help_heading = "DA")]
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,

    /// Prepare an upgrade to v33 or beyond after which the chain commits logs-only pubdata but
    /// delivers nothing L1 checks (`discouraged-empty-no-da`, or an L1 DA validator that does not
    /// check the scheme), so nothing it commits can be read back from L1. Without this, such an
    /// upgrade is refused rather than prepared. It never lifts the refusal of full pubdata
    /// delivered nothing.
    #[clap(long, default_value_t = false, help_heading = "DA")]
    pub acknowledge_unrecommended_noda: bool,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainUpgradeArgs) -> anyhow::Result<()> {
    let bridgehub = args.topology.resolve()?;
    let env_cfg = args.topology.env_config()?;

    // The DA setup is chain-specific — which validator, which scheme and whether the chain
    // publishes its pubdata at all — so one `--da-mode` cannot describe every chain of a
    // multi-chain loop.
    anyhow::ensure!(
        args.da_mode.is_none() || args.chain_id.is_some(),
        "--da-mode / --l1-da-validator require a single --chain-id (the DA setup is \
         chain-specific and cannot be applied across all chains)"
    );

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
                    cfg.protocol_ops_out_dir()
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
            chain_id,
            chain_address,
            admin_address,
            chain_admin_owner: (access_control_restriction == Address::ZERO)
                .then_some(sender.address),
            access_control_restriction,
            da_move,
        },
    )
    .await?;

    logger::success(format!("Chain {chain_id} upgrade prepared"));
    Ok(())
}

/// Work out what the upgrade should do to the chain's DA setup, refusing a setup the chain should
/// not run once the upgrade lands ([`check_da_after_upgrade`]).
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
    crate::common::l1_contracts::ensure_supported_os_ctm(l1_rpc_url, ctm).await?;

    let requested = requested_da_move(
        args.da_mode,
        args.l1_da_validator,
        args.l2_da_commitment_scheme,
    )?;
    let new_minor =
        crate::common::l1_contracts::resolve_ctm_minor_protocol_version(l1_rpc_url, ctm).await?;
    let live = read_live_da(l1_rpc_url, chain_address).await?;
    let da_move = requested.skipping_unchanged_content(live.content);
    let rollup_pairs = read_rollup_pairs(
        l1_rpc_url,
        chain_address,
        EffectiveDa::after(&da_move, live).l1_da_validator,
    )
    .await?;
    check_da_after_upgrade(
        chain_id,
        new_minor,
        &da_move,
        live,
        rollup_pairs,
        args.acknowledge_unrecommended_noda,
    )?;
    Ok(da_move)
}

/// The DA half of the bundle as the flags ask for it.
///
/// `--da-mode` names the target and everything else follows from it, so the pair and the content
/// cannot end up disagreeing. Without it the bundle leaves the chain's DA setup alone.
fn requested_da_move(
    da_mode: Option<DAValidatorType>,
    l1_da_validator: Option<Address>,
    l2_da_commitment_scheme: Option<L2DACommitmentScheme>,
) -> anyhow::Result<DaMove> {
    let Some(da_mode) = da_mode else {
        // clap enforces this too; `ChainUpgradeArgs` is also `Deserialize`.
        anyhow::ensure!(
            l1_da_validator.is_none() && l2_da_commitment_scheme.is_none(),
            "--l1-da-validator and --l2-da-commitment-scheme require --da-mode: the bundle sets the \
             DA validator pair only as a whole, for the mode the chain moves to"
        );
        return Ok(DaMove::default());
    };
    let l2_da_commitment_scheme =
        l2_da_commitment_scheme.unwrap_or_else(|| L2DACommitmentScheme::from_da_type(da_mode));
    anyhow::ensure!(
        l2_da_commitment_scheme != L2DACommitmentScheme::None,
        "--l2-da-commitment-scheme none is not a scheme a chain can be set to \
         (`setDAValidatorPair` rejects it)"
    );
    Ok(DaMove {
        pair: Some(DaPair {
            l1_da_validator: l1_da_validator.context("--da-mode requires --l1-da-validator")?,
            l2_da_commitment_scheme,
        }),
        // Follows from the kind of chain `--da-mode` says it now is; it has no knob of its own.
        pubdata_content: Some(PubdataContent::from_da_type(da_mode)),
    })
}

/// The chain's DA setup before the upgrade.
#[derive(Clone, Copy, Debug)]
struct LiveDa {
    validium_priced: bool,
    l1_da_validator: Address,
    scheme: L2DACommitmentScheme,
    /// The stored content, or — on a chain that predates
    /// [`MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT`] — the default it gets on arriving there. The
    /// upgrade itself never writes it.
    content: PubdataContent,
}

async fn read_live_da(l1_rpc_url: &str, chain_address: Address) -> anyhow::Result<LiveDa> {
    use crate::common::l1_contracts as l1;

    let validium_priced =
        l1::resolve_pubdata_pricing_mode(l1_rpc_url, chain_address).await? == PRICING_MODE_VALIDIUM;
    let (l1_da_validator, scheme) =
        l1::resolve_da_validator_pair(l1_rpc_url, chain_address).await?;
    let chain_minor = l1::resolve_chain_minor_protocol_version(l1_rpc_url, chain_address).await?;
    let content = if stores_pubdata_content(chain_minor) {
        l1::resolve_pubdata_content(l1_rpc_url, chain_address).await?
    } else {
        PubdataContent::default()
    };
    Ok(LiveDa {
        validium_priced,
        l1_da_validator,
        scheme,
        content,
    })
}

/// Whether a diamond at minor version `chain_minor` stores the pubdata content and exposes
/// `getPubdataContent()`.
fn stores_pubdata_content(chain_minor: u64) -> bool {
    chain_minor >= MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT
}

/// The L1-delivery schemes the chain's `RollupDAManager` allows an L1 DA validator for.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct RollupPairs {
    /// `isPairAllowed(validator, BLOBS_ZKSYNC_OS)`.
    blobs: bool,
    /// `isPairAllowed(validator, BLOBS_AND_PUBDATA_KECCAK256)`: commit-tx calldata on ZKsync OS.
    calldata: bool,
}

/// Read [`RollupPairs`] for `l1_da_validator` from the manager the chain's Admin facet pins today.
/// The ecosystem upgrade pins the same one into the new facet unless its config overrides it.
async fn read_rollup_pairs(
    l1_rpc_url: &str,
    chain_address: Address,
    l1_da_validator: Address,
) -> anyhow::Result<RollupPairs> {
    use crate::common::l1_contracts as l1;

    let manager = l1::resolve_rollup_da_manager(l1_rpc_url, chain_address).await?;
    let allowed =
        |scheme| l1::is_rollup_da_pair_allowed(l1_rpc_url, manager, l1_da_validator, scheme);
    Ok(RollupPairs {
        blobs: allowed(L2DACommitmentScheme::BlobsZKSyncOS).await?,
        calldata: allowed(L2DACommitmentScheme::BlobsAndPubdataKeccak256).await?,
    })
}

/// The DA setup the chain runs once the bundle has landed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct EffectiveDa {
    content: PubdataContent,
    scheme: L2DACommitmentScheme,
    l1_da_validator: Address,
    /// The chain commits through `l1_da_validator` today with the empty no-DA scheme, so it is a
    /// validator that checks no delivery.
    no_da_validator: bool,
}

impl EffectiveDa {
    /// What `da_move` sets, and the chain's live setup for what it leaves alone.
    fn after(da_move: &DaMove, live: LiveDa) -> Self {
        let (l1_da_validator, scheme) = da_move
            .pair
            .map_or((live.l1_da_validator, live.scheme), |pair| {
                (pair.l1_da_validator, pair.l2_da_commitment_scheme)
            });
        Self {
            content: da_move.pubdata_content.unwrap_or(live.content),
            scheme,
            l1_da_validator,
            no_da_validator: live.scheme == L2DACommitmentScheme::EmptyNoDA
                && live.l1_da_validator == l1_da_validator,
        }
    }

    /// `rollup_pairs` is what the chain's `RollupDAManager` allows `self.l1_da_validator` for.
    fn delivery(self, rollup_pairs: RollupPairs) -> Delivery {
        use L2DACommitmentScheme as S;

        let checked = match self.scheme {
            S::None | S::EmptyNoDA => return Delivery::Nothing,
            S::BlobsZKSyncOS => rollup_pairs.blobs,
            S::BlobsAndPubdataKeccak256 => rollup_pairs.calldata,
            // No registry lists external DA validators: any other validator is taken on trust.
            S::PubdataKeccak256 => {
                !(self.no_da_validator || rollup_pairs.blobs || rollup_pairs.calldata)
            }
        };
        if checked {
            Delivery::Checked
        } else {
            Delivery::Unchecked
        }
    }
}

/// Whether L1 checks that a chain delivers what it commits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Delivery {
    /// The scheme delivers nothing.
    Nothing,
    /// The scheme delivers, but the L1 DA validator does not check it, so a batch whose pubdata
    /// was never delivered is accepted all the same.
    Unchecked,
    /// The L1 DA validator checks the scheme's delivery.
    Checked,
}

/// How the guard rates the DA setup a chain runs from [`MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT`]
/// on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DaVerdict {
    /// Proves, and L1 checks it delivers what the chain commits.
    Accepted,
    /// Full pubdata committed, nothing delivered: the chain's batches do not prove.
    NotProving,
    /// Full pubdata committed through a scheme whose delivery the L1 DA validator does not check.
    /// The batches prove, but nothing L1 checks is delivered.
    FullPubdataUnchecked,
    /// The log region committed, nothing L1 checks delivered: the batches prove, but nothing the
    /// chain commits can be read back from L1, its interop commitment tree leaves included.
    /// Prepared only with `--acknowledge-unrecommended-noda`.
    DeliversNothing,
    /// A validium-priced chain committing full pubdata. The state such a chain is prepared into is
    /// the log region, delivered.
    ValidiumWithFullPubdata,
}

/// Rate `da` for a chain whose pubdata pricing mode is validium iff `validium_priced`, where
/// `rollup_pairs` is what its `RollupDAManager` allows `da.l1_da_validator` for.
fn classify_da(da: EffectiveDa, rollup_pairs: RollupPairs, validium_priced: bool) -> DaVerdict {
    use PubdataContent::{FullPubdata, LogsOnly};

    match (da.content, da.delivery(rollup_pairs)) {
        (FullPubdata, Delivery::Nothing) => DaVerdict::NotProving,
        (FullPubdata, Delivery::Unchecked) => DaVerdict::FullPubdataUnchecked,
        (LogsOnly, Delivery::Nothing | Delivery::Unchecked) => DaVerdict::DeliversNothing,
        (FullPubdata, Delivery::Checked) if validium_priced => DaVerdict::ValidiumWithFullPubdata,
        (FullPubdata | LogsOnly, Delivery::Checked) => DaVerdict::Accepted,
    }
}

/// Refuse to prepare an upgrade to `new_minor` after which chain `chain_id` runs a DA setup the
/// guard does not accept ([`DaVerdict`]). Below [`MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT`] every
/// setup is accepted.
fn check_da_after_upgrade(
    chain_id: u64,
    new_minor: u64,
    da_move: &DaMove,
    live: LiveDa,
    rollup_pairs: RollupPairs,
    acknowledge_unrecommended_noda: bool,
) -> anyhow::Result<()> {
    if new_minor < MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT {
        return Ok(());
    }
    let da = EffectiveDa::after(da_move, live);
    let EffectiveDa {
        content,
        scheme,
        l1_da_validator: validator,
        ..
    } = da;
    match classify_da(da, rollup_pairs, live.validium_priced) {
        DaVerdict::Accepted => Ok(()),
        DaVerdict::DeliversNothing if acknowledge_unrecommended_noda => Ok(()),
        DaVerdict::NotProving => anyhow::bail!(
            "this upgrade would take chain {chain_id} to v{new_minor} committing {content} while its \
             DA scheme is {scheme}, which delivers nothing — batches in that state do not prove, \
             whatever `--acknowledge-unrecommended-noda` says. Pass `--da-mode <mode> \
             --l1-da-validator <address>` with a delivering scheme (`--da-mode logs-only-validium` \
             for a validium)"
        ),
        DaVerdict::FullPubdataUnchecked => anyhow::bail!(
            "this upgrade would take chain {chain_id} to v{new_minor} committing {content} through \
             {scheme}, but L1 DA validator {validator:#x} does not check that delivery, so L1 would \
             accept batches whose pubdata was never delivered — whatever \
             `--acknowledge-unrecommended-noda` says. For a blobs or calldata scheme the validator \
             must be a pair the chain's RollupDAManager allows; for pubdata-keccak256, an external \
             DA validator (not a rollup one, nor the no-DA validator the chain runs today). Pass \
             `--l1-da-validator` with the one the ecosystem deployed for the scheme"
        ),
        DaVerdict::DeliversNothing => anyhow::bail!(
            "this upgrade would take chain {chain_id} to v{new_minor} committing {content} but \
             delivering nothing L1 checks (scheme {scheme}, L1 DA validator {validator:#x}), so \
             nothing it commits can be read back from L1 — its interop commitment tree leaves \
             included. Give it a delivering scheme and the L1 DA validator that checks it (blobs is \
             what `--da-mode logs-only-validium` derives), or pass \
             `--acknowledge-unrecommended-noda` to prepare it anyway"
        ),
        DaVerdict::ValidiumWithFullPubdata => anyhow::bail!(
            "this upgrade would take validium-priced chain {chain_id} to v{new_minor} committing \
             {content} (DA scheme {scheme}); a validium-priced chain is prepared only committing \
             the log region and delivering it. Pass `--da-mode logs-only-validium \
             --l1-da-validator <address>`, or move the chain to rollup pricing first if it is \
             becoming a rollup"
        ),
    }
}

#[cfg(test)]
mod tests {
    use clap::ValueEnum;

    use super::*;

    const CHAIN_ID: u64 = 1;
    /// A target version the guard applies to.
    const NEW_MINOR: u64 = MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT + 2;

    /// The validator `--l1-da-validator` names.
    fn l1_da_validator() -> Address {
        Address::repeat_byte(0x11)
    }

    /// The validator the chain runs today, unless a test says otherwise.
    fn live_l1_da_validator() -> Address {
        Address::repeat_byte(0x22)
    }

    /// What the `RollupDAManager` allows the validator the ecosystem deployed for `scheme` for. The
    /// external-DA and no-DA validators are allowed for nothing.
    fn deployed_for(scheme: L2DACommitmentScheme) -> RollupPairs {
        RollupPairs {
            blobs: scheme == L2DACommitmentScheme::BlobsZKSyncOS,
            calldata: scheme == L2DACommitmentScheme::BlobsAndPubdataKeccak256,
        }
    }

    /// The CLI spelling of a value-enum variant.
    fn cli_name<T: ValueEnum>(value: T) -> String {
        value
            .to_possible_value()
            .expect("no variant is hidden")
            .get_name()
            .to_string()
    }

    fn parse(flags: &[String]) -> Result<ChainUpgradeArgs, clap::Error> {
        let argv = ["upgrade", "--chain-id", "1"]
            .into_iter()
            .map(String::from)
            .chain(flags.iter().cloned());
        ChainUpgradeArgs::try_parse_from(argv)
    }

    /// The DA move the CLI builds from `--da-mode <mode> --l1-da-validator <validator>
    /// [--l2-da-commitment-scheme <scheme>]`.
    fn cli_da_move_with(
        da_mode: DAValidatorType,
        scheme: Option<L2DACommitmentScheme>,
        validator: Address,
    ) -> anyhow::Result<DaMove> {
        let mut flags = vec![
            "--da-mode".to_string(),
            cli_name(da_mode),
            "--l1-da-validator".to_string(),
            format!("{validator:#x}"),
        ];
        if let Some(scheme) = scheme {
            flags.extend(["--l2-da-commitment-scheme".to_string(), cli_name(scheme)]);
        }
        let args = parse(&flags).expect("the CLI accepts every --da-mode/scheme pair");
        requested_da_move(
            args.da_mode,
            args.l1_da_validator,
            args.l2_da_commitment_scheme,
        )
    }

    fn cli_da_move(
        da_mode: DAValidatorType,
        scheme: Option<L2DACommitmentScheme>,
    ) -> anyhow::Result<DaMove> {
        cli_da_move_with(da_mode, scheme, l1_da_validator())
    }

    fn live_on(
        validium_priced: bool,
        content: PubdataContent,
        l1_da_validator: Address,
        scheme: L2DACommitmentScheme,
    ) -> LiveDa {
        LiveDa {
            validium_priced,
            l1_da_validator,
            scheme,
            content,
        }
    }

    fn live(
        validium_priced: bool,
        content: PubdataContent,
        scheme: L2DACommitmentScheme,
    ) -> LiveDa {
        live_on(validium_priced, content, live_l1_da_validator(), scheme)
    }

    /// The guard rates `da_move` on `live` as `verdict`, and prepares it exactly when that verdict
    /// allows, with and without the acknowledgement.
    fn assert_verdict(
        da_move: &DaMove,
        live: LiveDa,
        rollup_pairs: RollupPairs,
        verdict: DaVerdict,
        what: &str,
    ) {
        let check = |acknowledged| {
            check_da_after_upgrade(
                CHAIN_ID,
                NEW_MINOR,
                da_move,
                live,
                rollup_pairs,
                acknowledged,
            )
        };
        assert_eq!(
            classify_da(
                EffectiveDa::after(da_move, live),
                rollup_pairs,
                live.validium_priced
            ),
            verdict,
            "{what}"
        );
        assert_eq!(
            check(false).is_ok(),
            verdict == DaVerdict::Accepted,
            "{what}, unacknowledged"
        );
        assert_eq!(
            check(true).is_ok(),
            matches!(verdict, DaVerdict::Accepted | DaVerdict::DeliversNothing),
            "{what}, acknowledged"
        );
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Expected {
        /// `requested_da_move` refuses the flags before the guard runs.
        InvalidScheme,
        Verdict(DaVerdict),
    }

    /// Every `--da-mode` × `--l2-da-commitment-scheme` pair the CLI accepts, with the guard's
    /// verdict:
    ///
    /// - with the L1 DA validator the ecosystem deployed for the scheme, on a rollup-priced and on
    ///   a validium-priced chain. The bundle sets the whole DA setup here, so the chain's live one
    ///   must not change the verdict;
    /// - with the validator the chain runs today with the empty no-DA scheme (the
    ///   `ValidiumL1DAValidator` a pre-v33 validium has), which checks no delivery, on either
    ///   pricing.
    #[test]
    fn every_cli_da_pair_gets_the_documented_verdict() {
        use DAValidatorType as M;
        use DaVerdict::*;
        use Expected::{InvalidScheme, Verdict};
        use L2DACommitmentScheme as S;

        // (da mode, scheme flag, rollup-priced, validium-priced, with the no-DA validator)
        #[rustfmt::skip]
        let table: [(M, Option<S>, Expected, Expected, Expected); 24] = [
            (M::Rollup, None, Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Rollup, Some(S::None), InvalidScheme, InvalidScheme, InvalidScheme),
            (M::Rollup, Some(S::EmptyNoDA), Verdict(NotProving), Verdict(NotProving), Verdict(NotProving)),
            (M::Rollup, Some(S::PubdataKeccak256), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Rollup, Some(S::BlobsAndPubdataKeccak256), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Rollup, Some(S::BlobsZKSyncOS), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::LogsOnlyValidium, None, Verdict(Accepted), Verdict(Accepted), Verdict(DeliversNothing)),
            (M::LogsOnlyValidium, Some(S::None), InvalidScheme, InvalidScheme, InvalidScheme),
            (M::LogsOnlyValidium, Some(S::EmptyNoDA), Verdict(DeliversNothing), Verdict(DeliversNothing), Verdict(DeliversNothing)),
            (M::LogsOnlyValidium, Some(S::PubdataKeccak256), Verdict(Accepted), Verdict(Accepted), Verdict(DeliversNothing)),
            (M::LogsOnlyValidium, Some(S::BlobsAndPubdataKeccak256), Verdict(Accepted), Verdict(Accepted), Verdict(DeliversNothing)),
            (M::LogsOnlyValidium, Some(S::BlobsZKSyncOS), Verdict(Accepted), Verdict(Accepted), Verdict(DeliversNothing)),
            (M::Avail, None, Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Avail, Some(S::None), InvalidScheme, InvalidScheme, InvalidScheme),
            (M::Avail, Some(S::EmptyNoDA), Verdict(NotProving), Verdict(NotProving), Verdict(NotProving)),
            (M::Avail, Some(S::PubdataKeccak256), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Avail, Some(S::BlobsAndPubdataKeccak256), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Avail, Some(S::BlobsZKSyncOS), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Eigen, None, Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Eigen, Some(S::None), InvalidScheme, InvalidScheme, InvalidScheme),
            (M::Eigen, Some(S::EmptyNoDA), Verdict(NotProving), Verdict(NotProving), Verdict(NotProving)),
            (M::Eigen, Some(S::PubdataKeccak256), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Eigen, Some(S::BlobsAndPubdataKeccak256), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
            (M::Eigen, Some(S::BlobsZKSyncOS), Verdict(Accepted), Verdict(ValidiumWithFullPubdata), Verdict(FullPubdataUnchecked)),
        ];

        // The table covers exactly the pairs the CLI accepts: a new variant must get a row.
        let scheme_flags: Vec<Option<S>> = std::iter::once(None)
            .chain(S::value_variants().iter().copied().map(Some))
            .collect();
        for &mode in M::value_variants() {
            for &scheme in &scheme_flags {
                let rows = table
                    .iter()
                    .filter(|(m, s, ..)| *m == mode && *s == scheme)
                    .count();
                assert_eq!(rows, 1, "--da-mode {mode:?} with scheme {scheme:?}");
            }
        }
        assert_eq!(table.len(), M::value_variants().len() * scheme_flags.len());

        for (mode, scheme, on_rollup_pricing, on_validium_pricing, with_no_da_validator) in table {
            let what = format!("--da-mode {mode:?}, scheme {scheme:?}");
            let requested = cli_da_move(mode, scheme);
            if on_rollup_pricing == InvalidScheme {
                assert!(requested.is_err(), "{what}: must be refused");
                assert_eq!(on_validium_pricing, InvalidScheme, "{what}");
                assert_eq!(with_no_da_validator, InvalidScheme, "{what}");
                continue;
            }
            let requested = requested.as_ref().expect(&what);
            let target_scheme = requested
                .pair
                .expect("--da-mode sets the pair")
                .l2_da_commitment_scheme;
            let verdict = |expected: Expected| match expected {
                Verdict(verdict) => verdict,
                InvalidScheme => panic!("{what}: the flags are valid"),
            };

            // Two opposite live setups, both through a validator other than the bundle's: the
            // verdict must not depend on what the bundle overrides.
            let live_setups = [
                (PubdataContent::LogsOnly, S::BlobsZKSyncOS),
                (PubdataContent::FullPubdata, S::EmptyNoDA),
            ];
            for (validium_priced, expected) in
                [(false, on_rollup_pricing), (true, on_validium_pricing)]
            {
                for (content, live_scheme) in live_setups {
                    let live = live(validium_priced, content, live_scheme);
                    assert_verdict(
                        &requested.skipping_unchanged_content(live.content),
                        live,
                        deployed_for(target_scheme),
                        verdict(expected),
                        &format!("{what}, validium-priced {validium_priced}, live {content}"),
                    );
                }
            }

            for validium_priced in [false, true] {
                for content in [PubdataContent::FullPubdata, PubdataContent::LogsOnly] {
                    let live = live_on(validium_priced, content, l1_da_validator(), S::EmptyNoDA);
                    assert_verdict(
                        &requested.skipping_unchanged_content(live.content),
                        live,
                        RollupPairs::default(),
                        verdict(with_no_da_validator),
                        &format!(
                            "{what}, the no-DA validator, validium-priced {validium_priced}, \
                             live {content}"
                        ),
                    );
                }
            }
        }
    }

    /// Regression: a rollup-priced chain asking for full pubdata delivered nothing used to pass,
    /// since the guard returned before looking at the pair on any chain not priced as a validium.
    #[test]
    fn full_pubdata_delivered_nothing_is_refused_on_a_rollup_priced_chain() {
        let da_move = cli_da_move(
            DAValidatorType::Rollup,
            Some(L2DACommitmentScheme::EmptyNoDA),
        )
        .unwrap();
        let live = live(
            false,
            PubdataContent::FullPubdata,
            L2DACommitmentScheme::BlobsZKSyncOS,
        );
        for acknowledged in [false, true] {
            let err = check_da_after_upgrade(
                CHAIN_ID,
                NEW_MINOR,
                &da_move,
                live,
                RollupPairs::default(),
                acknowledged,
            )
            .expect_err("full pubdata delivered nothing does not prove");
            assert!(err.to_string().contains("do not prove"), "{err}");
        }
    }

    /// Delivery is what the L1 DA validator checks, not what the scheme alone says: a delivering
    /// scheme through a validator that does not check it delivers nothing L1 checks.
    #[test]
    fn an_l1_da_validator_that_does_not_check_the_scheme_delivers_nothing() {
        use DAValidatorType as M;
        use DaVerdict::*;
        use L2DACommitmentScheme as S;
        use PubdataContent::{FullPubdata, LogsOnly};

        let blobs_validator = deployed_for(S::BlobsZKSyncOS);
        let calldata_validator = deployed_for(S::BlobsAndPubdataKeccak256);
        // `ValidiumL1DAValidator`, or an external DA one: the RollupDAManager allows it for nothing.
        let no_rollup_pair = RollupPairs::default();

        // A pre-v33 no-DA validium keeping its validator under an external-DA scheme.
        let pre_v33_validium = live_on(true, FullPubdata, l1_da_validator(), S::EmptyNoDA);
        let keeps_its_validator =
            cli_da_move(M::LogsOnlyValidium, Some(S::PubdataKeccak256)).unwrap();
        assert_verdict(
            &keeps_its_validator,
            pre_v33_validium,
            no_rollup_pair,
            DeliversNothing,
            "logs-only over pubdata-keccak256 through the chain's no-DA validator",
        );
        // The same scheme through an external DA validator is taken on trust.
        let external = cli_da_move_with(
            M::LogsOnlyValidium,
            Some(S::PubdataKeccak256),
            Address::repeat_byte(0x33),
        )
        .unwrap();
        assert_verdict(
            &external,
            pre_v33_validium,
            no_rollup_pair,
            Accepted,
            "logs-only over pubdata-keccak256 through an external DA validator",
        );
        // ...unless the RollupDAManager lists it as a rollup validator.
        assert_verdict(
            &external,
            pre_v33_validium,
            blobs_validator,
            DeliversNothing,
            "logs-only over pubdata-keccak256 through a rollup validator",
        );

        // Blobs through a validator the RollupDAManager does not allow for blobs.
        let rollup_chain = live(false, FullPubdata, S::BlobsZKSyncOS);
        let blobs = cli_da_move(M::LogsOnlyValidium, None).unwrap();
        assert_verdict(
            &blobs,
            rollup_chain,
            no_rollup_pair,
            DeliversNothing,
            "logs-only over blobs through a validator allowed for nothing",
        );
        assert_verdict(
            &blobs,
            rollup_chain,
            calldata_validator,
            DeliversNothing,
            "logs-only over blobs through the calldata validator",
        );

        // Full pubdata on a rollup-priced chain: refused whatever the acknowledgement says.
        for (mode, scheme, pairs, what) in [
            (
                M::Rollup,
                None,
                no_rollup_pair,
                "rollup over blobs, validator allowed for nothing",
            ),
            (
                M::Rollup,
                None,
                calldata_validator,
                "rollup over blobs, the calldata validator",
            ),
            (
                M::Rollup,
                Some(S::BlobsAndPubdataKeccak256),
                blobs_validator,
                "rollup over calldata, the blobs validator",
            ),
            (
                M::Avail,
                None,
                blobs_validator,
                "avail through the blobs validator",
            ),
        ] {
            let da_move = cli_da_move(mode, scheme).unwrap();
            assert_verdict(&da_move, rollup_chain, pairs, FullPubdataUnchecked, what);
            let err =
                check_da_after_upgrade(CHAIN_ID, NEW_MINOR, &da_move, rollup_chain, pairs, true)
                    .unwrap_err()
                    .to_string();
            assert!(
                err.contains(&format!("{:#x}", l1_da_validator())),
                "{what}: the error names the validator: {err}"
            );
        }
        let calldata = cli_da_move(M::Rollup, Some(S::BlobsAndPubdataKeccak256)).unwrap();
        assert_verdict(
            &calldata,
            rollup_chain,
            calldata_validator,
            Accepted,
            "rollup over calldata, the calldata validator",
        );

        // Without `--da-mode` the chain's live validator is the one rated.
        let unchanged = DaMove::default();
        let logs_only_validium = live(true, LogsOnly, S::BlobsZKSyncOS);
        assert_verdict(
            &unchanged,
            logs_only_validium,
            blobs_validator,
            Accepted,
            "a live logs-only validium over blobs, the blobs validator",
        );
        assert_verdict(
            &unchanged,
            logs_only_validium,
            no_rollup_pair,
            DeliversNothing,
            "a live logs-only validium over blobs, a validator allowed for nothing",
        );
        assert_verdict(
            &unchanged,
            rollup_chain,
            no_rollup_pair,
            FullPubdataUnchecked,
            "a live rollup over blobs, a validator allowed for nothing",
        );
    }

    /// Regression (OZ AI-audit M-13): without `--da-mode` the content the chain keeps is its live
    /// one, not the version default, so an existing logs-only validium that delivers is accepted.
    #[test]
    fn without_da_mode_the_chain_keeps_its_live_setup() {
        let unchanged = DaMove::default();
        let check = |content, scheme, acknowledged| {
            check_da_after_upgrade(
                CHAIN_ID,
                NEW_MINOR,
                &unchanged,
                live(true, content, scheme),
                deployed_for(scheme),
                acknowledged,
            )
        };

        check(
            PubdataContent::LogsOnly,
            L2DACommitmentScheme::BlobsZKSyncOS,
            false,
        )
        .expect("a delivering logs-only validium keeps running as one");
        check(
            PubdataContent::LogsOnly,
            L2DACommitmentScheme::PubdataKeccak256,
            false,
        )
        .expect("a delivering logs-only validium keeps running as one");

        // A logs-only validium that delivers nothing still needs the acknowledgement.
        check(
            PubdataContent::LogsOnly,
            L2DACommitmentScheme::EmptyNoDA,
            false,
        )
        .expect_err("nothing delivered");
        check(
            PubdataContent::LogsOnly,
            L2DACommitmentScheme::EmptyNoDA,
            true,
        )
        .expect("acknowledged");

        // A validium-priced chain committing full pubdata is still refused when the bundle
        // leaves it so.
        check(
            PubdataContent::FullPubdata,
            L2DACommitmentScheme::BlobsZKSyncOS,
            false,
        )
        .expect_err("full pubdata on a validium-priced chain");
    }

    /// The content is read from the chain only where its diamond stores it; a chain arriving from
    /// an older version gets the default, so a pre-v33 validium crossing without `--da-mode` lands
    /// on full pubdata delivered nothing and is refused.
    #[test]
    fn a_validium_from_before_pubdata_content_must_move_its_da() {
        assert!(!stores_pubdata_content(
            MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT - 1
        ));
        assert!(stores_pubdata_content(
            MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT
        ));
        assert!(stores_pubdata_content(NEW_MINOR));

        let pre_v33_validium = live(
            true,
            PubdataContent::default(),
            L2DACommitmentScheme::EmptyNoDA,
        );
        for acknowledged in [false, true] {
            check_da_after_upgrade(
                CHAIN_ID,
                NEW_MINOR,
                &DaMove::default(),
                pre_v33_validium,
                RollupPairs::default(),
                acknowledged,
            )
            .expect_err("full pubdata delivered nothing does not prove");
        }
        let moved = cli_da_move(DAValidatorType::LogsOnlyValidium, None).unwrap();
        check_da_after_upgrade(
            CHAIN_ID,
            NEW_MINOR,
            &moved,
            pre_v33_validium,
            deployed_for(L2DACommitmentScheme::BlobsZKSyncOS),
            false,
        )
        .expect("the bundle moves it to logs-only pubdata over blobs");
    }

    /// Below the version with pubdata content, a validium's no-DA setup is how it runs and proves.
    #[test]
    fn the_guard_starts_at_the_version_with_pubdata_content() {
        let validium = live(
            true,
            PubdataContent::default(),
            L2DACommitmentScheme::EmptyNoDA,
        );
        let check = |new_minor| {
            check_da_after_upgrade(
                CHAIN_ID,
                new_minor,
                &DaMove::default(),
                validium,
                RollupPairs::default(),
                false,
            )
        };
        check(MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT - 1)
            .expect("before the version with pubdata content");
        check(MIN_MINOR_VERSION_WITH_PUBDATA_CONTENT)
            .expect_err("from the version with pubdata content");
    }

    /// The scheme is set only together with the L1 DA validator `--da-mode` names; on its own it
    /// used to be accepted and silently dropped.
    #[test]
    fn a_commitment_scheme_without_da_mode_is_refused() {
        let scheme_only = parse(&[
            "--l2-da-commitment-scheme".to_string(),
            cli_name(L2DACommitmentScheme::BlobsZKSyncOS),
        ])
        .expect_err("--l2-da-commitment-scheme requires --da-mode");
        assert_eq!(
            scheme_only.kind(),
            clap::error::ErrorKind::MissingRequiredArgument
        );

        requested_da_move(None, None, Some(L2DACommitmentScheme::BlobsZKSyncOS))
            .expect_err("a scheme without --da-mode");
        requested_da_move(None, Some(l1_da_validator()), None)
            .expect_err("a validator without --da-mode");

        let args = parse(&[]).unwrap();
        let unchanged = requested_da_move(
            args.da_mode,
            args.l1_da_validator,
            args.l2_da_commitment_scheme,
        )
        .unwrap();
        assert!(unchanged.pair.is_none() && unchanged.pubdata_content.is_none());

        let moved = cli_da_move(DAValidatorType::LogsOnlyValidium, None).unwrap();
        let pair = moved.pair.unwrap();
        assert_eq!(pair.l1_da_validator, l1_da_validator());
        assert_eq!(
            pair.l2_da_commitment_scheme,
            L2DACommitmentScheme::BlobsZKSyncOS
        );
        assert_eq!(moved.pubdata_content, Some(PubdataContent::LogsOnly));
    }

    /// `setPubdataContent` reverts on a permanent rollup even for an unchanged value, so the
    /// bundle sends it only when `--da-mode` changes the content. This is what lets a permanent
    /// rollup move its DA pair in the upgrade's own multicall.
    #[test]
    fn the_bundle_sets_the_pubdata_content_only_when_it_changes() {
        use DAValidatorType as M;
        use PubdataContent::{FullPubdata, LogsOnly};

        for (mode, live_content, sent) in [
            (M::Rollup, FullPubdata, None),
            (M::Rollup, LogsOnly, Some(FullPubdata)),
            (M::LogsOnlyValidium, FullPubdata, Some(LogsOnly)),
            (M::LogsOnlyValidium, LogsOnly, None),
            (M::Avail, FullPubdata, None),
        ] {
            let what = format!("--da-mode {mode:?} on a live {live_content} chain");
            let requested = cli_da_move(mode, None).unwrap();
            let bundle = requested.skipping_unchanged_content(live_content);
            assert_eq!(bundle.pubdata_content, sent, "{what}");
            assert!(bundle.pair.is_some(), "{what}: the pair is still set");
            // The guard rates the same setup either way.
            let live = live(false, live_content, L2DACommitmentScheme::EmptyNoDA);
            assert_eq!(
                EffectiveDa::after(&bundle, live),
                EffectiveDa::after(&requested, live),
                "{what}"
            );
        }
        assert!(DaMove::default()
            .skipping_unchanged_content(FullPubdata)
            .pubdata_content
            .is_none());
    }
}
