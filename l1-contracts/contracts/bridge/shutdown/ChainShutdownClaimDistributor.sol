// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import {BitMapsUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/structs/BitMapsUpgradeable.sol";
import {MerkleProofUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/MerkleProofUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";

import {ZeroAddress} from "../../common/L1ContractErrors.sol";
import {ClaimAlreadyClaimed, ClaimEthTransferFailed, ClaimInvalidProof, ClaimWindowNotOpen} from "../L1BridgeContractErrors.sol";

/// @title ChainShutdownClaimDistributor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1 distributor for the funds of a shut down ZK chain. Funds committed in a Merkle tree can be claimed
/// either by the claimant themselves or by any caller on behalf of the claimant; in both cases the funds are
/// transferred to the claimant encoded in the leaf.
/// @dev This is a port of the `ZkSyncLiteSunsetClaimDistributorL1` contract used for the ZKsync Lite sunset
/// (repository matter-labs/zksync-lite-sunset, commit b7ab9f88, `contracts/zksync-lite-migration-claims`). The claim logic, leaf format
/// and storage layout are unchanged; only the pragma, import paths, naming conventions and error definitions differ.
/// The `MERKLE_ROOT` / `WINDOW_START` getter names are kept for ABI compatibility with the original tooling.
/// @dev The funds of the shut down chain are sent here by `L1AssetTracker.sendShutdownChainFunds`.
/// The Merkle root is expected to commit to the final state of the chain (i.e. after `shutdownInfo.lastExecutedBatch`),
/// including all withdrawals that were not finalized and failed deposits that were not claimed on L1 before the shutdown.
/// @dev Leaf format is `keccak256(abi.encodePacked(index, claimant, token, amount))`, where `token` is the L1 address
/// of the token. `token == address(0)` denotes a native ETH claim. Leaf indices must be globally unique across all leaves
/// because the claimed bitmap is keyed only by `index`.
/// @dev Expected to be deployed as a TransparentUpgradeableProxy.
contract ChainShutdownClaimDistributor is Initializable, OwnableUpgradeable, PausableUpgradeable {
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

    /// @notice Disables initializers on the implementation so it can only be used behind a proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes proxy storage.
    /// @param _merkleRoot Merkle root for the claim dataset.
    /// @param _windowStart Claim start timestamp (inclusive).
    /// @param _initialOwner Owner allowed to pause and unpause claiming.
    function initialize(bytes32 _merkleRoot, uint256 _windowStart, address _initialOwner) external initializer {
        require(_initialOwner != address(0), ZeroAddress());

        __Ownable_init();
        __Pausable_init();

        if (_initialOwner != _msgSender()) {
            _transferOwnership(_initialOwner);
        }

        MERKLE_ROOT = _merkleRoot;
        WINDOW_START = _windowStart;
    }

    /// @notice Returns whether a claim index has already been consumed.
    /// @param _index The index of the claim leaf.
    /// @return Whether the claim has been executed.
    function isClaimed(uint256 _index) public view returns (bool) {
        return claimedBitMap.get(_index);
    }

    /// @notice Pauses all claim entrypoints.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Re-enables claim entrypoints.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Accepts native-token funding so the contract can be funded for ETH claims.
    /// @dev Any ETH sent here that does not correspond to a claim leaf is permanently locked.
    receive() external payable {}

    /// @notice Convenience self-claim path; equivalent to `claimTo` with `claimant = msg.sender`.
    /// @param _index The index of the claim leaf.
    /// @param _token The token address (use `address(0)` for native ETH).
    /// @param _amount The amount to transfer.
    /// @param _merkleProof The Merkle proof for the claim leaf.
    function claim(
        uint256 _index,
        address _token,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    ) external whenNotPaused {
        _claim({_index: _index, _claimant: msg.sender, _token: _token, _amount: _amount, _merkleProof: _merkleProof});
    }

    /// @notice Permissionless claim path; any caller can trigger the claim for `claimant`, and
    /// funds are transferred to `claimant` (as bound by the Merkle leaf).
    /// @param _index The index of the claim leaf.
    /// @param _claimant The address encoded in the Merkle leaf and receiving the funds.
    /// @param _token The token address (use `address(0)` for native ETH).
    /// @param _amount The amount to transfer.
    /// @param _merkleProof The Merkle proof for the claim leaf.
    function claimTo(
        uint256 _index,
        address _claimant,
        address _token,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    ) external whenNotPaused {
        _claim({_index: _index, _claimant: _claimant, _token: _token, _amount: _amount, _merkleProof: _merkleProof});
    }

    /// @notice Executes a single claim after verifying the leaf against the Merkle root.
    /// @dev Marks the index as claimed before transferring funds (checks-effects-interactions).
    /// Batching across multiple leaves is expected to be composed at the call site via Multicall3.
    function _claim(
        uint256 _index,
        address _claimant,
        address _token,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    ) internal claimWindowOpen notClaimed(_index) {
        bytes32 leaf = keccak256(abi.encodePacked(_index, _claimant, _token, _amount));

        if (!MerkleProofUpgradeable.verifyCalldata(_merkleProof, MERKLE_ROOT, leaf)) {
            revert ClaimInvalidProof();
        }

        claimedBitMap.set(_index);
        _transferClaim(_claimant, _token, _amount);
        emit Claimed(_index, _claimant, _token, _amount);
    }

    /// @notice Transfers the claim amount to `_claimant`.
    /// @dev Routes ERC-20 via SafeERC20 and native-token via `call{value:}`.
    function _transferClaim(address _claimant, address _token, uint256 _amount) internal {
        // `_token == address(0)` is reserved for native ETH claims.
        if (_token == address(0)) {
            // slither-disable-next-line arbitrary-send-eth
            (bool success, ) = _claimant.call{value: _amount}("");
            if (!success) {
                revert ClaimEthTransferFailed();
            }
        } else {
            IERC20Upgradeable(_token).safeTransfer(_claimant, _amount);
        }
    }

    /// @dev Reverts if `block.timestamp < WINDOW_START`.
    modifier claimWindowOpen() {
        if (block.timestamp < WINDOW_START) {
            revert ClaimWindowNotOpen();
        }
        _;
    }

    /// @dev Reverts if the given `_index` has already been consumed.
    modifier notClaimed(uint256 _index) {
        if (isClaimed(_index)) {
            revert ClaimAlreadyClaimed();
        }
        _;
    }
}
