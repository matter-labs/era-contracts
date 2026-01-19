use anyhow::{Context, Result};
use ethers::types::{Address, Bytes, U256};
use protocol_cli_types::{Plan, Stage, Step, TransactionStep};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

// --- Traits ---

pub trait ForgeSimulator {
    // FIX 1: Return Artifacts map alongside transactions
    fn simulate(
        &self,
        script_path: &str,
        params_json: &str,
    ) -> Result<(Vec<SimulatedTx>, HashMap<String, Address>)>;
}

#[derive(Debug, Clone)]
pub struct SimulatedTx {
    pub from: Address,
    pub to: Option<Address>,
    pub data: Bytes,
    pub value: U256,
    pub contract_name: Option<String>,
    pub description: Option<String>,
}

// --- Internal State Container ---

struct BuilderContext {
    simulator: Box<dyn ForgeSimulator>,
    role_map: HashMap<Address, String>,
    tx_counter: usize,
}

// --- The Plan Builder ---

pub struct PlanBuilder {
    protocol_version: String,
    stages: Vec<Stage>,
    // Use Rc<RefCell> to share ownership of the context without lifetimes
    context: Rc<RefCell<BuilderContext>>,
}

impl PlanBuilder {
    pub fn new(version: &str, simulator: impl ForgeSimulator + 'static) -> Self {
        Self {
            protocol_version: version.to_string(),
            stages: Vec::new(),
            context: Rc::new(RefCell::new(BuilderContext {
                simulator: Box::new(simulator),
                role_map: HashMap::new(),
                tx_counter: 0,
            })),
        }
    }

    pub fn register_role(&mut self, address: Address, role_name: &str) {
        self.context
            .borrow_mut()
            .role_map
            .insert(address, role_name.to_string());
    }

    // FIX 2: Make add_stage generic over R so it can return artifacts
    pub fn add_stage<F, R>(&mut self, name: &str, setup_fn: F) -> Result<R>
    where
        F: FnOnce(&mut StageBuilder) -> Result<R>,
    {
        let mut stage_builder = StageBuilder {
            context: self.context.clone(),
            steps: Vec::new(),
        };

        // Run the user's closure and capture the result (e.g., artifacts)
        let result = setup_fn(&mut stage_builder)?;

        self.stages.push(Stage {
            name: name.to_string(),
            description: None,
            steps: stage_builder.steps,
        });

        Ok(result)
    }

    pub fn build(self) -> Plan {
        Plan {
            protocol_version: self.protocol_version,
            stages: self.stages,
        }
    }
    
    pub fn save_plan(self, path: std::path::PathBuf) -> Result<()> {
        let plan = self.build();
        let json = serde_json::to_string_pretty(&plan)?;
        std::fs::write(path, json)?;
        Ok(())
    }
}

// --- The Stage Builder ---

pub struct StageBuilder {
    context: Rc<RefCell<BuilderContext>>,
    steps: Vec<Step>,
}

impl StageBuilder {
    pub fn add_forge_script(
        &mut self,
        script_name: &str,
        params: &impl serde::Serialize,
    ) -> Result<HashMap<String, Address>> {
        let params_json = serde_json::to_string(params).context("Failed to serialize params")?;

        // Borrow the context briefly
        let mut ctx = self.context.borrow_mut();

        // 1. Simulate using the trait (now returns artifacts too)
        let (simulated_txs, artifacts) = ctx.simulator.simulate(script_name, &params_json)?;

        // 2. Process Transactions
        let mut script_steps = Vec::new();
        for tx in simulated_txs {
            ctx.tx_counter += 1;
            let id = format!("tx_{}", ctx.tx_counter);

            let from_role = ctx
                .role_map
                .get(&tx.from)
                .cloned()
                .unwrap_or_else(|| format!("{:?}", tx.from));

            let description = tx
                .description
                .clone()
                .or_else(|| {
                    tx.contract_name
                        .as_ref()
                        .map(|n| format!("Interact with {}", n))
                })
                .unwrap_or_else(|| "Unknown Transaction".to_string());

            script_steps.push(Step::Transaction(TransactionStep {
                id,
                description,
                from_role,
                to: tx.to,
                data: tx.data,
                value: tx.value,
                contract_name: tx.contract_name,
                function_sig: None,
            }));
        }

        self.steps.push(Step::ScriptGroup {
            name: script_name.to_string(),
            steps: script_steps,
        });

        // Return the artifacts map so the caller can use addresses in subsequent stages
        Ok(artifacts)
    }
}