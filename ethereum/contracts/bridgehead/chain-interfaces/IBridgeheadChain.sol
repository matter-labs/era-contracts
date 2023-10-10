// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IChainGovernance.sol";
import "./IChainExecutor.sol";
import "./IChainGetters.sol";

interface IBridgeheadChain is IChainGovernance, IChainExecutor, IChainGetters {
    function initialize(
        uint256 _chainId,
        address _proofSystem,
        address _governor,
        IAllowList _allowList
    ) external;
}
