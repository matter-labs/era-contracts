use serde::Serialize;
use serde_json::Value;

use crate::common::forge::ForgeRunner;

/// Current output format version.
pub const OUTPUT_VERSION: u32 = 1;

/// Standard envelope for all protocol_ops command outputs.
///
/// Every command writes JSON with this structure:
/// ```json
/// {
///   "version": 1,
///   "command": "ecosystem.init",
///   "input": { ... },
///   "output": { ... },
///   "runs": [ ... ]
/// }
/// ```
#[derive(Serialize)]
pub struct CommandEnvelope<I: Serialize, O: Serialize> {
    pub version: u32,
    pub command: String,
    pub input: I,
    pub output: O,
    pub runs: Vec<RunEntry>,
}

/// A single forge script execution record.
#[derive(Serialize)]
pub struct RunEntry {
    pub script: String,
    pub run: Value,
}

impl<I: Serialize, O: Serialize> CommandEnvelope<I, O> {
    pub fn new(command: &str, input: I, output: O, runner: &ForgeRunner) -> Self {
        let runs = runner
            .runs()
            .iter()
            .map(|r| RunEntry {
                script: r.script.display().to_string(),
                run: r.payload.clone(),
            })
            .collect();

        Self {
            version: OUTPUT_VERSION,
            command: command.to_string(),
            input,
            output,
            runs,
        }
    }

    pub fn write_to_file(&self, path: &std::path::Path) -> anyhow::Result<()> {
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)?;
        Ok(())
    }
}
