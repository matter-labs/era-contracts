// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {
    MAX_TOKEN_BALANCE,
    SavedTotalSupply,
    TOKEN_BALANCE_MIGRATION_DATA_VERSION
} from "./IAssetTrackerBase.sol";
import {
    L1ToGatewayTokenBalanceMigrationData,
    MigrationConfirmationData
} from "../../common/Messaging.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_BRIDGEHUB,
    L2_CHAIN_ASSET_HANDLER,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {InvalidChainId, Unauthorized} from "../../common/L1ContractErrors.sol";

import {
    AssetIdNotRegistered,
    MaxChainBalanceAlreadyAssigned,
    MissingBaseTokenAssetId,
    OnlyGatewaySettlementLayer,
    TokenBalanceNotMigratedToGateway
} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";

contract L2AssetTracker is AssetTrackerBase, IL2AssetTracker {
    struct InteropL2Info {
        uint256 totalWithdrawalsToL1;
        uint256 totalSuccessfulDepositsFromL1;
    }

    uint256 public L1_CHAIN_ID;

    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @notice We save the token balance in the first deposit after chain migration. For native tokens, this is the chainBalance; for foreign tokens, this is the total supply. See _handleFinalizeBridgingOnL2Inner for details.
    /// @notice We need this to be able to migrate token balance to Gateway AssetTracker from the L1AssetTracker.
    mapping(uint256 migrationNumber => mapping(bytes32 assetId => SavedTotalSupply savedTotalSupply))
        internal savedTotalSupply;

    /// @dev L2-side accounting used to compute the amount to keep on L1 during L1 -> Gateway migration.
    mapping(bytes32 assetId => InteropL2Info info) internal interopInfo;

    /// @dev Token total supply snapshot captured before the first post-v31 bridge operation for each token.
    /// @dev For tokens that existed before the chain migrated to v31, it should be equal to `totalSuccessfulDeposits - totalWithdrawalsToL1`.
    /// - If a token is bridged tokens, it is equal to its `totalSupply()`. 
    /// - If a token is a native token, it is equal to the `2^256-1 - balanceOf of the native token vault`, i.e. one 
    /// could image there was a big successful deposit at the inception time of 2^256-1 and then the withdrawals behaved the same way as for
    /// the bridged L2 tokens. 
    /// @dev For native tokens, it is expected to be populated atomatically with `maxChainBalanceAssigned[block.chainid]`.
    mapping(bytes32 assetId => SavedTotalSupply snapshot) internal totalPreV31TotalSupply;

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

    /// @notice Sets the L1 chain ID and base token asset ID for this L2 chain.
    /// @dev This function is called during contract initialization or upgrades.
    /// @param _l1ChainId The chain ID of the L1 network.
    /// @param _baseTokenAssetId The asset ID of the base token used for gas fees on this chain.
    function setAddresses(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
    }

    function _l1ChainId() internal view returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVaultBase) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    /// @inheritdoc AssetTrackerBase
    function registerNewToken(bytes32 _assetId, uint256 _originChainId) public override onlyNativeTokenVault {
        _registerTokenOnL2(_assetId);
        if (_originChainId == block.chainid) {
            _assignMaxChainBalance(_originChainId, _assetId);
            // By convention, we treat native tokens as those that had an infinite deposit
            // at the inception of the chain, so we set the `totalPreV31TotalSupply` to MAX_TOKEN_BALANCE to reflect that. 
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({
                isSaved: true, 
                amount: MAX_TOKEN_BALANCE
            });
        }
    }

    function _registerTokenOnL2(bytes32 _assetId) internal {
        /// If the chain is settling on Gateway, then withdrawals are not automatically allowed for new tokens.
        if (L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == _l1ChainId()) {
            assetMigrationNumber[block.chainid][_assetId] = L2_CHAIN_ASSET_HANDLER.migrationNumber(block.chainid);
        }
    }

    /// @notice Registers a legacy token on this L2 chain for backwards compatibility.
    /// @dev This function is used during upgrades to ensure pre-V31 tokens continue to work.
    /// @dev We do not make legacy tokens interoperable automatically.
    /// @param _assetId The asset ID of the legacy token to register.
    function registerLegacyTokenOnChain(bytes32 _assetId) external onlyNativeTokenVault {
        _registerTokenOnL2(_assetId);
    }

    /// @notice Stores token total supply snapshot used for pre-v31 migration accounting.
    /// @dev Anyone can call this to eagerly initialize the snapshot before the first bridge operation.
    function populateTotalPreV31TotalSupply(bytes32 _assetId) external {
        address tokenAddress = _tryGetTokenAddress(_assetId);
        _populateTotalPreV31TotalSupplyIfNeeded(_assetId, tokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is called for outgoing bridging from the L2, i.e. L2->L1 withdrawals and outgoing L2->L2 interop.
    /// @param _toChainId The destination chain id of the transfer.
    /// @param _assetId The bridged asset id.
    /// @param _amount The transferred amount.
    /// @param _tokenOriginChainId Origin chain id of the bridged token.
    function handleInitiateBridgingOnL2(
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external onlyL2NativeTokenVault {
        _handleInitiateBridgingOnL2Inner(_toChainId, _assetId, _amount, _tokenOriginChainId);
    }

    function _handleInitiateBridgingOnL2Inner(
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) internal {
        address tokenAddress = _tryGetTokenAddress(_assetId);
        _populateTotalPreV31TotalSupplyIfNeeded(_assetId, tokenAddress);

        _checkAssetMigrationNumber(_assetId);
        if (_tokenOriginChainId == block.chainid) {
            /// On the L2 we only save chainBalance for native tokens.
            _decreaseChainBalance(block.chainid, _assetId, _amount);
        }

        if (_toChainId == L1_CHAIN_ID && L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID) {
            interopInfo[_assetId].totalWithdrawalsToL1 += _amount;
        }
    }

    /// @notice This function is used to check the asset migration number.
    /// @dev This is used to pause outgoing withdrawals and interop transactions after the chain migrates to Gateway.
    function _checkAssetMigrationNumber(bytes32 _assetId) internal view {
        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        /// Note we always allow bridging when settling on L1.
        /// On Gateway we require that the tokenBalance be migrated to Gateway from L1,
        /// otherwise withdrawals might fail in the GWAssetTracker when the chain settles.
        require(
            savedAssetMigrationNumber == migrationNumber ||
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == _l1ChainId(),
            TokenBalanceNotMigratedToGateway(_assetId, savedAssetMigrationNumber, migrationNumber)
        );
    }

    /// @notice Handles the initiation of base token bridging operations on L2.
    /// @dev This function is specifically for the chain's native base token used for gas payments.
    /// @param _amount The amount of base tokens being bridged out.
    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external onlyL2BaseTokenSystemContract {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        uint256 baseTokenOriginChainId = L2_NATIVE_TOKEN_VAULT.originChainId(baseTokenAssetId);
        _handleInitiateBridgingOnL2Inner(L1_CHAIN_ID, baseTokenAssetId, _amount, baseTokenOriginChainId);
    }

    /// @notice Handles the finalization of incoming token bridging operations on L2.
    /// @dev This function is called when tokens are bridged into this L2 from another chain.
    /// @param _fromChainId The source chain id of the transfer.
    /// @param _assetId The asset ID of the token being bridged in.
    /// @param _amount The amount of tokens being bridged in.
    /// @param _tokenOriginChainId The chain ID where this token was originally created.
    /// @param _tokenAddress The contract address of the token on this chain.
    function handleFinalizeBridgingOnL2(
        uint256 _fromChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) external onlyL2NativeTokenVault {
        _handleFinalizeBridgingOnL2Inner(_fromChainId, _assetId, _amount, _tokenOriginChainId, _tokenAddress);
    }

    function _handleFinalizeBridgingOnL2Inner(
        uint256 _fromChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) internal {
        _populateTotalPreV31TotalSupplyIfNeeded(_assetId, _tokenAddress);

        if (_needToForceSetAssetMigrationOnL2(_assetId, _tokenOriginChainId, _tokenAddress)) {
            _forceSetAssetMigrationNumber(block.chainid, _assetId);
        }

        /// On the L2 we only save chainBalance for native tokens.
        if (_tokenOriginChainId == block.chainid) {
            chainBalance[block.chainid][_assetId] += _amount;
        }

        if (_fromChainId == L1_CHAIN_ID && L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID) {
            interopInfo[_assetId].totalSuccessfulDepositsFromL1 += _amount;
        }
    }

    function _populateTotalPreV31TotalSupplyIfNeeded(
        bytes32 _assetId,
        address _tokenAddress
    ) internal returns (uint256 _totalSupply) {
        // Firstly, we need to ensure that if the token is native to the current chain,
        // it has its totalSupply correctly set up.
        SavedTotalSupply memory snapshot = totalPreV31TotalSupply[_assetId];
        if (snapshot.isSaved) {
            return snapshot.amount;
        }

        INativeTokenVaultBase ntv = _nativeTokenVault();

        // Token is not new and yet it does not have the prev31 total supply saved,
        // so it is a token that has been present on the chain before the v31 upgrade.
        uint256 originChainId = ntv.originChainId(_assetId);
        require(originChainId != 0, AssetIdNotRegistered(_assetId));
        if(originChainId == block.chainid) {
            // Invariant check: the only way how the max chain balance can be assigned to a chain
            // is through the migraiton of the balance from the NTV.
            require(!maxChainBalanceAssigned[_assetId], MaxChainBalanceAlreadyAssigned(_assetId));
            // Invariant check: the chain balance of the origin chain should be 0 until the balance migration
            // from NTV is complete.
            require(chainBalance[originChainId][_assetId] == 0, "Chain balance should be 0 before migration");

            // Initialize chainBalance
            // For origin chains, chainBalance starts at MAX_TOKEN_BALANCE and decreases as tokens are bridged out.
            // We need to account for tokens currently locked in the NTV from previous bridge operations.
            // Note, that this logic treats "tokens sent direclty to L2NTV" and tokens bridged to L1 through NTV the same
            // way. It is okay, since the tokens that have been sent to L1 are basically frozen anyway.
            uint256 ntvBalance = IERC20(_tokenAddress).balanceOf(address(ntv));
            uint256 chainTotalSupply = MAX_TOKEN_BALANCE - ntvBalance;

            // We imagine that the chain started with MAX_TOKEN_BALANCE supply, and then some tokens were bridged out and are currently in the NTV.
            chainBalance[originChainId][_assetId] = chainTotalSupply;

            maxChainBalanceAssigned[_assetId] = true;

            _totalSupply = chainTotalSupply;
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: chainTotalSupply});
        } else {
            _totalSupply = IERC20(_tokenAddress).totalSupply();
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: _totalSupply});
        }
    }
        

    /// @notice Handles the finalization of incoming base token bridging operations on L2.
    /// @dev This function is specifically for the chain's native base token used for gas payments.
    /// @param _amount The amount of base tokens being bridged into this chain.
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
            L1_CHAIN_ID,
            baseTokenAssetId,
            _amount,
            L1_CHAIN_ID,
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration
    //////////////////////////////////////////////////////////////*/

    /// @notice Migrates the token balance from L1 to Gateway.
    /// @dev This function can be called multiple times on the chain it does not have a direct effect.
    /// @dev This function is permissionless, it does not affect the state of the contract substantially, and can be called multiple times.
    /// @dev The value to migrate is read from the L2, but the tracking is done on L1/GW.
    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external {
        require(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() != L1_CHAIN_ID,
            OnlyGatewaySettlementLayer()
        );

        address tokenAddress = _tryGetTokenAddress(_assetId);
        uint256 readTotalPreV31TotalSupply = _populateTotalPreV31TotalSupplyIfNeeded(_assetId, tokenAddress);

        uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        address originalToken = L2_NATIVE_TOKEN_VAULT.originToken(_assetId);

        uint256 chainMigrationNumber = _getChainMigrationNumber(block.chainid);
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        if (chainMigrationNumber == savedAssetMigrationNumber) {
            /// In this case the token was either already migrated, or the migration number was set using _forceSetAssetMigrationNumber.
            return;
        }

        L1ToGatewayTokenBalanceMigrationData memory tokenBalanceMigrationData = L1ToGatewayTokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            originToken: originalToken,
            chainId: block.chainid,
            assetId: _assetId,
            tokenOriginChainId: originChainId,
            chainMigrationNumber: chainMigrationNumber,
            assetMigrationNumber: savedAssetMigrationNumber,
            totalWithdrawalsToL1: interopInfo[_assetId].totalWithdrawalsToL1,
            totalSuccessfulDepositsFromL1: interopInfo[_assetId].totalSuccessfulDepositsFromL1,
            totalPreV31TotalSupply: readTotalPreV31TotalSupply
        });
        _sendL1ToGatewayMigrationDataToL1(tokenBalanceMigrationData);

        emit IL2AssetTracker.L1ToGatewayMigrationInitiated(_assetId, block.chainid, readTotalPreV31TotalSupply);
    }

    /// @notice Confirms a migration operation has been completed and updates the asset migration number.
    /// @dev This function is called by L1 after a migration has been processed to update local state.
    /// @param _data The migration confirmation data containing the asset ID and migration number.
    function confirmMigrationOnL2(MigrationConfirmationData calldata _data) external onlyServiceTransactionSender {
        assetMigrationNumber[block.chainid][_data.assetId] = _data.assetMigrationNumber;
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Determines if a token's migration number should be force-set during bridging operations.
    /// @param _assetId The asset ID of the token to check.
    /// @param _tokenOriginChainId The chain ID where this token originated.
    /// @param _tokenAddress The contract address of the token on this chain.
    /// @return bool True if the migration number should be force-set, false otherwise.
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

    /// @notice Retrieves the token contract address for a given asset ID.
    /// @param _assetId The asset ID to look up.
    /// @return tokenAddress The contract address of the token.
    function _tryGetTokenAddress(bytes32 _assetId) internal view returns (address tokenAddress) {
        tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);
        require(tokenAddress != address(0), AssetIdNotRegistered(_assetId));
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return L2_CHAIN_ASSET_HANDLER.migrationNumber(_chainId);
    }
}
