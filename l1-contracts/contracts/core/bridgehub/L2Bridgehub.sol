// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "../../common/Config.sol";
import {BridgehubBase} from "./BridgehubBase.sol";
import {IL2Bridgehub} from "./IL2Bridgehub.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {ICTMDeploymentTracker} from "../ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {NotInGatewayMode, NotRelayedSender} from "./L1BridgehubErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2Bridgehub is BridgehubBase, IL2Bridgehub {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @dev The asset ID of ETH token.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 public ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public L1_CHAIN_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is a temporary security measure.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public MAX_NUMBER_OF_ZK_CHAINS;

    modifier onlyChainRegistrationSender() {
        if (
            /// Note on the L2 the chainRegistrationSender is aliased.
            msg.sender != chainRegistrationSender && msg.sender != SERVICE_TRANSACTION_SENDER
        ) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
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

    /// @notice used to register chains on L2 for the purpose of interop.
    /// @param _chainId the chainId of the chain to be registered.
    /// @param _baseTokenAssetId the base token asset id of the chain.
    function registerChainForInterop(uint256 _chainId, bytes32 _baseTokenAssetId) external onlyChainRegistrationSender {
        baseTokenAssetId[_chainId] = _baseTokenAssetId;
    }

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the asset ID of ETH token for internal use.
    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    /// @dev Returns the maximum number of ZK chains for internal use.
    function _maxNumberOfZKChains() internal view override returns (uint256) {
        return MAX_NUMBER_OF_ZK_CHAINS;
    }

    /// @dev Returns the L1 chain ID for internal use.
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    modifier onlySettlementLayerRelayedSender() {
        /// There is no sender for the wrapping, we use a virtual address.
        if (msg.sender != SETTLEMENT_LAYER_RELAY_SENDER) {
            revert NotRelayedSender(msg.sender, SETTLEMENT_LAYER_RELAY_SENDER);
        }
        _;
    }

    /// @notice Used to forward a transaction on the gateway to the chains mailbox.
    /// @param _chainId the chainId of the chain
    /// @param _canonicalTxHash the canonical transaction hash
    /// @param _expirationTimestamp the expiration timestamp for the transaction
    function forwardTransactionOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external onlySettlementLayerRelayedSender {
        if (L1_CHAIN_ID == block.chainid) {
            revert NotInGatewayMode();
        }
        address zkChain = zkChainMap.get(_chainId);
        IZKChain(zkChain).bridgehubRequestL2TransactionOnGateway(_canonicalTxHash, _expirationTimestamp);
    }

    /// @notice Set addresses
    function setAddresses(
        address _assetRouter,
        ICTMDeploymentTracker _l1CtmDeployer,
        IMessageRootBase _messageRoot,
        address _chainAssetHandler,
        address _chainRegistrationSender
    ) external override onlyOwnerOrUpgrader {
        assetRouter = IAssetRouterBase(_assetRouter);
        l1CtmDeployer = _l1CtmDeployer;
        messageRoot = _messageRoot;
        chainAssetHandler = _chainAssetHandler;
        chainRegistrationSender = _chainRegistrationSender;
    }
}
