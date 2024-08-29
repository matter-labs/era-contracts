// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";

import {IL2AssetRouter} from "./IL2AssetRouter.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";
// import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {AssetRouterBase} from "./AssetRouterBase.sol";

import {IL2NativeTokenVault, INativeTokenVault} from "../ntv/IL2NativeTokenVault.sol";

import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
// import {IL2SharedBridgeLegacyFunctions} from "../interfaces/IL2SharedBridgeLegacyFunctions.sol";
import {IBridgedStandardToken} from "../interfaces/IBridgedStandardToken.sol";

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";

import {L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_BRIDGEHUB_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../../common/L2ContractAddresses.sol";
import {L2ContractHelper} from "../../common/libraries/L2ContractHelper.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {EmptyAddress, InvalidCaller, AmountMustBeGreaterThanZero} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2AssetRouter is AssetRouterBase, IL2AssetRouter {
    /// @dev The address of the L2 legacy shared bridge.
    address public immutable L2_LEGACY_SHARED_BRIDGE;

    /// @dev The address of the L1 asset router counterpart.
    address public override l1AssetRouter;

    /// @dev A mapping of asset ID to asset handler address
    // mapping(bytes32 assetId => address assetHandlerAddress) public override assetHandlerAddress;

    /// @notice Checks that the message sender is the L1 Asset Router.
    modifier onlyAssetRouterCounterpart(uint256 _originChainId) {
        if (_originChainId == L1_CHAIN_ID) {
            // Only the L1 Asset Router counterpart can initiate and finalize the deposit.
            if (AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1AssetRouter) {
                revert InvalidCaller(msg.sender);
            }
        } else {
            revert InvalidCaller(msg.sender); // xL2 messaging not supported for now
        }
        _;
    }

    /// @notice Checks that the message sender is the legacy L2 bridge.
    modifier onlyLegacyBridge() {
        if (msg.sender != L2_LEGACY_SHARED_BRIDGE) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @dev Disable the initialization to prevent Parity hack.
    /// @param _l1AssetRouter The address of the L1 Bridge contract.
    constructor(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _l1AssetRouter,
        address _legacySharedBridge
    ) AssetRouterBase(_l1ChainId, _eraChainId, IBridgehub(L2_BRIDGEHUB_ADDR), L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR) {
        L2_LEGACY_SHARED_BRIDGE = _legacySharedBridge;
        if (_l1AssetRouter == address(0)) {
            revert EmptyAddress();
        }
        nativeTokenVault = INativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDRESS);
        l1AssetRouter = _l1AssetRouter;

        _disableInitializers();
    }

    ///  @inheritdoc IL2AssetRouter
    function setAssetHandlerAddress(
        uint256 _originChainId,
        bytes32 _assetId,
        address _assetAddress
    ) external onlyAssetRouterCounterpart(_originChainId) {
        _setAssetHandlerAddress(_assetId, _assetAddress);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIATTE DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalize the deposit and mint funds
    /// @param _assetId The encoding of the asset on L2
    /// @param _transferData The encoded data required for deposit (address _l1Sender, uint256 _amount, address _l2Receiver, bytes memory erc20Data, address originToken)
    function finalizeDeposit(
        bytes32 _assetId,
        bytes memory _transferData
    ) public override onlyAssetRouterCounterpart(L1_CHAIN_ID) {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler != address(0)) {
            IAssetHandler(assetHandler).bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
        } else {
            IAssetHandler(L2_NATIVE_TOKEN_VAULT_ADDRESS).bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
            assetHandlerAddress[_assetId] = L2_NATIVE_TOKEN_VAULT_ADDRESS;
        }

        emit FinalizeDepositSharedBridge(L1_CHAIN_ID, _assetId, _transferData);
    }

    /*//////////////////////////////////////////////////////////////
                            LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy finalizeDeposit.
    /// @dev Finalizes the deposit and mint funds.
    /// @param _l1Sender The address of token sender on L1.
    /// @param _l2Receiver The address of token receiver on L2.
    /// @param _l1Token The address of the token transferred.
    /// @param _amount The amount of the token transferred.
    /// @param _data The metadata of the token transferred.
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external onlyAssetRouterCounterpart(L1_CHAIN_ID) {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        // solhint-disable-next-line func-named-parameters
        bytes memory data = DataEncoding.encodeBridgeMintData(_l1Sender, _l2Receiver, _l1Token, _amount, _data);
        finalizeDeposit(assetId, data);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @dev A compatibility method to support legacy functionality for the SDK.
    /// @param _l1Receiver The account address that should receive funds on L1
    /// @param _l2Token The L2 token address which is withdrawn
    /// @param _amount The total amount of tokens to be withdrawn
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external {
        if (_amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        _withdrawLegacy(_l1Receiver, _l2Token, _amount, msg.sender);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    function withdraw(bytes32 _assetId, bytes memory _assetData) public override {
        _withdrawSender(_assetId, _assetData, msg.sender);
    }

    /// @notice Legacy withdraw.
    /// @dev Finalizes the deposit and mint funds.
    /// @param _l1Receiver The address of token receiver on L1.
    /// @param _l2Token The address of token on L2.
    /// @param _amount The amount of the token transferred.
    /// @param _sender The original msg.sender.
    function withdrawLegacyBridge(
        address _l1Receiver,
        address _l2Token,
        uint256 _amount,
        address _sender
    ) external onlyLegacyBridge {
        _withdrawLegacy(_l1Receiver, _l2Token, _amount, _sender);
    }

    function _withdrawLegacy(address _l1Receiver, address _l2Token, uint256 _amount, address _sender) internal {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, getL1TokenAddress(_l2Token));
        bytes memory data = abi.encode(_amount, _l1Receiver);
        _withdrawSender(assetId, data, _sender);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    /// @param _sender The address of the sender of the message
    function _withdrawSender(bytes32 _assetId, bytes memory _assetData, address _sender) internal {
        address assetHandler = assetHandlerAddress[_assetId];
        bytes memory _l1bridgeMintData = IAssetHandler(assetHandler).bridgeBurn({
            _chainId: L1_CHAIN_ID,
            _msgValue: 0,
            _assetId: _assetId,
            _prevMsgSender: _sender,
            _data: _assetData
        });

        bytes memory message = _getL1WithdrawMessage(_assetId, _l1bridgeMintData);
        L2ContractHelper.sendMessageToL1(message);

        emit WithdrawalInitiatedSharedBridge(L1_CHAIN_ID, _sender, _assetId, _assetData);
    }

    /// @notice Encodes the message for l2ToL1log sent during withdraw initialization.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _l1bridgeMintData The calldata used by l1 asset handler to unlock tokens for recipient.
    function _getL1WithdrawMessage(
        bytes32 _assetId,
        bytes memory _l1bridgeMintData
    ) internal pure returns (bytes memory) {
        // note we use the IL1SharedBridge.finalizeWithdrawal function selector to specify the selector for L1<>L2 messages,
        // and we use this interface so that when the switch happened the old messages could be processed
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IL1AssetRouter.finalizeWithdrawal.selector, _assetId, _l1bridgeMintData);
    }

    /// @notice Legacy getL1TokenAddress.
    /// @param _l2Token The address of token on L2.
    /// @return The address of token on L1.
    function getL1TokenAddress(address _l2Token) public view returns (address) {
        return IBridgedStandardToken(_l2Token).l1Address();
    }

    /// @notice Legacy function used for backward compatibility to return L2 wrapped token
    /// @notice address corresponding to provided L1 token address and deployed through NTV.
    /// @dev However, the shared bridge can use custom asset handlers such that L2 addresses differ,
    /// @dev or an L1 token may not have an L2 counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return Address of an L2 token counterpart
    function l2TokenAddress(address _l1Token) public view returns (address) {
        IL2NativeTokenVault l2NativeTokenVault = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDRESS);
        address currentlyDeployedAddress = l2NativeTokenVault.l2TokenAddress(_l1Token);

        if (currentlyDeployedAddress != address(0)) {
            return currentlyDeployedAddress;
        }

        // For backwards compatibility, the bridge smust return the address of the token even if it
        // has not been deployed yet.
        return INativeTokenVault(address(l2NativeTokenVault)).calculateCreate2TokenAddress(L1_CHAIN_ID, _l1Token);
    }

    /// @notice Returns the address of the L1 asset router.
    /// @dev The old name is kept for backward compatibility.
    function l1Bridge() external view returns (address) {
        return l1AssetRouter;
    }
}
