use std::path::{Path, PathBuf};

use clap::{Parser, ValueEnum};
use ethers::{contract::BaseContract, core::abi::Tokenize, core::types::Bytes, utils::hex};
use serde::{Deserialize, Serialize};
use strum::Display;

use crate::common::wallets::Wallet;

/// ForgeScript is a wrapper around the forge script command.
#[derive(Clone)]
pub struct ForgeScript {
    pub(crate) base_path: PathBuf,
    pub(crate) script_path: PathBuf,
    pub(crate) args: ForgeScriptArgs,
    pub(crate) envs: Vec<(String, String)>,
    pub(crate) timing_label: Option<String>,
}

impl ForgeScript {
    pub fn with_timing_label(mut self, label: impl Into<String>) -> Self {
        self.timing_label = Some(label.into());
        self
    }

    /// Add the ffi flag to the forge script command.
    pub fn with_ffi(mut self) -> Self {
        self.args.add_arg(ForgeScriptArg::Ffi);
        self
    }

    /// Add the sender address to the forge script command.
    pub fn with_sender(mut self, address: String) -> Self {
        self.args.add_arg(ForgeScriptArg::Sender { address });
        self
    }

    pub fn with_unlocked(mut self) -> Self {
        self.args.add_arg(ForgeScriptArg::Unlocked);
        self
    }

    /// Add the rpc-url flag to the forge script command.
    pub fn with_rpc_url(mut self, rpc_url: String) -> Self {
        self.args.add_arg(ForgeScriptArg::RpcUrl { url: rpc_url });
        self
    }

    /// Add the broadcast flag to the forge script command.
    ///
    /// Also adds `--slow`: forge waits for each tx to be confirmed before
    /// sending the next, which is required for correctness against the anvil
    /// fork.
    pub fn with_broadcast(mut self) -> Self {
        self.args.add_arg(ForgeScriptArg::Broadcast);
        self.args.add_arg(ForgeScriptArg::Slow);
        self
    }

    pub fn with_calldata(mut self, calldata: &Bytes) -> Self {
        self.args.add_arg(ForgeScriptArg::Sig {
            sig: hex::encode(calldata),
        });
        self
    }

    pub fn with_contract_call<T: Tokenize>(
        self,
        contract: &BaseContract,
        function: &str,
        args: T,
    ) -> anyhow::Result<Self> {
        let calldata = contract
            .encode(function, args)
            .map_err(|error| anyhow::anyhow!("failed to encode {}: {}", function, error))?;
        Ok(self.with_calldata(&calldata))
    }

    pub fn with_gas_limit(mut self, gas_limit: u64) -> Self {
        self.args.add_arg(ForgeScriptArg::GasLimit { gas_limit });
        self
    }

    /// Add an environment variable that will be set when running the script.
    pub fn with_env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.envs.push((key.into(), value.into()));
        self
    }

    /// Apply wallet authentication against the anvil fork: always uses
    /// `--sender --unlocked` so forge impersonates the wallet's address via
    /// anvil auto-impersonation. Any private key on the wallet is ignored —
    /// this Forge script never broadcasts against real L1.
    pub fn with_wallet(self, wallet: &Wallet) -> Self {
        self.with_sender(format!("{:#x}", wallet.address))
            .with_unlocked()
    }

    pub(crate) fn sig(&self) -> Option<String> {
        self.args.args.iter().find_map(|a| {
            if let ForgeScriptArg::Sig { sig } = a {
                Some(sig.clone())
            } else {
                None
            }
        })
    }

    pub(crate) fn is_broadcast(&self) -> bool {
        self.args
            .args
            .iter()
            .any(|a| matches!(a, ForgeScriptArg::Broadcast))
    }

    pub(crate) fn needs_bridgehub_skip(&self) -> bool {
        self.script_path == Path::new("deploy-scripts/DeployCTM.s.sol")
    }

    pub(crate) fn script_name(&self) -> &Path {
        &self.script_path
    }

    pub(crate) fn base_path(&self) -> &Path {
        &self.base_path
    }
}

const PROHIBITED_ARGS: [&str; 10] = [
    "--contracts",
    "--root",
    "--lib-paths",
    "--out",
    "--sig",
    "--target-contract",
    "--chain-id",
    "-C",
    "-O",
    "-s",
];

/// Set of known forge script arguments necessary for execution.
#[derive(Display, Debug, Serialize, Deserialize, Clone, PartialEq)]
#[strum(serialize_all = "kebab-case", prefix = "--")]
pub enum ForgeScriptArg {
    Broadcast,
    #[strum(to_string = "etherscan-api-key={api_key}")]
    EtherscanApiKey {
        api_key: String,
    },
    Ffi,
    #[strum(to_string = "rpc-url={url}")]
    RpcUrl {
        url: String,
    },
    #[strum(to_string = "sig={sig}")]
    Sig {
        sig: String,
    },
    Slow,
    #[strum(to_string = "verifier={verifier}")]
    Verifier {
        verifier: String,
    },
    #[strum(to_string = "verifier-url={url}")]
    VerifierUrl {
        url: String,
    },
    Verify,
    #[strum(to_string = "sender={address}")]
    Sender {
        address: String,
    },
    #[strum(to_string = "gas-limit={gas_limit}")]
    GasLimit {
        gas_limit: u64,
    },
    Unlocked,
    Zksync,
    #[strum(to_string = "skip={skip_path}")]
    Skip {
        skip_path: String,
    },
}

