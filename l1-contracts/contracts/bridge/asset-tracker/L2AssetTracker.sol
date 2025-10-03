// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {SavedTotalSupply, TOKEN_BALANCE_MIGRATION_DATA_VERSION, MAX_TOKEN_BALANCE} from "./IAssetTrackerBase.sol";
import {ConfirmBalanceMigrationData, TokenBalanceMigrationData} from "../../common/Messaging.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BRIDGEHUB, L2_CHAIN_ASSET_HANDLER, L2_COMPLEX_UPGRADER_ADDR, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {Unauthorized, InvalidChainId} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {IBridgehubBase} from "../../bridgehub/IBridgehubBase.sol";

import {AssetIdNotRegistered, MissingBaseTokenAssetId, OnlyGatewaySettlementLayer, TokenBalanceNotMigratedToGateway, ChainBalanceAlreadyInitialized} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";

contract L2AssetTracker is AssetTrackerBase, IL2AssetTracker {
    uint256 public L1_CHAIN_ID;

    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @notice We save the total supply of the token in the first deposit after chain migration. See _handleFinalizeBridgingOnL2Inner for details.
    /// We need this to be able to migrate token balance to Gateway AssetTracker from the L1AssetTracker.
    mapping(uint256 migrationNumber => mapping(bytes32 assetId => SavedTotalSupply savedTotalSupply))
        internal savedTotalSupply;

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2NativeTokenVault() {
        if (msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2BaseTokenSystemContract() {
        if (msg.sender != address(L2_BASE_TOKEN_SYSTEM_CONTRACT)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != L2_BRIDGEHUB.getZKChain(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    function setAddresses(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
    }

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view override returns (IBridgehubBase) {
        return L2_BRIDGEHUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVaultBase) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return L2_MESSAGE_ROOT;
    }

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) public override onlyNativeTokenVault {
        _registerTokenOnL2(_assetId);
        if (_originChainId == block.chainid) {
            _assignMaxChainBalance(_originChainId, _assetId);
        }
    }

    function _registerTokenOnL2(bytes32 _assetId) internal {
        /// If the chain is settling on Gateway, then withdrawals are not automatically allowed for new tokens.
        if (L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() == _l1ChainId()) {
            assetMigrationNumber[block.chainid][_assetId] = L2_CHAIN_ASSET_HANDLER.getMigrationNumber(block.chainid);
        }
    }

    function registerLegacyTokenOnChain(bytes32 _assetId) external onlyNativeTokenVault {
        _registerTokenOnL2(_assetId);
    }

    /// @notice This function is used to migrate the token balance from the NTV to the AssetTracker for V30 upgrade.
    /// @param _chainId The chain id of the chain to migrate the token balance for.
    /// @param _assetId The asset id of the token to migrate the token balance for.
    function migrateTokenBalanceFromNTVV30(uint256 _chainId, bytes32 _assetId) external {
        INativeTokenVaultBase ntv = _nativeTokenVault();

        // Validate that this is an L2 native token
        uint256 originChainId = ntv.originChainId(_assetId);
        require(_chainId != L1_CHAIN_ID, InvalidChainId());

        // Get token address
        address tokenAddress = ntv.tokenAddress(_assetId);
        require(tokenAddress != address(0), AssetIdNotRegistered(_assetId));

        // Prevent re-initialization if already set
        if (chainBalance[block.chainid][_assetId] != 0 || maxChainBalanceAssigned[_assetId]) {
            revert ChainBalanceAlreadyInitialized(_assetId);
        }

        // Initialize chainBalance
        uint256 ntvBalance = IERC20(tokenAddress).balanceOf(address(ntv));
        chainBalance[originChainId][_assetId] = MAX_TOKEN_BALANCE - ntvBalance;

        // Mark chainBalance as assigned
        maxChainBalanceAssigned[_assetId] = true;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is called for outgoing bridging from the L2, i.e. L2->L1 withdrawals and outgoing L2->L2 interop.
    function handleInitiateBridgingOnL2(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external onlyL2NativeTokenVault {
        _handleInitiateBridgingOnL2Inner(_assetId, _amount, _tokenOriginChainId);
    }

    function _handleInitiateBridgingOnL2Inner(bytes32 _assetId, uint256 _amount, uint256 _tokenOriginChainId) internal {
        _checkAssetMigrationNumber(_assetId);
        if (_tokenOriginChainId == block.chainid) {
            /// On the L2 we only save chainBalance for native tokens.
            _decreaseChainBalance(block.chainid, _assetId, _amount);
        }
    }

    /// @notice This function is used to check the asset migration number.
    /// @dev This is used to pause outgoing withdrawals and interop transactions after the chain migrates to Gateway.
    function _checkAssetMigrationNumber(bytes32 _assetId) internal view {
        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        /// Note we always allow bridging when settling on L1.
        /// On Gateway we require that the tokenBalance be migrated to Gateway from L1,
        /// otherwise withdrawals might fail in the Gateway L2AssetTracker when the chain settles.
        require(
            savedAssetMigrationNumber == migrationNumber ||
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() == _l1ChainId(),
            TokenBalanceNotMigratedToGateway(_assetId, savedAssetMigrationNumber, migrationNumber)
        );
    }

    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external onlyL2BaseTokenSystemContract {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        uint256 baseTokenOriginChainId = L2_NATIVE_TOKEN_VAULT.originChainId(baseTokenAssetId);
        _handleInitiateBridgingOnL2Inner(baseTokenAssetId, _amount, baseTokenOriginChainId);
    }

    function handleFinalizeBridgingOnL2(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) external onlyL2NativeTokenVault {
        _handleFinalizeBridgingOnL2Inner(_assetId, _amount, _tokenOriginChainId, _tokenAddress);
    }

    function _handleFinalizeBridgingOnL2Inner(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) internal {
        if (_needToForceSetAssetMigrationOnL2(_assetId, _tokenOriginChainId, _tokenAddress)) {
            _forceSetAssetMigrationNumber(block.chainid, _assetId);
        }

        /// We save the total supply for the first deposit after a migration.
        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        /// Here we don't care about the total supply, we only want to save it if it is not already saved.
        // solhint-disable-next-line no-unused-vars
        _getOrSaveTotalSupply(_assetId, migrationNumber, _tokenOriginChainId, _tokenAddress);
        /// On the L2 we only save chainBalance for native tokens.
        if (_tokenOriginChainId == block.chainid) {
            chainBalance[block.chainid][_assetId] += _amount;
        }
    }

    /// @notice This saves the total supply if it is not saved yet. It returns the saved total supply.
    function _getOrSaveTotalSupply(
        bytes32 _assetId,
        uint256 _migrationNumber,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) internal returns (uint256 _totalSupply) {
        SavedTotalSupply memory tokenSavedTotalSupply = savedTotalSupply[_migrationNumber][_assetId];
        if (!tokenSavedTotalSupply.isSaved) {
            _totalSupply = _readTotalSupply(_assetId, _tokenOriginChainId, _tokenAddress);
            /// This function saves the token supply before the first deposit after the chain migration is processed (in the same transaction).
            /// This totalSupply is the chain's total supply at the moment of chain migration.
            savedTotalSupply[_migrationNumber][_assetId] = SavedTotalSupply({isSaved: true, amount: _totalSupply});
        } else {
            _totalSupply = tokenSavedTotalSupply.amount;
        }
    }

    function _readTotalSupply(
        bytes32 _assetId,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) internal view returns (uint256 _totalSupply) {
        if (_tokenOriginChainId == block.chainid) {
            _totalSupply = chainBalance[block.chainid][_assetId];
        } else {
            _totalSupply = IERC20(_tokenAddress).totalSupply();
        }
    }

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _amount) external onlyL2BaseTokenSystemContract {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        if (_amount == 0) {
            return;
        }
        if (baseTokenAssetId == bytes32(0)) {
            /// this means we are before the genesis upgrade, where we don't transfer value, so we can skip.
            /// if we don't skip we use incorrect asset id.
            revert MissingBaseTokenAssetId();
        }

        _handleFinalizeBridgingOnL2Inner(
            baseTokenAssetId,
            _amount,
            L1_CHAIN_ID,
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @notice Migrates the token balance from L2 to L1.
    /// @dev This function can be called multiple times on the chain it does not have a direct effect.
    /// @dev This function is permissionless, it does not affect the state of the contract substantially, and can be called multiple times.
    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external {
        require(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() != L1_CHAIN_ID,
            OnlyGatewaySettlementLayer()
        );
        address tokenAddress = _tryGetTokenAddress(_assetId);

        uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        address originalToken = L2_NATIVE_TOKEN_VAULT.originToken(_assetId);

        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        if (migrationNumber == assetMigrationNumber[block.chainid][_assetId]) {
            /// In this case the token was either already migrated, or the migration number was set using _forceSetAssetMigrationNumber.
            return;
        }
        uint256 amount = _getOrSaveTotalSupply(_assetId, migrationNumber, originChainId, tokenAddress);

        TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: block.chainid,
            assetId: _assetId,
            tokenOriginChainId: originChainId,
            amount: amount,
            migrationNumber: migrationNumber,
            originToken: originalToken,
            isL1ToGateway: true
        });
        _sendMigrationDataToL1(tokenBalanceMigrationData);
    }

    function confirmMigrationOnL2(ConfirmBalanceMigrationData calldata data) external onlyServiceTransactionSender {
        assetMigrationNumber[block.chainid][data.assetId] = data.migrationNumber;
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev We need to force set the asset migration number for newly deployed tokens.
    function _needToForceSetAssetMigrationOnL2(
        bytes32 _assetId,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) internal view returns (bool) {
        if (_tokenOriginChainId == block.chainid) {
            return false;
        }
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        uint256 amount = IERC20(_tokenAddress).totalSupply();

        return savedAssetMigrationNumber == 0 && amount == 0;
    }

    function _tryGetTokenAddress(bytes32 _assetId) internal view returns (address tokenAddress) {
        tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);
        require(tokenAddress != address(0), AssetIdNotRegistered(_assetId));
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return L2_CHAIN_ASSET_HANDLER.getMigrationNumber(_chainId);
    }
}
