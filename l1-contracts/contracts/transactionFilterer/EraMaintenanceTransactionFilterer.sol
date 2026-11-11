// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {ValueMismatch, ZeroAddress, ZeroChainId} from "../common/L1ContractErrors.sol";
import {MissingBaseTokenAssetId} from "../bridge/asset-tracker/AssetTrackerErrors.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_CREATE2_FACTORY_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {AssetRouterBase} from "../bridge/asset-router/AssetRouterBase.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";
import {CallMode, IEraMaintenanceTransactionFilterer} from "./interfaces/IEraMaintenanceTransactionFilterer.sol";
import {IBaseToken} from "../common/l2-helpers/IBaseToken.sol";
import {IL2AssetRouter} from "../bridge/asset-router/IL2AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "../bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IL2SharedBridgeLegacyFunctions} from "../bridge/interfaces/IL2SharedBridgeLegacyFunctions.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Filters L1->L2 transactions of an EraVM chain in maintenance mode.
/// See {docs/era-maintenance-filterer.md}.
contract EraMaintenanceTransactionFilterer is IEraMaintenanceTransactionFilterer, Ownable2StepUpgradeable {
    /// @notice The ecosystem's Bridgehub.
    IBridgehubBase public immutable BRIDGE_HUB;

    /// @notice The L1 asset router, the `sender` of every deposit made through the Bridgehub.
    address public immutable L1_ASSET_ROUTER;

    /// @notice The L1 native token vault. Deposits of assets with another handler are rejected, since their
    /// transfer data is handler-defined and the depositor and amount cannot be decoded from it.
    address public immutable L1_NATIVE_TOKEN_VAULT;

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    uint256 public chainId;

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    CallMode public callMode;

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    mapping(address account => bool isExempt) public exempt;

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    mapping(bytes32 assetId => uint256 cap) public depositCap;

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    mapping(bytes32 txHash => bool allowed) public allowedTxHashes;

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    mapping(address l2Contract => mapping(bytes4 selector => bool allowed)) public withdrawalFunctions;

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    mapping(address l1Bridge => bool isLegacyBridge) public legacyBridges;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @param _bridgeHub The ecosystem's Bridgehub.
    constructor(IBridgehubBase _bridgeHub) {
        BRIDGE_HUB = _bridgeHub;
        L1_ASSET_ROUTER = address(_bridgeHub.assetRouter());
        L1_NATIVE_TOKEN_VAULT = address(IL1AssetRouter(L1_ASSET_ROUTER).nativeTokenVault());
        if (L1_NATIVE_TOKEN_VAULT == address(0)) {
            revert ZeroAddress();
        }
        _disableInitializers();
    }

    /// @notice Initializes the filterer in its permissive configuration: `ALLOW_ALL`, the base token uncapped,
    /// no other token accepted, and the withdrawal functions of the L2 base token and L2 asset router allowed.
    /// @param _owner The owner, expected to be the chain admin.
    /// @param _chainId The chain whose Mailbox uses this filterer.
    function initialize(address _owner, uint256 _chainId) external initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        if (_chainId == 0) {
            revert ZeroChainId();
        }
        _transferOwnership(_owner);
        chainId = _chainId;
        // `ALLOW_ALL` is the zero value; it is set anyway so that the initial state is explicit.
        _setCallMode(CallMode.ALLOW_ALL);

        bytes32 baseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
        if (baseTokenAssetId == bytes32(0)) {
            revert MissingBaseTokenAssetId();
        }
        _setDepositCap(baseTokenAssetId, type(uint256).max);
        _setWithdrawalFunction(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, IBaseToken.withdraw.selector, true);
        _setWithdrawalFunction(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, IBaseToken.withdrawWithMessage.selector, true);
        _setWithdrawalFunction(L2_ASSET_ROUTER_ADDR, IL2AssetRouter.withdraw.selector, true);
        _setWithdrawalFunction(L2_ASSET_ROUTER_ADDR, IL2SharedBridgeLegacy.withdraw.selector, true);
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    function setCallMode(CallMode _callMode) external onlyOwner {
        _setCallMode(_callMode);
    }

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    function setExempt(address _account, bool _exempt) external onlyOwner {
        exempt[_account] = _exempt;
        emit ExemptSet(_account, _exempt);
    }

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    function setDepositCaps(bytes32[] calldata _assetIds, uint256[] calldata _caps) external onlyOwner {
        uint256 length = _assetIds.length;
        if (length != _caps.length) {
            revert ValueMismatch(length, _caps.length);
        }
        for (uint256 i = 0; i < length; ++i) {
            _setDepositCap(_assetIds[i], _caps[i]);
        }
    }

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    function setAllowedTxHash(bytes32 _txHash, bool _allowed) external onlyOwner {
        allowedTxHashes[_txHash] = _allowed;
        emit AllowedTxHashSet(_txHash, _allowed);
    }

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    function setWithdrawalFunction(address _l2Contract, bytes4 _selector, bool _allowed) external onlyOwner {
        _setWithdrawalFunction(_l2Contract, _selector, _allowed);
    }

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    function setLegacyBridge(address _l1Bridge, bool _isLegacyBridge) external onlyOwner {
        legacyBridges[_l1Bridge] = _isLegacyBridge;
        emit LegacyBridgeSet(_l1Bridge, _isLegacyBridge);
    }

    function _setCallMode(CallMode _callMode) internal {
        callMode = _callMode;
        emit CallModeSet(_callMode);
    }

    function _setDepositCap(bytes32 _assetId, uint256 _cap) internal {
        depositCap[_assetId] = _cap;
        emit DepositCapSet(_assetId, _cap);
    }

    function _setWithdrawalFunction(address _l2Contract, bytes4 _selector, bool _allowed) internal {
        withdrawalFunctions[_l2Contract][_selector] = _allowed;
        emit WithdrawalFunctionSet(_l2Contract, _selector, _allowed);
    }

    /*//////////////////////////////////////////////////////////////
                            FILTERING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEraMaintenanceTransactionFilterer
    function getTxHash(
        address _sender,
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _l2Calldata,
        address _refundRecipient
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_sender, _contractL2, _l2Value, keccak256(_l2Calldata), _refundRecipient));
    }

    /// @inheritdoc ITransactionFilterer
    function isTransactionAllowed(
        address _sender,
        address _contractL2,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes calldata _l2Calldata,
        address _refundRecipient
    ) external view returns (bool) {
        bytes32 txHash = getTxHash({
            _sender: _sender,
            _contractL2: _contractL2,
            _l2Value: _l2Value,
            _l2Calldata: _l2Calldata,
            _refundRecipient: _refundRecipient
        });
        if (allowedTxHashes[txHash] || exempt[_sender]) {
            return true;
        }

        if (_sender == L1_ASSET_ROUTER) {
            // Not expected to trigger: the L1 asset router always targets the L2 asset router, and its asset handlers
            // (the native token vault, the chain asset handler) and the asset handler registration require a zero
            // `l2Value`. Checked just in case.
            if (_contractL2 != L2_ASSET_ROUTER_ADDR || _l2Value != 0) {
                return false;
            }
            return _isDepositAllowed(_mintValue, _l2Calldata);
        }
        if (
            legacyBridges[_sender] && _hasSelector(_l2Calldata, IL2SharedBridgeLegacyFunctions.finalizeDeposit.selector)
        ) {
            return _isDepositAllowed(_mintValue, _l2Calldata);
        }

        // The L2 deployers are rejected in either mode. Any L2 factory contract can still deploy, so this only closes
        // the direct path.
        if (_contractL2 == L2_DEPLOYER_SYSTEM_CONTRACT_ADDR || _contractL2 == L2_CREATE2_FACTORY_ADDR) {
            return false;
        }
        if (callMode == CallMode.WITHDRAWALS_ONLY) {
            return _isCallAllowedInWithdrawalsOnlyMode(_contractL2, _mintValue, _l2Calldata);
        }
        return _isWithinCap(_baseTokenAssetId(), _mintValue);
    }

    /// @dev The `WITHDRAWALS_ONLY` rule for a call that is not a deposit: only a call to a registered withdrawal
    /// function with `_mintValue` within the base token cap passes.
    function _isCallAllowedInWithdrawalsOnlyMode(
        address _contractL2,
        uint256 _mintValue,
        bytes calldata _l2Calldata
    ) internal view returns (bool) {
        return
            _l2Calldata.length >= 4 &&
            withdrawalFunctions[_contractL2][bytes4(_l2Calldata[:4])] &&
            _isWithinCap(_baseTokenAssetId(), _mintValue);
    }

    /// @dev Decodes a deposit in either `finalizeDeposit` encoding. An exempt depositor passes in either mode;
    /// any other deposit is rejected in `WITHDRAWALS_ONLY` mode and checked against the caps in `ALLOW_ALL` mode.
    /// Only called for a sender that sends deposits: the L1 asset router (whose target and `l2Value` are already
    /// checked) or a legacy bridge. The legacy encoding carries the L1 token address, so the asset id is derived as
    /// an L1-native NTV token.
    function _isDepositAllowed(uint256 _mintValue, bytes calldata _l2Calldata) internal view returns (bool) {
        address depositor;
        bytes32 assetId;
        uint256 amount;
        if (_hasSelector(_l2Calldata, AssetRouterBase.finalizeDeposit.selector)) {
            bytes memory transferData;
            (, assetId, transferData) = abi.decode(_l2Calldata[4:], (uint256, bytes32, bytes));
            // Token deposits to an Era chain only use the native token vault. The other handler, the chain asset
            // handler, only migrates chains to a settlement layer, which this filterer rejects. The check also keeps
            // a custom handler registered later from passing data that decodeBridgeMintData would misread.
            if (IL1AssetRouter(L1_ASSET_ROUTER).assetHandlerAddress(assetId) != L1_NATIVE_TOKEN_VAULT) {
                return false;
            }
            // slither-disable-next-line unused-return
            (depositor, , , amount, ) = DataEncoding.decodeBridgeMintData(transferData);
        } else if (_hasSelector(_l2Calldata, IL2SharedBridgeLegacyFunctions.finalizeDeposit.selector)) {
            address l1Token;
            (depositor, , l1Token, amount, ) = abi.decode(_l2Calldata[4:], (address, address, address, uint256, bytes));
            assetId = DataEncoding.encodeNTVAssetId(block.chainid, l1Token);
        } else {
            return false;
        }

        // `isTransactionAllowed` checked the exemption of `_sender`, i.e. of the bridge; this is the depositor's.
        if (exempt[depositor]) {
            return true;
        }
        return
            callMode == CallMode.ALLOW_ALL &&
            _isWithinCap(_baseTokenAssetId(), _mintValue) &&
            _isWithinCap(assetId, amount);
    }

    function _isWithinCap(bytes32 _assetId, uint256 _amount) internal view returns (bool) {
        uint256 cap = depositCap[_assetId];
        return cap != 0 && _amount <= cap;
    }

    function _baseTokenAssetId() internal view returns (bytes32) {
        return BRIDGE_HUB.baseTokenAssetId(chainId);
    }

    function _hasSelector(bytes calldata _data, bytes4 _selector) internal pure returns (bool) {
        return _data.length >= 4 && bytes4(_data[:4]) == _selector;
    }
}
