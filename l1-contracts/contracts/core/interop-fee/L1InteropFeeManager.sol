// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1InteropFeeManager} from "./IL1InteropFeeManager.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";

import {
    AmountMustBeGreaterThanZero,
    MsgValueMismatch,
    TokenNotSupported,
    Unauthorized,
    WithdrawFailed,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";
import {ZKChainNotRegistered} from "../bridgehub/L1BridgehubErrors.sol";
import {InsufficientInteropFeeBalance} from "./InteropFeeErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 interop fee switch. See {protocol-docs/interop-fee.md}.
contract L1InteropFeeManager is IL1InteropFeeManager, ReentrancyGuard, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The ecosystem's Bridgehub, used to resolve a chain id to its diamond proxy.
    IBridgehubBase public immutable BRIDGE_HUB;

    /// @inheritdoc IL1InteropFeeManager
    address public feeToken;

    /// @inheritdoc IL1InteropFeeManager
    uint256 public feePerUnit;

    /// @inheritdoc IL1InteropFeeManager
    address public feeRecipient;

    /// @inheritdoc IL1InteropFeeManager
    mapping(address token => uint256 amount) public accruedFees;

    /// @inheritdoc IL1InteropFeeManager
    mapping(uint256 chainId => mapping(address token => uint256 balance)) public chainBalance;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehubBase _bridgehub) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
    }

    /// @notice Initializes the proxy. The switch starts off, with ether as the fee token.
    /// @param _owner The owner, allowed to set the fee and the recipient.
    /// @param _feeRecipient The initial recipient of swept fees.
    function initialize(address _owner, address _feeRecipient) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        require(_feeRecipient != address(0), ZeroAddress());
        _transferOwnership(_owner);
        _setFee(ETH_TOKEN_ADDRESS, 0);
        feeRecipient = _feeRecipient;
        emit NewFeeRecipient(address(0), _feeRecipient);
    }

    /// @inheritdoc IL1InteropFeeManager
    function setFee(address _feeToken, uint256 _feePerUnit) external onlyOwner {
        _setFee(_feeToken, _feePerUnit);
    }

    /// @inheritdoc IL1InteropFeeManager
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), ZeroAddress());
        address oldFeeRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit NewFeeRecipient(oldFeeRecipient, _feeRecipient);
    }

    /// @inheritdoc IL1InteropFeeManager
    function deposit(uint256 _chainId, address _token, uint256 _amount) external payable nonReentrant {
        require(_token == feeToken, TokenNotSupported(_token));
        require(_amount != 0, AmountMustBeGreaterThanZero());
        uint256 expectedMsgValue = _token == ETH_TOKEN_ADDRESS ? _amount : 0;
        require(msg.value == expectedMsgValue, MsgValueMismatch(expectedMsgValue, msg.value));
        // Only a registered chain's balance can ever be charged or withdrawn.
        _getZKChain(_chainId);
        chainBalance[_chainId][_token] += _amount;
        emit ChainBalanceDeposited(_chainId, _token, msg.sender, _amount);
        if (_token != ETH_TOKEN_ADDRESS) {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }
    }

    /// @inheritdoc IL1InteropFeeManager
    function withdraw(uint256 _chainId, address _token, address _to, uint256 _amount) external nonReentrant {
        require(msg.sender == IGetters(_getZKChain(_chainId)).getAdmin(), Unauthorized(msg.sender));
        require(_to != address(0), ZeroAddress());
        require(_amount != 0, AmountMustBeGreaterThanZero());
        uint256 balance = chainBalance[_chainId][_token];
        require(_amount <= balance, InsufficientInteropFeeBalance(_chainId, balance, _amount));
        chainBalance[_chainId][_token] = balance - _amount;
        emit ChainBalanceWithdrawn(_chainId, _token, _to, _amount);
        _transferOut(_token, _to, _amount);
    }

    /// @inheritdoc IL1InteropFeeManager
    function chargeInteropFee(uint256 _chainId, uint256 _batchNumber, uint256 _units) external {
        uint256 fee = feePerUnit * _units;
        if (fee == 0) {
            return;
        }
        require(msg.sender == _getZKChain(_chainId), Unauthorized(msg.sender));
        address token = feeToken;
        uint256 balance = chainBalance[_chainId][token];
        require(fee <= balance, InsufficientInteropFeeBalance(_chainId, balance, fee));
        chainBalance[_chainId][token] = balance - fee;
        accruedFees[token] += fee;
        emit InteropFeeCharged({chainId: _chainId, batchNumber: _batchNumber, token: token, units: _units, fee: fee});
    }

    /// @inheritdoc IL1InteropFeeManager
    function sweep(address _token) external nonReentrant {
        uint256 amount = accruedFees[_token];
        if (amount == 0) {
            return;
        }
        accruedFees[_token] = 0;
        address recipient = feeRecipient;
        emit FeesSwept(_token, recipient, amount);
        _transferOut(_token, recipient, amount);
    }

    /// @notice Sets the fee token and the fee per unit, which is denominated in that token.
    function _setFee(address _feeToken, uint256 _feePerUnit) private {
        require(_feeToken != address(0), ZeroAddress());
        address oldFeeToken = feeToken;
        uint256 oldFeePerUnit = feePerUnit;
        feeToken = _feeToken;
        feePerUnit = _feePerUnit;
        emit NewFee(oldFeeToken, oldFeePerUnit, _feeToken, _feePerUnit);
    }

    /// @notice Returns the diamond proxy of a registered chain, reverting for unknown chain ids.
    function _getZKChain(uint256 _chainId) private view returns (address zkChain) {
        zkChain = BRIDGE_HUB.getZKChain(_chainId);
        require(zkChain != address(0), ZKChainNotRegistered());
    }

    /// @notice Sends `_amount` of `_token` to `_to`, reverting if the transfer fails.
    function _transferOut(address _token, address _to, uint256 _amount) private {
        if (_token == ETH_TOKEN_ADDRESS) {
            // slither-disable-next-line arbitrary-send-eth
            (bool success, ) = _to.call{value: _amount}("");
            require(success, WithdrawFailed());
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }
}
