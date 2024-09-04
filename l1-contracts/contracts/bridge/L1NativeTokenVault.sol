// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IL1AssetRouter} from "./interfaces/IL1AssetRouter.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {EthOnlyAcceptedFromSharedBridge, ZeroAmountToTransfer, WrongAmountTransferred, EmptyToken, ClaimFailedDepositFailed} from "./L1BridgeContractErrors.sol";

import {BridgeHelper} from "./BridgeHelper.sol";

import {Unauthorized, ZeroAddress, NoFundsTransferred, ValueMismatch, TokensWithFeesNotSupported, NonEmptyMsgValue, TokenNotSupported, EmptyDeposit, InsufficientChainBalance, WithdrawFailed} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
contract L1NativeTokenVault is IL1NativeTokenVault, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev L1 Shared Bridge smart contract that handles communication with its counterparts on L2s
    IL1AssetRouter public immutable override L1_SHARED_BRIDGE;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev A mapping assetId => tokenAddress
    mapping(bytes32 assetId => address tokenAddress) public tokenAddress;

    /// @notice Checks that the message sender is the bridge.
    modifier onlyBridge() {
        if (msg.sender != address(L1_SHARED_BRIDGE)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _l1WethAddress, IL1AssetRouter _l1SharedBridge) {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        L1_SHARED_BRIDGE = _l1SharedBridge;
    }

    /// @dev Accepts ether only from the Shared Bridge.
    receive() external payable {
        if (address(L1_SHARED_BRIDGE) != msg.sender) {
            revert EthOnlyAcceptedFromSharedBridge();
        }
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy
    /// @param _owner Address which can change pause / unpause the NTV
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_owner);
    }

    /// @notice Transfers tokens from shared bridge as part of the migration process.
    /// @dev Both ETH and ERC20 tokens can be transferred. Exhausts balance of shared bridge after the first call.
    /// @dev Calling second time for the same token will revert.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    function transferFundsFromSharedBridge(address _token) external {
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balanceBefore = address(this).balance;
            L1_SHARED_BRIDGE.transferTokenToNTV(_token);
            uint256 balanceAfter = address(this).balance;
            if (balanceAfter <= balanceBefore) {
                revert NoFundsTransferred();
            }
        } else {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
            uint256 sharedBridgeChainBalance = IERC20(_token).balanceOf(address(L1_SHARED_BRIDGE));
            if (sharedBridgeChainBalance <= 0) {
                revert ZeroAmountToTransfer();
            }
            L1_SHARED_BRIDGE.transferTokenToNTV(_token);
            uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
            if (balanceAfter - balanceBefore < sharedBridgeChainBalance) {
                revert WrongAmountTransferred();
            }
        }
    }

    /// @notice Updates chain token balance within NTV to account for tokens transferred from the shared bridge (part of the migration process).
    /// @dev Clears chain balance on the shared bridge after the first call. Subsequent calls will not affect the state.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    /// @param _targetChainId The chain ID of the corresponding ZK chain.
    function updateChainBalancesFromSharedBridge(address _token, uint256 _targetChainId) external {
        uint256 sharedBridgeChainBalance = L1_SHARED_BRIDGE.chainBalance(_targetChainId, _token);
        chainBalance[_targetChainId][_token] = chainBalance[_targetChainId][_token] + sharedBridgeChainBalance;
        L1_SHARED_BRIDGE.nullifyChainBalanceByNTV(_targetChainId, _token);
    }

    /// @notice Registers tokens within the NTV.
    /// @dev The goal was to allow bridging L1 native tokens automatically, by registering them on the fly.
    /// @notice Allows the bridge to register a token address for the vault.
    /// @notice No access control is ok, since the bridging of tokens should be permissionless. This requires permissionless registration.
    function registerToken(address _l1Token) external {
        if (_l1Token == L1_WETH_TOKEN) {
            revert TokenNotSupported(L1_WETH_TOKEN);
        }
        if (_l1Token != ETH_TOKEN_ADDRESS && _l1Token.code.length <= 0) {
            revert EmptyToken();
        }
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, _l1Token);
        L1_SHARED_BRIDGE.setAssetHandlerAddressThisChain(bytes32(uint256(uint160(_l1Token))), address(this));
        tokenAddress[assetId] = _l1Token;
    }

    ///  @inheritdoc IL1AssetHandler
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable override onlyBridge whenNotPaused {
        // here we are minting the tokens after the bridgeBurn has happened on an L2, so we can assume the l1Token is not zero
        address l1Token = tokenAddress[_assetId];
        (uint256 amount, address l1Receiver) = abi.decode(_data, (uint256, address));
        // Check that the chain has sufficient balance
        if (chainBalance[_chainId][l1Token] < amount) {
            revert InsufficientChainBalance();
        }
        chainBalance[_chainId][l1Token] -= amount;

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1Receiver, amount, 0, 0, 0, 0)
            }
            if (!callSuccess) {
                revert WithdrawFailed();
            }
        } else {
            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);
        }
        emit BridgeMint(_chainId, _assetId, l1Receiver, amount);
    }

    /// @inheritdoc IL1AssetHandler
    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev In case of native token vault _data is the tuple of _depositAmount and _l2Receiver.
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

            if (_depositAmount != amount) {
                revert ValueMismatch(amount, msg.value);
            }
        } else {
            // The Bridgehub also checks this, but we want to be sure
            if (msg.value != 0) {
                revert NonEmptyMsgValue();
            }

            amount = _depositAmount;

            uint256 expectedDepositAmount = _depositFunds(_prevMsgSender, IERC20(l1Token), _depositAmount); // note if _prevMsgSender is this contract, this will return 0. This does not happen.
            // The token has non-standard transfer logic
            if (amount != expectedDepositAmount) {
                revert TokensWithFeesNotSupported();
            }
        }
        if (amount == 0) {
            // empty deposit amount
            revert EmptyDeposit();
        }

        chainBalance[_chainId][l1Token] += amount;

        _bridgeMintData = DataEncoding.encodeBridgeMintData({
            _prevMsgSender: _prevMsgSender,
            _l2Receiver: _l2Receiver,
            _l1Token: l1Token,
            _amount: amount,
            _erc20Metadata: getERC20Getters(l1Token)
        });

        emit BridgeBurn({
            chainId: _chainId,
            assetId: _assetId,
            l1Sender: _prevMsgSender,
            l2receiver: _l2Receiver,
            amount: amount
        });
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
        if (_amount == 0) {
            revert NoFundsTransferred();
        }

        // check that the chain has sufficient balance
        if (chainBalance[_chainId][l1Token] < _amount) {
            revert InsufficientChainBalance();
        }
        chainBalance[_chainId][l1Token] -= _amount;

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), _depositSender, _amount, 0, 0, 0, 0)
            }
            if (!callSuccess) {
                revert ClaimFailedDepositFailed();
            }
        } else {
            IERC20(l1Token).safeTransfer(_depositSender, _amount);
            // Note we don't allow weth deposits anymore, but there might be legacy weth deposits.
            // until we add Weth bridging capabilities, we don't wrap/unwrap weth to ether.
        }
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token) public view override returns (bytes memory) {
        return BridgeHelper.getERC20Getters(_token, ETH_TOKEN_ADDRESS);
    }

    /// @dev Shows the assetId for a given chain and token address
    function getAssetId(uint256 _chainId, address _l1Token) external pure override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(_chainId, _l1Token);
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
