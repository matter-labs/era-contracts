// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IL2StandardToken {
    event BridgeMint(address indexed _account, uint256 _amount);

    event BridgeBurn(address indexed _account, uint256 _amount);

    function bridgeMint(address _account, uint256 _amount) external;

    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _tokenInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable;

    function l1Address() external view returns (address);

    function l2Bridge() external view returns (address);
}
