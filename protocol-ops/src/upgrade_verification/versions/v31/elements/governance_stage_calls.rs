use super::{
    call_list::{Call, CallList},
    deployed_addresses::DeployedAddresses,
    fixed_force_deployment::FixedForceDeploymentsData,
    initialize_data_new_chain::InitializeDataNewChain,
    set_new_version_upgrade::{self, setNewVersionUpgradeCall},
};
use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::super::{
    get_expected_new_protocol_version, get_expected_old_protocol_version,
    utils::facet_cut_set::{self, FacetCutSet, FacetInfo},
};
use alloy::{
    hex,
    primitives::{Bytes, U256},
    sol,
    sol_types::{SolCall, SolValue},
};
use anyhow::Context;

sol! {
    #[derive(Debug)]
    struct L2TransactionRequestDirect {
        uint256 chainId;
        uint256 mintValue;
        address l2Contract;
        uint256 l2Value;
        bytes l2Calldata;
        uint256 l2GasLimit;
        uint256 l2GasPerPubdataByteLimit;
        bytes[] factoryDeps;
        address refundRecipient;
    }

    function approve(address spender, uint256 allowance);

    function pauseMigration();

    function unpauseMigration();

    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);
}

pub struct GovernanceStage0Calls {
    pub calls: CallList,
}

pub struct GovernanceStage1Calls {
    pub calls: CallList,
}
pub struct GovernanceStage2Calls {
    pub calls: CallList,
}

sol! {
    function upgrade(address proxy, address implementation);
    function upgradeAndCall(address proxy, address implementation, bytes data);
    function setAddresses(address _assetRouter, address _l1CtmDeployer, address _messageRoot);
    function setL1NativeTokenVault(address _l1NativeTokenVault);
    function setL1AssetRouter(address _l1AssetRouter);
    function setValidatorTimelock(address addr);
    function setProtocolVersionDeadline(uint256 protocolVersion, uint256 newDeadline);
    function updateDAPair(address l1_da_addr, address l2_da_addr, bool is_active);

    #[derive(Debug, PartialEq)]
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

    #[derive(Debug)]
    struct ChainCreationParams {
        address genesisUpgrade;
        bytes32 genesisBatchHash;
        uint64 genesisIndexRepeatedStorageChanges;
        bytes32 genesisBatchCommitment;
        DiamondCutData diamondCut;
        bytes forceDeploymentsData;
    }

    function setChainCreationParams(ChainCreationParams calldata _chainCreationParams);

    /// @notice Façet structure compatible with the EIP-2535 diamond loupe
    /// @param addr The address of the facet contract
    /// @param selectors The NON-sorted array with selectors associated with facet
    struct Facet {
        address addr;
        bytes4[] selectors;
    }

    function facets() external view returns (Facet[] memory result);
}

impl GovernanceStage1Calls {
    /// Verifies an upgrade call by decoding its data and comparing the proxy and implementation addresses.
    pub fn verify_upgrade_call(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        call: &Call,
        proxy_address: &str,
        implementation_address: &str,
        call_payload: Option<&str>,
    ) -> anyhow::Result<()> {
        let data = &call.data;
        let (proxy, implementation) = if let Some(expected_payload) = call_payload {
            let decoded =
                upgradeAndCallCall::abi_decode(data).expect("Failed to decode upgradeAndCall call");
            let expected_data = hex::decode(expected_payload)
                .expect("Failed to decode expected call payload from hex");
            if decoded.data != expected_data {
                result.report_error(&format!(
                    "Expected upgrade call data to be {:x?}, but got {:x?}",
                    expected_data, decoded.data
                ));
            }
            (decoded.proxy, decoded.implementation)
        } else {
            let decoded = upgradeCall::abi_decode(data).expect("Failed to decode upgrade call");
            (decoded.proxy, decoded.implementation)
        };

        if result.expect_address(verifiers, &proxy, proxy_address)
            && result.expect_address(verifiers, &implementation, implementation_address)
        {
            result.report_ok(&format!(
                "Upgrade call for {} ({}) to {} ({})",
                proxy, proxy_address, implementation, implementation_address
            ));
        }
        Ok(())
    }

