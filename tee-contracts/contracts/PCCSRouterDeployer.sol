// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {PCCSRouter} from "automata-network/dcap-attestation/evm/contracts/PCCSRouter.sol";

/**
 * @title PCCSRouterDeployer
 * @dev Contract for deploying the PCCSRouter component
 */
contract PCCSRouterDeployer {
    /**
     * @notice Deploys the PCCSRouter contract
     * @param enclaveIdDao Address of the EnclaveIdentityDao
     * @param fmspcTcbDao Address of the FmspcTcbDao
     * @param pcsDao Address of the PcsDao
     * @param pckDao Address of the PckDao
     * @param x509Helper Address of the X509Helper
     * @param x509CrlHelper Address of the X509CRLHelper
     * @param tcbHelper Address of the FmspcTcbHelper
     * @return router The newly created PCCSRouter instance
     */
    function deployRouter(
        address enclaveIdDao,
        address fmspcTcbDao,
        address pcsDao,
        address pckDao,
        address x509Helper,
        address x509CrlHelper,
        address tcbHelper
    ) external returns (PCCSRouter) {
        return new PCCSRouter(
            enclaveIdDao,
            fmspcTcbDao,
            pcsDao,
            pckDao,
            x509Helper,
            x509CrlHelper,
            tcbHelper
        );
    }
}