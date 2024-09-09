// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

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
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";

import {BridgedStandardERC20} from "../BridgedStandardERC20.sol";
import {BridgeHelper} from "../BridgeHelper.sol";

import {EmptyDeposit, Unauthorized, TokensWithFeesNotSupported, TokenNotSupported, NonEmptyMsgValue, ValueMismatch, WithdrawFailed, InsufficientChainBalance, AddressMismatch, AssetIdMismatch, AmountMustBeGreaterThanZero} from "../../common/L1ContractErrors.sol";

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

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    IBeacon public bridgedTokenBeacon;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev A mapping assetId => tokenAddress
    mapping(bytes32 assetId => address tokenAddress) public tokenAddress;

    /// @dev A mapping assetId => isTokenBridged
    mapping(bytes32 assetId => bool bridged) public isTokenBridged; // kl todo should we have isTokenNativeInstead

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[47] private __gap;

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
    constructor(address _wethToken, address _assetRouter) {
        _disableInitializers();
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        WETH_TOKEN = _wethToken;
    }

    /// @notice Registers tokens within the NTV.
    /// @dev The goal was to allow bridging native tokens automatically, by registering them on the fly.
    /// @notice Allows the bridge to register a token address for the vault.
    /// @notice No access control is ok, since the bridging of tokens should be permissionless. This requires permissionless registration.
    function registerToken(address _nativeToken) external {
        if (_nativeToken == WETH_TOKEN) {
            revert TokenNotSupported(WETH_TOKEN);
        }
        require(_nativeToken == ETH_TOKEN_ADDRESS || _nativeToken.code.length > 0, "NTV: empty token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, _nativeToken);
        ASSET_ROUTER.setAssetHandlerAddressThisChain(bytes32(uint256(uint160(_nativeToken))), address(this));
        tokenAddress[assetId] = _nativeToken;
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
        // We use chainBalance too differentiate between native and bridged tokens.
        // Either it was locked before, therefore is not zero, or it is sent from remote chain and standard erc20 will be deployed
        // Note: if the chainBalance has not been migrated and is 0, then the assetId check will fail as the token's origin chain is not chain that sent the message.
        // Note: after interop is implemented this will not work.
        address token = tokenAddress[_assetId];
        address receiver;
        uint256 amount;
        if (chainBalance[_chainId][token] > 0) {
            // kl todo we will implement chainBalance for bridged tokens as well. Rewrite this.
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
            token = _ensureTokenDeployed(_originChainId, _assetId, originToken, erc20Data);
        }

        IBridgedStandardToken(token).bridgeMint(receiver, amount);
        emit BridgeMint(_originChainId, _assetId, receiver, amount);
    }

    function _bridgeMintNativeToken(
        uint256 _originChainId,
        bytes32 _assetId,
        bytes calldata _data
    ) internal returns (address receiver, uint256 amount) {
        address token = tokenAddress[_assetId];
        (amount, receiver) = abi.decode(_data, (uint256, address));
        // Check that the chain has sufficient balance
        if (chainBalance[_originChainId][token] < amount) {
            revert InsufficientChainBalance();
        }
        chainBalance[_originChainId][token] -= amount;

        if (token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), receiver, amount, 0, 0, 0, 0)
            }
            if (!callSuccess) {
                revert WithdrawFailed();
            }
        } else {
            // Withdraw funds
            IERC20(token).safeTransfer(receiver, amount);
        }
        emit BridgeMint(_originChainId, _assetId, receiver, amount);
    }

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
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyAssetRouter whenNotPaused returns (bytes memory _bridgeMintData) {
        if (isTokenBridged[_assetId]) {
            _bridgeMintData = _bridgeBurnBridgedToken(_chainId, _assetId, _prevMsgSender, _data);
        } else {
            _bridgeMintData = _bridgeBurnNativeToken({
                _chainId: _chainId,
                _assetId: _assetId,
                _prevMsgSender: _prevMsgSender,
                _depositChecked: false,
                _data: _data
            });
        }
    }

    function _bridgeBurnBridgedToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) internal returns (bytes memory _bridgeMintData) {
        (uint256 _amount, address _receiver) = abi.decode(_data, (uint256, address));
        if (_amount == 0) {
            // "Amount cannot be zero");
            revert AmountMustBeGreaterThanZero();
        }

        address bridgedToken = tokenAddress[_assetId];
        IBridgedStandardToken(bridgedToken).bridgeBurn(_prevMsgSender, _amount);

        emit BridgeBurn({
            chainId: _chainId,
            assetId: _assetId,
            sender: _prevMsgSender,
            receiver: _receiver,
            amount: _amount
        });
        _bridgeMintData = _data;
    }

    function _bridgeBurnNativeToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        bool _depositChecked,
        bytes calldata _data
    ) internal virtual returns (bytes memory _bridgeMintData) {
        (uint256 _depositAmount, address _receiver) = abi.decode(_data, (uint256, address));

        uint256 amount;
        address nativeToken = tokenAddress[_assetId];
        if (nativeToken == ETH_TOKEN_ADDRESS) {
            amount = msg.value;

            // In the old SDK/contracts the user had to always provide `0` as the deposit amount for ETH token, while
            // ultimately the provided `msg.value` was used as the deposit amount. This check is needed for backwards compatibility.
            if (_depositAmount == 0) {
                _depositAmount = amount;
            }

            if (_depositAmount != amount) {
                revert ValueMismatch(amount, msg.value);
            }
        } else {
            // The Bridgehub also checks this, but we want to be sure
            if (msg.value != 0) {
                revert NonEmptyMsgValue();
            }

            amount = _depositAmount;
            if (!_depositChecked) {
                uint256 expectedDepositAmount = _depositFunds(_prevMsgSender, IERC20(nativeToken), _depositAmount); // note if _prevMsgSender is this contract, this will return 0. This does not happen.
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

        chainBalance[_chainId][nativeToken] += amount;

        _bridgeMintData = DataEncoding.encodeBridgeMintData({
            _prevMsgSender: _prevMsgSender,
            _l2Receiver: _receiver,
            _l1Token: nativeToken,
            _amount: amount,
            _erc20Metadata: getERC20Getters(nativeToken)
        });

        emit BridgeBurn({
            chainId: _chainId,
            assetId: _assetId,
            sender: _prevMsgSender,
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
    function getERC20Getters(address _token) public view override returns (bytes memory) {
        return BridgeHelper.getERC20Getters(_token, ETH_TOKEN_ADDRESS);
    }

    /// @notice Returns the parsed assetId.
    /// @param _nativeToken The address of the token to be parsed.
    /// @dev Shows the assetId for a given chain and token address
    function getAssetId(uint256 _chainId, address _nativeToken) external pure override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(_chainId, _nativeToken);
    }

    /*//////////////////////////////////////////////////////////////
                            TOKEN DEPLOYER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _ensureTokenDeployed(
        uint256 _originChainId,
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data
    ) internal virtual returns (address expectedToken) {
        expectedToken = _assetIdCheck(_originChainId, _assetId, _originToken);
        _ensureTokenDeployedInner({
            _originChainId: _originChainId,
            _assetId: _assetId,
            _originToken: _originToken,
            _erc20Data: _erc20Data,
            _expectedToken: expectedToken
        });
    }

    function _assetIdCheck(
        uint256 _originChainId,
        bytes32 _assetId,
        address _originToken
    ) internal view returns (address expectedToken) {
        expectedToken = calculateCreate2TokenAddress(_originChainId, _originToken);
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(_originChainId, _originToken);
        if (_assetId != expectedAssetId) {
            // Make sure that a NativeTokenVault sent the message
            revert AssetIdMismatch(_assetId, expectedAssetId);
        }
    }

    function _ensureTokenDeployedInner(
        uint256 _originChainId,
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data,
        address _expectedToken
    ) internal {
        address deployedToken = _deployBridgedToken(_originChainId, _originToken, _erc20Data);
        if (deployedToken != _expectedToken) {
            revert AddressMismatch(_expectedToken, deployedToken);
        }

        isTokenBridged[_assetId] = true;
        tokenAddress[_assetId] = _expectedToken;
    }

    /// @notice Calculates the bridged token address corresponding to native token counterpart.
    /// @param _bridgeToken The address of native token.
    /// @return The address of bridged token.
    function calculateCreate2TokenAddress(
        uint256 _originChainId,
        address _bridgeToken
    ) public view virtual override returns (address);

    /// @notice Deploys and initializes the bridged token for the native counterpart.
    /// @param _nativeToken The address of native token.
    /// @param _erc20Data The ERC20 metadata of the token deployed.
    /// @return The address of the beacon proxy (bridged token).
    function _deployBridgedToken(
        uint256 _originChainId,
        address _nativeToken,
        bytes memory _erc20Data
    ) internal returns (address) {
        bytes32 salt = _getCreate2Salt(_originChainId, _nativeToken);

        BeaconProxy l2Token = _deployBeaconProxy(salt);
        BridgedStandardERC20(address(l2Token)).bridgeInitialize(_nativeToken, _erc20Data);

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
    function _deployBeaconProxy(bytes32 _salt) internal virtual returns (BeaconProxy proxy);

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
