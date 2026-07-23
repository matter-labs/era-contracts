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
import {IBridgedStandardToken} from "../interfaces/IBridgedStandardToken.sol";
import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
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
import {ClaimFailedDepositFailed, OnlyFailureStatusAllowed, WrongCounterpart} from "../L1BridgeContractErrors.sol";
import {InsufficientChainBalance} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
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

    /// @dev L1 nullifier contract that handles legacy functions & finalize withdrawal, confirm l2 tx mappings
    IL1Nullifier public immutable L1_NULLIFIER;

    /// @dev Maps token balances for each chain. Deprecated: per-chain balance accounting was removed;
    ///      correctness of transfers is guaranteed by ZK proofs (plus 2FA on ZKsync OS chains).
    ///      We have a `chainBalance` function now, which returns the values in this mapping, for backwards compatibility.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) internal DEPRECATED_chainBalance;

    /// @dev Slot previously holding the removed L1AssetTracker address. Retained to preserve the
    ///      storage layout of already-deployed vaults across the in-place upgrade.
    // slither-disable-next-line unused-state
    address private __DEPRECATED_l1AssetTracker;

    /// @notice Net amount of each L1-native token currently bridged out of L1.
    /// @dev Increases on outbound flows (deposits/interop sends) and decreases on inbound ones
    /// (withdrawal finalizations and failed-deposit refunds), so unlike the vault's raw `balanceOf`
    /// it cannot be skewed by direct transfers into the vault. It is bounded by the amount actually
    /// escrowed in the vault, so it cannot overflow even for tokens with an astronomic total supply.
    mapping(bytes32 assetId => uint256 amount) public bridgedOut;

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

    /// @notice Used to register the Asset Handler asset in L2 AssetRouter.
    /// @param _assetHandlerAddressOnCounterpart the address of the asset handler on the counterpart chain.
    function bridgeCheckCounterpartAddress(
        uint256,
        bytes32,
        address,
        address _assetHandlerAddressOnCounterpart
    ) external view override onlyAssetRouter {
        require(_assetHandlerAddressOnCounterpart == L2_NATIVE_TOKEN_VAULT_ADDR, WrongCounterpart());
    }

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

    function _bridgeBurnNativeToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        // solhint-disable-next-line no-unused-vars
        bool _depositChecked,
        uint256 _depositAmount,
        address _receiver,
        address _nativeToken
    ) internal override returns (bytes memory _bridgeMintData) {
        bool depositChecked = IL1AssetRouter(address(ASSET_ROUTER)).transferFundsToNTV(
            _assetId,
            _depositAmount,
            _originalCaller
        );
        _bridgeMintData = super._bridgeBurnNativeToken({
            _chainId: _chainId,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _depositChecked: depositChecked,
            _depositAmount: _depositAmount,
            _receiver: _receiver,
            _nativeToken: _nativeToken
        });
    }

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
        address l1Token = tokenAddress[_assetId];
        require(_amount != 0, NoFundsTransferred());

        // Record the refund before giving out funds so the flow counters are already
        // consistent if the recipient re-enters a view of them.
        _handleBridgeFromChain(_chainId, _assetId, _amount);

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), _depositSender, _amount, 0, 0, 0, 0)
            }
            require(callSuccess, ClaimFailedDepositFailed());
        } else {
            uint256 originChainId = _getOriginChainId(_assetId);
            if (originChainId == block.chainid) {
                IERC20(l1Token).safeTransfer(_depositSender, _amount);
            } else if (originChainId != 0) {
                IBridgedStandardToken(l1Token).bridgeMint(_depositSender, _amount);
            } else {
                revert OriginChainIdNotFound();
            }
            // Note we don't allow weth deposits anymore, but there might be legacy weth deposits.
            // until we add Weth bridging capabilities, we don't wrap/unwrap weth to ether.
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL & HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _registerTokenIfBridgedLegacy(address) internal pure override returns (bytes32) {
        // There are no legacy tokens present on L1.
        return bytes32(0);
    }

    /// @notice Used to get the expected bridged token address corresponding to its native counterpart.
    /// @param _originChainId The chain id of the origin token.
    /// @param _nonNativeToken The address of token on its origin chain.
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
        // Use CREATE2 to deploy the BeaconProxy
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
