// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../libraries/Diamond.sol";

interface IZkSyncStateTransitionRegistry {
    /// @notice
    function newChain(
        uint256 _chainId,
        address _baseToken,
        address _baseTokenBridge,
        address _governor,
        bytes calldata _diamondCut
    ) external;

    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion
    ) external;

    function setUpgradeDiamondCut(Diamond.DiamondCutData calldata _cutData, uint256 _oldProtocolVersion) external;

    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external;

    // when a new Chain is added
    event StateTransitionNewChain(uint256 indexed _chainId, address indexed _stateTransitionChainContract);
}
