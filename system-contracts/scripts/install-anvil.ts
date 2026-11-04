import { execSync } from "child_process";
import { existsSync, mkdirSync, chmodSync } from "fs";
import { join } from "path";
import os from "os";

// Resolve the latest release from GitHub, matching the dutterbutter/anvil-zksync-action
// used in CI (which defaults to releaseTag: "latest"). This keeps local dev and CI on the
// same binary version without hardcoding a tag that drifts out of sync.
const GITHUB_REPO = "matter-labs/anvil-zksync";
const BIN_DIR = join(__dirname, "../bin");
const BINARY_PATH = join(BIN_DIR, "anvil-zksync");

function getPlatformInfo() {
  const platform = os.platform();
  const arch = os.arch();

  let osType: string;
  let archType: string;

  if (platform === "darwin") {
    osType = "apple-darwin";
  } else if (platform === "linux") {
    osType = "unknown-linux-gnu";
  } else {
    throw new Error(`Unsupported platform: ${platform}`);
  }

  if (arch === "arm64") {
    archType = "aarch64";
  } else if (arch === "x64") {
    archType = "x86_64";
  } else {
    throw new Error(`Unsupported architecture: ${arch}`);
  }

  return { archType, osType };
}

function resolveLatestTag(): string {
  const output = execSync(
    `curl -sI "https://github.com/${GITHUB_REPO}/releases/latest" | grep -i '^location:' | head -1`,
    { encoding: "utf-8" }
  ).trim();

  const match = output.match(/\/tag\/([^\s]+)/);
  if (!match) {
    throw new Error(`Failed to resolve latest release tag from GitHub. Response: ${output}`);
  }
  return match[1].trim();
}

function install() {
  try {
    const tag = resolveLatestTag();
    console.log(`📦 Resolved latest anvil-zksync release: ${tag}`);

    const { archType, osType } = getPlatformInfo();
    const url = `https://github.com/${GITHUB_REPO}/releases/download/${tag}/anvil-zksync-${tag}-${archType}-${osType}.tar.gz`;

    if (!existsSync(BIN_DIR)) {
      mkdirSync(BIN_DIR, { recursive: true });
    }

    console.log("📥 Downloading anvil-zksync...");
    execSync(`curl -L ${url} | tar xz -C ${BIN_DIR}`);

    console.log("🔧 Setting executable permissions...");
    chmodSync(BINARY_PATH, 0o755);

    const version = execSync(`${BINARY_PATH} --version`, { encoding: "utf-8" }).trim();
    console.log(`✅ anvil-zksync installed successfully (${version})`);
  } catch (error) {
    console.error("❌ Installation failed:", error);
    process.exit(1);
  }
}

install();
