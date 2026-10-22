//! `ecosystem sync-already-executed`: mark the transactions of a transaction-simulator scenario
//! that already ran on L1, so the simulator records them instead of replaying them.
//!
//! - A governance stage (`stage0`/`stage1`/`stage2`) is executed when the governance record of the
//!   proposal or operation that carries exactly its calls says so: `ProtocolUpgradeHandler.upgradeStatus`
//!   for an emergency proposal or a handler proposal, `Governance.isOperationDone` for a legacy
//!   Governance operation. The proposals and operations are read from the env's `execution.json`.
//! - A per-chain upgrade (`chain_upgrade_<id>_execute`) is executed when the chain's protocol
//!   version is past the version the cut upgrades from; its schedule (`chain_upgrade_<id>_schedule`)
//!   when the ServerNotifier holds an upgrade timestamp for that version.
//!
//! Every other transaction keeps its flag. A stage with no record in `execution.json` is left as it is.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::sol_types::{SolCall, SolValue};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::calldata::{self, InnerCall};
use crate::common::ethereum::get_provider;
use crate::common::logger;

use super::simulator::SimulatorTransaction;

alloy::sol! {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// zk-governance `IProtocolUpgradeHandler.UpgradeProposal`.
    struct UpgradeProposal {
        Call[] calls;
        address executor;
        bytes32 salt;
    }

    /// Legacy `IGovernance.Operation`.
    struct Operation {
        Call[] calls;
        bytes32 predecessor;
        bytes32 salt;
    }

    #[sol(rpc)]
    interface IEmergencyUpgradeBoard {
        function executeEmergencyUpgrade(
            Call[] _calls,
            bytes32 _salt,
            bytes _guardiansSignatures,
            bytes _securityCouncilSignatures,
            bytes _zkFoundationSignatures
        );
    }

    #[sol(rpc)]
    interface IProtocolUpgradeHandler {
        function execute(UpgradeProposal _proposal);
        function upgradeStatus(bytes32 _id) external view returns (
            uint48 creationTimestamp,
            uint48 securityCouncilApprovalTimestamp,
            bool guardiansApproval,
            bool guardiansExtendedLegalVeto,
            bool executed
        );
    }

    #[sol(rpc)]
    interface ILegacyGovernance {
        function execute(Operation _operation);
        function executeInstant(Operation _operation);
        function isOperationDone(bytes32 _id) external view returns (bool);
    }

    #[sol(rpc)]
    interface ISyncZkChain {
        function getProtocolVersion() external view returns (uint256);
    }

    #[sol(rpc)]
    interface ISyncServerNotifier {
        function protocolVersionToUpgradeTimestamp(uint256 _chainId, uint256 _protocolVersion)
            external view returns (uint256);
    }
}

/// Tag prefix of a governance stage's transactions, followed by the stage number.
const STAGE_TAG_PREFIX: &str = "stage";
/// Tag prefix of a per-chain upgrade's transactions, followed by `<chain id>_<phase>`.
const CHAIN_TAG_PREFIX: &str = "chain_upgrade_";
const SCHEDULE_PHASE: &str = "schedule";
const EXECUTE_PHASE: &str = "execute";
/// `execution.json` next to the scenario's `simulator/` directory.
const EXECUTION_FILE: &str = "execution.json";

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct SyncAlreadyExecutedArgs {
    /// Transaction-simulator scenario to update in place.
    #[clap(long)]
    pub scenario: PathBuf,

    /// The env's `execution.json`, which holds the governance proposals or operations of the
    /// stages. Defaults to the one next to the scenario's `simulator/` directory.
    #[clap(long)]
    pub execution: Option<PathBuf>,

    /// L1 RPC URL of the scenario's network.
    #[clap(long)]
    pub l1_rpc_url: String,
}

/// The parts of `execution.json` this command reads.
#[derive(Debug, Deserialize)]
struct Execution {
    #[serde(default)]
    protocol_upgrade_handler: Option<Address>,
    transactions: Vec<ExecutionTx>,
}

#[derive(Debug, Deserialize)]
struct ExecutionTx {
    to: Address,
    data: Bytes,
}

