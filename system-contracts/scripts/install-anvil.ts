import { execSync } from "child_process";
import { existsSync, mkdirSync, chmodSync } from "fs";
import { join } from "path";

const VERSION = "v0.5.3-v28";
const COMMIT_HASH = "aa7f1aa"; // Added commit hash
const BIN_DIR = join(__dirname, "../bin");
const BINARY_PATH = join(BIN_DIR, "anvil-zksync");
const DOWNLOAD_URL = `https://github.com/matter-labs/anvil-zksync/releases/download/${COMMIT_HASH}/anvil-zksync-${VERSION}-aarch64-apple-darwin.tar.gz`;

function install() {
  try {
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
