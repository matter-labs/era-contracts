// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {StateTransitionDeployedAddresses, Utils} from "./Utils.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ContractsBytecodesLib} from "./ContractsBytecodesLib.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IRollupDAManager} from "./interfaces/IRollupDAManager.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
import {L1VerifierFflonk} from "contracts/state-transition/verifiers/L1VerifierFflonk.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {DeployUtils} from "./DeployUtils.sol";

// solhint-disable-next-line gas-struct-packing
struct DeployedAddresses {
    BridgehubDeployedAddresses bridgehub;
    StateTransitionDeployedAddresses stateTransition;
    BridgesDeployedAddresses bridges;
    DataAvailabilityDeployedAddresses daAddresses;
    address transparentProxyAdmin;
    address governance;
    address chainAdmin;
    address accessControlRestrictionAddress;
    // TODO remove it
    L1NativeTokenVaultAddresses vaults;
}

// solhint-disable-next-line gas-struct-packing
struct L1NativeTokenVaultAddresses {
    address l1NativeTokenVaultImplementation;
    address l1NativeTokenVaultProxy;
}

struct DataAvailabilityDeployedAddresses {
    address rollupDAManager;
    address l1RollupDAValidator;
    address noDAValidiumL1DAValidator;
    address availBridge;
    address availL1DAValidator;
}

// solhint-disable-next-line gas-struct-packing
struct BridgehubDeployedAddresses {
    address bridgehubProxy;
    address ctmDeploymentTrackerProxy;
}

// solhint-disable-next-line gas-struct-packing
struct BridgesDeployedAddresses {
    address erc20BridgeProxy;
    address l1AssetRouterProxy;
    address l1NullifierProxy;
    address bridgedStandardERC20Implementation;
}

// solhint-disable-next-line gas-struct-packing
struct Config {
    uint256 l1ChainId;
    address deployerAddress;
    uint256 eraChainId;
    address ownerAddress;
    bool testnetVerifier;
    bool supportL2LegacySharedBridgeTest;
    ContractsConfig contracts;
}

// solhint-disable-next-line gas-struct-packing
struct ContractsConfig {
    address multicall3Addr;
    uint256 validatorTimelockExecutionDelay;
    bytes32 genesisRoot;
    uint256 genesisRollupLeafIndex;
    bytes32 genesisBatchCommitment;
    uint256 latestProtocolVersion;
    uint256 priorityTxMaxGasLimit;
    PubdataPricingMode diamondInitPubdataPricingMode;
    uint256 diamondInitBatchOverheadL1Gas;
    uint256 diamondInitMaxPubdataPerBatch;
    uint256 diamondInitMaxL2GasPerBatch;
    uint256 diamondInitPriorityTxMaxPubdata;
    uint256 diamondInitMinimalL2GasPrice;
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    bytes diamondCutData;
    bytes32 bootloaderHash;
    bytes32 defaultAAHash;
    bytes32 evmEmulatorHash;
    uint256 maxNumberOfChains;
    // questionable
    address availL1DAValidator;
}

// solhint-disable-next-line gas-struct-packing
struct GeneratedData {
    bytes forceDeploymentsData;
}

