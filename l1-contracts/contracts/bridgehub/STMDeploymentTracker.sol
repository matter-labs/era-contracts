// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {L2TransactionRequestTwoBridgesInner} from "./IBridgehub.sol";
import {ISTMDeploymentTracker} from "./ISTMDeploymentTracker.sol";

import {IBridgehub, IL1SharedBridge} from "../bridge/interfaces/IL1SharedBridge.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Contract to be deployed on L1, can link together other contracts based on AssetInfo.
contract STMDeploymentTracker is ISTMDeploymentTracker, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IL1SharedBridge public immutable override SHARED_BRIDGE;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "STM DT: not BH");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub, IL1SharedBridge _sharedBridge) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        SHARED_BRIDGE = _sharedBridge;
    }

    /// @notice used to initialize the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    function registerSTMAssetOnL1(address _stmAddress) external onlyOwner {
        require(BRIDGE_HUB.stateTransitionManagerIsRegistered(_stmAddress), "STMDT: stm not registered");
        SHARED_BRIDGE.setAssetAddress(bytes32(uint256(uint160(_stmAddress))), address(BRIDGE_HUB));
        BRIDGE_HUB.setAssetAddress(bytes32(uint256(uint160(_stmAddress))), _stmAddress);
    }

    /// @dev registerSTMAssetOnL2SharedBridge, use via requestL2TransactionTwoBridges
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256,
        bytes calldata _data
    ) external payable onlyBridgehub returns (L2TransactionRequestTwoBridgesInner memory request) {
        require(msg.value == 0, "STMDT: no eth allowed");
        require(_prevMsgSender == owner(), "STMDT: not owner");
        (bool _registerOnBridgehub, address _stmL1Address, address _stmL2Address) = abi.decode(
            _data,
            (bool, address, address)
        );

        if (_registerOnBridgehub) {
            request = _registerSTMAssetOnL2Bridgehub(_chainId, _stmL1Address, _stmL2Address);
        } else {
            request = _registerSTMAssetOnL2SharedBridge(_chainId, _stmL1Address);
        }
    }

    function _registerSTMAssetOnL2SharedBridge(
        uint256 _chainId,
        address _stmL1Address
    ) internal view returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = abi.encodeWithSelector(
            IL1SharedBridge.setAssetAddress.selector,
            bytes32(uint256(uint160(_stmL1Address))),
            BRIDGE_HUB.bridgehubCounterParts(_chainId)
        );

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: SHARED_BRIDGE.l2BridgeAddress(_chainId),
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: bytes32(0)
        });
    }

    function _registerSTMAssetOnL2Bridgehub(
        uint256 _chainId,
        address _stmL1Address,
        address _stmL2Address
    ) internal view returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = abi.encodeWithSelector(
            IBridgehub.setAssetAddress.selector,
            bytes32(uint256(uint160(_stmL1Address))),
            _stmL2Address
        );

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: BRIDGE_HUB.bridgehubCounterParts(_chainId),
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: bytes32(0)
        });
    }

    /// @dev we need to implement this for the bridgehub
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external {}
}
