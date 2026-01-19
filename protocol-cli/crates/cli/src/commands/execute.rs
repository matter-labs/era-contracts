// #[derive(Debug, Clone, Serialize, Deserialize, Parser)]
// pub struct PlanArgs {
//     #[clap(long)]
//     pub script_path: PathBuf,

//     #[clap(flatten)]
//     #[serde(flatten)]
//     pub forge_args: ForgeArgs,
// }

// pub async fn execute_plan(args: ExecuteArgs) -> Result<()> {
//     let plan: Plan = read_json(&args.plan_file)?;
//     let mut state = StateManager::load(&args.state_file)?;

//     for stage in plan.stages {
//         for step in stage.steps {
//             if state.is_done(&step.id) { continue; }

//             logger::info(&step.description);

//             // 1. Get Signer
//             let signer = match step.from_role.as_str() {
//                 "deployer" => args.deployer_signer,
//                 "governor" => args.governor_signer,
//                 _ => panic!("Unknown role"),
//             };

//             // 2. Send TX
//             let receipt = signer.send_transaction(
//                 step.to, 
//                 step.value, 
//                 step.data
//             ).await?;

//             // 3. Update State
//             state.mark_done(&step.id);
//         }
//     }
//     Ok(())
// }