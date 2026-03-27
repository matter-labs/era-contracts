use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScript},
    traits::{FileConfigTrait, ReadConfig},
    wallets::Wallet,
};
use crate::config::forge_interface::script_params::ACCEPT_GOVERNANCE_SCRIPT_PARAMS;
use crate::types::L2DACommitmentScheme;
use ethers::{
    contract::BaseContract,
    types::{Address, Bytes, U256},
    utils::hex,
};
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};

use crate::{
    abi::ADMINFUNCTIONSABI_ABI,
    commands::chain::admin_call_builder::{decode_admin_calls, AdminCall},
};

lazy_static! {
    static ref ADMIN_FUNCTIONS: BaseContract = BaseContract::from(ADMINFUNCTIONSABI_ABI.clone());
}

pub async fn accept_admin(
    runner: &mut ForgeRunner,
    admin: Address,
    governor: &Wallet,
    target_address: Address,
) -> anyhow::Result<()> {
    let calldata = ADMIN_FUNCTIONS
        .encode("chainAdminAcceptAdmin", (admin, target_address))
        .unwrap();
    let forge = build_governance_forge(runner, &calldata).with_broadcast();
    accept_ownership(runner, governor, forge).await
}

pub async fn accept_owner(
    runner: &mut ForgeRunner,
    governor_contract: Address,
    governor: &Wallet,
    target_address: Address,
) -> anyhow::Result<()> {
    let calldata = ADMIN_FUNCTIONS
        .encode("governanceAcceptOwner", (governor_contract, target_address))
        .unwrap();
    let forge = build_governance_forge(runner, &calldata).with_broadcast();
    accept_ownership(runner, governor, forge).await
}

pub async fn accept_owner_aggregated(
    runner: &mut ForgeRunner,
    governor_contract: Address,
    governor: &Wallet,
    target_address: Address,
) -> anyhow::Result<()> {
    let calldata = ADMIN_FUNCTIONS
        .encode(
            "governanceAcceptOwnerAggregated",
            (governor_contract, target_address),
        )
        .unwrap();
    let forge = build_governance_forge(runner, &calldata).with_broadcast();
    accept_ownership(runner, governor, forge).await
}

async fn accept_ownership(
    runner: &mut ForgeRunner,
    governor: &Wallet,
    forge: ForgeScript,
) -> anyhow::Result<()> {
    let forge = forge.with_wallet(governor, runner.simulate);
    runner.run(forge)?;
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
    runner: &mut ForgeRunner,
    mode: AdminScriptMode,
    calldata: Bytes,
) -> anyhow::Result<AdminScriptOutput> {
    let forge = build_governance_forge(runner, &calldata);

    let forge = match mode {
        AdminScriptMode::OnlySave => forge,
        AdminScriptMode::Broadcast(ref wallet) => {
            forge.with_broadcast().with_wallet(wallet, runner.simulate)
        }
    };

    let output_path = ACCEPT_GOVERNANCE_SCRIPT_PARAMS.output(&runner.foundry_scripts_path);
    runner.run(forge)?;
    Ok(AdminScriptOutputInner::read(&runner.shell, output_path)?.into())
}

pub async fn unpause_deposits(
    runner: &mut ForgeRunner,
    mode: AdminScriptMode,
    chain_id: u64,
    bridgehub: Address,
) -> anyhow::Result<AdminScriptOutput> {
    let calldata = ADMIN_FUNCTIONS
        .encode(
            "unpauseDeposits",
            (bridgehub, U256::from(chain_id), mode.should_send()),
        )
        .unwrap();

    call_script(runner, mode, calldata).await
}

pub async fn make_permanent_rollup(
    runner: &mut ForgeRunner,
    chain_admin_addr: Address,
    governor: &Wallet,
    diamond_proxy_address: Address,
) -> anyhow::Result<()> {
    let calldata = ADMIN_FUNCTIONS
        .encode(
            "makePermanentRollup",
            (chain_admin_addr, diamond_proxy_address),
        )
        .unwrap();
    let forge = build_governance_forge(runner, &calldata).with_broadcast();
    accept_ownership(runner, governor, forge).await
}

pub async fn set_da_validator_pair(
    runner: &mut ForgeRunner,
    mode: AdminScriptMode,
    chain_id: u64,
    bridgehub: Address,
    l1_da_validator_address: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
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

    call_script(runner, mode, calldata).await
}

/// Build a standard governance ForgeScript without auth or broadcast (caller adds those).
fn build_governance_forge(runner: &ForgeRunner, calldata: &Bytes) -> ForgeScript {
    Forge::new(&runner.foundry_scripts_path)
        .script(
            &ACCEPT_GOVERNANCE_SCRIPT_PARAMS.script(),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(runner.rpc_url.clone())
        .with_calldata(calldata)
}
