//! Human-readable descriptions of the transactions in a transaction-simulator scenario, derived
//! from their calldata and from the addresses an upgrade's artifacts name. A call to a function
//! outside [`calldata`]'s table is an error, so every description is complete.

use std::collections::{BTreeMap, HashSet};

use alloy::dyn_abi::DynSolValue;
use alloy::primitives::{Address, U256};

use crate::common::calldata::{
    self, as_address, as_uint, protocol_version, upgrade_timestamp_subject,
    UpgradeTimestampSubject, ANY_CONTRACT,
};
use crate::common::env_config::{EnvConfig, GovernanceKind};
use crate::common::execution_runbook;

/// `setUpgradeTimestamp`'s "no waiting" value: 0 is the unset sentinel, so 1 is the earliest.
const UPGRADE_TIMESTAMP_NOW: u64 = 1;

/// Key suffixes of an ecosystem TOML that mark an implementation behind a proxy.
const IMPLEMENTATION_SUFFIXES: &[&str] = &["_implementation", "_impl"];

/// How [`key_name`] marks an implementation behind a proxy.
const IMPLEMENTATION_LABEL: &str = " implementation";

/// Key suffixes of an ecosystem TOML that carry no meaning in the contract's name.
const NOISE_SUFFIXES: &[&str] = &["_addr", "_proxy"];

/// Key words of an ecosystem TOML written in capitals in a contract name.
const ACRONYMS: &[(&str, &str)] = &[
    ("l1", "L1"),
    ("l2", "L2"),
    ("ctm", "CTM"),
    ("da", "DA"),
    ("erc20", "ERC20"),
    ("eip7702", "EIP7702"),
    ("zk", "ZK"),
];

/// Ecosystem TOML keys whose name, built the generic way, would mislead.
const KEY_NAMES: &[(&str, &str)] = &[
    ("l1_governance_upgrade_timer", "GovernanceUpgradeTimer"),
    ("chain_type_manager_proxy", "ChainTypeManager"),
    ("transparent_proxy_admin", "ProxyAdmin"),
    // An upgrade's artifact records the verifiers it deploys.
    ("verifier_addr", "new Verifier"),
    ("verifier_plonk_addr", "new PLONK verifier"),
    ("verifier_fflonk_addr", "new FFLONK verifier"),
    ("native_token_vault_addr", "L1NativeTokenVault"),
];

/// Ecosystem TOML sections whose addresses are senders or owners, never call targets.
const SENDER_SECTIONS: &[&str] = &["admin", "deploy_calls", "misc", "test_upgrade_calls"];

/// Names of the addresses a scenario touches.
#[derive(Debug, Default, Clone)]
pub struct Names(BTreeMap<Address, String>);

impl Names {
    /// The names the env's permanent values give (bridgehub, CTMs, governance, ChainAdmins).
    pub fn from_env(env_cfg: &EnvConfig) -> Self {
        Self(execution_runbook::env_names(env_cfg))
    }

    /// Name `address`, unless it already has a name.
    pub fn insert(&mut self, address: Address, name: String) {
        if address != Address::ZERO {
            self.0.entry(address).or_insert(name);
        }
    }

    pub fn get(&self, address: Address) -> Option<&str> {
        self.0.get(&address).map(String::as_str)
    }

    pub fn as_map(&self) -> &BTreeMap<Address, String> {
        &self.0
    }

    /// Name every contract an ecosystem TOML records: each `[chain_upgrades.<id>]` chain and its
    /// ChainAdmin, and every other address-valued key after the key itself.
    pub fn add_ecosystem_toml(&mut self, toml: &toml::Table) {
        if let Some(toml::Value::Table(chains)) = toml.get("chain_upgrades") {
            for (chain_id, entry) in chains {
                let address = |key: &str| {
                    entry
                        .get(key)
                        .and_then(toml::Value::as_str)
                        .and_then(|value| value.parse::<Address>().ok())
                };
                if let Some(chain) = address("chain") {
                    self.insert(chain, format!("chain {chain_id}"));
                }
                if let Some(admin) = address("chain_admin") {
                    self.insert(admin, format!("chain {chain_id}'s ChainAdmin"));
                }
            }
        }
        for (section, value) in toml {
            if section != "chain_upgrades" && !SENDER_SECTIONS.contains(&section.as_str()) {
                self.add_keys(value);
            }
        }
    }