abstract contract DeployCTMUtils is DeployUtils {
    using stdToml for string;

    Config public config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    function initializeConfig(string memory configPath) internal virtual {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.testnetVerifier = toml.readBool("$.testnet_verifier");
        config.supportL2LegacySharedBridgeTest = toml.readBool("$.support_l2_legacy_shared_bridge_test");

        config.contracts.governanceSecurityCouncilAddress = toml.readAddress(
            "$.contracts.governance_security_council_address"
        );
        config.contracts.governanceMinDelay = toml.readUint("$.contracts.governance_min_delay");
        config.contracts.maxNumberOfChains = toml.readUint("$.contracts.max_number_of_chains");

        bytes32 create2FactorySalt = toml.readBytes32("$.contracts.create2_factory_salt");
        address create2FactoryAddr;
        if (vm.keyExistsToml(toml, "$.contracts.create2_factory_addr")) {
            create2FactoryAddr = toml.readAddress("$.contracts.create2_factory_addr");
        }
        _initCreate2FactoryParams(create2FactoryAddr, create2FactorySalt);

        config.contracts.validatorTimelockExecutionDelay = toml.readUint(
            "$.contracts.validator_timelock_execution_delay"
        );
        config.contracts.genesisRoot = toml.readBytes32("$.contracts.genesis_root");
        config.contracts.genesisRollupLeafIndex = toml.readUint("$.contracts.genesis_rollup_leaf_index");
        config.contracts.genesisBatchCommitment = toml.readBytes32("$.contracts.genesis_batch_commitment");
        config.contracts.latestProtocolVersion = toml.readUint("$.contracts.latest_protocol_version");
        config.contracts.priorityTxMaxGasLimit = toml.readUint("$.contracts.priority_tx_max_gas_limit");
        config.contracts.diamondInitPubdataPricingMode = PubdataPricingMode(
            toml.readUint("$.contracts.diamond_init_pubdata_pricing_mode")
        );
        config.contracts.diamondInitBatchOverheadL1Gas = toml.readUint(
            "$.contracts.diamond_init_batch_overhead_l1_gas"
        );
        config.contracts.diamondInitMaxPubdataPerBatch = toml.readUint(
            "$.contracts.diamond_init_max_pubdata_per_batch"
        );
        config.contracts.diamondInitMaxL2GasPerBatch = toml.readUint("$.contracts.diamond_init_max_l2_gas_per_batch");
        config.contracts.diamondInitPriorityTxMaxPubdata = toml.readUint(
            "$.contracts.diamond_init_priority_tx_max_pubdata"
        );
        config.contracts.diamondInitMinimalL2GasPrice = toml.readUint("$.contracts.diamond_init_minimal_l2_gas_price");
        config.contracts.defaultAAHash = toml.readBytes32("$.contracts.default_aa_hash");
        config.contracts.bootloaderHash = toml.readBytes32("$.contracts.bootloader_hash");
        config.contracts.evmEmulatorHash = toml.readBytes32("$.contracts.evm_emulator_hash");

        if (vm.keyExistsToml(toml, "$.contracts.avail_l1_da_validator")) {
            config.contracts.availL1DAValidator = toml.readAddress("$.contracts.avail_l1_da_validator");
        }
    }


    function deployStateTransitionDiamondFacets() internal {
        addresses.stateTransition.executorFacet = deploySimpleContract("ExecutorFacet", false);
        addresses.stateTransition.adminFacet = deploySimpleContract("AdminFacet", false);
        addresses.stateTransition.mailboxFacet = deploySimpleContract("MailboxFacet", false);
        addresses.stateTransition.gettersFacet = deploySimpleContract("GettersFacet", false);
        addresses.stateTransition.diamondInit = deploySimpleContract("DiamondInit", false);
    }

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts);

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts);

    function getChainCreationDiamondCutData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (Diamond.DiamondCutData memory diamondCut) {
        Diamond.FacetCut[] memory facetCuts = getChainCreationFacetCuts(stateTransition);

        DiamondInitializeDataNewChain memory initializeData = getInitializeData(stateTransition);

        diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });
        if (!stateTransition.isOnGateway) {
            config.contracts.diamondCutData = abi.encode(diamondCut);
        }
    }

    function getChainCreationParams(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainCreationParams memory) {
        Diamond.DiamondCutData memory diamondCut = getChainCreationDiamondCutData(stateTransition);
        return
            ChainCreationParams({
                genesisUpgrade: stateTransition.genesisUpgrade,
                genesisBatchHash: config.contracts.genesisRoot,
                genesisIndexRepeatedStorageChanges: uint64(config.contracts.genesisRollupLeafIndex),
                genesisBatchCommitment: config.contracts.genesisBatchCommitment,
                diamondCut: diamondCut,
                forceDeploymentsData: generatedData.forceDeploymentsData
            });
    }

    function getChainTypeManagerInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (ChainTypeManagerInitializeData memory) {
        ChainCreationParams memory chainCreationParams = getChainCreationParams(stateTransition);
        return
            ChainTypeManagerInitializeData({
                owner: msg.sender,
                validatorTimelock: stateTransition.validatorTimelock,
                chainCreationParams: chainCreationParams,
                protocolVersion: config.contracts.latestProtocolVersion,
                serverNotifier: stateTransition.serverNotifierProxy
            });
    }

    function getVerifierParams() internal returns (VerifierParams memory) {
        return
            VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            });
    }

    function getFeeParams() internal returns (FeeParams memory) {
        return
            FeeParams({
                pubdataPricingMode: config.contracts.diamondInitPubdataPricingMode,
                batchOverheadL1Gas: uint32(config.contracts.diamondInitBatchOverheadL1Gas),
                maxPubdataPerBatch: uint32(config.contracts.diamondInitMaxPubdataPerBatch),
                maxL2GasPerBatch: uint32(config.contracts.diamondInitMaxL2GasPerBatch),
                priorityTxMaxPubdata: uint32(config.contracts.diamondInitPriorityTxMaxPubdata),
                minimalL2GasPrice: uint64(config.contracts.diamondInitMinimalL2GasPrice)
            });
    }

    function getInitializeData(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal returns (DiamondInitializeDataNewChain memory) {
        VerifierParams memory verifierParams = getVerifierParams();

        FeeParams memory feeParams = getFeeParams();

        require(stateTransition.verifier != address(0), "verifier is zero");
        require(config.contracts.bootloaderHash != bytes32(0), "bootloader hash is zero");
        require(config.contracts.defaultAAHash != bytes32(0), "default aa hash is zero");
        require(config.contracts.evmEmulatorHash != bytes32(0), "evm emulator hash is zero");

        return
            DiamondInitializeDataNewChain({
                verifier: IVerifier(stateTransition.verifier),
                verifierParams: verifierParams,
                l2BootloaderBytecodeHash: config.contracts.bootloaderHash,
                l2DefaultAccountBytecodeHash: config.contracts.defaultAAHash,
                l2EvmEmulatorBytecodeHash: config.contracts.evmEmulatorHash,
                priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
                feeParams: feeParams
            });
    }

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "L1AssetRouter")) {
                return type(L1AssetRouter).creationCode;
            } else if (compareStrings(contractName, "L1ERC20Bridge")) {
                return type(L1ERC20Bridge).creationCode;
            } else if (compareStrings(contractName, "L1NativeTokenVault")) {
                return type(L1NativeTokenVault).creationCode;
            } else if (compareStrings(contractName, "BridgedStandardERC20")) {
                return type(BridgedStandardERC20).creationCode;
            } else if (compareStrings(contractName, "Governance")) {
                return type(Governance).creationCode;
            } else if (compareStrings(contractName, "ChainAdminOwnable")) {
                return type(ChainAdminOwnable).creationCode;
            } else if (compareStrings(contractName, "ChainAdmin")) {
                return type(ChainAdmin).creationCode;
            } else if (compareStrings(contractName, "ProxyAdmin")) {
                return type(ProxyAdmin).creationCode;
            } else if (compareStrings(contractName, "RollupDAManager")) {
                return type(RollupDAManager).creationCode;
            } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
                return type(ValidiumL1DAValidator).creationCode;
            } else if (compareStrings(contractName, "Verifier")) {
                if (config.testnetVerifier) {
                    return type(TestnetVerifier).creationCode;
                } else {
                    return type(DualVerifier).creationCode;
                }
            } else if (compareStrings(contractName, "VerifierFflonk")) {
                return type(L1VerifierFflonk).creationCode;
            } else if (compareStrings(contractName, "VerifierPlonk")) {
                return type(L1VerifierPlonk).creationCode;
            } else if (compareStrings(contractName, "DefaultUpgrade")) {
                return type(DefaultUpgrade).creationCode;
            } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
                return type(L1GenesisUpgrade).creationCode;
            } else if (compareStrings(contractName, "ValidatorTimelock")) {
                return type(ValidatorTimelock).creationCode;
            } else if (compareStrings(contractName, "ChainTypeManager")) {
                return type(ChainTypeManager).creationCode;
            } else if (compareStrings(contractName, "BytecodesSupplier")) {
                return type(BytecodesSupplier).creationCode;
            } else if (compareStrings(contractName, "ExecutorFacet")) {
                return type(ExecutorFacet).creationCode;
            } else if (compareStrings(contractName, "AdminFacet")) {
                return type(AdminFacet).creationCode;
            } else if (compareStrings(contractName, "MailboxFacet")) {
                return type(MailboxFacet).creationCode;
            } else if (compareStrings(contractName, "GettersFacet")) {
                return type(GettersFacet).creationCode;
            } else if (compareStrings(contractName, "DiamondInit")) {
                return type(DiamondInit).creationCode;
            } else if (compareStrings(contractName, "ServerNotifier")) {
                return type(ServerNotifier).creationCode;
            } else if (compareStrings(contractName, "UpgradeStageValidator")) {
                return type(UpgradeStageValidator).creationCode;
            }
        } else {
            if (compareStrings(contractName, "Verifier")) {
                if (config.testnetVerifier) {
                    return getCreationCode("TestnetVerifier", true);
                } else {
                    return getCreationCode("DualVerifier", true);
                }
            }
        }
        return ContractsBytecodesLib.getCreationCode(contractName, isZKBytecode);
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "BridgedStandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupDAManager")) {
            return abi.encode();
        } else if (compareStrings(contractName, "RollupL1DAValidator")) {
            return abi.encode(addresses.daAddresses.l1RollupDAValidator);
        } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
            return abi.encode();
        } else if (compareStrings(contractName, "AvailL1DAValidator")) {
            return abi.encode(addresses.daAddresses.availBridge);
        } else if (compareStrings(contractName, "DummyAvailBridge")) {
            return abi.encode();
        } else if (compareStrings(contractName, "Verifier")) {
            return abi.encode(addresses.stateTransition.verifierFflonk, addresses.stateTransition.verifierPlonk);
        } else if (compareStrings(contractName, "VerifierFflonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "VerifierPlonk")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DefaultUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return abi.encode(addresses.bridgehub.bridgehubProxy);
        } else if (compareStrings(contractName, "Governance")) {
            return
                abi.encode(
                    config.ownerAddress,
                    config.contracts.governanceSecurityCouncilAddress,
                    config.contracts.governanceMinDelay
                );
        } else if (compareStrings(contractName, "ChainAdminOwnable")) {
            return abi.encode(config.ownerAddress, address(0));
        } else if (compareStrings(contractName, "AccessControlRestriction")) {
            return abi.encode(uint256(0), config.ownerAddress);
        } else if (compareStrings(contractName, "ChainAdmin")) {
            address[] memory restrictions = new address[](1);
            restrictions[0] = addresses.accessControlRestrictionAddress;
            return abi.encode(restrictions);
        } else if (compareStrings(contractName, "ChainTypeManager")) {
            return abi.encode(addresses.bridgehub.bridgehubProxy);
        } else if (compareStrings(contractName, "BytecodesSupplier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ExecutorFacet")) {
            return abi.encode(config.l1ChainId);
        } else if (compareStrings(contractName, "AdminFacet")) {
            return abi.encode(config.l1ChainId, addresses.daAddresses.rollupDAManager);
        } else if (compareStrings(contractName, "MailboxFacet")) {
            return abi.encode(config.eraChainId, config.l1ChainId);
        } else if (compareStrings(contractName, "GettersFacet")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return abi.encode();
        } else if (compareStrings(contractName, "DiamondInit")) {
            return abi.encode();
        } else {
            revert(string.concat("Contract ", contractName, " creation calldata not set"));
        }
    }

    function calculateExpectedL2Address(string memory contractName) internal returns (address) {
        return Utils.getL2AddressViaCreate2Factory(bytes32(0), getL2BytecodeHash(contractName), hex"");
    }

    function getL2BytecodeHash(string memory contractName) public view virtual returns (bytes32) {
        return L2ContractHelper.hashL2Bytecode(getCreationCode(contractName, true));
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ChainTypeManager")) {
            return
                abi.encodeCall(
                    ChainTypeManager.initialize,
                    getChainTypeManagerInitializeData(addresses.stateTransition)
                );
        } else if (compareStrings(contractName, "ServerNotifier")) {
            return abi.encodeCall(ServerNotifier.initialize, (config.deployerAddress));
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return
                abi.encodeCall(
                    ValidatorTimelock.initialize,
                    (config.deployerAddress, uint32(config.contracts.validatorTimelockExecutionDelay))
                );
        } else {
            revert(string.concat("Contract ", contractName, " initialize calldata not set"));
        }
    }

    function transparentProxyAdmin() internal view override returns (address) {
        return addresses.transparentProxyAdmin;
    }

    function test() internal virtual {}
}
