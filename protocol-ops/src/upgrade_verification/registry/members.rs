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
//! | release | `verifier` | one of [`VERIFIERS`], and each sub-verifier it names ([`sub_verifiers`]) — or the verifier already in force where the upgrade departs from ([`DepartingMembers`]) |
//! | release | each L2 bytecode table row | the bytecode info of the contract its slot names |
//! | release | `l2SystemProxyBytecodeInfo` | the bytecode info of [`SYSTEM_PROXY_SHELL`] |
//! | transition | `upgradeEngine` | [`TRANSITION_ENGINES`] |
//! | bootstrap migration | `upgradeEngine` | [`BOOTSTRAP_ENGINES`] |
//! | transition, bootstrap migration | `l2Plan.delegateComposer` | [`DELEGATE_COMPOSERS`] |
//! | transition, bootstrap migration | `l2Plan.delegateBytecodeInfo` | the bytecode info of one of [`L2_DELEGATES`] |
//! | transition, bootstrap migration | each `l2Plan.extraBytecodeInfos` entry | the bytecode info of a reviewed contract |
//! | proxy upgrade transition (either domain), bootstrap migration | each row's `implNew` | the contract of the row's slot ([`super::rows`]) |
//!
//! An L1 member is identified by its RUNTIME: the live code against the reviewed artifact of each
//! contract its role admits, immutable slots masked ([`super::provenance::expect_code_identity`]).
//! A member the package newly installs is ALSO held to its construction record, which proves the
//! values in those slots ([`super::member_construction`]); one the departing side already names
//! ([`DepartingMembers`]) was reviewed when it was installed and is carried over. An L2 member is
//! a ZKsync OS bytecode info, held against the reviewed hashes' `(blake2s, length, keccak256)` of
//! the contract it must be.
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
//! `ZiskVerifier`'s Plonk backend is a snarkJS contract built outside this repository, so no
//! reviewed build describes it: it is held to its pinned runtime hash instead
//! ([`super::external_backends`]).
//!
//! # What this cannot cover
//!
//! * The values in a CARRIED-OVER member's immutable slots: they were reviewed when an earlier
//!   package installed it, or not at all for a release `ctm init` deployed.
//! * What an extra L2 bytecode does beyond being a reviewed contract: the plan names no role for it.

use std::cell::RefCell;
use std::collections::BTreeSet;

use alloy::primitives::{Address, Bytes, B256};
use alloy::providers::Provider;
use alloy::sol_types::SolValue;

use crate::upgrade_verification::constants::L2_ECOSYSTEM_CONTRACTS;
use crate::upgrade_verification::report::VerificationResult;

use super::construction::ReviewedBuild;
use super::external_backends::judge_zisk_backend;
use super::member_construction::{expect_member_construction, ArgContext, Member, MemberReview};
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
/// The engine the bootstrap migration pins (the v35 bootstrap prepare's `deployUsedUpgradeContract`,
/// `CTMUpgrade_v35`, retired in v36).
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
    // Not a member, but the contract a MailboxFacet's `_eip7702Checker` must run.
    ("EIP7702Checker.sol", "EIP7702Checker"),
];

/// A verifier's getter that names a sub-verifier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum SubVerifierGetter {
    Inner,
    Airbender,
    ZiskRange,
    Plonk,
}

impl SubVerifierGetter {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Inner => "INNER_VERIFIER",
            Self::Airbender => "AIRBENDER_VERIFIER",
            Self::ZiskRange => "ZISK_RANGE_VERIFIER",
            Self::Plonk => "PLONK_VERIFIER",
        }
    }
}

/// What a sub-verifier must be: one of the reviewed contracts, or the pinned ZiSK Plonk backend
/// ([`super::external_backends`]), which no reviewed build describes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SubVerifierKind {
    Reviewed(&'static [&'static str]),
    PinnedBackend,
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
        "ZiskVerifier" => &[(Plonk, PinnedBackend)],
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

/// The L1 members the departing side already names: they were reviewed when they were installed,
/// so a release that keeps one carries it over without a construction record. Among them, the
/// verifiers in force, which a release may carry over even when this build does not produce them
/// (see the module docs), and — read only when a new verifier node has no record — every
/// sub-verifier their trees name, which a new verifier may reuse.
#[derive(Debug, Default)]
pub(super) struct DepartingMembers {
    /// What the members were read from, for the report.
    source: String,
    members: BTreeSet<Address>,
    verifiers: BTreeSet<Address>,
    /// The sub-verifiers the trees of `verifiers` name, once read ([`Self::names_sub_verifier`]).
    sub_verifiers: RefCell<Option<BTreeSet<Address>>>,
}

impl DepartingMembers {
    /// The verifiers in force where a pre-registry CTM departs from (the bootstrap): no release
    /// names anything else.
    pub(super) fn verifiers_in_force(
        source: impl Into<String>,
        verifiers: BTreeSet<Address>,
    ) -> Self {
        Self {
            source: source.into(),
            members: verifiers.clone(),
            verifiers,
            sub_verifiers: RefCell::new(None),
        }
    }

