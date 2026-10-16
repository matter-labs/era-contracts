//! Do the MEMBERS a reviewed object names run the reviewed build's code?
//!
//! An object's construction ([`super::construction`]) proves its whole state, the ADDRESSES of
//! the contracts it names included. What those addresses RUN is a separate question, answered
//! here for every member kind a registry object names:
//!
//! | object | member | must be |
//! | --- | --- | --- |
//! | release | each genesis facet | one of [`FACETS`] |
//! | release | `diamondInit` | [`DIAMOND_INIT`] |
//! | release | `genesisUpgrade` | [`GENESIS_UPGRADE`] |
//! | release | `verifier` | one of [`VERIFIERS`], and each sub-verifier it names ([`sub_verifiers`]) — or the verifier already in force where the upgrade departs from ([`DepartingVerifiers`]) |
//! | release | each L2 bytecode table row | the bytecode info of the contract its slot names |
//! | release | `l2SystemProxyBytecodeInfo` | the bytecode info of [`SYSTEM_PROXY_SHELL`] |
//! | transition | `upgradeEngine` | [`TRANSITION_ENGINES`] |
//! | bootstrap migration | `upgradeEngine` | [`BOOTSTRAP_ENGINES`] |
//! | transition, bootstrap migration | `l2Plan.delegateComposer` | [`DELEGATE_COMPOSERS`] |
//! | transition, bootstrap migration | `l2Plan.delegateBytecodeInfo` | the bytecode info of one of [`L2_DELEGATES`] |
//! | transition, bootstrap migration | each `l2Plan.extraBytecodeInfos` entry | the bytecode info of a reviewed contract |
//! | core transition, operation, bootstrap migration | each row's `implNew` | the contract of the row's slot ([`super::rows`]) |
//!
//! An L1 member is identified by its RUNTIME: the live code against the reviewed artifact of each
//! contract its role admits, immutable slots masked ([`super::provenance::expect_code_identity`]).
//! Not by construction, because nothing records a member's constructor arguments — the prepare
//! deploys members through its ordinary deploy helpers, and a member it reuses was built by an
//! earlier release's run. An L2 member is a ZKsync OS bytecode info, held against the reviewed
//! hashes' `(blake2s, length, keccak256)` of the contract it must be.
//!
//! # The verifier a release carries over
//!
//! Every other release member is either deployed by the prepare from the reviewed build or reused
//! only when it already IS that build's code (`DefaultCTMUpgrade._canReuseReleaseMember`). The
//! verifier is not: `DeployCTMUtils.deployCurrentRelease` pins the live one unless the version
//! deploys verifiers, so a release can carry a verifier an earlier release's build produced. Such
//! a verifier is accepted only when it is the one already in force — the departing release's, or
//! for the bootstrap the one the CTM's chains at the departing version run — because then the
//! upgrade does not change it; anything else must be this build's.
//!
//! # What this cannot cover
//!
//! * The VALUES in a member's immutable slots: a facet built with another chain id, or an
//!   implementation built over another Bridgehub, runs the reviewed code. The one exception read
//!   here is a verifier's sub-verifiers, which are followed through their getters.
//! * `ZiskVerifier`'s Plonk backend: a snarkJS contract built outside this repository
//!   (`zisk_plonk_verifier_addr`), so no reviewed build describes it and it is an error.
//! * What an extra L2 bytecode does beyond being a reviewed contract: the plan names no role for it.

use std::collections::BTreeSet;

use alloy::primitives::{Address, Bytes, B256};
use alloy::providers::Provider;
use alloy::sol_types::SolValue;

use crate::upgrade_verification::constants::L2_ECOSYSTEM_CONTRACTS;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::ReviewedBuild;
use super::provenance::{
    classify_code, expect_code_identity, tolerate, BytecodeInfoKey, CodeVerdict,
};
use super::views::{AuthoredL2Plan, CTMReleaseView, ReleaseManifest, VerifierTreeView};

/// The diamond facets a release's genesis facet set may name.
pub(crate) const FACETS: &[&str] = &[
    "AdminFacet",
    "GettersFacet",
    "MailboxFacet",
    "ExecutorFacet",
    "MigratorFacet",
    "CommitterFacet",
];
pub(crate) const DIAMOND_INIT: &[&str] = &["DiamondInit"];
pub(crate) const GENESIS_UPGRADE: &[&str] = &["L1GenesisUpgrade"];
/// The verifiers a release may name as its own.
pub(crate) const VERIFIERS: &[&str] = &[
    "MultiProofTestnetVerifier",
    "MultiProofVerifier",
    "ZKsyncOSTestnetVerifier",
    "ZKsyncOSVerifier",
];
/// The engine a `CTMTransition` pins (`DefaultCTMUpgrade.deployUsedUpgradeContract`).
pub(crate) const TRANSITION_ENGINES: &[&str] = &["DefaultUpgrade"];
/// The engine the bootstrap migration pins (`CTMUpgrade_v35.deployUsedUpgradeContract`).
pub(crate) const BOOTSTRAP_ENGINES: &[&str] = &["BootstrapUpgrade"];
/// The `IL2DelegateCalldataComposer`s an authored L2 plan may name.
pub(crate) const DELEGATE_COMPOSERS: &[&str] = &["L2DefaultDelegateCalldataComposer"];
/// The L2 upgrade delegates an authored L2 plan may name.
pub(crate) const L2_DELEGATES: &[&str] = &["L2DefaultUpgrade"];
/// The system-proxy shell every L2 table member sits behind.
pub(crate) const SYSTEM_PROXY_SHELL: &str = "SystemContractProxy";
/// The contract the removed v31 GWAssetTracker's table row pins (`SystemContractsProcessing`).
const REMOVED_GW_ASSET_TRACKER_IMPLEMENTATION: &str = "EmptyContract";

