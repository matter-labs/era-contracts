// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IMailbox.sol";
import "./IChainGovernance.sol";
import "./IChainExecutor.sol";
import "./IChainGetters.sol";

interface IBridgeheadChain is IMailbox, IChainGovernance, IChainExecutor, IChainGetters {
    function initialize(
        uint256 _chainId,
        address _proofSystem,
        address _governor,
        IAllowList _allowList,
        uint256 _priorityTxMaxGasLimit
    ) external;
}
