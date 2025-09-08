// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "./IAssetTrackerBase.sol";
import {TokenBalanceMigrationData} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BRIDGEHUB, L2_CHAIN_ASSET_HANDLER, L2_COMPLEX_UPGRADER_ADDR, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

import {AssetIdNotRegistered, TokenBalanceNotMigratedToGateway} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IBridgedStandardToken} from "../BridgedStandardERC20.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";

struct SavedTotalSupply {
    bool isSaved;
    uint256 amount;
}

contract L2AssetTracker is AssetTrackerBase, IL2AssetTracker {
    uint256 public L1_CHAIN_ID;

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

    modifier onlyBaseTokenSystemContract() {
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

    function setAddresses(uint256 _l1ChainId) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view override returns (IBridgehub) {
        return L2_BRIDGEHUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVault) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return L2_MESSAGE_ROOT;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is called for outgoing bridging from the L2, i.e. L2->L1 withdrawals and outgoing L2->L2 interop.
    function handleInitiateBridgingOnL2(bytes32 _assetId, uint256 _amount, uint256 _tokenOriginChainId) public {
        if (_tokenOriginChainId == block.chainid) {
            // We track the total supply on the origin L2 to make sure the token is not maliciously overflowing the sum of chainBalances.
            totalSupplyAcrossAllChains[_assetId] += _amount;
            return;
        }
        _checkAssetMigrationNumber(_assetId);
    }

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

    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external {
        bytes32 baseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        /// Note the tokenOriginChainId, might not be the L1 chain Id, but the base token is bridged from L1,
        /// and we only use the token origin chain id to increase the totalSupplyAcrossAllChains.
        handleInitiateBridgingOnL2(baseTokenAssetId, _amount, L1_CHAIN_ID);
    }

    function handleFinalizeBridgingOnL2(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) public onlyL2NativeTokenVault {
        _handleFinalizeBridgingOnL2Inner(_assetId, _amount, _tokenOriginChainId, _tokenAddress);
    }

    function _handleFinalizeBridgingOnL2Inner(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) internal {
        if (_tokenCanSkipMigrationOnL2(_tokenOriginChainId, _assetId)) {
            _forceSetAssetMigrationNumber(_tokenOriginChainId, _assetId);
        } 

        /// We save the total supply for the first deposit after a migration.
        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        if (!savedTotalSupply[migrationNumber][_assetId].isSaved) {
            /// This function saves the token supply before the first deposit after the chain migration is processed (in the same transaction).
            /// This totalSupply is the chain's total supply at the moment of chain migration.
            savedTotalSupply[migrationNumber][_assetId] = SavedTotalSupply({
                isSaved: true,
                amount: IERC20(_tokenAddress).totalSupply()
            });
        }


        if (_tokenOriginChainId == block.chainid) {
            // We track the total supply on the origin L2 to make sure the token is not maliciously overflowing the sum of chainBalances.
            totalSupplyAcrossAllChains[_assetId] += _amount;
        }
    }

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _amount) external onlyBaseTokenSystemContract {
        bytes32 baseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        if (baseTokenAssetId == bytes32(0)) {
            /// this means we are before the genesis upgrade, where we don't transfer value, so we can skip.
            /// if we don't skip we use incorrect asset id.
            return;
        }
        if (_amount == 0) {
            return;
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
    /// @dev This function is permissionless, it does not affect the state.
    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external {
        address tokenAddress = _tryGetTokenAddress(_assetId);

        uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        address originalToken;
        if (originChainId == block.chainid) {
            originalToken = tokenAddress;
        } else if (originChainId != 0) {
            originalToken = IBridgedStandardToken(tokenAddress).originToken();
        } else {
            /// this is the base token case. We can set the L1 chain id here, we don't store the real origin chainId.
            originChainId = L1_CHAIN_ID;
        }
        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        if (migrationNumber == assetMigrationNumber[block.chainid][_assetId]) {
            /// In this case the token was either already migrated, or the migration number was set using _forceSetAssetMigrationNumber.
            return;
        }
        uint256 amount;
        {
            SavedTotalSupply memory totalSupply = savedTotalSupply[migrationNumber][_assetId];
            if (!totalSupply.isSaved) {
                amount = IERC20(tokenAddress).totalSupply();
            } else {
                amount = totalSupply.amount;
            }
        }

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

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata data) external {
        //onlyServiceTransactionSender {
        assetMigrationNumber[block.chainid][data.assetId] = data.migrationNumber;
    }

    function _sendMigrationDataToL1(TokenBalanceMigrationData memory data) internal {
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodeCall(IAssetTrackerDataEncoding.receiveMigrationOnL1, data)
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    function _registerToken(bytes32 _assetId, address _originalToken, uint256 _tokenOriginChainId) internal {}

    function _tokenCanSkipMigrationOnL2(uint256 _chainId, bytes32 _assetId) internal view returns (bool) {
        uint256 savedAssetMigrationNumber = assetMigrationNumber[_chainId][_assetId];
        address tokenAddress = _tryGetTokenAddress(_assetId);
        uint256 amount = IERC20(tokenAddress).totalSupply();

        return savedAssetMigrationNumber == 0 && amount == 0;
    }

    function _tryGetTokenAddress(bytes32 _assetId) internal view returns (address tokenAddress) {
        tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);

        if (tokenAddress == address(0)) {
            if (_assetId == L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID()) {
                tokenAddress = address(L2_BASE_TOKEN_SYSTEM_CONTRACT);
            } else {
                revert AssetIdNotRegistered(_assetId);
            }
        }
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return L2_CHAIN_ASSET_HANDLER.getMigrationNumber(_chainId);
    }
}
