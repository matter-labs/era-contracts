//! A release's genesis data against the reviewed values it was built from.
//!
//! Every chain a CTM creates from a `CTMRelease` starts from the release's genesis data, and the
//! release's construction check only proves the reviewed constructor stored the manifest it
//! serves — not that the manifest's genesis is the reviewed one. The prepare fills it from the
//! reviewed commit (`DeployCTMUtils.deployCurrentRelease`): `genesisBatchHash` is the ZKsync OS
//! genesis config's `genesis_root`, `genesisIndexRepeatedStorageChanges` is zero, and
//! `fixedForceDeploymentsData` is the blob the prepare also writes to its output. Each is held
//! against that source here, on both verification paths.

use alloy::primitives::{keccak256, Bytes, B256};

use crate::upgrade_verification::paths::repo_relative_path;
use crate::upgrade_verification::report::VerificationResult;

use super::views::ReleaseGenesisData;

/// The genesis config the prepare reads (`Utils.genesisConfigPath`).
pub(crate) const ZKSYNC_OS_GENESIS_CONFIG_PATH: &str = "configs/genesis/zksync-os/latest.json";

/// A ZKsync OS release's `genesisIndexRepeatedStorageChanges`: `ChainCreationParamsLib` reads no
/// rollup leaf index, so the prepare pins zero.
pub(crate) const ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES: u64 = 0;

/// The reviewed values a release's genesis data is held against.
pub(crate) struct ReviewedGenesis {
    /// `genesis_root` of the reviewed genesis config, or why it could not be read.
    pub(crate) genesis_root: Result<B256, String>,
    /// The package's `[ctms.*.contracts_config] force_deployments_data`.
    pub(crate) force_deployments_data: Option<Bytes>,
}

/// Reads `genesis_root` from the reviewed commit's genesis config. A failure is carried rather
/// than raised, so the rest of the report still runs and the release check reports it.
pub(crate) fn reviewed_genesis_root() -> Result<B256, String> {
    let path = repo_relative_path(ZKSYNC_OS_GENESIS_CONFIG_PATH);
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| format!("cannot read {} ({e})", path.display()))?;
    parse_genesis_root(&raw).map_err(|e| format!("{}: {e}", path.display()))
}

fn parse_genesis_root(raw: &str) -> Result<B256, String> {
    let json: serde_json::Value =
        serde_json::from_str(raw).map_err(|e| format!("not valid JSON ({e})"))?;
    let root = json
        .get("genesis_root")
        .and_then(|v| v.as_str())
        .ok_or("no `genesis_root` string")?;
    root.parse()
        .map_err(|e| format!("unparsable `genesis_root` {root} ({e})"))
}

