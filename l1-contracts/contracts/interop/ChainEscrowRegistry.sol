// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import {IChainEscrowRegistry} from "./IChainEscrowRegistry.sol";
import {Unauthorized, ZeroAddress, InsufficientEscrowBalance, AlreadyWithdrawnToday, ChainNotRegistered} from "../common/L1ContractErrors.sol";
import {L2_ASSET_TRACKER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";

/// @title ChainEscrowRegistry
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Manages ZK token escrows for each chain to ensure permissionless interop settlement
/// @dev This contract implements a per-chain escrow system that solves the operator rotation vulnerability.
///      Without escrow, operators could block all interop settlements (including from users who paid fixed ZK fees)
///      by emptying their ZK balance or rotating to validators with insufficient funds.
///
///      Key features:
///      - Settlement fees are paid from dedicated chain escrows, not operator addresses directly
///      - Anyone can deposit ZK tokens into any chain's escrow (enables community rescue)
///      - Operators can withdraw any amount once per day (simplified withdrawal system)
///      - Direct settlement fee payment (no complex reserve/settle phases)
///
///      This ensures true permissionlessness: users who paid fixed ZK fees will be able to get their interop actions settled,
///      regardless of operator behavior or balance management.
contract ChainEscrowRegistry is IChainEscrowRegistry, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The ZK token contract
    IERC20 public zkToken;

    /// @notice The bridgehub contract address
    address public bridgehub;

    /// @notice Mapping of chain ID to escrow data
    mapping(uint256 chainId => ChainEscrow escrow) public chainEscrows;

    /// @notice Mapping to track if a chain has already withdrawn on a specific day
    /// chainId => day (block.timestamp / 1 days) => hasWithdrawn
    mapping(uint256 chainId => mapping(uint256 day => bool hasWithdrawn)) public dailyWithdrawals;

    /// @notice Modifier to check if caller is the asset tracker
    modifier onlyAssetTracker() {
        if (msg.sender != L2_ASSET_TRACKER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier to check if caller is the chain admin
    modifier onlyChainAdmin(uint256 chainId) {
        address zkChain = IBridgehubBase(bridgehub).getZKChain(chainId);
        if (zkChain == address(0)) {
            revert ChainNotRegistered(chainId);
        }
        // Check if caller is the chain admin (owner of the chain contract)
        if (msg.sender != IZKChain(zkChain).getAdmin()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _zkToken The ZK token contract address
    /// @param _bridgehub The bridgehub address
    /// @param _owner The contract owner
    function initialize(address _zkToken, address _bridgehub, address _owner) external reentrancyGuardInitializer {
        if (_zkToken == address(0)) revert ZeroAddress();
        if (_bridgehub == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        _disableInitializers();
        zkToken = IERC20(_zkToken);
        bridgehub = _bridgehub;
        _transferOwnership(_owner);
    }

    /// @inheritdoc IChainEscrowRegistry
    function deposit(uint256 chainId, uint256 amount) external nonReentrant whenNotPaused {
        // Check if chain exists by verifying it's registered in Bridgehub
        if (IBridgehubBase(bridgehub).getZKChain(chainId) == address(0)) {
            revert ChainNotRegistered(chainId);
        }

        zkToken.safeTransferFrom(msg.sender, address(this), amount);
        chainEscrows[chainId].balance += amount;

        emit EscrowDeposited(chainId, msg.sender, amount);
    }

    /// @inheritdoc IChainEscrowRegistry
    function paySettlementFees(uint256 chainId, uint256 amount) external onlyAssetTracker {
        ChainEscrow storage escrow = chainEscrows[chainId];

        if (escrow.balance < amount) {
            revert InsufficientEscrowBalance(amount, escrow.balance);
        }

        escrow.balance -= amount;
        emit SettlementFeePaid(chainId, amount);
    }

    /// @inheritdoc IChainEscrowRegistry
    function withdraw(uint256 chainId, uint256 amount) external onlyChainAdmin(chainId) nonReentrant whenNotPaused {
        ChainEscrow storage escrow = chainEscrows[chainId];
        uint256 currentDay = block.timestamp / 1 days;

        // Check if already withdrawn today
        if (dailyWithdrawals[chainId][currentDay]) {
            revert AlreadyWithdrawnToday(chainId, currentDay);
        }

        if (escrow.balance < amount) {
            revert InsufficientEscrowBalance(amount, escrow.balance);
        }

        escrow.balance -= amount;
        dailyWithdrawals[chainId][currentDay] = true;

        zkToken.safeTransfer(msg.sender, amount);
        emit OperatorWithdrawal(chainId, msg.sender, amount);
    }

    /// @inheritdoc IChainEscrowRegistry
    /// @inheritdoc IChainEscrowRegistry
    function getChainEscrow(uint256 chainId) external view returns (ChainEscrow memory escrow) {
        return chainEscrows[chainId];
    }

    /// @inheritdoc IChainEscrowRegistry
    function getAvailableBalance(uint256 chainId) external view returns (uint256) {
        return chainEscrows[chainId].balance;
    }

    /// @notice Get whether a chain has already withdrawn today
    /// @param chainId The chain ID to check
    /// @param day The day to check (block.timestamp / 1 days)
    /// @return hasWithdrawn Whether the chain has withdrawn on this day
    function hasWithdrawnToday(uint256 chainId, uint256 day) external view returns (bool hasWithdrawn) {
        return dailyWithdrawals[chainId][day];
    }

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }
}
