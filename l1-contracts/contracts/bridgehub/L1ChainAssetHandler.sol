// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IL1Nullifier} from "../bridge/interfaces/IL1Nullifier.sol";
import {TxStatus} from "../common/Messaging.sol";
import {InvalidProof} from "../common/L1ContractErrors.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {MigrationNotInProgress} from "./L1BridgehubErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev L1 version – keeps the cheap immutables set in the constructor.
contract L1ChainAssetHandler is ChainAssetHandlerBase {
    /// @dev The assetId of the base token.
    bytes32 public immutable override ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    uint256 public immutable override L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    address public immutable override BRIDGEHUB;

    /// @dev The message root contract.
    address public immutable override MESSAGE_ROOT;

    /// @dev The asset router contract.
    address public immutable override ASSET_ROUTER;

    /// @dev The asset tracker contract.
    address internal immutable ASSET_TRACKER;

    /// @dev The L1 nullifier contract.
    IL1Nullifier internal immutable L1_NULLIFIER;

    /// @dev The mapping showing for each chain if migration is in progress or not, used for freezing deposits.abi
    mapping(uint256 chainId => bool isMigrationInProgress) public isMigrationInProgress;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }
    function _bridgehub() internal view override returns (address) {
        return BRIDGEHUB;
    }
    function _messageRoot() internal view override returns (address) {
        return MESSAGE_ROOT;
    }
    function _assetRouter() internal view override returns (address) {
        return ASSET_ROUTER;
    }

    function _assetTracker() internal view override returns (address) {
        return ASSET_TRACKER;
    }

    constructor(
        address _owner,
        address _bridgehub,
        address _assetRouter,
        address _messageRoot,
        address _assetTracker,
        IL1Nullifier _l1Nullifier
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGEHUB = _bridgehub;
        ASSET_ROUTER = _assetRouter;
        MESSAGE_ROOT = _messageRoot;
        L1_CHAIN_ID = block.chainid;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        ASSET_TRACKER = _assetTracker;
        L1_NULLIFIER = _l1Nullifier;
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    function confirmSuccessfulMigrationToGateway(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes memory _assetData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) public nonReentrant {
        bool proofValid = IMessageRoot(MESSAGE_ROOT).proveL1ToL2TransactionStatusShared({
            _chainId: _chainId,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof,
            _status: TxStatus.Success
        });
        require(proofValid, InvalidProof());
        require(isMigrationInProgress[_chainId], MigrationNotInProgress());
        isMigrationInProgress[_chainId] = false;
    }

    function _setMigrationInProgressOnL1(uint256 _chainId) internal override {
        isMigrationInProgress[_chainId] = true;
    }
}
