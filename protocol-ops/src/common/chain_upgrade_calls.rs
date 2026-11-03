//! The calls of `chain set-upgrade-timestamp` and `chain upgrade`. An `AdminFunctions.s.sol`
//! entry point builds them on a `ForgeRunner`'s fork; the commands write its broadcasts as Safe
//! bundles, and the built-in fork replay sends the same broadcasts.

use alloy::primitives::{Address, U256};
use alloy::sol_types::SolCall;
use anyhow::Context;

use crate::common::abi::AdminFunctionsAbi;
use crate::common::forge::scripts::ADMIN_FUNCTIONS_INVOCATION;
use crate::common::forge::{ForgeRunner, ForgeScript, DEFAULT_SCRIPT_GAS_LIMIT};
use crate::common::l1_contracts::{resolve_chain_admin, resolve_zk_chain};
use crate::common::wallets::Wallet;
use crate::types::L2DACommitmentScheme;

/// DA validator pair to set atomically in the same multicall as the upgrade.
#[derive(Debug, Clone, Copy)]
pub struct DaValidatorPair {
    pub l1_da_validator: Address,
    pub l2_da_commitment_scheme: L2DACommitmentScheme,
}

/// An `AdminFunctions.s.sol` call through a chain's ChainAdmin.
pub struct ChainAdminCall {
    pub admin: Address,
    /// Who `Utils.adminExecuteCalls` broadcasts from: the ChainAdmin's owner, or the
    /// AccessControlRestriction's default admin.
    pub sender: Wallet,
    calldata: Vec<u8>,
    gas_limit: Option<u64>,
}

/// The ChainAdmin's and the ServerNotifier's upgrade timestamp for `new_protocol_version`.
pub async fn set_upgrade_timestamp(
    runner: &ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    access_control_restriction: Address,
    new_protocol_version: U256,
    upgrade_timestamp: U256,
) -> anyhow::Result<ChainAdminCall> {
    let (admin, sender) =
        chain_admin(runner, bridgehub, chain_id, access_control_restriction).await?;
    Ok(ChainAdminCall::set_upgrade_timestamp(
        admin,
        sender,
        access_control_restriction,
        bridgehub,
        chain_id,
        new_protocol_version,
        upgrade_timestamp,
    ))
}

/// The chain's upgrade to its CTM's version, which reads the cut from the CTM. With a DA
/// validator pair, `setDAValidatorPair` follows in the same `ChainAdmin.multicall`, so the chain
/// is never upgraded without one. Returns the chain's diamond too.
pub async fn upgrade(
    runner: &ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    access_control_restriction: Address,
    da_validator_pair: Option<DaValidatorPair>,
) -> anyhow::Result<(Address, ChainAdminCall)> {
    let chain_address = resolve_zk_chain(&runner.rpc_url, bridgehub, chain_id)
        .await
        .context("resolving chain diamond proxy from L1")?;
    let (admin, sender) =
        chain_admin(runner, bridgehub, chain_id, access_control_restriction).await?;
    let call = ChainAdminCall::upgrade(
        chain_address,
        admin,
        sender,
        access_control_restriction,
        da_validator_pair,
    );
    Ok((chain_address, call))
}

/// The ChainAdmin, and its broadcaster funded on the runner's fork.
async fn chain_admin(
    runner: &ForgeRunner,
    bridgehub: Address,
    chain_id: u64,
    access_control_restriction: Address,
) -> anyhow::Result<(Address, Wallet)> {
    let admin = resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
        .await
        .context("resolving chain admin from L1")?;
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, access_control_restriction)
        .await?;
    Ok((admin, sender))
}

impl ChainAdminCall {
    fn set_upgrade_timestamp(
        admin: Address,
        sender: Wallet,
        access_control_restriction: Address,
        bridgehub: Address,
        chain_id: u64,
        new_protocol_version: U256,
        upgrade_timestamp: U256,
    ) -> Self {
        let call = AdminFunctionsAbi::adminScheduleUpgradeCall {
            _adminAddr: admin,
            _accessControlRestriction: access_control_restriction,
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
            _newProtocolVersion: new_protocol_version,
            _timestamp: upgrade_timestamp,
        };
        Self {
            admin,
            sender,
            calldata: call.abi_encode(),
            gas_limit: None,
        }
    }

    fn upgrade(
        chain_address: Address,
        admin: Address,
        sender: Wallet,
        access_control_restriction: Address,
        da_validator_pair: Option<DaValidatorPair>,
    ) -> Self {
        let calldata = match da_validator_pair {
            Some(pair) => AdminFunctionsAbi::upgradeChainFromCTMAndSetDAValidatorPairCall {
                _chainAddress: chain_address,
                _adminAddr: admin,
                _accessControlRestriction: access_control_restriction,
                _l1DaValidator: pair.l1_da_validator,
                _l2DaCommitmentScheme: pair.l2_da_commitment_scheme as u8,
            }
            .abi_encode(),
            None => AdminFunctionsAbi::upgradeChainFromCTMCall {
                _chainAddress: chain_address,
                _adminAddr: admin,
                _accessControlRestriction: access_control_restriction,
            }
            .abi_encode(),
        };
        Self {
            admin,
            sender,
            calldata,
            gas_limit: Some(DEFAULT_SCRIPT_GAS_LIMIT),
        }
    }

