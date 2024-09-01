// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

// import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
// import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {AssetRouterBase} from "./AssetRouterBase.sol";

import {IL2Bridge} from "../interfaces/IL2Bridge.sol";
// import {IL2BridgeLegacy} from "./interfaces/IL2BridgeLegacy.sol";
import {IL1AssetHandler} from "../interfaces/IL1AssetHandler.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
// import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
// import {IL1SharedBridgeLegacy} from "./interfaces/IL1SharedBridgeLegacy.sol";
import {IL2SharedBridgeLegacyFunctions} from "../interfaces/IL2SharedBridgeLegacyFunctions.sol";

import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
// import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/L2ContractAddresses.sol";
import {Unauthorized, ZeroAddress, TokenNotSupported, AddressAlreadyUsed} from "../../common/L1ContractErrors.sol";
import {L2_ASSET_ROUTER_ADDR} from "../../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../../bridgehub/IBridgehub.sol";

// import {BridgeHelper} from "./BridgeHelper.sol";

import {IL1AssetDeploymentTracker} from "../interfaces/IL1AssetDeploymentTracker.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1AssetRouter is
    AssetRouterBase,
    IL1AssetRouter, // IL1SharedBridgeLegacy,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev The address of ZKsync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev Address of nullifier.
    IL1Nullifier public immutable L1_NULLIFIER;

    /// @dev Address of legacy bridge.
    address public legacyBridge;

    /// @notice Checks that the message sender is the nullifier.
    modifier onlyNullifier() {
        if (msg.sender != address(L1_NULLIFIER)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyNullifierWithSender(address _expectedSender, address _prevMsgSender) {
        if (msg.sender != address(L1_NULLIFIER) || _expectedSender != _prevMsgSender) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or ZKsync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        if (msg.sender != address(BRIDGE_HUB) && (_chainId != ERA_CHAIN_ID || msg.sender != ERA_DIAMOND_PROXY)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the legacy bridge.
    modifier onlyLegacyBridge() {
        if (msg.sender != address(legacyBridge)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _l1WethAddress,
        address _bridgehub,
        address _l1Nullifier,
        uint256 _eraChainId,
        address _eraDiamondProxy
    )
        reentrancyGuardInitializer
        AssetRouterBase(block.chainid, _eraChainId, IBridgehub(_bridgehub), ETH_TOKEN_ADDRESS)
    {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
        L1_NULLIFIER = IL1Nullifier(_l1Nullifier);
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy.
    /// @dev Used for testing purposes only, as the contract has been initialized on mainnet.
    /// @param _owner The address which can change L2 token implementation and upgrade the bridge implementation.
    /// The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_owner);
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nativeTokenVault The address of the native token vault.
    function setNativeTokenVault(INativeTokenVault _nativeTokenVault) external onlyOwner {
        require(address(nativeTokenVault) == address(0), "AR: native token v already set");
        require(address(_nativeTokenVault) != address(0), "AR: native token vault 0");
        nativeTokenVault = _nativeTokenVault;
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _legacyBridge The address of the legacy bridge.
    function setL1Erc20Bridge(address _legacyBridge) external onlyOwner {
        if (address(legacyBridge) != address(0)) {
            revert AddressAlreadyUsed(address(legacyBridge));
        }
        if (_legacyBridge == address(0)) {
            revert ZeroAddress();
        }
        legacyBridge = _legacyBridge;
    }

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

    ///  @inheritdoc IL1AssetRouter
    function setAssetHandlerAddress(
        address _prevMsgSender,
        bytes32 _assetId,
        address _assetAddress
    ) external onlyNullifierWithSender(L2_ASSET_ROUTER_ADDR, _prevMsgSender) {
        _setAssetHandlerAddress(_assetId, _assetAddress);
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
    ) internal view override returns (L2TransactionRequestTwoBridgesInner memory request) {
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

    /*//////////////////////////////////////////////////////////////
                            INITIATTE DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRouterBase
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) public payable virtual override onlyBridgehubOrEra(_chainId) whenNotPaused {
        _bridgehubDepositBaseToken(_chainId, _assetId, _prevMsgSender, _amount);
    }

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
    ) external override(AssetRouterBase) onlyBridgehub whenNotPaused {
        L1_NULLIFIER.bridgehubConfirmL2TransactionForwarded(_chainId, _txDataHash, _txHash);
    }

    function _getLegacyNTVCalldata(
        address _sender,
        address _receiver,
        address _parsedNativeToken,
        uint256 _amount,
        bytes memory _gettersData
    ) internal view virtual override returns (bytes memory) {
        return
            abi.encodeCall(
                IL2SharedBridgeLegacyFunctions.finalizeDeposit,
                (_sender, _receiver, _parsedNativeToken, _amount, _gettersData)
            );
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    function finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public override onlyNullifier returns (address l1Receiver, uint256 amount) {
        (l1Receiver, amount) = super.finalizeDeposit(_chainId, _assetId, _transferData);
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

    /*//////////////////////////////////////////////////////////////
                            CLAIM FAILED DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The ZK chain id to which the deposit was initiated.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver. Might include extra information.
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
        bytes calldata _assetData
    ) external onlyNullifier nonReentrant whenNotPaused {
        IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeRecoverFailedTransfer(
            _chainId,
            _assetId,
            _depositSender,
            _assetData
        );

        emit ClaimedFailedDepositAssetRouter(_chainId, _assetId, _assetData);
    }
    /*//////////////////////////////////////////////////////////////
                     Internal & Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Decodes the transfer input for legacy data and transfers allowance to NTV.
    /// @dev Is not applicable for custom asset handlers.
    /// @param _data The encoded transfer data (address _l1Token, uint256 _depositAmount, address _l2Receiver).
    // / @param _prevMsgSender The address of the deposit initiator.
    /// @return Tuple of asset ID and encoded transfer data to conform with new encoding standard.
    function _handleLegacyData(bytes calldata _data, address) internal override returns (bytes32, bytes memory) {
        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        bytes32 assetId = _ensureTokenRegisteredWithNTV(_l1Token);
        // L1_NULLIFIER.transferAllowanceToNTV(assetId, _depositAmount, _prevMsgSender);
        return (assetId, abi.encode(_depositAmount, _l2Receiver));
    }

    /// @notice Ensures that token is registered with native token vault.
    /// @dev Only used when deposit is made with legacy data encoding format.
    /// @param _token The L1 token address which should be registered with native token vault.
    /// @return assetId The asset ID of the token provided.
    function _ensureTokenRegisteredWithNTV(address _token) internal returns (bytes32 assetId) {
        assetId = nativeTokenVault.getAssetId(block.chainid, _token);
        if (nativeTokenVault.tokenAddress(assetId) == address(0)) {
            nativeTokenVault.registerToken(_token);
        }
    }

    /*//////////////////////////////////////////////////////////////
                     Legacy Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted.
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Receiver The account address that should receive funds on L2.
    /// @param _l1Token The L1 token address which is deposited.
    /// @param _amount The total amount of tokens to be bridged.
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction.
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction.
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses
    /// out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will
    /// be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be
    /// sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds
    /// are controllable through the Mailbox, since the Mailbox applies address aliasing to the from address for the
    /// L2 tx if the L1 msg.sender is a contract. Without address aliasing for L1 contracts as refund recipients they
    /// would not be able to make proper L2 tx requests through the Mailbox to use or withdraw the funds from L2, and
    /// the funds would be lost.
    /// @return txHash The L2 transaction hash of deposit finalization.
    function depositLegacyErc20Bridge(
        address _prevMsgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable override onlyLegacyBridge nonReentrant whenNotPaused returns (bytes32 txHash) {
        if (_l1Token == L1_WETH_TOKEN) {
            revert TokenNotSupported(L1_WETH_TOKEN);
        }

        bytes32 _assetId;
        bytes memory bridgeMintCalldata;

        {
            // Inner call to encode data to decrease local var numbers
            _assetId = _ensureTokenRegisteredWithNTV(_l1Token);
            IERC20(_l1Token).forceApprove(address(nativeTokenVault), _amount);

            // solhint-disable-next-line func-named-parameters
            // bridgeMintCalldata = abi.encode(_amount, _prevMsgSender, _l2Receiver, getERC20Getters(_l1Token), _l1Token); // kl todo check correct
            bridgeMintCalldata = DataEncoding.encodeBridgeMintData({
                _prevMsgSender: _prevMsgSender,
                _l2Receiver: _l2Receiver,
                _l1Token: _l1Token,
                _amount: _amount,
                _erc20Metadata: nativeTokenVault.getERC20Getters(_l1Token)
            }); // kl todo don't we care about backwards compatibility here?
            // bridgeMintCalldata = _burn({
            //     _chainId: ERA_CHAIN_ID,
            //     _l2Value: 0,
            //     _assetId: _assetId,
            //     _prevMsgSender: _prevMsgSender,
            //     _transferData: abi.encode(_amount, _l2Receiver),
            //     _passValue: false
            // });
        }

        {
            bytes memory l2TxCalldata = getDepositCalldata(ERA_CHAIN_ID, _prevMsgSender, _assetId, bridgeMintCalldata);

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _prevMsgSender);

            L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
                chainId: ERA_CHAIN_ID,
                l2Contract: L2_ASSET_ROUTER_ADDR,
                mintValue: msg.value, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
                l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
                l2Calldata: l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: refundRecipient
            });
            txHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
        }

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        L1_NULLIFIER.bridgehubConfirmL2TransactionForwarded(
            ERA_CHAIN_ID,
            keccak256(abi.encode(_prevMsgSender, _l1Token, _amount)),
            txHash
        );

        emit LegacyDepositInitiated({
            chainId: ERA_CHAIN_ID,
            l2DepositTxHash: txHash,
            from: _prevMsgSender,
            to: _l2Receiver,
            l1Asset: _l1Token,
            amount: _amount
        });
    }
}