/// A governance proposal or operation of `execution.json` and where its record lives.
enum GovernanceRecord {
    /// `ProtocolUpgradeHandler.upgradeStatus(id).executed`.
    Handler { handler: Address, id: B256 },
    /// `Governance.isOperationDone(id)`.
    Governance { governance: Address, id: B256 },
}

pub async fn run(args: SyncAlreadyExecutedArgs) -> anyhow::Result<()> {
    let mut transactions: Vec<SimulatorTransaction> = serde_json::from_str(
        &fs::read_to_string(&args.scenario)
            .with_context(|| format!("failed to read {}", args.scenario.display()))?,
    )
    .with_context(|| format!("failed to parse {}", args.scenario.display()))?;

    let mut executed: BTreeMap<String, bool> = BTreeMap::new();
    for (stage, done) in stage_status(&args, &transactions).await? {
        executed.insert(format!("{STAGE_TAG_PREFIX}{stage}"), done);
    }
    executed.extend(chain_status(&args.l1_rpc_url, &transactions).await?);

    for tx in &mut transactions {
        if let Some(done) = executed.get(&tx.tag) {
            tx.already_executed = done.then_some(true);
        }
    }
    for (tag, done) in &executed {
        logger::info(format!(
            "{tag}: {}",
            if *done {
                "already executed"
            } else {
                "not executed"
            }
        ));
    }

    let body = serde_json::to_string_pretty(&transactions)?;
    fs::write(&args.scenario, format!("{body}\n"))
        .with_context(|| format!("failed to write {}", args.scenario.display()))?;
    Ok(())
}

/// Whether each governance stage of the scenario has executed, for the stages `execution.json`
/// holds a proposal or operation of.
async fn stage_status(
    args: &SyncAlreadyExecutedArgs,
    transactions: &[SimulatorTransaction],
) -> anyhow::Result<Vec<(u32, bool)>> {
    let stages = stage_calls(transactions)?;
    if stages.is_empty() {
        return Ok(Vec::new());
    }
    let execution_path = match &args.execution {
        Some(path) => path.clone(),
        None => default_execution_path(&args.scenario)?,
    };
    if !execution_path.is_file() {
        logger::warn(format!(
            "No {} for the governance stages; their flags are left as they are",
            execution_path.display()
        ));
        return Ok(Vec::new());
    }
    let execution: Execution = serde_json::from_str(
        &fs::read_to_string(&execution_path)
            .with_context(|| format!("failed to read {}", execution_path.display()))?,
    )
    .with_context(|| format!("failed to parse {}", execution_path.display()))?;
    let records = governance_records(&execution)?;

    let provider = get_provider(&args.l1_rpc_url)?;
    let mut out = Vec::new();
    for (stage, calls) in stages {
        let Some((_, record)) = records
            .iter()
            .find(|(record_calls, _)| *record_calls == calls)
        else {
            logger::warn(format!(
                "stage {stage}: no proposal or operation in {} carries exactly its calls; its flags \
                 are left as they are",
                execution_path.display()
            ));
            continue;
        };
        let done = match record {
            GovernanceRecord::Handler { handler, id } => {
                IProtocolUpgradeHandler::new(*handler, provider.clone())
                    .upgradeStatus(*id)
                    .call()
                    .await
                    .with_context(|| format!("upgradeStatus({id}) on {handler}"))?
                    .executed
            }
            GovernanceRecord::Governance { governance, id } => {
                ILegacyGovernance::new(*governance, provider.clone())
                    .isOperationDone(*id)
                    .call()
                    .await
                    .with_context(|| format!("isOperationDone({id}) on {governance}"))?
            }
        };
        out.push((stage, done));
    }
    Ok(out)
}

/// `<env out>/execution.json` for a scenario at `<env out>/simulator/<file>`.
fn default_execution_path(scenario: &Path) -> anyhow::Result<PathBuf> {
    scenario
        .parent()
        .and_then(Path::parent)
        .map(|out| out.join(EXECUTION_FILE))
        .ok_or_else(|| {
            anyhow::anyhow!(
                "{} has no env output directory above it; pass --execution",
                scenario.display()
            )
        })
}

