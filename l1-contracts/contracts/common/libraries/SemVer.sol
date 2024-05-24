// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

uint256 constant UINT32_MASK = 0xFFFFFFFF;


library SemVer {
    function unpackSemVer(
        uint256 _packedProtocolVersion
    ) internal pure returns (uint32 major, uint32 minor, uint32 patch) {
        require(_packedProtocolVersion <= uint256(uint96.max), "Semver: version is too large");
        patch = uint32(_packedProtocolVersion);
        minor = uint32(_packedProtocolVersion >> SEMVER_MINOR_OFFSET);
        major = uint32(_packedProtocolVersion >> SEMVER_MAJOR_OFFSET);
    }
}
