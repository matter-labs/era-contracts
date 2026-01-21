// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdToml} from "forge-std/Test.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2Utils} from "./L2Utils.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-abstract/Utils.sol";
import {ADDRESS_ONE} from "deploy-scripts/utils/Utils.sol";

import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
// import {DeployCTMIntegrationScript} from "../../l1/integration/deploy-scripts/DeployCTMIntegration.s.sol";

import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2WrappedBaseToken} from "contracts/bridge/L2WrappedBaseToken.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_ASSET_ROUTER} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ChainCreationParamsConfig} from "deploy-scripts/utils/Types.sol";

contract SharedL2ContractL2Deployer is SharedL2ContractDeployer {
    using stdToml for string;

    /// @notice Override to avoid library delegatecall issues in ZKsync mode
    /// Returns hardcoded values from the test config
    function getChainCreationParamsConfig(
        string memory /* _config */
    ) internal virtual override returns (ChainCreationParamsConfig memory chainCreationParams) {
        // Values from config-deploy-ctm.toml
        chainCreationParams.genesisRoot = bytes32(0x1000000000000000000000000000000000000000000000000000000000000000);
        chainCreationParams.genesisRollupLeafIndex = 1;
        chainCreationParams.genesisBatchCommitment = bytes32(
            0x1000000000000000000000000000000000000000000000000000000000000000
        );
        chainCreationParams.latestProtocolVersion = 120259084288;
        chainCreationParams.bootloaderHash = bytes32(
            0x0100085F9382A7928DD83BFC529121827B5F29F18B9AA10D18AA68E1BE7DDC35
        );
        chainCreationParams.defaultAAHash = bytes32(0x010005F767ED85C548BCE536C18ED2E1643CA8A6F27EE40826D6936AEA0C87D4);
        chainCreationParams.evmEmulatorHash = bytes32(
            0x01000D83E0329D9144AD041430FAFCBC2B388E5434DB8CB8A96E80157738A1DA
        );
    }

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual override {
        L2Utils.initSystemContracts(_args);
    }

    /// @notice Override setUpInner to use vm.etch instead of new to avoid foundry-zksync crashes
    function setUpInner(bool _skip) public virtual override {
        // Timestamp needs to be big enough for `pauseDepositsBeforeInitiatingMigration` time checks
        vm.warp(PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET + 1);

        if (_skip) {
            vm.startBroadcast();
        }

        // Deploy BridgedStandardERC20 using vm.etch
        bytes memory erc20Bytecode = Utils.readZKFoundryBytecodeL1("BridgedStandardERC20.sol", "BridgedStandardERC20");
        address erc20ImplAddr = makeAddr("bridgedStandardERC20Impl");
        vm.etch(erc20ImplAddr, erc20Bytecode);
        standardErc20Impl = BridgedStandardERC20(erc20ImplAddr);

        // Deploy UpgradeableBeacon using vm.etch
        bytes memory beaconBytecode = Utils.readFoundryBytecodeL1("UpgradeableBeacon.sol", "UpgradeableBeacon");
        address beaconAddr = makeAddr("upgradeableBeacon");
        vm.etch(beaconAddr, beaconBytecode);
        beacon = UpgradeableBeacon(beaconAddr);
        // Mock the implementation() call to return our erc20 impl
        vm.mockCall(
            beaconAddr,
            abi.encodeWithSelector(UpgradeableBeacon.implementation.selector),
            abi.encode(erc20ImplAddr)
        );

        // Deploy BeaconProxy using vm.etch
        bytes memory beaconProxyBytecode = Utils.readFoundryBytecodeL1("BeaconProxy.sol", "BeaconProxy");
        address beaconProxyAddr = makeAddr("beaconProxy");
        vm.etch(beaconProxyAddr, beaconProxyBytecode);
        proxy = BeaconProxy(payable(beaconProxyAddr));

        // Use a simple bytecode hash for testing
        bytes32 beaconProxyBytecodeHash = keccak256(beaconProxyBytecode);

        UNBUNDLER_ADDRESS = makeAddr("unbundlerAddress");
        EXECUTION_ADDRESS = makeAddr("executionAddress");

        interopTargetContract = makeAddr("interopTargetContract");
        originalChainId = block.chainid;

        coreAddresses.bridgehub.proxies.bridgehub = L2_BRIDGEHUB_ADDR;
        sharedBridgeLegacy = deployL2SharedBridgeLegacyEtch(
            L1_CHAIN_ID,
            ERA_CHAIN_ID,
            ownerWallet,
            l1AssetRouter,
            beaconProxyBytecodeHash
        );

        L2WrappedBaseToken deployedWeth = deployL2Weth();
        if (_skip) {
            vm.stopBroadcast();
        }
        initSystemContracts(
            SystemContractsArgs({
                broadcast: _skip,
                l1ChainId: L1_CHAIN_ID,
                eraChainId: ERA_CHAIN_ID,
                gatewayChainId: GATEWAY_CHAIN_ID,
                l1AssetRouter: l1AssetRouter,
                legacySharedBridge: sharedBridgeLegacy,
                l2TokenBeacon: address(beacon),
                l2TokenProxyBytecodeHash: beaconProxyBytecodeHash,
                aliasedOwner: ownerWallet,
                contractsDeployedAlready: false,
                l1CtmDeployer: l1CTMDeployer,
                maxNumberOfZKChains: 100
            })
        );
        if (!_skip) {
            deployL2Contracts(L1_CHAIN_ID);

            vm.prank(aliasedL1AssetRouter);
            l2AssetRouter.setAssetHandlerAddress(L1_CHAIN_ID, ctmAssetId, L2_CHAIN_ASSET_HANDLER_ADDR);
            vm.prank(ownerWallet);
            l2Bridgehub.addChainTypeManager(address(ctmAddresses.stateTransition.proxies.chainTypeManager));
            vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1CTMDeployer));
            l2Bridgehub.setCTMAssetAddress(
                bytes32(uint256(uint160(l1CTM))),
                address(ctmAddresses.stateTransition.proxies.chainTypeManager)
            );
            chainTypeManager = IChainTypeManager(address(ctmAddresses.stateTransition.proxies.chainTypeManager));
            getExampleChainCommitment();
        }

        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );
        bytes32 realBaseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, block.chainid),
            abi.encode(realBaseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.mint.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            address(interopTargetContract),
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );
    }

    /// @notice Deploy L2SharedBridgeLegacy using vm.etch to avoid foundry-zksync crash
    function deployL2SharedBridgeLegacyEtch(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1SharedBridge,
        bytes32 _l2TokenProxyBytecodeHash
    ) internal returns (address) {
        // Deploy L2SharedBridgeLegacy implementation using vm.etch
        bytes memory bridgeBytecode = Utils.readZKFoundryBytecodeL1("L2SharedBridgeLegacy.sol", "L2SharedBridgeLegacy");
        address bridgeImplAddr = makeAddr("l2SharedBridgeLegacyImpl");
        vm.etch(bridgeImplAddr, bridgeBytecode);

        // For simplicity, use the implementation directly with initialization via mock/storage
        // This avoids deploying a TransparentUpgradeableProxy which also crashes
        L2SharedBridgeLegacy bridge = L2SharedBridgeLegacy(bridgeImplAddr);

        // Initialize the bridge - we need to set up the storage slots manually
        // since we can't call the initializer through a proxy
        vm.store(bridgeImplAddr, bytes32(uint256(0)), bytes32(uint256(1))); // _initialized = 1
        vm.store(bridgeImplAddr, bytes32(uint256(201)), bytes32(uint256(uint160(_l1SharedBridge)))); // l1SharedBridge
        vm.store(bridgeImplAddr, bytes32(uint256(202)), _l2TokenProxyBytecodeHash); // l2TokenProxyBytecodeHash

        console.log("bridge (etched)", bridgeImplAddr);
        return bridgeImplAddr;
    }

    /// @notice this is duplicate code, but the inheritance is already complex
    /// here we have to deploy contracts manually with new Contract(), because that can be handled by the compiler.
    function deployL2Contracts(uint256 _l1ChainId) public virtual override {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm.toml"
        );
        string memory permanentValuesInputPath = string.concat(
            root,
            "/test/foundry/l1/integration/deploy-scripts/script-config/permanent-values.toml"
        );

        initializeConfig(inputPath, permanentValuesInputPath, L2_BRIDGEHUB_ADDR);
        ctmAddresses.admin.transparentProxyAdmin = address(0x1);
        ctmAddresses.admin.governance = address(0x2); // Mock governance for tests
        config.l1ChainId = _l1ChainId;
        // Generate mock force deployments data for L2 tests
        _generateMockForceDeploymentsData(_l1ChainId);
        console.log("Deploying L2 contracts");
        instantiateCreate2Factory();
        ctmAddresses.stateTransition.genesisUpgrade = address(new L1GenesisUpgrade());
        ctmAddresses.stateTransition.verifiers.verifier = address(
            new EraTestnetVerifier(IVerifierV2(ADDRESS_ONE), IVerifier(ADDRESS_ONE))
        );
        uint32 executionDelay = uint32(config.contracts.validatorTimelockExecutionDelay);
        ctmAddresses.stateTransition.proxies.validatorTimelock = address(
            new TransparentUpgradeableProxy(
                address(new ValidatorTimelock(L2_BRIDGEHUB_ADDR)),
                ctmAddresses.admin.transparentProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (config.deployerAddress, executionDelay))
            )
        );
        ctmAddresses.stateTransition.facets.executorFacet = address(new ExecutorFacet(config.l1ChainId));
        ctmAddresses.stateTransition.facets.adminFacet = address(
            new AdminFacet(config.l1ChainId, RollupDAManager(ctmAddresses.daAddresses.rollupDAManager), false)
        );
        ctmAddresses.stateTransition.facets.mailboxFacet = address(
            new MailboxFacet(
                config.eraChainId,
                config.l1ChainId,
                L2_CHAIN_ASSET_HANDLER_ADDR,
                IEIP7702Checker(address(0)),
                false
            )
        );
        ctmAddresses.stateTransition.facets.gettersFacet = address(new GettersFacet());
        ctmAddresses.stateTransition.facets.diamondInit = address(new DiamondInit(false));

        // Prepare force deployments data for testing
        generatedData.forceDeploymentsData = _prepareForceDeploymentsData();

        // Deploy ChainTypeManager implementation
        if (config.isZKsyncOS) {
            ctmAddresses.stateTransition.implementations.chainTypeManager = address(
                new ZKsyncOSChainTypeManager(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0))
            );
        } else {
            ctmAddresses.stateTransition.implementations.chainTypeManager = address(
                new EraChainTypeManager(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0))
            );
        }

        // Deploy TransparentUpgradeableProxy for ChainTypeManager
        bytes memory initCalldata = abi.encodeCall(
            IChainTypeManager.initialize,
            getChainTypeManagerInitializeData(ctmAddresses.stateTransition)
        );

        ctmAddresses.stateTransition.proxies.chainTypeManager = address(
            new TransparentUpgradeableProxy(
                ctmAddresses.stateTransition.implementations.chainTypeManager,
                ctmAddresses.admin.transparentProxyAdmin,
                initCalldata
            )
        );
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual override returns (address) {
        console.log("Deploying via create2 L2");
        return L2Utils.deployViaCreat2L2(creationCode, constructorArgs, create2FactoryParams.factorySalt);
    }

    /// @notice Prepares minimal force deployments data for L2 testing
    function _prepareForceDeploymentsData() internal view returns (bytes memory) {
        FixedForceDeploymentsData memory data = FixedForceDeploymentsData({
            l1ChainId: config.l1ChainId,
            gatewayChainId: config.gatewayChainId,
            eraChainId: config.eraChainId,
            l1AssetRouter: L2_ASSET_ROUTER_ADDR,
            l2TokenProxyBytecodeHash: bytes32(0),
            aliasedL1Governance: address(0),
            maxNumberOfZKChains: 100,
            bridgehubBytecodeInfo: abi.encode(bytes32(0)),
            l2AssetRouterBytecodeInfo: abi.encode(bytes32(0)),
            l2NtvBytecodeInfo: abi.encode(bytes32(0)),
            messageRootBytecodeInfo: abi.encode(bytes32(0)),
            chainAssetHandlerBytecodeInfo: abi.encode(bytes32(0)),
            interopCenterBytecodeInfo: abi.encode(bytes32(0)),
            interopHandlerBytecodeInfo: abi.encode(bytes32(0)),
            assetTrackerBytecodeInfo: abi.encode(bytes32(0)),
            beaconDeployerInfo: abi.encode(bytes32(0)),
            l2SharedBridgeLegacyImpl: address(0),
            l2BridgedStandardERC20Impl: address(0),
            aliasedChainRegistrationSender: address(0),
            dangerousTestOnlyForcedBeacon: address(0)
        });
        return abi.encode(data);
    }

    /// @notice Override deployL2Weth to use vm.etch to avoid foundry-zksync crash
    /// @dev This is a workaround for a bug in foundry-zksync where certain contracts
    /// cannot be deployed using `new` in the zkSync EVM environment
    function deployL2Weth() internal virtual override returns (L2WrappedBaseToken) {
        // Read the bytecode from the zkout artifacts
        bytes memory wethBytecode = Utils.readZKFoundryBytecodeL1("L2WrappedBaseToken.sol", "L2WrappedBaseToken");

        // Deploy implementation using vm.etch
        address wethImplAddr = makeAddr("wethImpl");
        vm.etch(wethImplAddr, wethBytecode);

        // For the proxy, we use a simple approach: just use the implementation directly
        // since proxy deployment also has issues with foundry-zksync
        weth = L2WrappedBaseToken(payable(wethImplAddr));

        // Initialize the WETH contract
        weth.initializeV3("Wrapped Ether", "WETH", L2_ASSET_ROUTER_ADDR, l1WethAddress, baseTokenAssetId);

        return weth;
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}

    /// @notice Generate mock force deployments data for L2 tests using a pre-encoded value
    function _generateMockForceDeploymentsData(uint256) internal {
        // Use pre-generated force deployments data to avoid bytecode size issues
        // This is the same as what would be generated by _buildForceDeploymentsData
        generatedData
            .forceDeploymentsData = hex"00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000007b0000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000101000000000000000000000000000000000000000000000000000000000000001111000000000000000000000000000000000000000000000000000000000001100000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000028000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000048000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020010000000000000000000000000000000000000000000000000000000000000000";
    }
}
