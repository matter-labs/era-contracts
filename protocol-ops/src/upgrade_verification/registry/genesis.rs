//! A release's genesis data against the reviewed values it was built from.
//!
//! Every chain a CTM creates from a `CTMRelease` starts from the release's genesis data, and the
//! release's construction check only proves the reviewed constructor stored the manifest it
//! serves — not that the manifest's genesis is the reviewed one. The prepare fills it from the
//! reviewed commit (`DeployCTMUtils.deployCurrentRelease`): `genesisBatchHash` is the ZKsync OS
//! genesis config's `genesis_root`, `genesisIndexRepeatedStorageChanges` is zero, and
//! `fixedForceDeploymentsData` is the blob the prepare also writes to its output. Each is held
//! against that source here, on the paths that install a release.
//!
//! The blob is also DECODED, and every field is held against an expectation the prepare did not
//! write ([`judge_force_deployments`]): the live L1 and Bridgehub, the reviewed governance and ZK
//! token, zero where the builder writes zero, and — for the bytecode fields — the release's own
//! L2 bytecode table (`DeployCTM._buildForceDeploymentsData`).

use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::providers::Provider;
use alloy::sol_types::SolValue;

use crate::upgrade_verification::constants::{
    FORCE_DEPLOYED_L2_ECOSYSTEM_SLOTS, L1_TO_L2_ALIAS_OFFSET,
};
use crate::upgrade_verification::paths::repo_relative_path;
use crate::upgrade_verification::report::VerificationResult;

use super::views::{BridgehubView, CtmView, FixedForceDeploymentsData, ReleaseManifest};

/// The genesis config the prepare reads (`Utils.genesisConfigPath`).
pub(crate) const ZKSYNC_OS_GENESIS_CONFIG_PATH: &str = "configs/genesis/zksync-os/latest.json";

/// A ZKsync OS release's `genesisIndexRepeatedStorageChanges`: `ChainCreationParamsLib` reads no
/// rollup leaf index, so the prepare pins zero.
pub(crate) const ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES: u64 = 0;

/// The reviewed values a release's genesis data is held against.
#[derive(Clone)]
pub(crate) struct ReviewedGenesis {
    /// `genesis_root` of the reviewed genesis config, or why it could not be read.
    pub(crate) genesis_root: Result<B256, String>,
    /// The package's `[ctms.*.contracts_config] force_deployments_data`.
    pub(crate) force_deployments_data: Option<Bytes>,
    /// The independent expectations of the blob's fields.
    pub(crate) force_deployments: ExpectedForceDeployments,
}

/// What each non-bytecode field of a release's force deployments must be, from sources the
/// prepare does not control. An `Err` says why an expectation is unavailable; the field is then
/// reported as unverifiable.
#[derive(Clone, Debug)]
pub(crate) struct ExpectedForceDeployments {
    /// The L1 RPC's chain id.
    pub(crate) l1_chain_id: Result<U256, String>,
    /// The CTM's Bridgehub's `assetRouter()`.
    pub(crate) l1_asset_router: Result<Address, String>,
    /// The REVIEWED governance, unaliased.
    pub(crate) governance: Result<Address, String>,
    /// The CTM's Bridgehub's `MAX_NUMBER_OF_ZK_CHAINS()`.
    pub(crate) max_number_of_zk_chains: Result<U256, String>,
    /// The CTM's Bridgehub's `chainRegistrationSender()`, unaliased.
    pub(crate) chain_registration_sender: Result<Address, String>,
    /// The reviewed env's permanent-values `zk_token_asset_id`.
    pub(crate) zk_token_asset_id: B256,
}

impl ExpectedForceDeployments {
    /// Before the live reads ([`Self::read_live`]): only the reviewed ZK token is known.
    pub(crate) fn unread(zk_token_asset_id: B256) -> Self {
        fn unread<T>() -> Result<T, String> {
            Err("not read".to_string())
        }
        Self {
            l1_chain_id: unread(),
            l1_asset_router: unread(),
            governance: unread(),
            max_number_of_zk_chains: unread(),
            chain_registration_sender: unread(),
            zk_token_asset_id,
        }
    }

