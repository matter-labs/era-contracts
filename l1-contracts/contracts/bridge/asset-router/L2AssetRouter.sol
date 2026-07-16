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
import {AssetIdNotSupported, EmptyAddress, Unauthorized} from "../../common/L1ContractErrors.sol";
import {IERC7786Attributes} from "../../interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2AssetRouter is AssetRouterBase, IL2AssetRouter, ReentrancyGuard, IAtomicRecoverable {
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

    /// @notice Returns the canonical atomic-flow manager address — the contract whitelisted to call
    /// `recoverAtomicCall` (the IMT atomic flow's timeout recovery path). It is a genesis-deployed
    /// built-in at a fixed address, like the interop center above; chains without the
    /// atomic-flow stack simply have nothing deployed there, so the auth gate never passes. Virtual
    /// for private interop override.
    function _atomicFlowManagerAddr() internal view virtual returns (address) {
        return L2_ATOMIC_FLOW_MANAGER_ADDR;
    }

    /// @notice Checks that the message sender is the asset-router counterpart for messages originating on L1.
    modifier onlyAssetRouterCounterpart(uint256 _sourceChainId) {
        if (_sourceChainId == L1_CHAIN_ID) {
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

    /// @notice Checks that the message sender is the L1 asset-router counterpart or this contract itself.
    /// @dev Self-calls are used for interop flows where the destination L2AssetRouter re-enters its own finalize path.
    modifier onlyAssetRouterCounterpartOrSelf(uint256 _sourceChainId) {
        if (_sourceChainId == L1_CHAIN_ID) {
            // For messages originating on L1, only the L1 Asset Router counterpart may call this function.
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
    /// `recoverAtomicCall` for the atomic interop flow's timeout path. On chains without the
    /// atomic-flow stack nothing is deployed at that address, so this gate naturally never passes.
    modifier onlyAtomicFlowManager() {
        require(msg.sender == _atomicFlowManagerAddr(), Unauthorized(msg.sender));
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
        uint256 _sourceChainId,
        bytes32 _assetId,
        address _assetHandlerAddress
    ) external override onlyAssetRouterCounterpart(_sourceChainId) {
        _setAssetHandler(_assetId, _assetHandlerAddress);
    }

    /// @inheritdoc AssetRouterBase
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external override {
        _setAssetHandlerAddressThisChain(_nativeTokenVaultAddr(), _assetRegistrationData, _assetHandlerAddress);
    }

    /// @inheritdoc AssetRouterBase
    /// @dev Interop calls are delivered by the L2 interop handler system contract.
    function _interopHandler() internal view override returns (address) {
        return L2_INTEROP_HANDLER_ADDR;
    }

    /// @inheritdoc AssetRouterBase
    /// @dev Validates cross-chain bridge operations initiated through the InteropCenter system:
    /// - L1->L2 calls: Currently Interop can only be initiated on L2, so this case shouldn't be covered.
    /// - L2->L2 calls: Only this contract (L2AssetRouter) can send messages from other L2 chains
    /// This dual validation prevents attackers from spoofing cross-chain messages by requiring
    /// both correct source chain ID and authorized sender address.
    ///
    /// INDIRECT CALL PATTERN (L2->L2 interop flow):
    /// 1. User calls InteropCenter on source L2
    /// 2. InteropCenter calls initiateIndirectCall() on source chain's L2AssetRouter
    /// 3. Source L2AssetRouter becomes the "sender" for the destination L2 call
    /// 4. Destination L2 validates senderAddress == address(this) for non-L1 sources
    ///    (L2AssetRouter address is equal for all ZKsync chains)
    function _isValidInteropSender(
        uint256 _senderChainId,
        address _senderAddress
    ) internal view override returns (bool) {
        return _senderChainId != L1_CHAIN_ID && _senderAddress == address(this);
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
    /// @param _sourceChainId The chain ID the deposit message originates from (the source chain of the
    /// message, not the origin chain of the bridged token).
    /// @param _assetId The encoding of the asset on L2
    /// @param _transferData The encoded data required for finalization
    /// (address _sender, uint256 _amount, address _receiver, bytes memory erc20Data, address originToken)
    function finalizeDeposit(
        uint256 _sourceChainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public payable override onlyAssetRouterCounterpartOrSelf(_sourceChainId) nonReentrant {
        require(_assetId != BASE_TOKEN_ASSET_ID, AssetIdNotSupported(BASE_TOKEN_ASSET_ID));
        _finalizeDeposit(_sourceChainId, _assetId, _transferData, _nativeTokenVaultAddr());

        emit DepositFinalizedAssetRouter(_sourceChainId, _assetId, _transferData);
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

        // For L2->L2 the counterpart is the L2 asset router (same address on every ZK chain). For an
        // L2->L1 withdrawal the destination is L1, where the asset router lives at a different address,
        // so we target the known L1 asset router instead. The finalizeDeposit calldata is identical.
        address destinationAssetRouter = _chainId == L1_CHAIN_ID ? address(L1_ASSET_ROUTER) : request.l2Contract;
        interopCallStarter = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(destinationAssetRouter),
            data: request.l2Calldata,
            callAttributes: attributes
        });
    }
}
