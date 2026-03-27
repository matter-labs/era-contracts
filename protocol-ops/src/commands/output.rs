use serde::Serialize;
use serde_json::Value;

use crate::common::forge::{all_runs_cast_transactions, ForgeRunner};
use crate::common::logger;

/// Current output format version.
pub const OUTPUT_VERSION: u32 = 1;

/// Standard envelope for all protocol_ops command `--out` JSON.
///
/// Includes flat **`transactions`** (`to` / `data` / `value`) for
/// `chain execute-simulated-transactions` / `ExecuteProtocolOpsOut.s.sol`.
#[derive(Serialize)]
pub struct CommandEnvelope {
    pub command: String,
    pub version: u32,
    pub runs: Vec<RunEntry>,
    pub transactions: Vec<Value>,
    pub input: Value,
    pub output: Value,
}

/// A single forge script execution record.
#[derive(Serialize)]
pub struct RunEntry {
    pub script: String,
    pub run: Value,
}

impl CommandEnvelope {
    pub fn new<I: Serialize, O: Serialize>(
        command: &str,
        runner: &ForgeRunner,
        input: &I,
        output: &O,
    ) -> anyhow::Result<Self> {
        let runs = runner
            .runs()
            .iter()
            .map(|r| RunEntry {
                script: r.script.display().to_string(),
                run: r.payload.clone(),
            })
            .collect();
        let transactions = all_runs_cast_transactions(runner);

        Ok(Self {
            command: command.to_string(),
            version: OUTPUT_VERSION,
            runs,
            transactions,
            input: serde_json::to_value(input)?,
            output: serde_json::to_value(output)?,
        })
    }

    pub fn write_to_file(&self, path: &std::path::Path) -> anyhow::Result<()> {
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)?;
        Ok(())
    }
}

/// Write `--out` JSON file if the user requested it. No-op otherwise.
pub fn write_output_if_requested<I, O>(
    command: &str,
    out_path: Option<&std::path::Path>,
    runner: &ForgeRunner,
    input: &I,
    output: &O,
) -> anyhow::Result<()>
where
    I: Serialize,
    O: Serialize,
{
    if let Some(out_path) = out_path {
        let envelope = CommandEnvelope::new(command, runner, input, output)?;
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }
    Ok(())
}
