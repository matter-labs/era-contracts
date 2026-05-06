use alloy::{
    hex,
    primitives::{keccak256, Address, FixedBytes, U256},
    sol,
    sol_types::SolCall,
};
use anyhow::Context;
use std::collections::HashSet;

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::{super::get_expected_new_protocol_version, protocol_version::ProtocolVersion};

const L2_FORCE_DEPLOYER_ADDRESS: u32 = 0x8007;
const L2_COMPLEX_UPGRADER_ADDRESS: u32 = 0x800f;
const L2_VERSION_SPECIFIC_UPGRADER_ADDRESS: u32 = 0x10001;
const ERA_SYSTEM_UPGRADE_TX_TYPE: u64 = 254;
const ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE: u64 = 126;
const L2_UPGRADE_GAS_LIMIT: u64 = 72_000_000;
const L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT: u64 = 800;
const L2_V31_UPGRADE_CONTRACT: &str = "l1-contracts/L2V31Upgrade";
const BOOTLOADER_CONTRACT: &str = "Bootloader";
const DEFAULT_ACCOUNT_CONTRACT: &str = "system-contracts/DefaultAccount";
const EVM_EMULATOR_CONTRACT: &str = "EvmEmulator";

// Mirrors CoreOnGatewayHelper.getFullListOfFactoryDependencies(false, [L2V31Upgrade]).
const EXPECTED_V31_ERA_BYTECODES: &[&str] = &[
    "Bootloader",
    "system-contracts/DefaultAccount",
    "EvmEmulator",
    "system-contracts/EmptyContract",
    "Ecrecover",
    "SHA256",
    "Identity",
    "EcAdd",
    "EcMul",
    "EcPairing",
    "Modexp",
    "system-contracts/AccountCodeStorage",
    "system-contracts/NonceHolder",
    "system-contracts/KnownCodesStorage",
    "system-contracts/ImmutableSimulator",
    "system-contracts/ContractDeployer",
    "system-contracts/L1Messenger",
    "system-contracts/MsgValueSimulator",
    "l1-contracts/L2BaseTokenEra",
    "system-contracts/SystemContext",
    "system-contracts/BootloaderUtilities",
    "EventWriter",
    "system-contracts/Compressor",
    "Keccak256",
    "CodeOracle",
    "EvmGasManager",
    "system-contracts/EvmPredeploysManager",
    "system-contracts/EvmHashesStorage",
    "P256Verify",
    "system-contracts/PubdataChunkPublisher",
    "system-contracts/Create2Factory",
    "system-contracts/SloadContract",
    "l1-contracts/SystemContractProxyAdmin",
    "l1-contracts/L2Bridgehub",
    "l1-contracts/L2AssetRouter",
    "l1-contracts/L2NativeTokenVault",
    "l1-contracts/L2MessageRoot",
    "l1-contracts/L2WrappedBaseToken",
    "l1-contracts/L2MessageVerification",
    "l1-contracts/L2ChainAssetHandler",
    "l1-contracts/L2InteropRootStorage",
    "l1-contracts/BaseTokenHolder",
    "l1-contracts/L2AssetTracker",
    "l1-contracts/InteropCenter",
    "l1-contracts/InteropHandler",
    "l1-contracts/GWAssetTracker",
    "l1-contracts/TransparentUpgradeableProxy",
    "l1-contracts/BeaconProxy",
    "l1-contracts/L2SharedBridgeLegacy",
    "l1-contracts/BridgedStandardERC20",
    "l1-contracts/DiamondProxy",
    "l1-contracts/ProxyAdmin",
    "l1-contracts/L2V31Upgrade",
];

