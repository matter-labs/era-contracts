// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerBase} from "./ChainTypeManagerBase.sol";
import {Diamond} from "./libraries/Diamond.sol";
import {ChainCreationParams} from "./IChainTypeManager.sol";

/// @title ZKsync OS Chain Type Manager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZKsyncOSChainTypeManager is ChainTypeManagerBase {
    /// @dev Contract is expected to be used as proxy implementation.
    constructor(address _bridgehub) ChainTypeManagerBase(_bridgehub) {}

    /// @notice Updates the parameters with which a new chain is created
    /// @param _chainCreationParams The new chain creation parameters
    function _setChainCreationParams(ChainCreationParams calldata _chainCreationParams) internal override {
        // Validate common parameters
        _validateChainCreationParams(_chainCreationParams);

        // No additional validation needed for ZKsync OS

        // Process the validated parameters
        _processValidatedChainCreationParams(_chainCreationParams);
    }

    /// @dev set New Version with upgrade from old version
    /// @param _cutData the new diamond cut data
    /// @param _oldProtocolVersion the old protocol version
    /// @param _oldProtocolVersionDeadline the deadline for the old protocol version
    /// @param _newProtocolVersion the new protocol version
    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _oldProtocolVersionDeadline,
        uint256 _newProtocolVersion
    ) external override onlyOwner {
        // No additional validation needed for ZKsync OS
        _setNewVersionUpgrade(_cutData, _oldProtocolVersion, _oldProtocolVersionDeadline, _newProtocolVersion);
    }
}