/// The artifact of every L1 member kind, as `(artifact file, contract)` under `l1-contracts/out`:
/// the release members, the engines and composers, and the implementations an inventory slot
/// admits ([`super::rows`]).
pub(crate) const MEMBER_ARTIFACTS: &[(&str, &str)] = &[
    ("Admin.sol", "AdminFacet"),
    ("Getters.sol", "GettersFacet"),
    ("Mailbox.sol", "MailboxFacet"),
    ("Executor.sol", "ExecutorFacet"),
    ("Migrator.sol", "MigratorFacet"),
    ("Committer.sol", "CommitterFacet"),
    ("DiamondInit.sol", "DiamondInit"),
    ("L1GenesisUpgrade.sol", "L1GenesisUpgrade"),
    ("MultiProofTestnetVerifier.sol", "MultiProofTestnetVerifier"),
    ("MultiProofVerifier.sol", "MultiProofVerifier"),
    ("ZKsyncOSTestnetVerifier.sol", "ZKsyncOSTestnetVerifier"),
    ("ZKsyncOSVerifier.sol", "ZKsyncOSVerifier"),
    ("ZKsyncOSVerifierPlonk.sol", "ZKsyncOSVerifierPlonk"),
    ("ZiskTestnetVerifier.sol", "ZiskTestnetVerifier"),
    ("ZiskVerifier.sol", "ZiskVerifier"),
    ("DefaultUpgrade.sol", "DefaultUpgrade"),
    ("BootstrapUpgrade.sol", "BootstrapUpgrade"),
    (
        "L2DefaultDelegateCalldataComposer.sol",
        "L2DefaultDelegateCalldataComposer",
    ),
    ("L1Bridgehub.sol", "L1Bridgehub"),
    ("L1ChainAssetHandler.sol", "L1ChainAssetHandler"),
    ("L1MessageRoot.sol", "L1MessageRoot"),
    ("L1Nullifier.sol", "L1Nullifier"),
    ("L1AssetRouter.sol", "L1AssetRouter"),
    ("L1NativeTokenVault.sol", "L1NativeTokenVault"),
    ("L1InteropHandler.sol", "L1InteropHandler"),
    ("CTMDeploymentTracker.sol", "CTMDeploymentTracker"),
    ("ChainRegistrationSender.sol", "ChainRegistrationSender"),
    ("ChainTypeManager.sol", "ChainTypeManager"),
    ("ValidatorTimelock.sol", "ValidatorTimelock"),
    ("MultisigCommitter.sol", "MultisigCommitter"),
    ("BytecodesSupplier.sol", "BytecodesSupplier"),
    ("PermissionlessValidator.sol", "PermissionlessValidator"),
    ("ServerNotifier.sol", "ServerNotifier"),
    ("L1InteropFeeManager.sol", "L1InteropFeeManager"),
];

/// A verifier's getter that names a sub-verifier.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SubVerifierGetter {
    Inner,
    Airbender,
    ZiskRange,
    Plonk,
}

impl SubVerifierGetter {
    fn name(self) -> &'static str {
        match self {
            Self::Inner => "INNER_VERIFIER",
            Self::Airbender => "AIRBENDER_VERIFIER",
            Self::ZiskRange => "ZISK_RANGE_VERIFIER",
            Self::Plonk => "PLONK_VERIFIER",
        }
    }
}

/// What a sub-verifier must be: one of the reviewed contracts, or a backend no reviewed build
/// describes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SubVerifierKind {
    Reviewed(&'static [&'static str]),
    External(&'static str),
}

/// The sub-verifiers the reviewed `verifier` contract names through its immutables, by getter.
/// A contract with none (the Plonk verifiers) names nothing further.
pub(crate) fn sub_verifiers(verifier: &str) -> &'static [(SubVerifierGetter, SubVerifierKind)] {
    use SubVerifierGetter::*;
    use SubVerifierKind::*;
    match verifier {
        "MultiProofTestnetVerifier" => &[(Inner, Reviewed(&["MultiProofVerifier"]))],
        "MultiProofVerifier" => &[
            (
                Airbender,
                Reviewed(&["ZKsyncOSVerifier", "ZKsyncOSTestnetVerifier"]),
            ),
            (
                ZiskRange,
                Reviewed(&["ZiskVerifier", "ZiskTestnetVerifier"]),
            ),
        ],
        "ZKsyncOSVerifier" | "ZKsyncOSTestnetVerifier" => {
            &[(Plonk, Reviewed(&["ZKsyncOSVerifierPlonk"]))]
        }
        "ZiskTestnetVerifier" => &[(Inner, Reviewed(&["ZiskVerifier"]))],
        "ZiskVerifier" => &[(
            Plonk,
            External(
                "the snarkJS Plonk backend `zisk_plonk_verifier_addr` names, built outside this \
                 repository",
            ),
        )],
        _ => &[],
    }
}

/// The contract a release's L2 bytecode table pins in the slot of `member`
/// (`SystemContractsProcessing.buildL2BytecodeInfoTable`): the member's own contract, except the
/// removed GWAssetTracker's slot, which pins its neutralizing implementation.
pub(crate) fn l2_table_contract(member: &str) -> &str {
    if member == "RemovedGWAssetTracker" {
        REMOVED_GW_ASSET_TRACKER_IMPLEMENTATION
    } else {
        member
    }
}

/// The verifiers already in force where an upgrade departs from, which the release it installs may
/// carry over (see the module docs).
#[derive(Debug, Default)]
pub(super) struct DepartingVerifiers {
    /// What the verifiers were read from, for the report.
    source: String,
    verifiers: BTreeSet<Address>,
}

impl DepartingVerifiers {
    pub(super) fn new(source: impl Into<String>, verifiers: BTreeSet<Address>) -> Self {
        Self {
            source: source.into(),
            verifiers,
        }
    }