    fn add_keys(&mut self, value: &toml::Value) {
        let toml::Value::Table(table) = value else {
            return;
        };
        for (key, value) in table {
            match value {
                toml::Value::String(text) => {
                    if let Ok(address) = text.parse::<Address>() {
                        self.insert(address, key_name(key));
                    }
                }
                toml::Value::Table(_) => {
                    if !SENDER_SECTIONS.contains(&key.as_str()) {
                        self.add_keys(value);
                    }
                }
                _ => {}
            }
        }
    }

    /// Name the chain and its ChainAdmin that a per-chain manifest's metadata records.
    pub fn add_chain_manifest_metadata(&mut self, metadata: &[serde_json::Value]) {
        for entry in metadata {
            let output = &entry["output"];
            let Some(chain_id) = output["chain_id"].as_u64() else {
                continue;
            };
            let address = |key: &str| {
                output[key]
                    .as_str()
                    .and_then(|value| value.parse::<Address>().ok())
            };
            if let Some(chain) = address("chain_address") {
                self.insert(chain, format!("chain {chain_id}"));
            }
            if let Some(admin) = address("admin_address") {
                self.insert(admin, format!("chain {chain_id}'s ChainAdmin"));
            }
            if let Some(bridgehub) = address("bridgehub") {
                self.insert(bridgehub, "Bridgehub".to_string());
            }
        }
    }

    fn display(&self, address: Address) -> String {
        self.get(address)
            .map(str::to_string)
            .unwrap_or_else(|| address.to_checksum(None))
    }
}

/// The contract name an ecosystem TOML key stands for, e.g. `upgrade_stage_validator` →
/// `UpgradeStageValidator`, `admin_facet_addr` → `AdminFacet`,
/// `bridgehub_implementation_addr` → `Bridgehub implementation`.
fn key_name(key: &str) -> String {
    if let Some((_, name)) = KEY_NAMES.iter().find(|(known, _)| *known == key) {
        return name.to_string();
    }
    let mut stem = key;
    for suffix in NOISE_SUFFIXES {
        stem = stem.strip_suffix(suffix).unwrap_or(stem);
    }
    let mut implementation = false;
    for suffix in IMPLEMENTATION_SUFFIXES {
        if let Some(rest) = stem.strip_suffix(suffix) {
            stem = rest;
            implementation = true;
        }
    }
    for suffix in NOISE_SUFFIXES {
        stem = stem.strip_suffix(suffix).unwrap_or(stem);
    }
    let camel: String = stem
        .split('_')
        .map(
            |word| match ACRONYMS.iter().find(|(lower, _)| *lower == word) {
                Some((_, upper)) => upper.to_string(),
                None => {
                    let mut chars = word.chars();
                    chars
                        .next()
                        .map(|first| first.to_uppercase().chain(chars).collect())
                        .unwrap_or_default()
                }
            },
        )
        .collect();
    if implementation {
        format!("{camel}{IMPLEMENTATION_LABEL}")
    } else {
        camel
    }
}

/// Describes a scenario's transactions in order: some descriptions depend on what came before
/// (`pauseMigration` the second time).
pub struct Describer {
    names: Names,
    governance_kind: Option<GovernanceKind>,
    seen: HashSet<String>,
}

impl Describer {
    /// `governance_kind` is the env's, when the scenario has one.
    pub fn new(names: Names, governance_kind: Option<GovernanceKind>) -> Self {
        Self {
            names,
            governance_kind,
            seen: HashSet::new(),
        }
    }

    pub fn names(&self) -> &Names {
        &self.names
    }

