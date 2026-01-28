import { Command } from "commander";
import * as fs from "fs";
import * as path from "path";
import { spawn } from "./utils";

const SELECTORS_FILE = path.resolve(__dirname, "../selectors");
const TEMP_SELECTORS_FILE = path.resolve(__dirname, "../selectors.tmp");

// Computes the list of selectors by running `forge selectors list`, and writes output to a temporary file.
async function computeSelectors(): Promise<void> {
  await spawn(`forge selectors list > ${TEMP_SELECTORS_FILE}`);
}

// Reads the current selectors file.
function readSelectorsFile(): string | null {
  if (!fs.existsSync(SELECTORS_FILE)) {
    return null;
  }
  return fs.readFileSync(SELECTORS_FILE, "utf8");
}

// Reads the computed selectors from temp file.
function readComputedSelectors(): string {
  return fs.readFileSync(TEMP_SELECTORS_FILE, "utf8");
}

// Writes the selectors to the file.
function writeSelectorsFile(selectors: string): void {
  fs.writeFileSync(SELECTORS_FILE, selectors, "utf8");
  console.log(`Selectors file updated: ${SELECTORS_FILE}`);
}

// Cleans up temporary file.
function cleanup(): void {
  if (fs.existsSync(TEMP_SELECTORS_FILE)) {
    fs.unlinkSync(TEMP_SELECTORS_FILE);
  }
}

// Compares two selector strings for strict equality.
function compareSelectors(computed: string, existing: string | null): boolean {
  if (existing === null) {
    return false;
  }
  return computed === existing;
}

async function main() {
  const program = new Command();
  program
    .option("--fix", "Compute selectors and update the selectors file")
    .option("--check", "Check if the selectors file matches the computed selectors")
    .parse(process.argv);

  const options = program.opts();

  // Validate that exactly one option is provided
  if ((!options.fix && !options.check) || (options.fix && options.check)) {
    console.error("Error: You must provide either --fix or --check, but not both.");
    process.exit(1);
  }

  try {
    console.log("Computing selectors using 'forge selectors list'...");
    await computeSelectors();
    const computed = readComputedSelectors();

    if (options.check) {
      console.log("Checking selectors...");
      const existing = readSelectorsFile();

      if (!compareSelectors(computed, existing)) {
        console.error("\n❌ Error: Selectors file does not match computed selectors.");
        console.error("To fix this issue, run: yarn l1 selectors --fix");
        cleanup();
        process.exit(1);
      }

      console.log("✅ Selectors file is up to date.");
    } else if (options.fix) {
      console.log("Updating selectors file...");
      writeSelectorsFile(computed);
      console.log("✅ Selectors file has been updated successfully.");
    }

    cleanup();
  } catch (error) {
    cleanup();
    throw error;
  }
}

main().catch((error) => {
  console.error("Fatal error:", error.message);
  process.exit(1);
});
