use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    time::Duration,
};

use anyhow::{bail, Context};
use serde_json::json;

use crate::common::ethereum::get_ethers_provider;

/// A running anvil instance. Killed on drop.
pub struct AnvilInstance {
    child: Child,
    rpc_url: String,
}

impl AnvilInstance {
    /// The local RPC URL for this anvil instance.
    pub fn rpc_url(&self) -> &str {
        &self.rpc_url
    }
}

impl Drop for AnvilInstance {
    fn drop(&mut self) {
        if let Err(e) = self.child.kill() {
            eprintln!(
                "warning: failed to kill anvil (pid {}): {e}",
                self.child.id()
            );
        }
        // Reap the child to avoid zombie processes.
        let _ = self.child.wait();
    }
}

/// Start anvil forking the given RPC URL with auto-impersonation enabled.
///
/// Blocks until anvil prints its "Listening on" line, then returns the handle.
///
/// Auto-impersonation is on at startup because simulate-mode forge runs always
/// use `--sender X --unlocked` (see `ForgeScript::with_wallet`) — the fork has
/// to be willing to sign for arbitrary addresses for those runs to succeed.
/// The fork is per-invocation and single-tenant, so always-on impersonation is
/// fine here.
pub fn start_anvil_fork(fork_url: &str) -> anyhow::Result<AnvilInstance> {
    let port = pick_unused_port()?;

    let mut child = Command::new("anvil")
        .args([
            "--fork-url",
            fork_url,
            "--port",
            &port.to_string(),
            "--auto-impersonate",
            // Scripts like bridgehub multicalls can exceed the 30M default
            // block gas limit; lift it so simulations don't spuriously OOG.
            "--disable-block-gas-limit",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn anvil — is it installed?")?;

    // Wait for anvil to be ready by reading stdout until we see the "Listening on" line.
    let stdout = child
        .stdout
        .take()
        .context("failed to capture anvil stdout")?;

    let rpc_url = wait_for_ready(stdout, port, Duration::from_secs(30))?;

    Ok(AnvilInstance { child, rpc_url })
}

/// Read lines from anvil's stdout until we see the listening message.
fn wait_for_ready(
    stdout: impl std::io::Read,
    port: u16,
    timeout: Duration,
) -> anyhow::Result<String> {
    let reader = BufReader::new(stdout);
    let deadline = std::time::Instant::now() + timeout;

    for line in reader.lines() {
        if std::time::Instant::now() > deadline {
            bail!("timed out waiting for anvil to start");
        }
        let line = line.context("reading anvil stdout")?;
        // Anvil prints: "Listening on 127.0.0.1:PORT"
        if line.contains("Listening on") {
            return Ok(format!("http://127.0.0.1:{port}"));
        }
    }
    bail!("anvil exited before it was ready")
}

/// Give `address` a fat ETH balance on an anvil fork via `anvil_setBalance`.
///
/// Used to unblock auto-resolved senders that are contracts (e.g. Governance,
/// the bridgehub admin Safe) or EOAs with insufficient ETH on the forked
/// chain. Only safe against anvil — real L1 rejects the call.
pub async fn set_balance(rpc_url: &str, address: ethers::types::Address) -> anyhow::Result<()> {
    let provider = get_ethers_provider(rpc_url)?;
    // 10 000 ETH is plenty for any deployment / multicall the Solidity
    // scripts do. Raw hex-encoded u256 to match anvil's expected format.
    const FUNDING_WEI_HEX: &str = "0x21e19e0c9bab2400000"; // 10_000 * 1e18
    provider
        .request::<_, serde_json::Value>(
            "anvil_setBalance",
            json!([format!("{address:#x}"), FUNDING_WEI_HEX]),
        )
        .await
        .with_context(|| format!("anvil_setBalance({address:#x}) failed against {rpc_url}"))?;
    Ok(())
}

/// Find an unused TCP port by binding to :0 and reading back the assigned port.
fn pick_unused_port() -> anyhow::Result<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .context("failed to bind ephemeral port for anvil")?;
    let port = listener.local_addr()?.port();
    // Listener is dropped here, freeing the port for anvil.
    // There is a small TOCTOU window, but acceptable for dev/test tooling.
    Ok(port)
}
