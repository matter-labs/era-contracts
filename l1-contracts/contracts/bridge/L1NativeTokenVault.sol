// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IL1StandardAsset} from "./interfaces/IL1StandardAsset.sol";

import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";
import {ETH_TOKEN_ADDRESS, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS} from "../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the hyperchains.
/// @dev Designed for use with a proxy for upgradability.
contract L1NativeTokenVault is
    IL1NativeTokenVault,
    IL1StandardAsset,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    /// @dev L1 Shared Bridge smart contract that handles communication with its counterparts on L2s
    IL1SharedBridge public immutable override L1_SHARED_BRIDGE;

    /// @dev Era's chainID
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => bool enabled) public hyperbridgingEnabled;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across hyperchains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev A mapping assetInfo => tokenAddress
    mapping(bytes32 assetInfo => address tokenAddress) public tokenAddress;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridge() {
        require(msg.sender == address(L1_SHARED_BRIDGE), "NTV not ShB");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyOwnerOrBridge() {
        require((msg.sender == address(L1_SHARED_BRIDGE) || (msg.sender == owner())), "NTV not ShB or o");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IL1SharedBridge _l1SharedBridge, uint256 _eraChainId) reentrancyGuardInitializer {
        _disableInitializers();
        ERA_CHAIN_ID = _eraChainId;
        L1_SHARED_BRIDGE = _l1SharedBridge;
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy
    /// @param _owner Address which can change L2 token implementation and upgrade the bridge
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), "NTV owner 0");
        _transferOwnership(_owner);
    }

    /// @dev We want to be able to bridge naitive tokens automatically, this means registering them on the fly
    /// @notice Allows the bridge to register a token address for the vault.
    function registerToken(address _l1Token) external {
        require(_l1Token == ETH_TOKEN_ADDRESS || _l1Token.code.length > 0, "NTV: empty token");
        bytes32 assetInfo = keccak256(
            abi.encode(block.chainid, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, uint256(uint160(_l1Token)))
        );
        L1_SHARED_BRIDGE.setAssetAddress(bytes32(uint256(uint160(_l1Token))), address(this));
        tokenAddress[assetInfo] = _l1Token;
    }

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    function bridgeBurn(
        uint256 _chainId,
        uint256,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridge whenNotPaused returns (bytes memory _bridgeMintData) {
        (uint256 _depositAmount, address _l2Receiver) = abi.decode(_data, (uint256, address));

        uint256 amount;
        address l1Token = tokenAddress[_assetInfo];
        if (l1Token == ETH_TOKEN_ADDRESS) {
            amount = msg.value;
            require(_depositAmount == 0 || _depositAmount == amount, "L1NTV: msg.value not equal to amount");
        } else {
            // The Bridgehub also checks this, but we want to be sure
            require(msg.value == 0, "NTV m.v > 0 b d.it");
            amount = _depositAmount;

            // ToDo: rename
            uint256 withdrawAmount = _depositFunds(_prevMsgSender, IERC20(l1Token), _depositAmount); // note if _prevMsgSender is this contract, this will return 0. This does not happen.
            require(withdrawAmount == _depositAmount, "3T"); // The token has non-standard transfer logic
        }
        require(amount != 0, "6T"); // empty deposit amount

        if (!L1_SHARED_BRIDGE.hyperbridgingEnabled(_chainId)) {
            chainBalance[_chainId][l1Token] += amount;
        }

        // solhint-disable-next-line func-named-parameters
        _bridgeMintData = abi.encode(amount, _prevMsgSender, _l2Receiver, getERC20Getters(l1Token), l1Token); // to do add l2Receiver in here
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address.
    /// @return The difference between the contract balance before and after the transferring of funds.
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        address from = _from;
        if (_token.allowance(address(L1_SHARED_BRIDGE), address(this)) > 0) {
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
            bytes memory name = bytes("Ether");
            bytes memory symbol = bytes("ETH");
            bytes memory decimals = abi.encode(uint8(18));
            return abi.encode(name, symbol, decimals); // when depositing eth to a non-eth based chain it is an ERC20
        }

        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return abi.encode(data1, data2, data3);
    }

    /* solhint-disable no-unused-vars */
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetInfo,
        bytes calldata _data
    ) external payable override returns (address _l1Receiver) {
        address l1Token = tokenAddress[_assetInfo];
        (uint256 amount, address l1Receiver) = abi.decode(_data, (uint256, address));
        _l1Receiver = l1Receiver;
        if (!L1_SHARED_BRIDGE.hyperbridgingEnabled(_chainId)) {
            // Check that the chain has sufficient balance
            require(chainBalance[_chainId][l1Token] >= amount, "NTV not enough funds 2"); // not enough funds
            chainBalance[_chainId][l1Token] -= amount;
        }
        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1Receiver, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "NTV: withdraw failed");
        } else {
            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);
        }
    }

    function bridgeClaimFailedBurn(
        uint256 _chainId,
        bytes32 _assetInfo,
        address,
        bytes calldata _data
    ) external payable override {
        (uint256 _amount, address _depositSender) = abi.decode(_data, (uint256, address));
        address l1Token = tokenAddress[_assetInfo];
        require(_amount > 0, "y1");

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), _depositSender, _amount, 0, 0, 0, 0)
            }
            require(callSuccess, "NTV: claimFailedDeposit failed");
        } else {
            IERC20(l1Token).safeTransfer(_depositSender, _amount);
            // Note we don't allow weth deposits anymore, but there might be legacy weth deposits.
            // until we add Weth bridging capabilities, we don't wrap/unwrap weth to ether.
        }

        if (!L1_SHARED_BRIDGE.hyperbridgingEnabled(_chainId)) {
            // check that the chain has sufficient balance
            require(chainBalance[_chainId][l1Token] >= _amount, "NTV n funds");
            chainBalance[_chainId][l1Token] -= _amount;
        }
    }

    function getAssetInfoFromLegacy(address _l1TokenAddress) public view override returns (bytes32) {
        if (tokenAddress[getAssetInfo(_l1TokenAddress)] != address(0)) {
            return getAssetInfo(_l1TokenAddress);
        }
        return bytes32(uint256(uint160(_l1TokenAddress)));
    }

    function getAssetInfo(address _l1TokenAddress) public view override returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS,
                    bytes32(uint256(uint160(_l1TokenAddress)))
                )
            );
    }
}
