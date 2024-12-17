// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IBridgedStandardToken} from "../interfaces/IBridgedStandardToken.sol";
import {INativeTokenVault} from "./INativeTokenVault.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {BridgedStandardERC20} from "../BridgedStandardERC20.sol";
import {BridgeHelper} from "../BridgeHelper.sol";

import {AssetIdAlreadyRegistered, DeployingBridgedTokenForNativeToken, EmptyDeposit, Unauthorized, TokensWithFeesNotSupported, TokenNotSupported, NonEmptyMsgValue, ValueMismatch, AddressMismatch, AssetIdMismatch, AmountMustBeGreaterThanZero, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {EmptyToken} from "../L1BridgeContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
abstract contract NativeTokenVault is INativeTokenVault, IAssetHandler, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token.
    address public immutable override WETH_TOKEN;

    /// @dev L1 Shared Bridge smart contract that handles communication with its counterparts on L2s
    IAssetRouterBase public immutable override ASSET_ROUTER;

    /// @dev The assetId of the base token.
    bytes32 public immutable BASE_TOKEN_ASSET_ID;

    /// @dev Chain ID of L1 for bridging reasons.
    uint256 public immutable L1_CHAIN_ID;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    IBeacon public bridgedTokenBeacon;

    /// @dev A mapping assetId => originChainId
    mapping(bytes32 assetId => uint256 originChainId) public originChainId;

    /// @dev A mapping assetId => tokenAddress
    mapping(bytes32 assetId => address tokenAddress) public tokenAddress;

    /// @dev A mapping tokenAddress => assetId
    mapping(address tokenAddress => bytes32 assetId) public assetId;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[46] private __gap;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyAssetRouter() {
        if (msg.sender != address(ASSET_ROUTER)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    /// @param _wethToken Address of WETH on deployed chain
    /// @param _assetRouter Address of assetRouter
    constructor(address _wethToken, address _assetRouter, bytes32 _baseTokenAssetId, uint256 _l1ChainId) {
        _disableInitializers();
        L1_CHAIN_ID = _l1ChainId;
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        WETH_TOKEN = _wethToken;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
    }

    /// @inheritdoc INativeTokenVault
    function registerToken(address _nativeToken) external virtual {
        _registerToken(_nativeToken);
    }

    function _registerToken(address _nativeToken) internal {
        if (_nativeToken == WETH_TOKEN) {
            revert TokenNotSupported(WETH_TOKEN);
        }
        if (_nativeToken.code.length == 0) {
            revert EmptyToken();
        }
        if (assetId[_nativeToken] != bytes32(0)) {
            revert AssetIdAlreadyRegistered();
        }
        _unsafeRegisterNativeToken(_nativeToken);
    }

    /// @inheritdoc INativeTokenVault
    function ensureTokenIsRegistered(address _nativeToken) public {
        if (assetId[_nativeToken] == bytes32(0)) {
            _registerToken(_nativeToken);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FINISH TRANSACTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetHandler
    /// @notice Used when the chain receives a transfer from L1 Shared Bridge and correspondingly mints the asset.
    /// @param _chainId The chainId that the message is from.
    /// @param _assetId The assetId of the asset being bridged.
    /// @param _data The abi.encoded transfer data.
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable override onlyAssetRouter whenNotPaused {
        address receiver;
        uint256 amount;
        // we set all originChainId for all already bridged tokens with the setLegacyTokenAssetId and updateChainBalancesFromSharedBridge functions.
        // for tokens that are bridged for the first time, the originChainId will be 0.
        if (originChainId[_assetId] == block.chainid) {
            (receiver, amount) = _bridgeMintNativeToken(_chainId, _assetId, _data);
        } else {
            (receiver, amount) = _bridgeMintBridgedToken(_chainId, _assetId, _data);
        }
        // solhint-disable-next-line func-named-parameters
        emit BridgeMint(_chainId, _assetId, receiver, amount);
    }

    function _bridgeMintBridgedToken(
        uint256 _originChainId,
        bytes32 _assetId,
        bytes calldata _data
    ) internal virtual returns (address receiver, uint256 amount) {
        // Either it was bridged before, therefore address is not zero, or it is first time bridging and standard erc20 will be deployed
        address token = tokenAddress[_assetId];
        bytes memory erc20Data;
        address originToken;
        // slither-disable-next-line unused-return
        (, receiver, originToken, amount, erc20Data) = DataEncoding.decodeBridgeMintData(_data);

        if (token == address(0)) {
            token = _ensureAndSaveTokenDeployed(_assetId, originToken, erc20Data);
        }
        _handleChainBalanceDecrease(_originChainId, _assetId, amount, false);
        IBridgedStandardToken(token).bridgeMint(receiver, amount);
        emit BridgeMint(_originChainId, _assetId, receiver, amount);
    }

    function _bridgeMintNativeToken(
        uint256 _originChainId,
        bytes32 _assetId,
        bytes calldata _data
    ) internal returns (address receiver, uint256 amount) {
        address token = tokenAddress[_assetId];
        // slither-disable-next-line unused-return
        (, receiver, , amount, ) = DataEncoding.decodeBridgeMintData(_data);

        _handleChainBalanceDecrease(_originChainId, _assetId, amount, true);
        _withdrawFunds(_assetId, receiver, token, amount);
        emit BridgeMint(_originChainId, _assetId, receiver, amount);
    }

    function _withdrawFunds(bytes32 _assetId, address _to, address _token, uint256 _amount) internal virtual;

    /*//////////////////////////////////////////////////////////////
                            Start transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetHandler
    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev In case of native token vault _data is the tuple of _depositAmount and _receiver.
    function bridgeBurn(
        uint256 _chainId,
        uint256,
        bytes32 _assetId,
        address _originalCaller,
        bytes calldata _data
    ) external payable override onlyAssetRouter whenNotPaused returns (bytes memory _bridgeMintData) {
        if (originChainId[_assetId] != block.chainid) {
            _bridgeMintData = _bridgeBurnBridgedToken(_chainId, _assetId, _originalCaller, _data);
        } else {
            _bridgeMintData = _bridgeBurnNativeToken({
                _chainId: _chainId,
                _assetId: _assetId,
                _originalCaller: _originalCaller,
                _depositChecked: false,
                _data: _data
            });
        }
    }

    function _bridgeBurnBridgedToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        bytes calldata _data
    ) internal returns (bytes memory _bridgeMintData) {
        (uint256 _amount, address _receiver) = abi.decode(_data, (uint256, address));
        if (_amount == 0) {
            // "Amount cannot be zero");
            revert AmountMustBeGreaterThanZero();
        }

        address bridgedToken = tokenAddress[_assetId];
        IBridgedStandardToken(bridgedToken).bridgeBurn(_originalCaller, _amount);
        _handleChainBalanceIncrease(_chainId, _assetId, _amount, false);

        emit BridgeBurn({
            chainId: _chainId,
            assetId: _assetId,
            sender: _originalCaller,
            receiver: _receiver,
            amount: _amount
        });
        bytes memory erc20Metadata;
        {
            // we set all originChainId for all already bridged tokens with the setLegacyTokenAssetId and updateChainBalancesFromSharedBridge functions.
            // for native tokens the originChainId is set when they register.
            uint256 originChainId = originChainId[_assetId];
            if (originChainId == 0) {
                revert ZeroAddress();
            }
            erc20Metadata = getERC20Getters(bridgedToken, originChainId);
        }
        address originToken;
        {
            originToken = IBridgedStandardToken(bridgedToken).originToken();
            if (originToken == address(0)) {
                revert ZeroAddress();
            }
        }

        _bridgeMintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _originalCaller,
            _remoteReceiver: _receiver,
            _originToken: originToken,
            _amount: _amount,
            _erc20Metadata: erc20Metadata
        });
    }

    function _bridgeBurnNativeToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        bool _depositChecked,
        bytes calldata _data
    ) internal virtual returns (bytes memory _bridgeMintData) {
        (uint256 _depositAmount, address _receiver) = abi.decode(_data, (uint256, address));

        uint256 amount;
        address nativeToken = tokenAddress[_assetId];
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            amount = msg.value;

            // In the old SDK/contracts the user had to always provide `0` as the deposit amount for ETH token, while
            // ultimately the provided `msg.value` was used as the deposit amount. This check is needed for backwards compatibility.
            if (_depositAmount == 0) {
                _depositAmount = amount;
            }
            _handleChainBalanceIncrease(_chainId, _assetId, amount, true);
            if (_depositAmount != amount) {
                revert ValueMismatch(_depositAmount, amount);
            }
        } else {
            // The Bridgehub also checks this, but we want to be sure
            if (msg.value != 0) {
                revert NonEmptyMsgValue();
            }
            amount = _depositAmount;
            _handleChainBalanceIncrease(_chainId, _assetId, amount, true);
            if (!_depositChecked) {
                uint256 expectedDepositAmount = _depositFunds(_originalCaller, IERC20(nativeToken), _depositAmount); // note if _originalCaller is this contract, this will return 0. This does not happen.
                // The token has non-standard transfer logic
                if (amount != expectedDepositAmount) {
                    revert TokensWithFeesNotSupported();
                }
            }
        }
        if (amount == 0) {
            // empty deposit amount
            revert EmptyDeposit();
        }

        bytes memory erc20Metadata;
        {
            erc20Metadata = getERC20Getters(nativeToken, originChainId[_assetId]);
        }
        _bridgeMintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _originalCaller,
            _remoteReceiver: _receiver,
            _originToken: nativeToken,
            _amount: amount,
            _erc20Metadata: erc20Metadata
        });

        emit BridgeBurn({
            chainId: _chainId,
            assetId: _assetId,
            sender: _originalCaller,
            receiver: _receiver,
            amount: amount
        });
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
        return BridgeHelper.getERC20Getters(_token, _originChainId);
    }

    /// @notice Registers a native token address for the vault.
    /// @dev It does not perform any checks for the correctnesss of the token contract.
    /// @param _nativeToken The address of the token to be registered.
    function _unsafeRegisterNativeToken(address _nativeToken) internal {
        bytes32 newAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _nativeToken);
        tokenAddress[newAssetId] = _nativeToken;
        assetId[_nativeToken] = newAssetId;
        originChainId[newAssetId] = block.chainid;
        ASSET_ROUTER.setAssetHandlerAddressThisChain(bytes32(uint256(uint160(_nativeToken))), address(this));
    }

    function _handleChainBalanceIncrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) internal virtual;

    function _handleChainBalanceDecrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) internal virtual;

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
            tokenOriginChainId = L1_CHAIN_ID;
        }
    }

    /// @notice Checks that the assetId is correct for the origin token and chain.
    function _assetIdCheck(uint256 _tokenOriginChainId, bytes32 _assetId, address _originToken) internal view {
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(_tokenOriginChainId, _originToken);
        if (_assetId != expectedAssetId) {
            // Make sure that a NativeTokenVault sent the message
            revert AssetIdMismatch(_assetId, expectedAssetId);
        }
    }

    function _ensureAndSaveTokenDeployedInner(
        uint256 _tokenOriginChainId,
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data,
        address _expectedToken
    ) internal {
        _assetIdCheck(_tokenOriginChainId, _assetId, _originToken);

        address deployedToken = _deployBridgedToken(_tokenOriginChainId, _assetId, _originToken, _erc20Data);
        if (deployedToken != _expectedToken) {
            revert AddressMismatch(_expectedToken, deployedToken);
        }

        tokenAddress[_assetId] = _expectedToken;
        assetId[_expectedToken] = _assetId;
    }

    /// @notice Calculates the bridged token address corresponding to native token counterpart.
    /// @param _tokenOriginChainId The chain id of the origin token.
    /// @param _bridgeToken The address of native token.
    /// @return The address of bridged token.
    function calculateCreate2TokenAddress(
        uint256 _tokenOriginChainId,
        address _bridgeToken
    ) public view virtual override returns (address);

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
        if (_tokenOriginChainId == block.chainid) {
            revert DeployingBridgedTokenForNativeToken();
        }
        bytes32 salt = _getCreate2Salt(_tokenOriginChainId, _originToken);

        BeaconProxy l2Token = _deployBeaconProxy(salt, _tokenOriginChainId);
        BridgedStandardERC20(address(l2Token)).bridgeInitialize(_assetId, _originToken, _erc20Data);

        originChainId[_assetId] = _tokenOriginChainId;
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

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