    /// Reads the live expectations: the L1 chain id and, through `ctm`'s Bridgehub, the asset
    /// router, the chain cap and the chain registration sender. `governance` is the reviewed
    /// governance (`None` names `governance_source` as what is missing).
    ///
    /// Reads, in order: `eth_chainId`, the CTM's `BRIDGE_HUB()`, the Bridgehub's `assetRouter()`,
    /// `MAX_NUMBER_OF_ZK_CHAINS()` and `chainRegistrationSender()`.
    pub(crate) async fn read_live<P: Provider>(
        &mut self,
        provider: &P,
        ctm: Option<Address>,
        governance: Option<Address>,
        governance_source: &str,
    ) {
        self.l1_chain_id = provider
            .get_chain_id()
            .await
            .map(U256::from)
            .map_err(|e| format!("the L1 chain id could not be read ({e})"));
        self.governance = governance
            .ok_or_else(|| format!("no reviewed governance: {governance_source} is required"));
        let bridgehub = match ctm {
            None => Err(
                "the package names no CTM (`chain_type_manager_proxy`), so its \
                         Bridgehub cannot be read"
                    .to_string(),
            ),
            Some(ctm) => CtmView::new(ctm, provider)
                .BRIDGE_HUB()
                .call()
                .await
                .map_err(|e| format!("the CTM's BRIDGE_HUB() could not be read ({e})")),
        };
        let bridgehub = match bridgehub {
            Ok(bridgehub) => BridgehubView::new(bridgehub, provider),
            Err(why) => {
                self.l1_asset_router = Err(why.clone());
                self.max_number_of_zk_chains = Err(why.clone());
                self.chain_registration_sender = Err(why);
                return;
            }
        };
        self.l1_asset_router = bridgehub
            .assetRouter()
            .call()
            .await
            .map_err(|e| format!("the Bridgehub's assetRouter() could not be read ({e})"));
        self.max_number_of_zk_chains =
            bridgehub
                .MAX_NUMBER_OF_ZK_CHAINS()
                .call()
                .await
                .map_err(|e| {
                    format!("the Bridgehub's MAX_NUMBER_OF_ZK_CHAINS() could not be read ({e})")
                });
        self.chain_registration_sender =
            bridgehub
                .chainRegistrationSender()
                .call()
                .await
                .map_err(|e| {
                    format!("the Bridgehub's chainRegistrationSender() could not be read ({e})")
                });
    }
}

