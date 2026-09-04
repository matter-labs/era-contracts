use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use alloy::network::Ethereum;
use alloy::providers::{ProviderBuilder, RootProvider};

use crate::common::abi::{AdminFunctionsAbi, IChainTypeManagerAbi, ZkChainAbi};
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct SetUpgradeTimestampOutput {
    admin_address: Address,
    access_control_restriction: Address,
    bridgehub: Address,
    chain_id: u64,
    upgrade_timestamp: String,
}

/// Set chain-upgrade timestamp, prepare-only.
///
/// Drives `AdminFunctions.s.sol::adminScheduleUpgrade(admin, acr, bridgehub, chainId, ts)`
/// against a forked anvil, emits a Gnosis Safe Transaction Builder JSON bundle
/// via `--out`, and never broadcasts. Apply the bundle via
/// `protocol-ops dev execute-safe` (or any Safe-bundle-aware executor).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetUpgradeTimestampArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address. Defaults to `0x0…0` for
    /// Ownable ChainAdmin deployments (i.e. every local-anvil fixture).
    /// Pass explicitly when the chain uses an access-control-restriction.
    #[clap(long, default_value = ZERO_ADDRESS)]
    pub access_control_restriction: Address,
    /// Upgrade timestamp (unix seconds)
    #[clap(long)]
    pub upgrade_timestamp: String,

    /// `PriorityOpLowerBound` registry address, for the pre-flight that refuses to schedule an
    /// upgrade whose diamond cut would revert `LowerBoundNotRecorded()`.
    ///
    /// Normally discovered by reading `PRIORITY_OP_LOWER_BOUND()` off the CTM's `defaultUpgrade`.
    /// That only works while the CTM stores this release's *one-shot* upgrade contract. v33
    /// deliberately stores the generic `DefaultUpgradeZKsyncOS` there instead — so that later
    /// verifier-only upgrades can reuse it — and the generic contract has no such immutable.
    /// Pass the registry explicitly in that case; it is the `priority_op_lower_bound_addr` from
    /// the release's `ecosystem.toml`.
    #[clap(long)]
    pub priority_op_lower_bound: Option<Address>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

/// The protocol version a chain must currently be on for the priority-op bound to be required.
///
/// Keyed off the chain rather than the CTM: `PRIORITY_OP_LOWER_BOUND` exists to prove that v31's
/// base-token backfill executed before this release removed its L2 entry point, so the precondition
/// belongs to chains leaving v31. A CTM already bumped by a later release would otherwise make this
/// check misfire.
const VERSION_REQUIRING_PRIORITY_OP_BOUND: u64 = 31;

alloy::sol! {
    /// The v33 per-chain upgrade contract and the registry it reads. Only the getters are needed:
    /// recording goes through `chain record-priority-op-lower-bound`.
    #[sol(rpc)]
    interface IPriorityOpLowerBoundGate {
        function PRIORITY_OP_LOWER_BOUND() external view returns (address);
        function recorded(address chain) external view returns (bool);
        function lowerBound(address chain) external view returns (uint256);
    }
}

