//! `protocol-ops ecosystem verify-bootstrap` — read-only verification of a v34
//! registry-bootstrap package against the live L1 it targets.
//!
//! Deliberately narrower than `verify-upgrade`: a bootstrap package's reviewable content is
//! the write-once objects and the authority they land on, so the tool needs the merged prepare
//! TOML and an L1 RPC — no gateway RPC, no zk-governance commit, and no transaction log, since
//! provenance is a codehash rather than a CREATE2 history to reconstruct.

use std::path::PathBuf;

use alloy::primitives::Address;
use clap::Parser;

use crate::{
    common::logger,
    upgrade_verification::{verifiers::VerificationResult, versions::v34},
};

#[derive(Debug, Clone, Parser)]
pub struct VerifyBootstrapArgs {
    /// The merged prepare TOML produced by `ecosystem upgrade-prepare-all`.
    #[clap(long)]
    pub ecosystem_toml: PathBuf,

    /// L1 RPC URL. Read-only: the verifier makes no transactions.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// The reviewed governance address the CTM domain must land on. Without it the owner the
    /// edge hands authority to is reported but not checked against the review, so supply it
    /// for any package that will actually be signed.
    #[clap(long)]
    pub expected_governance_owner: Option<Address>,
}

pub async fn run(args: VerifyBootstrapArgs) -> anyhow::Result<()> {
    logger::intro();

    let mut result = VerificationResult::default();
    v34::verify(
        &args.ecosystem_toml,
        &args.l1_rpc_url,
        args.expected_governance_owner,
        &mut result,
    )
    .await?;

    println!("\n{}", result);
    result.ensure_success()?;
    logger::outro("verify-bootstrap complete: no errors.");
    Ok(())
}
