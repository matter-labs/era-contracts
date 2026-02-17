import { Command } from "commander";
import { aiGeneralReviewCommand } from "./commands/ai-general-review";

async function main() {
  const program = new Command();
  program.name("ai-tools").version("0.1.0").description("AI-powered tools for smart contract analysis");

  program.addCommand(aiGeneralReviewCommand());

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
