// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IBridgeheadBase.sol";
import "../../proof-system/proof-system-interfaces/IProofForBridgehead.sol";
import "../../common/interfaces/IAllowList.sol";

interface IRegistry is IBridgeheadBase {
    function newChain(
        uint256 _chainId,
        address _proofSystem,
        address _chainGovernor,
        IAllowList _allowList
    ) external returns (uint256 chainId);

    function newProofSystem(address _proofSystem) external;

    // KL todo: chainId not uin256
    event NewChain(
        uint16 indexed chainId,
        address indexed chainContract,
        address proofSystem,
        address indexed chainGovernance
    );
}
