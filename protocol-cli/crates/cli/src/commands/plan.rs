use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

// Use internal crate types or workspace types
use protocol_cli_common::forge::ForgeArgs;
use protocol_cli_types::ScriptContext;
use crate::planner::builder::{ForgeSimulator, PlanBuilder, SimulatedTx};

// --- 1. Define Arguments ---
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct PlanArgs {
    #[clap(long)]
    pub deployer_address: Address,
    #[clap(long)]
    pub governor_address: Address,
    #[clap(long)]
    pub l1_chain_id: u64,
    #[clap(long)]
    pub output_path: PathBuf,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

// --- 2. Concrete Simulator Implementation ---
struct DefaultForgeSimulator;

impl DefaultForgeSimulator {
    fn new() -> Self {
        Self
    }
}

impl ForgeSimulator for DefaultForgeSimulator {
    fn simulate(
        &self,
        _script_path: &str,
        _params_json: &str,
    ) -> Result<(Vec<SimulatedTx>, HashMap<String, Address>)> {
        // TODO: Implement actual `forge script --json` execution and parsing here.
        // This requires running the shell command, parsing `run-latest.json` and the trace.
        Ok((vec![], HashMap::new()))
    }
}

// --- 3. The Run Function ---
pub async fn run(args: PlanArgs, _shell: &xshell::Shell) -> Result<()> {
    // Initialize Builder with the concrete simulator
    // Note: PlanBuilder::new() now takes a generic impl ForgeSimulator, not a Box
    // We clone() needed args to avoid move issues if PlanArgs is needed later
    let mut builder = PlanBuilder::new("1.0.0", DefaultForgeSimulator::new());

    // Register roles for cleaner plan output
    builder.register_role(args.deployer_address, "deployer");
    builder.register_role(args.governor_address, "governor");

    // 1. Prepare Initial Context
    let mut ctx = ScriptContext {
        deployer: args.deployer_address,
        governor: args.governor_address,
        l1_chain_id: args.l1_chain_id,
        // Initially unknown; will be filled by Stage 1 artifacts
        bridgehub_proxy_addr: Address::zero(), 
        // ... other fields ...
        contracts: Default::default(),
        era_chain_id: 0,
        l1_rpc_url: "http://localhost:8545".into(),
    };

    // --- Stage 1: Deploy ---
    // We use the closure to execute the script and capture the artifacts
    let artifacts = builder.add_stage("Deploy Core", |stage| {
        // `ctx` is passed as the params to the script
        let artifacts = stage.add_forge_script("DeployBridgehub.s.sol", &ctx)?;
        Ok(artifacts)
    })?;

    // --- Update Context ---
    // Use artifacts from Stage 1 to update context for Stage 2
    if let Some(addr) = artifacts.get("BridgehubProxy") {
        ctx.bridgehub_proxy_addr = *addr;
    }

    // --- Stage 2: Accept Ownership ---
    builder.add_stage("Accept Ownership", |stage| {
        // Now `ctx` contains the correct bridgehub address
        stage.add_forge_script("AcceptOwnership.s.sol", &ctx)?;
        Ok(())
    })?;

    // 5. Output Final Plan
    // Note: we use clone() on build() inside save_plan or implement save_plan to consume self
    // Assuming we added a helper or just build and serialize manually:
    let plan = builder.build();
    let json = serde_json::to_string_pretty(&plan)?;
    std::fs::write(&args.output_path, json)?;

    Ok(())
}