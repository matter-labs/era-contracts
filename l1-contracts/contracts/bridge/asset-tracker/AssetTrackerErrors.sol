// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {TokenInteropStatus} from "./IAssetTrackerBase.sol";

// 0xda72d995
error AssetIdNotRegistered(bytes32 _assetId);
// 0xa4804d7a
error AssetNotInteroperable(uint256 _chainId, bytes32 _assetId);
// 0x07859b3b
error InsufficientChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount);
// 0x29f90bc0
error InvalidInteropStatus(
    uint256 _chainId,
    bytes32 _assetId,
    TokenInteropStatus _expected,
    TokenInteropStatus _actual
);
// 0x39991f1b
error ChainNotV31(uint256 _chainId);
// 0x95bddd6c
error InvalidAssetMigrationNumber();
// 0xd24c490f
error InvalidBuiltInContractMessage(uint256 logCount, uint256 msgCount, bytes32 key);
// 0x7ad8c2c9
error InvalidCanonicalTxHash(bytes32);
// 0x05208b6d
error InvalidChainMigrationNumber(uint256, uint256);
// 0x24ef4f8a
error InvalidEmptyMessageRoot(bytes32 expectedMessageRoot, bytes32 providedMessageRoot);
// 0x532a43fc
error InvalidFunctionSignature(bytes4 functionSignature);
// 0x37ab3a06
error InvalidMakeInteroperableAssetId(bytes32 _expectedAssetId, bytes32 _actualAssetId);
// 0xfbf8ed35
error InvalidInteropBalanceChange(bytes32 bundleHash);
// 0x203d8be5
error InvalidInteropChainId(uint256 fromChainId, uint256 toChainId);
// 0xeaa867a8
error InvalidL1AssetRouter(address l1AssetRouter);
// 0xe1fe041e
error InvalidL2ShardId();
// 0x9530c5e1
error InvalidMigrationNumber(uint256, uint256);
// 0x4e8e15f3
error InvalidMigrationAmount(uint256 _availableAmount, uint256 _requiredAmount);
// 0xbe49e0f3
error InvalidPreInteropTransformDiff(uint256 _recordedChainBalance, uint256 _reportedTotalSupply);
// 0xddb5de5e
error InvalidSender();
// 0xaca75b50
error InvalidServiceLog();
// 0xd0f0bff7
error InvalidSettlementLayer();
// 0xa9146eeb
error InvalidVersion();
// 0xf76b228a
error InvalidWithdrawalChainId();
// 0xa16d8a80
error L1TotalSupplyAlreadyMigrated();
// 0xda4352c4
error MaxChainBalanceAlreadyAssigned(bytes32 assetId);
// 0x7e472272
error MissingBaseTokenAssetId();
// 0x8fdd5f2e
error NonInteroperableTokenInvalidCounterpart(uint256 _chainId, uint256 _requiredChainId);
// 0xe53f39d2
error NonInteroperableTokenWrongSettlementLayer(uint256 _settlementLayer, uint256 _requiredSettlementLayer);
// 0x8dfed13a
error NotMigratedChain();
// 0x4a22c4b8
error OnlyGatewaySettlementLayer();
// 0x0fd3385e
error OnlyWhitelistedSettlementLayer(address, address);
// 0x174996d5
error RegisterNewTokenNotAllowed();
// 0x90ed63bb
error TokenBalanceNotMigratedToGateway(bytes32, uint256, uint256);
// 0x6e94be79
error TotalSupplyNotAvailableForBaseToken(uint256 _chainId, bytes32 _assetId);
// 0x03a5ba47
error TransientBalanceChangeAlreadySet(uint256 storedAssetId, uint256 storedAmount);
// 0x8c463dfd
error UnexpectedSuccessfulDepositsValue(uint256 _totalSuccessfulDeposits, uint256 _totalDeposited);
