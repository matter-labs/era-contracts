// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";
import {Create2} from "@openzeppelin/contracts-v4/utils/Create2.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1NativeTokenVault} from "./IL1NativeTokenVault.sol";
import {NativeTokenVaultBase} from "./NativeTokenVaultBase.sol";

import {IL1AssetHandler} from "../interfaces/IL1AssetHandler.sol";
import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

import {ETH_TOKEN_ADDRESS, MAX_TOKEN_BALANCE} from "../../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {TxStatus} from "../../common/Messaging.sol";

import {
    AssetIdAlreadyRegistered,
    NoFundsTransferred,
    OriginChainIdNotFound,
    WithdrawFailed,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";
import {AssetNotNativeToL1, OnlyFailureStatusAllowed, WrongCounterpart} from "../L1BridgeContractErrors.sol";
import {InsufficientChainBalance} from "../asset-tracker/AssetTrackerErrors.sol";
import {ILegacyL1AssetTracker} from "../asset-tracker/ILegacyL1AssetTracker.sol";

import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 vault holding native ETH and ERC20 tokens bridged into the ZK chains.
/// See {protocol-docs/bridging.md#native-token-vault}.
/// @dev Designed for use with a proxy for upgradability.
contract L1NativeTokenVault is IL1NativeTokenVault, IL1AssetHandler, NativeTokenVaultBase {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token.
    IWETH9 public immutable WETH_TOKEN;

    /// @dev The L1 asset router contract.
    IAssetRouterBase public immutable ASSET_ROUTER;

    /// @dev The assetId of the base token.
    bytes32 public immutable BASE_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    uint256 public immutable L1_CHAIN_ID;

    /// @dev L1 nullifier contract that handles finalize withdrawal and confirm l2 tx mappings
    IL1Nullifier public immutable L1_NULLIFIER;

    /// @dev Maps token balances for each chain. Deprecated: per-chain balance accounting was removed;
    ///      correctness of transfers is guaranteed by ZK proofs (plus 2FA on ZKsync OS chains).
    ///      We have a `chainBalance` function now, which returns the values in this mapping, for backwards compatibility.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) internal DEPRECATED_chainBalance;

    /// @dev Slot holding the address of the removed L1AssetTracker. Retained to preserve the storage
    ///      layout of already-deployed vaults across the in-place upgrade, and read by
    ///      `populateBridgedOut` to locate the legacy per-chain accounting.
    // slither-disable-next-line uninitialized-state
    address internal __DEPRECATED_l1AssetTracker;

    /// @inheritdoc IL1NativeTokenVault
    mapping(bytes32 assetId => uint256 amount) public bridgedOut;

    /// @inheritdoc IL1NativeTokenVault
    mapping(bytes32 assetId => bool populated) public bridgedOutPopulated;

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the L1 asset router for internal use.
    function _assetRouter() internal view override returns (IAssetRouterBase) {
        return ASSET_ROUTER;
    }

    /// @dev Returns the L1 chain ID for internal use.
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    /// @dev Returns the base token asset ID for internal use.
    function _baseTokenAssetId() internal view override returns (bytes32) {
        return BASE_TOKEN_ASSET_ID;
    }

    /// @dev Returns the WETH token address for internal use.
    function _wethToken() internal view override returns (address) {
        return address(WETH_TOKEN);
    }

    /// @dev Returns the value of `DEPRECATED_chainBalance` for backwards compatibility.
    ///      The function body will be replaced with revert in the next release.
    /// @param _chainId The ID of the chain for which the chainBalance gets queried.
    /// @param _assetId Asset, the balance of which is being queried.
    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256) {
        return DEPRECATED_chainBalance[_chainId][_assetId];
    }

    /*//////////////////////////////////////////////////////////////
                        Populating bridgedOut
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1NativeTokenVault
    function legacyL1AssetTracker() external view returns (address) {
        return __DEPRECATED_l1AssetTracker;
    }

    /// @inheritdoc IL1NativeTokenVault
    function legacyBridgedOut(bytes32 _assetId) public view returns (uint256 amount) {
        // The bulkhead complement below is only a net outflow for an asset whose origin chain is L1: for an
        // L2-native asset L1's entry is a bridged-in balance, so the complement would be a ~`2^256` garbage
        // number. `bridgedOut` only governs L1-native assets anyway.
        uint256 assetOriginChainId = originChainId[_assetId];
        require(assetOriginChainId == L1_CHAIN_ID, AssetNotNativeToL1(_assetId, assetOriginChainId));

        address legacyTracker = __DEPRECATED_l1AssetTracker;

        // The v31 tracker seeds the asset's origin chain — L1, for the assets `bridgedOut` tracks — with
        // the `MAX_TOKEN_BALANCE` bulkhead and moves amounts in and out of that entry on every L1 outflow
        // and inflow, so its complement is the net amount bridged out of L1. Reading it instead of summing
        // the per-chain entries keeps the result immune to amounts moving between chains, which the
        // tracker's own migration entry points can still perform after the upgrade.
        // Registration in the tracker also means this vault holds nothing for the asset:
        // `L1AssetTracker.registerLegacyToken` moved each chain's amount over with
        // `migrateTokenBalanceToAssetTracker`, which zeroed the entry it read, for every chain except the
        // asset's origin chain — and that origin chain is L1, whose entry is excluded below anyway. Nothing
        // has written these entries since, so chains registered later hold nothing either.
        // Neither function is in the tree any more — they went away with the trackers in `1df271ef2`, so
        // the argument above is checked against `1df271ef2^`; the accounting itself is described in
        // {protocol-docs/bridging.md#populating-bridgedout-during-an-in-place-upgrade}.
        if (legacyTracker != address(0) && ILegacyL1AssetTracker(legacyTracker).isAssetRegistered(_assetId)) {
            return MAX_TOKEN_BALANCE - ILegacyL1AssetTracker(legacyTracker).chainBalance(L1_CHAIN_ID, _assetId);
        }

        // Assets that never went through the tracker migration still have their amounts here. Nothing writes
        // these entries anymore, so summing them over the registered chains is exact. The list holds ZK
        // chains only, never L1 itself, so no entry of this vault's own chain can enter the sum.
        uint256[] memory chainIds = IBridgehubBase(address(L1_NULLIFIER.BRIDGE_HUB())).getAllZKChainChainIDs();
        uint256 chainIdsLength = chainIds.length;
        for (uint256 i = 0; i < chainIdsLength; ++i) {
            amount += DEPRECATED_chainBalance[chainIds[i]][_assetId];
        }
    }

    /// @inheritdoc IL1NativeTokenVault
    function populateBridgedOut(bytes32[] calldata _assetIds) external returns (uint256[] memory populatedAmounts) {
        uint256 assetIdsLength = _assetIds.length;
        populatedAmounts = new uint256[](assetIdsLength);

        for (uint256 i = 0; i < assetIdsLength; ++i) {
            bytes32 assetIdToPopulate = _assetIds[i];

            // Repeated assets are skipped rather than reverted so that a partially mined batch can simply
            // be re-submitted.
            if (bridgedOutPopulated[assetIdToPopulate]) {
                continue;
            }
            bridgedOutPopulated[assetIdToPopulate] = true;

            // Reverts for anything that is not native to L1, which is a caller mistake rather than a no-op
            // worth tolerating.
            uint256 legacyAmount = legacyBridgedOut(assetIdToPopulate);
            if (legacyAmount != 0) {
                bridgedOut[assetIdToPopulate] += legacyAmount;
                populatedAmounts[i] = legacyAmount;
            }
            emit BridgedOutPopulated(assetIdToPopulate, legacyAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Initialization
    //////////////////////////////////////////////////////////////*/

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _wethToken Address of WETH on deployed chain
    /// @param _assetRouter Address of Asset Router on L1.
    /// @param _l1Nullifier Address of the nullifier contract, which handles transaction progress between L1 and ZK chains.
    constructor(address _wethToken, address _assetRouter, IL1Nullifier _l1Nullifier) {
        _disableInitializers();
        WETH_TOKEN = IWETH9(_wethToken);
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        L1_CHAIN_ID = block.chainid;
        BASE_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        L1_NULLIFIER = _l1Nullifier;
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy
    /// @param _owner Address which can change pause / unpause the NTV
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner, address _bridgedTokenBeacon) external initializer {
        require(_owner != address(0), ZeroAddress());
        bridgedTokenBeacon = IBeacon(_bridgedTokenBeacon);
        _transferOwnership(_owner);
    }

    /// @inheritdoc IL1NativeTokenVault
    function registerEthToken() external {
        require(assetId[ETH_TOKEN_ADDRESS] == bytes32(0), AssetIdAlreadyRegistered());
        _unsafeRegisterNativeToken(ETH_TOKEN_ADDRESS);
    }

    /*//////////////////////////////////////////////////////////////
                            Check counterpart Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates the asset handler being set on a counterpart chain: for NTV-managed assets it
    /// must be the L2 NTV.
    /// @param _assetHandlerAddressOnCounterpart The address of the asset handler on the counterpart chain.
    function bridgeCheckCounterpartAddress(
        uint256,
        bytes32,
        address,
        address _assetHandlerAddressOnCounterpart
    ) external view override onlyAssetRouter {
        require(_assetHandlerAddressOnCounterpart == L2_NATIVE_TOKEN_VAULT_ADDR, WrongCounterpart());
    }

    /// @dev Resolves the token's origin chain, falling back to vault/nullifier balance heuristics for
    /// legacy deposits made before the token was registered; returns 0 if it cannot be determined.
    function _getOriginChainId(bytes32 _assetId) internal view returns (uint256) {
        uint256 chainId = originChainId[_assetId];
        if (chainId != 0) {
            return chainId;
        } else {
            address token = tokenAddress[_assetId];
            if (token == ETH_TOKEN_ADDRESS) {
                return block.chainid;
            } else if (IERC20(token).balanceOf(address(this)) > 0) {
                return block.chainid;
            } else if (IERC20(token).balanceOf(address(L1_NULLIFIER)) > 0) {
                return block.chainid;
            } else {
                return 0;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Start transaction Functions
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            L1 SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    ///  @inheritdoc IL1AssetHandler
    function bridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter whenNotPaused {
        require(_txStatus == TxStatus.Failure, OnlyFailureStatusAllowed());
        // slither-disable-next-line unused-return
        (uint256 _amount, , ) = DataEncoding.decodeBridgeBurnData(_data);
        require(_amount != 0, NoFundsTransferred());

        uint256 originChain = _getOriginChainId(_assetId);
        if (originChain == 0) {
            revert OriginChainIdNotFound();
        }
        // The token is always already known here, so `_disburseFailedTransfer`'s deploy branch is never
        // taken and the `_originToken`/`_erc20Data` arguments are unused. Legacy WETH deposits may still
        // be claimed (no wrap/unwrap is performed) even though new WETH deposits are not allowed.
        bool isNative = originChain == block.chainid;
        _disburseFailedTransfer({
            _chainId: _chainId,
            _assetId: _assetId,
            _receiver: _depositSender,
            _amount: _amount,
            _isNative: isNative,
            _originToken: address(0),
            _erc20Data: ""
        });
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL & HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc NativeTokenVaultBase
    function calculateCreate2TokenAddress(
        uint256 _originChainId,
        address _nonNativeToken
    ) public view override returns (address) {
        bytes32 salt = _getCreate2Salt(_originChainId, _nonNativeToken);
        return
            Create2.computeAddress(
                salt,
                keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgedTokenBeacon, "")))
            );
    }

    function _withdrawFunds(bytes32 _assetId, address _to, address _token, uint256 _amount) internal override {
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), _to, _amount, 0, 0, 0, 0)
            }
            require(callSuccess, WithdrawFailed());
        } else {
            // Withdraw funds
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function _deployBeaconProxy(bytes32 _salt, uint256) internal override returns (BeaconProxy proxy) {
        address proxyAddress = Create2.deploy(
            0,
            _salt,
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgedTokenBeacon, ""))
        );
        return BeaconProxy(payable(proxyAddress));
    }

    /// @dev Records the outbound flow of L1-native tokens; see `bridgedOut`.
    function _handleBridgeToChain(uint256, bytes32 _assetId, uint256 _amount) internal override {
        if (originChainId[_assetId] == block.chainid) {
            bridgedOut[_assetId] += _amount;
        }
    }

    /// @dev Records the inbound flow of L1-native tokens; see `bridgedOut`.
    /// @dev An inbound amount exceeding the outstanding bridged-out amount is only possible if
    /// bridged representations of the asset were forged somewhere upstream, so such a transfer
    /// is blocked rather than recorded.
    function _handleBridgeFromChain(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal override {
        if (originChainId[_assetId] == block.chainid) {
            if (bridgedOut[_assetId] < _amount) {
                revert InsufficientChainBalance(_chainId, _assetId, _amount);
            }
            bridgedOut[_assetId] -= _amount;
        }
    }
}
