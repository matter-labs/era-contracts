//! Decoding against an explicit table of known functions. A selector outside the table is
//! shown as its four bytes; nothing is looked up elsewhere or guessed.

use std::sync::OnceLock;

use alloy::dyn_abi::{DynSolValue, JsonAbiExt};
use alloy::json_abi::Function;
use alloy::primitives::{Address, U256};

/// The contract that defines a function whose name several contracts share (`acceptOwnership`,
/// `transferOwnership`, ...): the target's own name says which one is called.
pub(crate) const ANY_CONTRACT: &str = "";

/// Every function a runbook or a simulator scenario names: the contract that defines it, and its
/// full ABI signature.
const KNOWN_FUNCTIONS: &[(&str, &str)] = &[
    // Gnosis Safe
    ("Safe", "approveHash(bytes32)"),
    // zk-governance EmergencyUpgradeBoard
    (
        "EmergencyUpgradeBoard",
        "executeEmergencyUpgrade((address,uint256,bytes)[],bytes32,bytes,bytes,bytes)",
    ),
    // zk-governance ProtocolUpgradeHandler: execute(UpgradeProposal)
    (
        "ProtocolUpgradeHandler",
        "execute(((address,uint256,bytes)[],address,bytes32))",
    ),
    // Legacy Governance: Operation = (Call[] calls, bytes32 predecessor, bytes32 salt)
    (
        "Governance",
        "scheduleTransparent(((address,uint256,bytes)[],bytes32,bytes32),uint256)",
    ),
    ("Governance", "execute(((address,uint256,bytes)[],bytes32,bytes32))"),
    ("Governance", "executeInstant(((address,uint256,bytes)[],bytes32,bytes32))"),
    // ChainAdmin
    ("ChainAdmin", "multicall((address,uint256,bytes)[],bool)"),
    // ChainAdmin's `setUpgradeTimestamp(protocolVersion, ts)` and ServerNotifier's
    // `setUpgradeTimestamp(chainId, ts)` share a selector; see [`upgrade_timestamp_subject`].
    ("ServerNotifier", "setUpgradeTimestamp(uint256,uint256)"),
    // ZK chain Admin facet: the current and the pre-v31 signature
    (
        "ZK chain",
        "upgradeChainFromVersion(address,uint256,((address,uint8,bool,bytes4[])[],address,bytes))",
    ),
    (
        "ZK chain",
        "upgradeChainFromVersion(uint256,((address,uint8,bool,bytes4[])[],address,bytes))",
    ),
    // ChainTypeManager
    (
        "ChainTypeManager",
        "setNewVersionUpgrade(((address,uint8,bool,bytes4[])[],address,bytes),uint256,uint256,uint256,address)",
    ),
    (
        "ChainTypeManager",
        "setChainCreationParams((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))",
    ),
    (
        "ChainTypeManager",
        "createNewVerifierOnlyUpgrade(uint256,uint256,uint256,address)",
    ),
    ("ChainTypeManager", "setDefaultUpgrade(address)"),
    // Bridgehub
    (
        "Bridgehub",
        "createNewChain(uint256,address,bytes32,uint256,address,bytes,bytes[])",
    ),
    ("Bridgehub", "setSettlementLayerStatus(uint256,bool)"),
    ("Bridgehub", "setAddressesV31(address)"),
    (
        "Bridgehub",
        "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))",
    ),
    (
        "Bridgehub",
        "requestL2TransactionTwoBridges((uint256,uint256,uint256,uint256,uint256,address,address,uint256,bytes))",
    ),
    // CTMDeploymentTracker
    ("CTMDeploymentTracker", "registerCTMAssetOnL1(address)"),
    // L1AssetRouter
    ("L1AssetRouter", "setL1InteropHandler(address)"),
    ("L1AssetRouter", "setAssetDeploymentTracker(bytes32,address)"),
    // L1NativeTokenVault, v0.31
    ("L1NativeTokenVault", "setAssetTracker(address)"),
    // L2AssetTracker
    ("L2AssetTracker", "registerLegacyToken(bytes32)"),
    // GovernanceUpgradeTimer
    ("GovernanceUpgradeTimer", "startTimer()"),
    ("GovernanceUpgradeTimer", "checkDeadline()"),
    // UpgradeStageValidator
    ("UpgradeStageValidator", "checkMigrationsPaused()"),
    ("UpgradeStageValidator", "checkProtocolUpgradePresence()"),
    ("UpgradeStageValidator", "checkMigrationsUnpaused()"),
    // ChainAssetHandler
    ("ChainAssetHandler", "pauseMigration()"),
    ("ChainAssetHandler", "unpauseMigration()"),
    ("ChainAssetHandler", "setAddresses()"),
    (
        "ChainAssetHandler",
        "setHistoricalMigrationInterval(uint256,uint256,(uint256,uint256,uint256,uint256,uint256,bool))",
    ),
    // ERC20
    ("ERC20", "approve(address,uint256)"),
    // Ownable / Ownable2Step, and the admin role of the bridgehub and chains
    (ANY_CONTRACT, "acceptOwnership()"),
    (ANY_CONTRACT, "transferOwnership(address)"),
    (ANY_CONTRACT, "acceptAdmin()"),
    (ANY_CONTRACT, "setPendingAdmin(address)"),
    // (Transparent) ProxyAdmin
    ("ProxyAdmin", "upgrade(address,address)"),
    ("ProxyAdmin", "upgradeAndCall(address,address,bytes)"),
];

