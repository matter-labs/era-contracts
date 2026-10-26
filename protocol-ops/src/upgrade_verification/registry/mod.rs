//! Verification of a registry-driven upgrade package, for ANY release.
//!
//! # Why this is not named for a version
//!
//! The pre-registry verifier had one module per release, because the reviewable artifact WAS the
//! calldata: every release produced different calls, so every release needed its own re-derivation
//! of them. A registry-driven package inverts that. Governance signs at most three executor calls,
//! each naming one write-once object, and everything executable is derived on-chain from those
//! objects at execution time. What a reviewer checks is therefore the same for v36 as for v37 —
//! the objects, and that the signed transaction invokes them in canonical order — so there is one
//! verifier, not one per release.
//!
//! The single exception is the one-time BOOTSTRAP edge ([`bootstrap`]), and it is an exception
//! because it happens exactly once: it is how a CTM that predates the registry model enters it.
//! Every upgrade after it is an ordinary one ([`upgrade`]). Repairing a committed transition is not
//! an upgrade but a CTM owner operation, and has its own path ([`replacement`]).
//!
//! # What it asks
//!
//!   1. Was every object PRODUCED by the reviewed code's constructor from its reviewed
//!      arguments? ([`construction`]) — the manifest a write-once object serves (a
//!      `ProxyUpgradeTransition`'s domain included), an executor's deploy-time record
//!      ([`lifecycle`]), or the migration and core transition the bootstrap sequence was built
//!      over. The question a runtime codehash cannot answer, and
//!      the reason the chain no longer pretends to answer it. Every object a package names gets
//!      this check, on every path.
//!   2. Does every object, and every MEMBER an object names, run the code the reviewed build
//!      produces for its role? ([`provenance`], [`members`]) — the live code against the
//!      reviewed artifact, byte for byte outside its immutable slots: each release's facets,
//!      `DiamondInit`, genesis upgrade and verifier tree, each L2 bytecode the release's table or
//!      a plan names, each engine and composer, each row's `implNew`. Was each member the package
//!      newly installs BUILT from argument values the review holds — the values that comparison
//!      masks? ([`member_construction`]) The ZiSK Plonk backend, which no reviewed build
//!      describes, is held to its pin ([`external_backends`]).
//!   3. Does every proxy inventory belong to the domain its leg applies, upgrade something, and
//!      hold only real edges, each naming the proxy of its slot, discovered on chain from the
//!      REVIEWED Bridgehub or a CTM registered on it? ([`rows`], [`ecosystem_binding`])
//!   4. Does every release the package installs pin the reviewed genesis — the genesis config's
//!      root and the force deployments the prepare wrote ([`genesis`]) — and pass its own
//!      `validate()`, which the CTM runs when it installs it?
//!   5. Is authority bound where the review says — the package's Bridgehub, every CTM it drives
//!      and both executors' ProxyAdmins to the reviewed Bridgehub ([`ecosystem_binding`]), each
//!      executor to that CTM and ProxyAdmin — and to the expected governance owner, with no
//!      nomination outstanding on any authority the upgrade drives and the CTM's
//!      ValidatorTimelock still governance's?
//!   6. Does every proxy row depart from the implementation that is actually live, read through
//!      its domain's `ProxyAdmin`? ([`rows`]) A pre-execution check only; what a replayed bundle
//!      leaves behind is checked by `ecosystem upgrade-governance` ([`applied`]).
//!   7. Do chains crossing an edge keep the system-proxy logic new chains get? ([`shell`])
//!   8. Does the transaction governance signs invoke the reviewed upgrade, at the reviewed
//!      addresses, as one contiguous run in canonical order — and are its calls other than the
//!      executor legs exactly the declared external actions? ([`declared_calls`])
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
//! set out to remove. The only object `validate()` it calls is the arriving release's, which
//! reads no live state; the others judge the state at execution, which a review cannot see.

use alloy::primitives::{Address, B256, U256};
use alloy::providers::Provider;

use crate::common::env_config::EnvConfig;
use crate::common::ethereum::get_provider;
use crate::upgrade_verification::contract_hashes::contract_hashes_path;
use crate::upgrade_verification::report::VerificationResult;