    /// The departing release's verifier, read off its manifest. An unreadable manifest offers no
    /// carry-over (reported).
    pub(super) async fn of_release<P: Provider>(
        provider: &P,
        result: &mut VerificationResult,
        release: Address,
    ) -> Self {
        let verifier = tolerate(
            CTMReleaseView::new(release, provider)
                .getManifest()
                .call()
                .await
                .map(|manifest| manifest.verifier),
            result,
            &format!("the departing release {release}'s manifest"),
        );
        Self::new(
            format!("the departing release {release}"),
            verifier.into_iter().collect(),
        )
    }
}

/// Holds every member a release names against the reviewed build: its facets, `DiamondInit`, its
/// genesis upgrade, its verifier tree (or the verifier it carries over from `departing`) and its
/// L2 bytecode table.
pub(super) async fn verify_release_members<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    release: &ReleaseManifest,
    departing: &DepartingVerifiers,
) -> anyhow::Result<()> {
    for (i, row) in release.genesisFacets.iter().enumerate() {
        expect_code_identity(
            provider,
            build,
            result,
            &format!("{label}: genesis facet {i}"),
            row.facet,
            FACETS,
        )
        .await?;
    }
    expect_code_identity(
        provider,
        build,
        result,
        &format!("{label}: diamondInit"),
        release.diamondInit,
        DIAMOND_INIT,
    )
    .await?;
    expect_code_identity(
        provider,
        build,
        result,
        &format!("{label}: genesisUpgrade"),
        release.genesisUpgrade,
        GENESIS_UPGRADE,
    )
    .await?;
    let verifier_label = format!("{label}: verifier");
    if !carried_over_verifier(
        provider,
        build,
        result,
        &verifier_label,
        release.verifier,
        departing,
    )
    .await?
    {
        verify_verifier_tree(provider, build, result, &verifier_label, release.verifier).await?;
    }
    judge_l2_table(build, result, label, release);
    Ok(())
}

/// Whether `verifier` is one already in force at `departing` that this build does not produce —
/// reported as carried over, and its tree is not walked. A departing verifier this build DOES
/// produce is held to the build like any other (returns `false`).
async fn carried_over_verifier<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    verifier: Address,
    departing: &DepartingVerifiers,
) -> anyhow::Result<bool> {
    if !departing.verifiers.contains(&verifier) {
        return Ok(false);
    }
    let code = provider.get_code_at(verifier).await?;
    if code.is_empty()
        || matches!(
            classify_code(build, &code, VERIFIERS),
            CodeVerdict::Reviewed { .. }
        )
    {
        return Ok(false);
    }
    result.report_ok(&format!(
        "{label} at {verifier} is carried over unchanged from {}: this upgrade does not change \
         it, and its code — which this commit's build does not produce — is the one already in \
         force",
        departing.source
    ));
    Ok(true)
}

/// Holds a verifier and every sub-verifier it names, depth first, against the reviewed build.
///
/// Reads, per verifier: its code, then the getter of each sub-verifier its identified contract
/// declares.
pub(super) async fn verify_verifier_tree<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    verifier: Address,
) -> anyhow::Result<()> {
    let mut pending = vec![(label.to_string(), verifier, VERIFIERS)];
    while let Some((label, address, admitted)) = pending.pop() {
        let Some(identified) =
            expect_code_identity(provider, build, result, &label, address, admitted).await?
        else {
            continue;
        };
        let view = VerifierTreeView::new(address, provider);
        // Pushed in reverse so the report reads in declaration order.
        let mut children = Vec::new();
        for (getter, kind) in sub_verifiers(identified) {
            let what = format!("{label}'s {}()", getter.name());
            let read = match getter {
                SubVerifierGetter::Inner => view.INNER_VERIFIER().call().await,
                SubVerifierGetter::Airbender => view.AIRBENDER_VERIFIER().call().await,
                SubVerifierGetter::ZiskRange => view.ZISK_RANGE_VERIFIER().call().await,
                SubVerifierGetter::Plonk => view.PLONK_VERIFIER().call().await,
            };
            let Some(sub) = tolerate(read, result, &what) else {
                continue;
            };
            let sub_label = format!("{label} -> {}", getter.name());
            match kind {
                SubVerifierKind::Reviewed(admitted) => children.push((sub_label, sub, *admitted)),
                SubVerifierKind::External(what) => result.report_error(&format!(
                    "{sub_label} at {sub} is {what}: no reviewed build describes its code, so \
                     the proofs this verifier accepts rest on a contract this review cannot \
                     identify"
                )),
            }
        }
        pending.extend(children.into_iter().rev());
    }
    Ok(())
}

/// Each row of a release's L2 bytecode table, and its system-proxy shell, against the bytecode
/// info the reviewed build produces for the contract the row's slot names.
fn judge_l2_table(
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    release: &ReleaseManifest,
) {
    for (slot, row) in release.l2BytecodeInfos.iter().enumerate() {
        if row.is_empty() {
            continue;
        }
        let Some(member) = L2_ECOSYSTEM_CONTRACTS.get(slot) else {
            result.report_error(&format!(
                "{label}: L2 bytecode table slot {slot} lies beyond the {} members of \
                 L2EcosystemContract this verifier knows, so what it pins cannot be named",
                L2_ECOSYSTEM_CONTRACTS.len()
            ));
            continue;
        };
        expect_bytecode_info(
            build,
            result,
            &format!("{label}: L2 bytecode table slot {slot} (L2EcosystemContract.{member})"),
            row,
            Some(&[l2_table_contract(member)]),
        );
    }
    if !release.l2SystemProxyBytecodeInfo.is_empty() {
        expect_bytecode_info(
            build,
            result,
            &format!("{label}: l2SystemProxyBytecodeInfo"),
            &release.l2SystemProxyBytecodeInfo,
            Some(&[SYSTEM_PROXY_SHELL]),
        );
    }
}

