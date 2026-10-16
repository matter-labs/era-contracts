// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice The features of deployed contracts that the scripts branch on, each with the protocol minor version that
/// introduced it (like anvil-zksync's `BUILTIN_CONTRACT_LOCATIONS`). A script meeting contracts from before and after
/// a feature checks `has(<their protocol version>, <feature>)` instead of comparing minor versions itself; a new such
/// feature gets a row here.
library ProtocolVersionFeatures {
    /// @dev The CTM exposes the L1 interop fee manager (`L1_INTEROP_FEE_MANAGER()`).
    uint32 internal constant CTM_INTEROP_FEE_MANAGER = 35;

    /// @notice Whether contracts on `_protocolVersion` have `_feature`.
    /// @param _protocolVersion A packed protocol version, as the CTM and the chains report it.
    /// @param _feature One of the constants above.
    function has(uint256 _protocolVersion, uint32 _feature) internal pure returns (bool) {
        (, uint32 minor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_protocolVersion));
        return minor >= _feature;
    }
}