    /// Verifies all the governance stage 1 calls.
    /// Returns a pair of expected diamond cut data as well as expected fixed force deployments data.
    pub async fn verify(
        &self,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        gateway_chain_id: u64,
        priority_txs_l2_gas_limit: u64,
        l1_expected_chain_creation_facets: FacetCutSet,
        gw_expected_chain_creation_facets: FacetCutSet,
        deployed_addresses: &DeployedAddresses,
        l1_expected_upgrade_facets: FacetCutSet,
        l1_expected_chain_upgrade_diamond_cut: &str,
        gw_expected_upgrade_facets: FacetCutSet,
        gw_expected_chain_upgrade_diamond_cut: &str,
    ) -> anyhow::Result<(String, String, String, String)> {
        result.print_info("== Gov stage 1 calls ===");

        // Stage1 is where most of the upgrade happens.
        // It usually consists of 3 parts:
        // * upgrading proxies (we deploy a new implementation and point existing proxy to it)
        // * upgrading chain creation parameters (telling the system how the new chains should look like)
        // * saving the information on how to upgrade existing chains (set new version upgrade)

        // Optionally for some upgrades we might have additional contract calls
        // (for example when we added a new type of bridge, we also included a call to bridgehub to set its address etc)

        let list_of_calls = [
            // Check time has passed
            ("upgrade_timer", "checkDeadline()"),
            // Check that migrations are paused
            ("upgrade_stage_validator", "checkMigrationsPaused()"),
            // Proxy upgrades
            ("transparent_proxy_admin", "upgrade(address,address)"),
            ("transparent_proxy_admin", "upgrade(address,address)"),
            ("transparent_proxy_admin", "upgrade(address,address)"),
            ("transparent_proxy_admin", "upgrade(address,address)"),
            ("transparent_proxy_admin", "upgrade(address,address)"),
            ("transparent_proxy_admin", "upgrade(address,address)"),
            // index = 5
            (
                "state_transition_manager",
                "setChainCreationParams((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))",
            ),

            ("state_transition_manager",
            "setNewVersionUpgrade(((address,uint8,bool,bytes4[])[],address,bytes),uint256,uint256,uint256)"),
            ("rollup_da_manager", "updateDAPair(address,address,bool)"),
            // Approve base token
            ("gateway_base_token", "approve(address,uint256)"),
            // Set new version for upgrade
            ("bridgehub_proxy", "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))"),
            // Approve base token
            ("gateway_base_token", "approve(address,uint256)"),
            // New chain creation params
            ("bridgehub_proxy", "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))"),
            // Approve base token
            ("gateway_base_token", "approve(address,uint256)"),
            // Upgrade CTM
            ("bridgehub_proxy", "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))"),
            // Approve base token
            ("gateway_base_token", "approve(address,uint256)"),
            // Upgrade CTM
            ("bridgehub_proxy", "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))"),
        ];
        const UPGRADE_CTM: usize = 2;
        const UPGRADE_BRIDGEHUB: usize = 3;
        const UPGRADE_L1_NULLIFIER: usize = 4;
        const UPGRADE_L1_ASSET_ROUTER: usize = 5;
        const UPGRADE_NATIVE_TOKEN_VAULT: usize = 6;
        const UPGRADE_MESSAGE_ROOT: usize = 7;
        const SET_CHAIN_CREATION_INDEX: usize = 8;
        const SET_NEW_VERSION_INDEX: usize = 9;
        const UPDATE_ROLLUP_DA_PAIR: usize = 10;
        const APPROVE_BASE_TOKEN_NEW_PROTOCOL_VERSION: usize = 11;
        const GATEWAY_SET_NEW_VERSION: usize = 12;
        const APPROVE_BASE_TOKEN_NEW_CHAIN_CREATION_PARAMS: usize = 13;
        const GATEWAY_NEW_CHAIN_CREATION_PARAMS: usize = 14;
        const APPROVE_BASE_TOKEN_UPGRADE_CTM: usize = 15;
        const GATEWAY_UPGRADE_CTM: usize = 16;
        const APPROVE_TOKEN_GATEWAY_UPDATE_DA_PAIR: usize = 17;
        const GATEWAY_UPDATE_DA_PAIR: usize = 18;

        // For calls without any params, we don't have to check
        // anything else. This is true for stage 0 and stage 2.

        self.calls.verify(&list_of_calls, verifiers, result)?;

        // Verify each upgrade call.
        self.verify_upgrade_call(
            verifiers,
            result,
            &self.calls.elems[UPGRADE_CTM],
            "state_transition_manager",
            "state_transition_implementation_addr",
            None,
        )?;

        self.verify_upgrade_call(
            verifiers,
            result,
            &self.calls.elems[UPGRADE_BRIDGEHUB],
            "bridgehub_proxy",
            "bridgehub_implementation_addr",
            None,
        )?;

        self.verify_upgrade_call(
            verifiers,
            result,
            &self.calls.elems[UPGRADE_L1_NULLIFIER],
            "l1_nullifier_proxy_addr",
            "l1_nullifier_implementation_addr",
            None,
        )?;

        self.verify_upgrade_call(
            verifiers,
            result,
            &self.calls.elems[UPGRADE_L1_ASSET_ROUTER],
            "l1_asset_router_proxy",
            "l1_asset_router_implementation_addr",
            None,
        )?;
        self.verify_upgrade_call(
            verifiers,
            result,
            &self.calls.elems[UPGRADE_NATIVE_TOKEN_VAULT],
            "native_token_vault",
            "native_token_vault_implementation_addr",
            None,
        )?;
        self.verify_upgrade_call(
            verifiers,
            result,
            &self.calls.elems[UPGRADE_MESSAGE_ROOT],
            "l1_message_root",
            "l1_message_root_implementation_addr",
            None,
        )?;

        // Verify setNewVersionUpgrade
        {
            let calldata = &self.calls.elems[SET_NEW_VERSION_INDEX].data;
            let data = setNewVersionUpgradeCall::abi_decode(calldata).unwrap();

            if data.oldProtocolVersionDeadline != U256::MAX {
                result.report_error("Wrong old protocol version deadline for stage1 call");
            }

            if data.newProtocolVersion != Into::<U256>::into(get_expected_new_protocol_version()) {
                result.report_error("Wrong new protocol version for stage1 call");
            }
            if data.oldProtocolVersion != Into::<U256>::into(get_expected_old_protocol_version()) {
                result.report_error("Wrong old protocol version for stage1 call");
            }

            let diamond_cut = data.diamondCut;
            if alloy::hex::encode(diamond_cut.abi_encode())
                != l1_expected_chain_upgrade_diamond_cut[2..]
            {
                result.report_error(&format!(
                    "Invalid chain upgrade diamond cut. Expected: {}\n Received: {}",
                    l1_expected_chain_upgrade_diamond_cut,
                    alloy::hex::encode(diamond_cut.abi_encode())
                ));
            }

            // should match state_transition.default_upgrade
            result.expect_address(verifiers, &diamond_cut.initAddress, "default_upgrade");

            verity_facet_cuts(
                &diamond_cut.facetCuts,
                result,
                l1_expected_upgrade_facets.clone(),
            )
            .await;

            let upgrade =
                super::set_new_version_upgrade::upgradeCall::abi_decode(&diamond_cut.initCalldata)
                    .unwrap();

            upgrade
                ._proposedUpgrade
                .verify(
                    verifiers,
                    result,
                    deployed_addresses.l1_bytecodes_supplier_addr,
                    false,
                )
                .await
                .context("proposed upgrade")?;
        }

        // Verify setChainCreationParams call.
        let (l1_chain_creation_diamond_cut, l1_force_deployments) = {
            let decoded = setChainCreationParamsCall::abi_decode(
                &self.calls.elems[SET_CHAIN_CREATION_INDEX].data,
            )
            .expect("Failed to decode setChainCreationParams call");
            decoded
                ._chainCreationParams
                .verify(
                    verifiers,
                    result,
                    l1_expected_chain_creation_facets.clone(),
                    false,
                )
                .await?;

            let ChainCreationParams {
                diamondCut,
                forceDeploymentsData,
                ..
            } = decoded._chainCreationParams;

            (
                hex::encode(diamondCut.abi_encode()),
                hex::encode(forceDeploymentsData),
            )
        };

        // Verify rollup_da_manager call
        {
            let decoded =
                updateDAPairCall::abi_decode(&self.calls.elems[UPDATE_ROLLUP_DA_PAIR].data)
                    .expect("Failed to decode updateDAPair call");
            if decoded.l1_da_addr != deployed_addresses.rollup_l1_da_validator_addr {
                result.report_error(&format!(
                    "Expected l1_da_addr to be {}, but got {}",
                    deployed_addresses.rollup_l1_da_validator_addr, decoded.l1_da_addr
                ));
            }

            if decoded.l2_da_addr
                != verifiers.address_verifier.name_to_address["rollup_l2_da_validator"]
            {
                result.report_error(&format!(
                    "Expected l2_da_addr to be {}, but got {}",
                    verifiers.address_verifier.name_to_address["rollup_l2_da_validator"],
                    decoded.l2_da_addr
                ));
            }
        }

        // Verify Approve base token
        {
            let calldata = &self.calls.elems[APPROVE_BASE_TOKEN_NEW_PROTOCOL_VERSION].data;
            let data = approveCall::abi_decode(&calldata).expect("Failed to decode approve call");

            result.expect_address(verifiers, &data.spender, "l1_asset_router_proxy");
        }

        // Verify Gateway Set new version for upgrade
        {
            let calldata = &self.calls.elems[GATEWAY_SET_NEW_VERSION].data;
            let data = requestL2TransactionDirectCall::abi_decode(&calldata)
                .expect("Failed to decode L2 -> GW setNewVersion");

            if data._request.chainId != U256::from(gateway_chain_id) {
                result.report_error("Wrong gateway chain id for stage1 setNewVersion");
            }

            let l2_data = setNewVersionUpgradeCall::abi_decode(&data._request.l2Calldata)
                .expect("Failed to decode setNewVersion Inner");

            if l2_data.oldProtocolVersionDeadline != U256::MAX {
                result.report_error("Wrong old protocol version deadline for stage1 call");
            }

            if l2_data.newProtocolVersion != Into::<U256>::into(get_expected_new_protocol_version())
            {
                result.report_error("Wrong new protocol version for stage1 call");
            }

            if l2_data.oldProtocolVersion != Into::<U256>::into(get_expected_old_protocol_version())
            {
                result.report_error("Wrong old protocol version for stage1 call");
            }

            let diamond_cut = l2_data.diamondCut;

            result.expect_address(
                verifiers,
                &diamond_cut.initAddress,
                "gateway_default_upgrade_addr",
            );

            if alloy::hex::encode(diamond_cut.abi_encode())
                != gw_expected_chain_upgrade_diamond_cut[2..]
            {
                result.report_error(&format!(
                    "Invalid gw chain upgrade diamond cut. Expected: {}\n Received: {}",
                    gw_expected_chain_upgrade_diamond_cut,
                    alloy::hex::encode(diamond_cut.abi_encode())
                ));
            }

            verity_facet_cuts(&diamond_cut.facetCuts, result, gw_expected_upgrade_facets).await;

            let upgrade =
                super::set_new_version_upgrade::upgradeCall::abi_decode(&diamond_cut.initCalldata)
                    .unwrap();

            upgrade
                ._proposedUpgrade
                .verify(
                    verifiers,
                    result,
                    deployed_addresses.l1_bytecodes_supplier_addr,
                    true,
                )
                .await
                .context("proposed upgrade")?;
        }

        // Verify Approve base token
        {
            let calldata = &self.calls.elems[APPROVE_BASE_TOKEN_NEW_CHAIN_CREATION_PARAMS].data;
            let data = approveCall::abi_decode(&calldata).expect("Failed to decode approve call");

            result.expect_address(verifiers, &data.spender, "l1_asset_router_proxy");
        }

        // Verify Gateway New chain creation params
        let (gw_chain_creation_diamond_cut, gw_force_deployments) = {
            let calldata = &self.calls.elems[GATEWAY_NEW_CHAIN_CREATION_PARAMS].data;
            let data = requestL2TransactionDirectCall::abi_decode(&calldata)
                .expect("Failed to decode L2 -> GW newCreationParams");

            if data._request.chainId != U256::from(gateway_chain_id) {
                result.report_error("Wrong gateway chain id for stage1 newCreationParams");
            }

            let l2_data = setChainCreationParamsCall::abi_decode(&data._request.l2Calldata)
                .expect("Failed to decode setChainCreationParams");

            l2_data
                ._chainCreationParams
                .verify(verifiers, result, gw_expected_chain_creation_facets, true)
                .await?;

            let ChainCreationParams {
                diamondCut,
                forceDeploymentsData,
                ..
            } = l2_data._chainCreationParams;

            (
                hex::encode(diamondCut.abi_encode()),
                hex::encode(forceDeploymentsData),
            )
        };

        // Verify Approve base token
        {
            let calldata = &self.calls.elems[APPROVE_BASE_TOKEN_UPGRADE_CTM].data;
            let data = approveCall::abi_decode(&calldata).expect("Failed to decode approve call");

            result.expect_address(verifiers, &data.spender, "l1_asset_router_proxy");
        }

        // Gateway verify CTM upgrade
        {
            let calldata = &self.calls.elems[GATEWAY_UPGRADE_CTM].data;
            let data = requestL2TransactionDirectCall::abi_decode(&calldata)
                .expect("Failed to decode L2 -> GW newCreationParams");

            if data._request.chainId != U256::from(gateway_chain_id) {
                result.report_error("Wrong gateway chain id for stage1 newCreationParams");
            }

            let call = Call {
                target: data._request.l2Contract,
                value: data._request.l2Value,
                data: data._request.l2Calldata,
            };

            self.verify_upgrade_call(
                verifiers,
                result,
                &call,
                "gateway_chain_type_manager_proxy",
                "gateway_chain_type_manager_implementation_addr",
                None,
            )?;
        }

        // Verify Approve base token
        {
            let calldata = &self.calls.elems[APPROVE_TOKEN_GATEWAY_UPDATE_DA_PAIR].data;
            let data = approveCall::abi_decode(&calldata).expect("Failed to decode approve call");

            result.expect_address(verifiers, &data.spender, "l1_asset_router_proxy");
        }

        // Verify GW rollup_da_manager call
        {
            let calldata = &self.calls.elems[GATEWAY_UPDATE_DA_PAIR].data;
            let decoded = check_l1_to_gateway_transaction(
                verifiers,
                result,
                calldata,
                updateDAPairCall::abi_decode,
                gateway_chain_id,
                priority_txs_l2_gas_limit,
                "gateway_rollup_da_manager",
            );

            result.expect_address(
                verifiers,
                &decoded.l1_da_addr,
                "gateway_rollup_l2_da_validator",
            );
            result.expect_address(verifiers, &decoded.l2_da_addr, "rollup_l2_da_validator");
        }

        Ok((
            l1_chain_creation_diamond_cut,
            l1_force_deployments,
            gw_chain_creation_diamond_cut,
            gw_force_deployments,
        ))
    }
}