/// An upgrade engine and the authored L2 plan beside it — a transition's or the bootstrap
/// migration's — against the reviewed build.
pub(super) async fn verify_engine_and_l2_plan<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    engine: Address,
    engines: &[&'static str],
    plan: &AuthoredL2Plan,
) -> anyhow::Result<()> {
    expect_code_identity(
        provider,
        build,
        result,
        &format!("{label}: upgradeEngine"),
        engine,
        engines,
    )
    .await?;
    if !plan.delegateComposer.is_zero() {
        expect_code_identity(
            provider,
            build,
            result,
            &format!("{label}: l2Plan.delegateComposer"),
            plan.delegateComposer,
            DELEGATE_COMPOSERS,
        )
        .await?;
    }
    judge_authored_l2_bytecodes(build, result, label, plan);
    Ok(())
}

/// The authored delegate and extra bytecode infos of an L2 plan against the reviewed build.
fn judge_authored_l2_bytecodes(
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    plan: &AuthoredL2Plan,
) {
    if !plan.delegateBytecodeInfo.is_empty() {
        expect_bytecode_info(
            build,
            result,
            &format!("{label}: l2Plan.delegateBytecodeInfo"),
            &plan.delegateBytecodeInfo,
            Some(L2_DELEGATES),
        );
    }
    for (i, info) in plan.extraBytecodeInfos.iter().enumerate() {
        expect_bytecode_info(
            build,
            result,
            &format!("{label}: l2Plan.extraBytecodeInfos[{i}]"),
            info,
            None,
        );
    }
}

/// `ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo`: `abi.decode(info, (bytes32, uint32,
/// bytes32))`, refusing anything but exactly that encoding.
pub(crate) fn decode_bytecode_info(info: &[u8]) -> Option<BytecodeInfoKey> {
    let (blake, length, keccak) = <(B256, u32, B256)>::abi_decode_params(info).ok()?;
    ((blake, length, keccak).abi_encode_params() == info).then_some((blake, length, keccak))
}

