use alloy::{
    primitives::{Address, U256},
    sol,
    sol_types::SolCall,
};
use anyhow::{Context, Result};

use crate::{
    common::{
        abi::IServerNotifierAbi,
        governance_calls::{decode_calls, GovernanceCall},
    },
    upgrade_verification::{
        artifacts::{
            required_address_in_value as required_address, CtmArtifact, EcosystemUpgradeArtifact,
        },
        verifiers::{VerificationResult, Verifiers},
    },
};

sol! {
    function upgrade(address proxy, address implementation);
    function acceptOwnership();
    function setUpgradePreconditionChecker(uint256 _protocolVersion, address _checker);

    #[sol(rpc)]
    contract ChainTypeManagerView {
        function serverNotifierAddress() external view returns (address);
    }

    #[sol(rpc)]
    contract OwnableView {
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
    }
}

#[derive(Clone, Copy)]
struct ExpectedServerNotifierUpgrade {
    proxy_admin: Address,
    server_notifier: Address,
    implementation: Address,
    old_protocol_version: U256,
    checker: Address,
}

pub(crate) async fn verify_ctm_admin_calls(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    result.print_info("== CTM admin calls ==");

    for ctm in &artifact.ctms {
        if let Err(err) = verify_server_notifier_upgrade(ctm, verifiers).await {
            result.report_error(&format!(
                "ctms.{}.ctm_admin_calls.server_notifier_upgrade: {err:#}",
                ctm.flavor.label()
            ));
        } else {
            result.report_ok(&format!(
                "ctms.{}.ctm_admin_calls.server_notifier_upgrade contains the expected ordered calls",
                ctm.flavor.label()
            ));
        }
    }

    Ok(())
}

async fn verify_server_notifier_upgrade(ctm: &CtmArtifact, verifiers: &Verifiers) -> Result<()> {
    let scope = format!("ctms.{}", ctm.flavor.label());
    let ctm_proxy = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "chain_type_manager_proxy"],
    )?;
    let server_notifier =
        ChainTypeManagerView::new(ctm_proxy, verifiers.network_verifier.get_l1_provider())
            .serverNotifierAddress()
            .call()
            .await
            .with_context(|| {
                format!("calling ChainTypeManager.serverNotifierAddress() at {ctm_proxy}")
            })?;
    anyhow::ensure!(
        server_notifier != Address::ZERO,
        "ChainTypeManager.serverNotifierAddress() returned address(0)"
    );

    let proxy_admin = verifiers
        .network_verifier
        .try_get_proxy_admin(server_notifier)
        .await?;
    anyhow::ensure!(
        proxy_admin != Address::ZERO,
        "ServerNotifier {server_notifier} has no EIP-1967 proxy admin"
    );

    let intended_chain_admin =
        required_address(&ctm.value, &scope, &["ctm_admin_calls", "chain_admin"])?;
    anyhow::ensure!(
        intended_chain_admin != Address::ZERO,
        "{scope}.ctm_admin_calls.chain_admin must not be address(0)"
    );

    let provider = verifiers.network_verifier.get_l1_provider();
    let live_chain_admin = OwnableView::new(proxy_admin, provider.clone())
        .owner()
        .call()
        .await
        .with_context(|| format!("calling ProxyAdmin.owner() at {proxy_admin}"))?;
    anyhow::ensure!(
        live_chain_admin == intended_chain_admin,
        "ServerNotifier ProxyAdmin owner must be intended ChainAdmin {intended_chain_admin}, got {live_chain_admin}"
    );

    let intended_chain_admin_owner = required_address(
        &ctm.value,
        &scope,
        &["ctm_admin_calls", "chain_admin_owner"],
    )?;
    let live_chain_admin_owner = OwnableView::new(live_chain_admin, provider.clone())
        .owner()
        .call()
        .await
        .with_context(|| format!("calling ChainAdmin.owner() at {live_chain_admin}"))?;
    validate_chain_admin_owner(live_chain_admin_owner, intended_chain_admin_owner)?;

    let server_notifier_ownable = OwnableView::new(server_notifier, provider);
    let server_notifier_owner = server_notifier_ownable
        .owner()
        .call()
        .await
        .with_context(|| format!("calling ServerNotifier.owner() at {server_notifier}"))?;
    let pending_owner = server_notifier_ownable
        .pendingOwner()
        .call()
        .await
        .with_context(|| format!("calling ServerNotifier.pendingOwner() at {server_notifier}"))?;
    validate_ownership_state(server_notifier_owner, pending_owner, intended_chain_admin)?;

    let implementation = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "server_notifier_implementation_addr"],
    )?;
    let checker = required_address(
        &ctm.value,
        &scope,
        &["state_transition", "upgrade_precondition_checker_addr"],
    )?;
    anyhow::ensure!(
        implementation != Address::ZERO,
        "{scope}.state_transition.server_notifier_implementation_addr must not be address(0)"
    );
    anyhow::ensure!(
        checker != Address::ZERO,
        "{scope}.state_transition.upgrade_precondition_checker_addr must not be address(0)"
    );
    let encoded_calls = required_server_notifier_upgrade(ctm)?;

    let expected = ExpectedServerNotifierUpgrade {
        proxy_admin,
        server_notifier,
        implementation,
        old_protocol_version: U256::from(ctm.contracts_config.old_protocol_version),
        checker,
    };
    validate_server_notifier_upgrade(encoded_calls, expected)?;
    // The prepare phase executes both supported call sequences before verification.
    let implementation = verifiers
        .network_verifier
        .try_get_proxy_implementation(server_notifier)
        .await?;
    let checker = IServerNotifierAbi::new(
        server_notifier,
        verifiers.network_verifier.get_l1_provider(),
    )
    .upgradePreconditionChecker(expected.old_protocol_version)
    .call()
    .await
    .context("reading the checker registered by the completed ServerNotifier upgrade")?;
    validate_completed_upgrade(implementation, checker, expected)?;
    Ok(())
}