// Mirrors CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, [L2V31Upgrade]).
const EXPECTED_V31_ZKSYNC_OS_BYTECODES: &[&str] = &[
    "l1-contracts/SystemContractProxy",
    "l1-contracts/SystemContractProxyAdmin",
    "l1-contracts/L2Bridgehub",
    "l1-contracts/L2AssetRouter",
    "l1-contracts/L2NativeTokenVaultZKOS",
    "l1-contracts/L2MessageRoot",
    "l1-contracts/L2WrappedBaseToken",
    "l1-contracts/L2MessageVerification",
    "l1-contracts/L2ChainAssetHandler",
    "l1-contracts/L2InteropRootStorage",
    "l1-contracts/BaseTokenHolder",
    "l1-contracts/L2AssetTracker",
    "l1-contracts/InteropCenter",
    "l1-contracts/InteropHandler",
    "l1-contracts/GWAssetTracker",
    "l1-contracts/UpgradeableBeaconDeployer",
    "l1-contracts/L2V31Upgrade",
    "l1-contracts/L2BaseTokenZKOS",
    "l1-contracts/L1MessengerZKOS",
    "l1-contracts/SystemContext",
];

sol! {
    #[derive(Debug)]
    enum Action {
        Add,
        Replace,
        Remove
    }

    #[derive(Debug)]
    struct FacetCut {
        address facet;
        Action action;
        bool isFreezable;
        bytes4[] selectors;
    }

    #[derive(Debug)]
    struct DiamondCutData {
        FacetCut[] facetCuts;
        address initAddress;
        bytes initCalldata;
    }

    function setNewVersionUpgrade(
        DiamondCutData diamondCut,
        uint256 oldProtocolVersion,
        uint256 oldProtocolVersionDeadline,
        uint256 newProtocolVersion,
        address verifier
    );

    #[derive(Debug)]
    struct VerifierParams {
        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
    }

    #[derive(Debug)]
    struct L2CanonicalTransaction {
        uint256 txType;
        uint256 from;
        uint256 to;
        uint256 gasLimit;
        uint256 gasPerPubdataByteLimit;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 paymaster;
        uint256 nonce;
        uint256 value;
        // In the future, we might want to add some
        // new fields to the struct. The `txData` struct
        // is to be passed to account and any changes to its structure
        // would mean a breaking change to these accounts. To prevent this,
        // we should keep some fields as "reserved"
        // It is also recommended that their length is fixed, since
        // it would allow easier proof integration (in case we will need
        // some special circuit for preprocessing transactions)
        uint256[4] reserved;
        bytes data;
        bytes signature;
        uint256[] factoryDeps;
        bytes paymasterInput;
        // Reserved dynamic type for the future use-case. Using it should be avoided,
        // But it is still here, just in case we want to enable some additional functionality
        bytes reservedDynamic;
    }

    #[derive(Debug)]
    struct ProposedUpgrade {
        L2CanonicalTransaction l2ProtocolUpgradeTx;
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        address verifier;
        VerifierParams verifierParams;
        bytes l1ContractsUpgradeCalldata;
        bytes postUpgradeCalldata;
        uint256 upgradeTimestamp;
        uint256 newProtocolVersion;
    }

    #[derive(Debug)]
    function upgrade(ProposedUpgrade calldata _proposedUpgrade);

    interface IComplexUpgrader {
        #[derive(Debug, PartialEq, Eq)]
        enum ContractUpgradeType {
            EraForceDeployment,
            ZKsyncOSSystemProxyUpgrade,
            ZKsyncOSUnsafeForceDeployment
        }

        #[derive(Debug)]
        struct ForceDeployment {
            bytes32 bytecodeHash;
            address newAddress;
            bool callConstructor;
            uint256 value;
            bytes input;
        }

        #[derive(Debug)]
        struct UniversalContractUpgradeInfo {
            ContractUpgradeType upgradeType;
            bytes deployedBytecodeInfo;
            address newAddress;
        }

        function forceDeployAndUpgrade(
            ForceDeployment[] calldata _forceDeployments,
            address _delegateTo,
            bytes calldata _calldata
        ) external payable;

        function forceDeployAndUpgradeUniversal(
            UniversalContractUpgradeInfo[] calldata _forceDeployments,
            address _delegateTo,
            bytes calldata _calldata
        ) external payable;
    }

    interface IL2V31Upgrade {
        function upgrade(
            bool _isZKsyncOS,
            address _ctmDeployer,
            bytes calldata _fixedForceDeploymentsData,
            bytes calldata _additionalForceDeploymentsData
        ) external;
    }

    #[sol(rpc)]
    contract BytecodesSupplier {
        mapping(bytes32 bytecodeHash => uint256 blockNumber) public publishingBlock;
    }
}

