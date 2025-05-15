// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AutomataPcsDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataPcsDao.sol";

/**
 * @title PcsDaoDeployer
 * @dev Contract for deploying the PcsDao component
 */
contract PcsDaoDeployer {
    /**
     * @notice Deploys the PcsDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param x509Helper Address of the X509Helper
     * @param x509CrlHelper Address of the X509CRLHelper
     * @return pcsDao_ The newly created PcsDao instance
     */
    function deployPcsDao(
        address pccsStorage, 
        address p256Verifier, 
        address x509Helper, 
        address x509CrlHelper
    ) external returns (AutomataPcsDao pcsDao_) {
        return new AutomataPcsDao(
            pccsStorage,
            p256Verifier,
            x509Helper,
            x509CrlHelper
        );
    }
}