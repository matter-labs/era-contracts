use alloy::primitives::{Address, B256, FixedBytes};

/// Represents the source of a contract's bytecode.
#[derive(Clone, Copy)]
pub enum ContractSource {
    /// Load bytecode from a compiled contract artifact by name from l1-contracts.
    L1ContractName(&'static str),
    /// Load bytecode from a compiled contract artifact by name from da-contracts.
    #[allow(dead_code)]
    DAContractName(&'static str),
    /// Use bytecode directly.
    Bytecode(&'static [u8]),
}

/// Describes how a contract is deployed at genesis.
#[derive(Clone, Copy)]
pub enum ContractDeployment {
    /// Deploy the bytecode directly at the address.
    Direct(ContractSource),
    /// Deploy a `SystemContractProxy` at the address with the given source as the implementation.
    /// The implementation is deployed at a randomly generated address derived from its bytecode
    /// via `generate_random_address`, mirroring the Solidity `generateRandomAddress` helper.
    SystemProxy(ContractSource),
}

pub const L2_COMPLEX_UPGRADER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000000800f"
)));
pub const L2_GENESIS_UPGRADE: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010001"
)));
pub const L2_WRAPPED_BASE_TOKEN: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010007"
)));
pub const SYSTEM_CONTRACT_PROXY_ADMIN: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000c"
)));

pub const L2_MESSAGE_ROOT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010005"
)));

pub const L2_BRIDGEHUB_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010002"
)));

pub const L2_ASSET_ROUTER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010003"
)));

pub const L2_NATIVE_TOKEN_VAULT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010004"
)));

pub const L2_NTV_BEACON_DEPLOYER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000b"
)));

pub const L2_CHAIN_ASSET_HANDLER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000a"
)));

pub const L2_INTEROP_CENTER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000d"
)));

pub const L2_INTEROP_HANDLER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000e"
)));

pub const L2_ASSET_TRACKER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000f"
)));

/// The removed v31 GWAssetTracker's reserved address. v31 released with the tracker deployed there
/// as a system-proxied built-in, so the v32 upgrade swaps its proxy's implementation for
/// `EmptyContract` (see `getRemovedTrackerNeutralizations`); genesis deploys the same
/// EmptyContract-backed proxy so fresh and upgraded chains match at this address.
pub const REMOVED_GW_ASSET_TRACKER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010010"
)));

pub const L2_BASE_TOKEN_HOLDER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010011"
)));

// Deterministic Create2 factory
// https://github.com/Arachnid/deterministic-deployment-proxy
pub const DETERMINISTIC_CREATE2_ADDRESS: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "4e59b44847b379578588920cA78FbF26c0B4956C"
)));
pub const CREATE2_FACTORY_RUNTIME_BYTECODE: &[u8] = &hex_literal::hex!(
    "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
);

// System contracts
pub const L2_DEPLOYER_SYSTEM_CONTRACT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000008006"
)));

pub const L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR: Address = Address(FixedBytes::<20>(
    hex_literal::hex!("0000000000000000000000000000000000008008"),
));

pub const L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR: Address = Address(FixedBytes::<20>(
    hex_literal::hex!("000000000000000000000000000000000000800a"),
));

pub const L2_SYSTEM_CONTEXT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000000800b"
)));

pub const SYSTEM_PROXY_ADMIN_OWNER_SLOT: B256 = B256::ZERO;

pub const EIP1967_IMPLEMENTATION_SLOT: B256 = FixedBytes::<32>(hex_literal::hex!(
    "360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
));
pub const EIP1967_ADMIN_SLOT: B256 = FixedBytes::<32>(hex_literal::hex!(
    "b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
));

const L2_INTEROP_ROOT_STORAGE: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010008"
)));
const L2_MESSAGE_VERIFICATION: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010009"
)));
const L2_INTEROP_COMMITMENT_TREE: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010012"
)));
// 0x10013 is reserved (formerly L2GlobalInteropRootImporter). See {protocol-docs/atomicity/README.md#contracts}.
const L2_ATOMIC_FLOW_MANAGER: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010014"
)));

// Stateless ERC-7786 attribute parser split out of the InteropCenter to keep the latter under the
// EIP-170 runtime code-size limit. Deployed as a SystemProxy, matching the L1 deploy scripts.
const L2_INTEROP_ATTRIBUTE_PARSER: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010015"
)));

