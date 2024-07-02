// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IL2AssetRouter} from "./interfaces/IL2AssetRouter.sol";
import {IL1AssetRouter} from "./interfaces/IL1AssetRouter.sol";
import {ILegacyL2SharedBridge} from "./interfaces/ILegacyL2SharedBridge.sol";
import {IL2AssetHandler} from "./interfaces/IL2AssetHandler.sol";
import {ILegacyL2SharedBridge} from "./interfaces/ILegacyL2SharedBridge.sol";
import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";

import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {L2ContractHelper, L2_NATIVE_TOKEN_VAULT} from "../L2ContractHelper.sol";

import {EmptyAddress, InvalidCaller} from "../L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2AssetRouter is IL2AssetRouter, ILegacyL2SharedBridge, Initializable {
    /// @dev Chain ID of Era for legacy reasons
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Chain ID of L1 for bridging reasons
    uint256 public immutable L1_CHAIN_ID;

    /// @dev The address of the L1 shared bridge counterpart.
    address public override l1SharedBridge;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public DEPRECATED_l2TokenBeacon;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal DEPRECATED_l2TokenProxyBytecodeHash;

    /// @dev A mapping l2 token address => l1 token address.
    mapping(address l2TokenAddress => address l1TokenAddress) public override l1TokenAddress;

    /// @dev The address of the legacy L1 erc20 bridge counterpart.
    /// This is non-zero only on Era, and should not be renamed for backward compatibility with the SDKs.
    address public override l1Bridge;

    /// @dev A mapping l2 token address => l1 token address.
    mapping(bytes32 assetId => address assetHandlerAddress) public override assetHandlerAddress;

    /// @notice Checks that the message sender is the legacy bridge.
    modifier onlyL1BridgeOrNTV() {
        // Only the L1 bridge counterpart can initiate and finalize the deposit.
        if (
            msg.sender == L2_NATIVE_TOKEN_VAULT ||
            (AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1Bridge &&
                AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1SharedBridge)
        ) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        require(msg.sender == address(L2_BRIDGEHUB_ADDRESS), "NTV not BH");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    /// @param _l1SharedBridge The address of the L1 Bridge contract.
    /// @param _l1Bridge The address of the legacy L1 Bridge contract.
    constructor(uint256 _eraChainId, uint256 _l1ChainId, address _l1SharedBridge, address _l1Bridge) {
        ERA_CHAIN_ID = _eraChainId;
        L1_CHAIN_ID = _l1ChainId;
        if (_l1SharedBridge == address(0)) {
            revert EmptyAddress();
        }

        l1SharedBridge = _l1SharedBridge;
        if (block.chainid == ERA_CHAIN_ID) {
            if (_l1Bridge == address(0)) {
                revert EmptyAddress();
            }
            if (l1Bridge == address(0)) {
                l1Bridge = _l1Bridge;
            }
        }
        _disableInitializers();
    }

    /// @notice Finalizes the deposit / withdrawal and mint funds.
    /// @param _assetId The encoding of the asset on L2.
    /// @param _transferData The encoded data required for deposit (address _l1Sender, uint256 _amount, address _l2Receiver, bytes memory erc20Data, address originToken).
    function finalizeTransfer(bytes32 _assetId, bytes memory _transferData) public override onlyL1Bridge {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler != address(0)) {
            IL2AssetHandler(assetHandler).bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
        } else {
            L2_NATIVE_TOKEN_VAULT.bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
            assetHandlerAddress[_assetId] = address(L2_NATIVE_TOKEN_VAULT);
        }

        emit FinalizeTransferSharedBridge(L1_CHAIN_ID, _assetId, keccak256(_transferData));
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _transferData The data that is passed to the asset handler contract.
    function withdraw(bytes32 _assetId, bytes memory _transferData) public override {
        address assetHandler = assetHandlerAddress[_assetId];
        bytes memory _l1bridgeMintData = IL2AssetHandler(assetHandler).bridgeBurn({
            _chainId: L1_CHAIN_ID,
            _mintValue: 0,
            _assetId: _assetId,
            _prevMsgSender: msg.sender,
            _transferData: _transferData
        });

        bytes memory message = _getL1WithdrawMessage(_assetId, _l1bridgeMintData);
        L2ContractHelper.sendMessageToL1(message);

        emit WithdrawalInitiatedSharedBridge(L1_CHAIN_ID, msg.sender, _assetId, _transferData);
    }

    /// @notice Initiates a deposit by locking funds on the contract and sending the message to L1
    /// where tokens would be minted.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _transferData The data that is passed to the asset handler contract.
    function deposit(bytes32 _assetId, bytes memory _transferData) public override {
        address assetHandler = assetHandlerAddress[_assetId];
        bytes memory _l1bridgeMintData = IL2AssetHandler(assetHandler).bridgeBurn({
            _chainId: L1_CHAIN_ID,
            _mintValue: 0,
            _assetId: _assetId,
            _prevMsgSender: msg.sender,
            _transferData: _transferData
        });

        bytes memory message = _getL1DepositMessage(_assetId, _l1bridgeMintData);
        L2ContractHelper.sendMessageToL1(message);

        emit DepositInitiatedSharedBridge(L1_CHAIN_ID, msg.sender, _assetId, _transferData);
    }

    /// @notice Encodes the message for l2ToL1log sent during withdraw initialization.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _l1bridgeMintData The calldata used by l1 asset handler to unlock tokens for recipient.
    function _getL1WithdrawMessage(
        bytes32 _assetId,
        bytes memory _l1bridgeMintData
    ) internal pure returns (bytes memory) {
        // note we use the IL1AssetRouter.finalizeWithdrawal function selector to specify the selector for L1<>L2 messages,
        // and we use this interface so that when the switch happened the old messages could be processed
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IL1AssetRouter.finalizeWithdrawal.selector, _assetId, _l1bridgeMintData);
    }

    /// @notice Encodes the message for l2ToL1log sent during deposit initialization.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _l1bridgeMintData The calldata used by l1 asset handler to unlock tokens for recipient.
    function _getL1DepositMessage(
        bytes32 _assetId,
        bytes memory _l1bridgeMintData
    ) internal pure returns (bytes memory) {
        // note we use the IL1AssetRouter.finalizeDeposit function selector to specify the selector for L1<>L2 messages,
        // and we use this interface so that when the switch happened the old messages could be processed
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IL1AssetRouter.finalizeDeposit.selector, _assetId, _l1bridgeMintData);
    }

    /// @notice Sets the asset handler address for a given assetId.
    /// @dev Will be called by ZK Gateway or NTV.
    /// @param _assetData The encoding of the asset on L2.
    /// @param _assetHandlerAddress The address of the asset handler, which will hold the token of interest.
    function setAssetHandlerAddress(bytes32 _assetData, address _assetHandlerAddress) external onlyL1BridgeOrNTV {
        if (msg.sender == L2_NATIVE_TOKEN_VAULT) {
            bytes32 assetId = keccak256(abi.encode(uint256(block.chainid), L2_NATIVE_TOKEN_VAULT, _assetData));
            assetHandlerAddress[assetId] = _assetHandlerAddress;
        } else {
            assetHandlerAddress[_assetId] = _assetHandlerAddress;
        }
        emit AssetHandlerRegistered(_assetId, _assetHandlerAddress);
    }

    /*//////////////////////////////////////////////////////////////
                            LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalizes the deposit and mint funds.
    /// @param _l1Sender The address of token sender on L1.
    /// @param _l2Receiver The address of token receiver on L2.
    /// @param _l1Token The address of the token transferred.
    /// @param _amount The amount of the token transferred.
    /// @param erc20Data The ERC20 metadata of the token transferred.
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata erc20Data
    ) external override {
        // onlyBridge {
        bytes32 assetId = keccak256(abi.encode(L1_CHAIN_ID, address(L2_NATIVE_TOKEN_VAULT), _l1Token));
        // solhint-disable-next-line func-named-parameters
        bytes memory data = abi.encode(_l1Sender, _amount, _l2Receiver, erc20Data, _l1Token);
        finalizeDeposit(assetId, data);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked.
    /// @param _l1Receiver The address of token receiver on L1.
    /// @param _l2Token The address of the token transferred.
    /// @param _amount The amount of the token transferred.
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external {
        bytes32 assetId = keccak256(
            abi.encode(L1_CHAIN_ID, address(L2_NATIVE_TOKEN_VAULT), getL1TokenAddress(_l2Token))
        );
        bytes memory data = abi.encode(_amount, _l1Receiver);
        withdraw(assetId, data);
    }

    /// @notice Retrieves L1 address corresponding to L2 wrapped token.
    /// @param _l2Token The address of token on L2.
    /// @return The address of token on L1.
    function getL1TokenAddress(address _l2Token) public view returns (address) {
        return IL2StandardToken(_l2Token).l1Address();
    }

    /// @notice Retrieves L2 wrapped token address corresponding to L1 token counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return The address of token on L2.
    function l2TokenAddress(address _l1Token) public view returns (address) {
        return L2_NATIVE_TOKEN_VAULT.l2TokenAddress(_l1Token);
    }
}
