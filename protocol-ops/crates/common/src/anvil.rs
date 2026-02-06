use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    time::Duration,
};

use anyhow::{bail, Context};

use crate::logger;

/// A running anvil instance. Killed on drop.
pub struct AnvilInstance {
    child: Child,
    rpc_url: String,
    port: u16,
}

impl AnvilInstance {
    /// The local RPC URL for this anvil instance.
    pub fn rpc_url(&self) -> &str {
        &self.rpc_url
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for AnvilInstance {
    fn drop(&mut self) {
        if let Err(e) = self.child.kill() {
            eprintln!("warning: failed to kill anvil (pid {}): {e}", self.child.id());
        }
        // Reap the child to avoid zombie processes.
        let _ = self.child.wait();
    }
}

/// Start anvil forking the given RPC URL with auto-impersonate enabled.
///
/// Blocks until anvil prints its "Listening on" line, then returns the handle.
pub fn start_anvil_fork(fork_url: &str) -> anyhow::Result<AnvilInstance> {
    let port = pick_unused_port()?;

    logger::info(format!(
        "Starting anvil fork of {fork_url} on port {port}..."
    ));

    let mut child = Command::new("anvil")
        .args([
            "--fork-url",
            fork_url,
            "--port",
            &port.to_string(),
            "--auto-impersonate",
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

    logger::info(format!("Anvil ready at {rpc_url}"));

    Ok(AnvilInstance {
        child,
        rpc_url,
        port,
    })
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

/// Find an unused TCP port by binding to :0 and reading back the assigned port.
fn pick_unused_port() -> anyhow::Result<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .context("failed to bind ephemeral port for anvil")?;
    let port = listener.local_addr()?.port();
    // Listener is dropped here, freeing the port for anvil.
    // There is a small TOCTOU window, but acceptable for dev/test tooling.
    Ok(port)
}