impl ChainCreationParams {
    /// Verifies the chain creation parameters.
    pub async fn verify(
        &self,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        expected_chain_creation_facets: FacetCutSet,
        is_gateway: bool,
    ) -> anyhow::Result<()> {
        result.print_info("== Chain creation params ==");
        let genesis_upgrade_name = verifiers
            .address_verifier
            .name_or_unknown(&self.genesisUpgrade);

        let name = if is_gateway {
            "gateway_genesis_upgrade_addr"
        } else {
            "genesis_upgrade_addr"
        };

        if genesis_upgrade_name != name {
            result.report_error(&format!(
                "Expected genesis upgrade address to be genesis_upgrade_addr, but got {}",
                genesis_upgrade_name
            ));
        }

        if self.genesisBatchHash.to_string() != verifiers.genesis_config.genesis_root {
            result.report_error(&format!(
                "Expected genesis batch hash to be {}, but got {}",
                verifiers.genesis_config.genesis_root, self.genesisBatchHash
            ));
        }

        if self.genesisIndexRepeatedStorageChanges
            != verifiers.genesis_config.genesis_rollup_leaf_index
        {
            result.report_error(&format!(
                "Expected genesis index repeated storage changes to be {}, but got {}",
                verifiers.genesis_config.genesis_rollup_leaf_index,
                self.genesisIndexRepeatedStorageChanges
            ));
        }

        if self.genesisBatchCommitment.to_string()
            != verifiers.genesis_config.genesis_batch_commitment
        {
            result.report_error(&format!(
                "Expected genesis batch commitment to be {}, but got {}",
                verifiers.genesis_config.genesis_batch_commitment, self.genesisBatchCommitment
            ));
        }

        verify_chain_creation_diamond_cut(
            verifiers,
            result,
            &self.diamondCut,
            expected_chain_creation_facets,
            is_gateway,
        )
        .await?;

        let fixed_force_deployments_data =
            FixedForceDeploymentsData::abi_decode(&self.forceDeploymentsData)
                .expect("Failed to decode FixedForceDeploymentsData");
        fixed_force_deployments_data
            .verify(verifiers, result)
            .await?;

        Ok(())
    }
}

