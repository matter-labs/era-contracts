import { execSync } from "child_process";
import { existsSync, mkdirSync, chmodSync } from "fs";
import { join } from "path";
import os from "os";

const VERSION = "v0.6.1";
const COMMIT_HASH = "v0.6.1";
const BIN_DIR = join(__dirname, "../bin");
const BINARY_PATH = join(BIN_DIR, "anvil-zksync");

function getPlatformInfo() {
  const platform = os.platform();
  const arch = os.arch();

  let osType: string;
  let archType: string;

  // Map OS
  if (platform === "darwin") {
    osType = "apple-darwin";
  } else if (platform === "linux") {
    osType = "unknown-linux-gnu";
  } else {
    throw new Error(`Unsupported platform: ${platform}`);
  }

  // Map architecture
  if (arch === "arm64") {
    archType = "aarch64";
  } else if (arch === "x64") {
    archType = "x86_64";
  } else {
    throw new Error(`Unsupported architecture: ${arch}`);
  }

  return { archType, osType };
}

function install() {
  try {
    const { archType, osType } = getPlatformInfo();
    const DOWNLOAD_URL = `https://github.com/matter-labs/anvil-zksync/releases/download/${COMMIT_HASH}/anvil-zksync-${VERSION}-${archType}-${osType}.tar.gz`;

    // Create bin directory if needed
    if (!existsSync(BIN_DIR)) {
      mkdirSync(BIN_DIR, { recursive: true });
    }

    console.log("📥 Downloading anvil-zksync...");
    execSync(`curl -L ${DOWNLOAD_URL} | tar xz -C ${BIN_DIR}`);

    console.log("🔧 Setting executable permissions...");
    chmodSync(BINARY_PATH, 0o755);

    console.log("✅ anvil-zksync installed successfully");
  } catch (error) {
    console.error("❌ Installation failed:", error);
    process.exit(1);
  }
}

install();
