// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner, BridgehubMintCTMAssetData, BridgehubBurnCTMAssetData} from "./IBridgehub.sol";
import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IL1BaseTokenAssetHandler} from "../bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";

import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER, L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS} from "../common/Config.sol";
import {BridgehubL2TransactionRequest, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ICTMDeploymentTracker} from "./ICTMDeploymentTracker.sol";
import {NotL1, NotRelayedSender, NotAssetRouter, ChainIdAlreadyPresent, ChainNotPresentInCTM, SecondBridgeAddressTooLow, NotInGatewayMode, SLNotWhitelisted, IncorrectChainAssetId, NotCurrentSL, HyperchainNotRegistered, IncorrectSender, AlreadyCurrentSL, ChainNotLegacy} from "./L1BridgehubErrors.sol";
import {NoCTMForAssetId, SettlementLayersMustSettleOnL1, MigrationPaused, AssetIdAlreadyRegistered, ChainIdNotRegistered, AssetHandlerNotRegistered, ZKChainLimitReached, CTMAlreadyRegistered, CTMNotRegistered, ZeroChainId, ChainIdTooBig, BridgeHubAlreadyRegistered, MsgValueMismatch, ZeroAddress, Unauthorized, SharedBridgeNotSet, WrongMagicValue, ChainIdAlreadyExists, ChainIdMismatch, ChainIdCantBeCurrentChain, EmptyAssetId, AssetIdNotSupported, IncorrectBridgeHubAddress} from "../common/L1ContractErrors.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {AssetHandlerModifiers} from "../bridge/interfaces/AssetHandlerModifiers.sol";
import {BridgehubBase} from "./BridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
/// Bridgehub is also an IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev Important: L2 contracts are not allowed to have any immutable variables. This is needed for compatibility with ZKsyncOS.
contract L2Bridgehub is BridgehubBase {
    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal ETH_TOKEN_ASSET_ID;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public L1_CHAIN_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is the temporary security measure.
    uint256 public MAX_NUMBER_OF_ZK_CHAINS;

    /// @notice to avoid parity hack
    constructor() {}

    /// @notice Initializes the contract
    /// @dev This function is used to initialize the contract with the initial values.
    /// @dev This function is called both for new chains.
    /// @param _l1ChainId The chain id of L1.
    /// @param _owner The owner of the contract.
    /// @param _maxNumberOfZKChains The maximum number of ZK chains that can be created.
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        uint256 _maxNumberOfZKChains
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        updateL2(_l1ChainId, _maxNumberOfZKChains);
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @notice Updates the contract.
    /// @dev This function is used to initialize the new implementation of L2Bridgehub on existing chains during
    /// the upgrade.
    /// @param _l1ChainId The chain id of L1.
    /// @param _maxNumberOfZKChains The maximum number of ZK chains that can be created.
    function updateL2(uint256 _l1ChainId, uint256 _maxNumberOfZKChains) public onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        MAX_NUMBER_OF_ZK_CHAINS = _maxNumberOfZKChains;

        // Note that this assumes that the bridgehub only accepts transactions on chains with ETH base token only.
        // This is indeed true, since the only methods where this immutable is used are the ones with `onlyL1` modifier.
        // We will change this with interop.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
    }

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _maxNumberOfZKChains() internal view override returns (uint256) {
        return MAX_NUMBER_OF_ZK_CHAINS;
    }
}
