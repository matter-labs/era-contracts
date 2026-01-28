// SPDX-License-Identifier: MIT
// ZKSync-compatible version of SharedL2ContractDeployer that doesn't use EXTCODECOPY

pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";
import "forge-std/console.sol";

import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";

import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {L2Utils} from "./L2Utils.sol";
import {SystemContractsArgs} from "./L2Utils.sol";

import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";

import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";

/// @notice ZKSync-compatible L2 contract deployer for tests
/// This version does NOT use .code or EXTCODECOPY which are unsupported in EraVM
/// It extends SharedL2ContractDeployer and overrides methods that would use EXTCODECOPY
contract SharedL2ContractL2Deployer is SharedL2ContractDeployer {
    using stdToml for string;

    // Override to use L2Utils for system contract initialization
    function initSystemContracts(SystemContractsArgs memory _args) internal virtual override {
        L2Utils.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual override returns (address) {
        console.log("Deploying via create2 L2");
        return L2Utils.deployViaCreat2L2(creationCode, constructorArgs, create2FactoryParams.factorySalt);
    }

    /// @notice Override to use hardcoded chain creation params (avoids TOML parsing issues in zkSync)
    function getChainCreationParamsConfig(
        string memory
    ) internal virtual override returns (ChainCreationParamsConfig memory chainCreationParams) {
        chainCreationParams.genesisRoot = bytes32(0x1000000000000000000000000000000000000000000000000000000000000000);
        chainCreationParams.genesisRollupLeafIndex = 1;
        chainCreationParams.genesisBatchCommitment = bytes32(0x1000000000000000000000000000000000000000000000000000000000000000);
        chainCreationParams.latestProtocolVersion = 120259084288;
        chainCreationParams.bootloaderHash = bytes32(0x0100085F9382A7928DD83BFC529121827B5F29F18B9AA10D18AA68E1BE7DDC35);
        chainCreationParams.defaultAAHash = bytes32(0x010005F767ED85C548BCE536C18ED2E1643CA8A6F27EE40826D6936AEA0C87D4);
        chainCreationParams.evmEmulatorHash = bytes32(0x01000D83E0329D9144AD041430FAFCBC2B388E5434DB8CB8A96E80157738A1DA);
    }

    /// @notice Override to use hardcoded selectors instead of .code extraction (avoids EXTCODECOPY)
    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        facetCuts = new Diamond.FacetCut[](4);

        // Hardcoded selectors for AdminFacet
        bytes4[] memory adminSelectors = new bytes4[](24);
        adminSelectors[0] = AdminFacet.setPendingAdmin.selector;
        adminSelectors[1] = AdminFacet.acceptAdmin.selector;
        adminSelectors[2] = AdminFacet.setValidator.selector;
        adminSelectors[3] = AdminFacet.setPorterAvailability.selector;
        adminSelectors[4] = AdminFacet.setPriorityTxMaxGasLimit.selector;
        adminSelectors[5] = AdminFacet.changeFeeParams.selector;
        adminSelectors[6] = AdminFacet.setTokenMultiplier.selector;
        adminSelectors[7] = AdminFacet.setPubdataPricingMode.selector;
        adminSelectors[8] = AdminFacet.setTransactionFilterer.selector;
        adminSelectors[9] = AdminFacet.getRollupDAManager.selector;
        adminSelectors[10] = AdminFacet.setDAValidatorPair.selector;
        adminSelectors[11] = AdminFacet.makePermanentRollup.selector;
        adminSelectors[12] = AdminFacet.allowEvmEmulation.selector;
        adminSelectors[13] = AdminFacet.upgradeChainFromVersion.selector;
        adminSelectors[14] = AdminFacet.executeUpgrade.selector;
        adminSelectors[15] = AdminFacet.genesisUpgrade.selector;
        adminSelectors[16] = AdminFacet.freezeDiamond.selector;
        adminSelectors[17] = AdminFacet.unfreezeDiamond.selector;
        adminSelectors[18] = AdminFacet.pauseDepositsBeforeInitiatingMigration.selector;
        adminSelectors[19] = AdminFacet.unpauseDeposits.selector;
        adminSelectors[20] = AdminFacet.forwardedBridgeBurn.selector;
        adminSelectors[21] = AdminFacet.forwardedBridgeMint.selector;
        adminSelectors[22] = AdminFacet.forwardedBridgeConfirmTransferResult.selector;
        adminSelectors[23] = AdminFacet.prepareChainCommitment.selector;

        facetCuts[0] = Diamond.FacetCut({
            facet: stateTransition.facets.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: adminSelectors
        });

        // Hardcoded selectors for GettersFacet
        bytes4[] memory gettersSelectors = new bytes4[](30);
        gettersSelectors[0] = GettersFacet.getVerifier.selector;
        gettersSelectors[1] = GettersFacet.getAdmin.selector;
        gettersSelectors[2] = GettersFacet.getPendingAdmin.selector;
        gettersSelectors[3] = GettersFacet.getTotalBatchesCommitted.selector;
        gettersSelectors[4] = GettersFacet.getTotalBatchesVerified.selector;
        gettersSelectors[5] = GettersFacet.getTotalBatchesExecuted.selector;
        gettersSelectors[6] = GettersFacet.getTotalPriorityTxs.selector;
        gettersSelectors[7] = GettersFacet.getFirstUnprocessedPriorityTx.selector;
        gettersSelectors[8] = GettersFacet.getPriorityQueueSize.selector;
        gettersSelectors[9] = GettersFacet.isPriorityQueueActive.selector;
        gettersSelectors[10] = GettersFacet.isValidator.selector;
        gettersSelectors[11] = GettersFacet.l2LogsRootHash.selector;
        gettersSelectors[12] = GettersFacet.storedBatchHash.selector;
        gettersSelectors[13] = GettersFacet.getL2BootloaderBytecodeHash.selector;
        gettersSelectors[14] = GettersFacet.getL2DefaultAccountBytecodeHash.selector;
        gettersSelectors[15] = GettersFacet.getVerifierParams.selector;
        gettersSelectors[16] = GettersFacet.isDiamondStorageFrozen.selector;
        gettersSelectors[17] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        gettersSelectors[18] = GettersFacet.isEthWithdrawalFinalized.selector;
        gettersSelectors[19] = GettersFacet.facets.selector;
        gettersSelectors[20] = GettersFacet.facetFunctionSelectors.selector;
        gettersSelectors[21] = GettersFacet.facetAddresses.selector;
        gettersSelectors[22] = GettersFacet.facetAddress.selector;
        gettersSelectors[23] = GettersFacet.isFunctionFreezable.selector;
        gettersSelectors[24] = GettersFacet.isFacetFreezable.selector;
        gettersSelectors[25] = GettersFacet.getProtocolVersion.selector;
        gettersSelectors[26] = GettersFacet.getPubdataPricingMode.selector;
        gettersSelectors[27] = GettersFacet.getChainId.selector;
        gettersSelectors[28] = GettersFacet.baseTokenGasPriceMultiplierNominator.selector;
        gettersSelectors[29] = GettersFacet.baseTokenGasPriceMultiplierDenominator.selector;

        facetCuts[1] = Diamond.FacetCut({
            facet: stateTransition.facets.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: gettersSelectors
        });

        // Hardcoded selectors for MailboxFacet
        bytes4[] memory mailboxSelectors = new bytes4[](7);
        mailboxSelectors[0] = MailboxFacet.proveL2MessageInclusion.selector;
        mailboxSelectors[1] = MailboxFacet.proveL2LogInclusion.selector;
        mailboxSelectors[2] = MailboxFacet.proveL1ToL2TransactionStatus.selector;
        mailboxSelectors[3] = MailboxFacet.finalizeEthWithdrawal.selector;
        mailboxSelectors[4] = MailboxFacet.requestL2Transaction.selector;
        mailboxSelectors[5] = MailboxFacet.bridgehubRequestL2Transaction.selector;
        mailboxSelectors[6] = MailboxFacet.l2TransactionBaseCost.selector;

        facetCuts[2] = Diamond.FacetCut({
            facet: stateTransition.facets.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: mailboxSelectors
        });

        // Hardcoded selectors for ExecutorFacet
        bytes4[] memory executorSelectors = new bytes4[](4);
        executorSelectors[0] = ExecutorFacet.commitBatchesSharedBridge.selector;
        executorSelectors[1] = ExecutorFacet.proveBatchesSharedBridge.selector;
        executorSelectors[2] = ExecutorFacet.executeBatchesSharedBridge.selector;
        executorSelectors[3] = ExecutorFacet.revertBatchesSharedBridge.selector;

        facetCuts[3] = Diamond.FacetCut({
            facet: stateTransition.facets.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: executorSelectors
        });
    }

    /// @notice Implement abstract deployL2Contracts from parent
    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        // No-op for L2 context - L2 contracts are deployed via system contract mechanisms
        // Tests that need specific L2 contract deployment override this method
    }

    /// @notice Provide L2-specific mock calls (shadows parent since parent function is not virtual)
    function mockDiamondInitInteropCenterCallsWithAddress(
        address bridgehub,
        address assetRouter,
        bytes32 _baseTokenAssetId
    ) public virtual {
        address nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
        if (assetRouter == address(0)) {
            assetRouter = makeAddr("assetRouter");
            nativeTokenVault = makeAddr("nativeTokenVault");
        }

        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(assetRouter));
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(nativeTokenVault)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, _baseTokenAssetId),
            abi.encode(block.chainid)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, _baseTokenAssetId),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
    }

    // Add this to be excluded from coverage report
    function test() internal virtual override {}
}
