//! `l1-contracts/upgrade-envs/<upgrade>/upgrade.toml`: how the generate / replay / deploy
//! pipeline produces and checks one protocol upgrade.
//!
//! Two kinds exist:
//! - `prepare = "prepare-all"`: the v31 flow, `upgrade-prepare-all` plus PUVT.
//! - `prepare = "forge-script"`: one forge script, run on a fork as the deployer. Its
//!   broadcasts become the deployer's bundle, packed exactly like `upgrade-prepare-all`'s.
//!   The upgrade supplies its own checks, since PUVT only knows v31.

use std::path::{Path, PathBuf};

use alloy::dyn_abi::{DynSolType, DynSolValue, JsonAbiExt};
use alloy::json_abi::Function;
use anyhow::Context;
use serde::Deserialize;

use crate::common::paths;

pub const UPGRADE_DESCRIPTOR_FILE: &str = "upgrade.toml";

/// Placeholder in `args` for the environment name.
const ENV_PLACEHOLDER: &str = "{env}";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "prepare", rename_all = "kebab-case", deny_unknown_fields)]
pub enum UpgradeDescriptor {
    /// `upgrade-prepare-all` and PUVT. A struct variant so unknown keys are rejected.
    PrepareAll {},
    /// One forge script whose broadcasts are the deployer's bundle.
    ForgeScript(ForgeScriptUpgrade),
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ForgeScriptUpgrade {
    /// `path/To.s.sol:Contract`, relative to `l1-contracts/`.
    pub script: String,
    /// Solidity signature of the entry point, e.g. `prepare(string,string)`.
    pub signature: String,
    /// Entry-point arguments, coerced to the signature's types. `{env}` becomes the
    /// environment name. The script must write `output/<env>/ecosystem.toml` of its upgrade
    /// directory.
    pub args: Vec<String>,
    /// Checks a fork on which the bundle was replayed; may send impersonated transactions.
    /// Run from `l1-contracts/` with `L1_RPC_URL`, `ECOSYSTEM_TOML` and `UPGRADE_ENV` set.
    pub verify_fork: Vec<String>,
    /// Read-only checks against a real chain the bundle was broadcast to. Same environment
    /// as `verify_fork`; must never send a transaction.
    pub verify_chain: Vec<String>,
}

/// An upgrade name is a directory under `upgrade-envs/`; it arrives from workflow inputs
/// and bundle metadata, so it must not be able to point anywhere else.
pub fn validate_upgrade_name(upgrade: &str) -> anyhow::Result<()> {
    let valid = !upgrade.is_empty()
        && upgrade != "."
        && upgrade != ".."
        && upgrade
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'));
    anyhow::ensure!(
        valid,
        "invalid upgrade name {upgrade:?}: expected a directory name under upgrade-envs/"
    );
    Ok(())
}

/// `l1-contracts/upgrade-envs/<upgrade>/`.
pub fn upgrade_dir(upgrade: &str) -> anyhow::Result<PathBuf> {
    validate_upgrade_name(upgrade)?;
    Ok(paths::resolve_l1_contracts_path()?
        .join("upgrade-envs")
        .join(upgrade))
}

impl UpgradeDescriptor {
    pub fn load(upgrade: &str) -> anyhow::Result<Self> {
        let path = upgrade_dir(upgrade)?.join(UPGRADE_DESCRIPTOR_FILE);
        let raw = std::fs::read_to_string(&path)
            .with_context(|| format!("read upgrade descriptor {}", path.display()))?;
        Self::parse(&raw).with_context(|| format!("parse {}", path.display()))
    }

    fn parse(raw: &str) -> anyhow::Result<Self> {
        let descriptor: Self = toml::from_str(raw)?;
        if let Self::ForgeScript(upgrade) = &descriptor {
            anyhow::ensure!(
                !upgrade.verify_fork.is_empty() && !upgrade.verify_chain.is_empty(),
                "a forge-script upgrade must declare verify_fork and verify_chain"
            );
            // Fail on a malformed signature or argument list when loading, not mid-run.
            upgrade.calldata("env")?;
        }
        Ok(descriptor)
    }
}

impl ForgeScriptUpgrade {
    /// `args` with `{env}` substituted.
    pub fn args_for(&self, env: &str) -> Vec<String> {
        self.args
            .iter()
            .map(|arg| arg.replace(ENV_PLACEHOLDER, env))
            .collect()
    }

