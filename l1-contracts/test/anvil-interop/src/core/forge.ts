import { spawn } from "child_process";

/**
 * Run a Forge script with the given parameters.
 *
 * Spawns a `forge script` process, streams stdout/stderr in real-time,
 * and returns the captured stdout on success.
 */
export async function runForgeScript(params: {
  scriptPath: string;
  envVars: Record<string, string>;
  rpcUrl: string;
  senderAddress?: string;
  privateKey?: string;
  projectRoot: string;
  sig?: string;
  args?: string;
  extraForgeArgs?: string[];
}): Promise<string> {
  const { scriptPath, envVars, rpcUrl, senderAddress, privateKey, projectRoot, sig, args } = params;

  const env = {
    ...process.env,
    ...envVars,
  };

  const commandArgs = ["script", scriptPath, "--rpc-url", rpcUrl];

  if (privateKey) {
    commandArgs.push("--private-key", privateKey);
  } else {
    commandArgs.push("--unlocked", "--sender", senderAddress!);
  }

  commandArgs.push("--broadcast", "--legacy", "--ffi", "--sig", sig || "runForTest()");

  if (params.extraForgeArgs) {
    commandArgs.push(...params.extraForgeArgs);
  }

  if (args) {
    commandArgs.push(...args.split(" "));
  }

  console.log(`   Running: ${scriptPath}`);
  console.log(`   Command: forge ${commandArgs.join(" ")}`);
  console.log("");

  return new Promise((resolve, reject) => {
    const forgeProcess = spawn("forge", commandArgs, {
      cwd: projectRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";

    forgeProcess.stdout.on("data", (data: Buffer) => {
      const text = data.toString();
      stdout += text;
      process.stdout.write(text);
    });

    forgeProcess.stderr.on("data", (data: Buffer) => {
      const text = data.toString();
      const lines = text.split("\n");
      const nonWarningLines = lines.filter((line: string) => !line.includes("Warning"));
      if (nonWarningLines.length > 0 && nonWarningLines.join("").trim()) {
        process.stderr.write(nonWarningLines.join("\n") + "\n");
      }
    });

    forgeProcess.on("close", (code: number) => {
      console.log("");
      if (code === 0) {
        console.log("✅ Script completed successfully");
        resolve(stdout);
      } else {
        console.error(`❌ Forge script failed with exit code ${code}`);
        reject(new Error(`Forge script exited with code ${code}`));
      }
    });

    forgeProcess.on("error", (error: Error) => {
      console.error("❌ Failed to spawn forge process:", error.message);
      reject(error);
    });
  });
}
