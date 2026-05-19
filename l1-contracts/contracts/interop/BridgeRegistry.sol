// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts-v4/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts-v4/security/Pausable.sol";

/**
 * @title BridgeRegistry
 * @notice Companion contract for L1 ↔ L2 interop on Prividium. Sits beside the user's
 *         L2BaseToken.withdraw + L2InteropCenter.sendBundleToL1 calls; records intent,
 *         enforces per-user daily limits, and provides a global pause.
 */
contract BridgeRegistry is AccessControl, Pausable {
    enum Direction { Deposit, Withdraw }

    bytes32 public constant BRIDGE_USER_ROLE = keccak256("BRIDGE_USER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    mapping(address => uint256) public dailyLimit;
    mapping(address => mapping(uint256 => uint256)) private _usedOnDay;

    event BridgeAnnounced(
        address indexed user,
        Direction indexed direction,
        uint256 amount,
        bytes32 opsHash,
        address delegate,
        uint256 dayIndex,
        uint256 usedAfter
    );

    event DailyLimitUpdated(address indexed user, uint256 oldLimit, uint256 newLimit);

    error ZeroAddress();
    error ZeroAmount();
    error EmptyOpsHash();
    error DailyLimitExceeded(address user, uint256 requested, uint256 remaining);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function announceBridge(Direction direction, uint256 amount, bytes32 opsHash, address delegate)
        external
        whenNotPaused
        onlyRole(BRIDGE_USER_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        if (opsHash == bytes32(0)) revert EmptyOpsHash();

        uint256 dayIndex = block.timestamp / 1 days;
        uint256 used = _usedOnDay[msg.sender][dayIndex];
        uint256 limit = dailyLimit[msg.sender];

        uint256 remaining = limit > used ? limit - used : 0;
        if (amount > remaining) revert DailyLimitExceeded(msg.sender, amount, remaining);

        uint256 newUsed = used + amount;
        _usedOnDay[msg.sender][dayIndex] = newUsed;

        emit BridgeAnnounced({
            user: msg.sender,
            direction: direction,
            amount: amount,
            opsHash: opsHash,
            delegate: delegate,
            dayIndex: dayIndex,
            usedAfter: newUsed
        });
    }

    function usedToday(address user) external view returns (uint256) {
        return _usedOnDay[user][block.timestamp / 1 days];
    }

    function setDailyLimit(address user, uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        uint256 oldLimit = dailyLimit[user];
        dailyLimit[user] = newLimit;
        emit DailyLimitUpdated(user, oldLimit, newLimit);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
