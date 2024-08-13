// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {L2TransactionRequestTwoBridgesInner} from "./IBridgehub.sol";
import {ISTMDeploymentTracker} from "./ISTMDeploymentTracker.sol";

import {IBridgehub, IL1AssetRouter} from "../bridge/interfaces/IL1AssetRouter.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {L2_BRIDGEHUB_ADDR} from "../common/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Contract to be deployed on L1, can link together other contracts based on AssetInfo.
contract STMDeploymentTracker is ISTMDeploymentTracker, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IL1AssetRouter public immutable override SHARED_BRIDGE;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        // solhint-disable-next-line gas-custom-errors
        require(msg.sender == address(BRIDGE_HUB), "STM DT: not BH");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation on L1.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub, IL1AssetRouter _sharedBridge) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        SHARED_BRIDGE = _sharedBridge;
    }

    /// @notice used to initialize the contract
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @notice Used to register the stm asset in L1 contracts, AssetRouter and Bridgehub.
    /// @param _stmAddress the address of the stm asset
    function registerSTMAssetOnL1(address _stmAddress) external onlyOwner {
        // solhint-disable-next-line gas-custom-errors

        require(BRIDGE_HUB.stateTransitionManagerIsRegistered(_stmAddress), "STMDT: stm not registered");
        SHARED_BRIDGE.setAssetHandlerAddressInitial(bytes32(uint256(uint160(_stmAddress))), address(BRIDGE_HUB));
        BRIDGE_HUB.setAssetHandlerAddressInitial(bytes32(uint256(uint160(_stmAddress))), _stmAddress);
    }

    /// @notice The function responsible for registering the L2 counterpart of an STM asset on the L2 Bridgehub.
    /// @dev The function is called by the Bridgehub contract during the `Bridgehub.requestL2TransactionTwoBridges`.
    /// @dev Since the L2 settlement layers `_chainId` might potentially have ERC20 tokens as native assets,
    /// there are two ways to perform the L1->L2 transaction:
    /// - via the `Bridgehub.requestL2TransactionDirect`. However, this would require the STMDeploymentTracker to
    /// handle the ERC20 balances to be used in the transaction.
    /// - via the `Bridgehub.requestL2TransactionTwoBridges`. This way it will be the sender that provides the funds
    /// for the L2 transaction.
    /// The second approach is used due to its simplicity even though it gives the sender slightly more control over the call:
    /// `gasLimit`, etc.
    /// @param _chainId the chainId of the chain
    /// @param _prevMsgSender the previous message sender
    /// @param _data the data of the transaction
    // slither-disable-next-line locked-ether
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256,
        bytes calldata _data
    ) external payable onlyBridgehub returns (L2TransactionRequestTwoBridgesInner memory request) {
        // solhint-disable-next-line gas-custom-errors

        require(msg.value == 0, "STMDT: no eth allowed");
        // solhint-disable-next-line gas-custom-errors

        require(_prevMsgSender == owner(), "STMDT: not owner");
        (address _stmL1Address, address _stmL2Address) = abi.decode(_data, (address, address));

        request = _registerSTMAssetOnL2Bridgehub(_chainId, _stmL1Address, _stmL2Address);
    }

    /// @notice The function called by the Bridgehub after the L2 transaction has been initiated.
    /// @dev Not used in this contract. In case the transaction fails, we can just re-try it.
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external {}

    // todo this has to be put in L1AssetRouter via TwoBridges for custom base tokens. Hard, because we have to have multiple msg types in bridgehubDeposit in the AssetRouter.
    /// @notice Used to register the stm asset in L2 AssetRouter.
    /// @param _chainId the chainId of the chain
    function registerSTMAssetOnL2SharedBridge(
        uint256 _chainId,
        address _stmL1Address,
        uint256 _mintValue,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByteLimit,
        address _refundRecipient
    ) public payable onlyOwner {
        bytes32 assetId;
        {
            assetId = getAssetId(_stmL1Address);
        }
        // slither-disable-next-line unused-return
        SHARED_BRIDGE.setAssetHandlerAddressOnCounterPart{value: msg.value}({
            _chainId: _chainId,
            _mintValue: _mintValue,
            _l2TxGasLimit: _l2TxGasLimit,
            _l2TxGasPerPubdataByte: _l2TxGasPerPubdataByteLimit,
            _refundRecipient: _refundRecipient,
            _assetId: assetId,
            _assetAddressOnCounterPart: L2_BRIDGEHUB_ADDR
        });
    }

    function getAssetId(address _l1STM) public view override returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), bytes32(uint256(uint160(_l1STM)))));
    }

    // Todo this works for now, but it will not work in the future if we want to change STM DTs. Probably ok.
    /// @notice Used to register the stm asset in L2 Bridgehub.
    /// @param _chainId the chainId of the chain
    function _registerSTMAssetOnL2Bridgehub(
        // solhint-disable-next-line no-unused-vars
        uint256 _chainId,
        address _stmL1Address,
        address _stmL2Address
    ) internal pure returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = abi.encodeCall(
            /// todo it should not be initial in setAssetHandlerAddressInitial
            IBridgehub.setAssetHandlerAddressInitial,
            (bytes32(uint256(uint160(_stmL1Address))), _stmL2Address)
        );

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_BRIDGEHUB_ADDR,
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            // The `txDataHash` is typically used in usual ERC20 bridges to commit to the transaction data
            // so that the user can recover funds in case the bridging fails on L2.
            // However, this contract uses the `requestL2TransactionTwoBridges` method just to perform an L1->L2 transaction.
            // We do not need to recover anything and so `bytes32(0)` here is okay.
            txDataHash: bytes32(0)
        });
    }
}
