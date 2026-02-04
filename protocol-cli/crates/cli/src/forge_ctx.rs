use std::path::{Path, PathBuf};
use std::str::FromStr;

use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use protocol_cli_common::forge::{Forge, ForgeRunner, ForgeScriptArgs};
use protocol_cli_config::{
    forge_interface::script_params::ForgeScriptParams,
    traits::{ReadConfig, SaveConfig},
};
use xshell::Shell;

/// Anvil/Hardhat first default account private key.
/// Mnemonic: "test test test test test test test test test test test junk"
const DEV_PRIVATE_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

/// How the forge script authenticates transactions.
pub enum SenderAuth {
    /// Sign with a private key (forge --private-key)
    PrivateKey(H256),
    /// Unlocked account on the node (forge --sender --unlocked)
    Unlocked(Address),
}

/// Resolves authentication from CLI args.
/// Priority: --private-key > --dev > --sender (unlocked) > error
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
