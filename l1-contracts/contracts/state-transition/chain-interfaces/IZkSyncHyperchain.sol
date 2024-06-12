// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAdmin} from "./IAdmin.sol";
import {IExecutor} from "./IExecutor.sol";
import {IGetters} from "./IGetters.sol";
import {IMailbox} from "./IMailbox.sol";

import {Diamond} from "../libraries/Diamond.sol";

interface IZkSyncHyperchain is IAdmin, IExecutor, IGetters, IMailbox {
    // We need this structure for the server for now
    event ProposeTransparentUpgrade(
        Diamond.DiamondCutData diamondCut,
        uint256 indexed proposalId,
        bytes32 proposalSalt
    );
}
