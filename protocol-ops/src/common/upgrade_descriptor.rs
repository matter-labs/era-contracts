//! `l1-contracts/upgrade-envs/<upgrade>/upgrade.toml`: how the generate / replay / deploy
//! pipeline produces and checks one protocol upgrade.
//!
//! Two kinds exist:
//! - `prepare = "prepare-all"`: the v31 flow, `upgrade-prepare-all` plus PUVT.
//! - `prepare = "forge-script"`: one forge script, run on a fork as the deployer. Its
//!   broadcasts become the deployer's bundle, packed exactly like `upgrade-prepare-all`'s.
//!   The upgrade supplies its own checks, since PUVT only knows v31. An optional
//!   `[execution]` script writes the transactions whoever executes sends by hand; the
//!   pipeline replays them on the fork and renders `EXECUTE.md` from them. Its `envs`
//!   limits it to the environments whose governance can run it.

use std::path::{Path, PathBuf};

use alloy::dyn_abi::{DynSolType, DynSolValue, JsonAbiExt};
use alloy::json_abi::Function;
use anyhow::Context;
use serde::Deserialize;

use crate::common::env_config::PERMANENT_VALUES_DIR;
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
    /// How the upgrade is executed by hand, if the pipeline should write its runbook. Boxed:
    /// the variant carrying it would otherwise dwarf `PrepareAll`.
    #[serde(default)]
    pub execution: Option<Box<ExecutionScript>>,
}

/// A read-only forge script that writes the transactions whoever executes the upgrade sends
/// (a format `common::execution_runbook` reads), run on the generation fork after the deploy
/// bundle was replayed there.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExecutionScript {
    /// The environments that get the runbook; absent means every environment. Leave out
    /// one whose governance the script can't drive, e.g. behind a timer between stages.
    #[serde(default)]
    pub envs: Option<Vec<String>>,
    /// `path/To.s.sol:Contract`, relative to `l1-contracts/`.
    pub script: String,
    /// Solidity signature of the entry point.
    pub signature: String,
    /// Entry-point arguments, coerced to the signature's types; `{env}` becomes the env name.
    pub args: Vec<String>,
    /// The file the script writes, a bare name under `output/<env>/`.
    pub output: String,
}

/// A single path component, so it can't point outside the directory it is joined to.
fn is_plain_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// An upgrade name is a directory under `upgrade-envs/`; it arrives from workflow inputs
/// and bundle metadata, so it must not be able to point anywhere else.
pub fn validate_upgrade_name(upgrade: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        is_plain_name(upgrade),
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
        let permanent_values = paths::resolve_l1_contracts_path()?.join(PERMANENT_VALUES_DIR);
        Self::parse(&raw, |env| {
            permanent_values.join(format!("{env}.toml")).is_file()
        })
        .with_context(|| format!("parse {}", path.display()))
    }

    /// `has_permanent_values(env)`: whether `permanent-values/<env>.toml` exists.
    fn parse(raw: &str, has_permanent_values: impl Fn(&str) -> bool) -> anyhow::Result<Self> {
        let descriptor: Self = toml::from_str(raw)?;
        if let Self::ForgeScript(upgrade) = &descriptor {
            anyhow::ensure!(
                !upgrade.verify_fork.is_empty() && !upgrade.verify_chain.is_empty(),
                "a forge-script upgrade must declare verify_fork and verify_chain"
            );
            // Fail on a malformed signature or argument list when loading, not mid-run.
            upgrade.calldata("env")?;
            if let Some(execution) = &upgrade.execution {
                execution.calldata("env")?;
                anyhow::ensure!(
                    Path::new(&execution.output).file_name() == Some(execution.output.as_ref())
                        && execution.output != ".."
                        && execution.output != ".",
                    "execution.output {:?} must be a file name under output/<env>/",
                    execution.output
                );
                if let Some(envs) = &execution.envs {
                    anyhow::ensure!(
                        !envs.is_empty(),
                        "execution.envs is empty; drop it to run the script for every env"
                    );
                    for env in envs {
                        anyhow::ensure!(
                            is_plain_name(env) && has_permanent_values(env),
                            "execution.envs lists {env:?}, which has no permanent-values/<env>.toml"
                        );
                    }
                }
            }
        }
        Ok(descriptor)
    }
}

