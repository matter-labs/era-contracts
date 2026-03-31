// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChainCreationParamsConfig} from "../Types.sol";
import {ChainCreationParamsLib} from "../../ctm/ChainCreationParamsLib.sol";

/// @notice Genesis / chain-creation config loading with Era vs ZKsyncOS branching.
///         This library is an internal implementation detail of EraZkosRouter.
///         External callers should use EraZkosRouter's public API instead.
///         Delegates to ChainCreationParamsLib for the actual parsing logic.
library EraZkosGenesisConfig {
    /// @notice Load chain creation params from a genesis JSON config file.
    ///         Delegates to ChainCreationParamsLib with the VM mode.
    function getChainCreationParams(
        string memory _configPath,
        bool _isZKsyncOS
    ) internal returns (ChainCreationParamsConfig memory) {
        return ChainCreationParamsLib.getChainCreationParams(_configPath, _isZKsyncOS);
    }
}