    /// What the call does, e.g. `start the governance upgrade timer (GovernanceUpgradeTimer.startTimer)`.
    pub fn describe_call(&mut self, target: Address, data: &[u8]) -> anyhow::Result<String> {
        if data.is_empty() {
            return Ok(format!("plain transfer to {}", self.names.display(target)));
        }
        let (known, args) = calldata::decode(data).ok_or_else(|| {
            anyhow::anyhow!(
                "call to {} with selector 0x{} is not a function protocol-ops can describe: add it \
                 to KNOWN_FUNCTIONS in protocol-ops/src/common/calldata.rs",
                target.to_checksum(None),
                alloy::hex::encode(data.get(..4).unwrap_or(data))
            )
        })?;
        let function = known.function.name.as_str();
        let kind = contract_kind(known.contract, function, &args);
        let instance = self
            .names
            .get(target)
            .map(str::to_string)
            .or_else(|| kind.clone())
            .unwrap_or_else(|| target.to_checksum(None));

        if let Some(wrapped) = calldata::wrapped(data) {
            let inner = wrapped
                .calls
                .iter()
                .map(|call| self.describe_call(call.target, &call.data))
                .collect::<anyhow::Result<Vec<_>>>()?;
            return Ok(format!("{instance}.{function}: {}", inner.join("; ")));
        }

        let action = self.action(function, target, &args);
        self.seen.insert(function.to_string());
        Ok(match action {
            Some(action) => format!("{action} ({}.{function})", kind.unwrap_or(instance)),
            None => format!("{instance}.{function}({})", self.args_display(&args)),
        })
    }

    /// The protocol-level meaning of a call, for the functions an upgrade sends.
    fn action(&self, function: &str, target: Address, args: &[DynSolValue]) -> Option<String> {
        let uint = |i: usize| args.get(i).and_then(as_uint);
        let address = |i: usize| {
            args.get(i)
                .and_then(as_address)
                .map(|a| self.names.display(a))
        };
        let version = |i: usize| uint(i).map(protocol_version);
        Some(match function {
            "pauseMigration" if self.seen.contains("pauseMigration") => {
                match self.governance_kind {
                    Some(GovernanceKind::Puh) => "pause chain migrations again: \
                        ProtocolUpgradeHandler.executeEmergencyUpgrade unpauses them before a \
                        proposal's calls"
                        .to_string(),
                    _ => "pause chain migrations again".to_string(),
                }
            }
            "pauseMigration" => {
                "pause chain migrations, which the CTM requires to take a new version".to_string()
            }
            "unpauseMigration" => "unpause chain migrations".to_string(),
            "startTimer" => "start the governance upgrade timer".to_string(),
            "checkDeadline" => {
                "check the governance upgrade timer's deadline has passed".to_string()
            }
            "checkMigrationsPaused" => "check chain migrations are paused".to_string(),
            "checkProtocolUpgradePresence" => {
                "check the new protocol version is registered on the CTM".to_string()
            }
            "checkMigrationsUnpaused" => "check chain migrations are unpaused".to_string(),
            "createNewVerifierOnlyUpgrade" => {
                let deadline = uint(1)?;
                let until = if deadline == U256::MAX {
                    String::new()
                } else {
                    format!(", {} valid until {deadline}", version(0)?)
                };
                format!(
                    "register {} as an upgrade of {} with {}{until}",
                    version(2)?,
                    version(0)?,
                    self.verifier_display(args.get(3).and_then(as_address)?)
                )
            }
            "setNewVersionUpgrade" => format!(
                "register the {} → {} upgrade cut with {}",
                version(1)?,
                version(3)?,
                self.verifier_display(args.get(4).and_then(as_address)?)
            ),
            "setChainCreationParams" => "set the chain creation params".to_string(),
            "setDefaultUpgrade" => format!("set the default upgrade to {}", address(0)?),
            "upgradeChainFromVersion" => {
                let (chain, old) = if args.len() == 3 {
                    (address(0)?, version(1)?)
                } else {
                    (self.names.display(target), version(0)?)
                };
                format!("upgrade {chain} from {old} with the CTM's stored cut")
            }
            "setUpgradeTimestamp" => {
                let timestamp = uint(1)?;
                let when = if timestamp == U256::from(UPGRADE_TIMESTAMP_NOW) {
                    format!("{timestamp}, i.e. without waiting")
                } else {
                    timestamp.to_string()
                };
                match upgrade_timestamp_subject(uint(0)?) {
                    UpgradeTimestampSubject::Chain(chain_id) => {
                        format!("set chain {chain_id}'s upgrade timestamp to {when}")
                    }
                    UpgradeTimestampSubject::Version(old) => format!(
                        "set the upgrade timestamp from {} to {when}",
                        protocol_version(old)
                    ),
                }
            }
            "createNewChain" => format!("create chain {} on {}", uint(0)?, address(1)?),
            "acceptOwnership" => format!("accept ownership of {}", self.names.display(target)),
            "transferOwnership" => format!(
                "transfer ownership of {} to {}",
                self.names.display(target),
                address(0)?
            ),
            "acceptAdmin" => format!("accept the admin role of {}", self.names.display(target)),
            "setPendingAdmin" => format!(
                "propose {} as the admin of {}",
                address(0)?,
                self.names.display(target)
            ),
            "upgrade" => {
                let (proxy, implementation) = self.proxy_upgrade_display(args)?;
                format!("upgrade {proxy} to {implementation}")
            }
            "upgradeAndCall" => {
                let (proxy, implementation) = self.proxy_upgrade_display(args)?;
                format!("upgrade {proxy} to {implementation} and initialize it")
            }
            _ => return None,
        })
    }

