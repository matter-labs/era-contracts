// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "../Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {GatewayUpgrade} from "contracts/upgrades/GatewayUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {AddressHasNoCode} from "../ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {Call} from "contracts/governance/Common.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_FORCE_DEPLOYER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {GatewayUpgradeEncodedInput} from "contracts/upgrades/GatewayUpgrade.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {SystemContractsProcessing} from "./SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "./BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {Create2AndTransfer} from "../Create2AndTransfer.sol";

import {DeployL1Script} from "../DeployL1.s.sol";

contract EcosystemUpgrade_v27_1 is Script, DeployL1Script {
    using stdToml for string;

    bytes internal oldEncodedChainCreationParams;

    function run() public override {
        string memory root = vm.projectRoot();

        initializeConfig(string.concat(root, vm.envString("UPGRADE_ECOSYSTEM_INPUT")));
        instantiateCreate2Factory();
        deployBlobVersionedHashRetriever();

        ChainCreationParams memory oldChainCreationParams = abi.decode(
            oldEncodedChainCreationParams,
            (ChainCreationParams)
        );
        Diamond.DiamondCutData memory oldDiamondCut = oldChainCreationParams.diamondCut;
        DiamondInitializeDataNewChain memory oldInitializeData = abi.decode(
            oldDiamondCut.initCalldata,
            (DiamondInitializeDataNewChain)
        );

        // We only change blobVerionedHashRetriever
        oldInitializeData.blobVersionedHashRetriever = addresses.blobVersionedHashRetriever;
        Diamond.DiamondCutData memory newDiamondCut = Diamond.DiamondCutData({
            facetCuts: oldDiamondCut.facetCuts,
            initAddress: oldDiamondCut.initAddress,
            initCalldata: abi.encode(oldInitializeData)
        });
        ChainCreationParams memory newChainCreationParams = ChainCreationParams({
            genesisUpgrade: oldChainCreationParams.genesisUpgrade,
            genesisBatchHash: oldChainCreationParams.genesisBatchHash,
            genesisIndexRepeatedStorageChanges: oldChainCreationParams.genesisIndexRepeatedStorageChanges,
            genesisBatchCommitment: oldChainCreationParams.genesisBatchCommitment,
            diamondCut: newDiamondCut,
            forceDeploymentsData: oldChainCreationParams.forceDeploymentsData
        });

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(ChainTypeManager.setChainCreationParams, (newChainCreationParams)),
            value: 0
        });

        saveOutput(
            string.concat(root, vm.envString("UPGRADE_ECOSYSTEM_OUTPUT")),
            abi.encode(calls),
            abi.encode(newDiamondCut)
        );
    }

    function initializeConfig(string memory newConfigPath) internal virtual override {
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        addresses.stateTransition.bytecodesSupplier = toml.readAddress("$.contracts.l1_bytecodes_supplier_addr");

        addresses.bridgehub.bridgehubProxy = toml.readAddress("$.contracts.bridgehub_proxy_address");

        setAddressesBasedOnBridgehub();

        addresses.transparentProxyAdmin = toml.readAddress("$.contracts.transparent_proxy_admin");
        addresses.protocolUpgradeHandlerProxy = toml.readAddress("$.contracts.protocol_upgrade_handler_proxy_address");

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");

        addresses.daAddresses.rollupDAManager = toml.readAddress("$.contracts.rollup_da_manager");

        oldEncodedChainCreationParams = toml.readBytes("$.v27_chain_creation_params");
    }

    function setAddressesBasedOnBridgehub() internal virtual {
        config.ownerAddress = Bridgehub(addresses.bridgehub.bridgehubProxy).owner();
        address ctm = Bridgehub(addresses.bridgehub.bridgehubProxy).chainTypeManager(config.eraChainId);
        addresses.stateTransition.chainTypeManagerProxy = ctm;
        // We have to set the diamondProxy address here - as it is used by multiple constructors (for example L1Nullifier etc)
        addresses.stateTransition.diamondProxy = Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(
            config.eraChainId
        );
        addresses.bridges.l1AssetRouterProxy = Bridgehub(addresses.bridgehub.bridgehubProxy).assetRouter();

        addresses.vaults.l1NativeTokenVaultProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).nativeTokenVault()
        );
        addresses.bridges.l1NullifierProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).L1_NULLIFIER()
        );

        addresses.bridgehub.ctmDeploymentTrackerProxy = address(
            Bridgehub(addresses.bridgehub.bridgehubProxy).l1CtmDeployer()
        );

        addresses.bridgehub.messageRootProxy = address(Bridgehub(addresses.bridgehub.bridgehubProxy).messageRoot());

        addresses.bridges.erc20BridgeProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).legacyBridge()
        );

        address eraDiamondProxy = Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(config.eraChainId);
        (addresses.daAddresses.l1RollupDAValidator, ) = GettersFacet(eraDiamondProxy).getDAValidatorPair();
    }

    function saveOutput(string memory outputPath, bytes memory encodedCalls, bytes memory newDiamondCut) internal {
        vm.serializeBytes("root", "governance_upgrade_calls", encodedCalls);

        string memory toml = vm.serializeBytes("root", "new_diamond_cut", newDiamondCut);

        vm.writeToml(toml, outputPath);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
