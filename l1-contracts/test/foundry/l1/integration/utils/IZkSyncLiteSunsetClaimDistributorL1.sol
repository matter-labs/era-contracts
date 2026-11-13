// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Interface of the vendored, unchanged ZKsync Lite sunset claim distributor
/// (`vendor/zksync-lite-sunset/src/ZkSyncLiteSunsetClaimDistributorL1.sol`).
/// @dev The distributor is built with its own (upstream) compiler settings, so tests deploy it from its artifact
/// and talk to it through this interface. Errors are redeclared here so that their selectors can be asserted.
interface IZkSyncLiteSunsetClaimDistributorL1 {
    event Claimed(uint256 index, address claimant, address token, uint256 amount);

    error ZkSyncLiteSunsetClaimDistributor__AlreadyClaimed();
    error ZkSyncLiteSunsetClaimDistributor__ClaimWindowNotOpen();
    error ZkSyncLiteSunsetClaimDistributor__InvalidProof();
    error ZkSyncLiteSunsetClaimDistributor__EthTransferFailed();

    function initialize(bytes32 _merkleRoot, uint256 _windowStart, address _initialOwner) external;

    function MERKLE_ROOT() external view returns (bytes32);

    function WINDOW_START() external view returns (uint256);

    function isClaimed(uint256 _index) external view returns (bool);

    function pause() external;

    function unpause() external;

    function claim(uint256 _index, address _token, uint256 _amount, bytes32[] calldata _merkleProof) external;

    function claimTo(
        uint256 _index,
        address _claimant,
        address _token,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    ) external;
}
