// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SEMVER_MINOR_OFFSET, SEMVER_MAJOR_OFFSET} from "../Config.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The library for managing SemVer for the protocol version.
 */
library SemVer {
    /// @notice Unpacks the SemVer version from a single uint256 into major, minor and patch components.
    /// @param _packedProtocolVersion The packed protocol version.
    /// @return major The major version.
    /// @return minor The minor version.
    /// @return patch The patch version.
    function unpackSemVer(
        uint256 _packedProtocolVersion
    ) internal pure returns (uint32 major, uint32 minor, uint32 patch) {
        require(_packedProtocolVersion <= uint256(type(uint96).max), "Semver: version is too large");
        patch = uint32(_packedProtocolVersion);
        minor = uint32(_packedProtocolVersion >> SEMVER_MINOR_OFFSET);
        major = uint32(_packedProtocolVersion >> SEMVER_MAJOR_OFFSET);
    }
}
