use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use alloy::primitives::{address, keccak256, Address, Bytes, FixedBytes, U256};
use alloy::sol_types::SolCall;

use super::decode::{self, protocol_version};
use super::load::relative_link;
use super::*;
use crate::common::env_config::EnvConfig;

alloy::sol! {
    struct Call { address target; uint256 value; bytes data; }
    struct Operation { Call[] calls; bytes32 predecessor; bytes32 salt; }
    struct FacetCut { address facet; uint8 action; bool isFreezable; bytes4[] selectors; }
    struct DiamondCutData { FacetCut[] facetCuts; address initAddress; bytes initCalldata; }
    function approveHash(bytes32 hashToApprove);
    function multicall(Call[] _calls, bool _requireSuccess);
    function scheduleTransparent(Operation _operation, uint256 _delay);
    function execute(Operation _operation);
    function setUpgradeTimestamp(uint256 _protocolVersion, uint256 _upgradeTimestamp);
    function upgradeChainFromVersion(address _chain, uint256 _oldProtocolVersion, DiamondCutData _cut);
}

/// The v0.33.0 stage upgrade: the committed emergency proposal and its runbook.
const V33_STAGE: &str = "../l1-contracts/upgrade-envs/v0.33.0-compiler/output/stage";
/// Chain 499's v0.33.0 ChainAdmin upgrade, written by `protocol_ops chain upgrade`.
const V33_STAGE_CHAIN_499: &str =
    "../l1-contracts/upgrade-envs/v0.33.0-compiler/output/stage/chain-upgrades/499";

/// The bullet the committed stage runbook carries beyond what the proposal says.
pub(super) const V33_STAGE_NOTE: &str = "No running chain changes version: chains upgrade later \
     through their own ChainAdmin. Chain 499's upgrade is [`chain-upgrades/499/EXECUTE.md`](./chain-upgrades/499/EXECUTE.md) \
     (set the upgrade timestamp, then upgrade), sent from its ChainAdmin owner once stage runs a v33-aware server.";

const STAGE_OWNER: Address = address!("d669494442609879b209CcA8eba2BdC904D2E69D");
const OWNER_A: Address = address!("1111111111111111111111111111111111111111");
const OWNER_B: Address = address!("2222222222222222222222222222222222222222");
const CHAIN_ADMIN: Address = address!("3333333333333333333333333333333333333333");
const GOVERNANCE: Address = address!("4444444444444444444444444444444444444444");
const DIAMOND: Address = address!("5555555555555555555555555555555555555555");

fn repo_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(relative)
}

fn hex_of(data: &[u8]) -> String {
    format!("0x{}", hex::encode(data))
}

// ─── round trip: every tx of a rendered page, read back ──────────────────────────

/// One table row, read back from the Markdown.
#[derive(Debug)]
struct RenderedTx {
    number: usize,
    to: Address,
    data: Vec<u8>,
}

/// Read the table rows and the `<details>` calldata back out of a rendered page.
fn read_back(markdown: &str) -> Vec<RenderedTx> {
    let mut full: std::collections::BTreeMap<usize, Vec<u8>> = Default::default();
    let lines: Vec<&str> = markdown.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        if let Some(rest) = line.strip_prefix("<summary>Tx ") {
            let number: usize = rest.split(' ').next().unwrap().parse().unwrap();
            assert_eq!(lines[i + 2], "```text");
            full.insert(number, hex::decode(&lines[i + 3][2..]).unwrap());
        }
    }
    let backticked = |cell: &str| -> String { cell.split('`').nth(1).unwrap().to_string() };
    let mut txs = Vec::new();
    for line in lines.iter().filter(|line| line.starts_with("| ")) {
        let cells: Vec<&str> = line.trim_matches('|').split(" | ").map(str::trim).collect();
        let Ok(number) = cells[0].parse::<usize>() else {
            continue;
        };
        let to: Address = backticked(cells[2]).parse().unwrap();
        let data_cell = cells.last().unwrap();
        let data = if data_cell.starts_with("`0x") {
            hex::decode(&backticked(data_cell)[2..]).unwrap()
        } else {
            let data = full.remove(&number).expect("long calldata printed below");
            let size: usize = data_cell
                .split(' ')
                .next()
                .unwrap()
                .replace(',', "")
                .parse()
                .unwrap();
            assert_eq!(size, data.len(), "tx {number}: byte count");
            assert_eq!(
                backticked(data_cell),
                format!("{:#x}", keccak256(&data)),
                "tx {number}: keccak"
            );
            data
        };
        txs.push(RenderedTx { number, to, data });
    }
    assert!(full.is_empty(), "calldata printed for no table row");
    txs
}