    /// Every L1 member of the departing release, read off its manifest. An unreadable manifest
    /// carries nothing over (reported).
    pub(super) async fn of_release<P: Provider>(
        provider: &P,
        result: &mut VerificationResult,
        release: Address,
    ) -> Self {
        let manifest = tolerate(
            CTMReleaseView::new(release, provider)
                .getManifest()
                .call()
                .await,
            result,
            &format!("the departing release {release}'s manifest"),
        );
        let mut members = BTreeSet::new();
        let mut verifiers = BTreeSet::new();
        if let Some(manifest) = manifest {
            members.extend(manifest.genesisFacets.iter().map(|row| row.facet));
            members.extend([
                manifest.diamondInit,
                manifest.genesisUpgrade,
                manifest.verifier,
            ]);
            verifiers.insert(manifest.verifier);
        }
        Self {
            source: format!("the departing release {release}"),
            members,
            verifiers,
            sub_verifiers: RefCell::new(None),
        }
    }

    /// What carries `address` over, when the departing side names it.
    fn carries(&self, address: Address) -> Option<String> {
        self.members.contains(&address).then(|| self.source.clone())
    }

    /// Why a member the departing side does not name must be a deployment of the package.
    fn new_because(&self) -> String {
        format!("{} does not name it", self.source)
    }

    /// Whether the tree of a departing verifier names `address` below its root. The trees are
    /// walked once, the first time this is asked, over each node's reviewed sub-verifier getters;
    /// nothing about them is reported, since they only exempt (an unreadable or unreviewed node
    /// names nothing, which fails closed).
    async fn names_sub_verifier<P: Provider>(
        &self,
        provider: &P,
        build: &ReviewedBuild,
        address: Address,
    ) -> bool {
        if self.sub_verifiers.borrow().is_none() {
            let mut found = BTreeSet::new();
            let mut pending: Vec<(Address, &'static [&'static str])> = self
                .verifiers
                .iter()
                .map(|verifier| (*verifier, VERIFIERS))
                .collect();
            while let Some((node, admitted)) = pending.pop() {
                let Ok(code) = provider.get_code_at(node).await else {
                    continue;
                };
                let CodeVerdict::Reviewed { name, .. } = classify_code(build, &code, admitted)
                else {
                    continue;
                };
                let view = VerifierTreeView::new(node, provider);
                for (getter, kind) in sub_verifiers(name) {
                    let Ok(sub) = read_sub_verifier(&view, *getter).await else {
                        continue;
                    };
                    if found.insert(sub) {
                        if let SubVerifierKind::Reviewed(names) = kind {
                            pending.push((sub, names));
                        }
                    }
                }
            }
            *self.sub_verifiers.borrow_mut() = Some(found);
        }
        self.sub_verifiers
            .borrow()
            .as_ref()
            .is_some_and(|found| found.contains(&address))
    }
}

/// `getter` on the verifier `view` reads.
async fn read_sub_verifier<P: Provider>(
    view: &VerifierTreeView::VerifierTreeViewInstance<&P>,
    getter: SubVerifierGetter,
) -> Result<Address, alloy::contract::Error> {
    match getter {
        SubVerifierGetter::Inner => view.INNER_VERIFIER().call().await,
        SubVerifierGetter::Airbender => view.AIRBENDER_VERIFIER().call().await,
        SubVerifierGetter::ZiskRange => view.ZISK_RANGE_VERIFIER().call().await,
        SubVerifierGetter::Plonk => view.PLONK_VERIFIER().call().await,
    }
}

/// Holds every member a release names against the reviewed build: its facets, `DiamondInit`, its
/// genesis upgrade, its verifier tree (or the verifier it carries over from `departing`) and its
/// L2 bytecode table — each L1 member's code, and the construction of each one `departing` does
/// not name.
pub(super) async fn verify_release_members<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    members: &MemberReview<'_>,
    label: &str,
    release: &ReleaseManifest,
    departing: &DepartingMembers,
) -> anyhow::Result<()> {
    let mut named: Vec<(String, Address, &'static [&'static str])> = release
        .genesisFacets
        .iter()
        .enumerate()
        .map(|(i, row)| (format!("{label}: genesis facet {i}"), row.facet, FACETS))
        .collect();
    named.push((
        format!("{label}: diamondInit"),
        release.diamondInit,
        DIAMOND_INIT,
    ));
    named.push((
        format!("{label}: genesisUpgrade"),
        release.genesisUpgrade,
        GENESIS_UPGRADE,
    ));
    for (member_label, address, admitted) in named {
        let Some(identified) =
            expect_code_identity(provider, build, result, &member_label, address, admitted).await?
        else {
            continue;
        };
        expect_member_construction(
            provider,
            build,
            result,
            members,
            Member {
                label: &member_label,
                address,
                admitted,
                identified,
                carried_over: departing.carries(address),
                new_because: &departing.new_because(),
                context: ArgContext::None,
            },
        )
        .await?;
    }
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
        verify_verifier_tree(
            provider,
            build,
            result,
            members,
            departing,
            &verifier_label,
            release.verifier,
        )
        .await?;
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
    departing: &DepartingMembers,
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

