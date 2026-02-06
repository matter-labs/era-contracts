use std::path::Path;
use std::str::FromStr;

use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use protocol_ops_common::anvil::{self, AnvilInstance};
use protocol_ops_common::forge::{Forge, ForgeRunner, ForgeScriptArgs};
use protocol_ops_common::wallets::Wallet;
use protocol_ops_config::{
    forge_interface::script_params::ForgeScriptParams,
    traits::{ReadConfig, SaveConfig},
};
use xshell::Shell;

/// Anvil/Hardhat first default account private key.
/// Mnemonic: "test test test test test test test test test test test junk"
const DEV_PRIVATE_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

/// How the forge script authenticates transactions.
#[derive(Clone)]
pub enum SenderAuth {
    /// Sign with a private key (forge --private-key)
    PrivateKey(H256),
    /// Unlocked account on the node (forge --sender --unlocked)
    Unlocked(Address),
}

impl SenderAuth {
    /// Convert to a Wallet for use with forge scripts that need a Wallet.
    pub fn to_wallet(&self) -> anyhow::Result<Wallet> {
        match self {
            SenderAuth::PrivateKey(pk) => {
                let local_wallet = LocalWallet::from_bytes(pk.as_bytes())
                    .map_err(|e| anyhow::anyhow!("Invalid private key: {}", e))?;
                Ok(Wallet {
                    address: local_wallet.address(),
                    private_key: Some(local_wallet),
                })
            }
            SenderAuth::Unlocked(addr) => Ok(Wallet {
                address: *addr,
                private_key: None,
            }),
        }
    }
}

/// Whether the command is executing for real or simulating against an anvil fork.
pub enum ExecutionMode {
    /// Broadcast transactions to the target RPC.
    Broadcast,
    /// Fork the target RPC with anvil, run against the fork, tear down on drop.
    Simulate(AnvilInstance),
}

impl ExecutionMode {
    /// The RPC URL that forge scripts should target.
    pub fn rpc_url<'a>(&'a self, original: &'a str) -> &'a str {
        match self {
            ExecutionMode::Broadcast => original,
            ExecutionMode::Simulate(anvil) => anvil.rpc_url(),
        }
    }
}

/// Resolves authentication and execution mode from CLI args.
///
/// Rules:
/// - `--simulate` forces simulation mode (anvil fork with auto-impersonate)
/// - Without `--simulate`:
///   - `--private-key` → Broadcast with that key
///   - `--dev` → Broadcast with the hardcoded dev key
///   - `--sender` (no key) → Simulate (implicit)
/// - At least one of `--private-key`, `--dev`, or `--sender` must be provided
pub fn resolve_execution(
    private_key: Option<H256>,
    sender: Option<Address>,
    dev: bool,
    simulate: bool,
    l1_rpc_url: &str,
) -> anyhow::Result<(SenderAuth, Address, ExecutionMode)> {
    // Resolve the sender address and optional private key
    let (resolved_addr, resolved_pk) = if let Some(pk) = private_key {
        let wallet = LocalWallet::from_bytes(pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid private key: {}", e))?;
        if let Some(sender) = sender {
            if sender != wallet.address() {
                anyhow::bail!(
                    "Sender address does not match private key: got {:#x}, want {:#x}",
                    sender,
                    wallet.address()
                );
            }
        }
        (wallet.address(), Some(pk))
    } else if dev {
        let pk = H256::from_str(DEV_PRIVATE_KEY)?;
        let wallet = LocalWallet::from_bytes(pk.as_bytes()).unwrap();
        (wallet.address(), Some(pk))
    } else if let Some(sender) = sender {
        (sender, None)
    } else {
        anyhow::bail!("Either --private-key, --dev, or --sender must be provided");
    };

    // Determine execution mode
    if simulate {
        // --simulate forces simulation, even if pk is provided
        let anvil = anvil::start_anvil_fork(l1_rpc_url)?;
        Ok((
            SenderAuth::Unlocked(resolved_addr),
            resolved_addr,
            ExecutionMode::Simulate(anvil),
        ))
    } else if let Some(pk) = resolved_pk {
        // Have a key and not simulating → broadcast
        Ok((
            SenderAuth::PrivateKey(pk),
            resolved_addr,
            ExecutionMode::Broadcast,
        ))
    } else {
        // No key and no --simulate → implicit simulation
        let anvil = anvil::start_anvil_fork(l1_rpc_url)?;
        Ok((
            SenderAuth::Unlocked(resolved_addr),
            resolved_addr,
            ExecutionMode::Simulate(anvil),
        ))
    }
}

/// Backward-compatible resolver that doesn't manage execution mode.
/// Kept for commands that haven't been migrated yet.
pub fn resolve_sender(
    private_key: Option<H256>,
    sender: Option<Address>,
    dev: bool,
) -> anyhow::Result<(SenderAuth, Address)> {
    if let Some(pk) = private_key {
        let wallet = LocalWallet::from_bytes(pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid private key: {}", e))?;
        if let Some(sender) = sender {
            if sender != wallet.address() {
                anyhow::bail!(
                    "Sender address does not match private key: got {:#x}, want {:#x}",
                    sender,
                    wallet.address()
                );
            }
        }
        Ok((SenderAuth::PrivateKey(pk), wallet.address()))
    } else if dev {
        let pk = H256::from_str(DEV_PRIVATE_KEY)?;
        let wallet = LocalWallet::from_bytes(pk.as_bytes()).unwrap();
        Ok((SenderAuth::PrivateKey(pk), wallet.address()))
    } else if let Some(sender) = sender {
        Ok((SenderAuth::Unlocked(sender), sender))
    } else {
        anyhow::bail!("Either --private-key, --dev, or --sender must be provided");
    }
}

/// Common context for running forge scripts.
pub struct ForgeContext<'a> {
    pub shell: &'a Shell,
    pub foundry_scripts_path: &'a Path,
    pub runner: &'a mut ForgeRunner,
    pub forge_args: &'a ForgeScriptArgs,
    pub l1_rpc_url: &'a str,
    pub auth: &'a SenderAuth,
}

impl<'a> ForgeContext<'a> {
    /// Write input config, run forge script, read output.
    pub fn run<I: SaveConfig, O: ReadConfig>(
        &mut self,
        params: &ForgeScriptParams,
        input: &I,
    ) -> anyhow::Result<O> {
        // Write input config
        let input_path = params.input(self.foundry_scripts_path);
        input.save(self.shell, input_path)?;

        // Build forge command
        let mut forge = Forge::new(self.foundry_scripts_path)
            .script(&params.script(), self.forge_args.clone())
            .with_ffi()
            .with_rpc_url(self.l1_rpc_url.to_string())
            .with_broadcast()
            .with_slow();

        match self.auth {
            SenderAuth::PrivateKey(pk) => {
                forge = forge.with_private_key(*pk);
            }
            SenderAuth::Unlocked(addr) => {
                forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked();
            }
        }

        // Run
        self.runner.run(self.shell, forge)?;

        // Read output
        let output_path = params.output(self.foundry_scripts_path);
        O::read(self.shell, output_path)
    }
}