    /// The proxy and the implementation of a `ProxyAdmin.upgrade(proxy, implementation)`. When the
    /// artifact names only one of them, the other is called after it.
    fn proxy_upgrade_display(&self, args: &[DynSolValue]) -> Option<(String, String)> {
        let proxy = args.first().and_then(as_address)?;
        let implementation = args.get(1).and_then(as_address)?;
        Some(
            match (self.names.get(proxy), self.names.get(implementation)) {
                (None, Some(implementation_name)) => {
                    let contract = implementation_name
                        .strip_suffix(IMPLEMENTATION_LABEL)
                        .unwrap_or(implementation_name);
                    (
                        format!("the {contract} proxy {}", proxy.to_checksum(None)),
                        implementation_name.to_string(),
                    )
                }
                (Some(proxy_name), None) => (
                    proxy_name.to_string(),
                    format!(
                        "a new {proxy_name}{IMPLEMENTATION_LABEL} {}",
                        implementation.to_checksum(None)
                    ),
                ),
                _ => (
                    self.names.display(proxy),
                    self.names.display(implementation),
                ),
            },
        )
    }

    /// `the new Verifier` when the artifact names it, `verifier 0x…` otherwise.
    fn verifier_display(&self, verifier: Address) -> String {
        match self.names.get(verifier) {
            Some(name) => format!("the {name}"),
            None => format!("verifier {}", verifier.to_checksum(None)),
        }
    }

    fn args_display(&self, args: &[DynSolValue]) -> String {
        args.iter()
            .map(|arg| self.value_display(arg))
            .collect::<Vec<_>>()
            .join(", ")
    }

    fn value_display(&self, value: &DynSolValue) -> String {
        match value {
            DynSolValue::Address(address) => self.names.display(*address),
            DynSolValue::Uint(value, _) => value.to_string(),
            DynSolValue::Bool(value) => value.to_string(),
            DynSolValue::FixedBytes(word, size) => {
                format!("0x{}", alloy::hex::encode(&word[..*size]))
            }
            DynSolValue::Bytes(bytes) => format!("<{} bytes>", bytes.len()),
            _ => "(…)".to_string(),
        }
    }
}

