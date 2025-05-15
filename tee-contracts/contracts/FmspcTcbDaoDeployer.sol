// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AutomataFmspcTcbDao} from "@automata-network/on-chain-pccs/automata_pccs/AutomataFmspcTcbDao.sol";

/**
 * @title FmspcTcbDaoDeployer
 * @dev Contract for deploying the FmspcTcbDao component
 */
contract FmspcTcbDaoDeployer {
    /**
     * @notice Deploys the FmspcTcbDao contract
     * @param pccsStorage Address of the DAO storage
     * @param p256Verifier Address of the P256 verifier
     * @param pcsDao Address of the PcsDao
     * @param tcbHelper Address of the FmspcTcbHelper
     * @param x509Helper Address of the X509Helper
     * @return fmspcTcbDao_ The newly created FmspcTcbDao instance
     */
    function deployFmspcTcbDao(
        address pccsStorage,
        address p256Verifier,
        address pcsDao,
        address tcbHelper,
        address x509Helper
    ) external returns (AutomataFmspcTcbDao fmspcTcbDao_) {
        return new AutomataFmspcTcbDao(
            pccsStorage,
            p256Verifier,
            pcsDao,
            tcbHelper,
            x509Helper
        );
    }
}