pub(crate) mod applied;
pub(crate) mod bootstrap;
pub(crate) mod construction;
mod declared_calls;
pub(crate) mod ecosystem_binding;
pub(crate) mod external_backends;
pub(crate) mod genesis;
#[cfg(test)]
mod keyed_l1;
pub(crate) mod lifecycle;
pub(crate) mod member_construction;
pub(crate) mod members;
pub(crate) mod package;
pub(crate) mod provenance;
pub(crate) mod records;
pub(crate) mod replacement;
pub(crate) mod rows;
pub(crate) mod shell;
#[cfg(test)]
mod shell_path_tests;
pub(crate) mod upgrade;
pub(crate) mod views;

use construction::ReviewedBuild;
use external_backends::ZiskBackendPins;
use genesis::{ExpectedForceDeployments, ReviewedGenesis};
use member_construction::ReviewedEnv;
use package::RegistryPackage;
use provenance::CodeIdentity;
use views::CommittedUpgradeView;

/// Verify a registry-driven upgrade package against the live L1 it targets.
///
/// The package's own calldata decides which verifier runs — an upgrade, a bootstrap edge or a
/// transition replacement (see [`RegistryPackage::load`]); a package that is none of them, or
/// mixes them, is refused rather than verified as the nearest match.
///
/// `expected_governance_owner` is the reviewed address the upgrade must be driven by. For a
/// bootstrap that is the owner the CTM domain lands on permanently; otherwise it is the owner of
/// the whole lifecycle. `executor_records` are files whose `[upgrade_executors]` records add to
/// the package's own ([`records`]). `env` names the upgrade env whose permanent values hold the
/// reviewed Bridgehub every package kind is bound to ([`ecosystem_binding`]) and the reviewed ZK
/// token asset id an installed release's force deployments are held against ([`genesis`]); a
/// replacement, or an upgrade without a transition leg, installs no release and does not need the
/// token. The env's permanent values are also what the members' constructor arguments are held
/// against where they come from the env ([`member_construction`]), and it selects the ZiSK
/// backend pins that apply ([`external_backends`]). `expected_bridgehub` replaces the env's
/// `bridgehub_proxy_addr` as the reviewed Bridgehub; a run naming neither is refused. `contract_hashes`
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
    expected_bridgehub: Option<Address>,
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
    let build = ReviewedBuild::load(identity).with_zisk_backends(ZiskBackendPins::load(env));
    let genesis_root = genesis::reviewed_genesis_root();
    let genesis_image = genesis::reviewed_genesis_image();
    let env_config = env.map(EnvConfig::load).transpose()?;
    let reviewed_env = reviewed_env(env_config.as_ref(), expected_bridgehub, result)?;

    let mut package = RegistryPackage::load(ecosystem_toml)?;
    let held = match &mut package {
        RegistryPackage::Upgrade(p) => &mut p.executor_records,
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
                &reviewed_env,
                result,
            )
            .await
        }
        RegistryPackage::Upgrade(package) => {
            // Only a transition leg installs a release whose force deployments pin the token.
            let zk_token_asset_id = if package.leg(package::LegKind::Transition).is_some() {
                reviewed_zk_token_asset_id(env_config.as_ref())?
            } else {
                B256::ZERO
            };
            let salts = merge_salts(&package.create2_salts, extra_create2_salts);
            let genesis = ReviewedGenesis {
                genesis_root,
                image: genesis_image,
                force_deployments_data: package.force_deployments_data.clone(),
                force_deployments: ExpectedForceDeployments::unread(zk_token_asset_id),
            };
            upgrade::verify(
                &provider,
                &build,
                &genesis,
                &package,
                expected_governance_owner,
                &salts,
                &reviewed_env,
                result,
            )
            .await
        }
        RegistryPackage::Bootstrap(package) => {
            let zk_token_asset_id = reviewed_zk_token_asset_id(env_config.as_ref())?;
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
                &reviewed_env,
                result,
            )
            .await
        }
    }
}

