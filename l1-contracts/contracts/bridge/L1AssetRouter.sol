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
import {IL1Nullifier} from "./interfaces/IL1Nullifier.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";

import {AssetRouterBase} from "./AssetRouterBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1AssetRouter is AssetRouterBase, IL1AssetRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of zkSync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev Maps asset ID to the asset deployment tracker address.
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain).
    /// @dev For the asset and stores respective addresses.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /// @dev Address of nullifier.
    IL1Nullifier public nullifierStorage;

    /// @notice Checks that the message sender is the nullifier.
    modifier onlyNullifier() {
        require(msg.sender == address(nullifierStorage), "ShB not BH");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or zkSync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        require(
            msg.sender == address(BRIDGE_HUB) || (_chainId == ERA_CHAIN_ID && msg.sender == ERA_DIAMOND_PROXY),
            "L1AssetRouter: msg.sender not equal to bridgehub or era chain"
        );
        _;
    }

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

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nullifier The address of the nullifier.
    function setL1Nullifier(IL1Nullifier _nullifier) external onlyOwner {
        require(address(_nullifier) == address(0), "ShB: nullifier already set");
        require(address(_nullifier) != address(0), "ShB: nullifier 0");
        nullifierStorage = _nullifier;
    }

    /// @notice Sets the asset handler address for a given asset ID.
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @param _assetData In most cases this parameter is bytes32 encoded token address. However, it can include extra information used by custom asset handlers.
    /// @param _assetHandlerAddress The address of the asset handler, which will hold the token of interest.
    function setAssetHandlerAddress(
        bytes32 _assetData,
        address _assetHandlerAddress
    ) external override(AssetRouterBase, IAssetRouterBase) {
        address sender = msg.sender == address(nativeTokenVault) ? L2_NATIVE_TOKEN_VAULT_ADDRESS : msg.sender;
        bytes32 assetId = keccak256(abi.encode(uint256(block.chainid), sender, _assetData));
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        assetDeploymentTracker[assetId] = msg.sender;
        emit AssetHandlerRegistered(assetId, _assetHandlerAddress, _assetData, sender);
    }

    /// @notice Used to set the asset handler address for a given asset ID on a remote ZK chain
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @param _chainId The ZK chain ID.
    /// @param _mintValue The value withdrawn by base token bridge to cover for l2 gas and l2 msg.value costs.
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction.
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction.
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @param _assetId The encoding of asset ID.
    /// @param _assetAddressOnCounterPart The address of the asset handler, which will hold the token of interest.
    /// @return l2TxHash The L2 transaction hash of setting asset handler on remote chain.
    function setAssetHandlerAddressOnCounterPart(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient,
        bytes32 _assetId,
        address _assetAddressOnCounterPart
    ) external payable returns (bytes32 l2TxHash) {
        require(msg.sender == assetDeploymentTracker[_assetId] || msg.sender == owner(), "ShB: only ADT or owner");

        bytes memory l2Calldata = abi.encodeCall(
            IL2Bridge.setAssetHandlerAddress,
            (_assetId, _assetAddressOnCounterPart)
        );

        L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
            chainId: _chainId,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            mintValue: _mintValue, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
            l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
            l2Calldata: l2Calldata,
            l2GasLimit: _l2TxGasLimit,
            l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
            factoryDeps: new bytes[](0),
            refundRecipient: _refundRecipient
        });
        l2TxHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
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
        bool legacyDeposit = false;
        bytes1 encodingVersion = _data[0];

        if (encodingVersion == 0x01) {
            (assetId, transferData) = abi.decode(_data[1:], (bytes32, bytes));
        } else {
            (assetId, transferData) = _handleLegacyData(_data, _prevMsgSender);
            legacyDeposit = true;
        }

        require(BRIDGE_HUB.baseTokenAssetId(_chainId) != assetId, "ShB: baseToken deposit not supported");

        bytes memory l2BridgeMintCalldata = _burn({
            _chainId: _chainId,
            _value: _l2Value,
            _assetId: assetId,
            _prevMsgSender: _prevMsgSender,
            _transferData: transferData
        });
        bytes32 txDataHash;

        if (legacyDeposit) {
            (uint256 _depositAmount, ) = abi.decode(transferData, (uint256, address));
            txDataHash = keccak256(abi.encode(_prevMsgSender, nativeTokenVault.tokenAddress(assetId), _depositAmount));
        } else {
            txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(_prevMsgSender, assetId, transferData)));
        }

        request = _requestToBridge({
            _chainId: _chainId,
            _prevMsgSender: _prevMsgSender,
            _assetId: assetId,
            _bridgeMintCalldata: l2BridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _prevMsgSender,
            assetId: assetId,
            bridgeMintCalldata: l2BridgeMintCalldata
        });
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked.
    /// @param _chainId The chain ID of the ZK chain to which to withdraw.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _transferData The data that is passed to the asset handler contract.
    function bridgehubWithdraw(
        // ToDo: how to unify L1 and L2 withdraw? 1 is done via system contract, another one via request, so input / output is inhenerently different
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _transferData
    ) external override onlyBridgehub whenNotPaused returns (L2TransactionRequestTwoBridgesInner memory request) {
        require(BRIDGE_HUB.baseTokenAssetId(_chainId) != _assetId, "ShB: baseToken withdrawal not supported");

        bytes memory l2BridgeMintCalldata = _burn({
            _chainId: _chainId,
            _value: 0,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _transferData: _transferData
        });
        bytes32 txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(_prevMsgSender, _assetId, _transferData)));

        request = _requestToBridge({
            _chainId: _chainId,
            _prevMsgSender: _prevMsgSender,
            _assetId: _assetId,
            _bridgeMintCalldata: l2BridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubWithdrawalInitiated(_chainId, msg.sender, _assetId, keccak256(_transferData));
    }

    /// @notice Routes the confirmation to nullifier for backward compatibility.
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
        assetId = nativeTokenVault.getAssetId(_l1Token);
        if (nativeTokenVault.tokenAddress(assetId) == address(0)) {
            nativeTokenVault.registerToken(_l1Token);
        }
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The chain ID to which transfer failed.
    /// @param _depositSender The address of the deposit initiator.
    /// @param _assetId The address of the deposited L1 ERC20 token.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes memory _transferData
    ) external onlyNullifier nonReentrant whenNotPaused {
        IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeRecoverFailedTransfer(_chainId, _assetId, _transferData);

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _assetId, _transferData);
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
            IL1AssetHandler(assetHandler).bridgeMint(_chainId, _assetId, _transferData);
        } else {
            IL1AssetHandler(address(nativeTokenVault)).bridgeMint(_chainId, _assetId, _transferData); // Maybe it's better to receive amount and receiver here? transferData may have different encoding
            assetHandlerAddress[_assetId] = address(nativeTokenVault);
        }

        (amount, l1Receiver) = abi.decode(_transferData, (uint256, address));

        emit WithdrawalFinalizedAssetRouter(_chainId, l1Receiver, _assetId, amount);
    }
}
