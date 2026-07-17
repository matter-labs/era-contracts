// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL2NativeTokenVault, InteropL2Info, SavedTotalSupply} from "./IL2NativeTokenVault.sol";
import {NativeTokenVaultBase} from "./NativeTokenVaultBase.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_HOLDER,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR
} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {IContractDeployer, L2ContractHelper} from "../../common/l2-helpers/L2ContractHelper.sol";

import {SystemContractsCaller} from "../../common/l2-helpers/SystemContractsCaller.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {
    AddressMismatch,
    AssetIdMismatch,
    AssetIdNotRegistered,
    AssetIdNotSupported,
    ChainIdMismatch,
    DeployFailed,
    EmptyAddress,
    EmptyBytes32,
    InsufficientChainBalance,
    InvalidCaller
} from "../../common/L1ContractErrors.sol";

import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {TokenBridgingData, TokenMetadata} from "../../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2NativeTokenVault is IL2NativeTokenVault, NativeTokenVaultBase {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    address public WETH_TOKEN;

    /// @dev The assetId of the base token.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @dev Chain ID of L1 for bridging reasons.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public L1_CHAIN_ID;

    /// @dev Deprecated slot, retained to preserve the upgradeable storage layout.
    /// Formerly `L2_LEGACY_SHARED_BRIDGE` (the L2 legacy shared bridge). No longer read or written.
    // slither-disable-next-line uninitialized-state
    address private __DEPRECATED_L2_LEGACY_SHARED_BRIDGE;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 public L2_TOKEN_PROXY_BYTECODE_HASH;

    /// @dev The address of the base token on its origin chain
    address public BASE_TOKEN_ORIGIN_TOKEN;

    /// @dev The name of the base token.
    string public BASE_TOKEN_NAME;

    /// @dev The symbol of the base token.
    string public BASE_TOKEN_SYMBOL;

    /// @dev The decimals of the base token.
    uint256 public BASE_TOKEN_DECIMALS;

    /// @notice Net amount of each L2-native token currently bridged out of this chain.
    /// @dev This is write-only bookkeeping kept for future use; it is not consulted by any bridging
    /// decision. Correctness of transfers is guaranteed by ZK proofs (plus 2FA on ZKsync OS chains)
    /// rather than by on-chain balance enforcement. It mirrors `L1NativeTokenVault.bridgedOut`:
    /// it increases on outbound flows and decreases on inbound ones, so unlike the vault's raw
    /// `balanceOf` it cannot be skewed by direct transfers into the vault.
    /// @dev For tokens that were bridged before this bookkeeping was introduced (including via the
    /// retired L2AssetTracker, which chains upgraded in place retain at its reserved address), the
    /// value is seeded with the vault's escrow balance on the token's first tracked bridge operation;
    /// see `_trackLegacyTokenIfNeeded`.
    mapping(bytes32 assetId => uint256 amount) public bridgedOut;

    /// @notice Denotes whether the chain-local bookkeeping for a token has been initialized: its
    /// `bridgedOut` seed and `preTrackingTotalSupply` snapshot are set.
    /// @dev Once we know that all legacy tokens have been tracked (and all new ones have the
    /// corresponding logic performed automatically), this mapping can be removed. So DONT RELY ON IT!
    mapping(bytes32 assetId => bool isTracked) public isAssetTracked;

    /// @notice Token total-supply snapshot captured before the first tracked bridge operation for each
    /// bridged (non-native) token. Together with `interopInfo` it allows reconstructing the amount of a
    /// token attributable to L1 if per-chain accounting is ever reintroduced.
    /// @dev For L2-native tokens no snapshot is stored: their bridged-out accounting is carried by
    /// `bridgedOut`. For chains upgraded in place, snapshots recorded before the upgrade remain in the
    /// retired L2AssetTracker at its reserved address.
    mapping(bytes32 assetId => SavedTotalSupply snapshot) public preTrackingTotalSupply;

    /// @notice L2-side accounting of L1 <-> L2 flows. All chains are assumed to settle on L1, so no
    /// settlement-layer distinction is made. Together with `preTrackingTotalSupply` it allows
    /// reconstructing the amount of a token attributable to the L1 escrow if per-chain accounting is
    /// ever reintroduced.
    mapping(bytes32 assetId => InteropL2Info info) public interopInfo;

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
    /// @param _l1ChainId The chain id of L1.
    /// @param _aliasedOwner The address of the owner of the contract.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _bridgedTokenBeacon The address of the L2 token beacon for legacy chains.
    /// @param _wethToken The address of the L2 weth token.
    /// @param _baseTokenBridgingData The bridging data of the base token.
    /// @param _baseTokenMetadata The metadata of the base token.
    function initL2(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _bridgedTokenBeacon,
        address _wethToken,
        TokenBridgingData calldata _baseTokenBridgingData,
        TokenMetadata calldata _baseTokenMetadata
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        // solhint-disable-next-line func-named-parameters
        updateL2(
            _l1ChainId,
            _aliasedOwner,
            _l2TokenProxyBytecodeHash,
            _wethToken,
            _baseTokenBridgingData,
            _baseTokenMetadata
        );
        if (_bridgedTokenBeacon == address(0)) {
            revert EmptyAddress();
        }
        bridgedTokenBeacon = IBeacon(_bridgedTokenBeacon);
        emit L2TokenBeaconUpdated(address(bridgedTokenBeacon), _l2TokenProxyBytecodeHash);
    }

    /// @notice Updates the contract.
    /// @dev This function is used to initialize the new implementation of L2NativeTokenVault on existing chains during
    /// the upgrade.
    /// @param _l1ChainId The chain id of L1.
    /// @param _aliasedOwner The expected owner. If the current owner is different (e.g. a temporary
    ///        multisig on a chain that predates decentralized governance), it will be reset.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _wethToken The address of the WETH token.
    /// @param _baseTokenBridgingData The bridging data of the base token.
    /// @param _baseTokenMetadata The metadata of the base token.
    function updateL2(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _wethToken,
        TokenBridgingData calldata _baseTokenBridgingData,
        TokenMetadata calldata _baseTokenMetadata
    ) public onlyUpgrader {
        // Ensure _wethToken is not zero address to maintain WETH security guards
        require(_wethToken != address(0), EmptyAddress());

        // Prevent changing WETH_TOKEN if already set to a different non-zero value
        require(WETH_TOKEN == address(0) || WETH_TOKEN == _wethToken, AddressMismatch(_wethToken, WETH_TOKEN));

        // Prevent changing L1_CHAIN_ID if already set to a different value
        require(L1_CHAIN_ID == 0 || L1_CHAIN_ID == _l1ChainId, ChainIdMismatch());

        // Freeze BASE_TOKEN_ASSET_ID once set (mirrors the WETH_TOKEN / L1_CHAIN_ID guards above): a change
        // would strand in-flight bundles whose snapshotted destinationBaseTokenAssetId no longer matches.
        require(
            BASE_TOKEN_ASSET_ID == bytes32(0) || BASE_TOKEN_ASSET_ID == _baseTokenBridgingData.assetId,
            AssetIdMismatch(BASE_TOKEN_ASSET_ID, _baseTokenBridgingData.assetId)
        );

        WETH_TOKEN = _wethToken;
        BASE_TOKEN_ASSET_ID = _baseTokenBridgingData.assetId;
        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ORIGIN_TOKEN = _baseTokenBridgingData.originToken;
        BASE_TOKEN_NAME = _baseTokenMetadata.name;
        BASE_TOKEN_SYMBOL = _baseTokenMetadata.symbol;
        BASE_TOKEN_DECIMALS = _baseTokenMetadata.decimals;

        tokenAddress[_baseTokenBridgingData.assetId] = L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;
        assetId[L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR] = _baseTokenBridgingData.assetId;
        originChainId[_baseTokenBridgingData.assetId] = _baseTokenBridgingData.originChainId;

        require(_l2TokenProxyBytecodeHash != bytes32(0), EmptyBytes32());

        L2_TOKEN_PROXY_BYTECODE_HASH = _l2TokenProxyBytecodeHash;

        // Ensure the owner matches the expected governance.
        if (owner() != _aliasedOwner) {
            require(_aliasedOwner != address(0), EmptyAddress());
            _transferOwnership(_aliasedOwner);
        }
    }

    /// @dev Initializes the chain-local bookkeeping for a token that is registered in the vault for
    /// the first time (total-supply snapshot / outbound accounting).
    function _registerTokenForTracking(bytes32 _assetId, uint256 _originChainId) internal override {
        if (isAssetTracked[_assetId]) {
            return;
        }
        isAssetTracked[_assetId] = true;

        // For a token native to this chain nothing is escrowed yet, so its net `bridgedOut` amount
        // starts at zero. A bridged token registered here is deployed by the vault and has never been
        // bridged before, so its pre-tracking total supply is zero.
        if (_originChainId != block.chainid) {
            preTrackingTotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: 0});
        }
    }

    /// @notice Ensures that the token is deployed.
    /// @param _assetId The asset ID.
    /// @param _originToken The origin token address.
    /// @param _erc20Data The ERC20 data.
    /// @return expectedToken The token address.
    function _ensureAndSaveTokenDeployed(
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data
    ) internal override returns (address expectedToken) {
        uint256 tokenOriginChainId;
        (expectedToken, tokenOriginChainId) = _calculateExpectedTokenAddress(_originToken, _erc20Data);
        super._ensureAndSaveTokenDeployedInner({
            _tokenOriginChainId: tokenOriginChainId,
            _assetId: _assetId,
            _originToken: _originToken,
            _erc20Data: _erc20Data,
            _expectedToken: expectedToken
        });
    }

    /// @notice Deploys the beacon proxy for the L2 token, while using ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `L2_TOKEN_PROXY_BYTECODE_HASH` is used
    /// for the code of the proxy.
    /// @param _salt The salt used for beacon proxy deployment of L2 bridged token.
    /// @param _tokenOriginChainId The origin chain id of the token.
    /// @return proxy The beacon proxy, i.e. L2 bridged token.
    function _deployBeaconProxy(
        bytes32 _salt,
        // solhint-disable-next-line no-unused-vars
        uint256 _tokenOriginChainId
    ) internal virtual override returns (BeaconProxy proxy) {
        // Deploy the beacon proxy for the L2 token
        (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
            uint32(gasleft()),
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            0,
            abi.encodeCall(
                IContractDeployer.create2,
                (_salt, L2_TOKEN_PROXY_BYTECODE_HASH, abi.encode(address(bridgedTokenBeacon), ""))
            )
        );

        // The deployment should be successful and return the address of the proxy
        require(success, DeployFailed());
        proxy = BeaconProxy(abi.decode(returndata, (address)));
    }

    function _withdrawFunds(bytes32 _assetId, address _to, address _token, uint256 _amount) internal override {
        require(_assetId != BASE_TOKEN_ASSET_ID, AssetIdNotSupported(BASE_TOKEN_ASSET_ID));
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /// @dev The base token is escrowed off-vault (in `BaseTokenHolder`) at burn time, so the native/bridged
    /// disbursement branches cannot recover it; return the escrow instead — the inverse of
    /// `burnAndStartBridging`. `_chainId` is the original bridge-out destination.
    function _disburseFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _receiver,
        uint256 _amount,
        bool _isNative,
        address _originToken,
        bytes memory _erc20Data
    ) internal override {
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            L2_BASE_TOKEN_HOLDER.recoverBaseToken(_receiver, _amount, _chainId);
            return;
        }
        super._disburseFailedTransfer({
            _chainId: _chainId,
            _assetId: _assetId,
            _receiver: _receiver,
            _amount: _amount,
            _isNative: _isNative,
            _originToken: _originToken,
            _erc20Data: _erc20Data
        });
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL & HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the L2 asset router for internal use.
    function _assetRouter() internal view virtual override returns (IAssetRouterBase) {
        return IAssetRouterBase(L2_ASSET_ROUTER_ADDR);
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
        return WETH_TOKEN;
    }

    /// @notice Calculates L2 wrapped token address given the currently stored beacon proxy bytecode hash and beacon address.
    /// @param _tokenOriginChainId The chain id of the origin token.
    /// @param _nonNativeToken The address of token on its origin chain.
    /// @return Address of an L2 token counterpart.
    function calculateCreate2TokenAddress(
        uint256 _tokenOriginChainId,
        address _nonNativeToken
    ) public view virtual override returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(bridgedTokenBeacon), ""));
        bytes32 salt = _getCreate2Salt(_tokenOriginChainId, _nonNativeToken);
        return
            L2ContractHelper.computeCreate2Address(
                address(this),
                salt,
                L2_TOKEN_PROXY_BYTECODE_HASH,
                constructorInputHash
            );
    }

    /// @notice Calculates the salt for the Create2 deployment of the L2 token.
    function _getCreate2Salt(
        uint256 _tokenOriginChainId,
        address _l1Token
    ) internal view override returns (bytes32 salt) {
        salt = _tokenOriginChainId == L1_CHAIN_ID
            ? bytes32(uint256(uint160(_l1Token)))
            : keccak256(abi.encode(_tokenOriginChainId, _l1Token));
    }

    /// @dev Records the outbound flow (L2->L1 withdrawal or outgoing L2->L2 interop); see `bridgedOut`.
    /// @dev Note GW->L2 txs are not allowed. Even for GW, transactions go through L1,
    /// so L2NativeTokenVault doesn't have to handle balance changes on GW.
    function _handleBridgeToChain(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal virtual override {
        _trackLegacyTokenIfNeeded(_assetId);

        // On the L2 we only track the bridged-out amount of native tokens.
        if (originChainId[_assetId] == block.chainid) {
            bridgedOut[_assetId] += _amount;
        }

        // All chains are assumed to settle on L1, so every L1-destined withdrawal is recorded.
        if (_chainId == L1_CHAIN_ID) {
            interopInfo[_assetId].totalWithdrawalsToL1 += _amount;
        }
    }

    /// @dev Records the inbound flow (L1->L2 deposit or incoming L2->L2 interop finalization); see
    /// `bridgedOut`.
    /// @dev An inbound amount of a native token exceeding the outstanding bridged-out amount is only
    /// possible if bridged representations of the asset were forged somewhere upstream, so such a
    /// transfer is blocked rather than recorded.
    function _handleBridgeFromChain(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal virtual override {
        _trackLegacyTokenIfNeeded(_assetId);

        // On the L2 we only track the bridged-out amount of native tokens.
        if (originChainId[_assetId] == block.chainid) {
            if (bridgedOut[_assetId] < _amount) {
                revert InsufficientChainBalance(_chainId, _assetId, _amount);
            }
            bridgedOut[_assetId] -= _amount;
        }

        // All chains are assumed to settle on L1, so every L1-originated deposit is recorded.
        if (_chainId == L1_CHAIN_ID) {
            interopInfo[_assetId].totalSuccessfulDepositsFromL1 += _amount;
        }
    }

    /// @inheritdoc IL2NativeTokenVault
    /// @dev Anyone can call this to eagerly initialize the bookkeeping of a legacy token before its
    /// first post-upgrade bridge operation captures a stale snapshot.
    function trackLegacyToken(bytes32 _assetId) external {
        _trackLegacyTokenIfNeeded(_assetId);
    }

    /// @dev Initializes the chain-local bookkeeping for a token that is already registered in the
    /// vault but has not been tracked here yet (i.e. a token registered before this bookkeeping was
    /// introduced). Called before any balance changes of the bridge operation are performed, so the
    /// captured values reflect the pre-operation state.
    function _trackLegacyTokenIfNeeded(bytes32 _assetId) internal {
        if (isAssetTracked[_assetId]) {
            return;
        }
        // Note we assume that the token must be legacy, since `_registerTokenForTracking` marks any
        // newly registered token as tracked. Legacy tokens are all expected to have the origin chain
        // id and token address set on the vault.
        uint256 tokenOriginChainId = originChainId[_assetId];
        require(tokenOriginChainId != 0, AssetIdNotRegistered(_assetId));
        address token = tokenAddress[_assetId];
        require(token != address(0), AssetIdNotRegistered(_assetId));
        isAssetTracked[_assetId] = true;

        if (tokenOriginChainId == block.chainid) {
            // Seed the net bridged-out amount with the vault's current escrow: tokens locked here by
            // previous bridge operations are exactly the amount currently bridged out. Note, that this
            // treats tokens sent directly to the vault the same way as bridged-out ones. It is okay,
            // since the tokens that have been sent to the vault are basically frozen anyway.
            bridgedOut[_assetId] = IERC20(token).balanceOf(address(this));
        } else {
            // Save the pre-tracking supply for bridged legacy tokens. Note, that here we assume that
            // `totalSupply()` won't be affected in any way until it is used here, i.e. all deposits or
            // withdrawals should firstly record the previous totalSupply.
            preTrackingTotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: IERC20(token).totalSupply()});
        }
    }

    function _registerToken(address _nativeToken) internal override returns (bytes32) {
        return super._registerToken(_nativeToken);
    }

    /*//////////////////////////////////////////////////////////////
                            LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates L2 wrapped token address corresponding to L1 token counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return expectedToken The address of token on L2.
    function l2TokenAddress(address _l1Token) public view returns (address expectedToken) {
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        expectedToken = tokenAddress[expectedAssetId];
    }

    function _getOriginTokenFromAddress(address _token) internal view override returns (address) {
        if (_token == L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR) {
            return BASE_TOKEN_ORIGIN_TOKEN;
        }
        return super._getOriginTokenFromAddress(_token);
    }

    function _getERC20GettersInner(
        address _token,
        uint256 _originChainId
    ) internal view virtual override returns (bytes memory) {
        if (_token == L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR) {
            bytes memory name = abi.encode(BASE_TOKEN_NAME);
            bytes memory symbol = abi.encode(BASE_TOKEN_SYMBOL);
            bytes memory decimals = abi.encode(uint8(BASE_TOKEN_DECIMALS));
            return
                DataEncoding.encodeTokenData({
                    _chainId: _originChainId,
                    _name: name,
                    _symbol: symbol,
                    _decimals: decimals
                });
        }
        return super._getERC20GettersInner(_token, _originChainId);
    }
}