/// The page shows exactly the source's txs: numbering, targets, calldata.
fn assert_round_trips(runbook: &Runbook, markdown: &str) {
    let rendered = read_back(markdown);
    assert_eq!(rendered.len(), runbook.txs.len());
    for (i, (shown, tx)) in rendered.iter().zip(&runbook.txs).enumerate() {
        assert_eq!(shown.number, i + 1);
        assert_eq!(shown.to, tx.to, "tx {}: to", i + 1);
        assert_eq!(shown.data, tx.data.to_vec(), "tx {}: data", i + 1);
    }
}

// ─── the committed stage runbook ─────────────────────────────────────────────────

/// What the committed runbook was rendered with: the stage env's names, the note, and the
/// check `dev execution-runbook --check-fork-url <sepolia> --check-fork-block 11813648` measured.
fn v33_stage_runbook() -> Option<Runbook> {
    let dir = repo_path(V33_STAGE);
    let env_cfg = EnvConfig::load("stage").ok()?;
    let options = LoadOptions {
        env: Some("stage".to_string()),
        chain_id: env_cfg.l1_chain_id(),
        names: env_names(&env_cfg),
        notes: vec![V33_STAGE_NOTE.to_string()],
        ..Default::default()
    };
    let mut runbook = load(
        &dir.join("emergency-upgrade-board.json"),
        &dir.join(RUNBOOK_FILE),
        &options,
    )
    .unwrap();
    runbook.facts = Some(CheckFacts {
        fork_block: 11_813_648,
        date: "2026-09-30".to_string(),
        nonces: vec![(STAGE_OWNER, 843)],
        eoa_senders: BTreeSet::from([STAGE_OWNER]),
        replayed_after: None,
    });
    Some(runbook)
}

#[test]
fn committed_stage_runbook_is_the_rendering_of_its_proposal() {
    let Some(runbook) = v33_stage_runbook() else {
        return; // no checkout around the test binary
    };
    let committed = fs::read_to_string(repo_path(V33_STAGE).join(RUNBOOK_FILE)).unwrap();
    assert_eq!(render(&runbook), committed);
}

#[test]
fn committed_stage_runbook_carries_every_proposal_tx() {
    let dir = repo_path(V33_STAGE);
    let Ok(raw) = fs::read_to_string(dir.join("emergency-upgrade-board.json")) else {
        return;
    };
    let source: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let markdown = fs::read_to_string(dir.join(RUNBOOK_FILE)).unwrap();
    let rendered = read_back(&markdown);
    let txs = source["transactions"].as_array().unwrap();
    assert_eq!(rendered.len(), txs.len());
    for (shown, tx) in rendered.iter().zip(txs) {
        assert_eq!(shown.number as u64, tx["step"].as_u64().unwrap());
        assert_eq!(
            shown.to,
            tx["to"].as_str().unwrap().parse::<Address>().unwrap()
        );
        assert_eq!(hex_of(&shown.data), tx["data"].as_str().unwrap());
        assert_eq!(
            tx["from"].as_str().unwrap(),
            source["owner"].as_str().unwrap()
        );
    }
    let owner = source["owner"].as_str().unwrap();
    assert!(markdown.contains(&format!(
        "- **Sender for all {} txs:** the stage owner EOA `{owner}`.",
        txs.len()
    )));
    assert!(markdown.contains(&format!(
        "Emergency Upgrade Board `{}`, Protocol Upgrade Handler `{}`",
        source["emergency_upgrade_board"].as_str().unwrap(),
        source["protocol_upgrade_handler"].as_str().unwrap()
    )));
}

