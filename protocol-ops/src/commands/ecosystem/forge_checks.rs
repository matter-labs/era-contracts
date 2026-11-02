//! Built-in checks of a `forge-script` upgrade (`builtin_checks = true` in its `upgrade.toml`).
//! They read `ecosystem.toml` in the layout `DefaultCTMUpgrade.saveOutput` writes and are the
//! same for every upgrade of an Era CTM; what one upgrade must contain is checked by its own
//! Foundry tests, which the files written here feed.
//!
//! - publication (fork and chain): every factory dep of the L2 upgrade transaction is
//!   published in the BytecodesSupplier, every output address has code, and the output's
//!   supplier is the CTM's;
//! - provenance (fork): every deployer transaction is a CREATE2 deployment through the env's
//!   factory of a bytecode in `AllContractsHashes.json`, or a publication to the supplier;
//!   one salt; every deployment is an output address, and every output address without code at
//!   the fork block is deployed exactly once. Writes `deployments.json`
//!   (`{salt, deployments: [{contract, address, args}]}`); whether the salt and the
//!   constructor args are the right ones is the upgrade's knowledge, checked in Foundry.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Display;
use std::fs;
use std::path::Path;

use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::{SolCall, SolValue};
use anyhow::Context;
use serde::{Deserialize, Serialize};

use crate::common::abi::IBytecodesSupplierPublish;
use crate::common::ethereum::get_provider;
use crate::common::governance_calls::{decode_calls, GovernanceCall};
use crate::common::l1_contracts::resolve_bytecodes_supplier;
use crate::upgrade_verification::verifiers::VerificationResult;
use crate::upgrade_verification::versions::v31::elements::set_new_version_upgrade::{
    upgradeCall, BytecodesSupplier, DiamondCutData,
};
use crate::upgrade_verification::versions::v31::utils::{
    bytecode_verifier::BytecodeVerifier, compute_create2_address_evm,
};

/// The identified deployments, written into the run's work dir for the fork tests.
pub(crate) const DEPLOYMENTS_FILE: &str = "deployments.json";

/// What the built-ins read from `ecosystem.toml`.
// The fork replay (next commit) reads the rest.
#[allow(dead_code)]
#[derive(Debug, Deserialize)]
pub(crate) struct UpgradeOutput {
    /// `abi.encode(DiamondCutData)`: the cut chains upgrade with.
    pub chain_upgrade_diamond_cut: Bytes,
    pub contracts_config: ContractsConfig,
    pub state_transition: BTreeMap<String, Address>,
    pub deployed_addresses: BTreeMap<String, Address>,
    pub governance_calls: GovernanceCalls,
    pub ctm_admin_calls: CtmAdminCalls,
    pub test_upgrade_calls: TestUpgradeCalls,
    /// The L2 upgrade transaction's factory deps, decoded from the cut.
    #[serde(skip)]
    pub factory_deps: Vec<B256>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
pub(crate) struct ContractsConfig {
    pub old_protocol_version: u64,
    pub new_protocol_version: u64,
    /// `abi.encode(DiamondCutData)` for new chains.
    pub diamond_cut_data: Bytes,
    pub force_deployments_data: Bytes,
    pub governance_upgrade_timer_initial_delay: u64,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
pub(crate) struct GovernanceCalls {
    #[serde(deserialize_with = "calls")]
    pub stage0_calls: Vec<GovernanceCall>,
    #[serde(deserialize_with = "calls")]
    pub stage1_calls: Vec<GovernanceCall>,
    #[serde(deserialize_with = "calls")]
    pub stage2_calls: Vec<GovernanceCall>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
pub(crate) struct CtmAdminCalls {
    pub chain_admin: Address,
    pub chain_admin_owner: Address,
    #[serde(deserialize_with = "calls")]
    pub server_notifier_upgrade: Vec<GovernanceCall>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
pub(crate) struct TestUpgradeCalls {
    #[serde(deserialize_with = "calls")]
    pub test_upgrade_chain: Vec<GovernanceCall>,
    pub test_upgrade_chain_caller: Address,
    #[serde(deserialize_with = "calls")]
    pub test_create_chain: Vec<GovernanceCall>,
    pub test_create_chain_caller: Address,
}

/// `abi.encode(Call[])` as hex.
fn calls<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<GovernanceCall>, D::Error> {
    let hex = String::deserialize(deserializer)?;
    decode_calls(&hex).map_err(|error| serde::de::Error::custom(format!("{error:#}")))
}

impl UpgradeOutput {
    pub(crate) fn read(path: &Path) -> anyhow::Result<Self> {
        let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        Self::parse(&raw).with_context(|| {
            format!(
                "{}: not in DefaultCTMUpgrade.saveOutput's layout",
                path.display()
            )
        })
    }

