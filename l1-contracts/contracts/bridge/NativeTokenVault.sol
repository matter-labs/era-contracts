// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgedStandardToken} from "./interfaces/IBridgedStandardToken.sol";
import {INativeTokenVault} from "./interfaces/INativeTokenVault.sol";
import {IAssetHandler} from "./interfaces/IAssetHandler.sol";
import {IAssetRouterBase} from "./interfaces/IAssetRouterBase.sol";
import {IL1Nullifier} from "./interfaces/IL1Nullifier.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {BridgedStandardERC20} from "../common/BridgedStandardERC20.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../common/L2ContractAddresses.sol";
import {BridgeHelper} from "./BridgeHelper.sol";

import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";

import {EmptyAddress, EmptyBytes32, AddressMismatch, AssetIdMismatch, DeployFailed, AmountMustBeGreaterThanZero, InvalidCaller} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
abstract contract NativeTokenVault is INativeTokenVault, IAssetHandler, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public bridgedTokenBeacon;

    /// @dev The address of the WETH token.
    address public immutable override WETH_TOKEN;

    IL2SharedBridgeLegacy public immutable L2_LEGACY_SHARED_BRIDGE;

    /// @dev L1 Shared Bridge smart contract that handles communication with its counterparts on L2s
    IAssetRouterBase public immutable override ASSET_ROUTER;

    /// @dev The address of the WETH token.
    address public immutable override BASE_TOKEN_ADDRESS; // ToDo: would this work in terms of storage layout?

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev A mapping assetId => tokenAddress
    mapping(bytes32 assetId => address tokenAddress) public tokenAddress;

    /// @dev A mapping assetId => isTokenBridged
    mapping(bytes32 assetId => bool bridged) public isTokenBridged;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridge() {
        require(msg.sender == address(ASSET_ROUTER), "NTV not AR");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    /// @param _wethToken Address of WETH on deployed chain
    /// @param _baseTokenAddress Address of Base token
    constructor(address _wethToken, address _assetRouter, address _baseTokenAddress) {
        _disableInitializers();
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        WETH_TOKEN = _wethToken;
        BASE_TOKEN_ADDRESS = _baseTokenAddress;
    }

    /// @notice Sets token beacon used by bridged ERC20 tokens deployed by NTV.
    /// @dev we don't call this in the constructor, as we need to provide factory deps
    function setBridgedTokenBeacon() external {
        if (address(bridgedTokenBeacon) != address(0)) {
            revert AddressMismatch(address(bridgedTokenBeacon), address(0));
        }
        address bridgedStandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());
        bridgedTokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(bridgedStandardToken);
        bridgedTokenBeacon.transferOwnership(owner());
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy.
    /// @param _owner Address which can change pause / unpause the NTV.
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external initializer {
        require(_owner != address(0), "NTV owner 0");
        _transferOwnership(_owner);
    }

    /// @dev Accepts ether only from the Shared Bridge.
    receive() external payable {
        require(address(ASSET_ROUTER) == msg.sender, "NTV: ETH only accepted from Asset Router");
    }

    /// @notice Registers tokens within the NTV.
    /// @dev The goal was to allow bridging native tokens automatically, by registering them on the fly.
    /// @notice Allows the bridge to register a token address for the vault.
    /// @notice No access control is ok, since the bridging of tokens should be permissionless. This requires permissionless registration.
    function registerToken(address _nativeToken) external {
        require(_nativeToken != WETH_TOKEN, "NTV: WETH deposit not supported");
        require(_nativeToken == BASE_TOKEN_ADDRESS || _nativeToken.code.length > 0, "NTV: empty token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, _nativeToken);
        ASSET_ROUTER.setAssetHandlerAddressThisChain(bytes32(uint256(uint160(_nativeToken))), address(this));
        tokenAddress[assetId] = _nativeToken;
    }

    ///  @inheritdoc IAssetHandler
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external payable override onlyBridge whenNotPaused returns (address receiver) {
        // Either it was locked before, therefore is not zero, or it is sent from remote chain and standard erc20 will be deployed
        address token = tokenAddress[_assetId];
        uint256 amount;

        if (chainBalance[_chainId][token] > 0) {
            (amount, receiver) = abi.decode(_transferData, (uint256, address));
            // Check that the chain has sufficient balance
            require(chainBalance[_chainId][token] >= amount, "NTV not enough funds 2"); // not enough funds
            chainBalance[_chainId][token] -= amount;

            if (token == BASE_TOKEN_ADDRESS) {
                bool callSuccess;
                // Low-level assembly call, to avoid any memory copying (save gas)
                assembly {
                    callSuccess := call(gas(), receiver, amount, 0, 0, 0, 0)
                }
                require(callSuccess, "NTV: withdrawal failed, no funds or cannot transfer to receiver");
            } else {
                // Withdraw funds
                IERC20(token).safeTransfer(receiver, amount);
            }
            // solhint-disable-next-line func-named-parameters
            emit BridgeMint(_chainId, _assetId, receiver, amount);
        } else {
            bytes memory erc20Data;
            address originToken;

            (, amount, receiver, erc20Data, originToken) = abi.decode(
                _transferData,
                (address, uint256, address, bytes, address)
            );
            address expectedToken = bridgedTokenAddress(originToken);
            if (address(L2_LEGACY_SHARED_BRIDGE) != address(0)) {
                // l1LegacyToken = L2_LEGACY_SHARED_BRIDGE.l1TokenAddress(expectedToken); // kl todo
            }
            if (token == address(0)) {
                bytes32 expectedAssetId = keccak256(
                    abi.encode(_chainId, L2_NATIVE_TOKEN_VAULT_ADDRESS, bytes32(uint256(uint160(originToken))))
                );
                if (_assetId != expectedAssetId) {
                    // Make sure that a NativeTokenVault sent the message
                    revert AssetIdMismatch(_assetId, expectedAssetId);
                }
                address deployedToken = _deployBridgedToken(originToken, erc20Data);
                if (deployedToken != expectedToken) {
                    revert AddressMismatch(expectedToken, deployedToken);
                }
                isTokenBridged[_assetId] = true;
                tokenAddress[_assetId] = expectedToken;
            }

            IBridgedStandardToken(expectedToken).bridgeMint(receiver, amount);
        }
        emit BridgeMint(_chainId, _assetId, receiver, amount);
    }

    /// @inheritdoc IAssetHandler
    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev In case of native token vault _transferData is the tuple of _depositAmount and _receiver.
    function bridgeBurn(
        uint256 _chainId,
        uint256,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridge whenNotPaused returns (bytes memory _bridgeMintData) {
        if (isTokenBridged[_assetId]) {
            (uint256 _depositAmount, address _receiver) = abi.decode(_data, (uint256, address));

            uint256 amount;
            address nativeToken = tokenAddress[_assetId];
            if (nativeToken == BASE_TOKEN_ADDRESS) {
                amount = msg.value;

                // In the old SDK/contracts the user had to always provide `0` as the deposit amount for ETH token, while
                // ultimately the provided `msg.value` was used as the deposit amount. This check is needed for backwards compatibility.
                if (_depositAmount == 0) {
                    _depositAmount = amount;
                }

                require(_depositAmount == amount, "L1NTV: msg.value not equal to amount");
            } else {
                // The Bridgehub also checks this, but we want to be sure
                require(msg.value == 0, "NTV m.v > 0 b d.it");
                amount = _depositAmount;

                uint256 expectedDepositAmount = _depositFunds(_prevMsgSender, IERC20(nativeToken), _depositAmount); // note if _prevMsgSender is this contract, this will return 0. This does not happen.
                require(expectedDepositAmount == _depositAmount, "5T"); // The token has non-standard transfer logic
            }
            require(amount != 0, "6T"); // empty deposit amount

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
        } else {
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
    }

    /// @notice Transfers tokens from the depositor address to the smart contract address.
    /// @param _from The address of the depositor.
    /// @param _token The ERC20 token to be transferred.
    /// @param _amount The amount to be transferred.
    /// @return The difference between the contract balance before and after the transferring of funds.
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        address from = _from;
        // in the legacy scenario the SharedBridge was granting the allowance, we have to transfer from them instead of the user
        if (
            _token.allowance(address(ASSET_ROUTER), address(this)) >= _amount &&
            _token.allowance(_from, address(this)) < _amount
        ) {
            from = address(ASSET_ROUTER);
        }
        // slither-disable-next-line arbitrary-send-erc20
        _token.safeTransferFrom(from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @param _token The address of token of interest.
    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token) public view override returns (bytes memory) {
        return BridgeHelper.getERC20Getters(_token, BASE_TOKEN_ADDRESS);
    }

    /// @notice Returns the parsed assetId.
    /// @param _nativeToken The address of the token to be parsed.
    /// @dev Shows the assetId for a given chain and token address
    function getAssetId(uint256 _chainId, address _nativeToken) external pure override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(_chainId, _nativeToken);
    }

    /// @notice Calculates the bridged token address corresponding to native token counterpart.
    /// @param _nativeToken The address of native token.
    /// @return The address of bridged token.
    function bridgedTokenAddress(address _nativeToken) public view virtual override returns (address);

    /// @notice Deploys and initializes the bridged token for the native counterpart.
    /// @param _nativeToken The address of native token.
    /// @param _erc20Data The ERC20 metadata of the token deployed.
    /// @return The address of the beacon proxy (bridged token).
    function _deployBridgedToken(address _nativeToken, bytes memory _erc20Data) internal returns (address) {
        bytes32 salt = _getCreate2Salt(_nativeToken);

        BeaconProxy l2Token;
        if (address(L2_LEGACY_SHARED_BRIDGE) == address(0)) {
            // Deploy the beacon proxy for the L2 token
            l2Token = _deployBeaconProxy(salt);
        } else {
            // Deploy the beacon proxy for the L2 token
            address l2TokenAddr = L2_LEGACY_SHARED_BRIDGE.deployBeaconProxy(salt);
            l2Token = BeaconProxy(payable(l2TokenAddr));
        }
        BridgedStandardERC20(address(l2Token)).bridgeInitialize(_nativeToken, _erc20Data);

        return address(l2Token);
    }

    /// @notice Converts the L1 token address to the create2 salt of deployed L2 token.
    /// @param _l1Token The address of token on L1.
    /// @return salt The salt used to compute address of bridged token on L2 and for beacon proxy deployment.
    function _getCreate2Salt(address _l1Token) internal pure returns (bytes32 salt) {
        salt = bytes32(uint256(uint160(_l1Token)));
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