/// `AddressAliasHelper.applyL1ToL2Alias`.
pub(crate) fn apply_l1_to_l2_alias(address: Address) -> Address {
    let sum = U256::from_be_slice(address.as_slice())
        + U256::from_be_slice(L1_TO_L2_ALIAS_OFFSET.as_slice());
    // The low 160 bits: the helper's `unchecked` addition wraps.
    Address::from_word(B256::from(sum))
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

/// Holds the genesis data of `release` — the release `label` names — against `reviewed`. Each
/// disagreement is an ERROR: chains created from the release would start from a genesis the
/// review does not describe.
pub(crate) fn judge_release_genesis(
    result: &mut VerificationResult,
    label: &str,
    release: &ReleaseManifest,
    reviewed: &ReviewedGenesis,
) {
    let genesis = &release.genesis;
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

    judge_force_deployments(result, label, release, &reviewed.force_deployments);
}

/// Decodes the release's `fixedForceDeploymentsData` and holds every field against `expected`
/// (the non-bytecode fields) or the release's own L2 bytecode table (the bytecode fields), one
/// line per field.
pub(crate) fn judge_force_deployments(
    result: &mut VerificationResult,
    label: &str,
    release: &ReleaseManifest,
    expected: &ExpectedForceDeployments,
) {
    let data =
        match FixedForceDeploymentsData::abi_decode(&release.genesis.fixedForceDeploymentsData) {
            Ok(data) => data,
            Err(e) => {
                result.report_error(&format!(
                "{label}: fixedForceDeploymentsData does not decode as FixedForceDeploymentsData \
                 ({e}): new chains' genesis upgrade would revert on it"
            ));
                return;
            }
        };
    let prefix = format!("{label}: force deployments");
    expect_field(
        result,
        &prefix,
        "l1ChainId",
        data.l1ChainId,
        &expected.l1_chain_id,
        "the L1 RPC's chain id",
    );
    expect_field(
        result,
        &prefix,
        "l1AssetRouter",
        data.l1AssetRouter,
        &expected.l1_asset_router,
        "the Bridgehub's assetRouter()",
    );
    expect_field(
        result,
        &prefix,
        "aliasedL1Governance",
        data.aliasedL1Governance,
        &expected.governance.clone().map(apply_l1_to_l2_alias),
        "the L1->L2 alias of the reviewed governance",
    );
    expect_field(
        result,
        &prefix,
        "maxNumberOfZKChains",
        data.maxNumberOfZKChains,
        &expected.max_number_of_zk_chains,
        "the Bridgehub's MAX_NUMBER_OF_ZK_CHAINS()",
    );
    expect_field(
        result,
        &prefix,
        "aliasedChainRegistrationSender",
        data.aliasedChainRegistrationSender,
        &expected
            .chain_registration_sender
            .clone()
            .map(apply_l1_to_l2_alias),
        "the L1->L2 alias of the Bridgehub's chainRegistrationSender()",
    );
    expect_field(
        result,
        &prefix,
        "zkTokenAssetId",
        data.zkTokenAssetId,
        &Ok(expected.zk_token_asset_id),
        "the env's permanent-values `zk_token_asset_id`",
    );
    for (name, value) in [
        ("l2SharedBridgeLegacyImpl", data.l2SharedBridgeLegacyImpl),
        (
            "l2BridgedStandardERC20Impl",
            data.l2BridgedStandardERC20Impl,
        ),
        (
            "dangerousTestOnlyForcedBeacon",
            data.dangerousTestOnlyForcedBeacon,
        ),
    ] {
        expect_field(
            result,
            &prefix,
            name,
            value,
            &Ok(Address::ZERO),
            "zero, which the builder always writes",
        );
    }

    // Each bytecode field repeats its member's table row, wrapped with the system-proxy shell —
    // or is empty for an empty row (the rule `CTMRelease`'s constructor enforces).
    let shell = &release.l2SystemProxyBytecodeInfo;
    for (name, member, value) in [
        (
            "bridgehubBytecodeInfo",
            "L2Bridgehub",
            &data.bridgehubBytecodeInfo,
        ),
        (
            "l2AssetRouterBytecodeInfo",
            "L2AssetRouter",
            &data.l2AssetRouterBytecodeInfo,
        ),
        (
            "l2NtvBytecodeInfo",
            "L2NativeTokenVault",
            &data.l2NtvBytecodeInfo,
        ),
        (
            "messageRootBytecodeInfo",
            "L2MessageRoot",
            &data.messageRootBytecodeInfo,
        ),
        (
            "baseTokenHolderBytecodeInfo",
            "BaseTokenHolder",
            &data.baseTokenHolderBytecodeInfo,
        ),
        (
            "chainAssetHandlerBytecodeInfo",
            "L2ChainAssetHandler",
            &data.chainAssetHandlerBytecodeInfo,
        ),
        (
            "interopCenterBytecodeInfo",
            "InteropCenter",
            &data.interopCenterBytecodeInfo,
        ),
        (
            "interopHandlerBytecodeInfo",
            "L2InteropHandler",
            &data.interopHandlerBytecodeInfo,
        ),
        (
            "assetTrackerBytecodeInfo",
            "L2AssetTracker",
            &data.assetTrackerBytecodeInfo,
        ),
    ] {
        let row = FORCE_DEPLOYED_L2_ECOSYSTEM_SLOTS
            .iter()
            .find(|(m, _)| *m == member)
            .and_then(|(_, slot)| release.l2BytecodeInfos.get(*slot));
        let Some(row) = row else {
            result.report_error(&format!(
                "{prefix}: {name} cannot be held against the release's table, which has no \
                 {member} slot"
            ));
            continue;
        };
        let expected = table_descriptor(row, shell);
        if value[..] == expected[..] {
            result.report_ok(&format!(
                "{prefix}: {name} is the release's {member} row ({} bytes)",
                value.len()
            ));
        } else {
            result.report_error(&format!(
                "{prefix}: {name} ({} bytes, keccak256 {}) is not the release's {member} row \
                 wrapped with its system-proxy shell ({} bytes, keccak256 {}): new chains would \
                 be told of an implementation the release does not pin",
                value.len(),
                keccak256(value),
                expected.len(),
                keccak256(&expected)
            ));
        }
    }
    // `UpgradeableBeaconDeployer` is not force-deployed, so the release's table has no row the
    // descriptor could repeat; ZKsync OS genesis reads no bytecode-info field.
    result.print_info(&format!(
        "  {prefix}: beaconDeployerInfo ({} bytes, keccak256 {}) has no release-table row to be \
         held against",
        data.beaconDeployerInfo.len(),
        keccak256(&data.beaconDeployerInfo)
    ));
}

/// `DeployCTM._tableDescriptor`: `abi.encode(row, shell)`, or empty for an empty row.
fn table_descriptor(row: &Bytes, shell: &Bytes) -> Vec<u8> {
    if row.is_empty() {
        Vec::new()
    } else {
        (row.clone(), shell.clone()).abi_encode_params()
    }
}

/// One force-deployments field against its independent expectation.
fn expect_field<T: PartialEq + std::fmt::Display>(
    result: &mut VerificationResult,
    prefix: &str,
    name: &str,
    actual: T,
    expected: &Result<T, String>,
    source: &str,
) {
    match expected {
        Ok(expected) if *expected == actual => {
            result.report_ok(&format!("{prefix}: {name} {actual} is {source}"))
        }
        Ok(expected) => result.report_error(&format!(
            "{prefix}: {name} is {actual} but {source} is {expected}: new chains' genesis would \
             start from a value the review does not describe"
        )),
        Err(why) => result.report_error(&format!(
            "{prefix}: {name} {actual} cannot be held against {source} — {why}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::registry::views::ReleaseGenesisData;

    const ROOT: B256 = B256::repeat_byte(0x47);
    const L1_CHAIN_ID: u64 = 11_155_111;
    const ASSET_ROUTER: Address = Address::repeat_byte(0xA5);
    const GOVERNANCE: Address = Address::repeat_byte(0x60);
    const MAX_CHAINS: u64 = 100;
    const REGISTRATION_SENDER: Address = Address::repeat_byte(0xC5);
    const ZK_TOKEN: B256 = B256::repeat_byte(0x2C);
    /// One slot past the last force-deployed member, so every member has a row.
    const TABLE_LEN: usize = 11;

    fn shell() -> Bytes {
        Bytes::from_static(b"the system-proxy shell")
    }

    /// A table whose force-deployed rows are distinct, with the BaseTokenHolder row empty.
    fn table() -> Vec<Bytes> {
        (0..TABLE_LEN)
            .map(|slot| {
                if slot == 5 {
                    Bytes::new()
                } else {
                    Bytes::from(format!("row {slot}").into_bytes())
                }
            })
            .collect()
    }

    /// The blob `DeployCTM._buildForceDeploymentsData` builds for `table` and the expected values.
    fn force_deployments_for(table: &[Bytes]) -> FixedForceDeploymentsData {
        let row = |slot: usize| Bytes::from(table_descriptor(&table[slot], &shell()));
        FixedForceDeploymentsData {
            l1ChainId: U256::from(L1_CHAIN_ID),
            l1AssetRouter: ASSET_ROUTER,
            aliasedL1Governance: apply_l1_to_l2_alias(GOVERNANCE),
            maxNumberOfZKChains: U256::from(MAX_CHAINS),
            bridgehubBytecodeInfo: row(0),
            l2AssetRouterBytecodeInfo: row(1),
            l2NtvBytecodeInfo: row(2),
            messageRootBytecodeInfo: row(3),
            chainAssetHandlerBytecodeInfo: row(6),
            interopCenterBytecodeInfo: row(7),
            interopHandlerBytecodeInfo: row(9),
            assetTrackerBytecodeInfo: row(10),
            beaconDeployerInfo: Bytes::from_static(b"the beacon deployer"),
            baseTokenHolderBytecodeInfo: row(5),
            l2SharedBridgeLegacyImpl: Address::ZERO,
            l2BridgedStandardERC20Impl: Address::ZERO,
            aliasedChainRegistrationSender: apply_l1_to_l2_alias(REGISTRATION_SENDER),
            dangerousTestOnlyForcedBeacon: Address::ZERO,
            zkTokenAssetId: ZK_TOKEN,
        }
    }

    fn force_deployments() -> Bytes {
        Bytes::from(force_deployments_for(&table()).abi_encode())
    }

    fn release_with(fixed_force_deployments: Bytes) -> ReleaseManifest {
        ReleaseManifest {
            protocolVersion: U256::from(0x24_0000_0000u64),
            diamondInit: Address::repeat_byte(0x01),
            verifier: Address::repeat_byte(0x02),
            genesisUpgrade: Address::repeat_byte(0x03),
            genesisFacets: Vec::new(),
            genesis: ReleaseGenesisData {
                fixedForceDeploymentsData: fixed_force_deployments,
                genesisBatchHash: ROOT,
                genesisIndexRepeatedStorageChanges:
                    ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES,
            },
            l2BytecodeInfos: table(),
            l2SystemProxyBytecodeInfo: shell(),
        }
    }

    fn release() -> ReleaseManifest {
        release_with(force_deployments())
    }

    fn expected() -> ExpectedForceDeployments {
        ExpectedForceDeployments {
            l1_chain_id: Ok(U256::from(L1_CHAIN_ID)),
            l1_asset_router: Ok(ASSET_ROUTER),
            governance: Ok(GOVERNANCE),
            max_number_of_zk_chains: Ok(U256::from(MAX_CHAINS)),
            chain_registration_sender: Ok(REGISTRATION_SENDER),
            zk_token_asset_id: ZK_TOKEN,
        }
    }

    fn reviewed() -> ReviewedGenesis {
        ReviewedGenesis {
            genesis_root: Ok(ROOT),
            force_deployments_data: Some(force_deployments()),
            force_deployments: expected(),
        }
    }

    fn judge(release: &ReleaseManifest, reviewed: &ReviewedGenesis) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_release_genesis(&mut result, "the release", release, reviewed);
        result
    }

    #[test]
    fn a_release_built_from_the_reviewed_genesis_passes() {
        let result = judge(&release(), &reviewed());
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    #[test]
    fn another_genesis_batch_hash_fails() {
        let mut release = release();
        release.genesis.genesisBatchHash = B256::repeat_byte(0x48);
        assert_eq!(judge(&release, &reviewed()).errors, 1);
    }

    #[test]
    fn another_genesis_index_fails() {
        let mut release = release();
        release.genesis.genesisIndexRepeatedStorageChanges =
            ZKSYNC_OS_GENESIS_INDEX_REPEATED_STORAGE_CHANGES + 1;
        assert_eq!(judge(&release, &reviewed()).errors, 1);
    }

    /// Another blob than the package's — here one that does not even decode.
    #[test]
    fn other_force_deployments_fail() {
        let release = release_with(Bytes::from_static(b"substituted force deployments"));
        assert_eq!(
            judge(&release, &reviewed()).errors,
            2,
            "the package's blob disagrees, and the release's does not decode"
        );
    }

    /// Nothing to hold a field against is an error, not a skipped check.
    #[test]
    fn a_missing_reviewed_value_fails() {
        let unreadable_config = ReviewedGenesis {
            genesis_root: Err("cannot read the config".to_string()),
            ..reviewed()
        };
        assert_eq!(judge(&release(), &unreadable_config).errors, 1);

        let no_force_deployments = ReviewedGenesis {
            force_deployments_data: None,
            ..reviewed()
        };
        assert_eq!(judge(&release(), &no_force_deployments).errors, 1);

        // Every independent expectation, missing on its own.
        fn missing<T>() -> Result<T, String> {
            Err("unavailable".to_string())
        }
        let mut expectations: Vec<ExpectedForceDeployments> = Vec::new();
        expectations.push(ExpectedForceDeployments {
            l1_chain_id: missing(),
            ..expected()
        });
        expectations.push(ExpectedForceDeployments {
            l1_asset_router: missing(),
            ..expected()
        });
        expectations.push(ExpectedForceDeployments {
            governance: missing(),
            ..expected()
        });
        expectations.push(ExpectedForceDeployments {
            max_number_of_zk_chains: missing(),
            ..expected()
        });
        expectations.push(ExpectedForceDeployments {
            chain_registration_sender: missing(),
            ..expected()
        });
        for expected in expectations {
            let reviewed = ReviewedGenesis {
                force_deployments: expected.clone(),
                ..reviewed()
            };
            assert_eq!(judge(&release(), &reviewed).errors, 1, "{expected:?}");
        }
    }

    // ───────────────────────── the decoded force deployments ─────────────────────────

    /// Judges a release whose blob is `data` (the package's own copy agreeing with it), so only
    /// the decoded fields can disagree.
    fn judge_fields(data: FixedForceDeploymentsData) -> VerificationResult {
        let blob = Bytes::from(data.abi_encode());
        let reviewed = ReviewedGenesis {
            force_deployments_data: Some(blob.clone()),
            ..reviewed()
        };
        judge(&release_with(blob), &reviewed)
    }

    /// One field of a correct blob made wrong.
    type Mutation = Box<dyn Fn(&mut FixedForceDeploymentsData)>;

    /// Each non-bytecode field, wrong on its own, is one error.
    #[test]
    fn each_non_bytecode_field_mismatch_fails() {
        let wrong = Address::repeat_byte(0xBA);
        let mutations: Vec<(&str, Mutation)> = vec![
            ("l1ChainId", Box::new(|d| d.l1ChainId = U256::from(1))),
            ("l1AssetRouter", Box::new(move |d| d.l1AssetRouter = wrong)),
            (
                "aliasedL1Governance (unaliased)",
                Box::new(|d| d.aliasedL1Governance = GOVERNANCE),
            ),
            (
                "aliasedL1Governance (another governance)",
                Box::new(move |d| d.aliasedL1Governance = apply_l1_to_l2_alias(wrong)),
            ),
            (
                "maxNumberOfZKChains",
                Box::new(|d| d.maxNumberOfZKChains = U256::from(MAX_CHAINS + 1)),
            ),
            (
                "aliasedChainRegistrationSender",
                Box::new(|d| d.aliasedChainRegistrationSender = REGISTRATION_SENDER),
            ),
            (
                "zkTokenAssetId",
                Box::new(|d| d.zkTokenAssetId = B256::repeat_byte(0x2D)),
            ),
            (
                "l2SharedBridgeLegacyImpl",
                Box::new(move |d| d.l2SharedBridgeLegacyImpl = wrong),
            ),
            (
                "l2BridgedStandardERC20Impl",
                Box::new(move |d| d.l2BridgedStandardERC20Impl = wrong),
            ),
            (
                "dangerousTestOnlyForcedBeacon",
                Box::new(move |d| d.dangerousTestOnlyForcedBeacon = wrong),
            ),
        ];
        for (field, mutate) in mutations {
            let mut data = force_deployments_for(&table());
            mutate(&mut data);
            assert_eq!(judge_fields(data).errors, 1, "{field}");
        }
    }

    /// Each bytecode field must repeat its member's row in the shell, or be empty for an empty
    /// row; the beacon deployer, which has no row, is reported but not compared.
    #[test]
    fn each_bytecode_field_mismatch_fails() {
        let other = || Bytes::from_static(b"an implementation the release does not pin");
        let mutations: Vec<(&str, Mutation)> = vec![
            (
                "bridgehub",
                Box::new(move |d| d.bridgehubBytecodeInfo = other()),
            ),
            (
                "asset router",
                Box::new(move |d| d.l2AssetRouterBytecodeInfo = other()),
            ),
            ("ntv", Box::new(move |d| d.l2NtvBytecodeInfo = other())),
            (
                "message root",
                Box::new(move |d| d.messageRootBytecodeInfo = other()),
            ),
            (
                "chain asset handler",
                Box::new(move |d| d.chainAssetHandlerBytecodeInfo = other()),
            ),
            (
                "interop center",
                Box::new(move |d| d.interopCenterBytecodeInfo = other()),
            ),
            (
                "interop handler",
                Box::new(move |d| d.interopHandlerBytecodeInfo = other()),
            ),
            (
                "asset tracker",
                Box::new(move |d| d.assetTrackerBytecodeInfo = other()),
            ),
            (
                "base token holder (an empty row)",
                Box::new(move |d| d.baseTokenHolderBytecodeInfo = other()),
            ),
            (
                "bridgehub (the bare row, no shell)",
                Box::new(|d| d.bridgehubBytecodeInfo = Bytes::from_static(b"row 0")),
            ),
        ];
        for (field, mutate) in mutations {
            let mut data = force_deployments_for(&table());
            mutate(&mut data);
            assert_eq!(judge_fields(data).errors, 1, "{field}");
        }

        let mut data = force_deployments_for(&table());
        data.beaconDeployerInfo = other();
        assert_eq!(judge_fields(data).errors, 0);
    }

    /// `abi.encode(row, shell)` of two `bytes` is the PARAMETER encoding: two offsets, then the
    /// tails — no outer offset word.
    #[test]
    fn the_table_descriptor_is_solidity_abi_encode_of_two_bytes() {
        let encoded = table_descriptor(&Bytes::from_static(b"a"), &Bytes::from_static(b"b"));
        assert_eq!(encoded.len(), 6 * 32);
        assert_eq!(U256::from_be_slice(&encoded[..32]), U256::from(0x40));
        assert_eq!(U256::from_be_slice(&encoded[32..64]), U256::from(0x80));
        assert!(table_descriptor(&Bytes::new(), &shell()).is_empty());
    }

    /// The helper's addition wraps modulo 2^160.
    #[test]
    fn the_alias_is_the_helpers_wrapping_addition() {
        assert_eq!(apply_l1_to_l2_alias(Address::ZERO), L1_TO_L2_ALIAS_OFFSET);
        assert_eq!(
            apply_l1_to_l2_alias(Address::repeat_byte(0x01)),
            "0x1212010101010101010101010101010101011212"
                .parse::<Address>()
                .unwrap()
        );
        assert_eq!(
            apply_l1_to_l2_alias(Address::repeat_byte(0xFF)),
            "0x1111000000000000000000000000000000001110"
                .parse::<Address>()
                .unwrap()
        );
    }

    /// The live reads, in the order they query: the chain id, the CTM's Bridgehub and its three
    /// getters. Without a CTM nothing past the chain id is read, and each Bridgehub field says
    /// why it is unavailable.
    #[tokio::test]
    async fn the_live_expectations_are_read_through_the_ctms_bridgehub() {
        use alloy::providers::ProviderBuilder;
        use alloy::transports::mock::Asserter;
        const CTM: Address = Address::repeat_byte(0xC7);
        const BRIDGEHUB: Address = Address::repeat_byte(0xB0);

        let asserter = Asserter::new();
        asserter.push_success(&alloy::primitives::U64::from(L1_CHAIN_ID));
        asserter.push_success(&Bytes::from(BRIDGEHUB.abi_encode()));
        asserter.push_success(&Bytes::from(ASSET_ROUTER.abi_encode()));
        asserter.push_success(&Bytes::from(U256::from(MAX_CHAINS).abi_encode()));
        asserter.push_success(&Bytes::from(REGISTRATION_SENDER.abi_encode()));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut live = ExpectedForceDeployments::unread(ZK_TOKEN);
        live.read_live(
            &provider,
            Some(CTM),
            Some(GOVERNANCE),
            "the test's governance",
        )
        .await;
        assert!(asserter.read_q().is_empty());
        let reviewed = ReviewedGenesis {
            force_deployments: live,
            ..reviewed()
        };
        assert_eq!(judge(&release(), &reviewed).errors, 0);

        let asserter = Asserter::new();
        asserter.push_success(&alloy::primitives::U64::from(L1_CHAIN_ID));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut live = ExpectedForceDeployments::unread(ZK_TOKEN);
        live.read_live(&provider, None, None, "--expected-governance-owner")
            .await;
        assert!(asserter.read_q().is_empty());
        for missing in [
            live.l1_asset_router.as_ref().err(),
            live.max_number_of_zk_chains.as_ref().err(),
            live.chain_registration_sender.as_ref().err(),
        ] {
            assert!(missing.unwrap().contains("names no CTM"));
        }
        assert!(live
            .governance
            .unwrap_err()
            .contains("--expected-governance-owner"));
        assert_eq!(
            live.zk_token_asset_id, ZK_TOKEN,
            "the live reads leave the reviewed ZK token alone"
        );
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
