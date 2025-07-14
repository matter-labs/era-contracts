// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";
import {Create2} from "@openzeppelin/contracts-v4/utils/Create2.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1NativeTokenVault} from "./IL1NativeTokenVault.sol";
import {INativeTokenVault} from "./INativeTokenVault.sol";
import {NativeTokenVault} from "./NativeTokenVault.sol";

import {IL1AssetHandler} from "../interfaces/IL1AssetHandler.sol";
import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {IBridgedStandardToken} from "../interfaces/IBridgedStandardToken.sol";
import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";

import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {OriginChainIdNotFound, Unauthorized, ZeroAddress, NoFundsTransferred, InsufficientChainBalance, WithdrawFailed} from "../../common/L1ContractErrors.sol";
import {ClaimFailedDepositFailed, ZeroAmountToTransfer, WrongAmountTransferred, WrongCounterpart} from "../L1BridgeContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
contract L1NativeTokenVault is IL1NativeTokenVault, IL1AssetHandler, NativeTokenVault {
    using SafeERC20 for IERC20;

    /// @dev L1 nullifier contract that handles legacy functions & finalize withdrawal, confirm l2 tx mappings
    IL1Nullifier public immutable override L1_NULLIFIER;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _l1WethAddress Address of WETH on deployed chain
    /// @param _l1AssetRouter Address of Asset Router on L1.
    /// @param _l1Nullifier Address of the nullifier contract, which handles transaction progress between L1 and ZK chains.
    constructor(
        address _l1WethAddress,
        address _l1AssetRouter,
        IL1Nullifier _l1Nullifier
    )
        NativeTokenVault(
            _l1WethAddress,
            _l1AssetRouter,
            DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS),
            block.chainid
        )
    {
        L1_NULLIFIER = _l1Nullifier;
    }

    /// @dev Accepts ether only from the contract that was the shared Bridge.
    receive() external payable {
        if (address(L1_NULLIFIER) != msg.sender) {
            revert Unauthorized(msg.sender);
        }
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy
    /// @param _owner Address which can change pause / unpause the NTV
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner, address _bridgedTokenBeacon) external initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        bridgedTokenBeacon = IBeacon(_bridgedTokenBeacon);
        _transferOwnership(_owner);
    }

    /// @inheritdoc IL1NativeTokenVault
    function registerEthToken() external {
        _unsafeRegisterNativeToken(ETH_TOKEN_ADDRESS);
    }

    /// @notice Transfers tokens from shared bridge as part of the migration process.
    /// The shared bridge becomes the L1Nullifier contract.
    /// @dev Both ETH and ERC20 tokens can be transferred. Exhausts balance of shared bridge after the first call.
    /// @dev Calling second time for the same token will revert.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    function transferFundsFromSharedBridge(address _token) external {
        ensureTokenIsRegistered(_token);
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balanceBefore = address(this).balance;
            L1_NULLIFIER.transferTokenToNTV(_token);
            uint256 balanceAfter = address(this).balance;
            if (balanceAfter <= balanceBefore) {
                revert NoFundsTransferred();
            }
        } else {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
            uint256 nullifierChainBalance = IERC20(_token).balanceOf(address(L1_NULLIFIER));
            if (nullifierChainBalance == 0) {
                revert ZeroAmountToTransfer();
            }
            L1_NULLIFIER.transferTokenToNTV(_token);
            uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
            if (balanceAfter - balanceBefore < nullifierChainBalance) {
                revert WrongAmountTransferred(balanceAfter - balanceBefore, nullifierChainBalance);
            }
        }
    }

    /// @notice Updates chain token balance within NTV to account for tokens transferred from the shared bridge (part of the migration process).
    /// @dev Clears chain balance on the shared bridge after the first call. Subsequent calls will not affect the state.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    /// @param _targetChainId The chain ID of the corresponding ZK chain.
    function updateChainBalancesFromSharedBridge(address _token, uint256 _targetChainId) external {
        uint256 nullifierChainBalance = L1_NULLIFIER.chainBalance(_targetChainId, _token);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, _token);
        chainBalance[_targetChainId][assetId] = chainBalance[_targetChainId][assetId] + nullifierChainBalance;
        originChainId[assetId] = block.chainid;
        L1_NULLIFIER.nullifyChainBalanceByNTV(_targetChainId, _token);
    }

    /// @notice Used to register the Asset Handler asset in L2 AssetRouter.
    /// @param _assetHandlerAddressOnCounterpart the address of the asset handler on the counterpart chain.
    function bridgeCheckCounterpartAddress(
        uint256,
        bytes32,
        address,
        address _assetHandlerAddressOnCounterpart
    ) external view override onlyAssetRouter {
        if (_assetHandlerAddressOnCounterpart != L2_NATIVE_TOKEN_VAULT_ADDR) {
            revert WrongCounterpart();
        }
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
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter whenNotPaused {
        // slither-disable-next-line unused-return
        (uint256 _amount, , ) = DataEncoding.decodeBridgeBurnData(_data);
        address l1Token = tokenAddress[_assetId];
        if (_amount == 0) {
            revert NoFundsTransferred();
        }

        _handleChainBalanceDecrease(_chainId, _assetId, _amount, false);

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

    // get the computed address before the contract DeployWithCreate2 deployed using Bytecode of contract DeployWithCreate2 and salt specified by the sender
    function calculateCreate2TokenAddress(
        uint256 _originChainId,
        address _nonNativeToken
    ) public view override(INativeTokenVault, NativeTokenVault) returns (address) {
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
            if (!callSuccess) {
                revert WithdrawFailed();
            }
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

    function _handleChainBalanceIncrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) internal override {
        // Note, that we do not update balances for chains where the assetId comes from,
        // since these chains can mint new instances of the token.
        if (!_hasInfiniteBalance(_isNative, _assetId, _chainId)) {
            chainBalance[_chainId][_assetId] += _amount;
        }
    }

    function _handleChainBalanceDecrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) internal override {
        // Note, that we do not update balances for chains where the assetId comes from,
        // since these chains can mint new instances of the token.
        if (!_hasInfiniteBalance(_isNative, _assetId, _chainId)) {
            // Check that the chain has sufficient balance
            if (chainBalance[_chainId][_assetId] < _amount) {
                revert InsufficientChainBalance();
            }
            chainBalance[_chainId][_assetId] -= _amount;
        }
    }

    /// @dev Returns whether a chain `_chainId` has infinite balance for an asset `_assetId`, i.e.
    /// it can be minted by it.
    /// @param _isNative Whether the asset is native to the L1 chain.
    /// @param _assetId The asset id
    /// @param _chainId An id of a chain which we test against.
    /// @return Whether The chain `_chainId` has infinite balance of the token
    function _hasInfiniteBalance(bool _isNative, bytes32 _assetId, uint256 _chainId) private view returns (bool) {
        return !_isNative && originChainId[_assetId] == _chainId;
    }
}