#[test]
fn stage_runbook_decodes_the_proposal() {
    let Some(runbook) = v33_stage_runbook() else {
        return;
    };
    let markdown = render(&runbook);
    assert!(markdown.contains(
        "- **What tx 13 does, atomically:** `pauseMigration()` on `0xCEe1A9d2FE1c587B72F115974d33296C1F9ac35d`, \
         `setNewVersionUpgrade(...)` (v0.32.2 to v0.33.0) on Era CTM `0x8b448ac7cd0f18F3d8464E2645575772a26A3b6b`, \
         `setChainCreationParams(...)` on Era CTM `0x8b448ac7cd0f18F3d8464E2645575772a26A3b6b`, \
         `unpauseMigration()` on `0xCEe1A9d2FE1c587B72F115974d33296C1F9ac35d`."
    ));
    assert!(markdown.contains(
        "- **Checked on 2026-09-30:** owner nonce 843 before tx 1; all 13 txs succeed on a Sepolia \
         fork at block 11813648."
    ));
    assert_eq!(markdown.matches("(member Safe)").count(), 12);
}

// ─── chain 499 (`protocol_ops chain upgrade`) ────────────────────────────────────

#[test]
fn committed_chain_499_runbook_schedules_then_sends_the_ecosystem_toml_call() {
    let dir = repo_path(V33_STAGE_CHAIN_499);
    let Ok(markdown) = fs::read_to_string(dir.join(RUNBOOK_FILE)) else {
        return;
    };
    let toml: toml::Value =
        crate::common::files::read_toml_file(repo_path(V33_STAGE).join("ecosystem.toml")).unwrap();
    let upgrade = &toml["chain_upgrades"]["499"];
    let expected_to: Address = upgrade["chain_admin"].as_str().unwrap().parse().unwrap();
    let expected_data = upgrade["chain_admin_calldata"].as_str().unwrap();
    let rendered = read_back(&markdown);
    assert_eq!(rendered.len(), 3);
    // Txs 1 and 2 (`protocol_ops chain set-upgrade-timestamp`) tell the ChainAdmin and the
    // server about the upgrade, timestamp 1 meaning "as soon as the server sees it"; tx 3 is the
    // upgrade itself.
    let schedule = setUpgradeTimestampCall {
        _protocolVersion: U256::from(141_733_920_768u64),
        _upgradeTimestamp: U256::from(1u8),
    }
    .abi_encode();
    assert_eq!(rendered[0].to, expected_to);
    assert_eq!(rendered[0].data, schedule);
    assert_eq!(rendered[1].to, expected_to);
    assert_eq!(rendered[2].to, expected_to);
    assert_eq!(hex_of(&rendered[2].data), expected_data.to_lowercase());
    // Re-rendering the committed bundle reproduces the committed page.
    let mut runbook = load(&dir, &dir.join(RUNBOOK_FILE), &LoadOptions::default()).unwrap();
    runbook.facts = chain_499_facts(&markdown);
    assert_eq!(render(&runbook), markdown);
    assert!(markdown.contains("(ChainAdmin)"));
    assert!(markdown.contains("`setUpgradeTimestamp(uint256,uint256)` (chain 499 at timestamp 1)"));
    assert!(markdown.contains("`upgradeChainFromVersion(...)` (from v0.32.2) on ZK chain"));
}

