// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {IInitable} from "../interfaces/IInitable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IModule is IInitable, IERC165 {}