/// All contracts to deploy at genesis, together with their deployment strategy.
///
/// Contracts marked `SystemProxy` are deployed as EIP-1967 transparent proxies: the well-known
/// address receives `SystemContractProxy` bytecode, while the implementation is deployed at a
/// randomly generated address (see `generate_random_address` in `utils.rs`).
///
/// Contracts marked `Direct` are deployed with their bytecode at the address as-is.
/// This applies to contracts that are not upgradeable proxies:
/// - `L2_GENESIS_UPGRADE` – one-shot genesis helper, never upgraded.
/// - `L2_WRAPPED_BASE_TOKEN` – uses its own proxy mechanism.
/// - `SYSTEM_CONTRACT_PROXY_ADMIN` – the proxy admin itself.
/// - `DETERMINISTIC_CREATE2_ADDRESS` – standard Create2 factory, not a system contract.
pub const INITIAL_CONTRACTS: [(Address, ContractDeployment); 25] = [
    (
        L2_COMPLEX_UPGRADER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2ComplexUpgrader")),
    ),
    (
        L2_GENESIS_UPGRADE,
        ContractDeployment::Direct(ContractSource::L1ContractName("L2GenesisUpgrade")),
    ),
    (
        L2_WRAPPED_BASE_TOKEN,
        ContractDeployment::Direct(ContractSource::L1ContractName("L2WrappedBaseToken")),
    ),
    (
        SYSTEM_CONTRACT_PROXY_ADMIN,
        ContractDeployment::Direct(ContractSource::L1ContractName("SystemContractProxyAdmin")),
    ),
    (
        L2_MESSAGE_ROOT_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2MessageRoot")),
    ),
    (
        L2_BRIDGEHUB_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2Bridgehub")),
    ),
    (
        L2_ASSET_ROUTER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2AssetRouter")),
    ),
    (
        L2_NATIVE_TOKEN_VAULT_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2NativeTokenVaultZKOS")),
    ),
    (
        L2_NTV_BEACON_DEPLOYER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName(
            "UpgradeableBeaconDeployer",
        )),
    ),
    (
        L2_CHAIN_ASSET_HANDLER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2ChainAssetHandler")),
    ),
    (
        L2_ASSET_TRACKER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2AssetTracker")),
    ),
    (
        L2_INTEROP_CENTER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2InteropCenter")),
    ),
    (
        L2_INTEROP_HANDLER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2InteropHandler")),
    ),
    // The removed v31 GWAssetTracker's address holds an EmptyContract-backed system proxy, matching
    // what the v32 upgrade installs on pre-existing chains; see REMOVED_GW_ASSET_TRACKER_ADDR.
    (
        REMOVED_GW_ASSET_TRACKER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("EmptyContract")),
    ),
    (
        L2_BASE_TOKEN_HOLDER_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("BaseTokenHolder")),
    ),
    // System contracts (0x8000 range)
    (
        L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("ZKOSContractDeployer")),
    ),
    (
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L1MessengerZKOS")),
    ),
    (
        L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2BaseTokenZKOS")),
    ),
    (
        L2_SYSTEM_CONTEXT_ADDR,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("SystemContext")),
    ),
    // Deterministic Create2 factory
    (
        DETERMINISTIC_CREATE2_ADDRESS,
        ContractDeployment::Direct(ContractSource::Bytecode(CREATE2_FACTORY_RUNTIME_BYTECODE)),
    ),
    (
        L2_INTEROP_ROOT_STORAGE,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2InteropRootStorage")),
    ),
    (
        L2_MESSAGE_VERIFICATION,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2MessageVerification")),
    ),
    // Atomic interop built-ins. See {protocol-docs/atomicity/README.md#zksync-os-genesis}.
    (
        L2_INTEROP_COMMITMENT_TREE,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2InteropCommitmentTree")),
    ),
    (
        L2_ATOMIC_FLOW_MANAGER,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("AtomicFlowManager")),
    ),
    (
        L2_INTEROP_ATTRIBUTE_PARSER,
        ContractDeployment::SystemProxy(ContractSource::L1ContractName("InteropAttributeParser")),
    ),
];

#[cfg(test)]
mod tests {
    use alloy::primitives::Address;

    use super::{
        ContractDeployment, ContractSource, INITIAL_CONTRACTS, L2_ASSET_TRACKER_ADDR,
        REMOVED_GW_ASSET_TRACKER_ADDR,
    };

    fn deployment_at(name: &str, addr: Address) -> &'static ContractDeployment {
        &INITIAL_CONTRACTS
            .iter()
            .find(|(address, _)| *address == addr)
            .unwrap_or_else(|| panic!("{name}: the reserved address must hold a deployment"))
            .1
    }

    #[test]
    fn keeps_the_asset_tracker_deployed_at_its_reserved_address() {
        assert!(
            matches!(
                deployment_at("L2AssetTracker", L2_ASSET_TRACKER_ADDR),
                ContractDeployment::SystemProxy(ContractSource::L1ContractName("L2AssetTracker"))
            ),
            "L2AssetTracker: genesis must deploy the tracker upgraded chains keep at this address"
        );
    }

    #[test]
    fn keeps_the_removed_gw_tracker_address_neutralized() {
        assert!(
            matches!(
                deployment_at("GWAssetTracker", REMOVED_GW_ASSET_TRACKER_ADDR),
                ContractDeployment::SystemProxy(ContractSource::L1ContractName("EmptyContract"))
            ),
            "GWAssetTracker: genesis must install the same EmptyContract proxy the v32 upgrade does"
        );
    }
}
