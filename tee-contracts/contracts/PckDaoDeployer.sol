// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AutomataPckDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataPckDao.sol";

/**
 * @title PckDaoDeployer
 * @dev Contract for deploying the PckDao component
 */
contract PckDaoDeployer {
    /**
     * @notice Deploys the PckDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param pcsDao Address of the PcsDao
     * @param x509Helper Address of the X509Helper
     * @param x509CrlHelper Address of the X509CRLHelper
     * @return pckDao_ The newly created PckDao instance
     */
    function deployPckDao(
        address pccsStorage,
        address p256Verifier,
        address pcsDao,
        address x509Helper,
        address x509CrlHelper
    ) external returns (AutomataPckDao pckDao_) {
        return new AutomataPckDao(
            pccsStorage,
            p256Verifier,
            pcsDao,
            x509Helper,
            x509CrlHelper
        );
    }
}