/// ForgeScriptArgs is a set of arguments that can be passed to the forge script command.
#[derive(Default, Debug, Serialize, Deserialize, Parser, Clone)]
#[clap(next_help_heading = "Forge options")]
pub struct ForgeScriptArgs {
    /// List of known forge script arguments.
    #[clap(skip)]
    pub(crate) args: Vec<ForgeScriptArg>,
    /// Verify deployed contracts
    #[clap(long, default_missing_value = "true", num_args = 0..=1)]
    pub verify: Option<bool>,
    /// Verifier to use
    #[clap(long, default_value_t = ForgeVerifier::Etherscan)]
    pub verifier: ForgeVerifier,
    /// Verifier URL, if using a custom provider
    #[clap(long)]
    pub verifier_url: Option<String>,
    /// Verifier API key
    #[clap(long)]
    pub verifier_api_key: Option<String>,
    #[clap(long)]
    pub zksync: bool,
    /// List of additional arguments that can be passed through the CLI.
    ///
    /// e.g.: `[COMMAND] -a --with-gas-price=4000000000`
    #[clap(long, short)]
    #[arg(trailing_var_arg = true, allow_hyphen_values = true, hide = false)]
    pub(crate) additional_args: Vec<String>,
}

impl ForgeScriptArgs {
    /// Build the forge script command arguments.
    pub fn build(&mut self) -> Vec<String> {
        self.add_verify_args();
        self.cleanup_contract_args();
        if self.zksync {
            self.add_arg(ForgeScriptArg::Zksync);
        }

        self.args
            .iter()
            .map(|arg| arg.to_string())
            .chain(self.additional_args.clone())
            .collect()
    }

    /// Adds verify arguments to the forge script command.
    fn add_verify_args(&mut self) {
        if !self.verify.is_some_and(|v| v) {
            return;
        }

        self.add_arg(ForgeScriptArg::Verify);
        if let Some(url) = &self.verifier_url {
            self.add_arg(ForgeScriptArg::VerifierUrl { url: url.clone() });
        }
        if let Some(api_key) = &self.verifier_api_key {
            self.add_arg(ForgeScriptArg::EtherscanApiKey {
                api_key: api_key.clone(),
            });
        }
        self.add_arg(ForgeScriptArg::Verifier {
            verifier: self.verifier.to_string(),
        });
    }

    /// Cleanup the contract arguments which are not allowed to be passed through the CLI.
    fn cleanup_contract_args(&mut self) {
        let mut skip_next = false;
        let mut cleaned_args = vec![];
        let mut forbidden_args = vec![];

        let prohibited_with_spacing: Vec<String> = PROHIBITED_ARGS
            .iter()
            .flat_map(|arg| vec![format!("{arg} "), format!("{arg}\t")])
            .collect();

        let prohibited_with_equals: Vec<String> = PROHIBITED_ARGS
            .iter()
            .map(|arg| format!("{arg}="))
            .collect();

        for arg in self.additional_args.iter() {
            if skip_next {
                skip_next = false;
                continue;
            }

            if prohibited_with_spacing
                .iter()
                .any(|prohibited_arg| arg.starts_with(prohibited_arg))
            {
                skip_next = true;
                forbidden_args.push(arg.clone());
                continue;
            }

            if prohibited_with_equals
                .iter()
                .any(|prohibited_arg| arg.starts_with(prohibited_arg))
            {
                skip_next = false;
                forbidden_args.push(arg.clone());
                continue;
            }

            cleaned_args.push(arg.clone());
        }

        if !forbidden_args.is_empty() {
            println!(
                "Warning: the following arguments are not allowed to be passed through the CLI and were skipped: {:?}",
                forbidden_args
            );
        }

        self.additional_args = cleaned_args;
    }

    /// Add additional arguments to the forge script command.
    /// If the argument already exists, a warning will be printed.
    pub fn add_arg(&mut self, arg: ForgeScriptArg) {
        if self.args.contains(&arg) {
            println!("Warning: argument {arg:?} already exists");
            return;
        }
        self.args.push(arg);
    }
}

#[derive(Debug, Clone, ValueEnum, Display, Serialize, Deserialize, Default)]
#[strum(serialize_all = "snake_case")]
pub enum ForgeVerifier {
    #[default]
    Etherscan,
    Sourcify,
    Blockscout,
    Oklink,
}
