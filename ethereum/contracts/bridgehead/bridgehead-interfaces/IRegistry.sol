// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IBridgeheadBase.sol";
import "../../proof-system/proof-system-interfaces/IProofSystem.sol";
import "../../common/interfaces/IAllowList.sol";
import "../../common/libraries/Diamond.sol";

interface IRegistry is IBridgeheadBase {
    function newChain(
        uint256 _chainId,
        address _proofSystem,
        address _chainGovernor,
        Diamond.DiamondCutData calldata _diamondCut
    ) external returns (uint256 chainId);

    function newProofSystem(address _proofSystem) external;

    // KL todo: chainId not uin256
    event NewChain(uint16 indexed chainId, address proofSystem, address indexed chainGovernance);
}
