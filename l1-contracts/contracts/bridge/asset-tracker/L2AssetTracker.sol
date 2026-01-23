// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {SavedTotalSupply, TOKEN_BALANCE_MIGRATION_DATA_VERSION, MAX_TOKEN_BALANCE} from "./IAssetTrackerBase.sol";
import {ConfirmBalanceMigrationData, TokenBalanceMigrationData} from "../../common/Messaging.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BRIDGEHUB, L2_CHAIN_ASSET_HANDLER, L2_COMPLEX_UPGRADER_ADDR, L2_NATIVE_TOKEN_VAULT, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {Unauthorized, InvalidChainId} from "../../common/L1ContractErrors.sol";

import {AssetIdNotRegistered, MissingBaseTokenAssetId, OnlyGatewaySettlementLayer, TokenBalanceNotMigratedToGateway, MaxChainBalanceAlreadyAssigned} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";

contract L2AssetTracker is AssetTrackerBase, IL2AssetTracker {
    /// @notice The initial balance of the BaseTokenHolder contract (2^127 - 1).
    /// @dev Used to derive the real circulating supply: INITIAL - currentHolderBalance = circulatingSupply
    uint256 public constant INITIAL_BASE_TOKEN_HOLDER_BALANCE = (2 ** 127) - 1;

    uint256 public L1_CHAIN_ID;

    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @notice We save the token balance in the first deposit after chain migration. For native tokens, this is the chainBalance; for foreign tokens, this is the total supply. See _handleFinalizeBridgingOnL2Inner for details.
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

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) public override onlyNativeTokenVault {
        _registerTokenOnL2(_assetId);
        if (_originChainId == block.chainid) {
            _assignMaxChainBalance(_originChainId, _assetId);
        }
    }

    function _registerTokenOnL2(bytes32 _assetId) internal {
        /// If the chain is settling on Gateway, then withdrawals are not automatically allowed for new tokens.
        // FIXME
        // if (L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == _l1ChainId()) {
        //     assetMigrationNumber[block.chainid][_assetId] = L2_CHAIN_ASSET_HANDLER.migrationNumber(block.chainid);
        // }
    }

    /// @notice Registers a legacy token on this L2 chain for backwards compatibility.
    /// @dev This function is used during upgrades to ensure pre-V31 tokens continue to work.
    /// @param _assetId The asset ID of the legacy token to register.
    function registerLegacyTokenOnChain(bytes32 _assetId) external onlyNativeTokenVault {
        _registerTokenOnL2(_assetId);
    }

    /// @notice Migrates token balance tracking from NativeTokenVault to AssetTracker for V31 upgrade.
    /// @dev This function calculates the correct chainBalance by accounting for tokens currently held in the NTV.
    /// @dev The chainBalance represents how much of the token supply is "available" for bridging out.
    /// @param _assetId The asset id of the token to migrate the token balance for.
    function migrateTokenBalanceFromNTVV31(bytes32 _assetId) external {
        INativeTokenVaultBase ntv = _nativeTokenVault();

        // Validate that this is a token native to the current L2
        uint256 originChainId = ntv.originChainId(_assetId);
        require(originChainId == block.chainid, InvalidChainId());

        // Get token address
        address tokenAddress = ntv.tokenAddress(_assetId);
        require(tokenAddress != address(0), AssetIdNotRegistered(_assetId));

        // Prevent re-initialization if already set
        require(!maxChainBalanceAssigned[_assetId], MaxChainBalanceAlreadyAssigned(_assetId));

        // Mark chainBalance as assigned
        maxChainBalanceAssigned[_assetId] = true;

        // Initialize chainBalance
        // For origin chains, chainBalance starts at MAX_TOKEN_BALANCE and decreases as tokens are bridged out
        // We need to account for tokens currently locked in the NTV from previous bridge operations
        uint256 ntvBalance = IERC20(tokenAddress).balanceOf(address(ntv));
        // First, flip the existing chainBalance calculation (was tracking bridged out, now tracks available)
        chainBalance[originChainId][_assetId] = MAX_TOKEN_BALANCE - chainBalance[originChainId][_assetId];
        // Then subtract tokens currently locked in NTV (these were already "bridged out" in pre-V31)
        chainBalance[originChainId][_assetId] -= ntvBalance;
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
        /// otherwise withdrawals might fail in the GWAssetTracker when the chain settles.
        // FIXME
        // require(
        //     savedAssetMigrationNumber == migrationNumber ||
        //         L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == _l1ChainId(),
        //     TokenBalanceNotMigratedToGateway(_assetId, savedAssetMigrationNumber, migrationNumber)
        // );
    }

    /// @notice Handles the initiation of base token bridging operations on L2.
    /// @dev This function is specifically for the chain's native base token used for gas payments.
    /// @param _amount The amount of base tokens being bridged out.
    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external onlyL2BaseTokenSystemContract {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        uint256 baseTokenOriginChainId = L2_NATIVE_TOKEN_VAULT.originChainId(baseTokenAssetId);
        _handleInitiateBridgingOnL2Inner(baseTokenAssetId, _amount, baseTokenOriginChainId);
    }

    /// @notice Handles the finalization of incoming token bridging operations on L2.
    /// @dev This function is called when tokens are bridged into this L2 from another chain.
    /// @param _assetId The asset ID of the token being bridged in.
    /// @param _amount The amount of tokens being bridged in.
    /// @param _tokenOriginChainId The chain ID where this token was originally created.
    /// @param _tokenAddress The contract address of the token on this chain.
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
        revert("Disabled for zksync os");
        // require(
        //     L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() != L1_CHAIN_ID,
        //     OnlyGatewaySettlementLayer()
        // );
        // address tokenAddress = _tryGetTokenAddress(_assetId);

        // uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        // address originalToken = L2_NATIVE_TOKEN_VAULT.originToken(_assetId);

        // uint256 chainMigrationNumber = _getChainMigrationNumber(block.chainid);
        // uint256 assetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        // if (chainMigrationNumber == assetMigrationNumber) {
        //     /// In this case the token was either already migrated, or the migration number was set using _forceSetAssetMigrationNumber.
        //     return;
        // }
        // uint256 amount = _getOrSaveTotalSupply(_assetId, chainMigrationNumber, originChainId, tokenAddress);

        // TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
        //     version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
        //     chainId: block.chainid,
        //     assetId: _assetId,
        //     tokenOriginChainId: originChainId,
        //     amount: amount,
        //     chainMigrationNumber: chainMigrationNumber,
        //     assetMigrationNumber: assetMigrationNumber,
        //     originToken: originalToken,
        //     isL1ToGateway: true
        // });
        // _sendMigrationDataToL1(tokenBalanceMigrationData);

        // emit IL2AssetTracker.L1ToGatewayMigrationInitiated(_assetId, block.chainid, amount);
    }

    /// @notice Confirms a migration operation has been completed and updates the asset migration number.
    /// @dev This function is called by L1 after a migration has been processed to update local state.
    /// @param data The migration confirmation data containing the asset ID and migration number.
    function confirmMigrationOnL2(ConfirmBalanceMigrationData calldata data) external onlyServiceTransactionSender {
        assetMigrationNumber[block.chainid][data.assetId] = data.migrationNumber;
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
