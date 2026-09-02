import { spawn, spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { REPO_ROOT } from "./file-system";

function isExecutable(filePath: string): boolean {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function findExecutableOnPath(executable: string): string | undefined {
  return process.env.PATH?.split(path.delimiter)
    .map((directory) => path.join(directory, executable))
    .find(isExecutable);
}

export function locateProtocolOps(protocolOpsDirectory = path.join(REPO_ROOT, "protocol-ops")): string {
  const executable = [
    path.join(protocolOpsDirectory, "target/debug/protocol_ops"),
    path.join(protocolOpsDirectory, "target/release/protocol_ops"),
    path.join(protocolOpsDirectory, "protocol_ops"),
    findExecutableOnPath("protocol_ops"),
  ].find((candidate): candidate is string => candidate !== undefined && isExecutable(candidate));
  if (executable) return executable;
  throw new Error("protocol_ops binary not found — build it with 'cd protocol-ops && cargo build --release'");
}

export async function runCommand(
  command: string,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv; quiet?: boolean } = {}
): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env ?? process.env,
      stdio: options.quiet ? "ignore" : "inherit",
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with ${signal ? `signal ${signal}` : `code ${String(code)}`}`));
    });
  });
}

export function captureCommand(command: string, args: string[], cwd?: string, fallback?: string): string {
  const result = spawnSync(command, args, { cwd, encoding: "utf8" });
  if (result.status === 0) return result.stdout.trim();
  if (fallback !== undefined) return fallback;
  throw new Error(`${command} failed: ${(result.stderr || result.stdout).trim()}`);
}

export function commandSucceeds(command: string, args: string[], cwd?: string): boolean {
  return spawnSync(command, args, { cwd, stdio: "ignore" }).status === 0;
}