/// Verifies the diamond cut used during chain creation.
pub async fn verify_chain_creation_diamond_cut(
    verifiers: &crate::upgrade_verification::verifiers::Verifiers,
    result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    diamond_cut: &DiamondCutData,
    expected_chain_creation_facets: FacetCutSet,
    is_gateway: bool,
) -> anyhow::Result<()> {
    let mut proposed_facet_cut = FacetCutSet::new();
    for facet in &diamond_cut.facetCuts {
        let action = match facet.action {
            Action::Add => facet_cut_set::Action::Add,
            Action::Remove => {
                result.report_error("Remove action is unexpected in diamond cut");
                continue;
            }
            Action::Replace => {
                result.report_error("Replace action is unexpected in diamond cut");
                continue;
            }
            Action::__Invalid => {
                result.report_error("Invalid action in diamond cut");
                continue;
            }
        };
        proposed_facet_cut.add_facet(FacetInfo {
            facet: facet.facet,
            action,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }

    if expected_chain_creation_facets != proposed_facet_cut {
        result.report_error(&format!(
            "Invalid chain creation facet cut. Expected: {:#?}\nReceived: {:#?}",
            expected_chain_creation_facets, proposed_facet_cut
        ));
    }

    let name = if is_gateway {
        "gateway_diamond_init_addr"
    } else {
        "diamond_init"
    };
    result.expect_address(verifiers, &diamond_cut.initAddress, name);
    let initialize_data_new_chain = InitializeDataNewChain::abi_decode(&diamond_cut.initCalldata)
        .expect("Failed to decode InitializeDataNewChain");
    initialize_data_new_chain
        .verify(verifiers, result, is_gateway)
        .await?;

    Ok(())
}

pub async fn verity_facet_cuts(
    facet_cuts: &[set_new_version_upgrade::FacetCut],
    result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    expected_upgrade_facets: FacetCutSet,
) {
    // We ensure two invariants here:
    // - Firstly we use `Remove` operations only. This is mainly for ensuring that
    // the upgrade will pass.
    // - Secondly, we ensure that the set of operations is identical.
    let mut used_add = false;
    let mut proposed_facet_cuts = FacetCutSet::new();
    facet_cuts.iter().for_each(|facet| {
        let action = match facet.action {
            set_new_version_upgrade::Action::Add => {
                used_add = true;
                facet_cut_set::Action::Add
            }
            set_new_version_upgrade::Action::Remove => {
                assert!(!used_add, "Unexpected `Remove` operation after `Add`");
                facet_cut_set::Action::Remove
            }
            set_new_version_upgrade::Action::Replace => panic!("Replace unexpected"),
            set_new_version_upgrade::Action::__Invalid => panic!("Invalid unexpected"),
        };

        proposed_facet_cuts.add_facet(FacetInfo {
            facet: facet.facet,
            action,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    });

    if proposed_facet_cuts != expected_upgrade_facets {
        result.report_error(&format!(
            "Incorrect facet cuts. Expected {:#?}\nReceived: {:#?}",
            expected_upgrade_facets, proposed_facet_cuts
        ));
    }
}

impl GovernanceStage0Calls {
    /// Stage0 is executed before the main upgrade even starts.
    pub(crate) async fn verify(
        &self,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        gateway_chain_id: u64,
        priority_txs_l2_gas_limit: u64,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 0 calls ===");

        // Stage 0 handles pausing migration on L1 and on Gateway
        let list_of_calls = [
            ("bridgehub_proxy", "pauseMigration()"),
            ("gateway_base_token", "approve(address,uint256)"),
            ("bridgehub_proxy", "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))"),
            ("upgrade_timer", "startTimer()"),
        ];
        const PAUSE_L1_MIGRATION: usize = 0;
        const APPROVE_BASE_TOKEN: usize = 1;
        const PAUSE_GATEWAY_MIGRATION: usize = 2;

        // For calls without any params, we don't have to check
        // anything else. This is true for stage 1 and stage 2.
        self.calls.verify(&list_of_calls, verifiers, result)?;

        // Verify pauseMigration
        {
            let calldata = &self.calls.elems[PAUSE_L1_MIGRATION].data;
            pauseMigrationCall::abi_decode(&calldata)
                .expect("Failed to decode pauseMigration Call on L1");
        }

        // Verify approve base token
        {
            let calldata = &self.calls.elems[APPROVE_BASE_TOKEN].data;
            let data = approveCall::abi_decode(&calldata).expect("Failed to decode approve call");

            result.expect_address(verifiers, &data.spender, "l1_asset_router_proxy");
        }

        // Verify L1 -> Gateway Pause Migration
        {
            let calldata = &self.calls.elems[PAUSE_GATEWAY_MIGRATION].data;
            check_l1_to_gateway_transaction(
                verifiers,
                result,
                calldata,
                pauseMigrationCall::abi_decode,
                gateway_chain_id,
                priority_txs_l2_gas_limit,
                "l2_bridgehub",
            );
        }

        Ok(())
    }
}

impl GovernanceStage2Calls {
    /// Stage2 is executed after all the chains have upgraded.
    pub(crate) async fn verify(
        &self,
        verifiers: &crate::upgrade_verification::verifiers::Verifiers,
        result: &mut crate::upgrade_verification::verifiers::VerificationResult,
        gateway_chain_id: u64,
        priority_txs_l2_gas_limit: u64,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 2 calls ===");

        // Stage2 is where we create the upgrade on gateway and unpause migration
        // on gateway and unpause migration on l1

        let list_of_calls = [
            // Check that the protocol upgrade has happened
            ("upgrade_stage_validator", "checkProtocolUpgradePresence()"),
            // Unpause L1 migration
            ("bridgehub_proxy", "unpauseMigration()"),
            // Approve base token
            ("gateway_base_token", "approve(address,uint256)"),
            // Unpause gateway
            ("bridgehub_proxy", "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))"),
            // Check that migrations are unpaused
            ("upgrade_stage_validator", "checkMigrationsUnpaused()"),
        ];
        const APPROVE_BASE_TOKEN: usize = 2;
        const GATEWAY_UNPAUSE_MIGRATION: usize = 3;

        // For calls without any params, we don't have to check
        // anything else. This is true for stage 0 and stage 1.
        self.calls.verify(&list_of_calls, verifiers, result)?;

        // Verify Approve base token
        {
            let calldata = &self.calls.elems[APPROVE_BASE_TOKEN].data;
            let data = approveCall::abi_decode(&calldata).expect("Failed to decode approve call");

            result.expect_address(verifiers, &data.spender, "l1_asset_router_proxy");
        }

        // Verify Unpause gateway migration
        {
            let calldata = &self.calls.elems[GATEWAY_UNPAUSE_MIGRATION].data;
            check_l1_to_gateway_transaction(
                verifiers,
                result,
                calldata,
                unpauseMigrationCall::abi_decode,
                gateway_chain_id,
                priority_txs_l2_gas_limit,
                "l2_bridgehub",
            );
        }

        Ok(())
    }
}

fn check_l1_to_gateway_transaction<T, F>(
    verifiers: &crate::upgrade_verification::verifiers::Verifiers,
    result: &mut crate::upgrade_verification::verifiers::VerificationResult,
    calldata: &Bytes,
    decoder: F,
    gateway_chain_id: u64,
    priority_txs_l2_gas_limit: u64,
    expected_l2_contract: &str,
) -> T
where
    F: Fn(&[u8]) -> alloy::sol_types::Result<T>,
{
    let data = requestL2TransactionDirectCall::abi_decode(&calldata)
        .expect("Failed to decode L2 -> GW transaction");

    if data._request.chainId != U256::from(gateway_chain_id) {
        result.report_error("Wrong gateway chain id for L2 -> GW transaction");
    }

    if data._request.l2GasLimit != U256::from(priority_txs_l2_gas_limit) {
        result.report_error("Wrong l2GasLimit for L2 -> GW transaction");
    }

    result.expect_address(verifiers, &data._request.l2Contract, expected_l2_contract);

    decoder(&data._request.l2Calldata).expect("Failed to decode inner L1 -> GW")
}