    fn parse(raw: &str) -> anyhow::Result<Self> {
        let mut output: Self = toml::from_str(raw)?;
        let cut = DiamondCutData::abi_decode(&output.chain_upgrade_diamond_cut)
            .context("chain_upgrade_diamond_cut is not abi.encode(DiamondCutData)")?;
        let upgrade = upgradeCall::abi_decode(&cut.initCalldata)
            .context("chain_upgrade_diamond_cut's initCalldata is not upgrade(ProposedUpgrade)")?;
        let tx = upgrade._proposedUpgrade.l2ProtocolUpgradeTx;
        output.factory_deps = tx.factoryDeps.iter().map(|dep| B256::from(*dep)).collect();
        Ok(output)
    }

    /// `state_transition.<key>`, which must be set and non-zero.
    pub(crate) fn state_transition_address(&self, key: &str) -> anyhow::Result<Address> {
        self.state_transition
            .get(key)
            .copied()
            .filter(|address| !address.is_zero())
            .ok_or_else(|| anyhow::anyhow!("state_transition.{key} is missing or zero"))
    }

    /// Every non-zero address of `[state_transition]` and `[deployed_addresses]`, with the
    /// keys that name it.
    pub(crate) fn output_addresses(&self) -> BTreeMap<Address, String> {
        let mut out: BTreeMap<Address, String> = BTreeMap::new();
        let tables = [
            ("state_transition", &self.state_transition),
            ("deployed_addresses", &self.deployed_addresses),
        ];
        for (table, entries) in tables {
            for (key, address) in entries.iter().filter(|(_, address)| !address.is_zero()) {
                let name = format!("{table}.{key}");
                out.entry(*address)
                    .and_modify(|names| *names = format!("{names} / {name}"))
                    .or_insert(name);
            }
        }
        out
    }
}

/// A checker's findings, printed the way PUVT prints its own; `finish` fails listing every
/// error.
#[derive(Default)]
pub(crate) struct Report {
    result: VerificationResult,
    errors: Vec<String>,
}

impl Report {
    pub(crate) fn ok(&self, what: impl AsRef<str>) {
        self.result.report_ok(what.as_ref());
    }

    pub(crate) fn error(&mut self, what: impl Into<String>) {
        let what = what.into();
        self.result.report_error(&what);
        self.errors.push(what);
    }

    pub(crate) fn equal<T: PartialEq + Display>(&mut self, what: &str, got: T, want: T) {
        if got == want {
            self.ok(what);
        } else {
            self.error(format!("{what}: expected {want}, got {got}"));
        }
    }

    pub(crate) fn finish(self) -> anyhow::Result<()> {
        anyhow::ensure!(self.errors.is_empty(), "{}", self.errors.join("; "));
        Ok(())
    }
}

/// Every factory dep of the L2 upgrade transaction is published, every output address has
/// code, and the output's supplier is the CTM's. Read-only, so safe against a real chain.
pub(crate) async fn check_publication(rpc_url: &str, output: &UpgradeOutput) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    let mut report = Report::default();
    let supplier = output.state_transition_address("bytecodes_supplier_addr")?;
    let ctm = output.state_transition_address("chain_type_manager_proxy")?;
    // A ZKsync OS CTM publishes EVM bytecodes, into `evmPublishingBlock`.
    anyhow::ensure!(
        !crate::common::l1_contracts::resolve_is_zksync_os(rpc_url, ctm).await?,
        "{ctm} is a ZKsync OS CTM: the built-in checks support Era CTMs only"
    );

