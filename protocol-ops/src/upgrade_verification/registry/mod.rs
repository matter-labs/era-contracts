//! Verification of a registry-driven upgrade package, for ANY release.
//!
//! # Why this is not named for a version
//!
//! The pre-registry verifier had one module per release, because the reviewable artifact WAS the
//! calldata: every release produced different calls, so every release needed its own re-derivation
//! of them. A registry-driven package inverts that. Governance signs one call naming one
//! write-once object, and everything executable is derived on-chain from that object at execution
//! time. What a reviewer checks is therefore the same for v36 as for v37 — the objects, and that
//! the signed transaction invokes them — so there is one verifier, not one per release.
//!
//! The single exception is the one-time BOOTSTRAP edge ([`bootstrap`]), and it is an exception
//! because it happens exactly once: it is how a CTM that predates the registry model enters it.
//! Every upgrade after it is an ordinary operation ([`operation`]). Repairing a committed
//! transition is not an upgrade but a CTM owner operation, and has its own path ([`replacement`]).
//!
//! # What it asks
//!
//!   1. Was every object PRODUCED by the reviewed code's constructor from its reviewed
//!      arguments? ([`construction`]) — the manifest a write-once object serves, an executor's
//!      deploy-time record ([`lifecycle`]), or the migration and core transition the bootstrap
//!      sequence was built over. The question a runtime codehash cannot answer, and
//!      the reason the chain no longer pretends to answer it. Every object a package names gets
//!      this check, on every path.
//!   2. Does every object, and every MEMBER an object names, run the code the reviewed build
//!      produces for its role? ([`provenance`], [`members`]) — the live code against the
//!      reviewed artifact, byte for byte outside its immutable slots: each release's facets,
//!      `DiamondInit`, genesis upgrade and verifier tree, each L2 bytecode the release's table or
//!      a plan names, each engine and composer, each row's `implNew`.
//!   3. Does every proxy row name the proxy of its slot, discovered on chain from the
//!      Bridgehub or the CTM? ([`rows`])
//!   4. Does every release the package installs pin the reviewed genesis — the genesis config's
//!      root and the force deployments the prepare wrote? ([`genesis`])
//!   5. Is authority bound where the review says, and to the expected governance owner — with
//!      no nomination outstanding on any authority the upgrade drives?
//!   6. Does every proxy row depart from the implementation that is actually live, read through
//!      its domain's `ProxyAdmin`? ([`rows`]) A pre-execution check only — completion does not
//!      re-read implementations (`protocol-docs/ecosystem-upgrade-coordination.md`).
//!   7. Do chains crossing an edge keep the system-proxy logic new chains get? ([`shell`])
//!   8. Does the transaction governance signs invoke the reviewed upgrade, at the reviewed
//!      address — and nothing else?
//!
//! None of it is "does an object's own fingerprint of a member match that member's code": the
//! manifest author supplies both halves of such a pair, so it can only ever agree with itself.
//! Every comparison here is against the reviewed commit, the reviewed inputs, or live state the
//! package does not control — and a construction is re-derived from the REVIEWED values or the
//! deploying run's record, never from what the object answers (a genuine executor built for an
//! attacker's owner answers every getter like the reviewed one).
//!
//! # What it deliberately does not do
//!
//! It does not re-derive facet cuts, L2 transactions or proposals. Those are derived on-chain
//! from the release pair, and `TransitionDerivationLib` is audited code — re-deriving them here
//! would be a second implementation to keep in sync, which is exactly what the registry model
//! set out to remove. It also does not call the objects' own `validate()`: that runs against
//! post-execution state, so beforehand it reverts by design and tells a reviewer nothing.

use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;

use crate::common::env_config::EnvConfig;
use crate::common::ethereum::get_provider;
use crate::upgrade_verification::contract_hashes::contract_hashes_path;
use crate::upgrade_verification::report::VerificationResult;

pub(crate) mod bootstrap;
pub(crate) mod construction;
pub(crate) mod genesis;
pub(crate) mod lifecycle;
pub(crate) mod members;
pub(crate) mod operation;
pub(crate) mod package;
pub(crate) mod provenance;
pub(crate) mod records;
pub(crate) mod replacement;
pub(crate) mod rows;
pub(crate) mod shell;
pub(crate) mod views;