/// `args` with `{env}` substituted.
fn substitute_env(args: &[String], env: &str) -> Vec<String> {
    args.iter()
        .map(|arg| arg.replace(ENV_PLACEHOLDER, env))
        .collect()
}

/// ABI-encoded call of `signature` with `args`, each coerced to its parameter type.
fn encode_entry_point(signature: &str, args: &[String]) -> anyhow::Result<Vec<u8>> {
    let function =
        Function::parse(signature).with_context(|| format!("parse signature {signature:?}"))?;
    anyhow::ensure!(
        args.len() == function.inputs.len(),
        "{} takes {} argument(s), the descriptor gives {}",
        signature,
        function.inputs.len(),
        args.len()
    );
    let values = function
        .inputs
        .iter()
        .zip(args)
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

impl ExecutionScript {
    /// `args` with `{env}` substituted.
    pub fn args_for(&self, env: &str) -> Vec<String> {
        substitute_env(&self.args, env)
    }

    /// ABI-encoded call of the entry point for `env`.
    pub fn calldata(&self, env: &str) -> anyhow::Result<Vec<u8>> {
        encode_entry_point(&self.signature, &self.args_for(env))
    }

    /// The script path forge takes, relative to `l1-contracts/`.
    pub fn script_path(&self) -> &Path {
        Path::new(&self.script)
    }
}

impl ForgeScriptUpgrade {
    /// `args` with `{env}` substituted.
    pub fn args_for(&self, env: &str) -> Vec<String> {
        substitute_env(&self.args, env)
    }

    /// The `[execution]` script, if it applies to `env`.
    pub fn execution_for(&self, env: &str) -> Option<&ExecutionScript> {
        self.execution.as_deref().filter(|execution| {
            execution
                .envs
                .as_ref()
                .is_none_or(|envs| envs.iter().any(|listed| listed == env))
        })
    }

    /// ABI-encoded call of the entry point for `env`.
    pub fn calldata(&self, env: &str) -> anyhow::Result<Vec<u8>> {
        encode_entry_point(&self.signature, &self.args_for(env))
    }

    /// The script path forge takes, relative to `l1-contracts/`.
    pub fn script_path(&self) -> &Path {
        Path::new(&self.script)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Envs the unit tests treat as having permanent values.
    const KNOWN_ENVS: [&str; 2] = ["stage", "testnet"];

    fn parse(raw: &str) -> anyhow::Result<UpgradeDescriptor> {
        UpgradeDescriptor::parse(raw, |env| KNOWN_ENVS.contains(&env))
    }

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
            parse("prepare = \"prepare-all\"\n").unwrap(),
            UpgradeDescriptor::PrepareAll {}
        );
    }

    #[test]
    fn parses_forge_script_and_encodes_the_call() {
        let UpgradeDescriptor::ForgeScript(upgrade) = parse(FORGE_SCRIPT).unwrap() else {
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

    const EXECUTION: &str = r#"
[execution]
script = "deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol:EmergencyStageUpgradeCalldata"
signature = "emergencyUpgradeAllStages(string,string,string)"
args = ["/upgrade-envs/permanent-values/{env}.toml", "/upgrade-envs/v0.33.0-compiler/output/{env}/ecosystem.toml", "/upgrade-envs/v0.33.0-compiler/output/{env}/emergency-upgrade-board.json"]
output = "emergency-upgrade-board.json"
"#;

    #[test]
    fn parses_an_execution_script() {
        let UpgradeDescriptor::ForgeScript(upgrade) =
            parse(&format!("{FORGE_SCRIPT}{EXECUTION}")).unwrap()
        else {
            panic!("expected a forge-script upgrade");
        };
        let execution = upgrade.execution.expect("execution parsed");
        assert_eq!(execution.output, "emergency-upgrade-board.json");
        assert_eq!(
            execution.args_for("testnet")[0],
            "/upgrade-envs/permanent-values/testnet.toml"
        );
        let calldata = execution.calldata("testnet").unwrap();
        let selector =
            &alloy::primitives::keccak256("emergencyUpgradeAllStages(string,string,string)")[..4];
        assert_eq!(&calldata[..4], selector);
        // Without the table the upgrade has no runbook.
        let UpgradeDescriptor::ForgeScript(plain) = parse(FORGE_SCRIPT).unwrap() else {
            panic!("expected a forge-script upgrade");
        };
        assert_eq!(plain.execution, None);
    }

    #[test]
    fn rejects_an_execution_output_outside_the_env_dir_and_unknown_keys() {
        for bad in ["../x.json", "a/b.json", ".."] {
            let raw = format!("{FORGE_SCRIPT}{EXECUTION}").replace(
                "output = \"emergency-upgrade-board.json\"",
                &format!("output = {bad:?}"),
            );
            assert!(parse(&raw).is_err(), "{bad:?} accepted");
        }
        let raw = format!("{FORGE_SCRIPT}{EXECUTION}extra = 1\n");
        assert!(parse(&raw).is_err());
    }

    /// The descriptor with `envs = <envs>` in its `[execution]` table.
    fn with_execution_envs(envs: &str) -> String {
        format!("{FORGE_SCRIPT}{EXECUTION}")
            .replace("[execution]\n", &format!("[execution]\nenvs = {envs}\n"))
    }

    fn forge_script(raw: &str) -> ForgeScriptUpgrade {
        let UpgradeDescriptor::ForgeScript(upgrade) = parse(raw).unwrap() else {
            panic!("expected a forge-script upgrade");
        };
        upgrade
    }

    #[test]
    fn execution_without_envs_applies_to_every_env() {
        let upgrade = forge_script(&format!("{FORGE_SCRIPT}{EXECUTION}"));
        // Not even checked against permanent values: absent `envs` is the pre-`envs` behaviour.
        for env in ["stage", "testnet", "mainnet"] {
            assert!(upgrade.execution_for(env).is_some(), "{env}");
        }
    }

    #[test]
    fn execution_applies_only_to_the_listed_envs() {
        let upgrade = forge_script(&with_execution_envs(r#"["stage"]"#));
        assert_eq!(
            upgrade.execution_for("stage").unwrap().envs,
            Some(vec!["stage".to_string()])
        );
        assert_eq!(upgrade.execution_for("testnet"), None);
        assert_eq!(upgrade.execution_for("mainnet"), None);
    }

    #[test]
    fn rejects_empty_or_unknown_execution_envs() {
        for bad in ["[]", r#"["mainnet"]"#, r#"["stage", "mainnet"]"#] {
            assert!(parse(&with_execution_envs(bad)).is_err(), "{bad} accepted");
        }
        // A name that isn't a single path component fails even if the file it points to exists.
        for bad in [
            r#"["../permanent-values/stage"]"#,
            r#"["a/b"]"#,
            r#"[".."]"#,
            r#"[""]"#,
        ] {
            let raw = with_execution_envs(bad);
            assert!(
                UpgradeDescriptor::parse(&raw, |_| true).is_err(),
                "{bad} accepted"
            );
        }
    }

    #[test]
    fn rejects_a_wrong_argument_count() {
        let raw = FORGE_SCRIPT.replace(
            "signature = \"prepare(string,string)\"",
            "signature = \"prepare(string)\"",
        );
        assert!(parse(&raw).is_err());
    }

    #[test]
    fn rejects_missing_checks_and_unknown_fields() {
        assert!(parse(&FORGE_SCRIPT.replace("verify_chain", "# verify_chain")).is_err());
        assert!(parse("prepare = \"prepare-all\"\nextra = 1\n").is_err());
    }

    /// Every committed `upgrade-envs/<upgrade>/upgrade.toml` parses.
    #[test]
    fn every_committed_descriptor_loads() {
        let Ok(root) = paths::resolve_l1_contracts_path() else {
            return; // no checkout around the test binary
        };
        let mut loaded = 0;
        for entry in std::fs::read_dir(root.join("upgrade-envs")).unwrap() {
            let dir = entry.unwrap().path();
            if dir.join(UPGRADE_DESCRIPTOR_FILE).is_file() {
                let upgrade = dir.file_name().unwrap().to_str().unwrap().to_string();
                UpgradeDescriptor::load(&upgrade)
                    .unwrap_or_else(|error| panic!("{upgrade}: {error:#}"));
                loaded += 1;
            }
        }
        assert!(loaded > 0, "no upgrade.toml found");
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
