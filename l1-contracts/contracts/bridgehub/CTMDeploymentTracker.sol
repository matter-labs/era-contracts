// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "./IBridgehub.sol";
import {ICTMDeploymentTracker} from "./ICTMDeploymentTracker.sol";

import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {L2_BRIDGEHUB_ADDR} from "../common/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Contract to be deployed on L1, can link together other contracts based on AssetInfo.
contract CTMDeploymentTracker is ICTMDeploymentTracker, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IAssetRouterBase public immutable override L1_ASSET_ROUTER;

    /// @dev The encoding version of the data.
    bytes1 internal constant ENCODING_VERSION = 0x01;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        // solhint-disable-next-line gas-custom-errors
        require(msg.sender == address(BRIDGE_HUB), "CTM DT: not BH");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyOwnerViaRouter(address _prevMsgSender) {
        // solhint-disable-next-line gas-custom-errors
        require(msg.sender == address(L1_ASSET_ROUTER) && _prevMsgSender == owner(), "CTM DT: not owner via router");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation on L1.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub, IAssetRouterBase _sharedBridge) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        L1_ASSET_ROUTER = _sharedBridge;
    }

    /// @notice used to initialize the contract
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @notice Used to register the ctm asset in L1 contracts, AssetRouter and Bridgehub.
    /// @param _ctmAddress the address of the ctm asset
    function registerCTMAssetOnL1(address _ctmAddress) external onlyOwner {
        // solhint-disable-next-line gas-custom-errors

        require(BRIDGE_HUB.chainTypeManagerIsRegistered(_ctmAddress), "CTMDT: ctm not registered");
        L1_ASSET_ROUTER.setAssetHandlerAddressThisChain(bytes32(uint256(uint160(_ctmAddress))), address(BRIDGE_HUB));
        BRIDGE_HUB.setAssetHandlerAddress(bytes32(uint256(uint160(_ctmAddress))), _ctmAddress);
    }

    /// @notice The function responsible for registering the L2 counterpart of an CTM asset on the L2 Bridgehub.
    /// @dev The function is called by the Bridgehub contract during the `Bridgehub.requestL2TransactionTwoBridges`.
    /// @dev Since the L2 settlement layers `_chainId` might potentially have ERC20 tokens as native assets,
    /// there are two ways to perform the L1->L2 transaction:
    /// - via the `Bridgehub.requestL2TransactionDirect`. However, this would require the CTMDeploymentTracker to
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

        require(msg.value == 0, "CTMDT: no eth allowed");
        // solhint-disable-next-line gas-custom-errors

        require(_prevMsgSender == owner(), "CTMDT: not owner");
        bytes1 encodingVersion = _data[0];
        require(encodingVersion == ENCODING_VERSION, "CTMDT: wrong encoding version");
        (address _ctmL1Address, address _ctmL2Address) = abi.decode(_data[1:], (address, address));

        request = _registerCTMAssetOnL2Bridgehub(_chainId, _ctmL1Address, _ctmL2Address);
    }

    /// @notice The function called by the Bridgehub after the L2 transaction has been initiated.
    /// @dev Not used in this contract. In case the transaction fails, we can just re-try it.
    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external {}

    /// @notice Used to register the ctm asset in L2 AssetRouter.
    /// @param _prevMsgSender the address that called the Router
    /// @param _assetHandlerAddressOnCounterpart the address of the asset handler on the counterpart chain.
    function bridgeCheckCounterpartAddress(
        uint256,
        bytes32,
        address _prevMsgSender,
        address _assetHandlerAddressOnCounterpart
    ) external view override onlyOwnerViaRouter(_prevMsgSender) {
        require(_assetHandlerAddressOnCounterpart == L2_BRIDGEHUB_ADDR, "CTMDT: wrong counter part");
    }

    function getAssetId(address _l1CTM) public view override returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), bytes32(uint256(uint160(_l1CTM)))));
    }

    /// @notice Used to register the ctm asset in L2 Bridgehub.
    /// @param _chainId the chainId of the chain
    function _registerCTMAssetOnL2Bridgehub(
        // solhint-disable-next-line no-unused-vars
        uint256 _chainId,
        address _ctmL1Address,
        address _ctmL2Address
    ) internal pure returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = abi.encodeCall(
            IBridgehub.setAssetHandlerAddress,
            (bytes32(uint256(uint160(_ctmL1Address))), _ctmL2Address)
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