use construction::ReviewedBuild;
use genesis::{ExpectedForceDeployments, ReviewedGenesis};
use package::RegistryPackage;
use provenance::CodeIdentity;
use views::CommittedUpgradeView;

/// Verify a registry-driven upgrade package against the live L1 it targets.
///
/// The package's own content decides which verifier runs — a recurring operation, a bootstrap
/// edge or a transition replacement (see [`RegistryPackage::load`]); a package that is none of
/// them is refused rather than verified as the nearest match.
///
/// `expected_governance_owner` is the reviewed address the upgrade must be driven by. For a
/// bootstrap that is the owner the CTM domain lands on permanently; otherwise it is the owner of
/// the whole lifecycle. `executor_records` are files whose `[upgrade_executors]` records add to
/// the package's own ([`records`]). `env` names the upgrade env whose permanent values hold the
/// reviewed ZK token asset id an installed release's force deployments are held against
/// ([`genesis`]); a replacement installs no release and does not need it. `contract_hashes`
/// replaces the committed `AllContractsHashes.json` the build is held against (see the
/// `--contract-hashes` help).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn verify(
    ecosystem_toml: &std::path::Path,
    l1_rpc_url: &str,
    expected_governance_owner: Option<Address>,
    extra_create2_salts: &[B256],
    executor_records: &[std::path::PathBuf],
    env: Option<&str>,
    contract_hashes: Option<&std::path::Path>,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    let provider = get_provider(l1_rpc_url)?;
    let hashes_path = contract_hashes_path(contract_hashes);
    let identity = CodeIdentity::from_hashes_file(&hashes_path)?;
    if contract_hashes.is_some() {
        result.report_warn(&format!(
            "code identity is held against {}, not the committed AllContractsHashes.json: this run \
             reviews the local build, not a commit",
            hashes_path.display()
        ));
    }
    let build = ReviewedBuild::load(identity);
    let genesis_root = genesis::reviewed_genesis_root();
    let genesis_image = genesis::reviewed_genesis_image();

    let mut package = RegistryPackage::load(ecosystem_toml)?;
    let held = match &mut package {
        RegistryPackage::Operation(p) => &mut p.executor_records,
        RegistryPackage::Bootstrap(p) => &mut p.executor_records,
        RegistryPackage::Replacement(p) => &mut p.executor_records,
    };
    for path in executor_records {
        let records = records::load_record_file(path)?;
        records::merge_records(held, records, &path.display().to_string())?;
    }

    match package {
        RegistryPackage::Replacement(package) => {
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            replacement::verify(
                &provider,
                &build,
                genesis_image.as_ref().ok(),
                &package,
                expected_governance_owner,
                &salts,
                result,
            )
            .await
        }
        RegistryPackage::Operation(package) => {
            let zk_token_asset_id = reviewed_zk_token_asset_id(env)?;
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            let genesis = ReviewedGenesis {
                genesis_root,
                image: genesis_image,
                force_deployments_data: package.force_deployments_data.clone(),
                force_deployments: ExpectedForceDeployments::unread(zk_token_asset_id),
            };
            operation::verify(
                &provider,
                &build,
                &genesis,
                &package,
                expected_governance_owner,
                &salts,
                result,
            )
            .await
        }
        RegistryPackage::Bootstrap(package) => {
            let zk_token_asset_id = reviewed_zk_token_asset_id(env)?;
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            let genesis = ReviewedGenesis {
                genesis_root,
                image: genesis_image,
                force_deployments_data: package.force_deployments_data.clone(),
                force_deployments: ExpectedForceDeployments::unread(zk_token_asset_id),
            };
            bootstrap::verify(
                &provider,
                &build,
                &genesis,
                &package,
                expected_governance_owner,
                &salts,
                result,
            )
            .await
        }
    }
}

/// The ZK token asset id `env`'s reviewed permanent values declare. Required on the paths that
/// install a release, so a missing env or key stops the run before anything is verified.
fn reviewed_zk_token_asset_id(env: Option<&str>) -> anyhow::Result<B256> {
    let env = env.ok_or_else(|| {
        anyhow::anyhow!(
            "this package installs a release whose force deployments pin the ZK token asset id: \
             pass --env <name> to hold it against that upgrade env's permanent-values \
             `zk_token_asset_id`"
        )
    })?;
    EnvConfig::load(env)?.require_zk_token_asset_id()
}

