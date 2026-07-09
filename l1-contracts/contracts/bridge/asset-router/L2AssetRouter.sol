// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2AssetRouter} from "./IL2AssetRouter.sol";
import {IL2CrossChainSender} from "../interfaces/IL2CrossChainSender.sol";
import {AssetRouterBase} from "./AssetRouterBase.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IL2NativeTokenVault} from "../ntv/IL2NativeTokenVault.sol";

import {IL2Bridgehub} from "../../core/bridgehub/IL2Bridgehub.sol";

import {IBridgehubBase, L2TransactionRequestTwoBridgesInner} from "../../core/bridgehub/IBridgehubBase.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";

import {InteropCallStarter} from "../../common/Messaging.sol";
import {IAtomicRecoverable} from "../../atomic-interop/IAtomicRecoverable.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "../../common/l2-helpers/L2ContractHelper.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {
    AssetIdNotSupported,
    EmptyAddress,
    ExecuteMessageFailed,
    InvalidSelector,
    PayloadTooShort,
    Unauthorized
} from "../../common/L1ContractErrors.sol";
import {IERC7786Recipient} from "../../interop/IERC7786Recipient.sol";
import {IERC7786Attributes} from "../../interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2AssetRouter is AssetRouterBase, IL2AssetRouter, ReentrancyGuard, IERC7786Recipient, IAtomicRecoverable {
    /// @dev Deprecated: previously stored the L2 Bridgehub. Now the address is resolved via
    /// `_bridgehub()` → `L2_BRIDGEHUB_ADDR` constant. Kept as an empty slot to preserve storage layout.
    IL2Bridgehub private __DEPRECATED_BRIDGE_HUB;

    /// @dev Chain ID of L1 for bridging reasons.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public L1_CHAIN_ID;

    /// @dev Chain ID of Era for legacy reasons.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public ERA_CHAIN_ID;

    /// @dev The address of the L1 asset router counterpart.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    IL1AssetRouter public L1_ASSET_ROUTER;

    /// @dev Deprecated slot, retained to preserve the upgradeable storage layout.
    /// Formerly `L2_LEGACY_SHARED_BRIDGE` (the L2 legacy shared bridge). No longer read or written.
    // slither-disable-next-line uninitialized-state
    address private __DEPRECATED_L2_LEGACY_SHARED_BRIDGE;

    /// @dev The asset id of the base token.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @notice Returns the bridgehub contract.
    function _bridgehub() internal view virtual override returns (IBridgehubBase) {
        return IBridgehubBase(L2_BRIDGEHUB_ADDR);
    }

    /// @notice Returns the native token vault address. Virtual for private interop override.
    function _nativeTokenVaultAddr() internal view virtual returns (address) {
        return L2_NATIVE_TOKEN_VAULT_ADDR;
    }

    /// @notice Returns the interop center address. Virtual for private interop override.
    function _interopCenterAddr() internal view virtual returns (address) {
        return L2_INTEROP_CENTER_ADDR;
    }

    /// @notice Returns the interop handler address. Virtual for private interop override.
    function _interopHandlerAddr() internal view virtual returns (address) {
        return L2_INTEROP_HANDLER_ADDR;
    }

    /// @notice Returns the canonical atomic-flow manager address — the contract whitelisted to call
    /// `recoverAtomicCall` (the IMT atomic flow's timeout recovery path). It is a genesis-deployed
    /// built-in at a fixed address, like the interop center / handler above; chains without the
    /// atomic-flow stack simply have nothing deployed there, so the auth gate never passes. Virtual
    /// for private interop override.
    function _atomicFlowManagerAddr() internal view virtual returns (address) {
        return L2_ATOMIC_FLOW_MANAGER_ADDR;
    }

    /// @notice Validates that an interop message sender is an authorized AssetRouter counterpart.
    /// @dev By default, only accepts messages from the same address (all system AssetRouters share one address).
    function _validateAssetRouterCounterpart(uint256 _senderChainId, address _senderAddress) internal view virtual {
        require((_senderChainId != L1_CHAIN_ID && _senderAddress == address(this)), Unauthorized(_senderAddress));
    }

    /// @notice Checks that the message sender is the L1 Asset Router.
    modifier onlyAssetRouterCounterpart(uint256 _originChainId) {
        if (_originChainId == L1_CHAIN_ID) {
            // For messages originating on L1, only the L1 Asset Router counterpart may call this function.
            require(
                AddressAliasHelper.undoL1ToL2Alias(msg.sender) == address(L1_ASSET_ROUTER),
                Unauthorized(msg.sender)
            );
        } else {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the L1 Asset Router or this contract itself.
    modifier onlyAssetRouterCounterpartOrSelf(uint256 _chainId) {
        if (_chainId == L1_CHAIN_ID) {
            if (
                (AddressAliasHelper.undoL1ToL2Alias(msg.sender) != address(L1_ASSET_ROUTER)) &&
                msg.sender != address(this)
            ) {
                revert Unauthorized(msg.sender);
            }
        } else {
            if (msg.sender != address(this)) {
                revert Unauthorized(msg.sender);
            }
        }
        _;
    }

    modifier onlyNTV() {
        require(msg.sender == _nativeTokenVaultAddr(), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the message sender is the interop center.
    modifier onlyL2InteropCenter() {
        require(msg.sender == _interopCenterAddr(), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the message sender is the canonical atomic-flow manager, which drives
    /// `recoverAtomicCall` for the L1-free atomic interop flow's timeout path. On chains without the
    /// atomic-flow stack nothing is deployed at that address, so this gate naturally never passes.
    modifier onlyAtomicFlowManager() {
        require(msg.sender == _atomicFlowManagerAddr(), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the message sender is the interop handler.
    modifier onlyL2InteropHandler() {
        require(msg.sender == _interopHandlerAddr(), Unauthorized(msg.sender));
        _;
    }

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
    /// @param _l1ChainId The chain id of L1.
    /// @param _eraChainId The chain id of Era.
    /// @param _l1AssetRouter The address of the L1 asset router.
    /// @param _baseTokenAssetId The asset id of the base token.
    /// @param _aliasedOwner The address of the owner of the contract.
    function initL2(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        IL1AssetRouter _l1AssetRouter,
        bytes32 _baseTokenAssetId,
        address _aliasedOwner
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        // solhint-disable-next-line func-named-parameters
        updateL2(_l1ChainId, _eraChainId, _l1AssetRouter, _baseTokenAssetId, _aliasedOwner);
        _setAssetHandler(_baseTokenAssetId, L2_NATIVE_TOKEN_VAULT_ADDR);
    }

    /// @notice Updates the contract.
    /// @dev This function is used to initialize the new implementation of L2AssetRouter on existing chains during
    /// the upgrade.
    /// @param _l1ChainId The chain id of L1.
    /// @param _eraChainId The chain id of Era.
    /// @param _l1AssetRouter The address of the L1 asset router.
    /// @param _baseTokenAssetId The asset id of the base token.
    /// @param _aliasedOwner The expected owner. If the current owner is different (e.g. a temporary
    ///        multisig on a chain that predates decentralized governance), it will be reset.
    function updateL2(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        IL1AssetRouter _l1AssetRouter,
        bytes32 _baseTokenAssetId,
        address _aliasedOwner
    ) public onlyUpgrader {
        require(address(_l1AssetRouter) != address(0), EmptyAddress());
        L1_CHAIN_ID = _l1ChainId;
        L1_ASSET_ROUTER = _l1AssetRouter;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        ERA_CHAIN_ID = _eraChainId;
        // Ensure the owner matches the expected governance. Pre-v31 ZKsync OS testnets ran with a
        // temporary multisig owner; we reset it here so every chain ends up with the same
        // (aliased L1 governance) owner after v31.
        if (owner() != _aliasedOwner) {
            _transferOwnership(_aliasedOwner);
        }
    }

    /// @inheritdoc IL2AssetRouter
    function setAssetHandlerAddress(
        uint256 _originChainId,
        bytes32 _assetId,
        address _assetHandlerAddress
    ) external override onlyAssetRouterCounterpart(_originChainId) {
        _setAssetHandler(_assetId, _assetHandlerAddress);
    }

    /// @inheritdoc AssetRouterBase
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external override {
        _setAssetHandlerAddressThisChain(_nativeTokenVaultAddr(), _assetRegistrationData, _assetHandlerAddress);
    }

    /// @notice Executes cross-chain interop messages following ERC-7786 standard
    /// @param sender ERC-7930 Address of the message sender
    /// @param payload Encoded function call data (must be finalizeDeposit)
    /// @return Function selector confirming successful execution per ERC-7786
    function receiveMessage(
        bytes32 /* receiveId */, // Unique identifier
        bytes calldata sender, // ERC-7930 address
        bytes calldata payload
    ) external payable onlyL2InteropHandler returns (bytes4) {
        // This function serves as the L2AssetRouter's entry point for processing cross-chain bridge operations
        // initiated through the InteropCenter system. It implements critical security validations:
        // - L1->L2 calls: Currently Interop can only be initiated on L2, so this case shouldn't be covered.
        // - L2->L2 calls: Only this contract (L2AssetRouter) can send messages from other L2 chains
        //
        // This dual validation prevents attackers from spoofing cross-chain messages by requiring
        // both correct source chain ID and authorized sender address.
        //
        // INDIRECT CALL PATTERN (L2->L2 interop flow):
        // 1. User calls InteropCenter on source L2
        // 2. InteropCenter calls initiateIndirectCall() on source chain's L2AssetRouter
        // 3. Source L2AssetRouter becomes the "sender" for the destination L2 call
        // 4. Destination L2 validates senderAddress == address(this) for non-L1 sources
        //    (L2AssetRouter address is equal for all ZKsync chains)

        (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);

        _validateAssetRouterCounterpart(senderChainId, senderAddress);

        // The payload must contain a valid finalizeDeposit selector to ensure only legitimate
        // bridge operations are executed. This prevents arbitrary function calls through the interop system.
        require(payload.length > 4, PayloadTooShort());
        require(
            bytes4(payload[0:4]) == AssetRouterBase.finalizeDeposit.selector,
            InvalidSelector(bytes4(payload[0:4]))
        );

        (bool success, ) = address(this).call{value: msg.value}(payload);
        require(success, ExecuteMessageFailed());
        return IERC7786Recipient.receiveMessage.selector;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIATE BRIDGE Functions
    //////////////////////////////////////////////////////////////*/

    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) public payable virtual override onlyL2InteropCenter {
        _bridgehubDepositBaseToken(_chainId, _assetId, _originalCaller, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalizes a bridge request and mints funds.
    /// @param _assetId The encoding of the asset on L2
    /// @param _transferData The encoded data required for finalization
    /// (address _sender, uint256 _amount, address _receiver, bytes memory erc20Data, address originToken)
    function finalizeDeposit(
        // solhint-disable-next-line no-unused-vars
        uint256 _originChainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public payable override onlyAssetRouterCounterpartOrSelf(_originChainId) nonReentrant {
        require(_assetId != BASE_TOKEN_ASSET_ID, AssetIdNotSupported(BASE_TOKEN_ASSET_ID));
        _finalizeDeposit(_originChainId, _assetId, _transferData, _nativeTokenVaultAddr());

        emit DepositFinalizedAssetRouter(_originChainId, _assetId, _transferData);
    }

    /// @inheritdoc IAtomicRecoverable
    /// @dev Recovers the burn embedded in an atomic-bundle `finalizeDeposit(chainId, assetId, transferData)`
    /// call: re-credits the burned asset to the original depositor (the burn's `originalCaller`) on the
    /// burn's destination chain, swapping the receiver to the depositor. Returns `false` for any other
    /// call so the {AtomicFlowManager} can skip non-recoverable bundle calls without reverting.
    function recoverAtomicCall(
        uint256 _destChainId,
        bytes calldata _callData
    ) external onlyAtomicFlowManager nonReentrant returns (bool recovered) {
        if (_callData.length < 4 || bytes4(_callData[:4]) != AssetRouterBase.finalizeDeposit.selector) {
            return false;
        }

        // Decode finalizeDeposit(sourceChainId, assetId, bridgeMintData); the source chain id is unused.
        // The bundle's mint data is forwarded verbatim: NTV.bridgeRecoverFailedTransfer refunds the data's
        // `originalCaller` (the source depositor), so the receiver swap no longer happens here.
        // slither-disable-next-line unused-return
        (, bytes32 assetId, bytes memory mintData) = abi.decode(_callData[4:], (uint256, bytes32, bytes));
        IL2NativeTokenVault(_nativeTokenVaultAddr()).bridgeRecoverFailedTransfer(_destChainId, assetId, mintData);
        return true;
    }

    /// @notice Refunds a timed-out atomic-interop value leg that was funded via the different-base-token
    /// path (`bridgehubDepositBaseToken`), re-crediting the destination base-token asset to the depositor.
    /// @dev Manager-gated wrapper symmetric with {bridgehubDepositBaseToken}; forwards to the NTV, which
    /// reverses the `bridgeBurn` done at send time.
    /// @param _chainId The chain the asset was being bridged to at burn time.
    /// @param _assetId The destination base-token asset id that was burned.
    /// @param _receiver The original depositor to refund.
    /// @param _amount The amount to recover.
    function bridgehubRecoverBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _receiver,
        uint256 _amount
    ) external onlyAtomicFlowManager nonReentrant {
        IL2NativeTokenVault(_nativeTokenVaultAddr()).bridgeRecoverBaseToken(_chainId, _assetId, _receiver, _amount);
    }

    /// @inheritdoc IL2CrossChainSender
    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable onlyL2InteropCenter returns (InteropCallStarter memory interopCallStarter) {
        // This function is called by the InteropCenter when processing indirect interop calls.
        // It prepares the bridge operation for cross-chain execution through these steps:
        // 1. Processing the bridge request through the standard bridgehub flow
        // 2. Encoding the call for interop execution with proper attributes
        // 3. Returning an InteropCallStarter struct for the InteropCenter to process
        // COMPLETE L2->L2 BRIDGE FLOW:
        // - User wants to bridge from L2A to L2B
        // - L2A InteropCenter calls this function on L2A AssetRouter
        // - This creates an InteropCallStarter targeting L2B AssetRouter
        // - InteropCenter sends the call to L2B via the interop messaging system
        // - L2B AssetRouter receives via executeMessage() with sender=address(this)
        //   (L2AssetRouter address is equal on all ZKsync chains)

        address ntvAddr = _nativeTokenVaultAddr();

        L2TransactionRequestTwoBridgesInner memory request = _bridgehubDeposit({
            _chainId: _chainId,
            _originalCaller: _originalCaller,
            _value: _value,
            _data: _data,
            _nativeTokenVault: ntvAddr
        });

        // The _value parameter represents the amount being bridged and is encoded
        // as an ERC-7786 attribute to ensure proper value transfer in the interop call.
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, _value);
        interopCallStarter = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(request.l2Contract),
            data: request.l2Calldata,
            callAttributes: attributes
        });
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @dev IMPORTANT: this method will be deprecated in one of the future releases, so contracts
    /// that rely on it must be upgradeable.
    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    function withdraw(bytes32 _assetId, bytes memory _assetData) public override nonReentrant returns (bytes32) {
        return _withdrawSender(_assetId, _assetData, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal & Helpers
    //////////////////////////////////////////////////////////////*/

    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    /// @param _sender The address of the sender of the message
    function _withdrawSender(
        bytes32 _assetId,
        bytes memory _assetData,
        address _sender
    ) internal returns (bytes32 txHash) {
        bytes memory l1bridgeMintData = _burn({
            _chainId: L1_CHAIN_ID,
            _nextMsgValue: 0,
            _assetId: _assetId,
            _originalCaller: _sender,
            _transferData: _assetData,
            _passValue: false,
            _nativeTokenVault: _nativeTokenVaultAddr()
        });

        bytes memory message = _getAssetRouterWithdrawMessage(_assetId, l1bridgeMintData);
        // slither-disable-next-line unused-return
        txHash = L2ContractHelper.sendMessageToL1(message);

        emit WithdrawalInitiatedAssetRouter(L1_CHAIN_ID, _sender, _assetId, _assetData);
    }

    /// @notice Encodes the message for l2ToL1log sent during withdraw initialization.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _l1bridgeMintData The calldata used by l1 asset handler to unlock tokens for recipient.
    function _getAssetRouterWithdrawMessage(
        bytes32 _assetId,
        bytes memory _l1bridgeMintData
    ) internal view returns (bytes memory) {
        return DataEncoding.encodeAssetRouterFinalizeDepositData(block.chainid, _assetId, _l1bridgeMintData);
    }
}
