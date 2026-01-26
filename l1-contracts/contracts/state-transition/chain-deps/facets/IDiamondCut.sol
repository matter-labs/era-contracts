// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "../../libraries/Diamond.sol";

/// @title IDiamondCut Interface
/// @dev Interface for the diamondCut function used in zkstack CLI
interface IDiamondCut {
    /// @notice Execute diamond cut
    /// @param _diamondCut The diamond cut data containing facet cuts, init address, and init calldata
    function diamondCut(Diamond.DiamondCutData memory _diamondCut) external;
}
