// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AdminFunctions} from "../AdminFunctions.s.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IFinalizeChainInit} from "contracts/script-interfaces/IFinalizeChainInit.sol";

contract FinalizeChainInit is AdminFunctions, IFinalizeChainInit {
    function finalizeChainInit(FinalizeChainInitParams calldata _params) external {
        ChainAdmin chainAdmin = ChainAdmin(payable(_params.chainAdmin));

        chainAdminAcceptAdmin(chainAdmin, _params.diamondProxy);

        if (_params.shouldUnpauseDeposits) {
            unpauseDeposits(_params.bridgehub, _params.chainId, true);
        }

        if (_params.tokenMultiplierSetter != address(0)) {
            chainSetTokenMultiplierSetter(
                _params.chainAdmin,
                _params.accessControlRestriction,
                _params.diamondProxy,
                _params.tokenMultiplierSetter
            );
        }

        if (_params.shouldSetDaValidatorPair) {
            setDAValidatorPair(
                _params.bridgehub,
                _params.accessControlRestriction,
                _params.chainId,
                _params.l1DaValidator,
                _params.l2DaCommitmentScheme,
                true
            );
        }

        // Before the permanent-rollup step below: that one requires `FULL_PUBDATA` and, once taken, locks
        // the pubdata content for good.
        if (_params.shouldSetPubdataContent) {
            setPubdataContent(
                _params.bridgehub,
                _params.accessControlRestriction,
                _params.chainId,
                _params.pubdataContent,
                true
            );
        }

        if (_params.shouldMakePermanentRollup) {
            makePermanentRollup(chainAdmin, _params.diamondProxy);
        }
    }
}