    /// Broadcasts on the runner's fork, where it only records the transactions.
    pub fn run(&self, runner: &mut ForgeRunner) -> anyhow::Result<()> {
        let script = self.script(runner.script(&ADMIN_FUNCTIONS_INVOCATION));
        runner.run(script)
    }

    fn script(&self, base: ForgeScript) -> ForgeScript {
        let script = base
            .with_calldata(&self.calldata.clone().into())
            .with_broadcast();
        match self.gas_limit {
            Some(gas_limit) => script.with_gas_limit(gas_limit),
            None => script,
        }
        .with_wallet(&self.sender)
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::common::forge::{Forge, ForgeScriptArgs};

    const ADMIN: Address = Address::repeat_byte(0xa1);
    const RESTRICTION: Address = Address::repeat_byte(0xac);
    const BRIDGEHUB: Address = Address::repeat_byte(0xb4);
    const CHAIN: Address = Address::repeat_byte(0xd1);
    const SENDER: Address = Address::repeat_byte(0xee);

    fn sender() -> Wallet {
        Wallet::parse(None, Some(SENDER)).unwrap()
    }

    /// The call's forge arguments past the runner's own (`--ffi`, `--rpc-url`).
    fn args(call: &ChainAdminCall) -> Vec<String> {
        let base = Forge::new(Path::new("l1-contracts")).script(
            &ADMIN_FUNCTIONS_INVOCATION.script(),
            ForgeScriptArgs::default(),
        );
        call.script(base).args.build()
    }

    /// What the commands ran before the builders moved here: each `--sig` is `cast calldata` of
    /// the AdminFunctions signature, the flags are in the order the commands added them.
    #[test]
    fn the_commands_run_the_scripts_they_ran_before() {
        let sender_arg = format!("--sender={SENDER:#x}");
        let gas = format!("--gas-limit={DEFAULT_SCRIPT_GAS_LIMIT}");
        let schedule = ChainAdminCall::set_upgrade_timestamp(
            ADMIN,
            sender(),
            RESTRICTION,
            BRIDGEHUB,
            312,
            U256::from(146_028_888_064_u64),
            U256::from(1_767_225_600),
        );
        // cast calldata "adminScheduleUpgrade(address,address,address,uint256,uint256,uint256)" \
        //   <ADMIN> <RESTRICTION> <BRIDGEHUB> 312 146028888064 1767225600
        let schedule_sig = "--sig=24b9b91a\
            000000000000000000000000a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\
            000000000000000000000000acacacacacacacacacacacacacacacacacacacac\
            000000000000000000000000b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4\
            0000000000000000000000000000000000000000000000000000000000000138\
            0000000000000000000000000000000000000000000000000000002200000000\
            000000000000000000000000000000000000000000000000000000006955b900";
        assert_eq!(
            args(&schedule),
            [
                schedule_sig,
                "--broadcast",
                "--slow",
                &sender_arg,
                "--unlocked"
            ]
        );

        let upgrade = ChainAdminCall::upgrade(CHAIN, ADMIN, sender(), RESTRICTION, None);
        // cast calldata "upgradeChainFromCTM(address,address,address)" <CHAIN> <ADMIN> <RESTRICTION>
        let upgrade_sig = "--sig=5ca58d00\
            000000000000000000000000d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1\
            000000000000000000000000a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\
            000000000000000000000000acacacacacacacacacacacacacacacacacacacac";
        assert_eq!(
            args(&upgrade),
            [
                upgrade_sig,
                "--broadcast",
                "--slow",
                &gas,
                &sender_arg,
                "--unlocked"
            ]
        );

        let pair = DaValidatorPair {
            l1_da_validator: Address::repeat_byte(0xda),
            l2_da_commitment_scheme: L2DACommitmentScheme::BlobsAndPubdataKeccak256,
        };
        let with_pair = ChainAdminCall::upgrade(CHAIN, ADMIN, sender(), RESTRICTION, Some(pair));
        // cast calldata \
        //   "upgradeChainFromCTMAndSetDAValidatorPair(address,address,address,address,uint8)" \
        //   <CHAIN> <ADMIN> <RESTRICTION> 0xdada…da 3
        let with_pair_sig = "--sig=cfaaef52\
            000000000000000000000000d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1\
            000000000000000000000000a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\
            000000000000000000000000acacacacacacacacacacacacacacacacacacacac\
            000000000000000000000000dadadadadadadadadadadadadadadadadadadada\
            0000000000000000000000000000000000000000000000000000000000000003";
        assert_eq!(
            args(&with_pair),
            [
                with_pair_sig,
                "--broadcast",
                "--slow",
                &gas,
                &sender_arg,
                "--unlocked"
            ]
        );
    }
}
