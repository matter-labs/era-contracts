// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title DummyChainTypeManagerForServerNotifier
/// @notice A test smart contract implementing the subset of ChainTypeManager functionality for testing purposes.
contract DummyChainTypeManager {
    mapping(uint256 chainId => address chainAdmin) chainAdmin;

    mapping(uint256 _protocolVersion => uint256) public protocolVersionDeadline;

    constructor() {}

    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external {
        protocolVersionDeadline[_protocolVersion] = _timestamp;
    }

    function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool) {
        return block.timestamp <= protocolVersionDeadline[_protocolVersion];
    }

    function getChainAdmin(uint256 _chainId) external view returns (address) {
        return chainAdmin[_chainId];
    }

    function setChainAdmin(uint256 _chainId, address _chainAdmin) external {
        chainAdmin[_chainId] = _chainAdmin;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
