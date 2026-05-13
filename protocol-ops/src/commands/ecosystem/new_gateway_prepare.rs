//! New-Gateway prepare step for the v31 ecosystem flow.
//!
//! When the env's `permanent-values/<env>.toml` carries a `[new_gateway]`
//! block, `V31UpgradeFull::prepare` invokes this step on the same anvil fork
//! as Core+CTM prepares. It wraps the existing
//! `chain::gateway::convert::stage_vote_prepare` (which itself drives
//! `deploy-scripts/gateway/GatewayVotePreparation.s.sol`) so we get the
//! complete new-GW bring-up in one bundle:
//!
//!   - L1 `setSettlementLayerStatus(gatewayChainId, true)` (whitelist).
//!   - L1→L2 `addChainTypeManager(gatewayCTM)` on the L2 Bridgehub.
//!   - L1 `setAssetDeploymentTracker` + `registerCTMAssetOnL1`.
//!   - L1→L2 two-bridges `setAssetHandler` for the chain assetId.
//!   - L1→L2 two-bridges chain-asset-handler registration for the GW CTM.
//!   - L1→L2 `acceptOwnership` on the GW RollupDAManager (+ ServerNotifier).
//!   - L1→L2 `setGatewaySettlementFee(fee)` on `GW_ASSET_TRACKER_ADDR`.
//!
//! The script writes its bundle as abi-encoded `Call[]` into the
//! `governance_calls_to_execute` field of an output TOML; the ecosystem
//! merge in [`super::upgrade::write_merged_ecosystem_toml`] decodes that
//! field and appends it to stage 2 of `<out>/prepare/ecosystem.toml`.
//!
//! Two real-fork caveats worth flagging:
//!
//! - The script CREATE2-deploys the entire GW CTM contract set (Mailbox /
//!   Executor / Diamond / etc.). Those deploys land in the deployer-EOA
//!   Safe bundle alongside Core+CTM-upgrade deploys, which makes that
//!   bundle noticeably larger.
//! - The deployer EOA pays for both the L1 deploys *and* the value attached
//!   to each L1→L2 priority tx (since `Utils.prepareGovernanceL1L2*`
//!   approves base-token spend from the *governance* address but the
//!   deploys themselves use `msg.sender`). On simulate forks that's
//!   harmless; on a real run the deployer needs ETH + ZK headroom.

use std::path::PathBuf;

use anyhow::Context;

use crate::commands::chain::gateway::convert::{stage_vote_prepare, VotePrepareInputs};
use crate::common::env_config::NewGatewayConfig;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::paths;
use crate::common::wallets::Wallet;

/// Relative path (inside `l1-contracts/`) where `GatewayVotePreparation` writes
/// its output. Lives under `script-out/` because forge's `fs_permissions` only
/// allows writes there. The ecosystem prepare flow reads from this same path
/// to extract `governance_calls_to_execute`.
const VOTE_PREP_OUTPUT_REL: &str = "script-out/v31-new-gateway-vote-preparation.toml";

/// Run `GatewayVotePreparation` for the env's configured new-gateway, returning
/// the absolute path to the output TOML so the caller can merge its
/// `governance_calls_to_execute` field into stage 2 of the ecosystem TOML.
///
/// `deployer` is the same wallet that signs the rest of the prepare phase
/// (the ecosystem deployer EOA); its broadcasts merge into the existing
/// deployer Safe bundle. When `new_gw.refund_recipient` is absent, the
/// deployer's address is used as the refund recipient — EOAs aren't aliased
/// across L1→L2, so refunds land back at the deployer on L2 and stay
/// spendable.
pub async fn prepare_new_gateway(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    bridgehub: ethers::types::Address,
    new_gw: &NewGatewayConfig,
) -> anyhow::Result<PathBuf> {
    let refund_recipient = new_gw.refund_recipient.unwrap_or(deployer.address);

    logger::step(format!(
        "Running new-Gateway vote-prepare (GW chain {}, source CTM via chain {})",
        new_gw.chain_id, new_gw.ctm_representative_chain_id
    ));
    logger::info(format!(
        "Settlement fee:   {} (wrapped-ZK wei)",
        new_gw.settlement_fee
    ));
    logger::info(format!(
        "Refund recipient: {refund_recipient:#x}{}",
        if new_gw.refund_recipient.is_some() {
            " (from [new_gateway].refund_recipient)"
        } else {
            " (defaulted to deployer EOA — EOAs not aliased across L1→L2)"
        }
    ));
    if let Some(sn) = new_gw.server_notifier {
        logger::info(format!("ServerNotifier (pre-deployed): {sn:#x}"));
    }

    let _ = stage_vote_prepare(
        runner,
        deployer,
        bridgehub,
        new_gw.chain_id,
        &VotePrepareInputs {
            ctm_representative_chain_id: new_gw.ctm_representative_chain_id,
            vote_preparation_toml: VOTE_PREP_OUTPUT_REL,
            refund_recipient,
            gateway_settlement_fee: new_gw.settlement_fee,
        },
    )
    .await
    .context("new-gateway vote-prepare forge invocation")?;

    let contracts_path = paths::resolve_l1_contracts_path()?;
    let abs_path = contracts_path.join(VOTE_PREP_OUTPUT_REL);
    anyhow::ensure!(
        abs_path.exists(),
        "Vote preparation output not found at {}",
        abs_path.display()
    );
    Ok(abs_path)
}

// The merge of `governance_calls_to_execute` (abi-encoded `Call[]`) into stage
// 2 of the ecosystem TOML lives inline in `upgrade::write_merged_ecosystem_toml`
// — that function also embeds the rest of the output TOML (deployed GW CTM
// addresses + diamond cut data) under `[new_gateway]` for reviewability, so
// splitting the read out into a separate helper here would be more code, not
// less.