fn validate_completed_upgrade(
    implementation: Address,
    checker: Address,
    expected: ExpectedServerNotifierUpgrade,
) -> Result<()> {
    anyhow::ensure!(
        implementation == expected.implementation,
        "completed preparation requires ServerNotifier implementation {}, got {implementation}",
        expected.implementation
    );
    anyhow::ensure!(
        checker == expected.checker,
        "completed preparation requires registered checker {}, got {checker}",
        expected.checker
    );
    Ok(())
}

fn validate_ownership_state(
    owner: Address,
    pending_owner: Address,
    intended_owner: Address,
) -> Result<()> {
    anyhow::ensure!(
        owner == intended_owner,
        "prepared ServerNotifier owner must be intended ChainAdmin {intended_owner}, got {owner}"
    );
    anyhow::ensure!(
        pending_owner == Address::ZERO,
        "prepared ServerNotifier has stale pending owner {pending_owner}"
    );
    Ok(())
}

fn validate_chain_admin_owner(live_owner: Address, intended_owner: Address) -> Result<()> {
    anyhow::ensure!(
        intended_owner != Address::ZERO,
        "ctm_admin_calls.chain_admin_owner must not be address(0)"
    );
    anyhow::ensure!(
        live_owner == intended_owner,
        "ChainAdmin owner must be intended signer {intended_owner}, got {live_owner}"
    );
    Ok(())
}

fn required_server_notifier_upgrade(ctm: &CtmArtifact) -> Result<&str> {
    let path = format!(
        "ctms.{}.ctm_admin_calls.server_notifier_upgrade",
        ctm.flavor.label()
    );
    ctm.value
        .get("ctm_admin_calls")
        .and_then(|value| value.get("server_notifier_upgrade"))
        .with_context(|| format!("{path} is required"))?
        .as_str()
        .with_context(|| format!("{path} must be a string"))
}

fn validate_server_notifier_upgrade(
    encoded_calls: &str,
    expected: ExpectedServerNotifierUpgrade,
) -> Result<()> {
    anyhow::ensure!(
        encoded_calls.starts_with("0x"),
        "must be a 0x-prefixed ABI-encoded Call[]"
    );
    let calls = decode_calls(encoded_calls).context("decoding ABI-encoded Call[]")?;
    let includes_ownership_acceptance = calls.len() == 3;
    anyhow::ensure!(
        matches!(calls.len(), 2 | 3),
        "expected 2 or 3 calls, got {}",
        calls.len()
    );

    validate_proxy_admin_upgrade(&calls[0], expected)?;
    let registration_index = if includes_ownership_acceptance {
        validate_accept_ownership(&calls[1], expected)?;
        2
    } else {
        1
    };
    validate_checker_registration(&calls[registration_index], registration_index, expected)?;
    Ok(())
}

