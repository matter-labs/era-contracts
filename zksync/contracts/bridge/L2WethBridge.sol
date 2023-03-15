// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
// import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./interfaces/IL1WethBridge.sol";
import "./interfaces/IL2WethBridge.sol";
import "./interfaces/IL2WethToken.sol";
import "./interfaces/IEthToken.sol";

import { L2WethToken } from "./L2WethToken.sol";

import "../vendor/AddressAliasHelper.sol";
import { L2ContractHelper } from "../L2ContractHelper.sol";

/// @title L2WethBridge
/// @author Matter Labs
contract L2WethBridge is IL2WethBridge, Initializable {
    /// @dev The address of the L1 bridge counterpart.
    address public override l1Bridge;

    /// @dev WETH address on L1.
    address public override l1WethAddress;

    /// @dev ETH token address on L2.
    address public constant l2EthAddress = address(0x800a);

    /// @dev Contract that store the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    TransparentUpgradeableProxy public l2WethTransparentProxy;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _l1Bridge,
        address _l1WethAddress,
        address _governor
    ) external initializer {
        require(_l1Bridge != address(0), "bf");
        require(_l1WethAddress != address(0), "df");
        require(_governor != address(0), "sf");

        l1Bridge = _l1Bridge;
        l1WethAddress = _l1WethAddress;

        // Deploy L2WethToken and transfer ownership to governor
        address l2WethToken = address(new L2WethToken{salt: bytes32(0)}());

        // Prepare the proxy constructor data
        bytes memory l2WethTokenProxyConstructorData;
        {
            // Data to be used in delegate call to initialize the proxy
            bytes memory proxyInitializationParams = abi.encodeWithSelector(IL2WethToken.initialize.selector, "Wrapped Ether", "WETH", 18);
            l2WethTokenProxyConstructorData = abi.encode(proxyInitializationParams);
        }
        
        l2WethTransparentProxy = new TransparentUpgradeableProxy{salt: bytes32(0)}(l2WethToken, _governor, l2WethTokenProxyConstructorData);
    }

    /// @notice Initiate the withdrawal of WETH from L2 to L1 by sending a message to L1 and calling withdraw on L2EthToken contract
    /// @param _l1Receiver The account address that would receive the WETH on L1
    /// @param _amount Total amount of WETH to withdraw
    function withdraw(address _l1Receiver, uint256 _amount) external {
        uint256 withdrawnAmount = _transferWethFunds(msg.sender, address(this), _amount);
        require(withdrawnAmount == _amount, "tf");

        IL2WethToken(l2WethAddress()).withdraw(_amount);
        IEthToken(l2EthAddress).withdraw{value: _amount}(l1Bridge);

        bytes memory message = _getL1WithdrawalMessage(msg.sender, _l1Receiver, _amount);
        L2ContractHelper.sendMessageToL1(message);

        emit WithdrawalInitiated(msg.sender, _l1Receiver, _amount);
    }

    /// @notice Finalize the deposit of WETH from L1 to L2 by calling deposit on L2Weth contract
    /// @param _l1Sender The account address that initiated the deposit on L1
    /// @param _l2Receiver The account address that would receive the WETH on L2
    function finalizeDeposit(address _l1Sender, address _l2Receiver) external payable {
        // Only the L1 bridge counterpart can initiate and finalize the deposit.
        require(AddressAliasHelper.undoL1ToL2Alias(msg.sender) == l1Bridge, "mq");
        
        require(_l1Sender != address(0), "sf");
        require(_l2Receiver != address(0), "sf");
        require(msg.value != 0, "tf");

        IL2WethToken(l2WethAddress()).deposit{value: msg.value}();
        uint256 _amount = _transferWethFunds(address(this), _l2Receiver, msg.value);
        require(_amount == msg.value, "tf");

        emit FinalizeDeposit(_l1Sender, _l2Receiver, _amount);
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

    /// @dev Transfers WETH tokens from the depositor to the receiver address
    /// @return The difference between the receiver balance before and after the transferring funds
    function _transferWethFunds(
        address _from,
        address _to,
        uint256 _amount
    ) internal returns (uint256) {
        IL2WethToken l2WethToken = IL2WethToken(l2WethAddress());

        uint256 balanceBefore = l2WethToken.balanceOf(_to);
        l2WethToken.transferFrom(_from, _to, _amount);
        uint256 balanceAfter = l2WethToken.balanceOf(_to);

        return balanceAfter - balanceBefore;
    }

    /// @notice Get the address of the L2 WETH token
    /// @return The address of the L2 WETH token
    function l2WethAddress() public view override returns (address) {
        return address(l2WethTransparentProxy);
    }
}