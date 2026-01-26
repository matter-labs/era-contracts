// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {IChainRegistrationSender} from "contracts/core/chain-registration/IChainRegistrationSender.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IValidatorTimelock} from "contracts/state-transition/IValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ADDRESS_ONE, Utils} from "../utils/Utils.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {PermanentValuesHelper} from "../utils/PermanentValuesHelper.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {AddressIntrospector} from "../utils/AddressIntrospector.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";

import {L2LegacySharedBridgeTestHelper} from "../dev/L2LegacySharedBridgeTestHelper.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Call} from "contracts/governance/Common.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {Create2AndTransfer} from "../utils/deploy/Create2AndTransfer.sol";
import {
    ZkChainAddresses,
    StateTransitionDeployedAddresses,
    CTMDeployedAddresses,
    CoreDeployedAddresses
} from "../utils/Types.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";
import {IRegisterZKChain, RegisterZKChainConfig} from "contracts/script-interfaces/IRegisterZKChain.sol";
import {GetDiamondCutData} from "../utils/GetDiamondCutData.sol";

contract RegisterZKChainScript is Script, IRegisterZKChain {
    using stdToml for string;

    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewZKChain(uint256,address)");

    struct LegacySharedBridgeParams {
        bytes implementationConstructorParams;
        address implementationAddress;
        bytes proxyConstructorParams;
        address proxyAddress;
    }

    LegacySharedBridgeParams internal legacySharedBridgeParams;

    CTMDeployedAddresses internal ctmAddresses;
    CoreDeployedAddresses internal coreAddresses;

    RegisterZKChainConfig internal config;
    ZkChainAddresses internal output;

    function run(address _chainTypeManagerProxy, uint256 _chainChainId) public {
        console.log("Deploying ZKChain");
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/register-zk-chain.toml");
        initializeConfig(path, _chainTypeManagerProxy, _chainChainId);
        loadChainCreationData(_chainTypeManagerProxy);
        // TODO: some chains may not want to have a legacy shared bridge
        runInner("/script-out/output-register-zk-chain.toml");
    }

    function loadChainCreationData(address _ctmAddress) internal {
        (config.diamondCutData, config.forceDeploymentsData) = GetDiamondCutData.getDiamondCutAndForceDeployment(
            _ctmAddress
        );
    }

    function runForTest(address _chainTypeManagerProxy, uint256 _chainChainId) public {
        console.log("Deploying ZKChain");

        // Timestamp needs to be late enough for `pauseDepositsBeforeInitiatingMigration` time checks
        vm.warp(PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET + 1);

        initializeConfigTest(_chainTypeManagerProxy, _chainChainId);
        runInner(vm.envString("ZK_CHAIN_OUT"));
    }

    function runInner(string memory outputPath) internal {
        string memory root = vm.projectRoot();

        outputPath = string.concat(root, outputPath);

        if (config.initializeLegacyBridge) {
            // This must be run before the chain is deployed
            setUpLegacySharedBridgeParams();
        }

        deployGovernance();
        deployChainAdmin();
        deployChainProxyAddress();
        checkTokenAddress();
        registerAssetIdOnBridgehub();
        registerTokenOnNTV();
        registerZKChain();
        addValidators();
        configureZkSyncStateTransition();
        setPendingAdmin();

        if (config.initializeLegacyBridge) {
            deployLegacySharedBridge();
        }

        saveOutput(outputPath);
    }

    function initializeConfig(string memory path, address chainTypeManagerProxy, uint256 chainChainId) internal {
        // Grab config from output of l1 deployment
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        initializeConfigFromOnChain(chainTypeManagerProxy);

        config.ownerAddress = toml.readAddress("$.owner_address");

        config.chainChainId = chainChainId;
        config.baseTokenGasPriceMultiplierNominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_nominator")
        );
        config.baseTokenGasPriceMultiplierDenominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_denominator")
        );
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.governanceSecurityCouncilAddress = toml.readAddress("$.chain.governance_security_council_address");
        config.governanceMinDelay = uint256(toml.readUint("$.chain.governance_min_delay"));
        config.bridgehubCreateNewChainSalt = toml.readUint("$.chain.bridgehub_create_new_chain_salt");
        config.validiumMode = toml.readBool("$.chain.validium_mode");
        config.validatorSenderOperatorEth = toml.readAddress("$.chain.validator_sender_operator_eth");
        config.validatorSenderOperatorBlobsEth = toml.readAddress("$.chain.validator_sender_operator_blobs_eth");

        // These were added to zkstack tool recently (9th Sept 2025).
        // So doing this for backwards compatibility.
        if (vm.keyExistsToml(toml, "$.chain.validator_sender_operator_prove")) {
            config.validatorSenderOperatorProve = toml.readAddress("$.chain.validator_sender_operator_prove");
        } else {
            config.validatorSenderOperatorProve = address(0);
        }
        if (vm.keyExistsToml(toml, "$.chain.validator_sender_operator_execute")) {
            config.validatorSenderOperatorExecute = toml.readAddress("$.chain.validator_sender_operator_execute");
        } else {
            config.validatorSenderOperatorExecute = address(0);
        }

        if (vm.keyExistsToml(toml, "$.chain.initialize_legacy_bridge")) {
            config.initializeLegacyBridge = toml.readBool("$.chain.initialize_legacy_bridge");
        }

        if (vm.keyExistsToml(toml, "$.chain.l1_erc20_bridge")) {
            config.l1Erc20Bridge = toml.readAddress("$.chain.l1_erc20_bridge");
        }
        if (vm.keyExistsToml(toml, "$.chain.l1_shared_bridge_proxy")) {
            config.l1SharedBridgeProxy = toml.readAddress("$.chain.l1_shared_bridge_proxy");
        }

        // Read create2 factory values from permanent values file
        (address create2FactoryAddr, bytes32 create2FactorySalt) = PermanentValuesHelper.getPermanentValues(vm);
        config.create2FactoryAddress = create2FactoryAddr;
        config.create2Salt = create2FactorySalt;

        if (vm.keyExistsToml(toml, "$.chain.allow_evm_emulator")) {
            config.allowEvmEmulator = toml.readBool("$.chain.allow_evm_emulator");
        }
    }

    function initializeConfigFromOnChain(address _ctmAddress) internal {
        ChainTypeManagerBase ctm = ChainTypeManagerBase(_ctmAddress);
        ctmAddresses = AddressIntrospector.getCTMAddresses(ctm);
        IL1Bridgehub bridgehub = IL1Bridgehub(ctm.BRIDGE_HUB());
        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(address(bridgehub));
    }

    function getConfig() public view returns (RegisterZKChainConfig memory) {
        return config;
    }

    function initializeConfigTest(address chainTypeManagerProxy, uint256 chainChainId) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("CTM_OUTPUT"));
        string memory toml = vm.readFile(path);
        config.forceDeploymentsData = toml.readBytes("$.contracts_config.force_deployments_data");
        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");
        config.create2FactoryAddress = toml.readAddress("$.contracts.create2_factory_addr");
        config.create2Salt = toml.readBytes32("$.contracts.create2_factory_salt");
        path = string.concat(root, vm.envString("ZK_CHAIN_CONFIG"));
        initializeConfig(path, chainTypeManagerProxy, chainChainId);
    }

    function getOwnerAddress() public view returns (address) {
        return config.ownerAddress;
    }

    function checkTokenAddress() internal view {
        if (config.baseToken == address(0)) {
            revert("Token address is not set");
        }

        // Check if it's ethereum address
        if (config.baseToken == ADDRESS_ONE) {
            return;
        }

        if (config.baseToken.code.length == 0) {
            revert("Token address is not a contract address");
        }

        console.log("Using base token address:", config.baseToken);
    }

    function setUpLegacySharedBridgeParams() internal {
        // Ecosystem governance is the owner of the L1Nullifier
        address ecosystemGovernance = L1NullifierDev(coreAddresses.bridges.proxies.l1Nullifier).owner();
        address bridgeAddress = L2LegacySharedBridgeTestHelper.calculateL2LegacySharedBridgeProxyAddr(
            // TODO: this is not correct, we need to get the l1Erc20Bridge from the asset router
            config.l1Erc20Bridge,
            coreAddresses.bridges.proxies.l1Nullifier,
            ecosystemGovernance
        );

        vm.broadcast();
        L1NullifierDev(coreAddresses.bridges.proxies.l1Nullifier).setL2LegacySharedBridge(
            config.chainChainId,
            bridgeAddress
        );
    }

    function registerAssetIdOnBridgehub() internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub);
        ChainAdminOwnable admin = ChainAdminOwnable(payable(coreAddresses.shared.bridgehubAdmin));
        INativeTokenVaultBase ntv = INativeTokenVaultBase(coreAddresses.bridges.proxies.l1NativeTokenVault);
        bytes32 baseTokenAssetId = ntv.assetId(config.baseToken);
        uint256 baseTokenOriginChain = ntv.originChainId(baseTokenAssetId);

        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);
        }

        if (bridgehub.assetIdIsRegistered(baseTokenAssetId)) {
            console.log("Base token asset id already registered on Bridgehub");
        } else {
            IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
            calls[0] = IChainAdminOwnable.Call({
                target: coreAddresses.bridgehub.proxies.bridgehub,
                value: 0,
                data: abi.encodeCall(bridgehub.addTokenAssetId, (baseTokenAssetId))
            });
            vm.broadcast(admin.owner());
            admin.multicall(calls, true);

            console.log("Base token asset id registered on Bridgehub");
        }
    }

    function registerTokenOnNTV() internal {
        INativeTokenVaultBase ntv = INativeTokenVaultBase(coreAddresses.bridges.proxies.l1NativeTokenVault);
        bytes32 baseTokenAssetId = ntv.assetId(config.baseToken);
        uint256 baseTokenOriginChain = ntv.originChainId(baseTokenAssetId);

        // If it hasn't been registered already with ntv
        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);
        }
        config.baseTokenAssetId = baseTokenAssetId;
        if (ntv.tokenAddress(baseTokenAssetId) != address(0) || config.baseToken == ETH_TOKEN_ADDRESS) {
            console.log("Token already registered on NTV");
        } else {
            vm.broadcast();
            ntv.registerToken(config.baseToken);
            console.log("Token registered on NTV");
        }
    }

    function deployGovernance() internal {
        bytes memory input = abi.encode(
            config.ownerAddress,
            config.governanceSecurityCouncilAddress,
            config.governanceMinDelay
        );
        address governance = Utils.deployViaCreate2(
            abi.encodePacked(type(Governance).creationCode, input),
            config.create2Salt,
            config.create2FactoryAddress
        );
        console.log("Governance deployed at:", governance);
        output.governance = governance;
    }

    function deployChainAdmin() internal {
        // TODO(EVM-924): provide an option to deploy a non-single owner ChainAdmin.
        (address chainAdmin, address accessControlRestriction) = deployChainAdminOwnable();

        output.accessControlRestrictionAddress = accessControlRestriction;
        output.chainAdmin = chainAdmin;
    }

    function deployChainAdminOwnable() internal returns (address chainAdmin, address accessControlRestriction) {
        chainAdmin = Utils.deployViaCreate2(
            abi.encodePacked(type(ChainAdminOwnable).creationCode, abi.encode(config.ownerAddress, address(0))),
            config.create2Salt,
            config.create2FactoryAddress
        );
        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        accessControlRestriction = address(0);

        console.log("ChainAdminOwnable deployed at:", accessControlRestriction);
    }

    // TODO(EVM-924): this function is unused
    function deployChainAdminWithRestrictions()
        internal
        returns (address chainAdmin, address accessControlRestriction)
    {
        bytes memory input = abi.encode(0, config.ownerAddress);
        accessControlRestriction = Utils.deployViaCreate2(
            abi.encodePacked(type(AccessControlRestriction).creationCode, input),
            config.create2Salt,
            config.create2FactoryAddress
        );

        address[] memory restrictions = new address[](1);
        restrictions[0] = accessControlRestriction;

        input = abi.encode(restrictions);
        chainAdmin = Utils.deployViaCreate2(
            abi.encodePacked(type(ChainAdmin).creationCode, input),
            config.create2Salt,
            config.create2FactoryAddress
        );
    }

    function registerZKChain() internal {
        IL1Bridgehub bridgehub = IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub);
        ChainAdminOwnable admin = ChainAdminOwnable(payable(coreAddresses.shared.bridgehubAdmin));

        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({
            target: coreAddresses.bridgehub.proxies.bridgehub,
            value: 0,
            data: abi.encodeCall(
                bridgehub.createNewChain,
                (
                    config.chainChainId,
                    ctmAddresses.stateTransition.proxies.chainTypeManager,
                    config.baseTokenAssetId,
                    config.bridgehubCreateNewChainSalt,
                    msg.sender,
                    abi.encode(config.diamondCutData, config.forceDeploymentsData),
                    getFactoryDeps()
                )
            )
        });
        vm.broadcast(admin.owner());
        admin.multicall(calls, true);
        console.log("ZK chain registered");

        // Get new diamond proxy address from emitted events
        address diamondProxyAddress = bridgehub.getZKChain(config.chainChainId);
        if (diamondProxyAddress == address(0)) {
            revert("Diamond proxy address not found");
        }
        output.diamondProxy = diamondProxyAddress;
        console.log("ZKChain diamond proxy deployed at:", diamondProxyAddress);
    }

    function addValidators() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(ctmAddresses.stateTransition.proxies.validatorTimelock);
        address chainAddress = IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).getZKChain(config.chainChainId);

        vm.startBroadcast(msg.sender);

        // Add committer role to the first two addresses (commit operators)

        // We give all roles to the committer, the reason is because the separate prover/executer roles
        // are only provided in ZKsync OS, while on Era all of them are filled by committer.
        validatorTimelock.addValidatorRoles(
            chainAddress,
            config.validatorSenderOperatorEth,
            IValidatorTimelock.ValidatorRotationParams({
                rotatePrecommitterRole: true,
                rotateCommitterRole: false,
                rotateReverterRole: true,
                rotateProverRole: true,
                rotateExecutorRole: true
            })
        );

        validatorTimelock.addValidatorRoles(
            chainAddress,
            config.validatorSenderOperatorBlobsEth,
            IValidatorTimelock.ValidatorRotationParams({
                rotatePrecommitterRole: false,
                rotateCommitterRole: true,
                rotateReverterRole: false,
                rotateProverRole: false,
                rotateExecutorRole: false
            })
        );

        // Add prover role to the third address, only if set
        if (config.validatorSenderOperatorProve != address(0)) {
            validatorTimelock.addValidatorRoles(
                chainAddress,
                config.validatorSenderOperatorProve,
                IValidatorTimelock.ValidatorRotationParams({
                    rotatePrecommitterRole: false,
                    rotateCommitterRole: false,
                    rotateReverterRole: false,
                    rotateProverRole: true,
                    rotateExecutorRole: false
                })
            );
        }

        // Add executor role to the fourth address, only if set
        if (config.validatorSenderOperatorExecute != address(0)) {
            validatorTimelock.addValidatorRoles(
                chainAddress,
                config.validatorSenderOperatorExecute,
                IValidatorTimelock.ValidatorRotationParams({
                    rotatePrecommitterRole: false,
                    rotateCommitterRole: false,
                    rotateReverterRole: false,
                    rotateProverRole: false,
                    rotateExecutorRole: true
                })
            );
        }

        vm.stopBroadcast();

        console.log("Validators added with specific roles");
    }

    function configureZkSyncStateTransition() internal {
        IZKChain zkChain = IZKChain(output.diamondProxy);

        vm.startBroadcast(msg.sender);
        zkChain.setTokenMultiplier(
            config.baseTokenGasPriceMultiplierNominator,
            config.baseTokenGasPriceMultiplierDenominator
        );

        if (config.validiumMode) {
            zkChain.setPubdataPricingMode(PubdataPricingMode.Validium);
        }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }

    function setPendingAdmin() internal {
        IZKChain zkChain = IZKChain(output.diamondProxy);

        vm.startBroadcast(msg.sender);
        zkChain.setPendingAdmin(output.chainAdmin);
        vm.stopBroadcast();
        console.log("Owner for ", output.diamondProxy, "set to", output.chainAdmin);
    }

    function deployChainProxyAddress() internal {
        bytes memory input = abi.encode(type(ProxyAdmin).creationCode, config.create2Salt, output.chainAdmin);
        bytes memory encoded = abi.encodePacked(type(Create2AndTransfer).creationCode, input);
        address create2AndTransfer = Utils.deployViaCreate2(encoded, config.create2Salt, config.create2FactoryAddress);

        address proxyAdmin = vm.computeCreate2Address(config.create2Salt, keccak256(encoded), create2AndTransfer);

        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        output.chainProxyAdmin = address(proxyAdmin);
    }

    function deployLegacySharedBridge() internal {
        bytes[] memory emptyDeps = new bytes[](0);
        address legacyBridgeImplAddr = Utils.deployThroughL1Deterministic({
            bytecode: ContractsBytecodesLib.getCreationCode("L2SharedBridgeLegacyDev"),
            constructorargs: hex"",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: emptyDeps,
            chainId: config.chainChainId,
            bridgehubAddress: coreAddresses.bridgehub.proxies.bridgehub,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });

        output.l2LegacySharedBridge = Utils.deployThroughL1Deterministic({
            bytecode: ContractsBytecodesLib.getCreationCode("TransparentUpgradeableProxy"),
            constructorargs: L2LegacySharedBridgeTestHelper.getLegacySharedBridgeProxyConstructorParams(
                legacyBridgeImplAddr,
                config.l1Erc20Bridge,
                coreAddresses.bridges.proxies.l1Nullifier,
                // Ecosystem governance is the owner of the L1Nullifier
                L1NullifierDev(coreAddresses.bridges.proxies.l1Nullifier).owner()
            ),
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: emptyDeps,
            chainId: config.chainChainId,
            bridgehubAddress: coreAddresses.bridgehub.proxies.bridgehub,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function getFactoryDeps() internal view returns (bytes[] memory) {
        bytes[] memory factoryDeps = new bytes[](0);
        return factoryDeps;
    }

    function saveOutput(string memory outputPath) internal {
        vm.serializeAddress("root", "diamond_proxy_addr", output.diamondProxy);
        vm.serializeAddress("root", "chain_admin_addr", output.chainAdmin);
        if (output.l2LegacySharedBridge != address(0)) {
            vm.serializeAddress("root", "l2_legacy_shared_bridge_addr", output.l2LegacySharedBridge);
        }
        vm.serializeAddress("root", "access_control_restriction_addr", output.accessControlRestrictionAddress);
        vm.serializeAddress("root", "chain_proxy_admin_addr", output.chainProxyAdmin);

        string memory chain = vm.serializeUint("", "chain_id", config.chainChainId);
        vm.serializeString("root", "chain", chain);

        string memory toml = vm.serializeAddress("root", "governance_addr", output.governance);
        string memory root = vm.projectRoot();
        vm.writeToml(toml, outputPath);
        console.log("Output saved at:", outputPath);
    }

    function governanceExecuteCalls(bytes memory callsToExecute, address governanceAddr) internal {
        IGovernance governance = IGovernance(governanceAddr);
        Ownable2Step ownable = Ownable2Step(governanceAddr);

        Call[] memory calls = abi.decode(callsToExecute, (Call[]));

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        vm.startBroadcast(ownable.owner());
        governance.scheduleTransparent(operation, 0);
        // We assume that the total value is 0
        governance.execute{value: 0}(operation);
        vm.stopBroadcast();
    }
}