/// The committed chain page was checked on a fork; its facts are read back from the page (the
/// check itself needs an RPC) and must name the bundle's sender.
fn chain_499_facts(markdown: &str) -> Option<CheckFacts> {
    let line = markdown
        .lines()
        .find(|line| line.starts_with("- **Checked on "))?;
    let date = line["- **Checked on ".len()..]
        .split(':')
        .next()?
        .to_string();
    let nonce: u64 = line
        .split(" nonce ")
        .nth(1)?
        .split(' ')
        .next()?
        .parse()
        .ok()?;
    let fork_block: u64 = line
        .split(" at block ")
        .nth(1)?
        .trim_end_matches('.')
        .parse()
        .ok()?;
    let sender: Address = markdown
        .lines()
        .find(|line| line.starts_with("- **Sender"))?
        .split('`')
        .nth(1)?
        .parse()
        .ok()?;
    Some(CheckFacts {
        fork_block,
        date,
        nonces: vec![(sender, nonce)],
        eoa_senders: if markdown.contains("the EOA `") {
            BTreeSet::from([sender])
        } else {
            BTreeSet::new()
        },
        replayed_after: None,
    })
}

// ─── multi-sender Safe bundles ───────────────────────────────────────────────────

fn write(path: &Path, content: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, content).unwrap();
}

fn safe_file(txs: &[(Address, U256, Vec<u8>)]) -> String {
    let txs: Vec<serde_json::Value> = txs
        .iter()
        .map(|(to, value, data)| {
            serde_json::json!({
                "to": format!("{to:#x}"),
                "value": value.to_string(),
                "data": hex_of(data),
                "contractMethod": null,
                "contractInputsValues": null,
            })
        })
        .collect();
    serde_json::to_string_pretty(&serde_json::json!({
        "version": "1.0",
        "chainId": "11155111",
        "createdAt": 1,
        "meta": { "name": "fixture", "description": "fixture" },
        "transactions": txs,
    }))
    .unwrap()
}

fn operation() -> Operation {
    Operation {
        calls: vec![Call {
            target: DIAMOND,
            value: U256::ZERO,
            data: setUpgradeTimestampCall {
                _protocolVersion: U256::from(141_733_920_768u64),
                _upgradeTimestamp: U256::from(1_790_000_000u64),
            }
            .abi_encode()
            .into(),
        }],
        predecessor: FixedBytes::ZERO,
        salt: FixedBytes::ZERO,
    }
}

/// Owner A schedules and executes a legacy Governance operation, owner B sends a ChainAdmin
/// multicall (with value) and approves a hash, then owner A again.
fn multi_sender_fixture(dir: &Path) -> PathBuf {
    let bundles = dir.join("sim-inputs");
    let schedule = scheduleTransparentCall {
        _operation: operation(),
        _delay: U256::from(3600u64),
    }
    .abi_encode();
    let execute = executeCall {
        _operation: operation(),
    }
    .abi_encode();
    let upgrade = upgradeChainFromVersionCall {
        _chain: DIAMOND,
        _oldProtocolVersion: U256::from(137_438_953_474u64),
        _cut: DiamondCutData {
            facetCuts: vec![],
            initAddress: Address::ZERO,
            initCalldata: Bytes::new(),
        },
    }
    .abi_encode();
    let multicall = multicallCall {
        _calls: vec![Call {
            target: DIAMOND,
            value: U256::ZERO,
            data: upgrade.into(),
        }],
        _requireSuccess: true,
    }
    .abi_encode();
    let approve = approveHashCall {
        hashToApprove: FixedBytes::repeat_byte(7),
    }
    .abi_encode();
    write(
        &bundles.join("01_a.safe.json"),
        &safe_file(&[
            (GOVERNANCE, U256::ZERO, schedule),
            (GOVERNANCE, U256::ZERO, execute),
        ]),
    );
    write(
        &bundles.join("02_b.safe.json"),
        &safe_file(&[
            (CHAIN_ADMIN, U256::from(5u8), multicall),
            (GOVERNANCE, U256::ZERO, approve),
        ]),
    );
    write(
        &bundles.join("03_a.safe.json"),
        &safe_file(&[(GOVERNANCE, U256::ZERO, vec![0xde, 0xad, 0xbe, 0xef])]),
    );
    write(
        &bundles.join("manifest.json"),
        &serde_json::json!({
            "bundles": [
                { "index": 1, "file": "01_a.safe.json", "target": format!("{OWNER_A:#x}"), "steps": ["fixture.a"] },
                { "index": 2, "file": "02_b.safe.json", "target": format!("{OWNER_B:#x}"), "steps": ["fixture.b"] },
                { "index": 3, "file": "03_a.safe.json", "target": format!("{OWNER_A:#x}"), "steps": [] },
            ],
            "metadata": [
                { "command": "chain.upgrade", "input": {}, "output": {
                    "admin_address": format!("{CHAIN_ADMIN:#x}"),
                    "chain_address": format!("{DIAMOND:#x}"),
                    "chain_id": 499,
                } },
            ],
        })
        .to_string(),
    );
    bundles
}

