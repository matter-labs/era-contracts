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

/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayVotePreparation is GatewayChainShared {
    using stdToml for string;

    uint256 constant EXPECTED_MAX_L1_GAS_PRICE = 50 gwei;

    address internal oldRollupL2DAValidator;
    address internal serverNotifier;
    address internal create2Factory;
    bytes32 internal create2FactorySalt;
    address internal refundRecipient;

    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function readAdditionalConfig(string memory votePreparationConfig) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, votePreparationConfig);
        string memory toml = vm.readFile(path);
    
        oldRollupL2DAValidator = toml.readAddress("$.old_rollup_l2_da_validator");
        create2FactorySalt = toml.readBytes32(".create2_factory_salt");
        refundRecipient = toml.readAddress("$.refund_recipient");
    }

    function deployServerNotifier() internal {
        // Unlike the already existing ProxyAdmin (that is controlled by the decentralized governance), 
        // its admin should the ecosystem admin.
        address ecosystemProxyAdmin = deployWithOwnerAndNotify(
            type(ProxyAdmin).creationCode,
            hex"",
            config.ecosystemAdmin,
            "ProxyAdmin",
            "Ecosystem Admin's ProxyAdmin"
        );

        address implementation = deployViaCreate2AndNotify(Utils.readFoundryBytecodeL1("ServerNotifier.sol", "ServerNotifier"), abi.encode(true), "ServerNotifier");
        address proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode, 
            abi.encode(implementation, ecosystemProxyAdmin, abi.encodeCall(ServerNotifier.initialize, (ecosystemProxyAdmin))),
            "TransparentUpgradeableProxy"
        );

        serverNotifier = proxy;
    }

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

    function run() public {
        console.log("Setting up the Gateway script");

        string memory votePreparationConfig = vm.envString("GATEWAY_VOTE_PREPARATION_CONFIG");
        vm.setEnv("DEPLOY_GATEWAY_CTM_CONFIG", votePreparationConfig);
        vm.setEnv("GATEWAY_CHAIN_SHARED_CONFIG", votePreparationConfig);

        readAdditionalConfig(votePreparationConfig);
        initializeConfig();

        // Firstly, we deploy Gateway CTM
        GatewayCTMFromL1 ctmDeployerScript = new GatewayCTMFromL1();
        ctmDeployerScript.deployCTM();
        GatewayCTMFromL1.Output output = ctmDeployerScript.getOutput();

        Call[] memory calls = _prepareGatewayGovernanceCalls(EXPECTED_MAX_L1_GAS_PRICE, output.gatewayStateTransition.chainTypeManagerProxy);

        // We need to also whitelist the old L2 rollup address
        calls = Utils.mergeCalls(calls, Utils.prepareGovernanceL1L2DirectTransaction(
            EXPECTED_MAX_L1_GAS_PRICE, 
            abi.encodeCall(RollupDAManager.updateDAPair, (output.relayedSLDAValidator, oldRollupL2DAValidator)), 
            Utils.MAX_PRIORITY_TX_GAS, 
            new bytes[](0), 
            output.rollupDAManager, 
            config.gatewayChainId, 
            config.bridgehub, 
            config.l1AssetRouterProxy
        ));

        saveOutput(calls);
    }

    function deployServerNotifier() external {
        string memory votePreparationConfig = vm.envString("GATEWAY_VOTE_PREPARATION_CONFIG");
        vm.setEnv("GATEWAY_CHAIN_SHARED_CONFIG", votePreparationConfig);

        initializeConfig();

        deployServerNotifier();
    
        bytes memory dataForAdmin = Utils.encodeChainAdminMulticall(
            Call({
                target: config.chainTypeManagerProxy,
                value: 0,
                data: abi.encodeCall(ChainTypeManager.setServerNotifier, (serverNotifierAddress));
            })
        );

        console.log("Data to invoke ChainAdmin with");
        console.logBytes(dataForAdmin);
    }

    function saveOutput(Call[] memory governanceCallsToExecute) internal {        
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
