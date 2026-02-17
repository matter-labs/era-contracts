import { Command } from "commander";
import * as fs from "fs";
import * as path from "path";
import * as readline from "readline";
import { spawn as spawnChild } from "child_process";
import chalk from "chalk";

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const AI_TOOLS_ROOT = path.resolve(__dirname, "../..");
const REPO_ROOT = path.resolve(AI_TOOLS_ROOT, "..");
const CONTRACTS_INFO_PATH = path.resolve(AI_TOOLS_ROOT, "contracts_info.json");

// ---------------------------------------------------------------------------
// Prompt template (hardcoded)
// ---------------------------------------------------------------------------

const PROMPT_TEMPLATE = `You are a professional Solidity auditor, tasked with ensuring the code quality of the contracts within the scope.

Your main job within the current task is to find dangerous patterns within the given contract <contract-name> and its interfaces. Dangerous patterns to look out for are:

1. Weak data management. No field should be "half-updated" on L1 or L2 implementation. The field is either updated or zero. If there are fields that depend on each other, these should be maintained in sync.
2. Unclear assumptions: when querying data from other contracts / reading from the state of the contract itself it should be either obvious where does the data come from or we should have explicit checks to validate the data.
3. Blocks of commented out code without clear comments on why it is commented out.
4. Sloppy access controll management. Which modifiers contain more or less allowed callers that actually call the contract?
5. Weak interface management: -Base contracts should only rely on interfaces of Base contracts (L1/L2 specific contracts allowed when a path strictly checks that it only gets executed on L1/L2). Similar to L1/L2 contracts: they can use Base functionality or the functionality from the corresponding layer.
6. Misallocation of L1/L2 specific functionality. If some functionality is only used on L1/L2, it should generally be present on the corresponding layer implementation only.
7. Contracts that can be deployed on L2 must not have any constructors or immutables.
8. General stylistic issues: unused items, logic that can be simplified etc.

The exceptions for the rules above can exist, but they should clearly described in the natspec.

Before finalizing the result, please double check with the following assumptions/traps for false positives before submitting the result:
- Anything that is invoked by the decentralized governance (\`owner\` of the contract) is trusted to be invoked with the corrent data and the correct number of times. While the implementation of \`initialize\` itself should be checked. Dont report errors like "this function can be called multiple times" or "params for this function may be wrong/zero address".
- It is acceptable to rely on concrete implementations of contracts and not their interfaces as long as rule (5) is followed.

Here are the special notes specific to the contract:
<special notes about the audited contract>

Your report MUST be in markdown, MUST start with \`## <contract-name> report summary\` header.
`;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ContractInfo {
  additional_comments: string | null;
  path: string;
}

type ContractsInfoMap = Record<string, ContractInfo>;

type ReviewStatus = "pending" | "in_progress" | "done" | "failed";

interface ReviewTask {
  contractName: string;
  status: ReviewStatus;
  outputFile: string;
}

// ---------------------------------------------------------------------------
// Data loading
// ---------------------------------------------------------------------------

function loadContractsInfo(): ContractsInfoMap {
  if (!fs.existsSync(CONTRACTS_INFO_PATH)) {
    throw new Error(`Contracts info file not found: ${CONTRACTS_INFO_PATH}`);
  }
  return JSON.parse(fs.readFileSync(CONTRACTS_INFO_PATH, "utf-8"));
}

// ---------------------------------------------------------------------------
// Prompt construction
// ---------------------------------------------------------------------------

function buildPrompt(contractName: string, info: ContractInfo): string {
  const contractFilePath = path.resolve(REPO_ROOT, info.path);
  if (!fs.existsSync(contractFilePath)) {
    throw new Error(`Contract source file not found: ${contractFilePath}`);
  }

  let prompt = PROMPT_TEMPLATE.replace(/<contract-name>/g, contractName).replace(
    "<special notes about the audited contract>",
    info.additional_comments || "No special notes for this contract."
  );
  
  return prompt;
}

// ---------------------------------------------------------------------------
// User confirmation
// ---------------------------------------------------------------------------

function askConfirmation(question: string): Promise<boolean> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.toLowerCase() === "y" || answer.toLowerCase() === "yes");
    });
  });
}

// ---------------------------------------------------------------------------
// Codex execution
// ---------------------------------------------------------------------------

interface CodexOptions {
  model: string;
  reasoningEffort: string;
}