#[test]
fn safe_bundles_get_one_section_per_run_of_one_sender() {
    let dir = tempfile::tempdir().unwrap();
    let bundles = multi_sender_fixture(dir.path());
    let out = default_runbook_path(&bundles).unwrap();
    assert_eq!(out, bundles.parent().unwrap().join(RUNBOOK_FILE));
    let options = LoadOptions {
        names: [(GOVERNANCE, "legacy Governance".to_string())].into(),
        ..Default::default()
    };
    let runbook = load(&bundles, &out, &options).unwrap();
    assert_eq!(runbook.chain_id, 11_155_111);
    assert_eq!(runbook.title, "Upgrade: chain 499 execution (Sepolia)");
    let markdown = render(&runbook);
    assert_round_trips(&runbook, &markdown);

    let a = OWNER_A.to_checksum(None);
    let b = OWNER_B.to_checksum(None);
    assert!(markdown.contains(&format!(
        "- **Senders (2 accounts; switch accounts between sections):** txs 1 to 2 from `{a}`; \
         txs 3 to 4 from `{b}`; tx 5 from `{a}`."
    )));
    assert!(markdown.contains(&format!("## Txs 1 to 2: send from `{a}`")));
    assert!(markdown.contains(&format!("## Txs 3 to 4: send from `{b}`")));
    assert!(markdown.contains(&format!("## Tx 5: send from `{a}`")));
    assert!(markdown.contains(
        "Safe Transaction Builder file for these txs: [`02_b.safe.json`](./sim-inputs/02_b.safe.json)."
    ));
    // The scheduled operation, and the execute that depends on it and its delay.
    assert!(markdown.contains(
        "- **What tx 1 schedules:** `setUpgradeTimestamp(uint256,uint256)` (v0.33.0 at timestamp 1790000000) on ZK chain"
    ));
    assert!(markdown.contains(
        "- **What tx 2 does:** executes, atomically, the operation tx 1 schedules; it reverts unless \
         tx 1 is mined first and its delay 3600 s has passed."
    ));
    assert!(markdown.contains("- **What tx 3 does, atomically:** `upgradeChainFromVersion(...)` (from v0.32.2) on ZK chain"));
    // Nonzero value: a Value column, and MetaMask told to use it.
    assert!(markdown.contains("| #   | Label"));
    assert!(markdown.contains("| Value  |") || markdown.contains("| Value |"));
    assert!(markdown.contains("| 5 wei  |") || markdown.contains("| 5 wei |"));
    assert!(markdown.contains("amount = the Value column"));
    // Names from the manifest's command record, and the caller's.
    assert!(markdown.contains(&format!("`{}` (ChainAdmin)", CHAIN_ADMIN.to_checksum(None))));
    assert!(markdown.contains("(legacy Governance)"));
    // Labels from the manifest steps; an unknown selector shows its four bytes.
    assert!(markdown.contains("| fixture.a: bundle 1 tx 1 |"));
    assert!(markdown.contains("`0xdeadbeef` (unknown function)"));
}

