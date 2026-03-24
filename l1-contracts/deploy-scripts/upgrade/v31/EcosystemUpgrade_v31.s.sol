// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";

import {DefaultEcosystemUpgrade} from "../default-upgrade/DefaultEcosystemUpgrade.s.sol";
import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CoreUpgrade_v31} from "./CoreUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "./CTMUpgrade_v31.s.sol";
import {GatewayUpgrade_v31} from "./GatewayUpgrade_v31.s.sol";
import {PermanentValuesHelper} from "../../utils/PermanentValuesHelper.sol";

/// @notice Script used for v31 ecosystem upgrade flow (core + CTM)
/// TODO: IMPORTANT this script should also contain the following steps:
/// - Initialize the previous Gateway migrations via `L1ChainAssetHandler.setHistoricalMigrationInterval`.
/// - Remove the whitelisted settlement layer status from the Era based ZK Gateway `L1Bridgehub.registerSettlementLayer`.
/// - Need to set the initial interop settlement fee on ZK Gateway.
/// - Call "L1ChainAssetHandler.setAddresses()"
contract EcosystemUpgrade_v31 is DefaultEcosystemUpgrade {
    /// @notice Create v31-specific core upgrade instance
    function createCoreUpgrade() internal virtual override returns (DefaultCoreUpgrade) {
        return new CoreUpgrade_v31();
    }

    /// @notice Create v31-specific CTM upgrade instance
    function createCTMUpgrade() internal virtual override returns (DefaultCTMUpgrade) {
        return new CTMUpgrade_v31();
    }

    /// @notice Override to set core output path
    function getCoreOutputPath(string memory _ecosystemOutputPath) internal virtual override returns (string memory) {
        // Use hardcoded path for v31 core output
        return "/script-out/v31-upgrade-core.toml";
    }

    /// @notice Override to set CTM output path
    function getCTMOutputPath() internal virtual override returns (string memory) {
        // Use hardcoded path for v31 CTM output
        return "/script-out/v31-upgrade-ctm.toml";
    }

    /// @notice Initialize with v31-specific permanent values preparation
    function initialize(
        string memory permanentValuesInputPath,
        string memory upgradeInputPath,
        string memory _ecosystemOutputPath
    ) public override {
        permanentValuesInputPath;
        upgradeInputPath;
        _ecosystemOutputPath;
        revert("EcosystemUpgrade_v31.initialize(permanent-values path,...) is deprecated. Use initializeWithArgs(...)");
    }

    function initializeWithArgs(
        address bridgehubProxyAddress,
        address ctmProxy,
        address bytecodesSupplier,
        address rollupDAManager,
        bool isZKsyncOS,
        bytes32 create2FactorySalt,
        string memory upgradeInputPath,
        string memory _ecosystemOutputPath,
        address governance
    ) public override {
        create2FactorySalt;
        (, bytes32 loadedSalt) = PermanentValuesHelper.getPermanentValues();
        string memory root = vm.projectRoot();
        ecosystemOutputPath = string.concat(root, _ecosystemOutputPath);

        // Get output paths (these return relative paths)
        string memory _coreOutputPath = getCoreOutputPath(_ecosystemOutputPath);
        string memory _ctmOutputPath = getCTMOutputPath();

        // Store full paths for later use
        coreOutputPath = string.concat(root, _coreOutputPath);
        ctmOutputPath = string.concat(root, _ctmOutputPath);

        // Create v31 core upgrade
        coreUpgrade = createCoreUpgrade();
        coreUpgrade.initializeWithArgs(
            bridgehubProxyAddress,
            isZKsyncOS,
            loadedSalt,
            upgradeInputPath,
            _coreOutputPath
        );
        _coreInitialized = true;

        // Initialize CTM upgrade with its own output path
        ctmUpgrade = createCTMUpgrade();
        ctmUpgrade.initializeWithArgs(
            ctmProxy,
            bytecodesSupplier,
            isZKsyncOS,
            rollupDAManager,
            loadedSalt,
            upgradeInputPath,
            _ctmOutputPath,
            governance
        );
        _ctmInitialized = true;

        // Allow subclasses to override protocol version for local testing
        overrideProtocolVersionForLocalTesting(upgradeInputPath);
    }

    function noGovernancePrepareWithArgs(
        address bridgehubProxyAddress,
        address ctmProxy,
        address bytecodesSupplier,
        address rollupDAManager,
        bool isZKsyncOS,
        string memory upgradeInputPath,
        string memory _ecosystemOutputPath,
        address governance
    ) public {
        initializeWithArgs(
            bridgehubProxyAddress,
            ctmProxy,
            bytecodesSupplier,
            rollupDAManager,
            isZKsyncOS,
            bytes32(0),
            upgradeInputPath,
            _ecosystemOutputPath,
            governance
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    /// @notice E2e upgrade generation
    function run() public override {
        revert(
            "EcosystemUpgrade_v31.run() is deprecated. Use --sig initializeWithArgs(...) and call preparation methods explicitly"
        );
    }

    /// @notice Stage 3: Post-governance migration tasks
    /// @dev This should be called after stage 0, 1, and 2 governance calls are executed
    /// @dev Can be called with any private key (doesn't need to be governance)
    function stage3(address bridgehubProxy) public {
        console.log("Starting v31 stage3 post-governance migration...");
        console.log("Bridgehub proxy:", bridgehubProxy);

        // Get contract addresses
        IBridgehubBase bridgehub = IBridgehubBase(bridgehubProxy);
        IL1AssetRouter assetRouter = IL1AssetRouter(address(bridgehub.assetRouter()));
        L1NativeTokenVault ntv = L1NativeTokenVault(payable(address(assetRouter.nativeTokenVault())));
        IL1AssetTracker assetTracker = ntv.l1AssetTracker();

        console.log("AssetRouter:", address(assetRouter));
        console.log("NativeTokenVault:", address(ntv));
        console.log("AssetTracker:", address(assetTracker));

        require(address(assetTracker) != address(0), "AssetTracker not set");

        // Migrate token balances from NTV to AssetTracker
        registerBridgedTokensInNTV(address(bridgehub));
        migrateTokenBalances(address(ntv), address(assetTracker), bridgehub);

        console.log("v31 stage3 migration complete!");
    }

    /// @notice Migrate token balances for a specific chain
    function migrateTokenBalancesForChain(
        uint256 chainId,
        L1NativeTokenVault ntv,
        IL1AssetTracker assetTracker
    ) internal {
        console.log("Processing chain:", chainId);

        uint256 tokenCount = ntv.bridgedTokensCount();

        for (uint256 j = 0; j < tokenCount; ++j) {
            bytes32 assetId = ntv.bridgedTokens(j);

            // Check if there's a balance to migrate
            uint256 balance = ntv.chainBalance(chainId, assetId);
            if (balance > 0) {
                address tokenAddress = ntv.tokenAddress(assetId);
                console.log("  Migrating token:", tokenAddress);
                console.log("  AssetId:", vm.toString(assetId));
                console.log("  Balance:", balance);

                // Call AssetTracker to migrate the balance
                vm.broadcast(getBroadcasterAddress());
                assetTracker.registerLegacyToken(assetId);

                console.log("  Migration successful");
            }
        }
    }

    /// @notice Migrate token balances from DEPRECATED_chainBalance to AssetTracker
    function migrateTokenBalances(address _ntv, address _assetTracker, IBridgehubBase _bridgehub) internal {
        console.log("Migrating token balances...");

        L1NativeTokenVault ntv = L1NativeTokenVault(payable(_ntv));
        IL1AssetTracker assetTracker = IL1AssetTracker(_assetTracker);

        // Get bridged token count
        uint256 tokenCount = ntv.bridgedTokensCount();
        console.log("Number of bridged tokens:", tokenCount);

        // First, migrate balances for the L1 chain itself
        uint256 l1ChainId = block.chainid;
        console.log("Migrating L1 chain balances (chainId:", l1ChainId, ")");
        migrateTokenBalancesForChain(l1ChainId, ntv, assetTracker);

        // Get list of registered L2 chains
        uint256[] memory chainIds = _bridgehub.getAllZKChainChainIDs();
        console.log("Number of L2 chains:", chainIds.length);

        // For each L2 chain and each token, migrate the balance
        for (uint256 i = 0; i < chainIds.length; ++i) {
            migrateTokenBalancesForChain(chainIds[i], ntv, assetTracker);
        }

        console.log("Token balance migration complete");
    }

    /// @notice Register legacy bridged tokens (if needed)
    /// @dev For production use, this function should be extended to register all bridged tokens
    /// from a config file or by querying on-chain state. Currently only registers ETH for fresh deployments.
    function registerBridgedTokensInNTV(address _bridgehub) public {
        console.log("Registering bridged tokens in NTV...");

        NativeTokenVaultBase ntv = NativeTokenVaultBase(
            address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault())
        );

        // For fresh deployments, register the ETH base token
        // ETH token address is 0x0000000000000000000000000000000000000001
        address ethTokenAddress = address(0x0000000000000000000000000000000000000001);

        // Get the assetId for ETH from NTV
        bytes32 ethAssetId = ntv.assetId(ethTokenAddress);
        console.log("ETH token address:", ethTokenAddress);
        console.log("ETH assetId:", vm.toString(ethAssetId));

        // TODO: For production, extend this to register all bridged tokens from config
        // Create array with ETH assetId
        bytes32[] memory savedBridgedTokens = new bytes32[](1);
        savedBridgedTokens[0] = ethAssetId;

        console.log("Registering tokens, count:", savedBridgedTokens.length);

        /// Register tokens in the bridged token list
        for (uint256 i = 0; i < savedBridgedTokens.length; ++i) {
            bytes32 assetId = savedBridgedTokens[i];
            address tokenAddress = ntv.tokenAddress(assetId);
            console.log("  Registering assetId:", vm.toString(assetId));
            console.log("  Token address:", tokenAddress);

            vm.broadcast(getBroadcasterAddress());
            ntv.addLegacyTokenToBridgedTokensList(tokenAddress);

            console.log("  Token registered successfully");
        }

        console.log("Bridged tokens registration complete");
    }

    function getBroadcasterAddress() internal view virtual returns (address) {
        return tx.origin;
    }
}