/// A function of [`KNOWN_FUNCTIONS`].
pub(crate) struct KnownFunction {
    /// The contract that defines it, or [`ANY_CONTRACT`].
    pub contract: &'static str,
    pub function: Function,
}

/// Calldata longer than this is summarized in the table (size + keccak) and printed in full
/// below it; up to a selector plus two words fits in a cell.
pub(crate) const INLINE_CALLDATA_MAX_BYTES: usize = 4 + 2 * 32;

/// Bit offsets of the packed protocol version `major << 64 | minor << 32 | patch`.
const SEMVER_MINOR_OFFSET: u32 = 32;
const SEMVER_MAJOR_OFFSET: u32 = 64;
const SEMVER_PART_MASK: u64 = u32::MAX as u64;

fn known_functions() -> &'static [KnownFunction] {
    static TABLE: OnceLock<Vec<KnownFunction>> = OnceLock::new();
    TABLE.get_or_init(|| {
        KNOWN_FUNCTIONS
            .iter()
            .map(|(contract, signature)| KnownFunction {
                contract,
                function: Function::parse(signature)
                    .unwrap_or_else(|error| panic!("known signature {signature}: {error}")),
            })
            .collect()
    })
}

/// The table entry of the function `data` calls, if its selector is in the table.
pub(crate) fn known(data: &[u8]) -> Option<&'static KnownFunction> {
    let selector = data.get(..4)?;
    known_functions()
        .iter()
        .find(|known| known.function.selector().as_slice() == selector)
}

/// The known function `data` calls, if its selector is in the table.
pub(crate) fn known_function(data: &[u8]) -> Option<&'static Function> {
    known(data).map(|known| &known.function)
}

/// `data` decoded against its known function; `None` if unknown or malformed.
pub(crate) fn decode(data: &[u8]) -> Option<(&'static KnownFunction, Vec<DynSolValue>)> {
    let known = known(data)?;
    let args = known.function.abi_decode_input(&data[4..]).ok()?;
    Some((known, args))
}

/// The Call column: the signature when every argument is a plain type, `name(...)` otherwise.
pub(crate) fn call_display(data: &[u8]) -> String {
    match (data.len(), known_function(data)) {
        (0, _) => "none (plain transfer)".to_string(),
        (1..=3, _) => format!("not a function call (`0x{}`)", hex::encode(data)),
        (_, Some(function)) => format!("`{}`", display_signature(function)),
        (_, None) => format!("`0x{}` (unknown function)", hex::encode(&data[..4])),
    }
}

fn display_signature(function: &Function) -> String {
    let signature = function.signature();
    let params = &signature[function.name.len() + 1..signature.len() - 1];
    if params.contains(['(', '[']) {
        format!("{}(...)", function.name)
    } else {
        signature
    }
}

/// `v<major>.<minor>.<patch>` of a packed protocol version, or the number if it does not unpack.
pub(crate) fn protocol_version(value: U256) -> String {
    if value >> (SEMVER_MAJOR_OFFSET + 32) != U256::ZERO {
        return value.to_string();
    }
    let raw: u128 = value.to::<u128>();
    let major = raw >> SEMVER_MAJOR_OFFSET;
    let minor = (raw >> SEMVER_MINOR_OFFSET) as u64 & SEMVER_PART_MASK;
    let patch = raw as u64 & SEMVER_PART_MASK;
    format!("v{major}.{minor}.{patch}")
}

pub(crate) fn as_uint(value: &DynSolValue) -> Option<U256> {
    match value {
        DynSolValue::Uint(value, _) => Some(*value),
        _ => None,
    }
}

pub(crate) fn as_address(value: &DynSolValue) -> Option<Address> {
    match value {
        DynSolValue::Address(address) => Some(*address),
        _ => None,
    }
}

