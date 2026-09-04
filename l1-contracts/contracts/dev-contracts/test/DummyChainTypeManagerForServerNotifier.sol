// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title DummyChainTypeManagerForServerNotifier
/// @notice A test smart contract implementing the subset of ChainTypeManager functionality for testing purposes.
contract DummyChainTypeManager {
    mapping(uint256 chainId => address chainAdmin) chainAdmin;

    mapping(uint256 chainId => uint256 protocolVersion) public protocolVersion;

    mapping(uint256 _protocolVersion => uint256) public protocolVersionDeadline;

    mapping(uint256 protocolVersion => bytes32 cutHash) public upgradeCutHash;

    mapping(uint256 oldProtocolVersion => address transition) public upgradeTransition;

    // solhint-disable-next-line var-name-mixedcase
    address public BRIDGE_HUB;

    constructor() {}

    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external {
        protocolVersionDeadline[_protocolVersion] = _timestamp;
    }

    function setUpgradeCutHash(uint256 _oldProtocolVersion, bytes32 _upgradeCutHash) external {
        upgradeCutHash[_oldProtocolVersion] = _upgradeCutHash;
    }

    function setUpgradeTransition(uint256 _oldProtocolVersion, address _transition) external {
        upgradeTransition[_oldProtocolVersion] = _transition;
    }

    function protocolVersionIsActive(uint256 _protocolVersion) external view returns (bool) {
        return block.timestamp <= protocolVersionDeadline[_protocolVersion];
    }

    function getChainAdmin(uint256 _chainId) external view returns (address) {
        return chainAdmin[_chainId];
    }

    function getProtocolVersion(uint256 _chainId) public view returns (uint256) {
        return protocolVersion[_chainId];
    }

    function setChainAdmin(uint256 _chainId, address _chainAdmin) external {
        chainAdmin[_chainId] = _chainAdmin;
    }

    function setBridgeHub(address _bridgeHub) external {
        BRIDGE_HUB = _bridgeHub;
    }

    function _setChainProtocolVersion(uint256 _chainId, uint256 _protocolVersion) external {
        protocolVersion[_chainId] = _protocolVersion;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
