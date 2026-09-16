//! Verification of a registry-driven upgrade package, for ANY release.
//!
//! # Why this is not named for a version
//!
//! The pre-registry verifier had one module per release, because the reviewable artifact WAS the
//! calldata: every release produced different calls, so every release needed its own re-derivation
//! of them. A registry-driven package inverts that. Governance signs three calls naming one
//! write-once object, and everything executable is derived on-chain from that object at execution
//! time. What a reviewer checks is therefore the same for v35 as for v36 — the objects, and that
//! the signed transaction invokes them — so there is one verifier, not one per release.
//!
//! The single exception is the one-time BOOTSTRAP edge ([`bootstrap`]), and it is an exception
//! because it happens exactly once: it is how a CTM that predates the registry model enters it.
//! Every upgrade after it is an ordinary operation ([`operation`]).
//!
//! # What it asks
//!
//!   1. Does every object run the code the reviewed commit produces? ([`provenance`])
//!   2. Was every object PRODUCED by that code's constructor from the manifest it serves?
//!      ([`construction`]) — the question a runtime codehash cannot answer, and the reason the
//!      chain no longer pretends to answer it.
//!   3. Does every contract an object names exist?
//!   4. Is authority bound where the review says, and to the expected governance owner?
//!   5. Does every proxy row depart from the implementation that is actually live?
//!   6. Does the transaction governance signs invoke the reviewed upgrade, at the reviewed
//!      address?
//!
//! None of it is "does an object's own fingerprint of a member match that member's code": the
//! manifest author supplies both halves of such a pair, so it can only ever agree with itself.
//! Every comparison here is against the reviewed commit or against live state the package does
//! not control.
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

use crate::common::ethereum::get_provider;
use crate::upgrade_verification::report::VerificationResult;

pub(crate) mod bootstrap;
pub(crate) mod construction;
pub(crate) mod operation;
pub(crate) mod package;
pub(crate) mod provenance;
pub(crate) mod views;

use construction::ReviewedBuild;
use package::RegistryPackage;
use provenance::CodeIdentity;
use views::CommittedUpgradeView;

/// Verify a registry-driven upgrade package against the live L1 it targets.
///
/// The package's own content decides which verifier runs — a recurring operation or a bootstrap
/// edge (see [`RegistryPackage::load`]); a package that is neither is refused rather than
/// verified as the nearest match.
///
/// `expected_governance_owner` is the reviewed address the upgrade must be driven by. For a
/// bootstrap that is the owner the CTM domain lands on permanently; for a recurring upgrade it is
/// the owner of the whole lifecycle.
pub(crate) async fn verify(
    ecosystem_toml: &std::path::Path,
    l1_rpc_url: &str,
    expected_governance_owner: Option<Address>,
    extra_create2_salts: &[B256],
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    let provider = get_provider(l1_rpc_url)?;
    let identity = CodeIdentity::from_local_hashes()?;
    let build = ReviewedBuild::load(&identity);

    match RegistryPackage::load(ecosystem_toml)? {
        RegistryPackage::Operation(package) => {
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            operation::verify(
                &provider,
                &identity,
                &build,
                &package,
                expected_governance_owner,
                &salts,
                result,
            )
            .await
        }
        RegistryPackage::Bootstrap(package) => {
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            bootstrap::verify(
                &provider,
                &identity,
                &build,
                &package,
                expected_governance_owner,
                &salts,
                result,
            )
            .await
        }
    }
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
/// summarised. Its agreement with the manifest is what the construction check above establishes;
/// what a human still has to read is whether the payload IS the proposal.
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

    #[test]
    fn formats_a_packed_semver() {
        // 0x2200000001 is v0.34.1 in the packed encoding the CTM stores.
        assert_eq!(format_semver(U256::from(0x22_0000_0001u64)), "v0.34.1");
        assert_eq!(format_semver(U256::from(0x22_0000_0000u64)), "v0.34.0");
        assert_eq!(format_semver(U256::from(0x21_0000_0000u64)), "v0.33.0");
    }
}