/// The contract type a call goes to, from the function it calls; `None` for a function several
/// contracts define (`acceptOwnership`, ...).
fn contract_kind(defining: &str, function: &str, args: &[DynSolValue]) -> Option<String> {
    if function == "setUpgradeTimestamp" {
        if let Some(UpgradeTimestampSubject::Version(_)) = args
            .first()
            .and_then(as_uint)
            .map(upgrade_timestamp_subject)
        {
            return Some("ChainAdmin".to_string());
        }
    }
    (defining != ANY_CONTRACT).then(|| defining.to_string())
}

/// `<what the tag is>: <what the call does>`, the description a scenario carries.
pub fn tagged(tag: &str, call_description: &str) -> String {
    format!("{}: {call_description}", tag_display(tag))
}

/// How a scenario tag reads at the start of a description: `stage1` → `Stage 1`,
/// `chain_upgrade_4221_schedule` → `Chain 4221, schedule`.
fn tag_display(tag: &str) -> String {
    if let Some(stage) = tag.strip_prefix("stage") {
        return format!("Stage {stage}");
    }
    if let Some(rest) = tag.strip_prefix("chain_upgrade_") {
        return match rest.split_once('_') {
            Some((chain_id, phase)) => format!("Chain {chain_id}, {phase}"),
            None => format!("Chain {rest}"),
        };
    }
    if let Some(bundle) = tag.strip_prefix("bundle_") {
        return format!("Bundle {bundle}");
    }
    if tag.starts_with("test_") {
        return "Test".to_string();
    }
    if tag.starts_with("ctm_admin_calls") {
        return "CTM admin calls".to_string();
    }
    tag.to_string()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use alloy::sol_types::SolCall;

    use super::*;

    alloy::sol! {
        struct Call { address target; uint256 value; bytes data; }
        function multicall(Call[] calls, bool requireSuccess);
        function setUpgradeTimestamp(uint256 first, uint256 timestamp);
        function pauseMigration();
        function startTimer();
        function createNewVerifierOnlyUpgrade(uint256 oldVersion, uint256 deadline, uint256 newVersion, address verifier);
    }

    const V0_33_0: u64 = 0x21_0000_0000;
    const V0_33_2: u64 = 0x21_0000_0002;

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    #[test]
    fn ecosystem_keys_become_contract_names() {
        assert_eq!(key_name("upgrade_stage_validator"), "UpgradeStageValidator");
        assert_eq!(key_name("admin_facet_addr"), "AdminFacet");
        assert_eq!(key_name("l1_asset_router_proxy_addr"), "L1AssetRouter");
        assert_eq!(
            key_name("bridgehub_implementation_addr"),
            "Bridgehub implementation"
        );
        assert_eq!(
            key_name("bridged_standard_erc20_impl"),
            "BridgedStandardERC20 implementation"
        );
        assert_eq!(
            key_name("l1_governance_upgrade_timer"),
            "GovernanceUpgradeTimer"
        );
        assert_eq!(key_name("verifier_plonk_addr"), "new PLONK verifier");
    }

    #[test]
    fn a_wrapped_server_notifier_call_reads_as_the_chain_it_schedules() {
        let mut names = Names::default();
        names.insert(address(1), "chain 4221's ChainAdmin".to_string());
        let mut describer = Describer::new(names, None);
        let inner = setUpgradeTimestampCall {
            first: U256::from(4221u16),
            timestamp: U256::from(UPGRADE_TIMESTAMP_NOW),
        }
        .abi_encode();
        let data = multicallCall {
            calls: vec![Call {
                target: address(2),
                value: U256::ZERO,
                data: inner.into(),
            }],
            requireSuccess: true,
        }
        .abi_encode();
        assert_eq!(
            tagged(
                "chain_upgrade_4221_schedule",
                &describer.describe_call(address(1), &data).unwrap()
            ),
            "Chain 4221, schedule: chain 4221's ChainAdmin.multicall: set chain 4221's upgrade \
             timestamp to 1, i.e. without waiting (ServerNotifier.setUpgradeTimestamp)"
        );
    }

    #[test]
    fn a_second_pause_says_why_under_a_protocol_upgrade_handler() {
        let mut describer = Describer::new(Names::default(), Some(GovernanceKind::Puh));
        let pause = pauseMigrationCall {}.abi_encode();
        let first = describer.describe_call(address(3), &pause).unwrap();
        assert_eq!(
            first,
            "pause chain migrations, which the CTM requires to take a new version \
             (ChainAssetHandler.pauseMigration)"
        );
        let second = describer.describe_call(address(3), &pause).unwrap();
        assert!(second.starts_with("pause chain migrations again: ProtocolUpgradeHandler"));
    }

    #[test]
    fn versions_and_verifiers_are_spelled_out() {
        let mut names = Names::default();
        names.insert(address(4), "new Verifier".to_string());
        let mut describer = Describer::new(names, None);
        let data = createNewVerifierOnlyUpgradeCall {
            oldVersion: U256::from(V0_33_0),
            deadline: U256::MAX,
            newVersion: U256::from(V0_33_2),
            verifier: address(4),
        }
        .abi_encode();
        assert_eq!(
            describer.describe_call(address(5), &data).unwrap(),
            "register v0.33.2 as an upgrade of v0.33.0 with the new Verifier \
             (ChainTypeManager.createNewVerifierOnlyUpgrade)"
        );
    }

    #[test]
    fn an_unknown_function_is_an_error_not_a_placeholder() {
        let mut describer = Describer::new(Names::default(), None);
        let error = describer
            .describe_call(address(6), &[0x12, 0x34, 0x56, 0x78])
            .unwrap_err()
            .to_string();
        assert!(error.contains("0x12345678"), "{error}");
        assert!(error.contains("KNOWN_FUNCTIONS"), "{error}");
    }

    #[test]
    fn a_named_target_is_called_by_its_name() {
        let mut names = Names::default();
        names.insert(address(7), "GovernanceUpgradeTimer".to_string());
        let mut describer = Describer::new(names, None);
        assert_eq!(
            describer
                .describe_call(address(7), &startTimerCall {}.abi_encode())
                .unwrap(),
            "start the governance upgrade timer (GovernanceUpgradeTimer.startTimer)"
        );
    }

    #[test]
    fn a_proxy_upgrade_borrows_the_name_of_its_named_side() {
        alloy::sol! { function upgrade(address proxy, address implementation); }
        let mut names = Names::default();
        names.insert(address(8), "ServerNotifier implementation".to_string());
        names.insert(address(9), "BytecodesSupplier".to_string());
        let mut describer = Describer::new(names, None);
        let unnamed_proxy = upgradeCall {
            proxy: address(10),
            implementation: address(8),
        }
        .abi_encode();
        assert_eq!(
            describer.describe_call(address(11), &unnamed_proxy).unwrap(),
            format!(
                "upgrade the ServerNotifier proxy {} to ServerNotifier implementation (ProxyAdmin.upgrade)",
                address(10).to_checksum(None)
            )
        );
        let unnamed_implementation = upgradeCall {
            proxy: address(9),
            implementation: address(12),
        }
        .abi_encode();
        assert_eq!(
            describer.describe_call(address(11), &unnamed_implementation).unwrap(),
            format!(
                "upgrade BytecodesSupplier to a new BytecodesSupplier implementation {} (ProxyAdmin.upgrade)",
                address(12).to_checksum(None)
            )
        );
    }

    /// Every call of the committed v0.33.2 testnet artifact can be described, and the deployed
    /// contracts are named after their keys.
    #[test]
    fn the_committed_testnet_artifact_is_fully_named() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../l1-contracts/upgrade-envs/v0.33.2-verifier/output/testnet/ecosystem.toml");
        let toml: toml::Table = toml::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let mut names = Names::default();
        names.add_ecosystem_toml(&toml);
        let validator: Address = toml["deployed_addresses"]["upgrade_stage_validator"]
            .as_str()
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(names.get(validator), Some("UpgradeStageValidator"));
        let admin: Address = toml["chain_upgrades"]["4221"]["chain_admin"]
            .as_str()
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(names.get(admin), Some("chain 4221's ChainAdmin"));
    }
}