/// The reviewer's inputs ([`ReviewedEnv`]), with the reviewed Bridgehub every package kind is
/// verified against ([`ecosystem_binding`]): `expected_bridgehub` when given — with a warning when
/// it is not the env's — else the env's `bridgehub_proxy_addr`. A run that names neither, or names
/// the zero address, stops here.
fn reviewed_env(
    config: Option<&EnvConfig>,
    expected_bridgehub: Option<Address>,
    result: &mut VerificationResult,
) -> anyhow::Result<ReviewedEnv> {
    if let (Some(expected), Some(config)) = (expected_bridgehub, config) {
        if expected != config.bridgehub() {
            result.report_warn(&format!(
                "--expected-bridgehub {expected} is not env {}'s bridgehub_proxy_addr {}: the flag \
                 is the reviewed Bridgehub, and this run reviews a harness L1, not the env's",
                config.env,
                config.bridgehub()
            ));
        }
    }
    let reviewed = ReviewedEnv::new(config, expected_bridgehub);
    let Some(bridgehub) = reviewed.bridgehub() else {
        anyhow::bail!(
            "a registry package is verified against the ecosystem it targets: pass --env <name> \
             (its permanent-values bridgehub_proxy_addr is the reviewed Bridgehub) or \
             --expected-bridgehub <address>"
        );
    };
    anyhow::ensure!(
        !bridgehub.address.is_zero(),
        "{} is the zero address: there is no reviewed Bridgehub to verify the package against",
        bridgehub.source
    );
    Ok(reviewed)
}

/// The ZK token asset id the reviewed env's permanent values declare. Required on the paths that
/// install a release, so a missing env or key stops the run before anything is verified.
fn reviewed_zk_token_asset_id(env: Option<&EnvConfig>) -> anyhow::Result<B256> {
    let env = env.ok_or_else(|| {
        anyhow::anyhow!(
            "this package installs a release whose force deployments pin the ZK token asset id: \
             pass --env <name> to hold it against that upgrade env's permanent-values \
             `zk_token_asset_id`"
        )
    })?;
    env.require_zk_token_asset_id()
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
            reviewed_zk_token_asset_id(Some(&stage)).unwrap(),
            stage.require_zk_token_asset_id().unwrap()
        );
        assert!(EnvConfig::load("no-such-env").is_err());
    }

    /// Q1/Q2: the reviewed Bridgehub is `--expected-bridgehub`, else the env's; the flag wins
    /// over a different env value with a warning, and a run naming neither, or zero, stops.
    #[test]
    fn the_reviewed_bridgehub_is_the_flag_else_the_envs() {
        let stage = EnvConfig::load("stage").unwrap();
        let other = Address::repeat_byte(0x0B);
        let run = |config: Option<&EnvConfig>, flag: Option<Address>| {
            let mut result = VerificationResult::default();
            let reviewed = reviewed_env(config, flag, &mut result)
                .map(|env| env.bridgehub().map(|b| (b.address, b.source.clone())));
            (reviewed, result)
        };

        let (reviewed, result) = run(None, Some(other));
        assert_eq!(
            reviewed.unwrap(),
            Some((other, "the reviewer's --expected-bridgehub".to_string()))
        );
        assert_eq!((result.errors, result.warnings), (0, 0));

        let (reviewed, result) = run(Some(&stage), None);
        assert_eq!(
            reviewed.unwrap(),
            Some((
                stage.bridgehub(),
                "env stage's bridgehub_proxy_addr".to_string()
            ))
        );
        assert_eq!((result.errors, result.warnings), (0, 0));

        let (reviewed, result) = run(Some(&stage), Some(stage.bridgehub()));
        assert_eq!(reviewed.unwrap().unwrap().0, stage.bridgehub());
        assert_eq!((result.errors, result.warnings), (0, 0));

        let (reviewed, result) = run(Some(&stage), Some(other));
        assert_eq!(reviewed.unwrap().unwrap().0, other, "the flag wins");
        assert_eq!((result.errors, result.warnings), (0, 1));

        let (reviewed, _) = run(None, None);
        let message = reviewed.unwrap_err().to_string();
        assert!(
            message.contains("--env") && message.contains("--expected-bridgehub"),
            "{message}"
        );

        let (reviewed, _) = run(None, Some(Address::ZERO));
        assert!(reviewed.unwrap_err().to_string().contains("zero address"));
    }

    #[test]
    fn formats_a_packed_semver() {
        // 0x2200000001 is v0.34.1 in the packed encoding the CTM stores.
        assert_eq!(format_semver(U256::from(0x22_0000_0001u64)), "v0.34.1");
        assert_eq!(format_semver(U256::from(0x22_0000_0000u64)), "v0.34.0");
        assert_eq!(format_semver(U256::from(0x21_0000_0000u64)), "v0.33.0");
    }
}
