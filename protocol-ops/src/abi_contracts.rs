use ethers::contract::BaseContract;
use lazy_static::lazy_static;

use crate::abi::{
    ADMINFUNCTIONSABI_ABI, DEPLOYGATEWAYTRANSACTIONFILTERERABI_ABI, GATEWAYUTILSABI_ABI,
    IDEPLOYCTMABI_ABI, IDEPLOYL2CONTRACTSABI_ABI, IDEPLOYPAYMASTERABI_ABI,
    IENABLEEVMEMULATORABI_ABI, IFINALIZECHAININITABI_ABI, IGATEWAYVOTEPREPARATIONABI_ABI,
    IREGISTERCTMABI_ABI, IREGISTERONALLCHAINSABI_ABI, IREGISTERZKCHAINABI_ABI,
    ISETUPLEGACYBRIDGEABI_ABI, IUPGRADEV31ABI_ABI,
};

lazy_static! {
    pub static ref ADMIN_FUNCTIONS_CONTRACT: BaseContract =
        BaseContract::from(ADMINFUNCTIONSABI_ABI.clone());
    pub static ref UPGRADE_V31_CONTRACT: BaseContract =
        BaseContract::from(IUPGRADEV31ABI_ABI.clone());
    pub static ref GATEWAY_UTILS_CONTRACT: BaseContract =
        BaseContract::from(GATEWAYUTILSABI_ABI.clone());
    pub static ref GATEWAY_VOTE_PREPARATION_CONTRACT: BaseContract =
        BaseContract::from(IGATEWAYVOTEPREPARATIONABI_ABI.clone());
    pub static ref DEPLOY_GATEWAY_TRANSACTION_FILTERER_CONTRACT: BaseContract =
        BaseContract::from(DEPLOYGATEWAYTRANSACTIONFILTERERABI_ABI.clone());
    pub static ref FINALIZE_CHAIN_INIT_CONTRACT: BaseContract =
        BaseContract::from(IFINALIZECHAININITABI_ABI.clone());
    pub static ref REGISTER_CHAIN_CONTRACT: BaseContract =
        BaseContract::from(IREGISTERZKCHAINABI_ABI.clone());
    pub static ref DEPLOY_L2_CONTRACTS_CONTRACT: BaseContract =
        BaseContract::from(IDEPLOYL2CONTRACTSABI_ABI.clone());
    pub static ref DEPLOY_PAYMASTER_CONTRACT: BaseContract =
        BaseContract::from(IDEPLOYPAYMASTERABI_ABI.clone());
    pub static ref REGISTER_ON_ALL_CHAINS_CONTRACT: BaseContract =
        BaseContract::from(IREGISTERONALLCHAINSABI_ABI.clone());
    pub static ref ENABLE_EVM_EMULATOR_CONTRACT: BaseContract =
        BaseContract::from(IENABLEEVMEMULATORABI_ABI.clone());
    pub static ref SETUP_LEGACY_BRIDGE_CONTRACT: BaseContract =
        BaseContract::from(ISETUPLEGACYBRIDGEABI_ABI.clone());
    pub static ref REGISTER_CTM_CONTRACT: BaseContract =
        BaseContract::from(IREGISTERCTMABI_ABI.clone());
    pub static ref DEPLOY_CTM_CONTRACT: BaseContract =
        BaseContract::from(IDEPLOYCTMABI_ABI.clone());
}
