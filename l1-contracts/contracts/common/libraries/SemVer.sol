// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

uint256 constant UINT32_MASK = 0xFFFFFFFF;

uint256 constant SEMVER_MINOR_OFFSET = 32;
uint256 constant SEMVER_MAJOR_OFFSET = 64;

library SemVer {
    function unpackSemVer(
        uint256 _packedProtocolVersion
    ) internal pure returns (uint32 major, uint32 minor, uint32 patch) {
        patch = uint32(_packedProtocolVersion);
        minor = uint32(_packedProtocolVersion >> SEMVER_MINOR_OFFSET);
        major = uint32(_packedProtocolVersion >> SEMVER_MAJOR_OFFSET);
    }
}