#[test]
fn rendering_is_deterministic() {
    let dir = tempfile::tempdir().unwrap();
    let bundles = multi_sender_fixture(dir.path());
    let out = default_runbook_path(&bundles).unwrap();
    let first = render(&load(&bundles, &out, &LoadOptions::default()).unwrap());
    let second = render(&load(&bundles, &out, &LoadOptions::default()).unwrap());
    assert_eq!(first, second);
}

// ─── transaction-simulator JSON ──────────────────────────────────────────────────

#[test]
fn simulator_lists_keep_their_descriptions_and_drop_excluded_tags() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("transaction-simulator.json");
    let approve = hex_of(
        &approveHashCall {
            hashToApprove: FixedBytes::repeat_byte(1),
        }
        .abi_encode(),
    );
    write(
        &path,
        &serde_json::json!([
            { "description": "approve it", "network": "sepolia", "from": format!("{OWNER_A:#x}"),
              "to": format!("{GOVERNANCE:#x}"), "data": approve, "value": "0", "valueToMint": "1", "tag": "bundle_1" },
            { "description": "later", "network": "sepolia", "from": format!("{OWNER_B:#x}"),
              "to": format!("{GOVERNANCE:#x}"), "data": "0x79ba5097", "value": "0", "timeIncrease": 60, "tag": "stage1" },
            { "description": "test only", "network": "sepolia", "from": format!("{OWNER_B:#x}"),
              "to": format!("{DIAMOND:#x}"), "data": "0x", "value": "0", "emulateAllBatchesExecuted": true, "tag": "test_upgrade_chain_era" },
        ])
        .to_string(),
    );
    let out = dir.path().join(RUNBOOK_FILE);
    let error = load(&path, &out, &LoadOptions::default()).unwrap_err();
    assert!(
        format!("{error:#}").contains("cannot be sent by hand"),
        "{error:#}"
    );

    let options = LoadOptions {
        exclude_tags: vec!["test_".to_string()],
        ..Default::default()
    };
    let runbook = load(&path, &out, &options).unwrap();
    assert_eq!(runbook.chain_id, 11_155_111);
    assert_eq!(runbook.txs.len(), 2);
    let markdown = render(&runbook);
    assert_round_trips(&runbook, &markdown);
    assert!(markdown.contains("| approve it |"));
    assert!(markdown.contains("`acceptOwnership()`"));
    assert!(markdown.contains("- **Before tx 2:** the simulator advances time by 60 s here"));
}

// ─── errors ──────────────────────────────────────────────────────────────────────

/// The emergency-upgrade-board list of the v0.33.0 stage upgrade, kept as test data so these
/// checks run on branches that do not carry that upgrade's directory.
const EMERGENCY_BOARD_FIXTURE: &str =
    "src/common/execution_runbook/testdata/emergency-upgrade-board.json";

fn emergency_fixture(dir: &Path, edit: impl FnOnce(&mut serde_json::Value)) -> PathBuf {
    let source = repo_path(EMERGENCY_BOARD_FIXTURE);
    let mut json: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(source).unwrap()).unwrap();
    edit(&mut json);
    let path = dir.join("emergency-upgrade-board.json");
    write(&path, &json.to_string());
    path
}

fn load_error(path: &Path, options: &LoadOptions) -> String {
    let out = path.parent().unwrap().join(RUNBOOK_FILE);
    format!("{:#}", load(path, &out, options).unwrap_err())
}

