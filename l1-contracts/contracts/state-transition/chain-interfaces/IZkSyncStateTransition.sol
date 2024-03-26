// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAdmin} from "./IAdmin.sol";
import {IExecutor} from "./IExecutor.sol";
import {IGetters} from "./IGetters.sol";
import {IMailbox} from "./IMailbox.sol";

// kl to do remove this, needed for the server for now
import {Diamond} from "../libraries/Diamond.sol";

interface IZkSyncStateTransition is IAdmin, IExecutor, IGetters, IMailbox {
    // KL todo: need this in the server for now
    event ProposeTransparentUpgrade(
        Diamond.DiamondCutData diamondCut,
        uint256 indexed proposalId,
        bytes32 proposalSalt
    );
}