impl upgradeCall {} // Placeholder implementation.

impl ProposedUpgrade {
    pub async fn verify_v31_template(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        expected_new_protocol_version: U256,
        expected_fixed_force_deployments_data: &str,
    ) -> anyhow::Result<usize> {
        result.print_info("== DefaultUpgrade ProposedUpgrade ==");
        let initial_error_count = result.errors;
        let expected_version = ProtocolVersion::from(expected_new_protocol_version);

        self.verify_static_fields(result, verifiers, expected_new_protocol_version);
        self.verify_l2_protocol_upgrade_tx(
            verifiers,
            result,
            expected_version,
            expected_fixed_force_deployments_data,
        )
        .await?;

        let new_errors = (result.errors - initial_error_count) as usize;
        if new_errors == 0 {
            result.report_ok("DefaultUpgrade ProposedUpgrade matches v31 template");
        }
        Ok(new_errors)
    }

    pub async fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        _bytecodes_supplier_addr: Address,
        _is_gateway: bool,
    ) -> anyhow::Result<()> {
        let expected_version = get_expected_new_protocol_version();
        self.verify_v31_template(verifiers, result, expected_version.into(), "")
            .await?;

        Ok(())
    }

    fn verify_static_fields(
        &self,
        result: &mut VerificationResult,
        verifiers: &Verifiers,
        expected_new_protocol_version: U256,
    ) {
        result.expect_zk_bytecode(verifiers, &self.bootloaderHash, BOOTLOADER_CONTRACT);
        result.expect_zk_bytecode(
            verifiers,
            &self.defaultAccountHash,
            DEFAULT_ACCOUNT_CONTRACT,
        );
        result.expect_zk_bytecode(verifiers, &self.evmEmulatorHash, EVM_EMULATOR_CONTRACT);

        if self.verifier != Address::ZERO {
            result.report_error(&format!(
                "ProposedUpgrade verifier must be zero, got {}",
                self.verifier
            ));
        }

        let zero_hash = FixedBytes::<32>::ZERO;
        if self.verifierParams.recursionNodeLevelVkHash != zero_hash
            || self.verifierParams.recursionLeafLevelVkHash != zero_hash
            || self.verifierParams.recursionCircuitsSetVksHash != zero_hash
        {
            result.report_error("ProposedUpgrade verifier params must be empty");
        }

        if !self.l1ContractsUpgradeCalldata.is_empty() {
            result.report_error("ProposedUpgrade l1ContractsUpgradeCalldata must be empty for v31");
        }

        if !self.postUpgradeCalldata.is_empty() {
            result.report_error("ProposedUpgrade postUpgradeCalldata must be empty for v31");
        }

        if self.upgradeTimestamp != U256::default() {
            result.report_error("ProposedUpgrade upgradeTimestamp must be zero");
        }

        if self.newProtocolVersion != expected_new_protocol_version {
            result.report_error(&format!(
                "ProposedUpgrade new protocol version mismatch: expected {}, got {}",
                expected_new_protocol_version, self.newProtocolVersion
            ));
        }
    }

    async fn verify_l2_protocol_upgrade_tx(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        expected_version: ProtocolVersion,
        expected_fixed_force_deployments_data: &str,
    ) -> anyhow::Result<()> {
        let tx = &self.l2ProtocolUpgradeTx;

        if tx.from != U256::from(L2_FORCE_DEPLOYER_ADDRESS) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx sender: expected 0x{L2_FORCE_DEPLOYER_ADDRESS:x}, got {}",
                tx.from
            ));
        }
        if tx.to != U256::from(L2_COMPLEX_UPGRADER_ADDRESS) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx target: expected 0x{L2_COMPLEX_UPGRADER_ADDRESS:x}, got {}",
                tx.to
            ));
        }
        if tx.gasLimit != U256::from(L2_UPGRADE_GAS_LIMIT) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx gasLimit: expected {L2_UPGRADE_GAS_LIMIT}, got {}",
                tx.gasLimit
            ));
        }
        if tx.gasPerPubdataByteLimit != U256::from(L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx gasPerPubdataByteLimit: expected {L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT}, got {}",
                tx.gasPerPubdataByteLimit
            ));
        }
        if tx.maxFeePerGas != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx maxFeePerGas");
        }
        if tx.maxPriorityFeePerGas != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx maxPriorityFeePerGas");
        }
        if tx.paymaster != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx paymaster");
        }
        if tx.nonce != U256::from(expected_version.minor) {
            result.report_error(&format!(
                "L2 upgrade tx nonce must be the minor protocol version: expected {}, got {}",
                expected_version.minor, tx.nonce
            ));
        }
        if tx.value != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx value");
        }
        if tx.reserved != [U256::ZERO; 4] {
            result.report_error("Invalid L2 upgrade tx reserved fields");
        }
        if !tx.signature.is_empty() {
            result.report_error("Invalid L2 upgrade tx signature");
        }
        if !tx.paymasterInput.is_empty() {
            result.report_error("Invalid L2 upgrade tx paymasterInput");
        }
        if !tx.reservedDynamic.is_empty() {
            result.report_error("Invalid L2 upgrade tx reservedDynamic");
        }

        if let Ok(decoded) = IComplexUpgrader::forceDeployAndUpgradeCall::abi_decode(&tx.data) {
            if tx.txType != U256::from(ERA_SYSTEM_UPGRADE_TX_TYPE) {
                result.report_error(&format!(
                    "Era L2 upgrade tx must use txType {ERA_SYSTEM_UPGRADE_TX_TYPE}, got {}",
                    tx.txType
                ));
            }
            verify_factory_deps(
                verifiers,
                result,
                &tx.factoryDeps,
                EXPECTED_V31_ERA_BYTECODES,
                "Era",
            );
            verify_era_force_deploy_and_upgrade(
                verifiers,
                result,
                &decoded,
                expected_fixed_force_deployments_data,
            )?;
            result.report_ok("Decoded Era forceDeployAndUpgrade L2 upgrade tx");
            return Ok(());
        }

        if let Ok(decoded) =
            IComplexUpgrader::forceDeployAndUpgradeUniversalCall::abi_decode(&tx.data)
        {
            if tx.txType != U256::from(ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE) {
                result.report_error(&format!(
                    "ZKsync OS L2 upgrade tx must use txType {ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE}, got {}",
                    tx.txType
                ));
            }
            verify_factory_deps(
                verifiers,
                result,
                &tx.factoryDeps,
                EXPECTED_V31_ZKSYNC_OS_BYTECODES,
                "ZKsync OS",
            );
            verify_zksync_os_force_deploy_and_upgrade(
                verifiers,
                result,
                &decoded,
                expected_fixed_force_deployments_data,
            )?;
            result.report_ok("Decoded ZKsync OS forceDeployAndUpgradeUniversal L2 upgrade tx");
            return Ok(());
        }

        result.report_error(
            "L2 upgrade tx data is neither forceDeployAndUpgrade nor forceDeployAndUpgradeUniversal",
        );
        Ok(())
    }
}

