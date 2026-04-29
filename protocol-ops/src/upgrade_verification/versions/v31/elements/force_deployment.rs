use std::fmt::Display;

use alloy::{
    primitives::{Address, U256},
    sol,
};

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::super::utils::address_from_short_hex;

sol! {
    #[derive(Debug)]
    struct ForceDeployment {
        bytes32 bytecodeHash;
        address newAddress;
        bool callConstructor;
        uint256 value;
        bytes input;
    }
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployParams) external;

}

impl Display for ForceDeployment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Force deploy: {} to {}",
            self.bytecodeHash, self.newAddress
        )
    }
}

pub fn expected_force_deployments() -> Vec<(String, Address, bool)> {
    vec![
        (
            "system-contracts/EmptyContract".into(),
            address_from_short_hex("0"),
            false,
        ),
        ("Ecrecover".into(), address_from_short_hex("1"), false),
        ("SHA256".into(), address_from_short_hex("2"), false),
        ("Identity".into(), address_from_short_hex("4"), false),
        ("EcAdd".into(), address_from_short_hex("6"), false),
        ("EcMul".into(), address_from_short_hex("7"), false),
        ("EcPairing".into(), address_from_short_hex("8"), false),
        ("Modexp".into(), address_from_short_hex("5"), false),
        // Note: deploy `EmptyContract` into the bootloader address.
        (
            "system-contracts/EmptyContract".into(),
            address_from_short_hex("8001"),
            false,
        ),
        (
            "system-contracts/AccountCodeStorage".into(),
            address_from_short_hex("8002"),
            false,
        ),
        (
            "system-contracts/NonceHolder".into(),
            address_from_short_hex("8003"),
            false,
        ),
        (
            "system-contracts/KnownCodesStorage".into(),
            address_from_short_hex("8004"),
            false,
        ),
        (
            "system-contracts/ImmutableSimulator".into(),
            address_from_short_hex("8005"),
            false,
        ),
        (
            "system-contracts/ContractDeployer".into(),
            address_from_short_hex("8006"),
            false,
        ),
        // We deploy nothing to the 8007 address.
        (
            "system-contracts/L1Messenger".into(),
            address_from_short_hex("8008"),
            false,
        ),
        (
            "system-contracts/MsgValueSimulator".into(),
            address_from_short_hex("8009"),
            false,
        ),
        (
            "system-contracts/L2BaseToken".into(),
            address_from_short_hex("800a"),
            false,
        ),
        (
            "system-contracts/SystemContext".into(),
            address_from_short_hex("800b"),
            false,
        ),
        (
            "system-contracts/BootloaderUtilities".into(),
            address_from_short_hex("800c"),
            false,
        ),
        ("EventWriter".into(), address_from_short_hex("800d"), false),
        (
            "system-contracts/Compressor".into(),
            address_from_short_hex("800e"),
            false,
        ),
        (
            "system-contracts/ComplexUpgrader".into(),
            address_from_short_hex("800f"),
            false,
        ),
        ("Keccak256".into(), address_from_short_hex("8010"), false),
        ("CodeOracle".into(), address_from_short_hex("8012"), false),
        (
            "EvmGasManager".into(),
            address_from_short_hex("8013"),
            false,
        ),
        (
            "system-contracts/EvmPredeploysManager".into(),
            address_from_short_hex("8014"),
            false,
        ),
        (
            "system-contracts/EvmHashesStorage".into(),
            address_from_short_hex("8015"),
            false,
        ),
        ("P256Verify".into(), address_from_short_hex("100"), false),
        (
            "system-contracts/PubdataChunkPublisher".into(),
            address_from_short_hex("8011"),
            false,
        ),
        (
            "system-contracts/Create2Factory".into(),
            address_from_short_hex("10000"),
            false,
        ),
        (
            "system-contracts/L2GenesisUpgrade".into(),
            address_from_short_hex("10001"),
            false,
        ),
        (
            "system-contracts/SloadContract".into(),
            address_from_short_hex("10006"),
            false,
        ),
        (
            "l1-contracts/Bridgehub".into(),
            address_from_short_hex("10002"),
            false,
        ),
        (
            "l1-contracts/L2AssetRouter".into(),
            address_from_short_hex("10003"),
            false,
        ),
        (
            "l1-contracts/L2NativeTokenVault".into(),
            address_from_short_hex("10004"),
            false,
        ),
        (
            "l1-contracts/MessageRoot".into(),
            address_from_short_hex("10005"),
            false,
        ),
        (
            "l1-contracts/L2WrappedBaseToken".into(),
            address_from_short_hex("10007"),
            false,
        ),
    ]
}

pub fn verify_force_deployments(
    force_deployments: &[ForceDeployment],
    expected_deployments: &[(String, Address, bool)],
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    if force_deployments.len() != expected_deployments.len() {
        result.report_error(&format!(
            "Expected {} force deployments, got {}",
            expected_deployments.len(),
            force_deployments.len()
        ));
    }

    for (force_deployment, (contract, expected_address, expected_constructor)) in
        force_deployments.iter().zip(expected_deployments.iter())
    {
        if &force_deployment.newAddress != expected_address {
            result.report_error(&format!(
                "Expected force deployment for {} to be at {}, got {}",
                contract, expected_address, force_deployment.newAddress
            ));
            continue;
        }

        // Address is as expected, so check the bytecode and constructor.
        result.expect_zk_bytecode(verifiers, &force_deployment.bytecodeHash, &contract);

        if &force_deployment.callConstructor != expected_constructor {
            result.report_error(&format!(
                "Expected force deployment for {} to have constructor {}, got {}",
                contract, expected_constructor, force_deployment.callConstructor
            ));
        }
        if force_deployment.value != U256::ZERO {
            result.report_error(&format!(
                "Force deployment for {} should not have value",
                contract
            ));
        }
        if !force_deployment.input.is_empty() {
            result.report_error(&format!(
                "Force deployment for {} should not have input",
                contract
            ));
        }
    }

    result.report_ok("Force deployments verified");
    Ok(())
}
