use crate::common::forge::scripts::admin::ADMIN_FUNCTIONS_SCRIPT_PARAMS;
use crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScript},
    wallets::Wallet,
};
use crate::types::L2DACommitmentScheme;
use alloy::primitives::{Address, Bytes, U256};
use alloy::sol_types::SolCall;

use crate::common::abi::AdminFunctionsAbi;

/// Accept the pending admin role on `target_address` via `ChainAdminOwnable.multicall`.
///
/// The forge script generates `deployer → ChainAdminOwnable.multicall([target.acceptAdmin()])`
/// via `vm.startBroadcast(adminOwner)`. Running with `--broadcast` applies this to the fork
/// immediately so that subsequent forge scripts in the same session (e.g. CTM deploy) see
/// `bridgehub.admin()` correctly set. The broadcast is recorded in `runner.runs()` and
/// included in the Safe bundle written by `write_output_if_requested`.
pub fn accept_admin(
    runner: &mut ForgeRunner,
    admin: Address,
    governor: &Wallet,
    target_address: Address,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::chainAdminAcceptAdminCall {
        _chainAdmin: admin,
        _target: target_address,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

pub fn accept_owner(
    runner: &mut ForgeRunner,
    governor_contract: Address,
    governor: &Wallet,
    target_address: Address,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::governanceAcceptOwnerCall {
        _governor: governor_contract,
        _target: target_address,
    }
    .abi_encode()
    .into();
    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

pub fn accept_owner_aggregated(
    runner: &mut ForgeRunner,
    governor_contract: Address,
    governor: &Wallet,
    target_address: Address,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::governanceAcceptOwnerAggregatedCall {
        _governor: governor_contract,
        _bridgehub: target_address,
    }
    .abi_encode()
    .into();
    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

pub fn unpause_deposits(
    runner: &mut ForgeRunner,
    wallet: &Wallet,
    chain_id: u64,
    bridgehub: Address,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::unpauseDepositsCall {
        _bridgehub: bridgehub,
        _chainId: U256::from(chain_id),
        _shouldSend: true,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(wallet)
        .with_broadcast();
    runner.run(forge)
}

pub fn make_permanent_rollup(
    runner: &mut ForgeRunner,
    chain_admin_addr: Address,
    governor: &Wallet,
    diamond_proxy_address: Address,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::makePermanentRollupCall {
        _chainAdmin: chain_admin_addr,
        _target: diamond_proxy_address,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

pub fn set_token_multiplier_setter(
    runner: &mut ForgeRunner,
    governor: &Wallet,
    chain_admin_addr: Address,
    access_control_restriction_addr: Address,
    diamond_proxy_addr: Address,
    new_setter: Address,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::chainSetTokenMultiplierSetterCall {
        _chainAdmin: chain_admin_addr,
        _accessControlRestriction: access_control_restriction_addr,
        _diamondProxyAddress: diamond_proxy_addr,
        _setter: new_setter,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

#[allow(clippy::too_many_arguments)]
pub fn set_da_validator_pair(
    runner: &mut ForgeRunner,
    wallet: &Wallet,
    chain_id: u64,
    bridgehub: Address,
    access_control_restriction: Address,
    l1_da_validator_address: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::setDAValidatorPairCall {
        _bridgehub: bridgehub,
        _accessControlRestriction: access_control_restriction,
        _chainId: U256::from(chain_id),
        _l1DaValidator: l1_da_validator_address,
        _l2DaCommitmentScheme: l2_da_commitment_scheme as u8,
        _shouldSend: true,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(wallet)
        .with_broadcast();
    runner.run(forge)
}

#[allow(clippy::too_many_arguments)]
pub fn update_validator(
    runner: &mut ForgeRunner,
    admin_addr: Address,
    governor: &Wallet,
    access_control_restriction: Address,
    validator_timelock: Address,
    chain_id: u64,
    validator_address: Address,
    add: bool,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::updateValidatorCall {
        _adminAddr: admin_addr,
        _accessControlRestriction: access_control_restriction,
        _validatorTimelock: validator_timelock,
        _chainId: U256::from(chain_id),
        _validatorAddress: validator_address,
        _addValidator: add,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

#[allow(clippy::too_many_arguments)]
pub fn schedule_upgrade(
    runner: &mut ForgeRunner,
    governor: &Wallet,
    admin_addr: Address,
    access_control_restriction: Address,
    bridgehub: Address,
    chain_id: u64,
    new_protocol_version: U256,
    timestamp: U256,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::adminScheduleUpgradeCall {
        _adminAddr: admin_addr,
        _accessControlRestriction: access_control_restriction,
        _bridgehub: bridgehub,
        _chainId: U256::from(chain_id),
        _newProtocolVersion: new_protocol_version,
        _timestamp: timestamp,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

pub fn upgrade_chain_from_ctm(
    runner: &mut ForgeRunner,
    governor: &Wallet,
    chain_address: Address,
    admin_addr: Address,
    access_control_restriction: Address,
) -> anyhow::Result<()> {
    let calldata: Bytes = AdminFunctionsAbi::upgradeChainFromCTMCall {
        _chainAddress: chain_address,
        _adminAddr: admin_addr,
        _accessControlRestriction: access_control_restriction,
    }
    .abi_encode()
    .into();

    let forge = build_governance_forge(runner, &calldata)
        .with_wallet(governor)
        .with_broadcast();
    runner.run(forge)
}

/// Build a standard governance ForgeScript without auth or broadcast (caller adds those).
fn build_governance_forge(runner: &ForgeRunner, calldata: &Bytes) -> ForgeScript {
    Forge::new(&runner.foundry_scripts_path)
        .script(
            &ADMIN_FUNCTIONS_SCRIPT_PARAMS.script(),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(runner.rpc_url.clone())
        .with_gas_limit(DEFAULT_SCRIPT_GAS_LIMIT)
        .with_calldata(calldata)
}