fn verify_factory_deps(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    factory_deps: &[U256],
    expected_bytecodes: &[&str],
    label: &str,
) {
    let expected_bytecodes: HashSet<&str> = expected_bytecodes.iter().copied().collect();
    let mut actual_bytecodes = HashSet::new();
    let mut errors = 0;

    for dep in factory_deps {
        let dep = fixed_bytes_from_u256(dep);
        match verifiers.bytecode_verifier.zk_bytecode_hash_to_file(&dep) {
            Some(file_name) => {
                if !expected_bytecodes.contains(file_name.as_str()) {
                    errors += 1;
                    result.report_error(&format!(
                        "Unexpected {label} dependency in L2 upgrade tx factoryDeps: {file_name}"
                    ));
                }
                if !actual_bytecodes.insert(file_name.as_str()) {
                    errors += 1;
                    result.report_error(&format!(
                        "Duplicate {label} dependency in L2 upgrade tx factoryDeps: {file_name}"
                    ));
                }
            }
            None => {
                errors += 1;
                result.report_error(&format!(
                    "Unknown {label} bytecode hash in L2 upgrade tx factoryDeps: {}",
                    dep
                ));
            }
        }
    }

    let mut missing_bytecodes = expected_bytecodes
        .difference(&actual_bytecodes)
        .copied()
        .collect::<Vec<_>>();
    missing_bytecodes.sort_unstable();
    if !missing_bytecodes.is_empty() {
        errors += missing_bytecodes.len();
        result.report_error(&format!(
            "Missing {label} dependencies in L2 upgrade tx factoryDeps: {:?}",
            missing_bytecodes
        ));
    }

    if errors == 0 {
        result.report_ok(&format!(
            "{label} L2 upgrade tx factoryDeps match expected v31 dependency set"
        ));
    }
}

