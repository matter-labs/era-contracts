// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./interfaces/IL1WethBridge.sol";
import "./interfaces/IL2WethBridge.sol";
import "./interfaces/IL2Weth.sol";
import "./interfaces/IL2StandardToken.sol";
import "./interfaces/IEthToken.sol";

import "../vendor/AddressAliasHelper.sol";
import { L2Weth } from "./L2Weth.sol";
import { L2ContractHelper } from "../L2ContractHelper.sol";

/// @title L2 WETH Bridge
/// @author Matter Labs
contract L2WethBridge is IL2WethBridge, Initializable {
    /// @dev The address of the L1 bridge counterpart.
    address public override l1WethBridge;

    /// @dev WETH token address on L1.
    address public override l1WethAddress;

    /// @dev WETH token address on L2.
    address public override l2WethAddress;

    /// @dev ETH token address on L2.
    address public constant l2EthAddress = address(0x800a);

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _l1WethBridge,
        address _l1WethAddress,
        address _governor
    ) external initializer {
        require(_l1WethBridge != address(0), "L1 WETH bridge address can not be zero");
        require(_l1WethAddress != address(0), "L1 WETH address can not be zero");
        require(_governor != address(0), "Governor address can not be zero");

        l1WethBridge = _l1WethBridge;
        l1WethAddress = _l1WethAddress;

        // Deploy L2 WETH token.
        address l2Weth = address(new L2Weth{salt: bytes32(0)}());

        // Initialization data for L2 WETH token.
        // abi.encodeCall is not supported by Solidity versions below 0.8.11
        bytes memory initializationData = abi.encodeWithSelector(
            L2Weth.bridgeInitialize.selector,
            address(this), _l1WethAddress, "Wrapped Ether", "WETH"
        );

        // Deploy L2 WETH token proxy.
        l2WethAddress = address(new TransparentUpgradeableProxy{salt: bytes32(0)}(l2Weth, _governor, initializationData));
    }

    /// @notice Initiate the withdrawal of WETH from L2 to L1 by sending a message to L1 and calling withdraw on L2EthToken contract
    /// @param _l1Receiver The account address that would receive the WETH on L1
    /// @param _amount Total amount of WETH to withdraw
    function withdraw(address _l1Receiver, uint256 _amount) external {
        require(_l1Receiver != address(0), "L1 receiver address can not be zero");
        require(_amount > 0, "Amount can not be zero");

        // Burn WETH on L2.
        IL2StandardToken(l2WethAddress).bridgeBurn(msg.sender, _amount);
        // Withdraw ETH to L1 bridge.
        IEthToken(l2EthAddress).withdraw{value: _amount}(l1WethBridge);

        // Send a message to L1 to finalize the withdrawal.
        bytes memory message = _getL1WithdrawalMessage(msg.sender, _l1Receiver, _amount);
        L2ContractHelper.sendMessageToL1(message);

        emit WithdrawalInitiated(msg.sender, _l1Receiver, l2WethAddress, _amount);
    }

    /// @notice Finalize the deposit of WETH from L1 to L2 by calling deposit on L2Weth contract
    /// @param _l1Sender The account address that initiated the deposit on L1
    /// @param _l2Receiver The account address that would receive the WETH on L2
    /// @param _amount Total amount of WETH to deposit
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        uint256 _amount
    ) external payable {
        require(AddressAliasHelper.undoL1ToL2Alias(msg.sender) == l1WethBridge, "Only L1 WETH bridge can call this function");
        require(_l1Sender != address(0), "L1 sender address can not be zero");
        require(_l2Receiver != address(0), "L2 receiver address can not be zero");
        require(msg.value == _amount, "Amount mismatch");

        // Deposit WETH to L2 receiver.
        IL2Weth(l2WethAddress).depositTo{value: msg.value}(_l2Receiver);

        emit FinalizeDeposit(_l1Sender, _l2Receiver, l2WethAddress, _amount);
    }

    /// @notice Get withdrawal message for L1
    /// @param _l2Sender The account address that would send the WETH on L2
    /// @param _l1Receiver The account address that would receive the WETH on L1
    /// @param _amount Total amount of WETH to withdraw
    /// @return Message for L1
    function _getL1WithdrawalMessage(
        address _l2Sender,
        address _l1Receiver,
        uint256 _amount
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(IL1WethBridge.finalizeWithdrawal.selector, _l2Sender, _l1Receiver, _amount);
    }

    receive() external payable {}
}