/// What a `setUpgradeTimestamp` call's first argument is: ChainAdmin's takes a protocol version,
/// ServerNotifier's a chain id, under the same selector. A packed protocol version always has a
/// nonzero minor (bits 32 and up); a chain id never does.
pub(crate) enum UpgradeTimestampSubject {
    Chain(U256),
    Version(U256),
}

pub(crate) fn upgrade_timestamp_subject(first: U256) -> UpgradeTimestampSubject {
    if first >> SEMVER_MINOR_OFFSET == U256::ZERO {
        UpgradeTimestampSubject::Chain(first)
    } else {
        UpgradeTimestampSubject::Version(first)
    }
}

/// A short, decoded fact about a call that the signature alone does not show.
pub(crate) fn annotation(data: &[u8]) -> Option<String> {
    let (known, args) = decode(data)?;
    let uint = |i: usize| args.get(i).and_then(as_uint);
    match known.function.name.as_str() {
        "setNewVersionUpgrade" => Some(format!(
            "{} to {}",
            protocol_version(uint(1)?),
            protocol_version(uint(3)?)
        )),
        "upgradeChainFromVersion" => {
            let old = if args.len() == 3 { uint(1)? } else { uint(0)? };
            Some(format!("from {}", protocol_version(old)))
        }
        "setUpgradeTimestamp" => {
            let subject = match upgrade_timestamp_subject(uint(0)?) {
                UpgradeTimestampSubject::Chain(chain_id) => format!("chain {chain_id}"),
                UpgradeTimestampSubject::Version(version) => protocol_version(version),
            };
            Some(format!("{subject} at timestamp {}", uint(1)?))
        }
        "scheduleTransparent" => Some(format!("delay {} s", uint(1)?)),
        "transferOwnership" | "setPendingAdmin" => Some(format!(
            "to `{}`",
            args.first().and_then(as_address)?.to_checksum(None)
        )),
        _ => None,
    }
}

/// One call a wrapper runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InnerCall {
    pub target: Address,
    pub value: U256,
    pub data: Vec<u8>,
}

/// How a wrapper runs its calls.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum WrapperKind {
    /// All calls in one tx; any failure reverts it.
    Atomic,
    /// ChainAdmin `multicall(calls, false)`: a failing call does not revert the tx.
    NonAtomic,
    /// Legacy Governance `scheduleTransparent`: nothing runs yet.
    Schedule,
}

/// The calls a wrapper call runs.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Wrapped {
    pub kind: WrapperKind,
    pub calls: Vec<InnerCall>,
    /// Legacy Governance operation, to pair an `execute` with the `scheduleTransparent` before it.
    pub operation: Option<DynSolValue>,
}

fn inner_calls(value: &DynSolValue) -> Option<Vec<InnerCall>> {
    let DynSolValue::Array(calls) = value else {
        return None;
    };
    calls
        .iter()
        .map(|call| match call {
            DynSolValue::Tuple(fields) => match fields.as_slice() {
                [DynSolValue::Address(target), DynSolValue::Uint(value, _), DynSolValue::Bytes(data)] => {
                    Some(InnerCall {
                        target: *target,
                        value: *value,
                        data: data.clone(),
                    })
                }
                _ => None,
            },
            _ => None,
        })
        .collect()
}

/// The first field of a tuple argument (the `Call[]` of an operation or proposal).
fn first_field(value: &DynSolValue) -> Option<&DynSolValue> {
    match value {
        DynSolValue::Tuple(fields) => fields.first(),
        _ => None,
    }
}

/// The calls `data` runs if it is a known wrapper (emergency upgrade, handler proposal, legacy
/// Governance operation, ChainAdmin multicall).
pub(crate) fn wrapped(data: &[u8]) -> Option<Wrapped> {
    let (known, args) = decode(data)?;
    let first = args.first()?;
    let signature = known.function.signature();
    let (kind, calls, operation) = match known.function.name.as_str() {
        "executeEmergencyUpgrade" => (WrapperKind::Atomic, inner_calls(first)?, None),
        "multicall" => {
            let kind = match args.get(1) {
                Some(DynSolValue::Bool(true)) => WrapperKind::Atomic,
                _ => WrapperKind::NonAtomic,
            };
            (kind, inner_calls(first)?, None)
        }
        "scheduleTransparent" => (
            WrapperKind::Schedule,
            inner_calls(first_field(first)?)?,
            Some(first.clone()),
        ),
        "execute" | "executeInstant" => {
            let calls = inner_calls(first_field(first)?)?;
            // The handler's proposal names an executor; the legacy Governance operation does not.
            let is_governance_operation = signature.ends_with(",bytes32,bytes32))");
            (
                WrapperKind::Atomic,
                calls,
                is_governance_operation.then(|| first.clone()),
            )
        }
        _ => return None,
    };
    Some(Wrapped {
        kind,
        calls,
        operation,
    })
}
