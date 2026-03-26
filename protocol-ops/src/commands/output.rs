use std::path::PathBuf;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::common::{forge::ForgeRunner, logger};

/// Current output format version.
pub const OUTPUT_VERSION: u32 = 1;

/// Shared output arguments, flattened into every `*Args` struct.
#[derive(Debug, Clone, Serialize, Deserialize, clap::Args)]
pub struct OutputArgs {
    /// Write full JSON output to file
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,
}

/// Standard envelope for all protocol_ops command outputs.
///
/// Every command writes JSON with this structure:
/// ```json
/// {
///   "version": 1,
///   "input": { ... },
///   "output": { ... },
///   "runs": [ ... ]
/// }
/// ```
#[derive(Serialize)]
pub struct CommandEnvelope {
    pub version: u32,
    pub input: Value,
    pub output: Value,
    pub runs: Vec<RunEntry>,
}

/// A single forge script execution record.
#[derive(Serialize)]
pub struct RunEntry {
    pub script: String,
    pub run: Value,
}

impl CommandEnvelope {
    pub fn new<I: Serialize, O: Serialize>(
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

        Ok(Self {
            version: OUTPUT_VERSION,
            input: serde_json::to_value(input)?,
            output: serde_json::to_value(output)?,
            runs,
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
    output_args: &OutputArgs,
    runner: &ForgeRunner,
    input: &I,
    output: &O,
) -> anyhow::Result<()>
where
    I: Serialize,
    O: Serialize,
{
    if let Some(out_path) = &output_args.out {
        let envelope = CommandEnvelope::new(runner, input, output)?;
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }
    Ok(())
}