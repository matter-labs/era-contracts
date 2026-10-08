// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {IInteropFeeManager} from "./IInteropFeeManager.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";

import {AmountMustBeGreaterThanZero, Unauthorized, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {ZKChainNotRegistered} from "../bridgehub/L1BridgehubErrors.sol";
import {InsufficientInteropFeeBalance, InteropFeeTransferFailed} from "./InteropFeeErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Network-level interop fee switch, deployed on L1 only. See {protocol-docs/interop-fee.md}.
contract InteropFeeManager is IInteropFeeManager, ReentrancyGuard, Ownable2StepUpgradeable {
    IBridgehubBase public immutable BRIDGE_HUB;

    /// @inheritdoc IInteropFeeManager
    uint256 public feePerUnit;

    /// @inheritdoc IInteropFeeManager
    address public feeRecipient;

    /// @inheritdoc IInteropFeeManager
    uint256 public accruedFees;

    /// @inheritdoc IInteropFeeManager
    mapping(uint256 chainId => uint256 balance) public chainBalance;

    constructor(IBridgehubBase _bridgehub) {
        BRIDGE_HUB = _bridgehub;
        _disableInitializers();
    }

    /// @notice Initializes the proxy. The switch starts off (`feePerUnit == 0`).
    /// @param _owner The owner, allowed to set the fee and the recipient.
    /// @param _feeRecipient The initial recipient of swept fees.
    function initialize(address _owner, address _feeRecipient) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        require(_feeRecipient != address(0), ZeroAddress());
        _transferOwnership(_owner);
        feeRecipient = _feeRecipient;
        emit FeeRecipientSet(address(0), _feeRecipient);
    }

    /// @inheritdoc IInteropFeeManager
    function setFeePerUnit(uint256 _feePerUnit) external onlyOwner {
        emit FeePerUnitSet(feePerUnit, _feePerUnit);
        feePerUnit = _feePerUnit;
    }

    /// @inheritdoc IInteropFeeManager
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), ZeroAddress());
        emit FeeRecipientSet(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    /// @inheritdoc IInteropFeeManager
    function deposit(uint256 _chainId) external payable {
        require(msg.value != 0, AmountMustBeGreaterThanZero());
        // Rejects deposits to chain ids that are not (yet) registered, which could never be charged or withdrawn.
        _getZKChain(_chainId);
        chainBalance[_chainId] += msg.value;
        emit Deposited(_chainId, msg.sender, msg.value);
    }

    /// @inheritdoc IInteropFeeManager
    function withdraw(uint256 _chainId, address _to, uint256 _amount) external nonReentrant {
        require(msg.sender == IGetters(_getZKChain(_chainId)).getAdmin(), Unauthorized(msg.sender));
        require(_to != address(0), ZeroAddress());
        uint256 balance = chainBalance[_chainId];
        require(_amount <= balance, InsufficientInteropFeeBalance(_chainId, balance, _amount));
        chainBalance[_chainId] = balance - _amount;
        emit Withdrawn(_chainId, _to, _amount);
        _sendEth(_to, _amount);
    }

    /// @inheritdoc IInteropFeeManager
    function chargeInteropFee(uint256 _chainId, uint256 _batchNumber, uint256 _units) external {
        require(msg.sender == _getZKChain(_chainId), Unauthorized(msg.sender));
        uint256 fee = feePerUnit * _units;
        if (fee == 0) {
            return;
        }
        uint256 balance = chainBalance[_chainId];
        require(fee <= balance, InsufficientInteropFeeBalance(_chainId, balance, fee));
        chainBalance[_chainId] = balance - fee;
        accruedFees += fee;
        emit InteropFeeCharged(_chainId, _batchNumber, _units, fee);
    }

    /// @inheritdoc IInteropFeeManager
    function sweep() external nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) {
            return;
        }
        accruedFees = 0;
        address recipient = feeRecipient;
        emit FeesSwept(recipient, amount);
        _sendEth(recipient, amount);
    }

    /// @dev Returns the diamond proxy of a registered chain, reverting for unknown chain ids.
    function _getZKChain(uint256 _chainId) private view returns (address zkChain) {
        zkChain = BRIDGE_HUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());
    }

    function _sendEth(address _to, uint256 _amount) private {
        // slither-disable-next-line arbitrary-send-eth
        (bool success, ) = _to.call{value: _amount}("");
        require(success, InteropFeeTransferFailed());
    }
}
