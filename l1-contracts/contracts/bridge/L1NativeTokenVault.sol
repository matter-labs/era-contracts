// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
contract L1NativeTokenVault is IL1NativeTokenVault, IL1AssetHandler, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev L1 Shared Bridge smart contract that handles communication with its counterparts on L2s
    IL1SharedBridge public immutable override L1_SHARED_BRIDGE;

    /// @dev Era's chainID
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev A mapping assetId => tokenAddress
    mapping(bytes32 assetId => address tokenAddress) public tokenAddress;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridge() {
        require(msg.sender == address(L1_SHARED_BRIDGE), "NTV not ShB");
        _;
    }

    /// @notice Checks that the message sender is the shared bridge itself.
    modifier onlySelf() {
        require(msg.sender == address(this), "NTV only");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _l1WethAddress, IL1SharedBridge _l1SharedBridge, uint256 _eraChainId) {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        ERA_CHAIN_ID = _eraChainId;
        L1_SHARED_BRIDGE = _l1SharedBridge;
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy
    /// @param _owner Address which can change pause / unpause the NTV
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external initializer {
        require(_owner != address(0), "NTV owner 0");
        _transferOwnership(_owner);
    }

    /// @dev Accepts ether only from the Shared Bridge.
    receive() external payable {
        require(address(L1_SHARED_BRIDGE) == msg.sender, "NTV: ETH only accepted from Shared Bridge");
    }

    /// @dev Transfer tokens from shared bridge as part of migration process.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    function transferFundsFromSharedBridge(address _token) external {
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balanceBefore = address(this).balance;
            L1_SHARED_BRIDGE.transferTokenToNTV(_token);
            uint256 balanceAfter = address(this).balance;
            require(balanceAfter > balanceBefore, "NTV: 0 eth transferred");
        } else {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
            uint256 sharedBridgeChainBalance = IERC20(_token).balanceOf(address(L1_SHARED_BRIDGE));
            require(sharedBridgeChainBalance > 0, "NTV: 0 amount to transfer");
            L1_SHARED_BRIDGE.transferTokenToNTV(_token);
            uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
            require(balanceAfter - balanceBefore >= sharedBridgeChainBalance, "NTV: wrong amount transferred");
        }
    }

    /// @dev Set chain token balance as part of migration process.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    /// @param _targetChainId The chain ID of the corresponding ZK chain.
    function transferBalancesFromSharedBridge(address _token, uint256 _targetChainId) external {
        uint256 sharedBridgeChainBalance = L1_SHARED_BRIDGE.chainBalance(_targetChainId, _token);
        chainBalance[_targetChainId][_token] = chainBalance[_targetChainId][_token] + sharedBridgeChainBalance;
        L1_SHARED_BRIDGE.transferBalanceToNTV(_targetChainId, _token);
    }

    /// @dev We want to be able to bridge native tokens automatically, this means registering them on the fly
    /// @notice Allows the bridge to register a token address for the vault.
    /// @notice No access control is ok, since the bridging of tokens should be permissionless. This requires permissionless registration.
    function registerToken(address _l1Token) external {
        require(_l1Token != L1_WETH_TOKEN, "NTV: WETH deposit not supported");
        require(_l1Token == ETH_TOKEN_ADDRESS || _l1Token.code.length > 0, "NTV: empty token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_l1Token);
        L1_SHARED_BRIDGE.setAssetHandlerAddressInitial(bytes32(uint256(uint160(_l1Token))), address(this));
        tokenAddress[assetId] = _l1Token;
    }

    /// @inheritdoc IL1AssetHandler
    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev here _data is the _depositAmount and the _l2Receiver
    function bridgeBurn(
        uint256 _chainId,
        uint256,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridge whenNotPaused returns (bytes memory _bridgeMintData) {
        (uint256 _depositAmount, address _l2Receiver) = abi.decode(_data, (uint256, address));

        uint256 amount;
        address l1Token = tokenAddress[_assetId];
        if (l1Token == ETH_TOKEN_ADDRESS) {
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

            uint256 expectedDepositAmount = _depositFunds(_prevMsgSender, IERC20(l1Token), _depositAmount); // note if _prevMsgSender is this contract, this will return 0. This does not happen.
            require(expectedDepositAmount == _depositAmount, "5T"); // The token has non-standard transfer logic
        }
        require(amount != 0, "6T"); // empty deposit amount

        chainBalance[_chainId][l1Token] += amount;

        // solhint-disable-next-line func-named-parameters
        _bridgeMintData = DataEncoding.encodeBridgeMintData(
            amount,
            _prevMsgSender,
            _l2Receiver,
            getERC20Getters(l1Token),
            l1Token
        ); // solhint-disable-next-line func-named-parameters
        emit BridgeBurn(_chainId, _assetId, _prevMsgSender, _l2Receiver, amount);
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address.
    /// @return The difference between the contract balance before and after the transferring of funds.
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        address from = _from;
        // in the legacy scenario the SharedBridge was granting the allowance, we have to transfer from them instead of the user
        if (
            _token.allowance(address(L1_SHARED_BRIDGE), address(this)) >= _amount &&
            _token.allowance(_from, address(this)) < _amount
        ) {
            from = address(L1_SHARED_BRIDGE);
        }
        // slither-disable-next-line arbitrary-send-erc20
        _token.safeTransferFrom(from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token) public view returns (bytes memory) {
        if (_token == ETH_TOKEN_ADDRESS) {
            bytes memory name = abi.encode("Ether");
            bytes memory symbol = abi.encode("ETH");
            bytes memory decimals = abi.encode(uint8(18));
            return abi.encode(name, symbol, decimals); // when depositing eth to a non-eth based chain it is an ERC20
        }

        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return abi.encode(data1, data2, data3);
    }

    ///  @inheritdoc IL1AssetHandler
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable override onlyBridge whenNotPaused returns (address l1Receiver) {
        // here we are minting the tokens after the bridgeBurn has happened on an L2, so we can assume the l1Token is not zero
        address l1Token = tokenAddress[_assetId];
        uint256 amount;
        (amount, l1Receiver) = abi.decode(_data, (uint256, address));
        // Check that the chain has sufficient balance
        require(chainBalance[_chainId][l1Token] >= amount, "NTV not enough funds 2"); // not enough funds
        chainBalance[_chainId][l1Token] -= amount;

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1Receiver, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "NTV: withdrawal failed, no funds or cannot transfer to receiver");
        } else {
            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);
        }
        // solhint-disable-next-line func-named-parameters
        emit BridgeMint(_chainId, _assetId, l1Receiver, amount);
    }

    ///  @inheritdoc IL1AssetHandler
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override onlyBridge whenNotPaused {
        (uint256 _amount, ) = abi.decode(_data, (uint256, address));
        address l1Token = tokenAddress[_assetId];
        require(_amount > 0, "y1");

        // check that the chain has sufficient balance
        require(chainBalance[_chainId][l1Token] >= _amount, "NTV n funds");
        chainBalance[_chainId][l1Token] -= _amount;

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), _depositSender, _amount, 0, 0, 0, 0)
            }
            require(callSuccess, "NTV: claimFailedDeposit failed, no funds or cannot transfer to receiver");
        } else {
            IERC20(l1Token).safeTransfer(_depositSender, _amount);
            // Note we don't allow weth deposits anymore, but there might be legacy weth deposits.
            // until we add Weth bridging capabilities, we don't wrap/unwrap weth to ether.
        }
    }

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
