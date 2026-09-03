// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2DACommitmentScheme, PubdataContent} from "contracts/common/Config.sol";

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
        /// @dev Which part of the pubdata the chain's batches commit to: `FULL_PUBDATA` for a rollup,
        /// `LOGS_ONLY` for a validium (see {PubdataContent}). ZKsync OS chains only.
        PubdataContent pubdataContent;
        bool shouldUnpauseDeposits;
        bool shouldSetDaValidatorPair;
        /// @dev Set only for a ZKsync OS chain that needs a value other than the `FULL_PUBDATA` a fresh
        /// chain starts with; `Admin.setPubdataContent` reverts on Era.
        bool shouldSetPubdataContent;
        bool shouldMakePermanentRollup;
    }

    function finalizeChainInit(FinalizeChainInitParams calldata _params) external;
}
