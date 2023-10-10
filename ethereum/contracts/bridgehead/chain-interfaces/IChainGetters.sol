// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../chain-deps/ChainStorage.sol";
import "./IChainBase.sol";

interface IChainGetters is IChainBase {
    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    function getGovernor() external view returns (address);

    function getPendingGovernor() external view returns (address);

    function getAllowList() external view returns (address);
}