    let bytecodes_supplier = BytecodesSupplier::new(supplier, provider.clone());
    let mut unpublished = 0;
    for dep in &output.factory_deps {
        let block = bytecodes_supplier
            .publishingBlock(*dep)
            .call()
            .await
            .with_context(|| format!("BytecodesSupplier({supplier}).publishingBlock({dep})"))?;
        if block.is_zero() {
            unpublished += 1;
            report.error(format!("factory dep {dep} is not published on {supplier}"));
        }
    }
    if output.factory_deps.is_empty() {
        report.error("the L2 upgrade transaction has no factory deps");
    } else if unpublished == 0 {
        report.ok(format!(
            "all {} factory deps of the L2 upgrade transaction are published on {supplier}",
            output.factory_deps.len()
        ));
    }

    let addresses = output.output_addresses();
    let mut without_code = 0;
    for (address, names) in &addresses {
        let code = provider
            .get_code_at(*address)
            .await
            .with_context(|| format!("eth_getCode({address})"))?;
        if code.is_empty() {
            without_code += 1;
            report.error(format!("{names} {address} has no code"));
        }
    }
    if without_code == 0 {
        report.ok(format!(
            "all {} output addresses have code",
            addresses.len()
        ));
    }

    report.equal(
        "state_transition.bytecodes_supplier_addr = the CTM's L1_BYTECODES_SUPPLIER()",
        supplier,
        resolve_bytecodes_supplier(rpc_url, ctm).await?,
    );
    report.finish()
}

/// A deployer transaction as `prepare/*.safe.json` holds it.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DeployerTx {
    pub to: Address,
    /// Decimal or `0x` hex.
    pub value: String,
    pub data: Bytes,
}

/// One identified CREATE2 deployment.
#[derive(Debug, Serialize)]
pub(crate) struct Deployment {
    /// `AllContractsHashes.json`'s name, e.g. `l1-contracts/AdminFacet`.
    pub contract: String,
    pub address: Address,
    /// The constructor arguments after the bytecode.
    pub args: Bytes,
}

/// `deployments.json`.
#[derive(Debug, Serialize)]
pub(crate) struct Deployments {
    /// `None` when nothing is deployed.
    pub salt: Option<B256>,
    pub deployments: Vec<Deployment>,
}

/// Provenance of the deployer transactions on the fork the bundle was replayed on, through
/// `factory` (`permanent-values/<env>.toml`'s `create2_factory_addr`). Writes
/// `deployments.json` into `work_dir`.
pub(crate) async fn check_provenance(
    rpc_url: &str,
    output: &UpgradeOutput,
    factory: Address,
    txs: &[DeployerTx],
    fork_block: u64,
    work_dir: &Path,
) -> anyhow::Result<()> {
    let provider = get_provider(rpc_url)?;
    let supplier = output.state_transition_address("bytecodes_supplier_addr")?;
    let addresses = output.output_addresses();
    let mut undeployed = BTreeSet::new();
    for address in addresses.keys() {
        let code = provider
            .get_code_at(*address)
            .block_id(fork_block.into())
            .await
            .with_context(|| format!("eth_getCode({address}) at block {fork_block}"))?;
        if code.is_empty() {
            undeployed.insert(*address);
        }
    }
    let hashes = BytecodeVerifier::init_from_local()?;
    let mut report = Report::default();
    let found = identify_deployments(
        txs,
        factory,
        supplier,
        &addresses,
        &undeployed,
        &hashes,
        &mut report,
    );
    fs::create_dir_all(work_dir)?;
    let path = work_dir.join(DEPLOYMENTS_FILE);
    fs::write(&path, serde_json::to_string_pretty(&found)? + "\n")
        .with_context(|| format!("write {}", path.display()))?;
    report.ok(format!("deployments written to {}", path.display()));
    report.finish()
}

/// The provenance rules on their own (no RPC). `undeployed`: the output addresses that had
/// no code at the fork block.
fn identify_deployments(
    txs: &[DeployerTx],
    factory: Address,
    supplier: Address,
    output: &BTreeMap<Address, String>,
    undeployed: &BTreeSet<Address>,
    hashes: &BytecodeVerifier,
    report: &mut Report,
) -> Deployments {
    let publish = [
        IBytecodesSupplierPublish::publishEraBytecodeCall::SELECTOR,
        IBytecodesSupplierPublish::publishEraBytecodesCall::SELECTOR,
    ];
    let errors_before = report.errors.len();
    let mut salt: Option<B256> = None;
    let mut deployments: Vec<Deployment> = Vec::new();
    let mut publications = 0;
    for (index, tx) in txs.iter().enumerate() {
        let label = format!("deployer tx #{index} (to {})", tx.to);
        if !tx.value.parse::<U256>().is_ok_and(|value| value.is_zero()) {
            report.error(format!("{label} sends value {}", tx.value));
        }
        if tx.to == supplier && tx.data.len() >= 4 && publish.iter().any(|s| tx.data[..4] == *s) {
            publications += 1;
            continue;
        }
        if tx.to != factory || tx.data.len() < 32 {
            report.error(format!(
                "{label} is neither a CREATE2 deployment through {factory} nor a publication to {supplier}"
            ));
            continue;
        }
        let (tx_salt, init_code) = tx.data.split_at(32);
        let tx_salt = B256::from_slice(tx_salt);
        match salt {
            None => salt = Some(tx_salt),
            Some(first) if first != tx_salt => {
                report.error(format!(
                    "{label} uses salt {tx_salt}, an earlier one {first}"
                ));
            }
            Some(_) => {}
        }
        let address = compute_create2_address_evm(factory, tx_salt, keccak256(init_code));
        let Some((contract, args)) = hashes.try_parse_bytecode(init_code) else {
            report.error(format!(
                "{label}: the init code for {address} is no bytecode of AllContractsHashes.json \
                 followed by constructor args"
            ));
            continue;
        };
        if !contract.starts_with("l1-contracts/") && !contract.starts_with("da-contracts/") {
            report.error(format!("{label} deploys {contract}, not an L1 contract"));
        } else if !output.contains_key(&address) {
            report.error(format!(
                "{label} deploys {contract} at {address}, which the output doesn't list"
            ));
        } else if deployments.iter().any(|known| known.address == address) {
            report.error(format!("{label} deploys {address} a second time"));
        } else {
            deployments.push(Deployment {
                contract,
                address,
                args: args.into(),
            });
        }
    }
    for address in undeployed {
        if !deployments.iter().any(|known| known.address == *address) {
            report.error(format!(
                "{} {address} had no code at the fork block, and no deployer transaction deploys it",
                output[address]
            ));
        }
    }
    if report.errors.len() == errors_before {
        report.ok(format!(
            "{} CREATE2 deployments identified and {publications} publications, one salt",
            deployments.len()
        ));
    }
    Deployments { salt, deployments }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::governance_calls::encode_calls;
    use crate::common::paths;
    use crate::upgrade_verification::versions::v31::utils::bytecode_verifier::{
        ContractHash, ContractHashes,
    };

    const SUPPLIER: Address = Address::repeat_byte(0x5b);
    const CTM: Address = Address::repeat_byte(0xc7);
    const CTM_IMPL: Address = Address::repeat_byte(0xc1);
    const TIMER: Address = Address::repeat_byte(0x71);

    fn calls_hex(calls: &[GovernanceCall]) -> String {
        format!("0x{}", alloy::hex::encode(encode_calls(calls)))
    }

    /// A base-layout output whose cut and stages come from v34 stage's committed output (its
    /// `contracts_config.upgrade_cut_data` is encoded like `chain_upgrade_diamond_cut`); the
    /// addresses are synthetic.
    fn base_layout_output() -> String {
        let l1_contracts = paths::resolve_l1_contracts_path().unwrap();
        let path = l1_contracts.join("upgrade-envs/v0.34.0-era/output/stage/ecosystem.toml");
        let committed: toml::Value = toml::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        let v34 = |table: &str, key: &str| committed[table][key].as_str().unwrap().to_string();
        let test_call = calls_hex(&[GovernanceCall {
            target: Address::repeat_byte(0xd1),
            value: U256::ZERO,
            data: vec![0xab],
        }]);
        format!(
            r#"chain_upgrade_diamond_cut = "{cut}"

[contracts_config]
diamond_cut_data = "0x01"
force_deployments_data = "0x02"
governance_upgrade_timer_initial_delay = 3600
is_testnet = true
new_protocol_version = 146028888064
old_protocol_version = 141733920768

[state_transition]
bytecodes_supplier_addr = "{SUPPLIER}"
chain_type_manager_proxy = "{CTM}"
chain_type_manager_implementation_addr = "{CTM_IMPL}"
state_transition_implementation_addr = "{CTM_IMPL}"
verifier_plonk_addr = "0x0000000000000000000000000000000000000000"

[deployed_addresses]
l1_governance_upgrade_timer = "{TIMER}"
validium_l1_da_validator_addr = "0x0000000000000000000000000000000000000000"

[governance_calls]
stage0_calls = "{stage0}"
stage1_calls = "{stage1}"
stage2_calls = "{stage2}"

[ctm_admin_calls]
chain_admin = "0x00000000000000000000000000000000000000a1"
chain_admin_owner = "0x00000000000000000000000000000000000000a2"
server_notifier_upgrade = "{test_call}"

[test_upgrade_calls]
test_upgrade_chain = "{test_call}"
test_upgrade_chain_caller = "0x00000000000000000000000000000000000000a3"
test_create_chain = "{test_call}"
test_create_chain_caller = "0x00000000000000000000000000000000000000a4"
"#,
            cut = v34("contracts_config", "upgrade_cut_data"),
            stage0 = v34("governance_calls", "stage0_calls"),
            stage1 = v34("governance_calls", "stage1_calls"),
            stage2 = v34("governance_calls", "stage2_calls"),
        )
    }

    #[test]
    fn reads_the_base_layout() {
        let raw = base_layout_output();
        let output = UpgradeOutput::parse(&raw).unwrap();
        assert_eq!(output.factory_deps.len(), 51);
        let stages = &output.governance_calls;
        let stage_sizes = [
            &stages.stage0_calls,
            &stages.stage1_calls,
            &stages.stage2_calls,
        ]
        .map(|calls| calls.len());
        assert_eq!(stage_sizes, [1, 3, 1]);
        let config = &output.contracts_config;
        assert_eq!(config.new_protocol_version, 146_028_888_064);
        assert_eq!(config.governance_upgrade_timer_initial_delay, 3600);
        assert_eq!(config.diamond_cut_data, Bytes::from(vec![0x01]));
        assert_eq!(
            output.test_upgrade_calls.test_upgrade_chain[0].data,
            vec![0xab]
        );
        assert_eq!(
            output
                .state_transition_address("bytecodes_supplier_addr")
                .unwrap(),
            SUPPLIER
        );
        assert!(output
            .state_transition_address("verifier_plonk_addr")
            .is_err());
        // Zero addresses are skipped; one address under two keys appears once.
        let addresses = output.output_addresses();
        let mut want = vec![CTM_IMPL, TIMER, SUPPLIER, CTM];
        want.sort();
        assert_eq!(addresses.keys().copied().collect::<Vec<_>>(), want);
        assert_eq!(
            addresses[&CTM_IMPL],
            "state_transition.chain_type_manager_implementation_addr / \
             state_transition.state_transition_implementation_addr"
        );
        // A missing key names itself.
        let error =
            UpgradeOutput::parse(&raw.replace("test_create_chain_caller", "x")).unwrap_err();
        assert!(
            format!("{error:#}").contains("test_create_chain_caller"),
            "{error:#}"
        );
    }

    const FACTORY: Address = Address::repeat_byte(0xfa);
    const SALT: B256 = B256::repeat_byte(0x5a);

    /// A synthetic bytecode (two words, the least `try_parse_bytecode` accepts) and a second one.
    fn bytecode(tag: u8) -> Vec<u8> {
        vec![tag; 64]
    }

    fn hashes() -> BytecodeVerifier {
        let entry = |name: &str, tag: u8| ContractHash {
            contract_name: name.to_string(),
            evm_bytecode_hash: Some(keccak256(bytecode(tag)).to_string()),
            evm_deployed_bytecode_hash: None,
            evm_deployed_bytecode_blake_hash: None,
            evm_deployed_bytecode_length: None,
            zk_bytecode_hash: None,
        };
        BytecodeVerifier::from_contract_hashes(ContractHashes {
            hashes: vec![
                entry("l1-contracts/Facet", 1),
                entry("da-contracts/Checker", 2),
            ],
        })
    }

    fn deploy(salt: B256, init_code: &[u8]) -> (DeployerTx, Address) {
        let tx = DeployerTx {
            to: FACTORY,
            value: "0".to_string(),
            data: [salt.as_slice(), init_code].concat().into(),
        };
        (
            tx,
            compute_create2_address_evm(FACTORY, salt, keccak256(init_code)),
        )
    }

    fn publication() -> DeployerTx {
        DeployerTx {
            to: SUPPLIER,
            value: "0x0".to_string(),
            data: IBytecodesSupplierPublish::publishEraBytecodesCall {
                _bytecodes: vec![Bytes::from(vec![1u8; 32])],
            }
            .abi_encode()
            .into(),
        }
    }

    /// The facet with one constructor word, and the checker without args.
    fn facet_init() -> Vec<u8> {
        [bytecode(1), vec![0x0a; 32]].concat()
    }

    /// Runs the rules with every deployed address in the output and undeployed at the fork
    /// block; returns the errors and what was identified.
    fn run(txs: &[DeployerTx], deployed: &[Address]) -> (Vec<String>, Deployments) {
        let output: BTreeMap<Address, String> = deployed
            .iter()
            .enumerate()
            .map(|(i, address)| (*address, format!("state_transition.key{i}")))
            .collect();
        let undeployed = deployed.iter().copied().collect();
        let mut report = Report::default();
        let found = identify_deployments(
            txs,
            FACTORY,
            SUPPLIER,
            &output,
            &undeployed,
            &hashes(),
            &mut report,
        );
        (report.errors, found)
    }

    #[test]
    fn identifies_deployments_and_publications() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (checker, checker_address) = deploy(SALT, &bytecode(2));
        let (errors, found) = run(
            &[facet, publication(), checker],
            &[facet_address, checker_address],
        );
        assert!(errors.is_empty(), "{errors:?}");
        assert_eq!(found.salt, Some(SALT));
        let summary: Vec<_> = found
            .deployments
            .iter()
            .map(|d| (d.contract.as_str(), d.address, d.args.to_vec()))
            .collect();
        assert_eq!(
            summary,
            [
                ("l1-contracts/Facet", facet_address, vec![0x0a; 32]),
                ("da-contracts/Checker", checker_address, vec![]),
            ]
        );
    }

