// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IAdmin} from "./IAdmin.sol";
import {IExecutor} from "./IExecutor.sol";
import {IGetters} from "./IGetters.sol";
import {IMailbox} from "./IMailbox.sol";

import {Diamond} from "../libraries/Diamond.sol";

interface IZKChain is IAdmin, IExecutor, IGetters, IMailbox {
    // We need this structure for the server for now
    event ProposeTransparentUpgrade(
        Diamond.DiamondCutData diamondCut,
        uint256 indexed proposalId,
        bytes32 proposalSalt
    );
}