#[test]
fn emergency_lists_reject_value_and_malformed_proposals() {
    let sepolia = LoadOptions {
        chain_id: Some(11_155_111),
        ..Default::default()
    };
    let dir = tempfile::tempdir().unwrap();

    let path = emergency_fixture(dir.path(), |json| {
        json["transactions"][12]["value"] = serde_json::json!("1");
    });
    let error = load_error(&path, &sepolia);
    assert!(error.contains("tx 13 (EXECUTE) sends value 1"), "{error}");

    let path = emergency_fixture(dir.path(), |json| {
        json["transactions"][3]["from"] = serde_json::json!(format!("{OWNER_A:#x}"));
    });
    let error = load_error(&path, &sepolia);
    assert!(error.contains("only the owner"), "{error}");

    let path = emergency_fixture(dir.path(), |json| {
        json["transactions"].as_array_mut().unwrap().pop();
    });
    let error = load_error(&path, &sepolia);
    assert!(
        error.contains("the last tx must call executeEmergencyUpgrade"),
        "{error}"
    );

    let path = emergency_fixture(dir.path(), |json| {
        json["transactions"][1]["step"] = serde_json::json!(7);
    });
    assert!(load_error(&path, &sepolia).contains("steps must be 1..13 in order"));

    // The list names no chain: it has to come from the caller, and must agree with the list.
    let path = emergency_fixture(dir.path(), |_| {});
    assert!(load_error(&path, &LoadOptions::default()).contains("records no chain id"));
    let path = emergency_fixture(dir.path(), |json| {
        json["chain_id"] = serde_json::json!(1);
    });
    assert!(load_error(&path, &sepolia).contains("is for chain 1, expected chain 11155111"));
}

#[test]
fn unknown_formats_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("x.json");
    write(&path, r#"{"calls": []}"#);
    assert!(load_error(&path, &LoadOptions::default()).contains("unknown transaction list format"));
    write(&path, "[]");
    assert!(load_error(&path, &LoadOptions::default()).contains("unknown transaction list format"));
    write(&path, "not json");
    assert!(load_error(&path, &LoadOptions::default()).contains("as JSON"));
    // A lone Safe Transaction Builder file has no sender.
    write(
        &path,
        &safe_file(&[(GOVERNANCE, U256::ZERO, vec![0x79, 0xba, 0x50, 0x97])]),
    );
    assert!(load_error(&path, &LoadOptions::default()).contains("does not record its sender"));
}

// ─── decoding and helpers ────────────────────────────────────────────────────────

#[test]
fn known_functions_have_the_selectors_the_contracts_use() {
    let expected = [
        ("0xd4d9bdcd", "`approveHash(bytes32)`"),
        ("0xc03fd44b", "`executeEmergencyUpgrade(...)`"),
        ("0xa1dcb9b8", "`execute(...)`"),
        ("0x2c431917", "`scheduleTransparent(...)`"),
        ("0x74da756b", "`execute(...)`"),
        ("0x95218ecd", "`executeInstant(...)`"),
        ("0x69340beb", "`multicall(...)`"),
        ("0xe2a9d554", "`setUpgradeTimestamp(uint256,uint256)`"),
        ("0x3b6d7534", "`upgradeChainFromVersion(...)`"),
        ("0xfc57565f", "`upgradeChainFromVersion(...)`"),
        ("0x8265f458", "`setNewVersionUpgrade(...)`"),
        ("0x9b016b8b", "`setChainCreationParams(...)`"),
        ("0xac700e63", "`pauseMigration()`"),
        ("0xf7c7eb92", "`unpauseMigration()`"),
        ("0x79ba5097", "`acceptOwnership()`"),
        ("0xf2fde38b", "`transferOwnership(address)`"),
        ("0x0e18b681", "`acceptAdmin()`"),
        ("0x4dd18bf5", "`setPendingAdmin(address)`"),
        ("0x99a88ec4", "`upgrade(address,address)`"),
        ("0x9623609d", "`upgradeAndCall(address,address,bytes)`"),
    ];
    for (selector, display) in expected {
        assert_eq!(
            decode::call_display(&hex::decode(selector.trim_start_matches("0x")).unwrap()),
            display,
            "{selector}"
        );
    }
    assert_eq!(
        decode::call_display(&[0x12, 0x34, 0x56, 0x78]),
        "`0x12345678` (unknown function)"
    );
    assert_eq!(decode::call_display(&[]), "none (plain transfer)");
}

