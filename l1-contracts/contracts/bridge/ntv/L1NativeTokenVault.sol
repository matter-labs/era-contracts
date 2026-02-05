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
import {IL1AssetTracker} from "../asset-tracker/IL1AssetTracker.sol";
import {IAssetTrackerBase} from "../asset-tracker/IAssetTrackerBase.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {TxStatus} from "../../common/Messaging.sol";

import {NoFundsTransferred, OriginChainIdNotFound, Unauthorized, WithdrawFailed, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {ClaimFailedDepositFailed, WrongCounterpart, OnlyFailureStatusAllowed} from "../L1BridgeContractErrors.sol";

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

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    ///      This mapping was deprecated in favor of AssetTracker component, now it will be responsible for tracking chain balances.
    ///      We have a `chainBalance` function now, which returns the values in this mapping, for backwards compatibility.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) internal DEPRECATED_chainBalance;

    /// @notice AssetTracker component address on L1. On L2 the address is L2_ASSET_TRACKER_ADDR.
    ///         It adds one more layer of security on top of cross chain communication.
    ///         Refer to its documentation for more details.
    IL1AssetTracker public l1AssetTracker;

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

    /// @dev Returns the AssetTracker component address on L1.
    function _assetTracker() internal view override returns (IAssetTrackerBase) {
        return IAssetTrackerBase(address(l1AssetTracker));
    }

    modifier onlyAssetTracker() {
        if (msg.sender != address(l1AssetTracker)) {
            revert Unauthorized(msg.sender);
        }
        _;
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
        _unsafeRegisterNativeToken(ETH_TOKEN_ADDRESS);
    }

    /// @dev Function used to set AssetTracker component address.
    ///      Only callable by owner.
    /// @param _l1AssetTracker The address of the AssetTracker component.
    function setAssetTracker(address _l1AssetTracker) external onlyOwner {
        l1AssetTracker = IL1AssetTracker(_l1AssetTracker);
    }

    /*//////////////////////////////////////////////////////////////
                            V31 migration
    //////////////////////////////////////////////////////////////*/

    function migrateTokenBalanceToAssetTracker(
        uint256 _chainId,
        bytes32 _assetId
    ) external onlyAssetTracker returns (uint256) {
        uint256 amount = DEPRECATED_chainBalance[_chainId][_assetId];
        DEPRECATED_chainBalance[_chainId][_assetId] = 0;
        return amount;
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

        // IMPORTANT: We must handle chain balance decrease before giving out funds to the user,
        // because otherwise the latter operation (via a malicious token or ETH recipient)
        // could've overwritten the transient values from L1Nullifier.
        _handleBridgeFromChain({_chainId: _chainId, _assetId: _assetId, _amount: _amount});

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

    function _registerTokenIfBridgedLegacy(address) internal override returns (bytes32) {
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

    function _handleBridgeToChain(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal override {
        l1AssetTracker.handleChainBalanceIncreaseOnL1(_chainId, _assetId, _amount, _getOriginChainId(_assetId));
    }

    function _handleBridgeFromChain(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal override {
        l1AssetTracker.handleChainBalanceDecreaseOnL1({
            _chainId: _chainId,
            _assetId: _assetId,
            _amount: _amount,
            _tokenOriginChainId: _getOriginChainId(_assetId)
        });
    }
}
