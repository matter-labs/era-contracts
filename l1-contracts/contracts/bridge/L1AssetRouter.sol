// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1AssetRouter} from "./interfaces/IL1AssetRouter.sol";
import {IAssetRouterBase} from "./interfaces/IAssetRouterBase.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IL2BridgeLegacy} from "./interfaces/IL2BridgeLegacy.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IAssetHandler} from "./interfaces/IAssetHandler.sol";
import {IL1Nullifier} from "./interfaces/IL1Nullifier.sol";
import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "./interfaces/INativeTokenVault.sol";
import {IL1SharedBridgeLegacy} from "./interfaces/IL1SharedBridgeLegacy.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";

import {AssetRouterBase} from "./AssetRouterBase.sol";

import {BridgeHelper} from "./BridgeHelper.sol";

import {IL1AssetDeploymentTracker} from "../bridge/interfaces/IL1AssetDeploymentTracker.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1AssetRouter is  AssetRouterBase, IL1AssetRouter, // IL1SharedBridgeLegacy,
ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of ZKsync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev The encoding version used for new txs.
    bytes1 internal constant LEGACY_ENCODING_VERSION = 0x00;

    /// @dev The encoding version used for legacy txs.
    bytes1 internal constant NEW_ENCODING_VERSION = 0x01;

    /// @dev The encoding version used for txs that set the asset handler on the counterpart contract.
    bytes1 internal constant SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION = 0x02;

    /// @dev Address of nullifier.
    IL1Nullifier public nullifierStorage;

    /// @notice Checks that the message sender is the nullifier.
    modifier onlyNullifier() {
        require(msg.sender == address(nullifierStorage), "L1AR: not nullifier");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or zkSync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        require(
            msg.sender == address(BRIDGE_HUB) || (_chainId == ERA_CHAIN_ID && msg.sender == ERA_DIAMOND_PROXY),
            "L1AR: msg.sender not equal to bridgehub or era chain"
        );
        _;
    }

    /// @notice Checks that the message sender is the legacy bridge.
    // modifier onlyLegacyBridge() {
    //     require(msg.sender == address(legacyBridge), "L1AR: not legacy bridge");
    //     _;
    // } // kl todo 

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _bridgehub,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer AssetRouterBase(IBridgehub(_bridgehub), ETH_TOKEN_ADDRESS) {
        _disableInitializers();
        ERA_CHAIN_ID = _eraChainId;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy.
    /// @dev Used for testing purposes only, as the contract has been initialized on mainnet.
    /// @param _owner The address which can change L2 token implementation and upgrade the bridge implementation.
    /// The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), "ShB owner 0");
        _transferOwnership(_owner);
    }

    /// @notice Legacy function used for migration, do not use!
    /// @param _chainId The chain id on which the bridge is deployed.
    // slither-disable-next-line uninitialized-state-variables
    // function l2BridgeAddress(uint256 _chainId) external view returns (address) {
    //     // slither-disable-next-line uninitialized-state-variables
    //     return __DEPRECATED_l2BridgeAddress[_chainId];
    // } // kl todo 

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nullifier The address of the nullifier.
    function setL1Nullifier(IL1Nullifier _nullifier) external onlyOwner {
        require(address(_nullifier) == address(0), "ShB: nullifier already set");
        require(address(_nullifier) != address(0), "ShB: nullifier 0");
        nullifierStorage = _nullifier;
    }

    /// @param _legacyBridge The address of the legacy bridge.
    // function setL1Erc20Bridge(address _legacyBridge) external onlyOwner {
    //     require(address(_legacyBridge) == address(0), "L1AR: legacy bridge already set");
    //     require(_legacyBridge != address(0), "L1AR: legacy bridge 0");
    //     legacyBridge = IL1ERC20Bridge(_legacyBridge);
    // } // kl todo 

    /// @notice Used to set the assed deployment tracker address for given asset data.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetDeploymentTracker The whitelisted address of asset deployment tracker for provided asset.
    function setAssetDeploymentTracker(
        bytes32 _assetRegistrationData,
        address _assetDeploymentTracker
    ) external onlyOwner {
        bytes32 assetId = keccak256(
            abi.encode(uint256(block.chainid), _assetDeploymentTracker, _assetRegistrationData)
        );
        assetDeploymentTracker[assetId] = _assetDeploymentTracker;
        emit AssetDeploymentTrackerSet(assetId, _assetDeploymentTracker, _assetRegistrationData);
    }

    /// @notice Sets the asset handler address for a specified asset ID on the chain of the asset deployment tracker.
    /// @dev The caller of this function is encoded within the `assetId`, therefore, it should be invoked by the asset deployment tracker contract.
    /// @dev Typically, for most tokens, ADT is the native token vault. However, custom tokens may have their own specific asset deployment trackers.
    /// @dev `setAssetHandlerAddressOnCounterpart` should be called on L1 to set asset handlers on L2 chains for a specific asset ID.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressThisChain(bytes32 _assetRegistrationData, address _assetHandlerAddress) external override(IL1AssetRouter, AssetRouterBase) {
        bool senderIsNTV = msg.sender == address(nativeTokenVault);
        address sender = senderIsNTV ? L2_NATIVE_TOKEN_VAULT_ADDRESS : msg.sender;
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, sender);
        require(senderIsNTV || msg.sender == assetDeploymentTracker[assetId], "ShB: not NTV or ADT");
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        if (senderIsNTV) {
            assetDeploymentTracker[assetId] = msg.sender;
        }
        emit AssetHandlerRegisteredInitial(assetId, _assetHandlerAddress, _assetRegistrationData, sender);
    }

    /// @notice Used to set the asset handler address for a given asset ID on a remote ZK chain
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @param _chainId The ZK chain ID.
    /// @param _assetId The encoding of asset ID.
    /// @param _assetHandlerAddressOnCounterpart The address of the asset handler, which will hold the token of interest.
    /// @return request The tx request sent to the Bridgehub
    function _setAssetHandlerAddressOnCounterpart(
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        address _assetHandlerAddressOnCounterpart
    ) internal returns (L2TransactionRequestTwoBridgesInner memory request) {
        IL1AssetDeploymentTracker(assetDeploymentTracker[_assetId]).bridgeCheckCounterpartAddress(
            _chainId,
            _assetId,
            _prevMsgSender,
            _assetHandlerAddressOnCounterpart
        );

        bytes memory l2Calldata = abi.encodeCall(
            IL2Bridge.setAssetHandlerAddress,
            (_assetId, _assetHandlerAddressOnCounterpart)
        );
        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2Calldata,
            factoryDeps: new bytes[](0),
            txDataHash: bytes32(0x00)
        });
    }

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) public payable virtual override(IAssetRouterBase, AssetRouterBase) onlyBridgehubOrEra(_chainId) whenNotPaused {
        super.bridgehubDepositBaseToken(_chainId, _assetId, _prevMsgSender, _amount);
    }

    /// @notice Initiates a deposit transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _data The calldata for the second bridge deposit.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    )
        external
        payable
        override(IAssetRouterBase, AssetRouterBase)
        onlyBridgehub
        whenNotPaused
        returns (L2TransactionRequestTwoBridgesInner memory request)
    {
        bytes32 assetId;
        bytes memory transferData;
        bytes1 encodingVersion = _data[0];

        // The new encoding ensures that the calldata is collision-resistant with respect to the legacy format.
        // In the legacy calldata, the first input was the address, meaning the most significant byte was always `0x00`.
        if (encodingVersion == SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION) {
            (bytes32 _assetId, address _assetHandlerAddressOnCounterpart) = abi.decode(_data[1:], (bytes32, address));
            return
                _setAssetHandlerAddressOnCounterpart(
                    _chainId,
                    _prevMsgSender,
                    _assetId,
                    _assetHandlerAddressOnCounterpart
                );
        } else if (encodingVersion == NEW_ENCODING_VERSION) {
            (assetId, transferData) = abi.decode(_data[1:], (bytes32, bytes));
            require(
                assetHandlerAddress[assetId] != address(nativeTokenVault),
                "ShB: new encoding format not yet supported for NTV"
            );
        } else {
            (assetId, transferData) = _handleLegacyData(_data, _prevMsgSender);
        }

        require(BRIDGE_HUB.baseTokenAssetId(_chainId) != assetId, "L1AR: baseToken deposit not supported");

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _value: _l2Value,
            _assetId: assetId,
            _prevMsgSender: _prevMsgSender,
            _transferData: transferData,
            _passValue: true
        });
        bytes32 txDataHash = this.encodeTxDataHash(encodingVersion, _prevMsgSender, assetId, transferData);

        request = _requestToBridge({
            _chainId: block.chainid, // kl todo this chain?
            _prevMsgSender: _prevMsgSender,
            _assetId: assetId,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _prevMsgSender,
            assetId: assetId,
            bridgeMintCalldata: bridgeMintCalldata
        });
    }

    // /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    // /// where tokens would be unlocked.
    // /// @param _chainId The chain ID of the ZK chain to which to withdraw.
    // /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    // /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    // /// @param _transferData The data that is passed to the asset handler contract.
    // function bridgehubWithdraw(
    //     // ToDo: how to unify L1 and L2 withdraw? 1 is done via system contract, another one via request, so input / output is inhenerently different
    //     uint256 _chainId,
    //     address _prevMsgSender,
    //     bytes32 _assetId,
    //     bytes memory _transferData
    // ) external override onlyBridgehub whenNotPaused returns (L2TransactionRequestTwoBridgesInner memory request) {
    //     require(BRIDGE_HUB.baseTokenAssetId(_chainId) != _assetId, "ShB: baseToken withdrawal not supported");

    //     bytes memory l2BridgeMintCalldata = _burn({
    //         _chainId: _chainId,
    //         _value: 0,
    //         _assetId: _assetId,
    //         _prevMsgSender: _prevMsgSender,
    //         _transferData: _transferData
    //     });
    //     bytes32 txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(_prevMsgSender, _assetId, _transferData)));

    //     request = _requestToBridge({
    //         _chainId: _chainId,
    //         _prevMsgSender: _prevMsgSender,
    //         _assetId: _assetId,
    //         _bridgeMintCalldata: l2BridgeMintCalldata,
    //         _txDataHash: txDataHash
    //     });

    //     emit BridgehubWithdrawalInitiated(_chainId, msg.sender, _assetId, keccak256(_transferData));
    // }

    /// @notice Routes the confirmation to nullifier for backward compatibility.
 

    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub whenNotPaused {
        nullifierStorage.bridgehubConfirmL2Transaction(_chainId, _txDataHash, _txHash);
    }

    /// @notice Ensures that token is registered with native token vault.
    /// @dev Only used when deposit is made with legacy data encoding format.
    /// @param _l1Token The L1 token address which should be registered with native token vault.
    /// @return assetId The asset ID of the token provided.
    function _ensureTokenRegisteredWithNTV(address _l1Token) internal returns (bytes32 assetId) {
        assetId = nativeTokenVault.getAssetId(block.chainid, _l1Token); // kl todo this chain?
        if (nativeTokenVault.tokenAddress(assetId) == address(0)) {
            nativeTokenVault.registerToken(_l1Token);
        }
    } // kl todo fix function

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The chain ID to which transfer failed.
    /// @param _depositSender The address of the deposit initiator.
    /// @param _assetId The address of the deposited L1 ERC20 token.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
 



    /// @dev Calls the internal `_encodeTxDataHash`. Used as a wrapped for try / catch case.
    /// @param _encodingVersion The version of the encoding.
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @return txDataHash The resulting encoded transaction data hash.
    function encodeTxDataHash(
        bytes1 _encodingVersion,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external view returns (bytes32 txDataHash) {
        return _encodeTxDataHash(_encodingVersion, _prevMsgSender, _assetId, _transferData);
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The ZK chain id to which deposit was initiated.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    // / @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver. Might include extra information.
    // / @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    // / @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    // / @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    // / @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    // / @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes memory _assetData
    ) external onlyNullifier nonReentrant whenNotPaused {
        IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeRecoverFailedTransfer(_chainId, _assetId, _depositSender, _assetData);

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _assetId, _assetData);
    }

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    function finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public override(AssetRouterBase, IAssetRouterBase) onlyNullifier returns (address l1Receiver, uint256 amount) {
        (l1Receiver, amount) = super.finalizeDeposit(_chainId, _assetId, _transferData);
    }

    /*//////////////////////////////////////////////////////////////
                     Legacy Functions & Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Routes the request through l1 asset router, to miminize the number of addresses from with l2 asset router expects deposit.
    function depositLegacyErc20Bridge(
        L2TransactionRequestDirect calldata _request
    ) external payable override onlyNullifier nonReentrant whenNotPaused returns (bytes32 l2TxHash) {
        return BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(_request);
    }

    /// @notice Decodes the transfer input for legacy data and transfers allowance to NTV.
    /// @dev Is not applicable for custom asset handlers.
    /// @param _data The encoded transfer data (address _l1Token, uint256 _depositAmount, address _l2Receiver).
    /// @param _prevMsgSender The address of the deposit initiator.
    /// @return Tuple of asset ID and encoded transfer data to conform with new encoding standard.
    function _handleLegacyData(bytes calldata _data, address _prevMsgSender) internal returns (bytes32, bytes memory) {
        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        bytes32 assetId = _ensureTokenRegisteredWithNTV(_l1Token);
        _transferAllowanceToNTV(assetId, _depositAmount, _prevMsgSender);
        return (assetId, abi.encode(_depositAmount, _l2Receiver));
    }

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    function finalizeWithdrawal(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external override onlyNullifier returns (address l1Receiver, uint256 amount) {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IAssetHandler(assetHandler).bridgeMint(_chainId, _assetId, _transferData);
        } else {
            IAssetHandler(address(nativeTokenVault)).bridgeMint(_chainId, _assetId, _transferData); // Maybe it's better to receive amount and receiver here? transferData may have different encoding
            assetHandlerAddress[_assetId] = address(nativeTokenVault);
        }

        (amount, l1Receiver) = abi.decode(_transferData, (uint256, address));

        emit WithdrawalFinalizedAssetRouter(_chainId, l1Receiver, _assetId, amount);
    }
    // function bridgeRecoverFailedTransfer(
    //     uint256 _chainId,
    //     address _depositSender,
    //     bytes32 _assetId,        
    //     bytes32 _l2TxHash,
    //     uint256 _l2BatchNumber,
    //     uint256 _l2MessageIndex,
    //     uint16 _l2TxNumberInBatch,
    //     bytes32[] calldata _merkleProof
    // ) public nonReentrant whenNotPaused {
    //     {
    //         bool proofValid = BRIDGE_HUB.proveL1ToL2TransactionStatus({
    //             _chainId: _chainId,
    //             _l2TxHash: _l2TxHash,
    //             _l2BatchNumber: _l2BatchNumber,
    //             _l2MessageIndex: _l2MessageIndex,
    //             _l2TxNumberInBatch: _l2TxNumberInBatch,
    //             _merkleProof: _merkleProof,
    //             _status: TxStatus.Failure
    //         });
    //         require(proofValid, "yn");
    //     }

    //     require(!_isEraLegacyDeposit(_chainId, _l2BatchNumber, _l2TxNumberInBatch), "L1AR: legacy cFD");
    //     {
    //         bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
    //         // Determine if the given dataHash matches the calculated legacy transaction hash.
    //         bool isLegacyTxDataHash = _isLegacyTxDataHash(_depositSender, _assetId, _assetData, dataHash);
    //         // If the dataHash matches the legacy transaction hash, skip the next step.
    //         // Otherwise, perform the check using the new transaction data hash encoding.
    //         if (!isLegacyTxDataHash) {
    //             bytes32 txDataHash = _encodeTxDataHash(NEW_ENCODING_VERSION, _depositSender, _assetId, _assetData);
    //             require(dataHash == txDataHash, "L1AR: d.it not hap");
    //         }
    //     }
    //     delete depositHappened[_chainId][_l2TxHash];

    //     IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeRecoverFailedTransfer(
    //         _chainId,
    //         _assetId,
    //         _depositSender,
    //         _assetData
    //     );

    //     emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _assetId, _assetData);
    // }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    // function getERC20Getters(address _token) public view returns (bytes memory) {
    //     return BridgeHelper.getERC20Getters(_token, ETH_TOKEN_ADDRESS);
    // }

    // struct MessageParams {
    //     uint256 l2BatchNumber;
    //     uint256 l2MessageIndex;
    //     uint16 l2TxNumberInBatch;
    // }

    /// @notice Internal function that handles the logic for finalizing withdrawals, supporting both the current bridge system and the legacy ERC20 bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message.
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
    /// @return l1Receiver The address to receive bridged assets.
    /// @return assetId The bridged asset ID.
    /// @return amount The amount of asset bridged.
    // function _finalizeWithdrawal(
    //     uint256 _chainId,
    //     uint256 _l2BatchNumber,
    //     uint256 _l2MessageIndex,
    //     uint16 _l2TxNumberInBatch,
    //     bytes calldata _message,
    //     bytes32[] calldata _merkleProof
    // ) internal nonReentrant whenNotPaused returns (address l1Receiver, bytes32 assetId, uint256 amount) {
    //     require(
    //         !isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex],
    //         "L1AR: Withdrawal is already finalized"
    //     );
    //     isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

    //     // Handling special case for withdrawal from ZKsync Era initiated before Shared Bridge.
    //     require(!_isEraLegacyEthWithdrawal(_chainId, _l2BatchNumber), "L1AR: legacy eth withdrawal");
    //     require(!_isEraLegacyTokenWithdrawal(_chainId, _l2BatchNumber), "L1AR: legacy token withdrawal");

    //     bytes memory transferData;
    //     {
    //         MessageParams memory messageParams = MessageParams({
    //             l2BatchNumber: _l2BatchNumber,
    //             l2MessageIndex: _l2MessageIndex,
    //             l2TxNumberInBatch: _l2TxNumberInBatch
    //         });
    //         (assetId, transferData) = _checkWithdrawal(_chainId, messageParams, _message, _merkleProof);
    //     }
    //     address l1AssetHandler = assetHandlerAddress[assetId];
    //     // slither-disable-next-line unused-return
    //     IL1AssetHandler(l1AssetHandler).bridgeMint(_chainId, assetId, transferData);
    //     (amount, l1Receiver) = abi.decode(transferData, (uint256, address));

    //     emit WithdrawalFinalizedSharedBridge(_chainId, l1Receiver, assetId, amount);
    // }


    // /// @dev Determines if the provided data for a failed deposit corresponds to a legacy failed deposit.
    // /// @param _prevMsgSender The address of the entity that initiated the deposit.
    // /// @param _assetId The unique identifier of the deposited L1 token.
    // /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    // /// @param _expectedTxDataHash The nullifier data hash stored for the failed deposit.
    // /// @return isLegacyTxDataHash True if the transaction is legacy, false otherwise.
    // function _isLegacyTxDataHash(
    //     address _prevMsgSender,
    //     bytes32 _assetId,
    //     bytes memory _transferData,
    //     bytes32 _expectedTxDataHash
    // ) internal view returns (bool isLegacyTxDataHash) {
    //     try this.encodeTxDataHash(LEGACY_ENCODING_VERSION, _prevMsgSender, _assetId, _transferData) returns (
    //         bytes32 txDataHash
    //     ) {
    //         return txDataHash == _expectedTxDataHash;
    //     } catch {
    //         return false;
    //     }
    // }

    /// @dev Encodes the transaction data hash using either the latest encoding standard or the legacy standard.
    /// @param _encodingVersion EncodingVersion.
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @return txDataHash The resulting encoded transaction data hash.
    function _encodeTxDataHash(
        bytes1 _encodingVersion,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal view returns (bytes32 txDataHash) {
        if (_encodingVersion == LEGACY_ENCODING_VERSION) {
            (uint256 depositAmount, ) = abi.decode(_transferData, (uint256, address));
            txDataHash = keccak256(abi.encode(_prevMsgSender, nativeTokenVault.tokenAddress(_assetId), depositAmount));
        } else {
            // Similarly to calldata, the txDataHash is collision-resistant.
            // In the legacy data hash, the first encoded variable was the address, which is padded with zeros during `abi.encode`.
            txDataHash = keccak256(bytes.concat(_encodingVersion, abi.encode(_prevMsgSender, _assetId, _transferData)));
        }
    } // kl todo this function



    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    // /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    // function pause() external onlyOwner {
    //     _pause();
    // }

    // /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    // function unpause() external onlyOwner {
    //     _unpause();
    // }
}
