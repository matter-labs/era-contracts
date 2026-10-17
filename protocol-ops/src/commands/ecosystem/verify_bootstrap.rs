//! `protocol-ops ecosystem verify-bootstrap` (alias `verify-package`) — read-only verification
//! of a v35 registry-driven upgrade package against the live L1 it targets.
//!
//! Handles every kind of package and decides which from its calldata: an UPGRADE whose
//! governance bundle calls the domain executors directly (1..3 legs in canonical order), the
//! one-time BOOTSTRAP edge onto the registry model, and a transition REPLACEMENT forwarded through
//! the CTM executor. The name kept its original spelling
//! because the docs and runbooks that reference it predate the other paths.
//!
//! A registry package's reviewable content is the write-once objects and the authority they land
//! on, so the tool needs only the merged prepare TOML and an L1 RPC: an object's provenance is
//! re-derived from the reviewed creation code and its own manifest rather than reconstructed from
//! a deployment history.

use std::path::PathBuf;

use alloy::primitives::{Address, B256};
use clap::Parser;

use crate::{
    common::logger,
    upgrade_verification::{registry, report::VerificationResult},
};

#[derive(Debug, Clone, Parser)]
pub struct VerifyBootstrapArgs {
    /// The merged prepare TOML produced by `ecosystem upgrade-prepare-all`.
    #[clap(long)]
    pub ecosystem_toml: PathBuf,

    /// L1 RPC URL. Read-only: the verifier makes no transactions.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// The reviewed governance address the upgrade must be driven by — for a bootstrap, the
    /// owner the CTM domain lands on permanently (held against the manifest's); for an upgrade or
    /// a replacement, the owner every executor the package drives must have. Without it a bootstrap's owner is reported but not checked against
    /// the review, and any other package fails — so supply it for any package that will actually
    /// be signed.
    #[clap(long)]
    pub expected_governance_owner: Option<Address>,

    /// A reviewed CREATE2 salt, repeatable. Objects are re-derived from the reviewed creation
    /// code and their own manifests under these salts, which is what proves the audited
    /// CONSTRUCTOR produced them rather than merely that they run audited runtime code. Take
    /// them from the upgrade env's `[contracts] create2_factory_salt` and its
    /// `[create2_factory_salts]` per-CTM entries; packages that record their own are picked up
    /// automatically and these add to them.
    #[clap(long = "create2-salt")]
    pub create2_salts: Vec<B256>,

    /// A file carrying `[upgrade_executors]` records, repeatable: the forge output of `ecosystem
    /// init` / `ctm init` (`DeployL1CoreContracts`, `DeployCTM`) or a merged bootstrap package.
    /// Each executor is re-derived from the salt and ORIGINAL constructor arguments its record
    /// states, so one whose owner moved since its deployment still verifies; an
    /// executor with no record is unverified — an error. Adds to the records the package carries
    /// (a bootstrap package carries its own); two different records of one executor are refused.
    #[clap(long = "executor-record")]
    pub executor_records: Vec<PathBuf>,

    /// The upgrade env (`stage`, `mainnet`, ...) whose reviewed
    /// `upgrade-envs/permanent-values/<env>.toml` the package is held against. Every release the
    /// package installs pins that file's `zk_token_asset_id` in its genesis force deployments, so
    /// a recurring or bootstrap package is refused without it; a replacement installs no release
    /// and does not need it.
    #[clap(long)]
    pub env: Option<String>,

    /// A hashes file in the `AllContractsHashes.json` format to hold the local build and the live
    /// code against, instead of the committed `AllContractsHashes.json`. Only for a harness that
    /// verifies deployments of an uncommitted build (the committed file is regenerated last):
    /// with it, the run reviews the local build rather than a commit, and the report says so. A
    /// review of a package that will be signed uses the default.
    #[clap(long)]
    pub contract_hashes: Option<PathBuf>,
}

pub async fn run(args: VerifyBootstrapArgs) -> anyhow::Result<()> {
    logger::intro();

    let mut result = VerificationResult::default();
    registry::verify(
        &args.ecosystem_toml,
        &args.l1_rpc_url,
        args.expected_governance_owner,
        &args.create2_salts,
        &args.executor_records,
        args.env.as_deref(),
        args.contract_hashes.as_deref(),
        &mut result,
    )
    .await?;

    println!("\n{}", result);
    result.ensure_success()?;
    logger::outro("verify-bootstrap complete: no errors.");
    Ok(())
}
