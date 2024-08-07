// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";
import {IL2SharedBridge} from "./interfaces/IL2SharedBridge.sol";
import {ILegacyL2SharedBridge} from "./interfaces/ILegacyL2SharedBridge.sol";
import {IL2AssetHandler} from "./interfaces/IL2AssetHandler.sol";
import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";
import {IL2NativeTokenVault} from "./interfaces/IL2NativeTokenVault.sol";

import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {L2ContractHelper, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS} from "../L2ContractHelper.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {EmptyAddress, InvalidCaller} from "../L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2SharedBridge is IL2SharedBridge, ILegacyL2SharedBridge, Initializable {
    /// @dev The address of the L1 shared bridge counterpart.
    address public override l1SharedBridge;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public DEPRECATED_l2TokenBeacon;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal DEPRECATED_l2TokenProxyBytecodeHash;

    /// @notice Deprecated. Kept for backwards compatibility.
    /// @dev A mapping l2 token address => l1 token address
    mapping(address _l2Token => address l1Token) public override l1TokenAddress;

    /// @notice Obsolete, as all calls are performed via L1 Shared Bridge. Kept for backwards compatibility.
    /// @dev The address of the legacy L1 erc20 bridge counterpart.
    /// This is non-zero only on Era, and should not be renamed for backward compatibility with the SDKs.
    address public override l1Bridge;

    /// @dev Chain ID of Era for legacy reasons.
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Chain ID of L1 for bridging reasons.
    uint256 public immutable L1_CHAIN_ID;

    /// @dev The contract responsible for handling tokens native to a single chain.
    IL2NativeTokenVault public nativeTokenVault;

    /// @dev A mapping of asset ID to asset handler address
    mapping(bytes32 _assetId => address assetHandlerAddress) public override assetHandlerAddress;

    /// @notice Checks that the message sender is the legacy bridge.
    modifier onlyL1Bridge() {
        // Only the L1 bridge counterpart can initiate and finalize the deposit.
        if (
            AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1Bridge &&
            AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1SharedBridge
        ) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    constructor(uint256 _eraChainId, uint256 _l1ChainId) {
        ERA_CHAIN_ID = _eraChainId;
        L1_CHAIN_ID = _l1ChainId;
        _disableInitializers();
    }

    /// @notice Initializes the bridge contract for later use. Expected to be used in the proxy.
    /// @param _l1SharedBridge The address of the L1 Bridge contract.
    /// @param _l1Bridge The address of the legacy L1 Bridge contract.
    /// @param _assetHandler The address of the nativeTokenVault contract.
    function initialize(
        address _l1SharedBridge,
        address _l1Bridge,
        IL2NativeTokenVault _assetHandler
    ) external reinitializer(3) {
        if (_l1SharedBridge == address(0)) {
            revert EmptyAddress();
        }
        if (address(_assetHandler) == address(0)) {
            revert EmptyAddress();
        }

        l1SharedBridge = _l1SharedBridge;
        nativeTokenVault = _assetHandler;
        if (block.chainid == ERA_CHAIN_ID) {
            if (_l1Bridge == address(0)) {
                revert EmptyAddress();
            }
            if (l1Bridge == address(0)) {
                l1Bridge = _l1Bridge;
            }
        }
    }

    /// @dev Used to set the assedAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(bytes32 _assetId, address _assetAddress) external onlyL1Bridge {
        assetHandlerAddress[_assetId] = _assetAddress;
        emit AssetHandlerRegistered(_assetId, _assetAddress);
    }

    /// @notice Finalize the deposit and mint funds
    /// @param _assetId The encoding of the asset on L2
    /// @param _transferData The encoded data required for deposit (address _l1Sender, uint256 _amount, address _l2Receiver, bytes memory erc20Data, address originToken)
    function finalizeDeposit(bytes32 _assetId, bytes memory _transferData) public override onlyL1Bridge {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler != address(0)) {
            IL2AssetHandler(assetHandler).bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
        } else {
            IL2AssetHandler(nativeTokenVault).bridgeMint(L1_CHAIN_ID, _assetId, _transferData);
            assetHandlerAddress[_assetId] = address(nativeTokenVault);
        }

        emit FinalizeDepositSharedBridge(L1_CHAIN_ID, _assetId, _transferData);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    function withdraw(bytes32 _assetId, bytes memory _assetData) public override {
        address assetHandler = assetHandlerAddress[_assetId];
        bytes memory _l1bridgeMintData = IL2AssetHandler(assetHandler).bridgeBurn({
            _chainId: L1_CHAIN_ID,
            _mintValue: 0,
            _assetId: _assetId,
            _prevMsgSender: msg.sender,
            _data: _assetData
        });

        bytes memory message = _getL1WithdrawMessage(_assetId, _l1bridgeMintData);
        L2ContractHelper.sendMessageToL1(message);

        emit WithdrawalInitiatedSharedBridge(L1_CHAIN_ID, msg.sender, _assetId, _assetData);
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
        return abi.encodePacked(IL1SharedBridge.finalizeWithdrawal.selector, _assetId, _l1bridgeMintData);
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
    ) external override {
        bytes32 assetId = keccak256(abi.encode(L1_CHAIN_ID, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, _l1Token));
        // solhint-disable-next-line func-named-parameters
        bytes memory data = DataEncoding.encodeBridgeMintData(_l1Sender, _l2Receiver, _l1Token, _amount, _data);
        finalizeDeposit(assetId, data);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked.
    /// @param _l1Receiver The address of token receiver on L1.
    /// @param _l2Token The address of the token transferred.
    /// @param _amount The amount of the token transferred.
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external {
        bytes32 assetId = keccak256(
            abi.encode(L1_CHAIN_ID, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, getL1TokenAddress(_l2Token))
        );
        bytes memory data = abi.encode(_amount, _l1Receiver);
        withdraw(assetId, data);
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
        return nativeTokenVault.l2TokenAddress(_l1Token);
    }
}