#[test]
fn values_parse_as_decimal_or_hex() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("transaction-simulator.json");
    write(
        &path,
        &serde_json::json!([
            { "description": "hex", "network": "sepolia", "from": format!("{OWNER_A:#x}"),
              "to": format!("{GOVERNANCE:#x}"), "data": "0x79ba5097", "value": "0x10" },
            { "description": "number", "network": "sepolia", "from": format!("{OWNER_A:#x}"),
              "to": format!("{GOVERNANCE:#x}"), "data": "0x79ba5097", "value": 7 },
        ])
        .to_string(),
    );
    let runbook = load(
        &path,
        &dir.path().join(RUNBOOK_FILE),
        &LoadOptions::default(),
    )
    .unwrap();
    assert_eq!(runbook.txs[0].value, U256::from(16u8));
    assert_eq!(runbook.txs[1].value, U256::from(7u8));
}

#[test]
fn protocol_versions_unpack() {
    assert_eq!(protocol_version(U256::from(137_438_953_474u64)), "v0.32.2");
    assert_eq!(protocol_version(U256::from(141_733_920_768u64)), "v0.33.0");
    assert_eq!(protocol_version(U256::from(1u128 << 64)), "v1.0.0");
    assert_eq!(protocol_version(U256::MAX), U256::MAX.to_string());
}

#[test]
fn upgrade_timestamps_name_a_version_or_a_chain() {
    let chain_admin = setUpgradeTimestampCall {
        _protocolVersion: U256::from(141_733_920_768u64),
        _upgradeTimestamp: U256::from(1u8),
    }
    .abi_encode();
    assert_eq!(
        decode::annotation(&chain_admin).as_deref(),
        Some("v0.33.0 at timestamp 1")
    );
    // ServerNotifier.setUpgradeTimestamp(chainId, ts) has the same selector, chain id first.
    let server_notifier = setUpgradeTimestampCall {
        _protocolVersion: U256::from(499u16),
        _upgradeTimestamp: U256::from(1u8),
    }
    .abi_encode();
    assert_eq!(
        decode::annotation(&server_notifier).as_deref(),
        Some("chain 499 at timestamp 1")
    );
}

#[test]
fn links_are_relative_to_the_runbook() {
    let root = Path::new("/a/output/stage");
    assert_eq!(
        relative_link(root, &root.join("emergency-upgrade-board.json")),
        "./emergency-upgrade-board.json"
    );
    assert_eq!(
        relative_link(root, &root.join("sim-inputs/manifest.json")),
        "./sim-inputs/manifest.json"
    );
    assert_eq!(
        relative_link(&root.join("chain-upgrades/499"), &root.join("x.json")),
        "../../x.json"
    );
}

/// `prettier --check` on every page these tests render, when `RUNBOOK_PRETTIER` names a prettier
/// binary (the tests themselves need no Node).
#[test]
fn rendered_pages_are_prettier_stable() {
    let Ok(prettier) = std::env::var("RUNBOOK_PRETTIER") else {
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let bundles = multi_sender_fixture(dir.path());
    let out = default_runbook_path(&bundles).unwrap();
    let mut pages = vec![render(
        &load(&bundles, &out, &LoadOptions::default()).unwrap(),
    )];
    pages.extend(v33_stage_runbook().map(|runbook| render(&runbook)));
    let mut files = Vec::new();
    for (i, page) in pages.iter().enumerate() {
        let path = dir.path().join(format!("page-{i}.md"));
        fs::write(&path, page).unwrap();
        files.push(path);
    }
    let status = std::process::Command::new(prettier)
        .arg("--check")
        .args(&files)
        .status()
        .unwrap();
    assert!(status.success(), "prettier would reformat a rendered page");
}
