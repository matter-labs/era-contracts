// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IL2AssetRouter} from "./interfaces/IL2AssetRouter.sol";
import {IL1AssetRouter} from "./interfaces/IL1AssetRouter.sol";
import {IL2AssetHandler} from "./interfaces/IL2AssetHandler.sol";
import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";

import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {L2ContractHelper, L2_NATIVE_TOKEN_VAULT} from "../L2ContractHelper.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {EmptyAddress, InvalidCaller, AmountMustBeGreaterThanZero} from "../L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2AssetRouter is IL2AssetRouter, Initializable {
    /// @dev Chain ID of Era for legacy reasons
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Chain ID of L1 for bridging reasons
    uint256 public immutable L1_CHAIN_ID;

    /// @dev The address of the L2 legacy shared bridge.
    address public immutable L2_LEGACY_SHARED_BRIDGE;

    /// @dev The address of the L1 asset router counterpart.
    address public override l1AssetRouter;

    /// @dev A mapping of asset ID to asset handler address
    mapping(bytes32 assetId => address assetHandlerAddress) public override assetHandlerAddress;

    /// @notice Checks that the message sender is the L1 Asset Router.
    modifier onlyL1AssetRouter() {
        // Only the L1 Asset Router counterpart can initiate and finalize the deposit.
        if (AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1AssetRouter) {
            revert InvalidCaller(msg.sender);
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
    constructor(uint256 _l1ChainId, uint256 _eraChainId, address _l1AssetRouter, address _legacySharedBridge) {
        ERA_CHAIN_ID = _eraChainId;
        L1_CHAIN_ID = _l1ChainId;
        L2_LEGACY_SHARED_BRIDGE = _legacySharedBridge;
        if (_l1AssetRouter == address(0)) {
            revert EmptyAddress();
        }

        l1AssetRouter = _l1AssetRouter;

        _disableInitializers();
    }

    /// @dev Used to set the assedAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(bytes32 _assetId, address _assetAddress) external onlyL1AssetRouter {
        assetHandlerAddress[_assetId] = _assetAddress;
        emit AssetHandlerRegistered(_assetId, _assetAddress);
    }

    /// @notice Finalize the deposit and mint funds
    /// @param _assetId The encoding of the asset on L2
    /// @param _transferData The encoded data required for deposit (address _l1Sender, uint256 _amount, address _l2Receiver, bytes memory erc20Data, address originToken)
    function finalizeDeposit(bytes32 _assetId, bytes memory _transferData) public override onlyL1AssetRouter {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler != address(0)) {
            IL2AssetHandler(assetHandler).bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
        } else {
            L2_NATIVE_TOKEN_VAULT.bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
            assetHandlerAddress[_assetId] = address(L2_NATIVE_TOKEN_VAULT);
        }

        emit FinalizeDepositSharedBridge(L1_CHAIN_ID, _assetId, _transferData);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    function withdraw(bytes32 _assetId, bytes memory _assetData) public override {
        _withdrawSender(_assetId, _assetData, msg.sender);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    /// @param _sender The address of the sender of the message
    function _withdrawSender(bytes32 _assetId, bytes memory _assetData, address _sender) internal {
        address assetHandler = assetHandlerAddress[_assetId];
        bytes memory _l1bridgeMintData = IL2AssetHandler(assetHandler).bridgeBurn({
            _chainId: L1_CHAIN_ID,
            _mintValue: 0,
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
    ) external {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        // solhint-disable-next-line func-named-parameters
        bytes memory data = DataEncoding.encodeBridgeMintData(_l1Sender, _l2Receiver, _l1Token, _amount, _data);
        finalizeDeposit(assetId, data);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @dev A compatibilty method to support legacy functionality for the SDK.
    /// @param _l1Receiver The account address that should receive funds on L1
    /// @param _l2Token The L2 token address which is withdrawn
    /// @param _amount The total amount of tokens to be withdrawn
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external {
        if (_amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        _withdrawLegacy(_l1Receiver, _l2Token, _amount, msg.sender);
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

    /// @notice Legacy getL1TokenAddress.
    /// @param _l2Token The address of token on L2.
    /// @return The address of token on L1.
    function getL1TokenAddress(address _l2Token) public view returns (address) {
        return IL2StandardToken(_l2Token).l1Address();
    }

    /// @notice Legacy function used for backward compatibility to return L2 wrapped token
    /// @notice address corresponding to provided L1 token address and deployed through NTV.
    /// @dev However, the shared bridge can use custom asset handlers such that L2 addresses differ,
    /// @dev or an L1 token may not have an L2 counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return Address of an L2 token counterpart
    function l2TokenAddress(address _l1Token) public view returns (address) {
        address currentlyDeployedAddress = L2_NATIVE_TOKEN_VAULT.l2TokenAddress(_l1Token);

        if (currentlyDeployedAddress != address(0)) {
            return currentlyDeployedAddress;
        }

        // For backwards compatibility, the bridge smust return the address of the token even if it
        // has not been deployed yet.
        return L2_NATIVE_TOKEN_VAULT.calculateCreate2TokenAddress(_l1Token);
    }

    /*//////////////////////////////////////////////////////////////
                            Legacy functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the L1 asset router.
    /// @dev The old name is kept for backward compatibility.
    function l1Bridge() external view override returns (address) {
        return l1AssetRouter;
    }
}