fn verify_era_force_deploy_and_upgrade(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    decoded: &IComplexUpgrader::forceDeployAndUpgradeCall,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    let expected_delegate_to = address_from_short_u32(L2_VERSION_SPECIFIC_UPGRADER_ADDRESS);
    if decoded._delegateTo != expected_delegate_to {
        result.report_error(&format!(
            "Era forceDeployAndUpgrade delegate target mismatch: expected {}, got {}",
            expected_delegate_to, decoded._delegateTo
        ));
    } else {
        result.report_ok(&format!(
            "Era forceDeployAndUpgrade delegate target is L2_VERSION_SPECIFIC_UPGRADER_ADDR ({expected_delegate_to})"
        ));
    }

    let mut matching_deployments = decoded._forceDeployments.iter().filter(|deployment| {
        bytecode_hash_matches_file(verifiers, &deployment.bytecodeHash, L2_V31_UPGRADE_CONTRACT)
    });
    match (matching_deployments.next(), matching_deployments.next()) {
        (Some(deployment), None) => {
            verify_era_l2_v31_deployment(verifiers, result, expected_delegate_to, deployment);
        }
        (None, _) => result.report_error(&format!(
            "Era forceDeployAndUpgrade does not include an {} force deployment",
            L2_V31_UPGRADE_CONTRACT
        )),
        (Some(_), Some(_)) => result.report_error(&format!(
            "Era forceDeployAndUpgrade contains multiple {} force deployments",
            L2_V31_UPGRADE_CONTRACT
        )),
    }

    verify_l2_v31_upgrade_inner_calldata(
        verifiers,
        result,
        &decoded._calldata,
        false,
        expected_fixed_force_deployments_data,
    )
}

