// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";

import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";

import {Call} from "contracts/governance/Common.sol";

import {DeployCTMScript} from "../DeployCTM.s.sol";

contract EcosystemUpgrade_v27_1 is Script, DeployCTMScript {
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

        // We only change blobVersionedHashRetriever
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
        config.ownerAddress = L1Bridgehub(addresses.bridgehub.bridgehubProxy).owner();
        address ctm = L1Bridgehub(addresses.bridgehub.bridgehubProxy).chainTypeManager(config.eraChainId);
        addresses.stateTransition.chainTypeManagerProxy = ctm;
        // We have to set the diamondProxy address here - as it is used by multiple constructors (for example L1Nullifier etc)
        addresses.stateTransition.diamondProxy = L1Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(
            config.eraChainId
        );
        addresses.bridges.l1AssetRouterProxy = L1Bridgehub(addresses.bridgehub.bridgehubProxy).assetRouter();

        addresses.vaults.l1NativeTokenVaultProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).nativeTokenVault()
        );
        addresses.bridges.l1NullifierProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).L1_NULLIFIER()
        );

        addresses.bridgehub.ctmDeploymentTrackerProxy = address(
            L1Bridgehub(addresses.bridgehub.bridgehubProxy).l1CtmDeployer()
        );

        addresses.bridgehub.messageRootProxy = address(L1Bridgehub(addresses.bridgehub.bridgehubProxy).messageRoot());

        addresses.bridges.erc20BridgeProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).legacyBridge()
        );

        address eraDiamondProxy = L1Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(config.eraChainId);
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