/// The calls of each `stage<N>` tag, in scenario order.
fn stage_calls(
    transactions: &[SimulatorTransaction],
) -> anyhow::Result<BTreeMap<u32, Vec<InnerCall>>> {
    let mut stages: BTreeMap<u32, Vec<InnerCall>> = BTreeMap::new();
    for tx in transactions {
        let Some(stage) = tx
            .tag
            .strip_prefix(STAGE_TAG_PREFIX)
            .and_then(|n| n.parse::<u32>().ok())
        else {
            continue;
        };
        stages.entry(stage).or_default().push(InnerCall {
            target: tx
                .to
                .parse()
                .with_context(|| format!("stage {stage} target {}", tx.to))?,
            value: U256::ZERO,
            data: alloy::hex::decode(tx.data.trim_start_matches("0x"))
                .with_context(|| format!("stage {stage} calldata"))?,
        });
    }
    Ok(stages)
}

/// Every governance proposal or operation `execution.json` executes, with its calls.
fn governance_records(
    execution: &Execution,
) -> anyhow::Result<Vec<(Vec<InnerCall>, GovernanceRecord)>> {
    let mut records = Vec::new();
    for tx in &execution.transactions {
        let data = tx.data.as_ref();
        if let Ok(call) = IEmergencyUpgradeBoard::executeEmergencyUpgradeCall::abi_decode(data) {
            let handler = execution.protocol_upgrade_handler.ok_or_else(|| {
                anyhow::anyhow!(
                    "execution.json has an emergency upgrade but no protocol_upgrade_handler"
                )
            })?;
            let proposal = UpgradeProposal {
                calls: call._calls,
                executor: tx.to,
                salt: call._salt,
            };
            let calls = inner_calls(&proposal.calls);
            records.push((
                calls,
                GovernanceRecord::Handler {
                    handler,
                    id: keccak256(proposal.abi_encode()),
                },
            ));
        } else if let Ok(call) = IProtocolUpgradeHandler::executeCall::abi_decode(data) {
            let calls = inner_calls(&call._proposal.calls);
            records.push((
                calls,
                GovernanceRecord::Handler {
                    handler: tx.to,
                    id: keccak256(call._proposal.abi_encode()),
                },
            ));
        } else if let Ok(operation) = ILegacyGovernance::executeCall::abi_decode(data)
            .map(|call| call._operation)
            .or_else(|_| {
                ILegacyGovernance::executeInstantCall::abi_decode(data).map(|call| call._operation)
            })
        {
            let calls = inner_calls(&operation.calls);
            records.push((
                calls,
                GovernanceRecord::Governance {
                    governance: tx.to,
                    id: keccak256(operation.abi_encode()),
                },
            ));
        }
    }
    Ok(records)
}

/// Calls as the scenario carries them: target and calldata (values are not compared).
fn inner_calls(calls: &[Call]) -> Vec<InnerCall> {
    calls
        .iter()
        .map(|call| InnerCall {
            target: call.target,
            value: U256::ZERO,
            data: call.data.to_vec(),
        })
        .collect()
}

