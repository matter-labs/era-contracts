use zksync_os_genesis_gen::InitialGenesisInput;

/// All contract names that `InitialGenesisInput::from_forge_artifacts` must load from disk.
/// Matches `INITIAL_CONTRACTS` in consts.rs (L1ContractName entries) plus the proxy skeleton.
const REQUIRED_ARTIFACTS: &[&str] = &[
    "SystemContractProxy", // proxy skeleton — not in INITIAL_CONTRACTS but always needed
    "L2ComplexUpgrader",
    "L2GenesisUpgrade",
    "L2WrappedBaseToken",
    "SystemContractProxyAdmin",
    "L2MessageRoot",
    "L2Bridgehub",
    "L2AssetRouter",
    "L2NativeTokenVaultZKOS",
    "UpgradeableBeaconDeployer",
    "L2ChainAssetHandler",
    "L2AssetTracker",
    "GWAssetTracker",
    "InteropCenter",
    "InteropHandler",
    "BaseTokenHolder",
    "ZKOSContractDeployer",
    "L1MessengerZKOS",
    "L2BaseTokenZKOS",
    "SystemContext",
    "L2InteropRootStorage",
    "L2MessageVerification",
];

fn write_fake_artifact(dir: &std::path::Path, name: &str) {
    let contract_dir = dir.join(format!("{name}.sol"));
    std::fs::create_dir_all(&contract_dir).unwrap();
    let artifact = serde_json::json!({
        "deployedBytecode": { "object": format!("0x{:0>64}", "deadbeef") }
    });
    std::fs::write(
        contract_dir.join(format!("{name}.json")),
        serde_json::to_string(&artifact).unwrap(),
    )
    .unwrap();
}

#[test]
fn errors_when_contract_file_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let result = InitialGenesisInput::from_forge_artifacts(tmp.path());
    assert!(
        result.is_err(),
        "expected error on empty directory, got Ok"
    );
    let msg = result.unwrap_err().to_string();
    assert!(
        msg.contains("SystemContractProxy"),
        "error should mention the missing contract, got: {msg}"
    );
}

#[test]
fn loads_all_contracts_and_populates_storage() {
    let tmp = tempfile::tempdir().unwrap();
    for name in REQUIRED_ARTIFACTS {
        write_fake_artifact(tmp.path(), name);
    }

    let input = InitialGenesisInput::from_forge_artifacts(tmp.path()).unwrap();

    // 18 SystemProxy entries → 18 proxy + 18 impl addresses
    // 3 Direct entries → 3 addresses
    // 1 Bytecode entry (Create2 factory) → 1 address (no disk load)
    // Total: 40 entries
    assert_eq!(
        input.initial_contracts.len(),
        40,
        "unexpected number of deployed contracts"
    );

    // SYSTEM_CONTRACT_PROXY_ADMIN storage + one entry per SystemProxy contract (18)
    assert!(
        !input.additional_storage.is_empty(),
        "additional_storage should be populated by proxy EIP-1967 slots"
    );

    // additional_storage_raw is empty by default
    assert!(input.additional_storage_raw.is_empty());
}

#[test]
fn build_genesis_root_hash_is_deterministic() {
    let tmp = tempfile::tempdir().unwrap();
    for name in REQUIRED_ARTIFACTS {
        write_fake_artifact(tmp.path(), name);
    }

    let input = InitialGenesisInput::from_forge_artifacts(tmp.path()).unwrap();
    let root1 = zksync_os_genesis_gen::build_genesis_root_hash(&input).unwrap();
    let root2 = zksync_os_genesis_gen::build_genesis_root_hash(&input).unwrap();
    assert_eq!(root1, root2, "genesis root hash must be deterministic");
}
