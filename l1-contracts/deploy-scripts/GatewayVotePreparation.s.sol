// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS} from "./Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L2AssetRouter, IL2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {GatewayChainShared} from "./GatewayChainShared.s.sol";

import {GatewayCTMFromL1} from "./GatewayCTMFromL1.s.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";

import {DeployL1Script} from "./DeployL1Script.s.sol";

import {GatewayCTMDeployerHelper} from "./GatewayCTMDeployerHelper.sol";
import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";


/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayVotePreparation is DeployL1Script {
    using stdToml for string;

    uint256 constant EXPECTED_MAX_L1_GAS_PRICE = 50 gwei;

    address internal rollupL2DAValidator;
    address internal oldRollupL2DAValidator;
    uint256 internal gatewayChainId;
    address internal gatewayChainAdmin;
    address internal ecosystemAdminAddress;
    address internal gatewayProxyAdmin;
    bytes internal forceDeploymentsData;

    address internal serverNotifier;
    address internal refundRecipient;

    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address internal gatewayTransactionFilterer;
    GatewayCTMDeployerConfig internal gatewayCTMDeployerConfig;

    function instantiateCreate2Factory() internal {
        address contractAddress;

        bool isDeterministicDeployed = DETERMINISTIC_CREATE2_ADDRESS.code.length > 0;

        if (isDeterministicDeployed) {
            contractAddress = DETERMINISTIC_CREATE2_ADDRESS;
            console.log("Using deterministic Create2Factory address:", contractAddress);
        } else {
            contractAddress = Utils.deployCreate2Factory();
            console.log("Create2Factory deployed at:", contractAddress);
        }

        create2Factory = contractAddress;
    }

    function initializeConfig(string memory configPath) public virtual override {
        super.initializeConfig(configPath);
        string memory toml = vm.readFile(configPath);

        addresses.bridgehub.bridgehubProxy = toml.readAddress("$.contracts.bridgehub_proxy_address");
        refundRecipient = toml.readAddress("$.refund_recipient");

        // The "new" and "old" rollup L2 DA validators are those that were set in v27 and v26 respectively 
        rollupL2DAValidator = toml.readAddress("$.rollup_l2_da_validator");
        oldRollupL2DAValidator = toml.readAddress("$.old_rollup_l2_da_validator");

        gatewayChainId = toml.readUint("$.gateway_chain_id");
        gatewayProxyAdmin = toml.readUint("$.gateway_proxy_admin");
        forceDeploymentsData = toml.readBytes(".force_deployments_data");

        setAddressesBasedOnBridgehub();

        address aliasedGovernor = AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress);
        gatewayCTMDeployerConfig = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: aliasedGovernor,
            salt: bytes32(0),
            eraChainId: config.eraChainId,
            l1ChainId: config.l1ChainId,
            rollupL2DAValidatorAddress: rollupL2DAValidator,
            testnetVerifier: config.testnetVerifier,
            adminSelectors: Utils.getAllSelectorsForFacet("Admin"),
            executorSelectors: Utils.getAllSelectorsForFacet("Executor"),
            mailboxSelectors: Utils.getAllSelectorsForFacet("Mailbox"),
            gettersSelectors: Utils.getAllSelectorsForFacet("Getters"),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
                recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
                recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
            }),
            feeParams: FeeParams({
                pubdataPricingMode: config.contracts.diamondInitPubdataPricingMode,
                batchOverheadL1Gas: uint32(config.contracts.diamondInitBatchOverheadL1Gas),
                maxPubdataPerBatch: uint32(config.contracts.diamondInitMaxPubdataPerBatch),
                maxL2GasPerBatch: uint32(config.contracts.diamondInitMaxL2GasPerBatch),
                priorityTxMaxPubdata: uint32(config.contracts.diamondInitPriorityTxMaxPubdata),
                minimalL2GasPrice: uint64(config.contracts.diamondInitMinimalL2GasPrice)
            }),
            bootloaderHash: config.contracts.bootloaderHash,
            defaultAccountHash: config.contracts.defaultAAHash,
            evmEmulatorHash: config.contracts.evmEmulatorHash,
            priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
            genesisRoot: config.contracts.genesisRoot,
            genesisRollupLeafIndex: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            forceDeploymentsData: forceDeploymentsData,
            protocolVersion: config.contracts.latestProtocolVersion
        });

    }

    function setAddressesBasedOnBridgehub() internal {
        config.ownerAddress = Bridgehub(addresses.bridgehub.bridgehubProxy).owner();
        address ctm = IBridgehub(addresses.bridgehub.bridgehubProxy).chainTypeManager(config.eraChainId);
        addresses.stateTransition.chainTypeManagerProxy = ctm;
        // We have to set the diamondProxy address here - as it is used by multiple constructors (for example L1Nullifier etc)
        addresses.stateTransition.diamondProxy = IBridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(
            config.eraChainId
        );
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        require(
            ctmProtocolVersion == config.contracts.latestProtocolVersion,
            "The latest protocol version is not correct"
        );
        serverNotifier = ChainTypeManager(ctm).serverNotifier();
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
        ecosystemAdminAddress = Bridgehub(addresses.bridgehub.bridgehubProxy).admin();

        address eraDiamondProxy = Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(config.eraChainId);
        (addresses.daAddresses.l1RollupDAValidator, ) = GettersFacet(eraDiamondProxy).getDAValidatorPair();

        address gatewayChainAddress = bridgehub.getZKChain(gatewayChainId);
        gatewayChainAdmin = IGetters(gatewayChainAddress).getAdmin();
    }

    function deployCTM() internal {
        (DeployedContracts memory expectedGatewayContracts, bytes memory create2Calldata, ) = GatewayCTMDeployerHelper
            .calculateAddresses(bytes32(0), gatewayCTMDeployerConfig);

        bytes[] memory deps = GatewayCTMDeployerHelper.getListOfFactoryDeps();

        for (uint i = 0; i < deps.length; i++) {
            bytes[] memory localDeps = new bytes[](1);
            localDeps[0] = deps[i];
            Utils.runL1L2Transaction({
                l2Calldata: hex"",
                l2GasLimit: 72_000_000,
                l2Value: 0,
                factoryDeps: localDeps,
                dstAddress: address(0),
                chainId: gatewayChainId,
                bridgehubAddress: addresses.bridgehub.bridgehubProxy,
                l1SharedBridgeProxy: addresses.bridges.l1AssetRouterProxy,
                refundRecipient: msg.sender
            });
        }

        Utils.runL1L2Transaction({
            l2Calldata: create2Calldata,
            l2GasLimit: 72_000_000,
            l2Value: 0,
            factoryDeps: new bytes[](0),
            dstAddress: L2_CREATE2_FACTORY_ADDRESS,
            chainId: gatewayChainId,
            bridgehubAddress: addresses.bridgehub.bridgehubProxy,
            l1SharedBridgeProxy: addresses.bridges.l1AssetRouterProxy,
            refundRecipient: msg.sender
        });

        _saveExpectedGatewayContractsToOutput(expectedGatewayContracts, address(0));
        saveOutput();
    }

    function run() public {
        console.log("Setting up the Gateway script");

        string memory root = vm.projectRoot();
        configPath = string.concat(root, vm.envString("GATEWAY_VOTE_PREPARATION_CONFIG"));

        initializeConfig(configPath);
        instantiateCreate2Factory();

        Call[] memory ecosystemAdminCalls;
        if (serverNotifier == address(0)) {
            (, serverNotifier) = deployServerNotifier();

            ecosystemAdminCalls = new Call[](2);
            calls[0] = Call({
                target: addresses.stateTransition.chainTypeManagerProxy,
                value: 0,
                data: abi.encodeCall(ChainTypeManager.setServerNotifier, (serverNotifier))
            });
            calls[1] = Call({
                target: serverNotifier,
                value: 0,
                data: abi.encodeCall(ServerNotifier.setChainTypeManager, (addresses.stateTransition.chainTypeManagerProxy))
            });
        }

        gatewayTransactionFilterer = _deployGatewayTransactionFilterer();

        // Firstly, we deploy Gateway CTM
        GatewayCTMFromL1 ctmDeployerScript = new GatewayCTMFromL1();
        ctmDeployerScript.deployCTM();
        GatewayCTMFromL1.Output output = ctmDeployerScript.getOutput();

        Call[] memory calls = _prepareGatewayGovernanceCalls(EXPECTED_MAX_L1_GAS_PRICE, output.gatewayStateTransition.chainTypeManagerProxy, refundRecipient);

        // We need to also whitelist the old L2 rollup address
        calls = Utils.mergeCalls(calls, Utils.prepareGovernanceL1L2DirectTransaction(
            EXPECTED_MAX_L1_GAS_PRICE, 
            abi.encodeCall(RollupDAManager.updateDAPair, (output.relayedSLDAValidator, oldRollupL2DAValidator)), 
            Utils.MAX_PRIORITY_TX_GAS, 
            new bytes[](0), 
            output.rollupDAManager, 
            gatewayChainId, 
            config.bridgehub, 
            addresses.bridges.l1AssetRouterProxy,
            refundRecipient
        ));

        saveOutput(calls);
    }

    function getCreationCode(string memory contractName) internal view virtual override returns (bytes memory) {
        if(compareStrings(contractName, "GatewayTransactionFilterer")) {
            return type(GatewayTransactionFilterer).creationCode;
        } else {
            return super.getCreationCode(contractName);
        }
    }

    function getCreationCalldata(string memory contractName) internal view virtual returns (bytes memory) {
        if(compareStrings(contractName, "GatewayTransactionFilterer")) {
            return abi.encode(addresses.bridgehub.bridgehubProxy, addresses.bridges.l1AssetRouterProxy);
        } else {
            return super.getCreationCalldata(contractName);
        }
    }

    function getInitializeCalldata(string memory contractName) internal view virtual returns (bytes memory) {
        if(compareStrings(contractName, "GatewayTransactionFilterer")) {
            return abi.encode(gatewayChainAdmin);
        } else {
            return super.getInitializeCalldata(contractName);
        }
    }

    /// The caller of this function should have private key of the admin of the *gateway*
    function _deployGatewayTransactionFilterer() internal returns (address proxy) {
        (, proxy) = deployTuppWithContractAndProxyAdmin(
            "GatewayTransactionFilterer",
            gatewayProxyAdmin
        );
    }

    function saveOutput(
        Call[] memory governanceCallsToExecute,
        Call[] memory ecosystemAdminCallsToExecute
    ) internal {        
        vm.serializeAddress("root", "gateway_admin_calls_to_execute", abi.encode(gatewayAdminCallsToExecute));
        vm.serializeAddress("root" , "ecosystem_admin_calls_to_execute", abi.encode(ecosystemAdminCallsToExecute));
        string memory toml = vm.serializeBytes("root", "encoded_calls", abi.encode(governanceCallsToExecute));
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-gateway-vote-preparation.toml");
        vm.writeToml(toml, path);
    }

    // Copied from `DeployUtils.s.sol` since it is a bit hard to 
    // inherit the contract directly due to config differences. 

    function deployViaCreate2AndNotify(
        bytes memory _creationCode,
        bytes memory _constructorParamsEncoded,
        string memory contractName
    ) internal returns (address deployedAddress) {
        deployedAddress = deployViaCreate2AndNotify(
            _creationCode,
            _constructorParamsEncoded,
            contractName,
            contractName
        );
    }

    function deployViaCreate2AndNotify(
        bytes memory _creationCode,
        bytes memory _constructorParamsEncoded,
        string memory contractName,
        string memory displayName
    ) internal returns (address deployedAddress) {
        bytes memory bytecode = abi.encodePacked(_creationCode, _constructorParamsEncoded);

        deployedAddress = deployViaCreate2(bytecode);
        notifyAboutDeployment(deployedAddress, contractName, _constructorParamsEncoded, displayName);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal virtual returns (address) {
        return
            Utils.deployViaCreate2(
                abi.encodePacked(creationCode, constructorArgs),
                create2FactorySalt,
                create2Factory
            );
    }

    function getDeployedContractName(string memory contractName) internal view virtual returns (string memory) {
        if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return "UpgradeableBeacon";
        } else {
            return contractName;
        }
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams
    ) internal {
        notifyAboutDeployment(contractAddr, contractName, constructorParams, contractName);
    }

    function notifyAboutDeployment(
        address contractAddr,
        string memory contractName,
        bytes memory constructorParams,
        string memory displayName
    ) internal {
        string memory basicMessage = string.concat(displayName, " has been deployed at ", vm.toString(contractAddr));
        console.log(basicMessage);

        string memory forgeMessage;
        string memory deployedContractName = getDeployedContractName(contractName);
        if (constructorParams.length == 0) {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                deployedContractName
            );
        } else {
            forgeMessage = string.concat(
                "forge verify-contract ",
                vm.toString(contractAddr),
                " ",
                deployedContractName,
                " --constructor-args ",
                vm.toString(constructorParams)
            );
        }

        console.log(forgeMessage);
    }

    function deployWithOwnerAndNotify(
        bytes memory initCode,
        bytes memory constructorParams,
        address owner,
        string memory contractName,
        string memory displayName
    ) internal returns (address contractAddress) {
        contractAddress = create2WithDeterministicOwner(abi.encodePacked(initCode, constructorParams), owner);
        notifyAboutDeployment(contractAddress, contractName, constructorParams, displayName);
    }

    function create2WithDeterministicOwner(bytes memory initCode, address owner) internal returns (address) {
        bytes memory creatorInitCode = abi.encodePacked(
            type(Create2AndTransfer).creationCode,
            abi.encode(initCode, create2FactorySalt, owner)
        );

        address deployerAddr = deployViaCreate2(creatorInitCode);

        return Create2AndTransfer(deployerAddr).deployedAddress();
    }


}   