/// Refuse to schedule the upgrade while the chain would fail the per-chain upgrade's precondition.
///
/// Scheduling is the point of no return for the server: the `UpgradeTimestampUpdated` event makes it
/// inject the L2 upgrade transaction and hold every subsequent batch until L1's protocol version
/// moves. If the priority-op bound has not been recorded and drained by then, the diamond cut reverts
/// with `LowerBoundNotRecorded()` / `PriorityQueueNotReady()` and the chain sits wedged in the
/// meantime. Checking here turns that into a refusal before anything is sent.
///
/// Applies only to a chain currently on v31 (see {VERSION_REQUIRING_PRIORITY_OP_BOUND}). Once it does
/// apply, every failure — RPC, decoding, an unexpected upgrade contract — is fatal rather than treated
/// as "nothing to check".
async fn ensure_priority_op_bound_ready(
    rpc_url: &str,
    bridgehub: Address,
    chain_id: u64,
    explicit_registry: Option<Address>,
) -> anyhow::Result<()> {
    let provider: RootProvider<Ethereum> =
        ProviderBuilder::default().connect_http(rpc_url.parse()?);
    let ctm = crate::common::l1_contracts::resolve_ctm_proxy(rpc_url, bridgehub, chain_id)
        .await
        .context("resolve CTM")?;
    let diamond = crate::common::l1_contracts::resolve_zk_chain(rpc_url, bridgehub, chain_id)
        .await
        .context("resolve chain diamond")?;

    // Decide from the *chain's* current protocol version, not the CTM's. The CTM may already have
    // been bumped past this release by a later one, whereas what actually matters is the version the
    // chain is upgrading away from: the bound exists to prove v31's base-token backfill executed.
    let packed = ZkChainAbi::new(diamond, &provider)
        .getProtocolVersion()
        .call()
        .await
        .context("read chain protocolVersion")?;
    let minor = (packed.wrapping_to::<u64>() >> 32) & 0xFFFF;
    if minor != VERSION_REQUIRING_PRIORITY_OP_BOUND {
        logger::info(format!(
            "Chain {chain_id} is on protocol version 0.{minor}.x, not 0.{VERSION_REQUIRING_PRIORITY_OP_BOUND}.x — no priority-op bound precondition to check"
        ));
        return Ok(());
    }

    // From here on every failure is fatal: this is a safety check, and an RPC hiccup must not be
    // mistaken for "no precondition to enforce".
    let registry = match explicit_registry {
        Some(addr) => addr,
        None => {
            let default_upgrade = IChainTypeManagerAbi::new(ctm, &provider)
                .defaultUpgrade()
                .call()
                .await
                .context("read CTM defaultUpgrade")?;
            IPriorityOpLowerBoundGate::new(default_upgrade, &provider)
                .PRIORITY_OP_LOWER_BOUND()
                .call()
                .await
                .context(
                    "read PRIORITY_OP_LOWER_BOUND from the CTM's default upgrade. That getter only \
                     exists on a release whose one-shot upgrade contract is what the CTM stores as \
                     its defaultUpgrade; v33 stores the generic DefaultUpgradeZKsyncOS instead. \
                     Pass --priority-op-lower-bound with the registry address from the release's \
                     ecosystem.toml",
                )?
        }
    };

    let registry = IPriorityOpLowerBoundGate::new(registry, &provider);
    anyhow::ensure!(
        registry.recorded(diamond).call().await.context("registry.recorded")?,
        "priority-op lower bound is not recorded for chain {chain_id}. Run \
         `protocol-ops chain record-priority-op-lower-bound` first, let the queue drain past it, \
         then schedule the upgrade — otherwise the diamond cut will revert with LowerBoundNotRecorded()"
    );

    let bound = registry
        .lowerBound(diamond)
        .call()
        .await
        .context("registry.lowerBound")?;
    let processed = ZkChainAbi::new(diamond, &provider)
        .getFirstUnprocessedPriorityTx()
        .call()
        .await
        .context("chain.getFirstUnprocessedPriorityTx")?;
    anyhow::ensure!(
        processed >= bound,
        "chain {chain_id} has not processed the priority ops below its recorded bound \
         (processed {processed}, bound {bound}). Wait for them to execute on L1 before scheduling \
         the upgrade — otherwise the diamond cut will revert with PriorityQueueNotReady()"
    );

    logger::info(format!(
        "Priority-op lower bound satisfied for chain {chain_id} (processed {processed} >= bound {bound})"
    ));
    Ok(())
}

pub async fn run(args: ChainSetUpgradeTimestampArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let upgrade_timestamp = args
        .upgrade_timestamp
        .parse::<U256>()
        .context("invalid upgrade_timestamp: expected decimal or hex uint256")?;

    // Checked against the real chain, not the fork: this is a precondition of the upgrade the
    // scheduled timestamp commits the server to.
    ensure_priority_op_bound_ready(
        &args.shared.l1_rpc_url,
        bridgehub,
        chain_id,
        args.priority_op_lower_bound,
    )
    .await?;

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    // The Solidity helper executes through ChainAdmin, but broadcasts from
    // ChainAdmin.owner() or the AccessControlRestriction default admin inside adminExecuteCalls.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, args.access_control_restriction)
        .await?;

    let forge = runner
        .script_call(AdminFunctionsAbi::adminScheduleUpgradeCall {
            _adminAddr: admin_address,
            _accessControlRestriction: args.access_control_restriction,
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
            _timestamp: upgrade_timestamp,
        })
        // `--broadcast` against the anvil fork. In this mode the
        // target RPC is the anvil fork, so "broadcast" produces no real-chain
        // effect — it just records the tx in forge's run file so protocol-ops can
        // extract it into the Safe bundle.
        .with_wallet(&sender);

    logger::step(
        "Preparing set-upgrade-timestamp Safe bundle via AdminFunctions.s.sol (simulation)",
    );
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!("Chain ID: {}", chain_id));
    logger::info(format!("Upgrade timestamp: {}", args.upgrade_timestamp));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to prepare set-upgrade-timestamp")?;

    crate::common::output::write_output_if_requested(
        "chain.set-upgrade-timestamp",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &SetUpgradeTimestampOutput {
            admin_address,
            access_control_restriction: args.access_control_restriction,
            bridgehub,
            chain_id,
            upgrade_timestamp: args.upgrade_timestamp.clone(),
        },
    )
    .await?;

    logger::success("Set upgrade timestamp prepared");
    Ok(())
}