fn verify_era_l2_v31_deployment(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    expected_delegate_to: Address,
    deployment: &IComplexUpgrader::ForceDeployment,
) {
    result.expect_zk_bytecode(verifiers, &deployment.bytecodeHash, L2_V31_UPGRADE_CONTRACT);
    if deployment.newAddress != expected_delegate_to {
        result.report_error(&format!(
            "Era L2V31Upgrade force deployment address must match delegate target: expected {}, got {}",
            expected_delegate_to, deployment.newAddress
        ));
    } else {
        result.report_ok(&format!(
            "Era L2V31Upgrade force deployment address is L2_VERSION_SPECIFIC_UPGRADER_ADDR ({expected_delegate_to})"
        ));
    }
    if deployment.callConstructor {
        result.report_error("Era L2V31Upgrade force deployment must not call a constructor");
    }
    if deployment.value != U256::ZERO {
        result.report_error(&format!(
            "Era L2V31Upgrade force deployment value must be zero, got {}",
            deployment.value
        ));
    }
    if !deployment.input.is_empty() {
        result.report_error("Era L2V31Upgrade force deployment constructor input must be empty");
    }
}

fn verify_zksync_os_force_deploy_and_upgrade(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    decoded: &IComplexUpgrader::forceDeployAndUpgradeUniversalCall,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    let mut matching_deployments = decoded
        ._forceDeployments
        .iter()
        .filter(|deployment| deployment.newAddress == decoded._delegateTo);
    match (matching_deployments.next(), matching_deployments.next()) {
        (Some(deployment), None) => {
            verify_zksync_os_l2_v31_deployment(verifiers, result, decoded._delegateTo, deployment);
        }
        (None, _) => result.report_error(&format!(
            "ZKsync OS forceDeployAndUpgradeUniversal does not deploy delegate target {}",
            decoded._delegateTo
        )),
        (Some(_), Some(_)) => result.report_error(&format!(
            "ZKsync OS forceDeployAndUpgradeUniversal contains multiple deployments for delegate target {}",
            decoded._delegateTo
        )),
    }

    verify_l2_v31_upgrade_inner_calldata(
        verifiers,
        result,
        &decoded._calldata,
        true,
        expected_fixed_force_deployments_data,
    )
}

fn verify_zksync_os_l2_v31_deployment(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    delegate_to: Address,
    deployment: &IComplexUpgrader::UniversalContractUpgradeInfo,
) {
    if deployment.upgradeType
        != IComplexUpgrader::ContractUpgradeType::ZKsyncOSUnsafeForceDeployment
    {
        result.report_error(&format!(
            "ZKsync OS L2V31Upgrade deployment must use ZKsyncOSUnsafeForceDeployment, got {:?}",
            deployment.upgradeType
        ));
    }

    let expected_delegate_to = generate_zksync_os_random_address(&deployment.deployedBytecodeInfo);
    if delegate_to != expected_delegate_to {
        result.report_error(&format!(
            "ZKsync OS delegate target mismatch: expected derived address {}, got {}",
            expected_delegate_to, delegate_to
        ));
    }

    match zksync_os_bytecode_info_hashes(&deployment.deployedBytecodeInfo) {
        Some((first_hash, observable_hash)) => {
            if bytecode_hash_matches_file(verifiers, &first_hash, L2_V31_UPGRADE_CONTRACT)
                || bytecode_hash_matches_file(verifiers, &observable_hash, L2_V31_UPGRADE_CONTRACT)
            {
                result.report_ok("ZKsync OS delegate deployment uses L2V31Upgrade bytecode info");
            } else {
                result.report_error(&format!(
                    "ZKsync OS delegate bytecode info does not map to {}: first={}, observable={}",
                    L2_V31_UPGRADE_CONTRACT, first_hash, observable_hash
                ));
            }
        }
        None => result.report_error(&format!(
            "ZKsync OS L2V31Upgrade bytecode info must be 96 bytes, got {}",
            deployment.deployedBytecodeInfo.len()
        )),
    }
}