function runCodexExec(prompt: string, outputFile: string, codexOpts: CodexOptions): Promise<void> {
  return new Promise((resolve, reject) => {
    // Write prompt to a temp file to avoid OS argument length limits.
    const promptFile = outputFile.replace(/\.md$/, ".prompt.txt");
    fs.writeFileSync(promptFile, prompt, "utf-8");

    // Open the output file as a write stream so output is flushed immediately.
    // This lets the user `tail -f` the file to see progress in real time.
    const outStream = fs.createWriteStream(outputFile, { flags: "w", encoding: "utf-8" });

    // Invoke codex with the prompt piped via stdin.
    const child = spawnChild("codex", [
      "exec",
      "--config", `model=${codexOpts.model}`,
      "--config", `model_reasoning_effort=${codexOpts.reasoningEffort}`,
    ], {
      cwd: REPO_ROOT,
      env: { ...process.env },
      stdio: [fs.openSync(promptFile, "r"), "pipe", "pipe"],
    });

    // Stream stdout directly to the output file.
    child.stdout?.on("data", (data: Buffer) => {
      outStream.write(data);
    });

    // Stream stderr with a marker so it's distinguishable.
    let stderrStarted = false;
    child.stderr?.on("data", (data: Buffer) => {
      if (!stderrStarted) {
        outStream.write("\n\n--- STDERR ---\n");
        stderrStarted = true;
      }
      outStream.write(data);
    });

    child.on("close", (code) => {
      outStream.end();

      // Clean up the temp prompt file.
      try {
        fs.unlinkSync(promptFile);
      } catch {
        // ignore
      }

      if (code !== 0) {
        reject(new Error(`codex exec exited with code ${code}`));
      } else {
        resolve();
      }
    });

    child.on("error", (err) => {
      outStream.end();
      try {
        fs.unlinkSync(promptFile);
      } catch {
        // ignore
      }
      reject(new Error(`Failed to start codex: ${err.message}. Is the codex CLI installed?`));
    });
  });
}

// ---------------------------------------------------------------------------
// Subreport extraction
// ---------------------------------------------------------------------------

/**
 * Reads the raw codex output file and extracts the subreport section.
 * Uses the **last** occurrence of `## <name> report summary` so that any
 * earlier mentions (e.g. in codex reasoning / echoed prompt) are skipped.
 * Runs until end-of-file, excluding any trailing `--- STDERR ---` block.
 */
function extractSubreport(outputFile: string, contractName: string): string | null {
  if (!fs.existsSync(outputFile)) {
    return null;
  }

  const raw = fs.readFileSync(outputFile, "utf-8");

  const header = `## ${contractName} report summary`;
  const idx = raw.lastIndexOf(header);
  if (idx === -1) {
    return null;
  }

  let subreport = raw.slice(idx);

  // Strip trailing stderr block if present.
  const stderrMarker = "\n\n--- STDERR ---\n";
  const stderrIdx = subreport.indexOf(stderrMarker);
  if (stderrIdx !== -1) {
    subreport = subreport.slice(0, stderrIdx);
  }

  return subreport.trimEnd();
}

/**
 * Shared logic: merge individual report files into a single full_report.md.
 * Returns the number of successfully extracted subreports.
 */
function mergeReports(contractNames: string[], outputDir: string, fullReportPath: string): number {
  const subreports: string[] = [];

  for (const name of contractNames) {
    const outputFile = path.join(outputDir, `${name}.md`);
    const sub = extractSubreport(outputFile, name);
    if (sub) {
      subreports.push(sub);
    } else {
      subreports.push(
        `## ${name} report summary\n\n` +
          `> _Warning: could not extract structured subreport. See raw output in \`${outputFile}\`._`
      );
    }
  }

  if (subreports.length > 0) {
    const header = `# AI General Review Report\n\n` + `_Generated on ${new Date().toISOString()}_\n\n---\n\n`;
    fs.writeFileSync(fullReportPath, header + subreports.join("\n\n---\n\n") + "\n", "utf-8");
  }

  return subreports.length;
}

// ---------------------------------------------------------------------------
// Display manager – renders live progress to the terminal
// ---------------------------------------------------------------------------

class DisplayManager {
  private tasks: ReviewTask[];
  private numJobs: number;
  private linesRendered = 0;
  private isTTY: boolean;

  constructor(tasks: ReviewTask[], numJobs: number) {
    this.tasks = tasks;
    this.numJobs = numJobs;
    this.isTTY = process.stdout.isTTY || false;
  }

  render(): void {
    if (this.isTTY) {
      this.renderTTY();
    }
  }

  /** Non-TTY fallback: emit a single log line on status change. */
  logEvent(message: string): void {
    if (!this.isTTY) {
      console.log(message);
    }
  }

