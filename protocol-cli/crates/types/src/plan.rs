use serde::{Deserialize, Serialize};
use ethers::types::{Address, Bytes, U256};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Plan {
    pub protocol_version: String,
    pub stages: Vec<Stage>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Stage {
    pub name: String,
    pub description: Option<String>,
    pub steps: Vec<Step>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type")]
pub enum Step {
    Transaction(TransactionStep),
    // Wrapper for a logical group of txs from a script
    ScriptGroup { name: String, steps: Vec<Step> },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TransactionStep {
    pub id: String,
    pub description: String, // "Approve BridgeHub"
    pub from_role: String,   // "deployer", "governor"
    pub to: Option<Address>, // None for CREATE
    pub data: Bytes,
    pub value: U256,
    pub contract_name: Option<String>, // For display: "Bridgehub"
    pub function_sig: Option<String>,  // For display: "acceptAdmin()"
}

#[derive(Serialize)]
pub struct ScriptContext {
    pub l1_chain_id: u64,
    pub era_chain_id: u64,
    pub deployer: Address,
    pub governor: Address,
    pub l1_rpc_url: String,
    pub bridgehub_proxy_addr: Address,
    
    // Roots of Trust (from contracts.yaml)
    // These might be empty/zero during initial deployment
    pub contracts: RootsOfTrust, 
}

#[derive(Serialize, Default)]
pub struct RootsOfTrust {
    pub bridgehub_proxy: Address,
    pub governance: Address,
    pub chain_admin: Address,
    pub l1_asset_router_proxy: Address,
}