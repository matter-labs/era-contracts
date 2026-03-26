use std::path::Path;

use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScript, ForgeScriptArgs},
    wallets::Wallet,
};
use crate::config::{
    forge_interface::script_params::ACCEPT_GOVERNANCE_SCRIPT_PARAMS,
    traits::{FileConfigTrait, ReadConfig},
};
use crate::types::L2DACommitmentScheme;
use ethers::{
    contract::BaseContract,
    types::{Address, Bytes, U256},
    utils::hex,
};
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::{
    abi::ADMINFUNCTIONSABI_ABI,
    commands::chain::admin_call_builder::{decode_admin_calls, AdminCall},
    utils::forge::{fill_forge_private_key, WalletOwner},
};

lazy_static! {
    static ref ADMIN_FUNCTIONS: BaseContract = BaseContract::from(ADMINFUNCTIONSABI_ABI.clone());
}

pub async fn accept_admin(
    shell: &Shell,
    runner: &mut ForgeRunner,
    foundry_contracts_path: &Path,
    admin: Address,
    governor: &Wallet,
    target_address: Address,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
) -> anyhow::Result<()> {
    let calldata = ADMIN_FUNCTIONS
        .encode("chainAdminAcceptAdmin", (admin, target_address))
        .unwrap();
    let forge = Forge::new(&foundry_contracts_path)
        .script(
            &ACCEPT_GOVERNANCE_SCRIPT_PARAMS.script(),
            forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(l1_rpc_url)
        .with_broadcast()
        .with_calldata(&calldata);
    accept_ownership(shell, runner, governor, forge).await
}

pub async fn accept_owner(
    shell: &Shell,
    runner: &mut ForgeRunner,
    foundry_contracts_path: &Path,
    governor_contract: Address,
    governor: &Wallet,
    target_address: Address,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
) -> anyhow::Result<()> {
    let calldata = ADMIN_FUNCTIONS
        .encode("governanceAcceptOwner", (governor_contract, target_address))
        .unwrap();
    let forge = Forge::new(&foundry_contracts_path)
        .script(
            &ACCEPT_GOVERNANCE_SCRIPT_PARAMS.script(),
            forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(l1_rpc_url)
        .with_broadcast()
        .with_calldata(&calldata);
    accept_ownership(shell, runner, governor, forge).await
}

pub async fn accept_owner_aggregated(
    shell: &Shell,
    runner: &mut ForgeRunner,
    foundry_contracts_path: &Path,
    governor_contract: Address,
    governor: &Wallet,
    target_address: Address,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
) -> anyhow::Result<()> {
    let calldata = ADMIN_FUNCTIONS
        .encode(
            "governanceAcceptOwnerAggregated",
            (governor_contract, target_address),
        )
        .unwrap();
    let forge = Forge::new(&foundry_contracts_path)
        .script(
            &ACCEPT_GOVERNANCE_SCRIPT_PARAMS.script(),
            forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(l1_rpc_url)
        .with_broadcast()
        .with_calldata(&calldata);
    accept_ownership(shell, runner, governor, forge).await
}

async fn accept_ownership(
    shell: &Shell,
    runner: &mut ForgeRunner,
    governor: &Wallet,
    mut forge: ForgeScript,
) -> anyhow::Result<()> {
    forge = fill_forge_private_key(forge, Some(governor), WalletOwner::Governor)?;
    runner.run(shell, forge)?;
    Ok(())
}

#[derive(Clone)]
pub enum AdminScriptMode {
    OnlySave,
    Broadcast(Wallet),
}

impl AdminScriptMode {
    fn should_send(&self) -> bool {
        matches!(self, AdminScriptMode::Broadcast(_))
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub(crate) struct AdminScriptOutputInner {
    admin_address: Address,
    encoded_data: String,
}

impl FileConfigTrait for AdminScriptOutputInner {}

#[derive(Debug, Clone, Default)]
pub struct AdminScriptOutput {
    pub admin_address: Address,
    pub calls: Vec<AdminCall>,
}

impl From<AdminScriptOutputInner> for AdminScriptOutput {
    fn from(value: AdminScriptOutputInner) -> Self {
        Self {
            admin_address: value.admin_address,
            calls: decode_admin_calls(&hex::decode(value.encoded_data).unwrap()).unwrap(),
        }
    }
}

pub async fn call_script(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_contracts_path: &Path,
    mode: AdminScriptMode,
    calldata: Bytes,
    l1_rpc_url: String,
    description: &str,
) -> anyhow::Result<AdminScriptOutput> {
    let forge = Forge::new(foundry_contracts_path)
        .script(
            &ACCEPT_GOVERNANCE_SCRIPT_PARAMS.script(),
            forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(l1_rpc_url)
        .with_calldata(&calldata);

    let (forge, _spiner_text) = match mode {
        AdminScriptMode::OnlySave => (forge, format!("Preparing calldata for {description}")),
        AdminScriptMode::Broadcast(wallet) => {
            let forge = forge.with_broadcast();
            let forge = fill_forge_private_key(forge, Some(&wallet), WalletOwner::Governor)?;
            (forge, format!("Executing {description}"))
        }
    };

    let output_path = ACCEPT_GOVERNANCE_SCRIPT_PARAMS.output(foundry_contracts_path);

    // let spinner = Spinner::new(&spiner_text);
    runner.run(shell, forge)?;
    // spinner.finish();
    Ok(AdminScriptOutputInner::read(shell, output_path)?.into())
}

#[allow(clippy::too_many_arguments)]
pub async fn set_da_validator_pair(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_contracts_path: &Path,
    mode: AdminScriptMode,
    chain_id: u64,
    bridgehub: Address,
    l1_da_validator_address: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
    l1_rpc_url: String,
) -> anyhow::Result<AdminScriptOutput> {
    let calldata = ADMIN_FUNCTIONS
        .encode(
            "setDAValidatorPair",
            (
                bridgehub,
                U256::from(chain_id),
                l1_da_validator_address,
                l2_da_commitment_scheme as u8,
                mode.should_send(),
            ),
        )
        .unwrap();

    call_script(
        shell,
        runner,
        forge_args,
        foundry_contracts_path,
        mode,
        calldata,
        l1_rpc_url,
        &format!(
            "setting data availability validator pair ({:#?}, {:#?}) for chain {}",
            l1_da_validator_address, l2_da_commitment_scheme, chain_id
        ),
    )
    .await
}

pub async fn unpause_deposits(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_contracts_path: &Path,
    mode: AdminScriptMode,
    chain_id: u64,
    bridgehub: Address,
    l1_rpc_url: String,
) -> anyhow::Result<AdminScriptOutput> {
    let calldata = ADMIN_FUNCTIONS
        .encode(
            "unpauseDeposits",
            (bridgehub, U256::from(chain_id), mode.should_send()),
        )
        .unwrap();

    call_script(
        shell,
        runner,
        forge_args,
        foundry_contracts_path,
        mode,
        calldata,
        l1_rpc_url,
        &format!("unpausing deposits for chain {}", chain_id),
    )
    .await
}