    /// ABI-encoded call of the entry point for `env`.
    pub fn calldata(&self, env: &str) -> anyhow::Result<Vec<u8>> {
        let function = Function::parse(&self.signature)
            .with_context(|| format!("parse signature {:?}", self.signature))?;
        let args = self.args_for(env);
        anyhow::ensure!(
            args.len() == function.inputs.len(),
            "{} takes {} argument(s), the descriptor gives {}",
            self.signature,
            function.inputs.len(),
            args.len()
        );
        let values = function
            .inputs
            .iter()
            .zip(&args)
            .map(|(param, arg)| {
                let ty: DynSolType = param
                    .ty
                    .parse()
                    .with_context(|| format!("type {}", param.ty))?;
                ty.coerce_str(arg)
                    .with_context(|| format!("argument {arg:?} as {}", param.ty))
            })
            .collect::<anyhow::Result<Vec<DynSolValue>>>()?;
        Ok(function.abi_encode_input(&values)?)
    }

    /// The script path forge takes, relative to `l1-contracts/`.
    pub fn script_path(&self) -> &Path {
        Path::new(&self.script)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FORGE_SCRIPT: &str = r#"
prepare = "forge-script"
script = "deploy-scripts/upgrade/v33/CTMUpgrade_v33.s.sol:CTMUpgrade_v33"
signature = "prepare(string,string)"
args = ["/upgrade-envs/v0.33.0-compiler/{env}.toml", "/upgrade-envs/v0.33.0-compiler/output/{env}/ecosystem.toml"]
verify_fork = ["bash", "upgrade-envs/v0.33.0-compiler/rehearse-stage.sh"]
verify_chain = ["bash", "upgrade-envs/v0.33.0-compiler/rehearse-stage.sh", "--published-only"]
"#;

    #[test]
    fn parses_prepare_all() {
        assert_eq!(
            UpgradeDescriptor::parse("prepare = \"prepare-all\"\n").unwrap(),
            UpgradeDescriptor::PrepareAll {}
        );
    }

    #[test]
    fn parses_forge_script_and_encodes_the_call() {
        let UpgradeDescriptor::ForgeScript(upgrade) =
            UpgradeDescriptor::parse(FORGE_SCRIPT).unwrap()
        else {
            panic!("expected a forge-script upgrade");
        };
        assert_eq!(
            upgrade.args_for("stage"),
            vec![
                "/upgrade-envs/v0.33.0-compiler/stage.toml".to_string(),
                "/upgrade-envs/v0.33.0-compiler/output/stage/ecosystem.toml".to_string(),
            ]
        );
        let calldata = upgrade.calldata("stage").unwrap();
        let selector = &alloy::primitives::keccak256("prepare(string,string)")[..4];
        assert_eq!(&calldata[..4], selector);
        let decoded = Function::parse("prepare(string,string)")
            .unwrap()
            .abi_decode_input(&calldata[4..])
            .unwrap();
        assert_eq!(
            decoded[1].as_str(),
            Some("/upgrade-envs/v0.33.0-compiler/output/stage/ecosystem.toml")
        );
    }

    #[test]
    fn rejects_a_wrong_argument_count() {
        let raw = FORGE_SCRIPT.replace(
            "signature = \"prepare(string,string)\"",
            "signature = \"prepare(string)\"",
        );
        assert!(UpgradeDescriptor::parse(&raw).is_err());
    }

    #[test]
    fn rejects_missing_checks_and_unknown_fields() {
        assert!(
            UpgradeDescriptor::parse(&FORGE_SCRIPT.replace("verify_chain", "# verify_chain"))
                .is_err()
        );
        assert!(UpgradeDescriptor::parse("prepare = \"prepare-all\"\nextra = 1\n").is_err());
    }

    #[test]
    fn rejects_upgrade_names_that_leave_upgrade_envs() {
        for bad in [
            "",
            ".",
            "..",
            "../permanent-values",
            "a/b",
            "v0.33.0 compiler",
        ] {
            assert!(validate_upgrade_name(bad).is_err(), "{bad:?} accepted");
        }
        for good in ["v0.31.0-interopB", "v0.33.0-compiler", "v34_force_fail"] {
            validate_upgrade_name(good).unwrap();
        }
    }
}