/// Whether each `chain_upgrade_<id>_<phase>` tag of the scenario has executed.
async fn chain_status(
    l1_rpc_url: &str,
    transactions: &[SimulatorTransaction],
) -> anyhow::Result<BTreeMap<String, bool>> {
    // Per chain: the diamond and the version its cut upgrades from (from the `execute` tx), and
    // the ServerNotifier its schedule writes to (from the `schedule` tx).
    #[derive(Default)]
    struct ChainTxs {
        upgrade: Option<(Address, U256)>,
        server_notifier: Option<Address>,
    }
    let mut chains: BTreeMap<u64, ChainTxs> = BTreeMap::new();
    for tx in transactions {
        let Some((chain_id, phase)) = chain_tag(&tx.tag) else {
            continue;
        };
        let data = alloy::hex::decode(tx.data.trim_start_matches("0x"))
            .with_context(|| format!("{} calldata", tx.tag))?;
        let inner = calldata::wrapped(&data)
            .map(|wrapped| wrapped.calls)
            .unwrap_or_default();
        let entry = chains.entry(chain_id).or_default();
        for call in inner {
            let Some((known, args)) = calldata::decode(&call.data) else {
                continue;
            };
            match (phase, known.function.name.as_str()) {
                (EXECUTE_PHASE, "upgradeChainFromVersion") => {
                    let (chain, old) = if args.len() == 3 {
                        (calldata::as_address(&args[0]), calldata::as_uint(&args[1]))
                    } else {
                        (Some(call.target), calldata::as_uint(&args[0]))
                    };
                    if let (Some(chain), Some(old)) = (chain, old) {
                        entry.upgrade = Some((chain, old));
                    }
                }
                (SCHEDULE_PHASE, "setUpgradeTimestamp") => {
                    entry.server_notifier = Some(call.target)
                }
                _ => {}
            }
        }
    }

    let provider = get_provider(l1_rpc_url)?;
    let mut out = BTreeMap::new();
    for (chain_id, txs) in chains {
        let Some((chain, old)) = txs.upgrade else {
            logger::warn(format!(
                "chain {chain_id}: no upgradeChainFromVersion call to read the old version from; \
                 its flags are left as they are"
            ));
            continue;
        };
        let current = ISyncZkChain::new(chain, provider.clone())
            .getProtocolVersion()
            .call()
            .await
            .with_context(|| format!("chain {chain_id} getProtocolVersion"))?;
        let upgraded = current > old;
        out.insert(chain_phase_tag(chain_id, EXECUTE_PHASE), upgraded);
        if let Some(notifier) = txs.server_notifier {
            let scheduled = upgraded
                || ISyncServerNotifier::new(notifier, provider.clone())
                    .protocolVersionToUpgradeTimestamp(U256::from(chain_id), old)
                    .call()
                    .await
                    .with_context(|| format!("chain {chain_id} upgrade timestamp"))?
                    != U256::ZERO;
            out.insert(chain_phase_tag(chain_id, SCHEDULE_PHASE), scheduled);
        }
    }
    Ok(out)
}

/// `(chain id, phase)` of a `chain_upgrade_<id>_<phase>` tag.
fn chain_tag(tag: &str) -> Option<(u64, &str)> {
    let (chain_id, phase) = tag.strip_prefix(CHAIN_TAG_PREFIX)?.split_once('_')?;
    let phase = match phase {
        SCHEDULE_PHASE => SCHEDULE_PHASE,
        EXECUTE_PHASE => EXECUTE_PHASE,
        _ => return None,
    };
    Some((chain_id.parse().ok()?, phase))
}

fn chain_phase_tag(chain_id: u64, phase: &str) -> String {
    format!("{CHAIN_TAG_PREFIX}{chain_id}_{phase}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chain_tags_parse_only_known_phases() {
        assert_eq!(
            chain_tag("chain_upgrade_4221_schedule"),
            Some((4221, SCHEDULE_PHASE))
        );
        assert_eq!(
            chain_tag("chain_upgrade_4221_execute"),
            Some((4221, EXECUTE_PHASE))
        );
        assert_eq!(chain_tag("chain_upgrade_4221"), None);
        assert_eq!(chain_tag("stage1"), None);
    }

    /// The testnet v0.33.2 emergency proposals executed on Sepolia at blocks 11947773, 11947835
    /// and 11947839: each stage of the committed scenario matches exactly one of them.
    #[test]
    fn every_testnet_stage_has_its_emergency_proposal() {
        let out = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../l1-contracts/upgrade-envs/v0.33.2-verifier/output/testnet");
        let execution: Execution =
            serde_json::from_str(&fs::read_to_string(out.join(EXECUTION_FILE)).unwrap()).unwrap();
        let records = governance_records(&execution).unwrap();
        assert_eq!(records.len(), 3);
        assert!(records
            .iter()
            .all(|(_, record)| matches!(record, GovernanceRecord::Handler { .. })));

        let scenario = fs::read_dir(out.join("simulator"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| path.to_string_lossy().ends_with("-1-ecosystem.json"))
            .unwrap();
        let transactions: Vec<SimulatorTransaction> =
            serde_json::from_str(&fs::read_to_string(scenario).unwrap()).unwrap();
        let stages = stage_calls(&transactions).unwrap();
        assert_eq!(stages.len(), 3);
        for (stage, calls) in stages {
            assert_eq!(
                records
                    .iter()
                    .filter(|(record_calls, _)| *record_calls == calls)
                    .count(),
                1,
                "stage {stage}"
            );
        }
    }
}