/// Holds `genesis` — the genesis data of the release `label` names — against `reviewed`. Each
/// disagreement is an ERROR: chains created from the release would start from a genesis the
/// review does not describe.
pub(crate) fn judge_release_genesis(
    result: &mut VerificationResult,
    label: &str,
    genesis: &ReleaseGenesisData,
    reviewed: &ReviewedGenesis,
) {
    let batch_hash = genesis.genesisBatchHash;
    match &reviewed.genesis_root {
        Ok(root) if *root == batch_hash => result.report_ok(&format!(
            "{label}: genesisBatchHash {batch_hash} is the genesis_root of \
             {ZKSYNC_OS_GENESIS_CONFIG_PATH}"
        )),
        Ok(root) => result.report_error(&format!(
            "{label}: genesisBatchHash is {batch_hash} but {ZKSYNC_OS_GENESIS_CONFIG_PATH} has \
             genesis_root {root}: chains created from this release would start from a genesis \
             state the review does not describe"
        )),
        Err(why) => result.report_error(&format!(
            "{label}: genesisBatchHash {batch_hash} cannot be held against the reviewed genesis \
             config — {why}"
        )),
    }

    let index = genesis.genesisIndexRepeatedStorageChanges;
    if index == ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES {
        result.report_ok(&format!(
            "{label}: genesisIndexRepeatedStorageChanges is {index}, as a ZKsync OS release pins it"
        ));
    } else {
        result.report_error(&format!(
            "{label}: genesisIndexRepeatedStorageChanges is {index} but a ZKsync OS release pins \
             {ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES}: the prepare did not build this \
             genesis"
        ));
    }

    let served = keccak256(&genesis.fixedForceDeploymentsData);
    match &reviewed.force_deployments_data {
        Some(reported) if keccak256(reported) == served => result.report_ok(&format!(
            "{label}: fixedForceDeploymentsData ({} bytes, keccak256 {served}) is the package's \
             force_deployments_data",
            genesis.fixedForceDeploymentsData.len()
        )),
        Some(reported) => result.report_error(&format!(
            "{label}: fixedForceDeploymentsData hashes to {served} but the package's \
             force_deployments_data hashes to {}: new chains would receive force deployments the \
             review did not read",
            keccak256(reported)
        )),
        None => result.report_error(&format!(
            "{label}: fixedForceDeploymentsData (keccak256 {served}) cannot be held against \
             anything: the package records no [ctms.*.contracts_config] force_deployments_data"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: B256 = B256::repeat_byte(0x47);

    fn force_deployments() -> Bytes {
        Bytes::from_static(b"the reviewed fixed force deployments")
    }

    fn release_genesis() -> ReleaseGenesisData {
        ReleaseGenesisData {
            fixedForceDeploymentsData: force_deployments(),
            genesisBatchHash: ROOT,
            genesisIndexRepeatedStorageChanges: ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES,
        }
    }

    fn reviewed() -> ReviewedGenesis {
        ReviewedGenesis {
            genesis_root: Ok(ROOT),
            force_deployments_data: Some(force_deployments()),
        }
    }

    fn judge(genesis: &ReleaseGenesisData, reviewed: &ReviewedGenesis) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_release_genesis(&mut result, "the release", genesis, reviewed);
        result
    }

    #[test]
    fn a_release_built_from_the_reviewed_genesis_passes() {
        let result = judge(&release_genesis(), &reviewed());
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    #[test]
    fn another_genesis_batch_hash_fails() {
        let mut genesis = release_genesis();
        genesis.genesisBatchHash = B256::repeat_byte(0x48);
        assert_eq!(judge(&genesis, &reviewed()).errors, 1);
    }

    #[test]
    fn another_genesis_index_fails() {
        let mut genesis = release_genesis();
        genesis.genesisIndexRepeatedStorageChanges =
            ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES + 1;
        assert_eq!(judge(&genesis, &reviewed()).errors, 1);
    }

    #[test]
    fn other_force_deployments_fail() {
        let mut genesis = release_genesis();
        genesis.fixedForceDeploymentsData = Bytes::from_static(b"substituted force deployments");
        assert_eq!(judge(&genesis, &reviewed()).errors, 1);
    }

    /// Nothing to hold a field against is an error, not a skipped check.
    #[test]
    fn a_missing_reviewed_value_fails() {
        let unreadable_config = ReviewedGenesis {
            genesis_root: Err("cannot read the config".to_string()),
            ..reviewed()
        };
        assert_eq!(judge(&release_genesis(), &unreadable_config).errors, 1);

        let no_force_deployments = ReviewedGenesis {
            force_deployments_data: None,
            ..reviewed()
        };
        assert_eq!(judge(&release_genesis(), &no_force_deployments).errors, 1);
    }

    #[test]
    fn the_committed_genesis_config_has_a_genesis_root() {
        let root = reviewed_genesis_root().expect("the committed genesis config must parse");
        assert_ne!(root, B256::ZERO);
    }

    #[test]
    fn a_genesis_config_without_a_root_is_refused() {
        assert!(parse_genesis_root(r#"{"genesis_root": "0x12"}"#).is_err());
        assert!(parse_genesis_root(r#"{"execution_version": 5}"#).is_err());
        assert_eq!(
            parse_genesis_root(&format!(r#"{{"genesis_root": "{ROOT}"}}"#)),
            Ok(ROOT)
        );
    }

    /// The prepare's genesis inputs are read here from its source: `genesis_root` comes from the
    /// config this module reads, and no rollup leaf index is read at all, so the pinned index is
    /// the zero [`ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES`] says.
    #[test]
    fn the_reviewed_values_are_the_prepares_sources() {
        const CHAIN_CREATION_PARAMS_LIB: &str =
            include_str!("../../../../l1-contracts/deploy-scripts/ctm/ChainCreationParamsLib.sol");
        const UTILS: &str = include_str!("../../../../l1-contracts/deploy-scripts/utils/Utils.sol");
        assert!(CHAIN_CREATION_PARAMS_LIB
            .contains(r#"chainCreationParams.genesisRoot = json.readBytes32("$.genesis_root");"#));
        assert!(
            !CHAIN_CREATION_PARAMS_LIB.contains("genesisRollupLeafIndex"),
            "the prepare now reads a rollup leaf index; read the same key here"
        );
        assert!(UTILS.contains(r#""/../configs/genesis/", GENESIS_FILENAME_ZKOS"#));
        assert!(UTILS.contains(r#"GENESIS_FILENAME_ZKOS = "zksync-os/latest.json""#));
        assert_eq!(
            ZKSYNC_OS_GENESIS_CONFIG_PATH,
            "configs/genesis/zksync-os/latest.json"
        );
    }
}