fn verify_l2_v31_upgrade_inner_calldata(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    calldata: &[u8],
    expected_is_zksync_os: bool,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    let decoded = IL2V31Upgrade::upgradeCall::abi_decode(calldata)
        .context("decoding IL2V31Upgrade.upgrade inner calldata")?;

    if decoded._isZKsyncOS != expected_is_zksync_os {
        result.report_error(&format!(
            "IL2V31Upgrade.upgrade _isZKsyncOS mismatch: expected {}, got {}",
            expected_is_zksync_os, decoded._isZKsyncOS
        ));
    }
    result.expect_address(
        verifiers,
        &decoded._ctmDeployer,
        "ctm_deployment_tracker_proxy",
    );

    if !expected_fixed_force_deployments_data.is_empty() {
        let expected = expected_fixed_force_deployments_data
            .strip_prefix("0x")
            .unwrap_or(expected_fixed_force_deployments_data);
        let actual = hex::encode(&decoded._fixedForceDeploymentsData);
        if !actual.eq_ignore_ascii_case(expected) {
            result.report_error(&format!(
                "IL2V31Upgrade.upgrade fixedForceDeploymentsData mismatch. Expected: 0x{}\nReceived: 0x{}",
                expected, actual
            ));
        } else {
            result.report_ok("IL2V31Upgrade.upgrade fixedForceDeploymentsData matches TOML");
        }
    }

    if !decoded._additionalForceDeploymentsData.is_empty() {
        result.report_error(
            "IL2V31Upgrade.upgrade additionalForceDeploymentsData template must be empty",
        );
    } else {
        result.report_ok("IL2V31Upgrade.upgrade additionalForceDeploymentsData template is empty");
    }

    Ok(())
}

fn fixed_bytes_from_u256(value: &U256) -> FixedBytes<32> {
    FixedBytes::<32>::from_slice(&value.to_be_bytes::<32>())
}

fn address_from_short_u32(value: u32) -> Address {
    let encoded = U256::from(value).to_be_bytes::<32>();
    Address::from_slice(&encoded[12..])
}

fn generate_zksync_os_random_address(bytecode_info: &[u8]) -> Address {
    let mut preimage = Vec::with_capacity(32 + bytecode_info.len());
    preimage.extend_from_slice(&[0u8; 32]);
    preimage.extend_from_slice(bytecode_info);
    let hash = keccak256(preimage);
    Address::from_slice(&hash[12..])
}

fn zksync_os_bytecode_info_hashes(
    bytecode_info: &[u8],
) -> Option<(FixedBytes<32>, FixedBytes<32>)> {
    if bytecode_info.len() != 96 {
        return None;
    }
    Some((
        FixedBytes::<32>::from_slice(&bytecode_info[0..32]),
        FixedBytes::<32>::from_slice(&bytecode_info[64..96]),
    ))
}

fn bytecode_hash_matches_file(
    verifiers: &Verifiers,
    bytecode_hash: &FixedBytes<32>,
    expected_file: &str,
) -> bool {
    verifiers
        .bytecode_verifier
        .zk_bytecode_hash_to_file(bytecode_hash)
        .is_some_and(|file| file == expected_file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_from_short_u32_preserves_system_contract_address() {
        let expected: Address = "0x0000000000000000000000000000000000010001"
            .parse()
            .unwrap();
        assert_eq!(
            address_from_short_u32(L2_VERSION_SPECIFIC_UPGRADER_ADDRESS),
            expected
        );
    }

    #[test]
    fn zksync_os_random_address_matches_helper_preimage_shape() {
        let expected: Address = "0xbcd8f33061f2577d6118395e7b44ea21c7ef62e0"
            .parse()
            .unwrap();
        assert_eq!(generate_zksync_os_random_address(&[1u8]), expected);
    }

    #[test]
    fn zksync_os_bytecode_info_hashes_requires_abi_tuple_size() {
        let mut bytecode_info = [0u8; 96];
        bytecode_info[31] = 1;
        bytecode_info[95] = 2;

        let (first_hash, observable_hash) = zksync_os_bytecode_info_hashes(&bytecode_info).unwrap();
        assert_eq!(first_hash[31], 1);
        assert_eq!(observable_hash[31], 2);
        assert!(zksync_os_bytecode_info_hashes(&bytecode_info[..95]).is_none());
    }
}
