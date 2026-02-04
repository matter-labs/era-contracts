// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainAssetHandler {
    function setSettlementLayerChainId(
        uint256 _previousSettlementLayerChainId,
        uint256 _currentSettlementLayerChainId
    ) external;
}
