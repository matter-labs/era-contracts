// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./IMailbox.sol";
import "./IAdmin.sol";
import "./IExecutor.sol";
import "./IGetters.sol";

interface IZkSync is IMailbox, IAdmin, IExecutor, IGetters {}