  private renderTTY(): void {
    // Move cursor up to overwrite the previous render.
    if (this.linesRendered > 0) {
      process.stdout.write(`\x1b[${this.linesRendered}A`);
    }

    const lines: string[] = [];

    const doneCount = this.tasks.filter((t) => t.status === "done").length;
    const failedCount = this.tasks.filter((t) => t.status === "failed").length;
    const inProgressCount = this.tasks.filter((t) => t.status === "in_progress").length;
    const pendingCount = this.tasks.length - doneCount - failedCount - inProgressCount;

    lines.push("");
    lines.push(
      chalk.bold("AI General Review") + chalk.gray(` — ${this.tasks.length} contracts, ${this.numJobs} parallel jobs`)
    );
    lines.push(chalk.gray("─".repeat(64)));

    for (const task of this.tasks) {
      const name = task.contractName.padEnd(30);
      switch (task.status) {
        case "done":
          lines.push(`  ${chalk.green("✓")} ${chalk.green(name)} ${chalk.gray("→ " + task.outputFile)}`);
          break;
        case "failed":
          lines.push(`  ${chalk.red("✗")} ${chalk.red(name)} ${chalk.red("failed")}`);
          break;
        case "in_progress":
          lines.push(`  ${chalk.yellow("●")} ${chalk.yellow(name)} ${chalk.yellow("in progress...")}`);
          break;
        case "pending":
          lines.push(`  ${chalk.gray("○")} ${chalk.gray(name)} ${chalk.gray("pending")}`);
          break;
      }
    }

    lines.push(chalk.gray("─".repeat(64)));

    const parts: string[] = [];
    parts.push(chalk.green(`${doneCount} done`));
    if (failedCount > 0) parts.push(chalk.red(`${failedCount} failed`));
    if (inProgressCount > 0) parts.push(chalk.yellow(`${inProgressCount} running`));
    if (pendingCount > 0) parts.push(chalk.gray(`${pendingCount} pending`));

    lines.push(`  Progress: ${parts.join(chalk.gray(" · "))}  ${chalk.gray(`(${doneCount + failedCount}/${this.tasks.length})`)}`);
    lines.push("");

    // Clear each line to avoid leftover characters from previous render.
    const output = lines.map((l) => l + "\x1b[K").join("\n");
    process.stdout.write(output);
    this.linesRendered = lines.length - 1;
  }
}

// ---------------------------------------------------------------------------
// Concurrency pool
// ---------------------------------------------------------------------------

async function runWithConcurrency<T>(items: T[], concurrency: number, fn: (item: T) => Promise<void>): Promise<void> {
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (nextIndex < items.length) {
      const idx = nextIndex++;
      await fn(items[idx]);
    }
  }

  const workers = Array.from({ length: Math.min(concurrency, items.length) }, () => worker());
  await Promise.all(workers);
}

// ---------------------------------------------------------------------------
// Command definition
// ---------------------------------------------------------------------------