/// One verifier of a walked tree, for its construction check.
struct VerifierNode {
    label: String,
    address: Address,
    admitted: &'static [&'static str],
    identified: &'static str,
    /// What carries it over: the departing side names it, or a carried-over verifier names it.
    carried_over: Option<String>,
    /// The sub-verifiers read through its getters.
    subs: Vec<(SubVerifierGetter, Address)>,
}

/// Holds a verifier and every sub-verifier it names, depth first, against the reviewed build —
/// each node's code, then the construction of each node `departing` does not carry over. A node a
/// carried-over verifier names is carried over with it, and so is a node without a record that a
/// departing verifier's tree names ([`DepartingMembers::names_sub_verifier`]).
///
/// Reads, per verifier: its code, then the getter of each sub-verifier its identified contract
/// declares (and a pinned backend's code right after its getter); after the walk, the departing
/// verifiers' trees, once, if some new node has no record.
pub(super) async fn verify_verifier_tree<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    members: &MemberReview<'_>,
    departing: &DepartingMembers,
    label: &str,
    verifier: Address,
) -> anyhow::Result<()> {
    let mut pending = vec![(
        label.to_string(),
        verifier,
        VERIFIERS,
        departing.carries(verifier),
    )];
    let mut nodes = Vec::new();
    while let Some((label, address, admitted, carried_over)) = pending.pop() {
        let Some(identified) =
            expect_code_identity(provider, build, result, &label, address, admitted).await?
        else {
            continue;
        };
        let view = VerifierTreeView::new(address, provider);
        // Pushed in reverse so the report reads in declaration order.
        let mut children = Vec::new();
        let mut subs = Vec::new();
        for (getter, kind) in sub_verifiers(identified) {
            let what = format!("{label}'s {}()", getter.name());
            let read = read_sub_verifier(&view, *getter).await;
            let Some(sub) = tolerate(read, result, &what) else {
                continue;
            };
            subs.push((*getter, sub));
            let sub_label = format!("{label} -> {}", getter.name());
            match kind {
                SubVerifierKind::Reviewed(admitted) => children.push((
                    sub_label,
                    sub,
                    *admitted,
                    departing.carries(sub).or_else(|| {
                        carried_over
                            .as_ref()
                            .map(|source| format!("{source}, through the verifier {address}"))
                    }),
                )),
                SubVerifierKind::PinnedBackend => {
                    judge_zisk_backend(provider, build, result, &sub_label, sub).await?
                }
            }
        }
        nodes.push(VerifierNode {
            label,
            address,
            admitted,
            identified,
            carried_over,
            subs,
        });
        pending.extend(children.into_iter().rev());
    }
    let new_because = departing.new_because();
    for node in nodes {
        let carried_over = match node.carried_over {
            Some(source) => Some(source),
            None if !members.has_record(node.address)
                && departing
                    .names_sub_verifier(provider, build, node.address)
                    .await =>
            {
                Some(format!("{}'s verifier tree", departing.source))
            }
            None => None,
        };
        expect_member_construction(
            provider,
            build,
            result,
            members,
            Member {
                label: &node.label,
                address: node.address,
                admitted: node.admitted,
                identified: node.identified,
                carried_over,
                new_because: &new_because,
                context: ArgContext::SubVerifiers(&node.subs),
            },
        )
        .await?;
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
/// migration's — against the reviewed build: the engine's and the composer's code and
/// construction (the prepare deploys both, so neither is carried over), and the L2 bytecodes.
#[allow(clippy::too_many_arguments)]
pub(super) async fn verify_engine_and_l2_plan<P: Provider>(
    provider: &P,
    build: &ReviewedBuild,
    result: &mut VerificationResult,
    members: &MemberReview<'_>,
    label: &str,
    engine: Address,
    engines: &'static [&'static str],
    plan: &AuthoredL2Plan,
) -> anyhow::Result<()> {
    let mut named = vec![(
        format!("{label}: upgradeEngine"),
        engine,
        engines,
        "the prepare deploys the engine its object pins",
    )];
    if !plan.delegateComposer.is_zero() {
        named.push((
            format!("{label}: l2Plan.delegateComposer"),
            plan.delegateComposer,
            DELEGATE_COMPOSERS,
            "the prepare deploys the composer its plan names",
        ));
    }
    for (member_label, address, admitted, new_because) in named {
        let Some(identified) =
            expect_code_identity(provider, build, result, &member_label, address, admitted).await?
        else {
            continue;
        };
        expect_member_construction(
            provider,
            build,
            result,
            members,
            Member {
                label: &member_label,
                address,
                admitted,
                identified,
                carried_over: None,
                new_because,
                context: ArgContext::None,
            },
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
    /// `deployUsedUpgradeContract`). The bootstrap engine and the composer were deployed by the v35
    /// bootstrap prepare (`CTMUpgrade_v35`), retired in v36.
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

    // ───────────────────────── review fixtures ─────────────────────────

    use super::super::construction::{canonical_create2_address, DETERMINISTIC_CREATE2_FACTORY};
    use super::super::external_backends::ZiskBackendPins;
    use super::super::member_construction::ReviewedEnv;
    use crate::common::forge::scripts::member_deployments::{
        MemberDeploymentRecord, MemberDeployments,
    };
    use alloy::primitives::{U256, U64};

    const SALT: B256 = B256::repeat_byte(0x5A);
    const CHAIN_ID: u64 = 1;

    /// The creation code the test builds hold for `name`: distinct per contract, so two
    /// argument-free members never derive one address.
    fn creation(name: &str) -> Vec<u8> {
        format!("the creation code of {name}").into_bytes()
    }

    /// The record of `contract` built from `args` under [`SALT`], and where it lands.
    fn recorded(contract: &str, args: Vec<u8>) -> (Address, MemberDeploymentRecord) {
        let address = canonical_create2_address(SALT, &creation(contract), &args);
        (
            address,
            MemberDeploymentRecord {
                contract: contract.to_string(),
                create2_factory: DETERMINISTIC_CREATE2_FACTORY,
                create2_salt: SALT,
                constructor_args: Bytes::from(args),
            },
        )
    }

    /// The departing side naming `members`, with `verifiers` in force among them.
    fn departing(members: &[Address], verifiers: &[Address]) -> DepartingMembers {
        DepartingMembers {
            source: "the departing release".to_string(),
            members: members.iter().chain(verifiers).copied().collect(),
            verifiers: verifiers.iter().copied().collect(),
            sub_verifiers: RefCell::new(None),
        }
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
                    creation("ZKsyncOSTestnetVerifier"),
                    artifact,
                    vec![PLONK_IMMUTABLE],
                ),
                (
                    "ZKsyncOSVerifierPlonk.sol",
                    "ZKsyncOSVerifierPlonk",
                    creation("ZKsyncOSVerifierPlonk"),
                    PLONK_RUNTIME.to_vec(),
                    Vec::new(),
                ),
            ],
        )
        .with_constructor("ZKsyncOSTestnetVerifier", &[("_plonkVerifier", "address")])
    }

    /// Drives the tree over a mocked transport, in the order it reads: the verifier's code, its
    /// `PLONK_VERIFIER()`, then the Plonk verifier's code. The departing side names the verifier,
    /// so this is about code identity alone.
    async fn walk(plonk_code: &[u8]) -> VerificationResult {
        let verifier = Address::repeat_byte(0x77);
        let plonk = Address::repeat_byte(0x9A);
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from(testnet_verifier_runtime(plonk)));
        asserter.push_success(&Bytes::from(plonk.abi_encode()));
        asserter.push_success(&Bytes::copy_from_slice(plonk_code));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let (records, env) = (MemberDeployments::new(), ReviewedEnv::default());
        verify_verifier_tree(
            &provider,
            &tree_build(),
            &mut result,
            &MemberReview::new(&records, &env, None, None),
            &departing(&[verifier], &[]),
            "the verifier",
            verifier,
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

    /// The ZiSK backend is held to its pin, never passed as reviewed code.
    #[test]
    fn the_zisk_backend_is_pinned() {
        assert!(matches!(
            sub_verifiers("ZiskVerifier"),
            [(SubVerifierGetter::Plonk, SubVerifierKind::PinnedBackend)]
        ));
        assert!(sub_verifiers("ZKsyncOSVerifierPlonk").is_empty());
    }

    // ───────────────────────── the ZiSK backend, through the walk ─────────────────────────

    const PINNED_BACKEND: &[u8] = b"the pinned snarkJS Plonk backend runtime";

    /// A runtime: `tag`, then each immutable as a word.
    fn tagged(tag: &[u8], immutables: &[Address]) -> Vec<u8> {
        let mut code = tag.to_vec();
        for immutable in immutables {
            code.extend_from_slice(&immutable.into_word()[..]);
        }
        code
    }

    /// The reviewed artifact of `name`, whose runtime is `tag` followed by `slots` immutables.
    fn tagged_artifact(
        name: &'static str,
        tag: &[u8],
        slots: usize,
    ) -> super::super::construction::TestArtifact {
        let ranges = (0..slots)
            .map(|i| tag.len() + 32 * i..tag.len() + 32 * (i + 1))
            .collect();
        (
            name,
            name,
            creation(name),
            tagged(tag, &vec![Address::ZERO; slots]),
            ranges,
        )
    }

    /// A multi-proof tree: `MultiProofVerifier` over a ZKsync OS testnet verifier (over its Plonk
    /// verifier) and a `ZiskVerifier` (over its pinned backend).
    fn zisk_build(pins: Result<ZiskBackendPins, String>) -> ReviewedBuild {
        ReviewedBuild::from_artifacts(
            CodeIdentity::empty(),
            vec![
                tagged_artifact("MultiProofVerifier", b"MULTI", 2),
                tagged_artifact("ZKsyncOSTestnetVerifier", b"TESTNET", 1),
                tagged_artifact("ZKsyncOSVerifierPlonk", b"PLONK", 0),
                tagged_artifact("ZiskVerifier", b"ZISK", 1),
            ],
        )
        .with_zisk_backends(pins)
    }

    /// Walks the multi-proof tree to the backend running `backend`, in read order: the root's
    /// code and its two getters, the Airbender side (code, `PLONK_VERIFIER()`, the Plonk code),
    /// then the ZiSK side (code, `PLONK_VERIFIER()`, the backend's code). The departing side names
    /// the root, so this is about the backend alone.
    async fn walk_to_the_zisk_backend(
        backend: &[u8],
        pins: Result<ZiskBackendPins, String>,
    ) -> VerificationResult {
        let [root, airbender, plonk, zisk, backend_at] =
            [0x10, 0x11, 0x12, 0x13, 0x14].map(Address::repeat_byte);
        let asserter = Asserter::new();
        for answer in [
            tagged(b"MULTI", &[airbender, zisk]),
            airbender.abi_encode(),
            zisk.abi_encode(),
            tagged(b"TESTNET", &[plonk]),
            plonk.abi_encode(),
            tagged(b"PLONK", &[]),
            tagged(b"ZISK", &[backend_at]),
            backend_at.abi_encode(),
            backend.to_vec(),
        ] {
            asserter.push_success(&Bytes::from(answer));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let (records, env) = (MemberDeployments::new(), ReviewedEnv::default());
        verify_verifier_tree(
            &provider,
            &zisk_build(pins),
            &mut result,
            &MemberReview::new(&records, &env, None, None),
            &departing(&[root], &[]),
            "the verifier",
            root,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty(), "every level was read");
        result
    }

    /// The backend `ZiskVerifier.PLONK_VERIFIER()` names must run a pinned runtime: anything
    /// else — other code, no code, no applicable pin, unreadable pins — fails exactly once.
    #[tokio::test]
    async fn the_walk_holds_the_zisk_backend_to_its_pin() {
        let pinned = || Ok(ZiskBackendPins::of(&[PINNED_BACKEND]));
        let result = walk_to_the_zisk_backend(PINNED_BACKEND, pinned()).await;
        assert_eq!(
            (result.errors, result.warnings),
            (0, 0),
            "{:?}",
            result.error_messages
        );
        for (backend, pins, needle) in [
            (
                b"a Plonk verifier that accepts anything".as_slice(),
                pinned(),
                "which is not the pinned ZiSK Plonk backend",
            ),
            (b"".as_slice(), pinned(), "has NO code"),
            (PINNED_BACKEND, Ok(ZiskBackendPins::of(&[])), "pins none"),
            (
                PINNED_BACKEND,
                Err("cannot read the pins".to_string()),
                "pins cannot be read",
            ),
        ] {
            let result = walk_to_the_zisk_backend(backend, pins).await;
            assert_eq!(result.errors, 1, "{needle}: {:?}", result.error_messages);
            assert!(result.has_error(needle), "{:?}", result.error_messages);
        }
    }

    // ───────────────────────── a release's L1 members ─────────────────────────
    //
    // One release naming one facet, DiamondInit, its genesis upgrade and a testnet verifier over
    // its Plonk verifier, driven through `verify_release_members` over a mocked transport. The
    // answers are queued in the order the members are read: the facet, DiamondInit, the genesis
    // upgrade, then the verifier tree (with one more read of the verifier's code first when it is
    // a departing verifier). The identity tests let the departing side name every member, so no
    // construction record is needed.

    const FACET: Address = Address::repeat_byte(0xF0);
    const DIAMOND: Address = Address::repeat_byte(0xD0);
    const GENESIS: Address = Address::repeat_byte(0x6E);
    const VERIFIER: Address = Address::repeat_byte(0x77);
    const PLONK: Address = Address::repeat_byte(0x9A);
    /// The members [`release`] names besides its verifier tree.
    const RELEASE_MEMBERS: [Address; 3] = [FACET, DIAMOND, GENESIS];
    /// Where [`admin_runtime`] holds its one immutable.
    const ADMIN_IMMUTABLE: std::ops::Range<usize> = 5..37;
    const DIAMOND_INIT_RUNTIME: &[u8] = b"the reviewed DiamondInit runtime";
    const GENESIS_UPGRADE_RUNTIME: &[u8] = b"the reviewed L1GenesisUpgrade runtime";
    const DEFAULT_UPGRADE_RUNTIME: &[u8] = b"the reviewed DefaultUpgrade runtime";
    const BOOTSTRAP_UPGRADE_RUNTIME: &[u8] = b"the reviewed BootstrapUpgrade runtime";
    const COMPOSER_RUNTIME: &[u8] = b"the reviewed L2DefaultDelegateCalldataComposer runtime";
    const COMMITTER_RUNTIME: &[u8] = b"the reviewed CommitterFacet runtime";
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
            (file, name, creation(name), runtime.to_vec(), Vec::new())
        };
        ReviewedBuild::from_artifacts(
            CodeIdentity::empty()
                .with_bytecode_info("l1-contracts/L2DefaultUpgrade", DELEGATE_INFO)
                .with_bytecode_info("l1-contracts/L2Bridgehub", OTHER_INFO),
            vec![
                (
                    "Admin.sol",
                    "AdminFacet",
                    creation("AdminFacet"),
                    admin_runtime(0),
                    vec![ADMIN_IMMUTABLE],
                ),
                artifact("Committer.sol", "CommitterFacet", COMMITTER_RUNTIME),
                artifact("DiamondInit.sol", "DiamondInit", DIAMOND_INIT_RUNTIME),
                artifact(
                    "L1GenesisUpgrade.sol",
                    "L1GenesisUpgrade",
                    GENESIS_UPGRADE_RUNTIME,
                ),
                (
                    "ZKsyncOSTestnetVerifier.sol",
                    "ZKsyncOSTestnetVerifier",
                    creation("ZKsyncOSTestnetVerifier"),
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
        .with_constructor("CommitterFacet", &[("_l1ChainId", "uint256")])
        .with_constructor("ZKsyncOSTestnetVerifier", &[("_plonkVerifier", "address")])
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

    /// Holds `release` to the build over `answers`, with `records` and `departing`.
    async fn run_release_with(
        release: &ReleaseManifest,
        answers: Vec<Vec<u8>>,
        records: &MemberDeployments,
        departing: DepartingMembers,
    ) -> VerificationResult {
        let asserter = Asserter::new();
        for answer in answers {
            asserter.push_success(&Bytes::from(answer));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let env = ReviewedEnv::default();
        verify_release_members(
            &provider,
            &member_build(),
            &mut result,
            &MemberReview::new(records, &env, None, None),
            "the release",
            release,
            &departing,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty(), "every member was read");
        result
    }

    async fn run_release(answers: Vec<Vec<u8>>, departing: DepartingMembers) -> VerificationResult {
        run_release_with(&release(), answers, &MemberDeployments::new(), departing).await
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
            departing(&[FACET, DIAMOND, GENESIS, VERIFIER], &[]),
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
            let result = run_release(
                answers,
                departing(&[FACET, DIAMOND, GENESIS, VERIFIER], &[]),
            )
            .await;
            assert_eq!(result.errors, 1);
            assert!(result.ensure_success().is_err());
        }
    }

    /// The verifier already in force where the upgrade departs from is carried over, even when
    /// this build does not produce it, and its tree is not walked: the upgrade does not change it.
    #[tokio::test]
    async fn the_departing_verifier_is_carried_over() {
        let result = run_release(
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                vec![UNKNOWN_RUNTIME.to_vec()],
            ),
            departing(&RELEASE_MEMBERS, &[VERIFIER]),
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
            departing(&RELEASE_MEMBERS, &[VERIFIER]),
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
            departing(&RELEASE_MEMBERS, &[Address::repeat_byte(0x78)]),
        )
        .await;
        assert_eq!(result.errors, 1);
    }

    // ───────────────────────── construction records ─────────────────────────

    /// Every member of [`new_release`].
    const EVERY_MEMBER: [&str; 5] = [
        "CommitterFacet",
        "DiamondInit",
        "L1GenesisUpgrade",
        "ZKsyncOSTestnetVerifier",
        "ZKsyncOSVerifierPlonk",
    ];

    /// A release every member of which is new — a `CommitterFacet` built for `facet_chain_id`,
    /// DiamondInit, the genesis upgrade and a testnet verifier over its Plonk verifier, each at
    /// the address its record derives — with the records of the members `recorded_members`
    /// names, and the Plonk verifier's address.
    fn new_release(
        facet_chain_id: u64,
        recorded_members: &[&str],
    ) -> (ReleaseManifest, MemberDeployments, Address) {
        let (facet, facet_record) =
            recorded("CommitterFacet", U256::from(facet_chain_id).abi_encode());
        let (diamond, diamond_record) = recorded("DiamondInit", Vec::new());
        let (genesis, genesis_record) = recorded("L1GenesisUpgrade", Vec::new());
        let (plonk, plonk_record) = recorded("ZKsyncOSVerifierPlonk", Vec::new());
        let (verifier, verifier_record) = recorded("ZKsyncOSTestnetVerifier", plonk.abi_encode());
        let mut release = release_with_table(Vec::new(), Bytes::new());
        release.genesisFacets = vec![GenesisFacet {
            facet,
            isFreezable: false,
        }];
        release.diamondInit = diamond;
        release.genesisUpgrade = genesis;
        release.verifier = verifier;
        let records = [
            (facet, facet_record),
            (diamond, diamond_record),
            (genesis, genesis_record),
            (verifier, verifier_record),
            (plonk, plonk_record),
        ]
        .into_iter()
        .filter(|(_, record)| recorded_members.contains(&record.contract.as_str()))
        .collect();
        (release, records, plonk)
    }

    /// Holds [`new_release`] to its records end to end, reading in order: the facet's code and
    /// (when it is recorded) the chain id its argument is held against, DiamondInit's and the
    /// genesis upgrade's code, then the verifier tree.
    async fn run_new_release(facet_chain_id: u64, recorded_members: &[&str]) -> VerificationResult {
        let (release, records, plonk) = new_release(facet_chain_id, recorded_members);
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(COMMITTER_RUNTIME));
        if recorded_members.contains(&"CommitterFacet") {
            asserter.push_success(&U64::from(CHAIN_ID));
        }
        for answer in [
            DIAMOND_INIT_RUNTIME.to_vec(),
            GENESIS_UPGRADE_RUNTIME.to_vec(),
            testnet_verifier_runtime(plonk),
            plonk.abi_encode(),
            PLONK_RUNTIME.to_vec(),
        ] {
            asserter.push_success(&Bytes::from(answer));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let env = ReviewedEnv::default();
        verify_release_members(
            &provider,
            &member_build(),
            &mut result,
            &MemberReview::new(&records, &env, None, None),
            "the release",
            &release,
            &DepartingMembers::default(),
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty(), "every member was read");
        result
    }

    /// A release whose members the package newly installs is held to their records end to end:
    /// every member re-derives and every argument holds, and a wrong value or a missing record
    /// fails exactly that member.
    #[tokio::test]
    async fn a_new_release_member_is_held_to_its_record() {
        let result = run_new_release(CHAIN_ID, &EVERY_MEMBER).await;
        assert_eq!(
            (result.errors, result.warnings),
            (0, 0),
            "{:?}",
            result.error_messages
        );

        // A facet built, and faithfully recorded, for another chain: it re-derives, and its one
        // argument does not hold.
        let result = run_new_release(5, &EVERY_MEMBER).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("CommitterFacet._l1ChainId is 5, but the L1's chain id is 1"));

        // A new DiamondInit the package does not record.
        let result = run_new_release(
            CHAIN_ID,
            &[
                "CommitterFacet",
                "L1GenesisUpgrade",
                "ZKsyncOSTestnetVerifier",
                "ZKsyncOSVerifierPlonk",
            ],
        )
        .await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("diamondInit at"));
        assert!(result.has_error("records no construction for it"));
    }

    /// A member the departing release names is carried over without a record: its manifest is
    /// read off the departing release. Without it, the same members are new and unrecorded.
    #[tokio::test]
    async fn a_member_of_the_departing_release_is_carried_over() {
        const FROM_RELEASE: Address = Address::repeat_byte(0xF1);
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from(release().abi_encode()));
        for answer in release_answers(
            admin_runtime(0x42),
            DIAMOND_INIT_RUNTIME,
            GENESIS_UPGRADE_RUNTIME,
            // The departing verifier is reviewed code: read for the carry-over, then walked.
            [vec![testnet_verifier_runtime(PLONK)], reviewed_verifier()].concat(),
        ) {
            asserter.push_success(&Bytes::from(answer));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let departing = DepartingMembers::of_release(&provider, &mut result, FROM_RELEASE).await;
        let (records, env) = (MemberDeployments::new(), ReviewedEnv::default());
        verify_release_members(
            &provider,
            &member_build(),
            &mut result,
            &MemberReview::new(&records, &env, None, None),
            "the release",
            &release(),
            &departing,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty());
        assert_eq!(
            (result.errors, result.warnings),
            (0, 0),
            "{:?}",
            result.error_messages
        );

        let result = run_release(
            release_answers(
                admin_runtime(0x42),
                DIAMOND_INIT_RUNTIME,
                GENESIS_UPGRADE_RUNTIME,
                reviewed_verifier(),
            ),
            DepartingMembers::default(),
        )
        .await;
        assert_eq!(result.errors, 5, "{:?}", result.error_messages);
        assert_eq!(
            result
                .error_messages
                .iter()
                .filter(|e| e.contains("records no construction for it"))
                .count(),
            5
        );
    }

    /// A new verifier may reuse a sub-verifier the departing verifier's tree names: that one is
    /// carried over without a record, read off the departing tree only because it has none. A
    /// sub-verifier the departing tree does not name gets no such pass.
    #[tokio::test]
    async fn a_sub_verifier_of_the_departing_verifier_is_carried_over() {
        const DEPARTING_VERIFIER: Address = Address::repeat_byte(0x76);
        let run = |departing_plonk: Address| async move {
            let (verifier, verifier_record) =
                recorded("ZKsyncOSTestnetVerifier", PLONK.abi_encode());
            let records: MemberDeployments = [(verifier, verifier_record)].into_iter().collect();
            let asserter = Asserter::new();
            for answer in [
                // The new verifier's tree.
                testnet_verifier_runtime(PLONK),
                PLONK.abi_encode(),
                PLONK_RUNTIME.to_vec(),
                // The departing verifier's tree, read because the Plonk verifier has no record.
                testnet_verifier_runtime(departing_plonk),
                departing_plonk.abi_encode(),
                PLONK_RUNTIME.to_vec(),
            ] {
                asserter.push_success(&Bytes::from(answer));
            }
            let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
            let mut result = VerificationResult::default();
            let env = ReviewedEnv::default();
            verify_verifier_tree(
                &provider,
                &member_build(),
                &mut result,
                &MemberReview::new(&records, &env, None, None),
                &DepartingMembers::verifiers_in_force(
                    "the verifier the chains run",
                    [DEPARTING_VERIFIER].into_iter().collect(),
                ),
                "the verifier",
                verifier,
            )
            .await
            .unwrap();
            assert!(asserter.read_q().is_empty());
            result
        };
        let result = run(PLONK).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
        let result = run(Address::repeat_byte(0x9B)).await;
        assert_eq!(result.errors, 1, "{:?}", result.error_messages);
        assert!(result.has_error("-> PLONK_VERIFIER at"));
    }

    // ───────────────────────── engines and authored L2 plans ─────────────────────────

    fn plan(composer: Address, delegate: Bytes, extras: Vec<Bytes>) -> AuthoredL2Plan {
        AuthoredL2Plan {
            delegateBytecodeInfo: delegate,
            extraBytecodeInfos: extras,
            delegateComposer: composer,
        }
    }

    /// Where the prepare deploys `contract` (no constructor arguments) under [`SALT`].
    fn deployed_at(contract: &str) -> Address {
        recorded(contract, Vec::new()).0
    }

    fn composer() -> Address {
        deployed_at("L2DefaultDelegateCalldataComposer")
    }

    /// The records of every engine and of the composer.
    fn engine_records() -> MemberDeployments {
        [
            "DefaultUpgrade",
            "BootstrapUpgrade",
            "L2DefaultDelegateCalldataComposer",
        ]
        .into_iter()
        .map(|contract| recorded(contract, Vec::new()))
        .collect()
    }

    /// The engine's code, then the composer's when the plan names one. The engine sits where the
    /// prepare deploys the first contract `engines` admits.
    async fn run_engine_with(
        answers: &[&[u8]],
        engines: &'static [&'static str],
        plan: &AuthoredL2Plan,
        records: &MemberDeployments,
    ) -> VerificationResult {
        let asserter = Asserter::new();
        for answer in answers {
            asserter.push_success(&Bytes::copy_from_slice(answer));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut result = VerificationResult::default();
        let env = ReviewedEnv::default();
        verify_engine_and_l2_plan(
            &provider,
            &member_build(),
            &mut result,
            &MemberReview::new(records, &env, None, None),
            "the transition",
            deployed_at(engines[0]),
            engines,
            plan,
        )
        .await
        .unwrap();
        assert!(asserter.read_q().is_empty());
        result
    }

    async fn run_engine(
        answers: &[&[u8]],
        engines: &'static [&'static str],
        plan: &AuthoredL2Plan,
    ) -> VerificationResult {
        run_engine_with(answers, engines, plan, &engine_records()).await
    }

    #[tokio::test]
    async fn a_reviewed_engine_composer_and_plan_pass() {
        let full = plan(
            composer(),
            encoded(DELEGATE_INFO),
            vec![encoded(OTHER_INFO)],
        );
        let result = run_engine(
            &[DEFAULT_UPGRADE_RUNTIME, COMPOSER_RUNTIME],
            TRANSITION_ENGINES,
            &full,
        )
        .await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
        // An L1-only edge: no composer, no delegate — the engine alone is read.
        let empty = plan(Address::ZERO, Bytes::new(), Vec::new());
        let result = run_engine(&[BOOTSTRAP_UPGRADE_RUNTIME], BOOTSTRAP_ENGINES, &empty).await;
        assert_eq!(result.errors, 0, "{:?}", result.error_messages);
    }

    /// The prepare deploys the engine and the composer, so neither is carried over: without a
    /// record each is unverified.
    #[tokio::test]
    async fn an_unrecorded_engine_or_composer_fails() {
        let full = plan(composer(), encoded(DELEGATE_INFO), Vec::new());
        let result = run_engine_with(
            &[DEFAULT_UPGRADE_RUNTIME, COMPOSER_RUNTIME],
            TRANSITION_ENGINES,
            &full,
            &MemberDeployments::new(),
        )
        .await;
        assert_eq!(result.errors, 2, "{:?}", result.error_messages);
        assert!(result.has_error("upgradeEngine at"));
        assert!(result.has_error("l2Plan.delegateComposer at"));
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
            &plan(composer(), encoded(DELEGATE_INFO), Vec::new()),
        )
        .await;
        assert_eq!(result.errors, 1);
        let result = run_engine(
            &[DEFAULT_UPGRADE_RUNTIME, COMPOSER_RUNTIME],
            TRANSITION_ENGINES,
            &plan(composer(), encoded(OTHER_INFO), Vec::new()),
        )
        .await;
        assert_eq!(result.errors, 1);
        let unknown = (B256::repeat_byte(0xEE), 1, B256::repeat_byte(0xEF));
        let result = run_engine(
            &[DEFAULT_UPGRADE_RUNTIME, COMPOSER_RUNTIME],
            TRANSITION_ENGINES,
            &plan(composer(), encoded(DELEGATE_INFO), vec![encoded(unknown)]),
        )
        .await;
        assert_eq!(result.errors, 1);
    }
}
