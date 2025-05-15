// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AutomataEnclaveIdentityDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataEnclaveIdentityDao.sol";

/**
 * @title EnclaveIdentityDaoDeployer
 * @dev Contract for deploying the EnclaveIdentityDao component
 */
contract EnclaveIdentityDaoDeployer {
    /**
     * @notice Deploys the EnclaveIdentityDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param pcsDao Address of the PcsDao
     * @param enclaveIdHelper Address of the EnclaveIdentityHelper
     * @param x509Helper Address of the X509Helper
     * @return enclaveIdDao_ The newly created EnclaveIdentityDao instance
     */
    function deployEnclaveIdentityDao(
        address pccsStorage,
        address p256Verifier,
        address pcsDao,
        address enclaveIdHelper,
        address x509Helper
    ) external returns (AutomataEnclaveIdentityDao enclaveIdDao_) {
        return new AutomataEnclaveIdentityDao(
            pccsStorage,
            p256Verifier,
            pcsDao,
            enclaveIdHelper,
            x509Helper
        );
    }
}