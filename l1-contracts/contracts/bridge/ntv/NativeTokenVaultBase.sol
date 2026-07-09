// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IBridgedStandardToken} from "../interfaces/IBridgedStandardToken.sol";
import {INativeTokenVaultBase} from "./INativeTokenVaultBase.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "../asset-router/AssetRouterBase.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {BridgedStandardERC20} from "../BridgedStandardERC20.sol";
import {BridgeHelper} from "../BridgeHelper.sol";
import {L2_BASE_TOKEN_HOLDER} from "../../common/l2-helpers/L2ContractInterfaces.sol";

import {EmptyToken, TokenAlreadyInBridgedTokensList} from "../L1BridgeContractErrors.sol";
import {
    AddressMismatch,
    AmountMustBeGreaterThanZero,
    AssetIdAlreadyRegistered,
    AssetIdMismatch,
    BurningNativeWETHNotSupported,
    DeployingBridgedTokenForNativeToken,
    NonEmptyMsgValue,
    TokenNotLegacy,
    TokenNotSupported,
    TokensWithFeesNotSupported,
    Unauthorized,
    ValueMismatch,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";
import {AssetHandlerModifiers} from "../interfaces/AssetHandlerModifiers.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
abstract contract NativeTokenVaultBase is
    INativeTokenVaultBase,
    IAssetHandler,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    AssetHandlerModifiers
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _assetRouter() internal view virtual returns (IAssetRouterBase);

    function _l1ChainId() internal view virtual returns (uint256);

    function _baseTokenAssetId() internal view virtual returns (bytes32);

    function _wethToken() internal view virtual returns (address);
    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    IBeacon public bridgedTokenBeacon;

    /// @dev A mapping assetId => originChainId
    /// @dev It is assumed, that `originChainId`, `tokenAddress` and `assetId`
    /// mappings are always atomically populated
    mapping(bytes32 assetId => uint256 originChainId) public originChainId;

    /// @dev A mapping assetId => tokenAddress
    /// @dev It is assumed, that `originChainId`, `tokenAddress` and `assetId`
    /// mappings are always atomically populated
    mapping(bytes32 assetId => address tokenAddress) public tokenAddress;

    /// @dev A mapping tokenAddress => assetId
    /// @dev It is assumed, that `originChainId`, `tokenAddress` and `assetId`
    /// mappings are always atomically populated
    mapping(address tokenAddress => bytes32 assetId) public assetId;

    /// @dev The number of bridged tokens.
    uint256 public bridgedTokensCount;

    /// @dev The mapping of bridged tokens, count => assetId.
    /// @dev Note, that this mapping includes not only "bridged" assets, but also native ones
    /// that were bridged to the other chains as well. For L2 chains it does not include the "base token"
    /// system contract address.
    mapping(uint256 count => bytes32 assetId) public bridgedTokens;

    /// @dev Used to record the index of the bridged token in the bridgedTokens array.
    mapping(bytes32 assetId => uint256 tokenIndex) public tokenIndex;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[43] private __gap;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyAssetRouter() {
        require(msg.sender == address(_assetRouter()), Unauthorized(msg.sender));
        _;
    }

    function originToken(bytes32 _assetId) public view virtual returns (address) {
        address token = tokenAddress[_assetId];
        if (token == address(0)) {
            return address(0);
        }
        if (originChainId[_assetId] == block.chainid) {
            return token;
        } else {
            return _getOriginTokenFromAddress(token);
        }
    }

    function _getOriginTokenFromAddress(address _token) internal view virtual returns (address) {
        return IBridgedStandardToken(_token).originToken();
    }

    /// @inheritdoc INativeTokenVaultBase
    function registerToken(address _nativeToken) external virtual {
        _registerToken(_nativeToken);
    }

    function _registerToken(address _nativeToken) internal virtual returns (bytes32 newAssetId) {
        // We allow registering `_wethToken()` inside `NativeTokenVault` only for L1 native token vault.
        // It is needed to allow withdrawing such assets. We restrict all WETH-related
        // operations to deposits from L1 only to be able to upgrade their logic more easily in the
        // future.
        require(_nativeToken != _wethToken() || block.chainid == _l1ChainId(), TokenNotSupported(_wethToken()));
        require(_nativeToken.code.length > 0, EmptyToken());
        require(assetId[_nativeToken] == bytes32(0), AssetIdAlreadyRegistered());
        newAssetId = _unsafeRegisterNativeToken(_nativeToken);
    }

    /// @inheritdoc INativeTokenVaultBase
    function ensureTokenIsRegistered(address _nativeToken) public returns (bytes32 tokenAssetId) {
        bytes32 currentAssetId = assetId[_nativeToken];
        if (currentAssetId == bytes32(0)) {
            tokenAssetId = _registerToken(_nativeToken);
        } else {
            tokenAssetId = currentAssetId;
        }
    }

    /// @notice Adds a legacy token to the bridged tokens list.
    /// @dev This function is used to add a legacy token to the bridged tokens list.
    /// @param _token The address of the token to be added to the bridged tokens list.
    function addLegacyTokenToBridgedTokensList(address _token) external {
        bytes32 tokenAssetId = assetId[_token];
        if (tokenAssetId == bytes32(0)) {
            revert TokenNotLegacy();
        }
        uint256 index = tokenIndex[tokenAssetId];
        if (index != 0 || (index == 0 && bridgedTokens[index] == tokenAssetId)) {
            revert TokenAlreadyInBridgedTokensList();
        }
        _addTokenToTokensList(tokenAssetId);
    }

    function _addTokenToTokensList(bytes32 _tokenAssetId) internal {
        bridgedTokens[bridgedTokensCount] = _tokenAssetId;
        tokenIndex[_tokenAssetId] = bridgedTokensCount;
        ++bridgedTokensCount;
    }

    /*//////////////////////////////////////////////////////////////
                            FINISH TRANSACTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetHandler
    /// @notice Used when the chain receives a transfer from another chain's Asset Router and correspondingly mints the asset.
    /// @param _chainId The chainId that the message is from.
    /// @param _assetId The assetId of the asset being bridged.
    /// @param _data The abi.encoded transfer data.
    /// @dev Note, the `_data` is provided by the potentially malicious `_chainId`. The best way to treat
    /// the security of this function is "_chainId sent a message that _assetId needs to be minted with _data".
    /// The following checks are applied to ensure safety:
    /// - assetIdcheck must be performed. It does not verify the metadata.
    /// - metadata not being verified is a known issue and will be addressed in the future releases. In the short term, we only expect
    /// chains with decently trusted chain type managers. This issue might affect the user experience, but never lead
    /// to loss of funds.
    /// - Correctness of the minted amounts is guaranteed by the ZK proofs of the sending chain
    /// (plus 2FA on ZKsync OS chains); there is no on-chain per-chain balance enforcement.
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter whenNotPaused {
        address receiver;
        uint256 amount;
        // we set all originChainId for all already bridged tokens with the setLegacyTokenAssetId and updateChainBalancesFromSharedBridge functions.
        // for tokens that are bridged for the first time, the originChainId will be 0.
        (receiver, amount) = _bridgeMintToken(_chainId, _assetId, _data);
        // solhint-disable-next-line func-named-parameters
        emit BridgeMint(_chainId, _assetId, receiver, amount);
    }

    /// @inheritdoc INativeTokenVaultBase
    /// @dev Refunds the original depositor (the burn data's `originalCaller`) by unlocking an
    /// origin-native asset or re-minting a bridged one, reversing the `bridgeBurn` that locked/burned the
    /// funds at `commitSend`. The bundle's mint data is forwarded verbatim, so the refund always targets
    /// the depositor regardless of the data's `remoteReceiver`. `_chainId` must be the destination chain
    /// used at burn time so `_handleBridgeFromChain` undoes the matching `_handleBridgeToChain`.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter whenNotPaused {
        // slither-disable-next-line unused-return
        (address originalCaller, , address originTokenAddress, uint256 amount, bytes memory erc20Data) = DataEncoding
            .decodeBridgeMintData(_data);
        bool isNative = originChainId[_assetId] == block.chainid;
        _disburseFailedTransfer({
            _chainId: _chainId,
            _assetId: _assetId,
            _receiver: originalCaller,
            _amount: amount,
            _isNative: isNative,
            _originToken: originTokenAddress,
            _erc20Data: erc20Data
        });
        // solhint-disable-next-line func-named-parameters
        emit BridgeRecoverFailedTransfer(_chainId, _assetId, originalCaller, amount);
    }

    /// @inheritdoc INativeTokenVaultBase
    /// @dev Reuses {_disburseFailedTransfer} for the different-base-token atomic-interop refund path. The
    /// base-token deposit (`bridgehubDepositBaseToken`) burned `_amount` of `_assetId` from the depositor
    /// without keeping bridge-mint data, so we reconstruct the disburse from primitives: the asset is
    /// already registered (it was burned from the depositor), hence the origin-token/erc20 params are dead.
    function bridgeRecoverBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _receiver,
        uint256 _amount
    ) external override onlyAssetRouter whenNotPaused {
        _disburseFailedTransfer({
            _chainId: _chainId,
            _assetId: _assetId,
            _receiver: _receiver,
            _amount: _amount,
            _isNative: originChainId[_assetId] == block.chainid,
            _originToken: address(0),
            _erc20Data: ""
        });
        // solhint-disable-next-line func-named-parameters
        emit BridgeRecoverFailedTransfer(_chainId, _assetId, _receiver, _amount);
    }

    /// @notice Mints/releases a bridged-in asset to the receiver and decreases the chain balance.
    /// @dev Unifies the native and bridged-token paths. A bridged token is minted (and deployed on first
    /// bridging if needed); a native token's escrowed funds are released via `_withdrawFunds`.
    /// @dev `_isBridgedToken` is derived from `originChainId` rather than passed in, to keep the stack small
    /// enough for the zksolc compiler (which is stricter than solc about stack depth).
    function _bridgeMintToken(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) internal returns (address receiver, uint256 amount) {
        bool _isBridgedToken = originChainId[_assetId] != block.chainid;
        // Either it was bridged before, therefore address is not zero, or it is first time bridging and standard erc20 will be deployed
        address token = tokenAddress[_assetId];
        address originToken;
        bytes memory erc20Data;
        // slither-disable-next-line unused-return
        (, receiver, originToken, amount, erc20Data) = DataEncoding.decodeBridgeMintData(_data);

        if (_isBridgedToken && token == address(0)) {
            token = _ensureAndSaveTokenDeployed(_assetId, originToken, erc20Data);
        }

        // IMPORTANT: We must handle chain balance decrease before giving out funds to the user,
        // because otherwise the latter operation (via a malicious token or ETH recipient)
        // could've overwritten the transient values from L1Nullifier.
        _handleBridgeFromChain({_chainId: _chainId, _assetId: _assetId, _amount: amount});

        if (_isBridgedToken) {
            IBridgedStandardToken(token).bridgeMint(receiver, amount);
        } else {
            _withdrawFunds(_assetId, receiver, token, amount);
        }
    }

    function _withdrawFunds(bytes32 _assetId, address _to, address _token, uint256 _amount) internal virtual;

    /// @notice Disburses a failed/recovered transfer's funds to `_receiver`, reversing the source-side
    /// `bridgeBurn` that locked/burned them.
    /// @dev Shared by `bridgeRecoverFailedTransfer` (atomic-interop recovery) and the L1
    /// `bridgeConfirmTransferResult` (failed-deposit claim). The chain balance is decreased before any
    /// funds are released, mirroring the `_bridgeMint*` ordering, so a malicious token/ETH recipient cannot
    /// overwrite the transient values from L1Nullifier.
    /// @param _chainId The chain the funds are being recovered from (the burn-time destination chain).
    /// @param _assetId The assetId of the asset being recovered.
    /// @param _receiver The address that receives the recovered funds (always the original depositor).
    /// @param _amount The amount to recover.
    /// @param _isNative Whether `_assetId` is native to this chain (unlock) or bridged (re-mint).
    /// @param _originToken The origin token address, used to deploy the bridged token if it is not yet known.
    /// @param _erc20Data The ERC20 metadata, used to deploy the bridged token if it is not yet known.
    function _disburseFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _receiver,
        uint256 _amount,
        bool _isNative,
        address _originToken,
        bytes memory _erc20Data
    ) internal {
        // IMPORTANT: We must handle chain balance decrease before giving out funds to the user,
        // because otherwise the latter operation (via a malicious token or ETH recipient)
        // could've overwritten the transient values from L1Nullifier.
        _handleBridgeFromChain({_chainId: _chainId, _assetId: _assetId, _amount: _amount});
        if (_isNative) {
            _withdrawFunds(_assetId, _receiver, tokenAddress[_assetId], _amount);
        } else {
            address token = tokenAddress[_assetId];
            if (token == address(0)) {
                token = _ensureAndSaveTokenDeployed(_assetId, _originToken, _erc20Data);
            }
            IBridgedStandardToken(token).bridgeMint(_receiver, _amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Start transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetHandler
    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev In case of native token vault _data is the tuple of _depositAmount and _receiver.
    function bridgeBurn(
        uint256 _chainId,
        uint256 _l2MsgValue,
        bytes32 _assetId,
        address _originalCaller,
        bytes calldata _data
    )
        external
        payable
        override
        requireZeroValue(_l2MsgValue)
        onlyAssetRouter
        whenNotPaused
        returns (bytes memory _bridgeMintData)
    {
        (uint256 amount, address receiver, address tokenAddress) = _decodeBurnAndCheckAssetId(_data, _assetId);
        _bridgeMintData = _bridgeBurnToken({
            _chainId: _chainId,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _amount: amount,
            _receiver: receiver,
            _tokenAddress: tokenAddress
        });
    }

    function tryRegisterTokenFromBurnData(bytes calldata _burnData, bytes32 _expectedAssetId) external {
        // slither-disable-next-line unused-return
        (, , address tokenAddress) = DataEncoding.decodeBridgeBurnData(_burnData);

        require(tokenAddress != address(0), ZeroAddress());

        bytes32 storedAssetId = assetId[tokenAddress];
        require(storedAssetId == bytes32(0), AssetIdAlreadyRegistered());

        // This token has not been registered within this NTV yet. This means that the
        // token is native to the chain and the user would prefer to get it registered as such.
        bytes32 newAssetId = _registerToken(tokenAddress);

        require(newAssetId == _expectedAssetId, AssetIdMismatch(_expectedAssetId, newAssetId));
    }

    function _decodeBurnAndCheckAssetId(
        bytes calldata _data,
        bytes32 _suppliedAssetId
    ) internal view returns (uint256 amount, address receiver, address parsedTokenAddress) {
        (amount, receiver, parsedTokenAddress) = DataEncoding.decodeBridgeBurnData(_data);

        if (parsedTokenAddress == address(0)) {
            // This means that the user wants the native token vault to resolve the
            // address. In this case, it is assumed that the assetId is already registered.
            parsedTokenAddress = tokenAddress[_suppliedAssetId];
        }

        // If it is still zero, it means that the token has not been registered.
        require(parsedTokenAddress != address(0), ZeroAddress());

        bytes32 storedAssetId = assetId[parsedTokenAddress];
        require(_suppliedAssetId == storedAssetId, AssetIdMismatch(storedAssetId, _suppliedAssetId));
    }

    /// @notice Burns an asset on the source chain and produces the bridge-mint data for the destination.
    /// @dev Unifies the native and bridged-token paths; they only differ in the WETH guard (native only),
    /// the metadata flag, and how the origin token is resolved.
    /// @dev `_isBridgedToken` is derived from `originChainId` rather than passed in, and the ERC20 metadata is
    /// inlined, to keep the stack small enough for the zksolc compiler (stricter than solc about stack depth).
    function _bridgeBurnToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount,
        address _receiver,
        address _tokenAddress
    ) internal returns (bytes memory _bridgeMintData) {
        bool _isBridgedToken = originChainId[_assetId] != block.chainid;
        require(_amount != 0, AmountMustBeGreaterThanZero());

        if (!_isBridgedToken) {
            // This ensures that WETH_TOKEN can never be bridged from chains it is native to.
            // It can only be withdrawn from the chain where it has already gotten.
            require(_tokenAddress != _wethToken(), BurningNativeWETHNotSupported());
        }

        _getTokenAndBridgeToChain({
            _isBridgedToken: _isBridgedToken,
            _tokenAddress: _tokenAddress,
            _depositAmount: _amount,
            _chainId: _chainId,
            _assetId: _assetId,
            _originalCaller: _originalCaller
        });
        /// Note L2->L2 asset transfers will accrue a fee in some form in later versions.

        // For native tokens the origin token is the token itself; for bridged tokens it must be resolved.
        address originToken = _tokenAddress;
        if (_isBridgedToken) {
            originToken = _getOriginTokenFromAddress(_tokenAddress);
            require(originToken != address(0), ZeroAddress());
        }

        _bridgeMintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _originalCaller,
            _remoteReceiver: _receiver,
            _originToken: originToken,
            _amount: _amount,
            _erc20Metadata: _getERC20Metadata(_tokenAddress, _assetId, _isBridgedToken)
        });

        emit BridgeBurn({
            chainId: _chainId,
            assetId: _assetId,
            sender: _originalCaller,
            receiver: _receiver,
            amount: _amount
        });
    }

    function _getERC20Metadata(
        address _token,
        bytes32 _assetId,
        bool _bridgedToken
    ) internal view virtual returns (bytes memory) {
        uint256 originChainId = originChainId[_assetId];
        if (_bridgedToken) {
            // we set all originChainId for all already bridged tokens with the setLegacyTokenAssetId and updateChainBalancesFromSharedBridge functions.
            // for native tokens the originChainId is set when they register.
            require(originChainId != 0, ZeroAddress());
        }
        return getERC20Getters(_token, originChainId);
    }

    function _getTokenAndBridgeToChain(
        bool _isBridgedToken,
        address _tokenAddress,
        uint256 _depositAmount,
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller
    ) internal {
        // Note, that in order to track `totalPreV31TotalSupply` correctly in L2AssetTracker,
        // we have to call _handleBridgeToChain before any balance changes will be performed.
        if (_assetId == _baseTokenAssetId()) {
            require(_depositAmount == msg.value, ValueMismatch(_depositAmount, msg.value));
            if (_isBridgedToken) {
                // This is the interop/asset-router case where this chain's base token is being
                // bridged to a chain with a different base token. NTV still has to produce the
                // bridge burn data for the asset-router flow, but the actual source-side base
                // token burn/accounting goes through BaseTokenHolder.
                L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: msg.value}(_chainId);
            } else {
                /// This is  only the case on L1, on L2 the base token is always bridged.
                _handleBridgeToChain(_chainId, _assetId, _depositAmount);
            }
        } else {
            _handleBridgeToChain(_chainId, _assetId, _depositAmount);
            require(msg.value == 0, NonEmptyMsgValue());
            if (_isBridgedToken) {
                IBridgedStandardToken(_tokenAddress).bridgeBurn(_originalCaller, _depositAmount);
            } else {
                uint256 expectedDepositAmount = _depositFunds(_originalCaller, IERC20(_tokenAddress), _depositAmount); // note if _originalCaller is this contract, this will return 0. This does not happen.
                // The token has non-standard transfer logic
                require(_depositAmount == expectedDepositAmount, TokensWithFeesNotSupported());
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL & HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers tokens from the depositor address to the smart contract address.
    /// @param _from The address of the depositor.
    /// @param _token The ERC20 token to be transferred.
    /// @param _amount The amount to be transferred.
    /// @return The difference between the contract balance before and after the transferring of funds.
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal virtual returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        // slither-disable-next-line arbitrary-send-erc20
        _token.safeTransferFrom(_from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @param _token The address of token of interest.
    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token, uint256 _originChainId) public view override returns (bytes memory) {
        return _getERC20GettersInner(_token, _originChainId);
    }

    function _getERC20GettersInner(
        address _token,
        uint256 _originChainId
    ) internal view virtual returns (bytes memory) {
        return BridgeHelper.getERC20Getters(_token, _originChainId);
    }

    /// @notice Registers a native token address for the vault.
    /// @dev It does not perform any checks for the correctnesss of the token contract.
    /// @param _nativeToken The address of the token to be registered.
    function _unsafeRegisterNativeToken(address _nativeToken) internal returns (bytes32 newAssetId) {
        newAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _nativeToken);
        _setNewTokenStorage(newAssetId, _nativeToken, block.chainid);
        AssetRouterBase(address(_assetRouter())).setAssetHandlerAddressThisChain(
            bytes32(uint256(uint160(_nativeToken))),
            address(this)
        );
    }

    /// @dev Chain-local bookkeeping hook invoked when funds are bridged out towards `_chainId`.
    /// @dev On L2 this records outbound amounts in the L2AssetTracker; on L1 it increases the
    /// net `bridgedOut` amount of L1-native tokens.
    function _handleBridgeToChain(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal virtual;

    /// @dev Chain-local bookkeeping hook invoked when funds bridged from `_chainId` are finalized here.
    /// @dev On L2 this records inbound amounts in the L2AssetTracker; on L1 it decreases the
    /// net `bridgedOut` amount of L1-native tokens.
    function _handleBridgeFromChain(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal virtual;

    /*//////////////////////////////////////////////////////////////
                            TOKEN DEPLOYER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _ensureAndSaveTokenDeployed(
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data
    ) internal virtual returns (address expectedToken) {
        uint256 tokenOriginChainId;
        (expectedToken, tokenOriginChainId) = _calculateExpectedTokenAddress(_originToken, _erc20Data);
        _ensureAndSaveTokenDeployedInner({
            _tokenOriginChainId: tokenOriginChainId,
            _assetId: _assetId,
            _originToken: _originToken,
            _erc20Data: _erc20Data,
            _expectedToken: expectedToken
        });
    }

    /// @notice Calculates the bridged token address corresponding to native token counterpart.
    function _calculateExpectedTokenAddress(
        address _originToken,
        bytes memory _erc20Data
    ) internal view returns (address expectedToken, uint256 tokenOriginChainId) {
        /// @dev calling externally to convert from memory to calldata
        tokenOriginChainId = this.tokenDataOriginChainId(_erc20Data);
        expectedToken = calculateCreate2TokenAddress(tokenOriginChainId, _originToken);
    }

    /// @notice Returns the origin chain id from the token data.
    function tokenDataOriginChainId(bytes calldata _erc20Data) public view returns (uint256 tokenOriginChainId) {
        // slither-disable-next-line unused-return
        (tokenOriginChainId, , , ) = DataEncoding.decodeTokenData(_erc20Data);
        if (tokenOriginChainId == 0) {
            tokenOriginChainId = _l1ChainId();
        }
    }

    function _ensureAndSaveTokenDeployedInner(
        uint256 _tokenOriginChainId,
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data,
        address _expectedToken
    ) internal {
        DataEncoding.assetIdCheck(_tokenOriginChainId, _assetId, _originToken);

        address deployedToken = _deployBridgedToken(_tokenOriginChainId, _assetId, _originToken, _erc20Data);
        require(deployedToken == _expectedToken, AddressMismatch(_expectedToken, deployedToken));

        _setNewTokenStorage(_assetId, _expectedToken, _tokenOriginChainId);
    }

    function _setNewTokenStorage(bytes32 _assetId, address _tokenAddress, uint256 _originChainId) internal {
        tokenAddress[_assetId] = _tokenAddress;
        assetId[_tokenAddress] = _assetId;
        originChainId[_assetId] = _originChainId;
        _addTokenToTokensList(_assetId);
        // Note, that it might be possible that the token is registered on the asset tracker, but not on the
        // native token vault. An example is when a token is automatically registered for a token that is native to L2
        // (i.e. registration got triggered, but the native token vault was never called since there was no actual
        // withdrawal of the asset).
        _registerTokenInAssetTracker(_assetId, _originChainId);
    }

    /// @dev Registers the token in the chain-local asset tracker, if one exists.
    /// @dev On L2 this records the token in the L2AssetTracker (total-supply / outbound bookkeeping).
    /// On L1 there is no asset tracker, so the default implementation is a no-op.
    // solhint-disable-next-line no-empty-blocks
    function _registerTokenInAssetTracker(bytes32 _assetId, uint256 _originChainId) internal virtual {}

    /// @notice Calculates the bridged token address corresponding to native token counterpart.
    /// @param _tokenOriginChainId The chain id of the origin token.
    /// @param _bridgeToken The address of native token.
    /// @return The address of bridged token.
    function calculateCreate2TokenAddress(
        uint256 _tokenOriginChainId,
        address _bridgeToken
    ) public view virtual returns (address);

    /// @notice Deploys and initializes the bridged token for the native counterpart.
    /// @param _tokenOriginChainId The chain id of the origin token.
    /// @param _originToken The address of origin token.
    /// @param _erc20Data The ERC20 metadata of the token deployed.
    /// @return The address of the beacon proxy (bridged token).
    function _deployBridgedToken(
        uint256 _tokenOriginChainId,
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data
    ) internal returns (address) {
        require(_tokenOriginChainId != block.chainid, DeployingBridgedTokenForNativeToken());
        bytes32 salt = _getCreate2Salt(_tokenOriginChainId, _originToken);

        BeaconProxy l2Token = _deployBeaconProxy(salt, _tokenOriginChainId);
        BridgedStandardERC20(address(l2Token)).bridgeInitialize(_assetId, _originToken, _erc20Data);

        return address(l2Token);
    }

    /// @notice Converts the L1 token address to the create2 salt of deployed L2 token.
    /// @param _l1Token The address of token on L1.
    /// @return salt The salt used to compute address of bridged token on L2 and for beacon proxy deployment.
    function _getCreate2Salt(uint256 _originChainId, address _l1Token) internal view virtual returns (bytes32 salt) {
        salt = keccak256(abi.encode(_originChainId, _l1Token));
    }

    /// @notice Deploys the beacon proxy for the bridged token.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `l2TokenProxyBytecodeHash` is used
    /// for the code of the proxy.
    /// @param _salt The salt used for beacon proxy deployment of the bridged token (we pass the native token address).
    /// @return proxy The beacon proxy, i.e. bridged token.
    function _deployBeaconProxy(
        bytes32 _salt,
        uint256 _tokenOriginChainId
    ) internal virtual returns (BeaconProxy proxy);

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @dev This pausability is inherited by both L1 and L2 vaults through the shared base.
    /// @dev On L1 it is part of the emergency controls for asset movement.
    /// On L2 it is kept only for legacy/shared-code reasons and should not be used as an emergency mechanism.
    /// Future L2 logic should rely on the L1/GW freeze flow instead of local pausability.
    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
