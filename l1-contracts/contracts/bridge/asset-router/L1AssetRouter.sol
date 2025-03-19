// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IL2AssetRouter} from "./IL2AssetRouter.sol";
import {IAssetRouterBase, LEGACY_ENCODING_VERSION, NEW_ENCODING_VERSION, SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "./IAssetRouterBase.sol";
import {AssetRouterBase} from "./AssetRouterBase.sol";

import {IL1AssetHandler} from "../interfaces/IL1AssetHandler.sol";
import {IL1ERC20Bridge} from "../interfaces/IL1ERC20Bridge.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {IL2SharedBridgeLegacyFunctions} from "../interfaces/IL2SharedBridgeLegacyFunctions.sol";

import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {NativeTokenVaultAlreadySet} from "../L1BridgeContractErrors.sol";
import {LegacyEncodingUsedForNonL1Token, LegacyBridgeUsesNonNativeToken, NonEmptyMsgValue, UnsupportedEncodingVersion, AssetIdNotSupported, AssetHandlerDoesNotExist, Unauthorized, ZeroAddress, TokenNotSupported, TokensWithFeesNotSupported, AddressAlreadySet} from "../../common/L1ContractErrors.sol";
import {L2_ASSET_ROUTER_ADDR} from "../../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../../bridgehub/IBridgehub.sol";

import {IL1AssetDeploymentTracker} from "../interfaces/IL1AssetDeploymentTracker.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1AssetRouter is AssetRouterBase, IL1AssetRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev The assetId of the base token.
    bytes32 public immutable ETH_TOKEN_ASSET_ID;

    /// @dev The address of ZKsync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev Address of nullifier.
    IL1Nullifier public immutable L1_NULLIFIER;

    /// @dev Address of native token vault.
    INativeTokenVault public nativeTokenVault;

    /// @dev Address of legacy bridge.
    IL1ERC20Bridge public legacyBridge;

    /// @notice Checks that the message sender is the nullifier.
    modifier onlyNullifier() {
        if (msg.sender != address(L1_NULLIFIER)) {
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

    /// @notice Checks that the message sender is the native token vault.
    modifier onlyNativeTokenVault() {
        if (msg.sender != address(nativeTokenVault)) {
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
    ) reentrancyGuardInitializer AssetRouterBase(block.chainid, _eraChainId, IBridgehub(_bridgehub)) {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
        L1_NULLIFIER = IL1Nullifier(_l1Nullifier);
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
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

    /// @notice Sets the NativeTokenVault contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nativeTokenVault The address of the native token vault.
    function setNativeTokenVault(INativeTokenVault _nativeTokenVault) external onlyOwner {
        if (address(nativeTokenVault) != address(0)) {
            revert NativeTokenVaultAlreadySet();
        }
        if (address(_nativeTokenVault) == address(0)) {
            revert ZeroAddress();
        }
        nativeTokenVault = _nativeTokenVault;
        _setAssetHandler(ETH_TOKEN_ASSET_ID, address(_nativeTokenVault));
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _legacyBridge The address of the legacy bridge.
    function setL1Erc20Bridge(IL1ERC20Bridge _legacyBridge) external override onlyOwner {
        if (address(legacyBridge) != address(0)) {
            revert AddressAlreadySet(address(legacyBridge));
        }
        if (address(_legacyBridge) == address(0)) {
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
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, _assetDeploymentTracker);
        assetDeploymentTracker[assetId] = _assetDeploymentTracker;
        emit AssetDeploymentTrackerSet(assetId, _assetDeploymentTracker, _assetRegistrationData);
    }

    /// @inheritdoc IAssetRouterBase
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external override(AssetRouterBase, IAssetRouterBase) {
        _setAssetHandlerAddressThisChain(address(nativeTokenVault), _assetRegistrationData, _assetHandlerAddress);
    }

    /// @notice Used to set the asset handler address for a given asset ID on a remote ZK chain
    /// @param _chainId The ZK chain ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The encoding of asset ID.
    /// @param _assetHandlerAddressOnCounterpart The address of the asset handler, which will hold the token of interest.
    /// @return request The tx request sent to the Bridgehub
    function _setAssetHandlerAddressOnCounterpart(
        uint256 _chainId,
        address _originalCaller,
        bytes32 _assetId,
        address _assetHandlerAddressOnCounterpart
    ) internal view returns (L2TransactionRequestTwoBridgesInner memory request) {
        IL1AssetDeploymentTracker(assetDeploymentTracker[_assetId]).bridgeCheckCounterpartAddress(
            _chainId,
            _assetId,
            _originalCaller,
            _assetHandlerAddressOnCounterpart
        );

        bytes memory l2Calldata = abi.encodeCall(
            IL2AssetRouter.setAssetHandlerAddress,
            (block.chainid, _assetId, _assetHandlerAddressOnCounterpart)
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

    /// @inheritdoc IL1AssetRouter
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) public payable virtual override onlyBridgehubOrEra(_chainId) whenNotPaused {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler == address(0)) {
            revert AssetHandlerDoesNotExist(_assetId);
        }

        // slither-disable-next-line unused-return
        IAssetHandler(assetHandler).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _msgValue: 0,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _data: DataEncoding.encodeBridgeBurnData(_amount, address(0), address(0))
        });

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _originalCaller, _assetId, _amount);
    }

    /// @inheritdoc IL1AssetRouter
    function bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    )
        external
        payable
        virtual
        override
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
            if (msg.value != 0 || _value != 0) {
                revert NonEmptyMsgValue();
            }

            (bytes32 _assetId, address _assetHandlerAddressOnCounterpart) = abi.decode(_data[1:], (bytes32, address));
            return
                _setAssetHandlerAddressOnCounterpart(
                    _chainId,
                    _originalCaller,
                    _assetId,
                    _assetHandlerAddressOnCounterpart
                );
        } else if (encodingVersion == NEW_ENCODING_VERSION) {
            (assetId, transferData) = abi.decode(_data[1:], (bytes32, bytes));
        } else if (encodingVersion == LEGACY_ENCODING_VERSION) {
            (assetId, transferData) = _handleLegacyData(_data, _originalCaller);
        } else {
            revert UnsupportedEncodingVersion();
        }

        if (BRIDGE_HUB.baseTokenAssetId(_chainId) == assetId) {
            revert AssetIdNotSupported(assetId);
        }

        address ntvCached = address(nativeTokenVault);

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _nextMsgValue: _value,
            _assetId: assetId,
            _originalCaller: _originalCaller,
            _transferData: transferData,
            _passValue: true,
            _nativeTokenVault: ntvCached
        });

        bytes32 txDataHash = DataEncoding.encodeTxDataHash({
            _nativeTokenVault: ntvCached,
            _encodingVersion: encodingVersion,
            _originalCaller: _originalCaller,
            _assetId: assetId,
            _transferData: transferData
        });

        request = _requestToBridge({
            _originalCaller: _originalCaller,
            _assetId: assetId,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _originalCaller,
            assetId: assetId,
            bridgeMintCalldata: bridgeMintCalldata
        });
    }

    /// @inheritdoc IL1AssetRouter
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub whenNotPaused {
        L1_NULLIFIER.bridgehubConfirmL2TransactionForwarded(_chainId, _txDataHash, _txHash);
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRouterBase
    function finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public payable override(AssetRouterBase, IAssetRouterBase) onlyNullifier {
        _finalizeDeposit(_chainId, _assetId, _transferData, address(nativeTokenVault));
        emit DepositFinalizedAssetRouter(_chainId, _assetId, _transferData);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM FAILED DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1AssetRouter
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData
    ) external override onlyNullifier nonReentrant whenNotPaused {
        IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeRecoverFailedTransfer(
            _chainId,
            _assetId,
            _depositSender,
            _assetData
        );

        emit ClaimedFailedDepositAssetRouter(_chainId, _assetId, _assetData);
    }

    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external {
        L1_NULLIFIER.bridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _depositSender: _depositSender,
            _assetId: _assetId,
            _assetData: _assetData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /*//////////////////////////////////////////////////////////////
                     Internal & Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Decodes the transfer input for legacy data and transfers allowance to NTV.
    /// @dev Is not applicable for custom asset handlers.
    /// @param _data The encoded transfer data (address _l1Token, uint256 _depositAmount, address _l2Receiver).
    /// @return Tuple of asset ID and encoded transfer data to conform with new encoding standard.
    function _handleLegacyData(bytes calldata _data, address) internal returns (bytes32, bytes memory) {
        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        bytes32 assetId = _ensureTokenRegisteredWithNTV(_l1Token);

        // We ensure that the legacy data format can not be used for tokens that did not originate from L1.
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _l1Token);
        if (assetId != expectedAssetId) {
            revert LegacyEncodingUsedForNonL1Token();
        }

        if (assetId == ETH_TOKEN_ASSET_ID) {
            // In the old SDK/contracts the user had to always provide `0` as the deposit amount for ETH token, while
            // ultimately the provided `msg.value` was used as the deposit amount. This check is needed for backwards compatibility.

            if (_depositAmount == 0) {
                _depositAmount = msg.value;
            }
        }

        return (assetId, DataEncoding.encodeBridgeBurnData(_depositAmount, _l2Receiver, _l1Token));
    }

    /// @notice Ensures that token is registered with native token vault.
    /// @dev Only used when deposit is made with legacy data encoding format.
    /// @param _token The native token address which should be registered with native token vault.
    /// @return assetId The asset ID of the token provided.
    function _ensureTokenRegisteredWithNTV(address _token) internal override returns (bytes32 assetId) {
        assetId = nativeTokenVault.ensureTokenIsRegistered(_token);
    }

    /// @inheritdoc IL1AssetRouter
    function transferFundsToNTV(
        bytes32 _assetId,
        uint256 _amount,
        address _originalCaller
    ) external onlyNativeTokenVault returns (bool) {
        address l1TokenAddress = INativeTokenVault(address(nativeTokenVault)).tokenAddress(_assetId);
        if (l1TokenAddress == address(0) || l1TokenAddress == ETH_TOKEN_ADDRESS) {
            return false;
        }
        IERC20 l1Token = IERC20(l1TokenAddress);

        // Do the transfer if allowance to Shared bridge is bigger than amount
        // And if there is not enough allowance for the NTV
        bool weCanTransfer = false;
        if (l1Token.allowance(address(legacyBridge), address(this)) >= _amount) {
            _originalCaller = address(legacyBridge);
            weCanTransfer = true;
        } else if (
            l1Token.allowance(_originalCaller, address(this)) >= _amount &&
            l1Token.allowance(_originalCaller, address(nativeTokenVault)) < _amount
        ) {
            weCanTransfer = true;
        }
        if (weCanTransfer) {
            uint256 balanceBefore = l1Token.balanceOf(address(nativeTokenVault));
            // slither-disable-next-line arbitrary-send-erc20
            l1Token.safeTransferFrom(_originalCaller, address(nativeTokenVault), _amount);
            uint256 balanceAfter = l1Token.balanceOf(address(nativeTokenVault));

            if (balanceAfter - balanceBefore != _amount) {
                revert TokensWithFeesNotSupported();
            }
            return true;
        }
        return false;
    }

    /// @dev The request data that is passed to the bridgehub.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The deposited asset ID.
    /// @param _bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function _requestToBridge(
        address _originalCaller,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view virtual returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = getDepositCalldata(_originalCaller, _assetId, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    /// @inheritdoc IL1AssetRouter
    function getDepositCalldata(
        address _sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) public view override returns (bytes memory) {
        // First branch covers the case when asset is not registered with NTV (custom asset handler)
        // Second branch handles tokens registered with NTV and uses legacy calldata encoding
        // We need to use the legacy encoding to support the old SDK, which relies on a specific encoding of the data.
        if (
            (nativeTokenVault.tokenAddress(_assetId) == address(0)) ||
            (nativeTokenVault.originChainId(_assetId) != block.chainid)
        ) {
            return abi.encodeCall(IAssetRouterBase.finalizeDeposit, (block.chainid, _assetId, _assetData));
        } else {
            // slither-disable-next-line unused-return
            (, address _receiver, address _parsedNativeToken, uint256 _amount, bytes memory _gettersData) = DataEncoding
                .decodeBridgeMintData(_assetData);
            return
                _getLegacyNTVCalldata({
                    _sender: _sender,
                    _receiver: _receiver,
                    _parsedNativeToken: _parsedNativeToken,
                    _amount: _amount,
                    _gettersData: _gettersData
                });
        }
    }

    function _getLegacyNTVCalldata(
        address _sender,
        address _receiver,
        address _parsedNativeToken,
        uint256 _amount,
        bytes memory _gettersData
    ) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                IL2SharedBridgeLegacyFunctions.finalizeDeposit,
                (_sender, _receiver, _parsedNativeToken, _amount, _gettersData)
            );
    }

    /*//////////////////////////////////////////////////////////////
                     Legacy Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1AssetRouter
    function depositLegacyErc20Bridge(
        address _originalCaller,
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
        {
            // Note, that to keep the code simple, while avoiding "stack too deep" error,
            // this `bridgeData` variable is reused in two places with different meanings:
            // - Firstly, it denotes the bridgeBurn data to be used for the NativeTokenVault
            // - Secondly, after the call to `_burn` function, it denotes the `bridgeMint` data that
            // will be sent to the L2 counterpart of the L1NTV.
            bytes memory bridgeData = DataEncoding.encodeBridgeBurnData(_amount, _l2Receiver, _l1Token);
            // Inner call to encode data to decrease local var numbers
            _assetId = _ensureTokenRegisteredWithNTV(_l1Token);
            // Legacy bridge is only expected to use native tokens for L1.
            if (_assetId != DataEncoding.encodeNTVAssetId(block.chainid, _l1Token)) {
                revert LegacyBridgeUsesNonNativeToken();
            }

            // Note, that starting from here `bridgeData` starts denoting bridgeMintData.
            bridgeData = _burn({
                _chainId: ERA_CHAIN_ID,
                _nextMsgValue: 0,
                _assetId: _assetId,
                _originalCaller: _originalCaller,
                _transferData: bridgeData,
                _passValue: false,
                _nativeTokenVault: address(nativeTokenVault)
            });

            bytes memory l2TxCalldata = getDepositCalldata(_originalCaller, _assetId, bridgeData);

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _originalCaller);

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

        {
            bytes memory transferData = DataEncoding.encodeBridgeBurnData(_amount, _l2Receiver, _l1Token);
            // Save the deposited amount to claim funds on L1 if the deposit failed on L2
            L1_NULLIFIER.bridgehubConfirmL2TransactionForwarded(
                ERA_CHAIN_ID,
                DataEncoding.encodeTxDataHash({
                    _encodingVersion: LEGACY_ENCODING_VERSION,
                    _originalCaller: _originalCaller,
                    _assetId: _assetId,
                    _nativeTokenVault: address(nativeTokenVault),
                    _transferData: transferData
                }),
                txHash
            );
        }

        emit LegacyDepositInitiated({
            chainId: ERA_CHAIN_ID,
            l2DepositTxHash: txHash,
            from: _originalCaller,
            to: _l2Receiver,
            l1Token: _l1Token,
            amount: _amount
        });
    }

    /// @inheritdoc IL1AssetRouter
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override {
        L1_NULLIFIER.finalizeWithdrawal({
            _chainId: _chainId,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _depositSender The address of the deposit initiator.
    /// @param _l1Token The address of the deposited L1 ERC20 token.
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external {
        L1_NULLIFIER.claimFailedDeposit({
            _chainId: _chainId,
            _depositSender: _depositSender,
            _l1Token: _l1Token,
            _amount: _amount,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /// @notice Legacy read method, which forwards the call to L1Nullifier to check if withdrawal was finalized
    function isWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex
    ) external view returns (bool) {
        return L1_NULLIFIER.isWithdrawalFinalized(_chainId, _l2BatchNumber, _l2MessageIndex);
    }

    /// @notice Legacy function to get the L2 shared bridge address for a chain.
    /// @dev In case the chain has been deployed after the gateway release,
    /// the returned value is 0.
    function l2BridgeAddress(uint256 _chainId) external view override returns (address) {
        return L1_NULLIFIER.l2BridgeAddress(_chainId);
    }
}
