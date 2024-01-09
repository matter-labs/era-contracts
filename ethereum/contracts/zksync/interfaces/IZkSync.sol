// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IMailbox} from "./IMailbox.sol";
import {IAdmin} from "./IAdmin.sol";
import {IExecutor} from "./IExecutor.sol";
import {IGetters} from "./IGetters.sol";

interface IZkSync is IMailbox, IAdmin, IExecutor, IGetters {}
