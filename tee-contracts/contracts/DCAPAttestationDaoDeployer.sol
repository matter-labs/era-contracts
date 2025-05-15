// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AutomataPcsDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataPcsDao.sol";
import {AutomataPckDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataPckDao.sol";
import {AutomataEnclaveIdentityDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataEnclaveIdentityDao.sol";
import {AutomataFmspcTcbDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataFmspcTcbDao.sol";

/**
 * @title DCAPAttestationDaoDeployer
 * @dev Contract for deploying the individual DAO components needed for DCAP attestation
 */
contract DCAPAttestationDaoDeployer {
    /**
     * @notice Deploys the PcsDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param x509Helper Address of the X509Helper
     * @param x509CrlHelper Address of the X509CRLHelper
     * @return pcsDao The newly created PcsDao instance
     */
    function deployPcsDao(
        address pccsStorage, 
        address p256Verifier, 
        address x509Helper, 
        address x509CrlHelper
    ) external returns (AutomataPcsDao) {
        return new AutomataPcsDao(
            pccsStorage,
            p256Verifier,
            x509Helper,
            x509CrlHelper
        );
    }

    /**
     * @notice Deploys the PckDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param pcsDao Address of the PcsDao
     * @param x509Helper Address of the X509Helper
     * @param x509CrlHelper Address of the X509CRLHelper
     * @return pckDao The newly created PckDao instance
     */
    function deployPckDao(
        address pccsStorage,
        address p256Verifier,
        address pcsDao,
        address x509Helper,
        address x509CrlHelper
    ) external returns (AutomataPckDao) {
        return new AutomataPckDao(
            pccsStorage,
            p256Verifier,
            pcsDao,
            x509Helper,
            x509CrlHelper
        );
    }
    
    /**
     * @notice Deploys the EnclaveIdentityDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param pcsDao Address of the PcsDao
     * @param enclaveIdHelper Address of the EnclaveIdentityHelper
     * @param x509Helper Address of the X509Helper
     * @return enclaveIdDao The newly created EnclaveIdentityDao instance
     */
    function deployEnclaveIdentityDao(
        address pccsStorage,
        address p256Verifier,
        address pcsDao,
        address enclaveIdHelper,
        address x509Helper
    ) external returns (AutomataEnclaveIdentityDao) {
        return new AutomataEnclaveIdentityDao(
            pccsStorage,
            p256Verifier,
            pcsDao,
            enclaveIdHelper,
            x509Helper
        );
    }
    
    /**
     * @notice Deploys the FmspcTcbDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param pcsDao Address of the PcsDao
     * @param tcbHelper Address of the FmspcTcbHelper
     * @param x509Helper Address of the X509Helper
     * @return fmspcTcbDao The newly created FmspcTcbDao instance
     */
    function deployFmspcTcbDao(
        address pccsStorage,
        address p256Verifier,
        address pcsDao,
        address tcbHelper,
        address x509Helper
    ) external returns (AutomataFmspcTcbDao) {
        return new AutomataFmspcTcbDao(
            pccsStorage,
            p256Verifier,
            pcsDao,
            tcbHelper,
            x509Helper
        );
    }
}