// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @dev The number of bits dedicated to the "patch" portion of the protocol version.
/// This also defines the bit starting from which the "minor" part is located.
uint256 constant SEMVER_MINOR_OFFSET = 32;

/// @dev The number of bits dedicated to the "patch" and "minor" portions of the protocol version.
/// This also defines the bit starting from which the "major" part is located.
/// Note, that currently, only major version of "0" is supported.
uint256 constant SEMVER_MAJOR_OFFSET = 64;

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
        uint96 _packedProtocolVersion
    ) internal pure returns (uint32 major, uint32 minor, uint32 patch) {
        patch = uint32(_packedProtocolVersion);
        minor = uint32(_packedProtocolVersion >> SEMVER_MINOR_OFFSET);
        major = uint32(_packedProtocolVersion >> SEMVER_MAJOR_OFFSET);
    }

    /// @notice Packs the SemVer version from the major, minor and patch components into a single uint96.
    /// @param _major The major version.
    /// @param _minor The minor version.
    /// @param _patch The patch version.
    /// @return packedProtocolVersion The packed protocol version.
    function packSemVer(
        uint32 _major,
        uint32 _minor,
        uint32 _patch
    ) internal pure returns (uint96 packedProtocolVersion) {
        packedProtocolVersion =
            uint96(_patch) |
            (uint96(_minor) << SEMVER_MINOR_OFFSET) |
            (uint96(_major) << SEMVER_MAJOR_OFFSET);
    }
}
