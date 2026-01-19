// pub fn simulate_script(...) -> Result<(Vec<TransactionStep>, HashMap<String, Address>)> {
//     // 1. Write context.json
//     fs::write("script-context.json", serde_json::to_string(&context)?)?;

//     // 2. Run Forge (Simulation Only)
//     let output = Command::new("forge").arg("script").arg("--json").output()?;
//     let trace = parse_foundry_trace(&output);

//     let mut steps = Vec::new();
//     let mut artifacts = HashMap::new();

//     // 3. Iterate Trace Events & Calls
//     for event in trace.events {
//         if event.name == "PlanDescription" {
//             current_description = event.args[0];
//         } 
//         else if event.name == "RegisterArtifact" {
//              artifacts.insert(event.args[0], event.args[1]); // Key, Address
//         }
//     }
    
//     // 4. Map Transactions from `broadcast` file to descriptions
//     // ... (implementation details of matching logs to txs) ...

//     Ok((steps, artifacts))
// }