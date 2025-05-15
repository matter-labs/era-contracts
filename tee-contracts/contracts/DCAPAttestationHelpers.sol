// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {
    EnclaveIdentityJsonObj,
    EnclaveIdentityHelper,
    IdentityObj
} from "@automata-network/on-chain-pccs/helpers/EnclaveIdentityHelper.sol";
import {TcbInfoJsonObj, FmspcTcbHelper} from "@automata-network/on-chain-pccs/helpers/FmspcTcbHelper.sol";
import {PCKHelper} from "@automata-network/on-chain-pccs/helpers/PCKHelper.sol";
import {X509CRLHelper} from "@automata-network/on-chain-pccs/helpers/X509CRLHelper.sol";

/**
 * @title DCAPAttestationHelpers
 * @dev Contains helper contract instances needed for DCAP attestation
 */
contract DCAPAttestationHelpers {
    EnclaveIdentityHelper public enclaveIdHelper;
    FmspcTcbHelper public tcbHelper;
    PCKHelper public x509;
    X509CRLHelper public x509Crl;

    /**
     * @notice Constructs the helper contracts
     */
    constructor() {
        enclaveIdHelper = new EnclaveIdentityHelper();
        tcbHelper = new FmspcTcbHelper();
        x509 = new PCKHelper();
        x509Crl = new X509CRLHelper();
    }
}