export function aiGeneralReviewCommand(): Command {
  const cmd = new Command("ai-general-review");

  cmd
    .description("Run AI-powered security review on smart contracts using OpenAI Codex")
    .option("--contract <names>", "Contract name(s) to review, comma-separated (must exist in contracts_info.json)")
    .option("--num-jobs <number>", "Number of parallel review jobs", "1")
    .option("--output-dir <dir>", "Output directory for review reports", "output")
    .option("--full-report <path>", "Path for the merged report file", "full_report.md")
    .option("--model <model>", "Codex model name", "gpt-5.3-codex")
    .option("--reasoning-effort <effort>", "Model reasoning effort level", "xhigh")
    .action(async (options) => {
      // Codex uses whatever one has inside `codex login`, so API key is not necessary.

      const contractsInfo = loadContractsInfo();
      const numJobs = parseInt(options.numJobs, 10);
      const outputDir = path.resolve(process.cwd(), options.outputDir);

      if (isNaN(numJobs) || numJobs < 1) {
        console.error(chalk.red("Error: --num-jobs must be a positive integer."));
        process.exit(1);
      }

      // ------------------------------------------------------------------
      // 2. Determine contracts to review
      // ------------------------------------------------------------------
      let contractNames: string[];

      if (options.contract) {
        contractNames = (options.contract as string).split(",").map((s) => s.trim()).filter(Boolean);
        const unknown = contractNames.filter((n) => !contractsInfo[n]);
        if (unknown.length > 0) {
          console.error(chalk.red(`Error: Unknown contract(s): ${unknown.join(", ")}`));
          console.error(chalk.gray("\nAvailable contracts:"));
          for (const name of Object.keys(contractsInfo).sort()) {
            console.error(chalk.gray(`  - ${name}`));
          }
          process.exit(1);
        }
      } else {
        contractNames = Object.keys(contractsInfo);

        console.log(`\nFound ${chalk.bold(String(contractNames.length))} contracts in contracts_info.json.\n`);

        const confirmed = await askConfirmation(
          chalk.yellow(
            `This will run AI review for all ${contractNames.length} contracts, which may be expensive.\nContinue? [y/N] `
          )
        );

        if (!confirmed) {
          console.log("Aborted.");
          process.exit(0);
        }
      }

      // ------------------------------------------------------------------
      // 3. Prepare output directory
      // ------------------------------------------------------------------
      fs.mkdirSync(outputDir, { recursive: true });

      // ------------------------------------------------------------------
      // 4. Build task list & render initial display
      // ------------------------------------------------------------------
      const tasks: ReviewTask[] = contractNames.map((name) => ({
        contractName: name,
        status: "pending" as ReviewStatus,
        outputFile: path.join(outputDir, `${name}.md`),
      }));

      const display = new DisplayManager(tasks, numJobs);
      display.render();

      // ------------------------------------------------------------------
      // 5. Run reviews with concurrency
      // ------------------------------------------------------------------
      const codexOpts: CodexOptions = {
        model: options.model,
        reasoningEffort: options.reasoningEffort,
      };

      await runWithConcurrency(tasks, numJobs, async (task) => {
        task.status = "in_progress";
        display.render();
        display.logEvent(`[STARTED] ${task.contractName}`);

        try {
          const info = contractsInfo[task.contractName];
          const prompt = buildPrompt(task.contractName, info);
          await runCodexExec(prompt, task.outputFile, codexOpts);
          task.status = "done";
        } catch (err: any) {
          task.status = "failed";
          fs.writeFileSync(task.outputFile, `Review failed for ${task.contractName}:\n${err.message}\n`, "utf-8");
        }

        display.render();
        display.logEvent(
          task.status === "done"
            ? `[DONE]    ${task.contractName} → ${task.outputFile}`
            : `[FAILED]  ${task.contractName}`
        );
      });

      // ------------------------------------------------------------------
      // 6. Merge subreports into a single file
      // ------------------------------------------------------------------
      const fullReportPath = path.resolve(process.cwd(), options.fullReport);
      const doneNames = tasks.filter((t) => t.status === "done").map((t) => t.contractName);
      const merged = mergeReports(doneNames, outputDir, fullReportPath);

      // ------------------------------------------------------------------
      // 7. Final summary
      // ------------------------------------------------------------------
      console.log(""); // newline after display

      const doneCount = tasks.filter((t) => t.status === "done").length;
      const failedCount = tasks.filter((t) => t.status === "failed").length;

      if (failedCount > 0) {
        console.log(
          chalk.yellow(`Completed with ${failedCount} failure(s). ${doneCount}/${tasks.length} reviews succeeded.`)
        );
      } else {
        console.log(chalk.green(`All ${doneCount} review(s) completed successfully.`));
      }

      console.log(chalk.gray(`Individual reports: ${outputDir}/`));
      if (merged > 0) {
        console.log(chalk.bold(`Merged report:      ${fullReportPath}`));
      }

      if (failedCount > 0) {
        process.exit(1);
      }
    });

  return cmd;
}

// ---------------------------------------------------------------------------
// combine-reports command
// ---------------------------------------------------------------------------

export function combineReportsCommand(): Command {
  const cmd = new Command("combine-reports");

  cmd
    .description("Combine individual raw review outputs into a single merged report")
    .requiredOption("--contract <names>", "Contract name(s) to include, comma-separated")
    .option("--output-dir <dir>", "Directory containing individual <Contract>.md files", "output")
    .option("--full-report <path>", "Path for the merged report file", "full_report.md")
    .action((options) => {
      const contractNames = (options.contract as string)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);

      if (contractNames.length === 0) {
        console.error(chalk.red("Error: no contract names provided."));
        process.exit(1);
      }

      const outputDir = path.resolve(process.cwd(), options.outputDir);
      const fullReportPath = path.resolve(process.cwd(), options.fullReport);

      // Validate that the individual files exist.
      const missing = contractNames.filter((n) => !fs.existsSync(path.join(outputDir, `${n}.md`)));
      if (missing.length > 0) {
        console.error(chalk.red(`Error: missing report file(s) in ${outputDir}/:`));
        for (const m of missing) {
          console.error(chalk.red(`  - ${m}.md`));
        }
        process.exit(1);
      }

      const merged = mergeReports(contractNames, outputDir, fullReportPath);
      console.log(chalk.green(`Merged ${merged} subreport(s) into ${fullReportPath}`));
    });

  return cmd;
}
