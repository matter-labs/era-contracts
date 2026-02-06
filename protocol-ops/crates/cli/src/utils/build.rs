use protocol_ops_common::cmd::Cmd;
use std::path::PathBuf;
use xshell::{cmd, Shell};

pub fn build_all_contracts(shell: &Shell, contracts_code_path: &PathBuf) -> anyhow::Result<()> {
    install_yarn_dependencies(shell, contracts_code_path)?;
    build_l1_contracts(shell.clone(), contracts_code_path.clone())?;
    build_l1_da_contracts(shell.clone(), contracts_code_path.clone())?;
    build_l2_contracts(shell.clone(), contracts_code_path.clone())?;
    build_system_contracts(shell.clone(), contracts_code_path.clone())?;
    Ok(())
}

pub fn install_yarn_dependencies(
    shell: &Shell,
    contracts_code_path: &PathBuf,
) -> anyhow::Result<()> {
    let _dir_guard = shell.push_dir(contracts_code_path);
    Ok(Cmd::new(cmd!(shell, "yarn install")).run()?)
}

pub fn build_l1_contracts(shell: Shell, contracts_code_path: PathBuf) -> anyhow::Result<()> {
    let _dir_guard = shell.push_dir(contracts_code_path.join("l1-contracts"));
    // Do not update era-contract's lockfile to avoid dirty submodule
    // Note, tha the v26 contracts depend on the node_modules to be present at the time of the compilation.
    Cmd::new(cmd!(shell, "yarn install --frozen-lockfile")).run()?;
    Ok(Cmd::new(cmd!(shell, "yarn build:foundry")).run()?)
}

pub fn build_l1_da_contracts(shell: Shell, contracts_code_path: PathBuf) -> anyhow::Result<()> {
    let _dir_guard = shell.push_dir(contracts_code_path.join("da-contracts"));
    Ok(Cmd::new(cmd!(shell, "forge build")).run()?)
}

pub fn build_l2_contracts(shell: Shell, contracts_code_path: PathBuf) -> anyhow::Result<()> {
    let _dir_guard = shell.push_dir(contracts_code_path.join("l2-contracts"));
    Cmd::new(cmd!(shell, "yarn build:foundry")).run()?;
    Ok(())
}

pub fn build_system_contracts(shell: Shell, contracts_code_path: PathBuf) -> anyhow::Result<()> {
    let _dir_guard = shell.push_dir(contracts_code_path.join("system-contracts"));
    Ok(Cmd::new(cmd!(shell, "yarn build:foundry")).run()?)
}
