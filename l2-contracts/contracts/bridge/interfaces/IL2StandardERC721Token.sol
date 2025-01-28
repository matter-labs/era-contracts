// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IL2StandardERC721Token {
    event BridgeInitialize(address indexed l1Token, string name, string symbol);

    event BridgeMint(address indexed _account, uint256 _tokenId);

    event BridgeBurn(address indexed _account, uint256 _tokenId);

    function bridgeMint(address _account, uint256 _tokenId, bytes memory _tokenURI) external;

    function bridgeBurn(address _account, uint256 _tokenId) external;

    function l1Address() external view returns (address);

    function l2Bridge() external view returns (address);
}
