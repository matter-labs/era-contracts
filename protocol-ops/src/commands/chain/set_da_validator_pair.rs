use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::types::{DAValidatorType, L2DACommitmentScheme};

#[derive(Serialize)]
struct SetDaValidatorPairOutput {
    chain_id: u64,
    admin_address: Address,
    l1_da_validator: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
}

/// Set the DA validator pair for an L1-settling chain.
///
/// Drives `AdminFunctions.s.sol::setDAValidatorPair(bridgehub,
/// accessControlRestriction, chainId, l1DaValidator, l2DaCommitmentScheme,
/// true)` against a forked anvil and
/// emits a Gnosis Safe Transaction Builder JSON bundle via `--out`. Replay
/// the bundle via `protocol-ops dev execute-safe` (or any Safe-bundle-aware
/// executor) to apply it.
///
/// Use case: post chain upgrade (e.g. v29 → v31), where the upgrade itself
/// resets the chain's L1 DA validator and the operator must re-set it
/// before the chain can commit batches.
///
/// For chains that settle on a gateway (rather than directly on L1), use
/// `chain gateway migrate-to` — the migrate-to flow already invokes the
/// gateway-aware variant (`setDAValidatorPairWithGateway`) as part of its
/// Phase 3.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetDaValidatorPairArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address.
    /// Use `ZERO_ADDRESS` for Ownable ChainAdmin.
    #[clap(long, default_value = ZERO_ADDRESS)]
    pub access_control_restriction: Address,

    /// L1 DA validator contract address. The post-upgrade `RollupL1DAValidator`
    /// (or analogous) deployed by the ecosystem upgrade.
    #[clap(long)]
    pub l1_da_validator: Address,

    /// What the chain does with its pubdata. The L2 DA commitment scheme follows from this and the
    /// VM the chain runs, which is read from its CTM — a ZKsync OS rollup or logs-only validium
    /// publishes through blobs (`blobs-zksync-os`), an Era rollup commits blobs and the pubdata hash
    /// (`blobs-and-pubdata-keccak256`), an Era validium commits nothing (`empty-no-da`) and a
    /// custom-DA chain commits the hash of the pubdata it hands over (`pubdata-keccak256`).
    #[clap(long, value_enum, default_value_t = DAValidatorType::Rollup)]
    pub da_mode: DAValidatorType,

    /// Override the L2 DA commitment scheme derived from `--da-mode` and the chain's VM. Needed
    /// only for a gateway-settling chain, which relays its pubdata and commits it as
    /// `blobs-and-pubdata-keccak256` whatever its VM.
    #[clap(long, value_enum, help_heading = "Advanced input")]
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainSetDaValidatorPairArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;

    // The commitment scheme is a function of the DA mode and the VM, and the VM is on L1 already, so
    // the caller only has to say what the chain does with its pubdata.
    let l2_da_commitment_scheme = match args.l2_da_commitment_scheme {
        Some(scheme) => scheme,
        None => {
            let ctm_proxy = crate::common::l1_contracts::resolve_ctm_proxy(
                &runner.rpc_url,
                bridgehub,
                chain_id,
            )
            .await
            .context("resolving the chain's CTM from L1")?;
            let vm_type =
                crate::common::l1_contracts::resolve_vm_type(&runner.rpc_url, ctm_proxy).await?;
            logger::info(format!("VM type (from L1): {vm_type:?}"));
            L2DACommitmentScheme::from_da_and_vm_types(args.da_mode, vm_type)
        }
    };
    // `AdminFunctions.setDAValidatorPair` → `Utils.adminExecuteCalls` internally
    // `vm.startBroadcast(adminOwner)` (or the AccessControlRestriction default
    // admin when `--access-control-restriction` is set), so Forge's sender must
    // match that EOA for nonce tracking on the anvil fork.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, args.access_control_restriction)
        .await?;

    let forge = runner
        .script_call(AdminFunctionsAbi::setDAValidatorPairCall {
            _bridgehub: bridgehub,
            _accessControlRestriction: args.access_control_restriction,
            _chainId: U256::from(chain_id),
            _l1DaValidator: args.l1_da_validator,
            _l2DaCommitmentScheme: l2_da_commitment_scheme as u8,
            _shouldSend: true,
        })
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(&sender);

    logger::step(
        "Preparing set-da-validator-pair Safe bundle via AdminFunctions.s.sol (simulation)",
    );
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!("Chain ID: {chain_id}"));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!("L1 DA validator: {:#x}", args.l1_da_validator));
    logger::info(format!("DA mode: {:?}", args.da_mode));
    logger::info(format!(
        "L2 DA commitment scheme: {} ({})",
        l2_da_commitment_scheme, l2_da_commitment_scheme as u8,
    ));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to execute forge script for set-da-validator-pair")?;

    crate::common::output::write_output_if_requested(
        "chain.set-da-validator-pair",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &SetDaValidatorPairOutput {
            chain_id,
            admin_address,
            l1_da_validator: args.l1_da_validator,
            l2_da_commitment_scheme,
        },
    )
    .await?;

    logger::success("set-da-validator-pair prepared");
    Ok(())
}