fn validate_proxy_admin_upgrade(
    call: &GovernanceCall,
    expected: ExpectedServerNotifierUpgrade,
) -> Result<()> {
    anyhow::ensure!(
        call.target == expected.proxy_admin,
        "call #0 target must be ServerNotifier ProxyAdmin {}, got {}",
        expected.proxy_admin,
        call.target
    );
    anyhow::ensure!(call.value == U256::ZERO, "call #0 value must be zero");

    let decoded =
        upgradeCall::abi_decode(&call.data).context("call #0 must be upgrade(address,address)")?;
    anyhow::ensure!(
        decoded.abi_encode() == call.data,
        "call #0 must contain only canonical upgrade(address,address) calldata"
    );
    anyhow::ensure!(
        decoded.proxy == expected.server_notifier,
        "call #0 proxy must be ServerNotifier {}, got {}",
        expected.server_notifier,
        decoded.proxy
    );
    anyhow::ensure!(
        decoded.implementation == expected.implementation,
        "call #0 implementation must be {}, got {}",
        expected.implementation,
        decoded.implementation
    );
    Ok(())
}

fn validate_accept_ownership(
    call: &GovernanceCall,
    expected: ExpectedServerNotifierUpgrade,
) -> Result<()> {
    anyhow::ensure!(
        call.target == expected.server_notifier,
        "call #1 target must be ServerNotifier {}, got {}",
        expected.server_notifier,
        call.target
    );
    anyhow::ensure!(call.value == U256::ZERO, "call #1 value must be zero");

    let decoded =
        acceptOwnershipCall::abi_decode(&call.data).context("call #1 must be acceptOwnership()")?;
    anyhow::ensure!(
        decoded.abi_encode() == call.data,
        "call #1 must contain only canonical acceptOwnership() calldata"
    );
    Ok(())
}