    #[test]
    fn rejects_tampered_init_code() {
        let mut init_code = facet_init();
        init_code[0] ^= 1;
        let (tx, address) = deploy(SALT, &init_code);
        let (errors, found) = run(&[tx], &[address]);
        assert!(
            errors[0].contains("no bytecode of AllContractsHashes.json"),
            "{errors:?}"
        );
        // The address it would have deployed stays undeployed.
        assert!(
            errors[1].contains("no deployer transaction deploys it"),
            "{errors:?}"
        );
        assert!(found.deployments.is_empty());
    }

    #[test]
    fn rejects_two_salts_and_value() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (mut checker, checker_address) = deploy(B256::repeat_byte(0x01), &bytecode(2));
        checker.value = "1".to_string();
        let (errors, _) = run(&[facet, checker], &[facet_address, checker_address]);
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(errors[0].contains("sends value 1"), "{errors:?}");
        assert!(errors[1].contains("uses salt"), "{errors:?}");
    }

    #[test]
    fn rejects_targets_the_output_does_not_list() {
        let (facet, _) = deploy(SALT, &facet_init());
        let stray = DeployerTx {
            to: Address::repeat_byte(0x99),
            value: "0".to_string(),
            data: Bytes::from(vec![1, 2, 3, 4]),
        };
        let (errors, _) = run(&[facet, stray], &[]);
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(
            errors[0].contains("which the output doesn't list"),
            "{errors:?}"
        );
        assert!(
            errors[1].contains("neither a CREATE2 deployment"),
            "{errors:?}"
        );
    }

    #[test]
    fn rejects_an_output_address_left_undeployed() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (_, checker_address) = deploy(SALT, &bytecode(2));
        let (errors, _) = run(&[facet], &[facet_address, checker_address]);
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(
            errors[0].contains(&checker_address.to_string()),
            "{errors:?}"
        );
    }

    #[test]
    fn rejects_a_double_deployment() {
        let (facet, facet_address) = deploy(SALT, &facet_init());
        let (errors, found) = run(&[facet.clone(), facet], &[facet_address]);
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(errors[0].contains("a second time"), "{errors:?}");
        assert_eq!(found.deployments.len(), 1);
    }
}