/// The reviewed salts: whatever the package recorded, plus whatever the reviewer supplied,
/// de-duplicated and order-stable so the report names the same salt run after run.
fn merge_salts(from_package: &[B256], from_reviewer: &[B256]) -> Vec<B256> {
    let mut salts: Vec<B256> = Vec::new();
    for salt in from_package.iter().chain(from_reviewer) {
        if !salts.contains(salt) {
            salts.push(*salt);
        }
    }
    salts
}

/// Prints the DERIVED payload an object constructed at its own construction.
///
/// This is the state a counterfeit exists to tamper with — the L2 force deployments and the
/// delegate leg every chain executes — so it is rendered for the reviewer rather than only
/// summarised. Its agreement with the manifest is what [`construction`] establishes; what a human
/// still has to read is whether the payload IS the proposal.
async fn render_derived_payloads<P: Provider>(
    provider: &P,
    result: &mut VerificationResult,
    object: Address,
) {
    let view = CommittedUpgradeView::new(object, provider);
    let Ok(plan) = view.l2Plan().call().await else {
        result.report_error(&format!(
            "the object at {object} does not answer `l2Plan()`: its derived payload cannot be \
             shown, so a reviewer cannot check it against the proposal"
        ));
        return;
    };
    result.print_info(&format!(
        "  derived L2 plan: {} force deployment(s), delegateTo {}, composer {}, {} factory \
         dependency hash(es)",
        plan.deployments.len(),
        plan.delegateTo,
        plan.delegateComposer,
        plan.factoryDepHashes.len()
    ));
    for (i, deployment) in plan.deployments.iter().enumerate() {
        result.print_info(&format!(
            "    deployment {i}: type {} at {} ({} bytes of bytecode info)",
            deployment.upgradeType,
            deployment.newAddress,
            deployment.deployedBytecodeInfo.len()
        ));
    }
}

/// Renders a packed SemVer protocol version the way the upgrade envs and release notes write it.
fn format_semver(packed: U256) -> String {
    // A version wider than the packed encoding is malformed rather than unrepresentable, so it
    // is reported verbatim: panicking would take the whole report down over one bad field.
    let Ok(raw) = TryInto::<u128>::try_into(packed) else {
        return format!("<malformed version {packed}>");
    };
    let major = raw >> 64;
    let minor = (raw >> 32) & 0xffff_ffff;
    let patch = raw & 0xffff_ffff;
    format!("v{major}.{minor}.{patch}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn salts_from_the_package_and_the_reviewer_merge_without_duplicates() {
        let a = B256::repeat_byte(0xAA);
        let b = B256::repeat_byte(0xBB);
        assert_eq!(merge_salts(&[a, b], &[b, a]), vec![a, b]);
        assert_eq!(merge_salts(&[], &[a]), vec![a]);
        assert!(merge_salts(&[], &[]).is_empty());
    }

    /// The paths that install a release cannot run without the env the ZK token is read from.
    #[test]
    fn the_reviewed_zk_token_asset_id_requires_an_env() {
        let message = reviewed_zk_token_asset_id(None).unwrap_err().to_string();
        assert!(message.contains("--env"), "{message}");

        let stage = EnvConfig::load("stage").unwrap();
        assert_eq!(
            reviewed_zk_token_asset_id(Some("stage")).unwrap(),
            stage.require_zk_token_asset_id().unwrap()
        );
        assert!(reviewed_zk_token_asset_id(Some("no-such-env")).is_err());
    }

    #[test]
    fn formats_a_packed_semver() {
        // 0x2200000001 is v0.34.1 in the packed encoding the CTM stores.
        assert_eq!(format_semver(U256::from(0x22_0000_0001u64)), "v0.34.1");
        assert_eq!(format_semver(U256::from(0x22_0000_0000u64)), "v0.34.0");
        assert_eq!(format_semver(U256::from(0x21_0000_0000u64)), "v0.33.0");
    }
}
