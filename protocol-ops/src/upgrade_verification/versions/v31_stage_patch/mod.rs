use alloy::{
    hex,
    primitives::{address, Address, Bytes, FixedBytes, U256},
    sol,
    sol_types::{SolCall, SolConstructor},
};
use anyhow::Context;

use crate::upgrade_verification::{
    verifiers::VerificationResult, versions::v31::utils::network_verifier::NetworkVerifier,
};

const ZKOS_VT_PROXY: Address = address!("0x1E4299F7a19597E09bD8593AB7B68277183e9778");
const ZKOS_VT_PROXY_ADMIN: Address = address!("0xff3582a0310916cd62442A4CA88Bf1C757D68938");
const ZKOS_BRIDGEHUB: Address = address!("0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE");

const MULTISIG_COMMITTER_FILE: &str = "l1-contracts/MultisigCommitter";

sol! {
    #[derive(Debug)]
    struct EmergencyUpgradeBoardCall {
        address target;
        uint256 value;
        bytes data;
    }

    function executeEmergencyUpgrade(
        EmergencyUpgradeBoardCall[] _calls,
        bytes32 _salt,
        bytes _guardiansSignatures,
        bytes _securityCouncilSignatures,
        bytes _zkFoundationSignatures
    );

    function upgrade(address proxy, address implementation);

    contract StagePatchMultisigCommitter {
        constructor(address _bridgehubAddr);
    }
}

pub(crate) struct StagePatchVerificationInput<'a> {
    pub(crate) execute_calldata: &'a str,
    pub(crate) network_verifier: &'a NetworkVerifier,
}

pub(crate) fn verify(
    input: StagePatchVerificationInput<'_>,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== v31 stage patch verification ==");

    let execute_call = decode_execute_calldata(input.execute_calldata)?;
    verify_outer_execute_call(&execute_call, result);

    let Some(vt_impl) = verify_upgrade_call(
        &execute_call._calls,
        0,
        "ZKsync OS ValidatorTimelock restore",
        ZKOS_VT_PROXY_ADMIN,
        ZKOS_VT_PROXY,
        result,
    ) else {
        return Ok(());
    };

    result.print_info("== Deployment provenance ==");
    expect_create2_params(
        result,
        input.network_verifier,
        vt_impl,
        StagePatchMultisigCommitter::constructorCall::new((ZKOS_BRIDGEHUB,)).abi_encode(),
        MULTISIG_COMMITTER_FILE,
    );

    Ok(())
}

fn decode_execute_calldata(calldata: &str) -> anyhow::Result<executeEmergencyUpgradeCall> {
    let bytes = decode_hex(calldata).context("decode --execute-calldata")?;
    executeEmergencyUpgradeCall::abi_decode(&bytes)
        .context("decode EmergencyUpgradeBoard.executeEmergencyUpgrade calldata")
}

fn verify_outer_execute_call(
    execute_call: &executeEmergencyUpgradeCall,
    result: &mut VerificationResult,
) {
    if execute_call._calls.len() == 1 {
        result.report_ok("Emergency upgrade proposal contains exactly one call");
    } else {
        result.report_error(&format!(
            "Emergency upgrade proposal must contain exactly one call, got {}",
            execute_call._calls.len()
        ));
    }

    if execute_call._salt == FixedBytes::<32>::ZERO {
        result.report_ok("Emergency upgrade proposal salt is zero");
    } else {
        result.report_error(&format!(
            "Emergency upgrade proposal salt must be zero, got {}",
            execute_call._salt
        ));
    }
}

fn verify_upgrade_call(
    calls: &[EmergencyUpgradeBoardCall],
    index: usize,
    label: &str,
    expected_target: Address,
    expected_proxy: Address,
    result: &mut VerificationResult,
) -> Option<Address> {
    let Some(call) = calls.get(index) else {
        result.report_error(&format!("Missing {label} call at index {index}"));
        return None;
    };

    let mut errors = 0;
    if call.target != expected_target {
        result.report_error(&format!(
            "{label} call target mismatch: expected {expected_target}, got {}",
            call.target
        ));
        errors += 1;
    }
    if call.value != U256::ZERO {
        result.report_error(&format!(
            "{label} call value must be zero, got {}",
            call.value
        ));
        errors += 1;
    }

    let decoded = match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => decoded,
        Err(err) => {
            result.report_error(&format!(
                "{label} call must be ProxyAdmin.upgrade(address,address): {err}"
            ));
            return None;
        }
    };

    if decoded.proxy != expected_proxy {
        result.report_error(&format!(
            "{label} proxy mismatch: expected {expected_proxy}, got {}",
            decoded.proxy
        ));
        errors += 1;
    }

    let exact = upgradeCall::new((decoded.proxy, decoded.implementation)).abi_encode();
    if call.data.as_ref() != exact.as_slice() {
        result.report_error(&format!(
            "{label} calldata is not the exact ABI encoding of ProxyAdmin.upgrade(proxy, implementation)"
        ));
        errors += 1;
    }

    if errors == 0 {
        result.report_ok(&format!(
            "{label} call #{index} is a zero-value ProxyAdmin.upgrade to {}",
            decoded.implementation
        ));
    }

    Some(decoded.implementation)
}

fn expect_create2_params(
    result: &mut VerificationResult,
    network_verifier: &NetworkVerifier,
    address: Address,
    expected_constructor_params: Vec<u8>,
    expected_file: &str,
) {
    let Some(deployed_file) = network_verifier.create2_known_bytecodes.get(&address) else {
        result.report_error(&format!(
            "{expected_file} implementation {address} is not present in recognized CREATE2 deployments"
        ));
        return;
    };

    if deployed_file != expected_file {
        result.report_error(&format!(
            "CREATE2 deployment at {address} has wrong contract: expected {expected_file}, got {deployed_file}"
        ));
        return;
    }

    let Some(constructor_params) = network_verifier.create2_constructor_params.get(&address) else {
        result.report_error(&format!(
            "CREATE2 deployment at {address} ({expected_file}) has no constructor params recorded"
        ));
        return;
    };

    if constructor_params.as_slice() != expected_constructor_params.as_slice() {
        result.report_error(&format!(
            "Invalid constructor params for {expected_file} at {address}: expected 0x{}, got 0x{}",
            hex::encode(expected_constructor_params),
            hex::encode(constructor_params)
        ));
        return;
    }

    result.report_ok(&format!(
        "{expected_file} implementation {address} has expected CREATE2 constructor params"
    ));
}

fn decode_hex(value: &str) -> anyhow::Result<Bytes> {
    let trimmed = value.trim().strip_prefix("0x").unwrap_or(value.trim());
    let bytes = hex::decode(trimmed).context("invalid hex")?;
    Ok(Bytes::from(bytes))
}
