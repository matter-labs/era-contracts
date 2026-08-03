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
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

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
import {
    AssetIdNotSupported,
    EmptyAddress,
    RecoverToL1NotSupported,
    Unauthorized
} from "../../common/L1ContractErrors.sol";
import {IERC7786Attributes} from "../../interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L2 side of asset routing: routes L1 <-> L2 and L2 <-> L2 asset transfers to per-asset
/// handlers. See {protocol-docs/bridging.md#asset-routing-burn--mint}.
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

    /// @notice Returns the canonical atomic-flow manager address, the only caller allowed into
    /// `recoverAtomicCall`. Chains without the atomic-flow stack have nothing deployed there, so the
    /// auth gate never passes. Virtual for private interop override.
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

    /// @notice Checks that the message sender is the canonical atomic-flow manager.
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
        // Reset the owner to the expected (aliased L1) governance; pre-v31 ZKsync OS testnets ran with a
        // temporary multisig owner.
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
    /// @dev Interop is only initiated on L2s, so the source may not be L1; the sender must be this same
    /// router (identical address on every ZK chain). See {protocol-docs/bridging.md#finalization-destination-side}.
    function _isValidInteropSender(
        uint256 _senderChainId,
        address _senderAddress
    ) internal view override returns (bool) {
        return _senderChainId != L1_CHAIN_ID && _senderAddress == address(this);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIATE BRIDGE Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AssetRouterBase
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

    /// @inheritdoc AssetRouterBase
    /// @dev Also callable by the aliased L1 asset router (L1 -> L2 deposits); the chain's own base-token
    /// asset ID is rejected.
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
    /// @dev Timeout-refund hook of the atomic interop flow: recognizes only `finalizeDeposit` calls and
    /// reverses their burn via the NTV, refunding the original depositor. Returns `false` for any other
    /// call so the {AtomicFlowManager} can skip non-recoverable bundle calls without reverting.
    /// See {protocol-docs/bridging.md#atomic-recovery-hook}.
    function recoverAtomicCall(
        uint256 _destChainId,
        bytes calldata _callData
    ) external onlyAtomicFlowManager nonReentrant returns (bool recovered) {
        // L2->L1 withdrawals are never revertable: `totalWithdrawalsToL1` must stay append-only.
        // See {protocol-docs/bridging.md#security-notes}.
        require(_destChainId != L1_CHAIN_ID, RecoverToL1NotSupported());
        if (_callData.length < 4 || bytes4(_callData[:4]) != AssetRouterBase.finalizeDeposit.selector) {
            return false;
        }

        // Decode finalizeDeposit(sourceChainId, assetId, bridgeMintData); the source chain id is unused.
        // slither-disable-next-line unused-return
        (, bytes32 assetId, bytes memory mintData) = abi.decode(_callData[4:], (uint256, bytes32, bytes));
        IL2NativeTokenVault(_nativeTokenVaultAddr()).bridgeRecoverFailedTransfer(_destChainId, assetId, mintData);
        return true;
    }

    /// @notice Refunds a timed-out atomic-interop value leg, re-crediting the destination base-token asset
    /// to the depositor.
    /// @dev Manager-gated wrapper symmetric with {bridgehubDepositBaseToken} and the same-base
    /// BaseTokenHolder path; forwards to the NTV, which dispatches through the existing failed-transfer
    /// recovery logic.
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
        require(_chainId != L1_CHAIN_ID, RecoverToL1NotSupported());
        // Reuse the generic failed-transfer recovery. The base-token deposit (bridgehubDepositBaseToken)
        // discarded its bridge-mint data, so reconstruct the minimal form: `bridgeRecoverFailedTransfer`
        // refunds the mint data's `originalCaller` for `amount`, and the asset is already registered on
        // this chain (it was burned from the depositor), so origin-token / erc20 metadata go unused.
        // solhint-disable-next-line func-named-parameters
        bytes memory mintData = DataEncoding.encodeBridgeMintData(_receiver, _receiver, address(0), _amount, "");
        IL2NativeTokenVault(_nativeTokenVaultAddr()).bridgeRecoverFailedTransfer(_chainId, _assetId, mintData);
    }

    /// @inheritdoc IL2CrossChainSender
    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable onlyL2InteropCenter returns (InteropCallStarter memory interopCallStarter) {
        address ntvAddr = _nativeTokenVaultAddr();

        L2TransactionRequestTwoBridgesInner memory request = _bridgehubDeposit({
            _chainId: _chainId,
            _originalCaller: _originalCaller,
            _value: _value,
            _data: _data,
            _nativeTokenVault: ntvAddr
        });

        // Echo the requested `interopCallValue` back so the InteropCenter's `IndirectCallValueMismatch`
        // check passes. It is always zero for an indirect call; the bridged token amount travels in the
        // `finalizeDeposit` calldata built above, not as call value.
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, _value);

        // For an L2->L1 withdrawal the asset router on L1 lives at a different address than the common
        // L2 one, so target the known L1 asset router; the finalizeDeposit calldata is identical.
        address destinationAssetRouter = _chainId == L1_CHAIN_ID ? address(L1_ASSET_ROUTER) : request.l2Contract;
        interopCallStarter = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(destinationAssetRouter),
            data: request.l2Calldata,
            callAttributes: attributes
        });
    }
}