/// Reports whether `info` is the ZKsync OS bytecode info of a contract the reviewed build
/// produces — one of `admitted` when the role names them — and returns that contract.
pub(super) fn expect_bytecode_info(
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    label: &str,
    info: &Bytes,
    admitted: Option<&[&str]>,
) -> bool {
    let Some(key) = decode_bytecode_info(info) else {
        result.report_error(&format!(
            "{label} ({} bytes) is not a ZKsync OS bytecode info `(bytes32 blake2s, uint32 \
             length, bytes32 keccak256)`: it names no bytecode the review can identify",
            info.len()
        ));
        return false;
    };
    let (blake, length, keccak) = key;
    let Some(name) = build.identity().name_of_bytecode_info(&key) else {
        result.report_error(&format!(
            "{label} (blake2s {blake}, {length} bytes, keccak256 {keccak}) is the bytecode of no \
             contract {} records: what it deploys on L2 is unknown",
            build.identity().source().display()
        ));
        return false;
    };
    let short = name.rsplit('/').next().unwrap_or(name);
    match admitted {
        Some(admitted) if !admitted.contains(&short) => {
            result.report_error(&format!(
                "{label} is the bytecode of {name}, not {}",
                admitted.join(" or ")
            ));
            false
        }
        _ => {
            result.report_ok(&format!(
                "{label} is the ZKsync OS bytecode info of the reviewed {name}"
            ));
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upgrade_verification::registry::provenance::CodeIdentity;
    use crate::upgrade_verification::registry::views::{GenesisFacet, ReleaseGenesisData};
    use alloy::providers::ProviderBuilder;
    use alloy::transports::mock::Asserter;

    // ───────────────────────── the member tables against the sources ─────────────────────────

    const L1_CONTRACTS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../l1-contracts");

    /// Every `.sol` file under `l1-contracts/contracts`, by file name.
    fn sources() -> std::collections::HashMap<String, std::path::PathBuf> {
        fn walk(
            dir: &std::path::Path,
            out: &mut std::collections::HashMap<String, std::path::PathBuf>,
        ) {
            for entry in std::fs::read_dir(dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    walk(&path, out);
                } else if path.extension().is_some_and(|e| e == "sol") {
                    out.insert(
                        path.file_name().unwrap().to_string_lossy().into_owned(),
                        path,
                    );
                }
            }
        }
        let mut out = std::collections::HashMap::new();
        walk(
            &std::path::Path::new(L1_CONTRACTS).join("contracts"),
            &mut out,
        );
        out
    }

    /// Each member artifact is a contract the production sources declare in that file — so the
    /// build loads what the table names, and a renamed or moved contract fails here rather than
    /// as an unverifiable member in a review.
    #[test]
    fn every_member_artifact_is_a_production_contract() {
        let sources = sources();
        for (file, name) in MEMBER_ARTIFACTS {
            let path = sources
                .get(*file)
                .unwrap_or_else(|| panic!("no {file} under l1-contracts/contracts"));
            let source = std::fs::read_to_string(path).unwrap();
            assert!(
                source.contains(&format!("contract {name} ")),
                "{file} declares no `contract {name}`"
            );
        }
    }

    /// Every contract a role admits is loaded by the build, or the role could never pass.
    #[test]
    fn every_admitted_contract_has_an_artifact() {
        let loaded: Vec<&str> = MEMBER_ARTIFACTS.iter().map(|(_, name)| *name).collect();
        let mut admitted: Vec<&str> = [
            FACETS,
            DIAMOND_INIT,
            GENESIS_UPGRADE,
            VERIFIERS,
            TRANSITION_ENGINES,
            BOOTSTRAP_ENGINES,
            DELEGATE_COMPOSERS,
        ]
        .concat();
        for verifier in VERIFIERS.iter().chain(&[
            "ZKsyncOSVerifierPlonk",
            "ZiskVerifier",
            "ZiskTestnetVerifier",
        ]) {
            for (_, kind) in sub_verifiers(verifier) {
                if let SubVerifierKind::Reviewed(names) = kind {
                    admitted.extend_from_slice(names);
                }
            }
        }
        for name in admitted {
            assert!(
                loaded.contains(&name),
                "{name} is admitted but never loaded"
            );
        }
    }

    /// The facet set, the engines and the composer are the contracts the prepares deploy for
    /// those roles (`DeployCTMUtils.deployStateTransitionDiamondFacets`, the engines'
    /// `deployUsedUpgradeContract`, `CTMUpgrade_v35.deployNewCTMContracts`).
    #[test]
    fn the_roles_are_what_the_prepares_deploy() {
        let read = |path: &str| std::fs::read_to_string(format!("{L1_CONTRACTS}/{path}")).unwrap();
        let ctm_utils = read("deploy-scripts/ctm/DeployCTMUtils.s.sol");
        for facet in FACETS {
            assert!(
                ctm_utils.contains(&format!("_deployReleaseFacet(\"{facet}\"")),
                "the release deploy does not deploy {facet}"
            );
        }
        assert!(ctm_utils.contains("_deployReleaseMember(\"DiamondInit\""));
        assert!(ctm_utils.contains("\"L1GenesisUpgrade\","));
        let default_ctm = read("deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol");
        assert!(default_ctm.contains("return deploySimpleContract(\"DefaultUpgrade\");"));
        let v35 = read("deploy-scripts/upgrade/v35/CTMUpgrade_v35.s.sol");
        assert!(v35.contains("return deploySimpleContract(\"BootstrapUpgrade\");"));
        assert!(v35.contains("deploySimpleContract(\"L2DefaultDelegateCalldataComposer\")"));
        assert!(v35.contains(
            "getZKOSBytecodeInfoForContract(\"L2DefaultUpgrade.sol\", \"L2DefaultUpgrade\")"
        ));
    }

    /// The L2 table pins each member's own contract (`CoreOnGatewayHelper._resolveContractName`
    /// is the identity on names), except the removed tracker's slot.
    #[test]
    fn the_l2_table_contracts_are_the_builders() {
        let helper = std::fs::read_to_string(format!(
            "{L1_CONTRACTS}/deploy-scripts/ecosystem/CoreOnGatewayHelper.sol"
        ))
        .unwrap();
        let resolver = helper
            .split_once("function _resolveContractName(")
            .unwrap()
            .1
            .split_once("revert UnknownCoreContract();")
            .unwrap()
            .0;
        let mut mapped = 0;
        for line in resolver.lines() {
            let Some((member, name)) = line
                .split_once("L2EcosystemContract.")
                .and_then(|(_, rest)| rest.split_once(')'))
                .and_then(|(member, rest)| {
                    rest.split('"').nth(1).map(|name| (member.trim(), name))
                })
            else {
                continue;
            };
            assert_eq!(l2_table_contract(member), name, "slot {member}");
            mapped += 1;
        }
        assert!(mapped > 10, "the resolver was not parsed");
        let builder = std::fs::read_to_string(format!(
            "{L1_CONTRACTS}/deploy-scripts/upgrade/SystemContractsProcessing.s.sol"
        ))
        .unwrap();
        let normalized: String = builder.split_whitespace().collect();
        assert!(normalized.contains(&format!(
            "rows[uint256(L2EcosystemContract.RemovedGWAssetTracker)]=_buildBytecodeInfo(\"EmptyContract.sol\",\"{REMOVED_GW_ASSET_TRACKER_IMPLEMENTATION}\")"
        )));
    }

    // ───────────────────────── L2 bytecode infos ─────────────────────────

    const DELEGATE_INFO: BytecodeInfoKey = (B256::repeat_byte(0xD1), 1234, B256::repeat_byte(0xD2));
    const OTHER_INFO: BytecodeInfoKey = (B256::repeat_byte(0x01), 99, B256::repeat_byte(0x02));

    fn encoded(info: BytecodeInfoKey) -> Bytes {
        Bytes::from(info.abi_encode_params())
    }

    fn info_build() -> ReviewedBuild {
        ReviewedBuild::from_artifacts(
            CodeIdentity::empty()
                .with_bytecode_info("l1-contracts/L2DefaultUpgrade", DELEGATE_INFO)
                .with_bytecode_info("l1-contracts/L2Bridgehub", OTHER_INFO),
            Vec::new(),
        )
    }

    fn judge_info(info: &Bytes, admitted: Option<&[&str]>) -> VerificationResult {
        let mut result = VerificationResult::default();
        expect_bytecode_info(&info_build(), &mut result, "the delegate", info, admitted);
        result
    }

    #[test]
    fn a_reviewed_bytecode_info_in_its_role_passes() {
        assert_eq!(
            judge_info(&encoded(DELEGATE_INFO), Some(L2_DELEGATES)).errors,
            0
        );
        assert_eq!(judge_info(&encoded(OTHER_INFO), None).errors, 0);
    }

    /// Reviewed code in the wrong role is still a finding: a delegate slot naming another L2
    /// contract would be delegatecalled by the ComplexUpgrader.
    #[test]
    fn a_reviewed_bytecode_info_in_another_role_fails() {
        assert_eq!(
            judge_info(&encoded(OTHER_INFO), Some(L2_DELEGATES)).errors,
            1
        );
    }

    /// Each of the three fields is part of the identity: one wrong field names no contract.
    #[test]
    fn an_unknown_or_malformed_bytecode_info_fails() {
        for tampered in [
            (B256::repeat_byte(0xEE), DELEGATE_INFO.1, DELEGATE_INFO.2),
            (DELEGATE_INFO.0, DELEGATE_INFO.1 + 1, DELEGATE_INFO.2),
            (DELEGATE_INFO.0, DELEGATE_INFO.1, B256::repeat_byte(0xEE)),
        ] {
            assert_eq!(judge_info(&encoded(tampered), None).errors, 1);
        }
        assert_eq!(
            judge_info(&Bytes::from_static(b"not an info"), None).errors,
            1
        );
        let mut longer = encoded(DELEGATE_INFO).to_vec();
        longer.push(0);
        assert_eq!(judge_info(&Bytes::from(longer), None).errors, 1);
    }

    fn release_with_table(table: Vec<Bytes>, shell: Bytes) -> ReleaseManifest {
        ReleaseManifest {
            protocolVersion: Default::default(),
            diamondInit: Address::ZERO,
            verifier: Address::ZERO,
            genesisUpgrade: Address::ZERO,
            genesisFacets: Vec::<GenesisFacet>::new(),
            genesis: ReleaseGenesisData {
                fixedForceDeploymentsData: Bytes::new(),
                genesisBatchHash: B256::ZERO,
                genesisIndexRepeatedStorageChanges: 0,
            },
            l2BytecodeInfos: table,
            l2SystemProxyBytecodeInfo: shell,
        }
    }

    /// A table row must be the bytecode of the contract its slot names; an empty row is the
    /// "not in this release" statement and is skipped.
    #[test]
    fn an_l2_table_row_is_held_against_its_slot() {
        let shell_info = (B256::repeat_byte(0x5A), 50, B256::repeat_byte(0x5B));
        let build = ReviewedBuild::from_artifacts(
            CodeIdentity::empty()
                .with_bytecode_info("l1-contracts/L2Bridgehub", OTHER_INFO)
                .with_bytecode_info("l1-contracts/L2DefaultUpgrade", DELEGATE_INFO)
                .with_bytecode_info("l1-contracts/SystemContractProxy", shell_info),
            Vec::new(),
        );
        let judge = |table: Vec<Bytes>| {
            let mut result = VerificationResult::default();
            judge_l2_table(
                &build,
                &mut result,
                "the release",
                &release_with_table(table, encoded(shell_info)),
            );
            result
        };
        // Slot 0 is L2Bridgehub.
        assert_eq!(judge(vec![encoded(OTHER_INFO), Bytes::new()]).errors, 0);
        // The delegate's bytecode in the Bridgehub's slot: reviewed code, wrong member.
        assert_eq!(judge(vec![encoded(DELEGATE_INFO)]).errors, 1);
        // A slot past the enum this verifier knows.
        let mut long = vec![Bytes::new(); L2_ECOSYSTEM_CONTRACTS.len()];
        long.push(encoded(OTHER_INFO));
        assert_eq!(judge(long).errors, 1);
    }

    // ───────────────────────── the verifier tree ─────────────────────────

    const PLONK_RUNTIME: &[u8] = b"the reviewed ZKsyncOSVerifierPlonk runtime";
    /// Where [`testnet_verifier_runtime`] holds its `PLONK_VERIFIER` immutable.
    const PLONK_IMMUTABLE: std::ops::Range<usize> = 7..39;

    fn testnet_verifier_runtime(plonk: Address) -> Vec<u8> {
        let mut code = b"TESTNET".to_vec();
        code.extend_from_slice(&plonk.into_word()[..]);
        code
    }

    fn tree_build() -> ReviewedBuild {
        let mut artifact = testnet_verifier_runtime(Address::ZERO);
        artifact[PLONK_IMMUTABLE].fill(0);
        ReviewedBuild::from_artifacts(
            CodeIdentity::empty(),
            vec![
                (
                    "ZKsyncOSTestnetVerifier.sol",
                    "ZKsyncOSTestnetVerifier",
                    Vec::new(),
                    artifact,
                    vec![PLONK_IMMUTABLE],
                ),
                (
                    "ZKsyncOSVerifierPlonk.sol",
                    "ZKsyncOSVerifierPlonk",
                    Vec::new(),
                    PLONK_RUNTIME.to_vec(),
                    Vec::new(),
                ),
            ],
        )
    }

    /// Drives the tree over a mocked transport, in the order it reads: the verifier's code, its
    /// `PLONK_VERIFIER()`, then the Plonk verifier's code.
    async fn walk(plonk_code: &[u8]) -> VerificationResult {
        let plonk = Address::repeat_byte(0x9A);
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from(testnet_verifier_runtime(plonk)));
        asserter.push_success(&Bytes::from(plonk.abi_encode()));
        asserter.push_success(&Bytes::copy_from_slice(plonk_code));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        verify_verifier_tree(
            &provider,
            &tree_build(),
            &mut result,
            "the verifier",
            Address::repeat_byte(0x77),
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty(), "every level was read");
        result
    }

    #[tokio::test]
    async fn a_reviewed_verifier_tree_passes() {
        assert_eq!(walk(PLONK_RUNTIME).await.errors, 0);
    }

    /// The reviewed wrapper over a Plonk verifier the build does not produce: the sub-verifier is
    /// what actually checks the proof, so it is a finding.
    #[tokio::test]
    async fn an_unreviewed_sub_verifier_fails() {
        let result = walk(b"a Plonk verifier that accepts anything").await;
        assert_eq!(result.errors, 1);
        assert!(result.ensure_success().is_err());
    }

    /// The external Zisk backend is reported, never passed.
    #[test]
    fn the_zisk_backend_is_external() {
        assert!(matches!(
            sub_verifiers("ZiskVerifier"),
            [(SubVerifierGetter::Plonk, SubVerifierKind::External(_))]
        ));
        assert!(sub_verifiers("ZKsyncOSVerifierPlonk").is_empty());
    }

    // ───────────────────────── a release's L1 members ─────────────────────────
    //
    // One release naming one facet, DiamondInit, its genesis upgrade and a testnet verifier over
    // its Plonk verifier, driven through `verify_release_members` over a mocked transport. The
    // answers are queued in the order the members are read: the facet, DiamondInit, the genesis
    // upgrade, then the verifier tree (with one more read of the verifier's code first when it is
    // a departing verifier).

    const FACET: Address = Address::repeat_byte(0xF0);
    const DIAMOND: Address = Address::repeat_byte(0xD0);
    const GENESIS: Address = Address::repeat_byte(0x6E);
    const VERIFIER: Address = Address::repeat_byte(0x77);
    const PLONK: Address = Address::repeat_byte(0x9A);
    /// Where [`admin_runtime`] holds its one immutable.
    const ADMIN_IMMUTABLE: std::ops::Range<usize> = 5..37;
    const DIAMOND_INIT_RUNTIME: &[u8] = b"the reviewed DiamondInit runtime";
    const GENESIS_UPGRADE_RUNTIME: &[u8] = b"the reviewed L1GenesisUpgrade runtime";
    const DEFAULT_UPGRADE_RUNTIME: &[u8] = b"the reviewed DefaultUpgrade runtime";
    const BOOTSTRAP_UPGRADE_RUNTIME: &[u8] = b"the reviewed BootstrapUpgrade runtime";
    const COMPOSER_RUNTIME: &[u8] = b"the reviewed L2DefaultDelegateCalldataComposer runtime";
    const UNKNOWN_RUNTIME: &[u8] = b"code no reviewed artifact is";

    /// An AdminFacet as deployed, its immutable set to `value`.
    fn admin_runtime(value: u8) -> Vec<u8> {
        let mut code = b"ADMIN".to_vec();
        code.extend_from_slice(&[value; 32]);
        code.extend_from_slice(b" facet body");
        code
    }

    fn member_build() -> ReviewedBuild {
        let mut verifier = testnet_verifier_runtime(Address::ZERO);
        verifier[PLONK_IMMUTABLE].fill(0);
        let artifact = |file: &'static str, name: &'static str, runtime: &[u8]| {
            (file, name, Vec::new(), runtime.to_vec(), Vec::new())
        };
        ReviewedBuild::from_artifacts(
            CodeIdentity::empty()
                .with_bytecode_info("l1-contracts/L2DefaultUpgrade", DELEGATE_INFO)
                .with_bytecode_info("l1-contracts/L2Bridgehub", OTHER_INFO),
            vec![
                (
                    "Admin.sol",
                    "AdminFacet",
                    Vec::new(),
                    admin_runtime(0),
                    vec![ADMIN_IMMUTABLE],
                ),
                artifact("DiamondInit.sol", "DiamondInit", DIAMOND_INIT_RUNTIME),
                artifact(
                    "L1GenesisUpgrade.sol",
                    "L1GenesisUpgrade",
                    GENESIS_UPGRADE_RUNTIME,
                ),
                (
                    "ZKsyncOSTestnetVerifier.sol",
                    "ZKsyncOSTestnetVerifier",
                    Vec::new(),
                    verifier,
                    vec![PLONK_IMMUTABLE],
                ),
                artifact(
                    "ZKsyncOSVerifierPlonk.sol",
                    "ZKsyncOSVerifierPlonk",
                    PLONK_RUNTIME,
                ),
                artifact(
                    "DefaultUpgrade.sol",
                    "DefaultUpgrade",
                    DEFAULT_UPGRADE_RUNTIME,
                ),
                artifact(
                    "BootstrapUpgrade.sol",
                    "BootstrapUpgrade",
                    BOOTSTRAP_UPGRADE_RUNTIME,
                ),
                artifact(
                    "L2DefaultDelegateCalldataComposer.sol",
                    "L2DefaultDelegateCalldataComposer",
                    COMPOSER_RUNTIME,
                ),
            ],
        )
    }

    fn release() -> ReleaseManifest {
        let mut release = release_with_table(Vec::new(), Bytes::new());
        release.genesisFacets = vec![GenesisFacet {
            facet: FACET,
            isFreezable: false,
        }];
        release.diamondInit = DIAMOND;
        release.genesisUpgrade = GENESIS;
        release.verifier = VERIFIER;
        release
    }

    async fn run_release(
        answers: Vec<Vec<u8>>,
        departing: DepartingVerifiers,
    ) -> VerificationResult {
        let asserter = Asserter::new();
        for answer in answers {
            asserter.push_success(&Bytes::from(answer));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        verify_release_members(
            &provider,
            &member_build(),
            &mut result,
            "the release",
            &release(),
            &departing,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty(), "every member was read");
        result
    }

    /// The facet, DiamondInit and the genesis upgrade in order, then `verifier`'s answers.
    fn release_answers(
        facet: Vec<u8>,
        diamond: &[u8],
        genesis: &[u8],
        verifier: Vec<Vec<u8>>,
    ) -> Vec<Vec<u8>> {
        let mut answers = vec![facet, diamond.to_vec(), genesis.to_vec()];
        answers.extend(verifier);
        answers
    }

    /// The reviewed verifier's reads: its code, its `PLONK_VERIFIER()`, the Plonk code.
    fn reviewed_verifier() -> Vec<Vec<u8>> {
        vec![
            testnet_verifier_runtime(PLONK),
            PLONK.abi_encode(),
            PLONK_RUNTIME.to_vec(),
        ]
    }

    #[tokio::test]
    async fn a_release_of_reviewed_members_passes_with_its_immutables_masked() {
        let result = run_release(
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                reviewed_verifier(),
            ),
            DepartingVerifiers::default(),
        )
        .await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    /// Each member kind is held to its own role: reviewed code of another role, or code no
    /// artifact is, fails exactly that member.
    #[tokio::test]
    async fn each_release_member_kind_is_held_to_its_role() {
        let mut tampered_facet = admin_runtime(0x42);
        tampered_facet[0] ^= 0x01;
        for answers in [
            // A facet slot running DiamondInit, and a facet whose code differs outside its slot.
            release_answers(
                DIAMOND_INIT_RUNTIME.to_vec(),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                reviewed_verifier(),
            ),
            release_answers(
                tampered_facet,
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                reviewed_verifier(),
            ),
            // DiamondInit running unknown code.
            release_answers(
                admin_runtime(0x42),
                UNKNOWN_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                reviewed_verifier(),
            ),
            // The genesis upgrade running the transition engine.
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                DEFAULT_UPGRADE_RUNTIME,
                reviewed_verifier(),
            ),
            // A verifier the build does not produce: its tree is not walked.
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                vec![UNKNOWN_RUNTIME.to_vec()],
            ),
            // The Plonk verifier running the Plonk verifier's wrapper.
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                vec![
                    testnet_verifier_runtime(PLONK),
                    PLONK.abi_encode(),
                    testnet_verifier_runtime(PLONK),
                ],
            ),
        ] {
            let result = run_release(answers, DepartingVerifiers::default()).await;
            assert_eq!(result.errors, 1);
            assert!(result.ensure_success().is_err());
        }
    }

    /// The verifier already in force where the upgrade departs from is carried over, even when
    /// this build does not produce it, and its tree is not walked: the upgrade does not change it.
    #[tokio::test]
    async fn the_departing_verifier_is_carried_over() {
        let departing =
            || DepartingVerifiers::new("the departing release", [VERIFIER].into_iter().collect());
        let result = run_release(
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                vec![UNKNOWN_RUNTIME.to_vec()],
            ),
            departing(),
        )
        .await;
        assert_eq!(result.errors, 0);

        // A departing verifier this build DOES produce is held to the build like any other: its
        // code is read once for the carry-over decision, then its tree is walked.
        let mut verifier = vec![testnet_verifier_runtime(PLONK)];
        verifier.extend(reviewed_verifier());
        let result = run_release(
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                verifier,
            ),
            departing(),
        )
        .await;
        assert_eq!(result.errors, 0);

        // Another verifier than the departing one gets no such pass.
        let result = run_release(
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                vec![UNKNOWN_RUNTIME.to_vec()],
            ),
            DepartingVerifiers::new(
                "the departing release",
                [Address::repeat_byte(0x78)].into_iter().collect(),
            ),
        )
        .await;
        assert_eq!(result.errors, 1);
    }

    // ───────────────────────── engines and authored L2 plans ─────────────────────────

    const ENGINE: Address = Address::repeat_byte(0xE0);
    const COMPOSER: Address = Address::repeat_byte(0xE1);

    fn plan(composer: Address, delegate: Bytes, extras: Vec<Bytes>) -> AuthoredL2Plan {
        AuthoredL2Plan {
            delegateBytecodeInfo: delegate,
            extraBytecodeInfos: extras,
            delegateComposer: composer,
        }
    }

    /// The engine's code, then the composer's when the plan names one.
    async fn run_engine(
        answers: &[&[u8]],
        engines: &[&'static str],
        plan: &AuthoredL2Plan,
    ) -> VerificationResult {
        let asserter = Asserter::new();
        for answer in answers {
            asserter.push_success(&Bytes::copy_from_slice(answer));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        verify_engine_and_l2_plan(
            &provider,
            &member_build(),
            &mut result,
            "the transition",
            ENGINE,
            engines,
            plan,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty());
        result
    }

    #[tokio::test]
    async fn a_reviewed_engine_composer_and_plan_pass() {
        let full = plan(COMPOSER, encoded(DELEGATE_INFO), vec![encoded(OTHER_INFO)]);
        let result = run_engine(
            &[DEFAULT_UPGRADE_RUNTIME, COMPOSER_RUNTIME],
            TRANSITION_ENGINES,
            &full,
        )
        .await;
        assert_eq!(result.errors, 0);
        // An L1-only edge: no composer, no delegate — the engine alone is read.
        let empty = plan(Address::ZERO, Bytes::new(), Vec::new());
        let result = run_engine(&[BOOTSTRAP_UPGRADE_RUNTIME], BOOTSTRAP_ENGINES, &empty).await;
        assert_eq!(result.errors, 0);
    }

    /// The engine kinds are not interchangeable: a transition pinning the bootstrap engine (or the
    /// reverse) would run another upgrade on every chain.
    #[tokio::test]
    async fn an_engine_of_another_kind_fails() {
        let empty = plan(Address::ZERO, Bytes::new(), Vec::new());
        let result = run_engine(&[BOOTSTRAP_UPGRADE_RUNTIME], TRANSITION_ENGINES, &empty).await;
        assert_eq!(result.errors, 1);
        let result = run_engine(&[DEFAULT_UPGRADE_RUNTIME], BOOTSTRAP_ENGINES, &empty).await;
        assert_eq!(result.errors, 1);
    }

    #[tokio::test]
    async fn a_composer_or_an_authored_bytecode_outside_its_role_fails() {
        let result = run_engine(
            &[DEFAULT_UPGRADE_RUNTIME, DEFAULT_UPGRADE_RUNTIME],
            TRANSITION_ENGINES,
            &plan(COMPOSER, encoded(DELEGATE_INFO), Vec::new()),
        )
        .await;
        assert_eq!(result.errors, 1);
        let result = run_engine(
            &[DEFAULT_UPGRADE_RUNTIME, COMPOSER_RUNTIME],
            TRANSITION_ENGINES,
            &plan(COMPOSER, encoded(OTHER_INFO), Vec::new()),
        )
        .await;
        assert_eq!(result.errors, 1);
        let unknown = (B256::repeat_byte(0xEE), 1, B256::repeat_byte(0xEF));
        let result = run_engine(
            &[DEFAULT_UPGRADE_RUNTIME, COMPOSER_RUNTIME],
            TRANSITION_ENGINES,
            &plan(COMPOSER, encoded(DELEGATE_INFO), vec![encoded(unknown)]),
        )
        .await;
        assert_eq!(result.errors, 1);
    }
}
