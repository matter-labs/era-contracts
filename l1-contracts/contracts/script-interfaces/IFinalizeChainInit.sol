// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IFinalizeChainInit {
    // solhint-disable-next-line gas-struct-packing
    struct FinalizeChainInitParams {
        address chainAdmin;
        address accessControlRestriction;
        address diamondProxy;
        address bridgehub;
        uint256 chainId;
        address l1DaValidator;
        address tokenMultiplierSetter;
        L2DACommitmentScheme l2DaCommitmentScheme;
        bool shouldUnpauseDeposits;
        bool shouldSetDaValidatorPair;
        bool shouldMakePermanentRollup;
    }

    function finalizeChainInit(FinalizeChainInitParams calldata _params) external;
}
