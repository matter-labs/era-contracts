// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

uint256 constant UINT32_MASK = 0xFFFFFFFF;

uint256 constant SEMVER_MINOR_OFFSET = 32;
uint256 constant SEMVER_MAJOR_OFFSET = 64;

library SemVer {
    function unpackSemVer(uint256 _packedProtocolVersion) returns (uint32 major, uint32 minor, uint32 patch) {
        patch = (_packedProtocolVersion & UINT32_MASK);
        minor = (_packedProtocolVersion >> SEMVER_MINOR_OFFSET) & UINT32_MASK;
        major = (_packedProtocolVersion >> SEMVER_MAJOR_OFFSET) & UINT32_MASK;
    }

    function packSemVer(uint256 _major, uint256 _minor, uint256 _patch) returns (uint256) {
        return (_major << SEMVER_MAJOR_OFFSET) | (_minor << SEMVER_MINOR_OFFSET) | (_patch);
    }
}
