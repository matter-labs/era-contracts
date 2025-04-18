// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract DummyChainTypeManager {
    constructor() {}

    mapping(uint256 _protocolVersion => uint256) public protocolVersionDeadline;

    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external {
        protocolVersionDeadline[_protocolVersion] = _timestamp;
    }

    function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool) {
        return block.timestamp <= protocolVersionDeadline[_protocolVersion];
    }
}
