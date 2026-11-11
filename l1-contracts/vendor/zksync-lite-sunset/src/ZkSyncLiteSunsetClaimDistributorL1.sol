// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {BitMapsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/BitMapsUpgradeable.sol";
import {
    MerkleProofUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/// @title ZkSyncLiteSunsetClaimDistributorL1
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1 distributor for the ZKsync Lite sunset. Funds committed in a
/// Merkle tree can be claimed either by the claimant themselves or by any caller
/// on behalf of the claimant; in both cases the funds are transferred to the
/// claimant encoded in the leaf.
/// @dev Leaf format is `keccak256(abi.encodePacked(index, claimant, token, amount))`.
/// `token == address(0)` denotes a native ETH claim. Leaf indices must be globally
/// unique across all leaves because the claimed bitmap is keyed only by `index`.
/// @dev Expected to be deployed as a TransparentUpgradeableProxy.
contract ZkSyncLiteSunsetClaimDistributorL1 is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using BitMapsUpgradeable for BitMapsUpgradeable.BitMap;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice Merkle root over leaves `keccak256(abi.encodePacked(index, claimant, token, amount))`.
    bytes32 public MERKLE_ROOT;
    /// @notice Claims are enabled at/after this timestamp.
    uint256 public WINDOW_START;
    /// @notice Packed bitmap tracking completion of claims per leaf index.
    BitMapsUpgradeable.BitMap internal claimedBitMap;

    /// @notice Emitted whenever a call to claim succeeds.
    /// @param index The index of the claim leaf that was consumed.
    /// @param claimant The address encoded in the leaf and receiving the funds.
    /// @param token The token address (use `address(0)` for native ETH).
    /// @param amount The amount transferred to the claimant.
    event Claimed(uint256 index, address claimant, address token, uint256 amount);

    /// @notice Thrown when the claim index has already been consumed.
    error ZkSyncLiteSunsetClaimDistributor__AlreadyClaimed();
    /// @notice Thrown when the claim window is not yet open.
    error ZkSyncLiteSunsetClaimDistributor__ClaimWindowNotOpen();
    /// @notice Thrown when the Merkle proof does not verify against `MERKLE_ROOT`.
    error ZkSyncLiteSunsetClaimDistributor__InvalidProof();
    /// @notice Thrown when the native-token transfer to the claimant reverts.
    error ZkSyncLiteSunsetClaimDistributor__EthTransferFailed();

    /// @notice Disables initializers on the implementation so it can only be used behind a proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes proxy storage.
    /// @param merkleRoot Merkle root for the claim dataset.
    /// @param windowStart Claim start timestamp (inclusive).
    /// @param initialOwner Owner allowed to pause and unpause claiming.
    /// @dev Transfers ownership to `initialOwner` if different from the proxy deployer
    /// that invokes this initializer.
    function initialize(bytes32 merkleRoot, uint256 windowStart, address initialOwner) external initializer {
        require(initialOwner != address(0), "Ownable: new owner is the zero address");

        __Ownable_init();
        __Pausable_init();

        if (initialOwner != _msgSender()) {
            _transferOwnership(initialOwner);
        }

        MERKLE_ROOT = merkleRoot;
        WINDOW_START = windowStart;
    }

    /// @notice Returns whether a claim index has already been consumed.
    /// @param index The index of the claim leaf.
    /// @return Whether the claim has been executed.
    function isClaimed(uint256 index) public view returns (bool) {
        return claimedBitMap.get(index);
    }

    /// @notice Pauses all claim entrypoints.
    /// @dev Only the owner may pause; halts every claim path until `unpause` is called.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Re-enables claim entrypoints.
    /// @dev Only the owner may unpause.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Accepts native-token funding so the contract can be pre-funded for ETH claims.
    /// @dev Any ETH sent here that does not correspond to a claim leaf is permanently locked.
    receive() external payable {}

    /// @notice Convenience self-claim path; equivalent to `claimTo` with `claimant = msg.sender`.
    /// @param index The index of the claim leaf.
    /// @param token The token address (use `address(0)` for native ETH).
    /// @param amount The amount to transfer.
    /// @param merkleProof The Merkle proof for the claim leaf.
    function claim(uint256 index, address token, uint256 amount, bytes32[] calldata merkleProof)
        external
        whenNotPaused
    {
        _claim(index, msg.sender, token, amount, merkleProof);
    }

    /// @notice Permissionless claim path; any caller can trigger the claim for `claimant`, and
    /// funds are transferred to `claimant` (as bound by the Merkle leaf).
    /// @param index The index of the claim leaf.
    /// @param claimant The address encoded in the Merkle leaf and receiving the funds.
    /// @param token The token address (use `address(0)` for native ETH).
    /// @param amount The amount to transfer.
    /// @param merkleProof The Merkle proof for the claim leaf.
    function claimTo(uint256 index, address claimant, address token, uint256 amount, bytes32[] calldata merkleProof)
        external
        whenNotPaused
    {
        _claim(index, claimant, token, amount, merkleProof);
    }

    /// @notice Executes a single claim after verifying the leaf against the Merkle root.
    /// @param index The index of the claim leaf.
    /// @param claimant The address encoded in the Merkle leaf and receiving the funds.
    /// @param token The token address (use `address(0)` for native ETH).
    /// @param amount The amount to transfer.
    /// @param merkleProof The Merkle proof for the claim leaf.
    /// @dev Internal entrypoint used by `claim` and `claimTo`. Batching across multiple leaves
    /// is expected to be composed at the call site via Multicall3 (or equivalent) rather than
    /// via a contract-level helper.
    /// Marks the index as claimed before transferring funds (checks-effects-interactions).
    function _claim(uint256 index, address claimant, address token, uint256 amount, bytes32[] calldata merkleProof)
        internal
        claimWindowOpen
        notClaimed(index)
    {
        bytes32 leaf = keccak256(abi.encodePacked(index, claimant, token, amount));

        if (!MerkleProofUpgradeable.verifyCalldata(merkleProof, MERKLE_ROOT, leaf)) {
            revert ZkSyncLiteSunsetClaimDistributor__InvalidProof();
        }

        claimedBitMap.set(index);
        _transferClaim(claimant, token, amount);
        emit Claimed(index, claimant, token, amount);
    }

    /// @notice Transfers the claim amount to `claimant`.
    /// @param claimant The address the funds are transferred to.
    /// @param token The token address (use `address(0)` for native ETH).
    /// @param amount The amount to transfer.
    /// @dev Routes ERC-20 via SafeERC20 and native-token via `call{value:}`; reverts with
    /// `__EthTransferFailed` if the native transfer fails.
    function _transferClaim(address claimant, address token, uint256 amount) internal {
        // `token == address(0)` is reserved for native ETH claims.
        if (token == address(0)) {
            (bool success,) = claimant.call{value: amount}("");
            if (!success) {
                revert ZkSyncLiteSunsetClaimDistributor__EthTransferFailed();
            }
        } else {
            IERC20Upgradeable(token).safeTransfer(claimant, amount);
        }
    }

    /// @dev Reverts if `block.timestamp < WINDOW_START`.
    modifier claimWindowOpen() {
        if (block.timestamp < WINDOW_START) {
            revert ZkSyncLiteSunsetClaimDistributor__ClaimWindowNotOpen();
        }
        _;
    }

    /// @dev Reverts if the given `index` has already been consumed.
    modifier notClaimed(uint256 index) {
        if (isClaimed(index)) {
            revert ZkSyncLiteSunsetClaimDistributor__AlreadyClaimed();
        }
        _;
    }
}