fn validate_checker_registration(
    call: &GovernanceCall,
    call_index: usize,
    expected: ExpectedServerNotifierUpgrade,
) -> Result<()> {
    anyhow::ensure!(
        call.target == expected.server_notifier,
        "call #{call_index} target must be ServerNotifier {}, got {}",
        expected.server_notifier,
        call.target
    );
    anyhow::ensure!(
        call.value == U256::ZERO,
        "call #{call_index} value must be zero"
    );

    let decoded = setUpgradePreconditionCheckerCall::abi_decode(&call.data).with_context(|| {
        format!("call #{call_index} must be setUpgradePreconditionChecker(uint256,address)")
    })?;
    anyhow::ensure!(
        decoded.abi_encode() == call.data,
        "call #{call_index} must contain only canonical setUpgradePreconditionChecker(uint256,address) calldata"
    );
    anyhow::ensure!(
        decoded._protocolVersion == expected.old_protocol_version,
        "call #{call_index} protocol version must be {}, got {}",
        expected.old_protocol_version,
        decoded._protocolVersion
    );
    anyhow::ensure!(
        decoded._checker == expected.checker,
        "call #{call_index} checker must be {}, got {}",
        expected.checker,
        decoded._checker
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use alloy::sol_types::SolCall;

    use crate::common::governance_calls::encode_calls;
    use crate::upgrade_verification::artifacts::{ContractsConfig, CtmFlavor};

    use super::*;

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    fn expected() -> ExpectedServerNotifierUpgrade {
        ExpectedServerNotifierUpgrade {
            proxy_admin: address(1),
            server_notifier: address(2),
            implementation: address(3),
            old_protocol_version: U256::from(31_u64) << 32,
            checker: address(4),
        }
    }

    fn valid_calls(
        expected: ExpectedServerNotifierUpgrade,
        accept_ownership: bool,
    ) -> Vec<GovernanceCall> {
        let mut calls = vec![GovernanceCall {
            target: expected.proxy_admin,
            value: U256::ZERO,
            data: upgradeCall::new((expected.server_notifier, expected.implementation))
                .abi_encode(),
        }];
        if accept_ownership {
            calls.push(GovernanceCall {
                target: expected.server_notifier,
                value: U256::ZERO,
                data: acceptOwnershipCall::new(()).abi_encode(),
            });
        }
        calls.push(GovernanceCall {
            target: expected.server_notifier,
            value: U256::ZERO,
            data: setUpgradePreconditionCheckerCall::new((
                expected.old_protocol_version,
                expected.checker,
            ))
            .abi_encode(),
        });
        calls
    }

    fn encoded(calls: &[GovernanceCall]) -> String {
        format!("0x{}", alloy::hex::encode(encode_calls(calls)))
    }

    fn ctm_with_value(value: toml::Value) -> CtmArtifact {
        CtmArtifact {
            flavor: CtmFlavor::ZksyncOs,
            chain_upgrade_diamond_cut: "0x".to_owned(),
            contracts_config: ContractsConfig {
                diamond_cut_data: "0x".to_owned(),
                force_deployments_data: "0x".to_owned(),
                new_protocol_version: 2,
                old_protocol_version: 1,
                governance_upgrade_timer_initial_delay: 0,
                is_testnet: true,
            },
            value,
        }
    }

    #[test]
    fn accepts_exact_ordered_server_notifier_calls() {
        let expected = expected();
        validate_server_notifier_upgrade(&encoded(&valid_calls(expected, false)), expected)
            .unwrap();

        validate_server_notifier_upgrade(&encoded(&valid_calls(expected, true)), expected).unwrap();
    }

    #[test]
    fn rejects_missing_or_too_many_calls() {
        let expected = expected();
        let mut calls = valid_calls(expected, false);
        calls.pop();
        let err = validate_server_notifier_upgrade(&encoded(&calls), expected).unwrap_err();
        assert!(format!("{err:#}").contains("expected 2 or 3 calls"));

        let mut calls = valid_calls(expected, false);
        calls.push(calls[1].clone());
        calls.push(calls[1].clone());
        let err = validate_server_notifier_upgrade(&encoded(&calls), expected).unwrap_err();
        assert!(format!("{err:#}").contains("expected 2 or 3 calls"));
    }

    #[test]
    fn rejects_reordered_calls() {
        let expected = expected();
        let mut calls = valid_calls(expected, false);
        calls.swap(0, 1);
        let err = validate_server_notifier_upgrade(&encoded(&calls), expected).unwrap_err();
        assert!(format!("{err:#}").contains("call #0 target must be ServerNotifier ProxyAdmin"));
    }

    #[test]
    fn rejects_wrong_proxy_admin_upgrade_fields() {
        let expected = expected();
        for (label, target, proxy, implementation) in [
            (
                "target",
                address(9),
                expected.server_notifier,
                expected.implementation,
            ),
            (
                "proxy",
                expected.proxy_admin,
                address(9),
                expected.implementation,
            ),
            (
                "implementation",
                expected.proxy_admin,
                expected.server_notifier,
                address(9),
            ),
        ] {
            let mut calls = valid_calls(expected, false);
            calls[0].target = target;
            calls[0].data = upgradeCall::new((proxy, implementation)).abi_encode();
            assert!(
                validate_server_notifier_upgrade(&encoded(&calls), expected).is_err(),
                "wrong {label} must fail"
            );
        }

        let mut calls = valid_calls(expected, false);
        calls[0].value = U256::from(1);
        assert!(validate_server_notifier_upgrade(&encoded(&calls), expected).is_err());
    }

    #[test]
    fn rejects_wrong_checker_registration_fields() {
        let expected = expected();
        for (label, target, version, checker) in [
            (
                "target",
                address(9),
                expected.old_protocol_version,
                expected.checker,
            ),
            (
                "protocol version",
                expected.server_notifier,
                expected.old_protocol_version + U256::from(1),
                expected.checker,
            ),
            (
                "checker",
                expected.server_notifier,
                expected.old_protocol_version,
                address(9),
            ),
        ] {
            let mut calls = valid_calls(expected, false);
            calls[1].target = target;
            calls[1].data = setUpgradePreconditionCheckerCall::new((version, checker)).abi_encode();
            assert!(
                validate_server_notifier_upgrade(&encoded(&calls), expected).is_err(),
                "wrong {label} must fail"
            );
        }

        let mut calls = valid_calls(expected, false);
        calls[1].value = U256::from(1);
        assert!(validate_server_notifier_upgrade(&encoded(&calls), expected).is_err());
    }

    #[test]
    fn validates_optional_accept_ownership_call() {
        let expected = expected();

        for (label, target, value, data) in [
            (
                "target",
                address(9),
                U256::ZERO,
                acceptOwnershipCall::new(()).abi_encode(),
            ),
            (
                "value",
                expected.server_notifier,
                U256::from(1),
                acceptOwnershipCall::new(()).abi_encode(),
            ),
            (
                "selector",
                expected.server_notifier,
                U256::ZERO,
                vec![0_u8; 4],
            ),
        ] {
            let mut calls = valid_calls(expected, true);
            calls[1] = GovernanceCall {
                target,
                value,
                data,
            };
            assert!(
                validate_server_notifier_upgrade(&encoded(&calls), expected).is_err(),
                "wrong acceptOwnership {label} must fail"
            );
        }
    }

    #[test]
    fn verifies_both_call_shapes_after_prepare_executes_them() {
        let expected = expected();
        let intended_owner = address(5);
        validate_ownership_state(intended_owner, Address::ZERO, intended_owner).unwrap();

        for accept_ownership in [false, true] {
            let prepared_calls = encoded(&valid_calls(expected, accept_ownership));
            validate_server_notifier_upgrade(&prepared_calls, expected).unwrap();
            validate_completed_upgrade(expected.implementation, expected.checker, expected)
                .unwrap();

            let err =
                validate_completed_upgrade(address(9), expected.checker, expected).unwrap_err();
            assert!(format!("{err:#}").contains("requires ServerNotifier implementation"));
            for checker in [Address::ZERO, address(9)] {
                let err = validate_completed_upgrade(expected.implementation, checker, expected)
                    .unwrap_err();
                assert!(format!("{err:#}").contains("requires registered checker"));
            }
        }
    }

    #[test]
    fn rejects_incomplete_or_stale_ownership_transfers() {
        let intended_owner = address(5);
        let err = validate_ownership_state(address(6), intended_owner, intended_owner).unwrap_err();
        assert!(format!("{err:#}").contains("owner must be intended ChainAdmin"));

        let err = validate_ownership_state(intended_owner, address(7), intended_owner).unwrap_err();
        assert!(format!("{err:#}").contains("stale pending owner"));
    }

    #[test]
    fn validates_chain_admin_owner() {
        let intended_owner = address(5);
        validate_chain_admin_owner(intended_owner, intended_owner).unwrap();

        let err = validate_chain_admin_owner(address(6), intended_owner).unwrap_err();
        assert!(format!("{err:#}").contains("must be intended signer"));

        let err = validate_chain_admin_owner(Address::ZERO, Address::ZERO).unwrap_err();
        assert!(format!("{err:#}").contains("must not be address(0)"));
    }

    #[test]
    fn rejects_wrong_selectors_and_trailing_calldata() {
        let expected = expected();
        let mut calls = valid_calls(expected, false);
        calls[0].data = vec![0_u8; 4];
        assert!(validate_server_notifier_upgrade(&encoded(&calls), expected).is_err());

        let mut calls = valid_calls(expected, false);
        calls[1].data.push(0);
        let err = validate_server_notifier_upgrade(&encoded(&calls), expected).unwrap_err();
        assert!(format!("{err:#}").contains("canonical setUpgradePreconditionChecker"));
    }

    #[test]
    fn requires_string_server_notifier_upgrade_field() {
        let missing = ctm_with_value(toml::from_str("").unwrap());
        let err = required_server_notifier_upgrade(&missing).unwrap_err();
        assert!(format!("{err:#}").contains("server_notifier_upgrade is required"));

        let wrong_type = ctm_with_value(
            toml::from_str("[ctm_admin_calls]\nserver_notifier_upgrade = 1").unwrap(),
        );
        let err = required_server_notifier_upgrade(&wrong_type).unwrap_err();
        assert!(format!("{err:#}").contains("server_notifier_upgrade must be a string"));
    }
}
