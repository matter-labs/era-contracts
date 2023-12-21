// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./IMailbox.sol";
import "./IAdmin.sol";
import "./IExecutor.sol";
import "./IGetters.sol";

/// @title The interface of the zkSync contract, responsible for the main zkSync logic.
/// @author Matter Labs
/// @dev This interface combines the interfaces of all the facets of the zkSync contract.
/// @custom:security-contact security@matterlabs
interface IZkSync is IMailbox, IAdmin, IExecutor, IGetters {

}
