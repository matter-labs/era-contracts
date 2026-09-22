//! `protocol-ops ecosystem verify-bootstrap` (alias `verify-package`) — read-only verification
//! of a v34 registry-driven upgrade package against the live L1 it targets.
//!
//! Handles both kinds of package and decides which from the package itself: a RECURRING upgrade
//! driven through its coordinator, and the one-time BOOTSTRAP edge onto the registry model. The
//! name kept its original spelling because the docs and runbooks that reference it predate the
//! recurring path.
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
    /// owner the CTM domain lands on permanently (held against the manifest's); for a recurring
    /// upgrade, the owner of the whole lifecycle, and the owner the executors' construction is
    /// re-derived from. Without it a bootstrap's owner is reported but not checked against the
    /// review, and a recurring package's executors are unverifiable — an error — so supply it for
    /// any package that will actually be signed.
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
}

pub async fn run(args: VerifyBootstrapArgs) -> anyhow::Result<()> {
    logger::intro();

    let mut result = VerificationResult::default();
    registry::verify(
        &args.ecosystem_toml,
        &args.l1_rpc_url,
        args.expected_governance_owner,
        &args.create2_salts,
        &mut result,
    )
    .await?;

    println!("\n{}", result);
    result.ensure_success()?;
    logger::outro("verify-bootstrap complete: no errors.");
    Ok(())
}
