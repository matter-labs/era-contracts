// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MailboxFacet} from "./facets/Mailbox.sol";
import {ExecutorFacet} from "./facets/Executor.sol";
import {GettersFacet} from "./facets/Getters.sol";
import {AdminFacet} from "./facets/Admin.sol";
import {Multicall3} from "../../dev-contracts/Multicall3.sol";

import {RollupDAManager} from "../data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "../data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "../data-availability/ValidiumL1DAValidator.sol";

import {EraDualVerifier} from "../verifiers/EraDualVerifier.sol";
import {ZKsyncOSDualVerifier} from "../verifiers/ZKsyncOSDualVerifier.sol";
import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "contracts/state-transition/verifiers/EraVerifierPlonk.sol";
import {ZKsyncOSVerifierFflonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol";

import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IEIP7702Checker} from "../chain-interfaces/IEIP7702Checker.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {EraTestnetVerifier} from "../verifiers/EraTestnetVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "../verifiers/ZKsyncOSTestnetVerifier.sol";
import {ValidatorTimelock} from "../ValidatorTimelock.sol";

import {DiamondInit} from "./DiamondInit.sol";
import {L1GenesisUpgrade} from "../../upgrades/L1GenesisUpgrade.sol";
import {Diamond} from "../libraries/Diamond.sol";

import {ZKsyncOSChainTypeManager} from "../ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "../EraChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {ROLLUP_L2_DA_COMMITMENT_SCHEME} from "../../common/Config.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "../chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "../IChainTypeManager.sol";
import {ServerNotifier} from "../../governance/ServerNotifier.sol";

/// @notice Configuration parameters for deploying the GatewayCTMDeployer contract.
// solhint-disable-next-line gas-struct-packing
struct GatewayCTMDeployerConfig {
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Chain ID of the Era chain.
    uint256 eraChainId;
    /// @notice Chain ID of the L1 chain.
    uint256 l1ChainId;
    /// @notice Flag indicating whether to use the testnet verifier.
    bool testnetVerifier;
    /// @notice Flag indicating whether to use ZKsync OS mode.
    bool isZKsyncOS;
    /// @notice Array of function selectors for the Admin facet.
    bytes4[] adminSelectors;
    /// @notice Array of function selectors for the Executor facet.
    bytes4[] executorSelectors;
    /// @notice Array of function selectors for the Mailbox facet.
    bytes4[] mailboxSelectors;
    /// @notice Array of function selectors for the Getters facet.
    bytes4[] gettersSelectors;
    /// @notice Hash of the bootloader bytecode.
    bytes32 bootloaderHash;
    /// @notice Hash of the default account bytecode.
    bytes32 defaultAccountHash;
    /// @notice Hash of the EVM emulator bytecode.
    bytes32 evmEmulatorHash;
    /// @notice Root hash of the genesis state.
    bytes32 genesisRoot;
    /// @notice Leaf index in the genesis rollup.
    uint256 genesisRollupLeafIndex;
    /// @notice Commitment of the genesis batch.
    bytes32 genesisBatchCommitment;
    /// @notice Data for force deployments.
    bytes forceDeploymentsData;
    /// @notice The latest protocol version.
    uint256 protocolVersion;
}

/// @notice Verifier contract addresses.
struct Verifiers {
    /// @notice Address of the Verifier contract.
    address verifier;
    /// @notice Address of the VerifierFflonk contract.
    address verifierFflonk;
    /// @notice Address of the VerifierPlonk contract.
    address verifierPlonk;
}

/// @notice Diamond facet contract addresses.
struct Facets {
    /// @notice Address of the Admin facet contract.
    address adminFacet;
    /// @notice Address of the Mailbox facet contract.
    address mailboxFacet;
    /// @notice Address of the Executor facet contract.
    address executorFacet;
    /// @notice Address of the Getters facet contract.
    address gettersFacet;
    /// @notice Address of the DiamondInit contract.
    address diamondInit;
}

/// @notice Addresses of state transition related contracts.
// solhint-disable-next-line gas-struct-packing
struct StateTransitionContracts {
    /// @notice Address of the ChainTypeManager proxy contract.
    address chainTypeManagerProxy;
    /// @notice Address of the ChainTypeManager implementation contract.
    address chainTypeManagerImplementation;
    /// @notice Verifier contracts.
    Verifiers verifiers;
    /// @notice Diamond facet contracts.
    Facets facets;
    /// @notice Address of the GenesisUpgrade contract.
    address genesisUpgrade;
    /// @notice Address of the implementation of the ValidatorTimelock contract.
    address validatorTimelockImplementation;
    /// @notice Address of the ValidatorTimelock contract.
    address validatorTimelock;
    /// @notice Address of the ProxyAdmin for ChainTypeManager.
    address chainTypeManagerProxyAdmin;
    /// @notice Address of the ServerNotifier proxy contract.
    address serverNotifierProxy;
    /// @notice Address of the ServerNotifier implementation contract.
    address serverNotifierImplementation;
}

/// @notice Addresses of Data Availability (DA) related contracts.
// solhint-disable-next-line gas-struct-packing
struct DAContracts {
    /// @notice Address of the RollupDAManager contract.
    address rollupDAManager;
    /// @notice Address of the RelayedSLDAValidator contract.
    address relayedSLDAValidator;
    /// @notice Address of the ValidiumL1DAValidator contract.
    address validiumDAValidator;
}

/// @notice Collection of all deployed contracts by the GatewayCTMDeployer.
struct DeployedContracts {
    /// @notice Address of the Multicall3 contract.
    address multicall3;
    /// @notice Struct containing state transition related contracts.
    StateTransitionContracts stateTransition;
    /// @notice Struct containing Data Availability related contracts.
    DAContracts daContracts;
    /// @notice Encoded data for the diamond cut operation.
    bytes diamondCutData;
}

/// @title GatewayCTMDeployer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Contract responsible for deploying all the CTM-related contracts on top
/// of the Gateway contract.
/// @dev The expectation is that this contract will be deployed via the built-in L2 `Create2Factory`.
/// This will achieve the fact that the address of this contract (and thus, the addresses of the
/// contract it deploys are deterministic). An important role that this contract plays is in
/// being the first owner of some of the contracts (e.g. ValidatorTimelock), which helps it to initialize it properly
/// and transfer the ownership to the correct governance.
/// @dev Note, that it is expected to be used in zkEVM environment only. Since all of the deployments
/// are done by hash in zkEVM, this contract is actually quite small and cheap to execute in zkEVM environment.
contract GatewayCTMDeployer {
    DeployedContracts internal deployedContracts;

    /// @notice Returns deployed contracts.
    /// @dev Just using `public` mode for the `deployedContracts` field did not work
    /// due to internal issues during testing.
    /// @return contracts The struct with information about the deployed contracts.
    function getDeployedContracts() external view returns (DeployedContracts memory contracts) {
        contracts = deployedContracts;
    }

    constructor(GatewayCTMDeployerConfig memory _config) {
        // Caching some values
        bytes32 salt = _config.salt;
        uint256 eraChainId = _config.eraChainId;
        uint256 l1ChainId = _config.l1ChainId;

        DeployedContracts memory contracts;

        contracts.multicall3 = address(new Multicall3{salt: salt}());

        _deployFacetsAndUpgrades({
            _salt: salt,
            _eraChainId: eraChainId,
            _l1ChainId: l1ChainId,
            _aliasedGovernanceAddress: _config.aliasedGovernanceAddress,
            _deployedContracts: contracts,
            _testnetVerifier: _config.testnetVerifier
        });
        // solhint-disable-next-line func-named-parameters
        _deployVerifier(salt, _config.testnetVerifier, _config.isZKsyncOS, contracts, _config.aliasedGovernanceAddress);

        _deployProxyAdmin(salt, _config.aliasedGovernanceAddress, contracts);

        _deployValidatorTimelock(salt, _config.aliasedGovernanceAddress, contracts);

        _deployServerNotifier(salt, contracts);

        _deployCTM(salt, _config, contracts);
        _setChainTypeManagerInServerNotifier(
            _config.aliasedGovernanceAddress,
            ServerNotifier(contracts.stateTransition.serverNotifierProxy),
            contracts
        );

        deployedContracts = contracts;
    }

    /// @notice Deploys facets and upgrade contracts.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _eraChainId Era Chain ID.
    /// @param _l1ChainId L1 Chain ID.
    /// used by permanent rollups.
    /// @param _aliasedGovernanceAddress The aliased address of the governnace.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployFacetsAndUpgrades(
        bytes32 _salt,
        uint256 _eraChainId,
        uint256 _l1ChainId,
        address _aliasedGovernanceAddress,
        DeployedContracts memory _deployedContracts,
        bool _testnetVerifier
    ) internal {
        _deployedContracts.stateTransition.facets.mailboxFacet = address(
            new MailboxFacet{salt: _salt}({
                _eraChainId: _eraChainId,
                _l1ChainId: _l1ChainId,
                _chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
                _eip7702Checker: IEIP7702Checker(address(0)),
                _isTestnet: _testnetVerifier
            })
        );
        _deployedContracts.stateTransition.facets.executorFacet = address(new ExecutorFacet{salt: _salt}(_l1ChainId));
        _deployedContracts.stateTransition.facets.gettersFacet = address(new GettersFacet{salt: _salt}());

        RollupDAManager rollupDAManager = _deployRollupDAContracts(
            _salt,
            _aliasedGovernanceAddress,
            _deployedContracts
        );
        _deployedContracts.stateTransition.facets.adminFacet = address(
            new AdminFacet{salt: _salt}({
                _l1ChainId: _l1ChainId,
                _rollupDAManager: rollupDAManager,
                _isTestnet: _testnetVerifier
            })
        );

        _deployedContracts.stateTransition.facets.diamondInit = address(new DiamondInit{salt: _salt}(false));
        _deployedContracts.stateTransition.genesisUpgrade = address(new L1GenesisUpgrade{salt: _salt}());
    }

    /// @notice Deploys a ProxyAdmin contract.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _aliasedGovernanceAddress The aliased address of the governnace.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployProxyAdmin(
        bytes32 _salt,
        address _aliasedGovernanceAddress,
        DeployedContracts memory _deployedContracts
    ) internal {
        ProxyAdmin proxyAdmin = new ProxyAdmin{salt: _salt}();
        proxyAdmin.transferOwnership(_aliasedGovernanceAddress);
        _deployedContracts.stateTransition.chainTypeManagerProxyAdmin = address(proxyAdmin);
    }

    /// @notice Deploys the ValidatorTimelock contract.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployValidatorTimelock(
        bytes32 _salt,
        address _aliasedGovernanceAddress,
        DeployedContracts memory _deployedContracts
    ) internal {
        address timelockImplementation = address(new ValidatorTimelock{salt: _salt}(L2_BRIDGEHUB_ADDR));
        _deployedContracts.stateTransition.validatorTimelockImplementation = timelockImplementation;
        _deployedContracts.stateTransition.validatorTimelock = address(
            new TransparentUpgradeableProxy{salt: _salt}(
                timelockImplementation,
                address(_deployedContracts.stateTransition.chainTypeManagerProxyAdmin),
                abi.encodeCall(ValidatorTimelock.initialize, (_aliasedGovernanceAddress, 0))
            )
        );
    }

    /// @notice Deploys a ServerNotifier contract.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployServerNotifier(bytes32 _salt, DeployedContracts memory _deployedContracts) internal {
        address serverNotifierImplementation = address(new ServerNotifier{salt: _salt}());
        _deployedContracts.stateTransition.serverNotifierImplementation = serverNotifierImplementation;
        _deployedContracts.stateTransition.serverNotifierProxy = address(
            new TransparentUpgradeableProxy{salt: _salt}(
                serverNotifierImplementation,
                address(_deployedContracts.stateTransition.chainTypeManagerProxyAdmin),
                abi.encodeCall(ServerNotifier.initialize, (address(this)))
            )
        );
    }

    /// @notice Deploys verifier.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _testnetVerifier Whether testnet verifier should be used.
    /// @param _isZKsyncOS Whether ZKsync OS mode should be used.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// @param _verifierOwner The owner that can add additional verification keys.
    /// in the process of the execution of this function.
    function _deployVerifier(
        bytes32 _salt,
        bool _testnetVerifier,
        bool _isZKsyncOS,
        DeployedContracts memory _deployedContracts,
        address _verifierOwner
    ) internal {
        address fflonkVerifier;
        address verifierPlonk;

        if (_isZKsyncOS) {
            fflonkVerifier = address(new ZKsyncOSVerifierFflonk{salt: _salt}());
            verifierPlonk = address(new ZKsyncOSVerifierPlonk{salt: _salt}());
        } else {
            fflonkVerifier = address(new EraVerifierFflonk{salt: _salt}());
            verifierPlonk = address(new EraVerifierPlonk{salt: _salt}());
        }

        _deployedContracts.stateTransition.verifiers.verifierFflonk = fflonkVerifier;
        _deployedContracts.stateTransition.verifiers.verifierPlonk = verifierPlonk;
        if (_testnetVerifier) {
            if (_isZKsyncOS) {
                _deployedContracts.stateTransition.verifiers.verifier = address(
                    new ZKsyncOSTestnetVerifier{salt: _salt}(
                        IVerifierV2(fflonkVerifier),
                        IVerifier(verifierPlonk),
                        _verifierOwner
                    )
                );
            } else {
                _deployedContracts.stateTransition.verifiers.verifier = address(
                    new EraTestnetVerifier{salt: _salt}(IVerifierV2(fflonkVerifier), IVerifier(verifierPlonk))
                );
            }
        } else {
            if (_isZKsyncOS) {
                _deployedContracts.stateTransition.verifiers.verifier = address(
                    new ZKsyncOSDualVerifier{salt: _salt}(
                        IVerifierV2(fflonkVerifier),
                        IVerifier(verifierPlonk),
                        _verifierOwner
                    )
                );
            } else {
                _deployedContracts.stateTransition.verifiers.verifier = address(
                    new EraDualVerifier{salt: _salt}(IVerifierV2(fflonkVerifier), IVerifier(verifierPlonk))
                );
            }
        }
    }

    /// @notice Deploys DA-related contracts.
    /// @param _salt Salt used for CREATE2 deployments.
    /// used by permanent rollups.
    /// @param _aliasedGovernanceAddress The aliased address of the governnace.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployRollupDAContracts(
        bytes32 _salt,
        address _aliasedGovernanceAddress,
        DeployedContracts memory _deployedContracts
    ) internal returns (RollupDAManager rollupDAManager) {
        rollupDAManager = new RollupDAManager{salt: _salt}();

        ValidiumL1DAValidator validiumDAValidator = new ValidiumL1DAValidator{salt: _salt}();

        RelayedSLDAValidator relayedSLDAValidator = new RelayedSLDAValidator{salt: _salt}();
        rollupDAManager.updateDAPair(address(relayedSLDAValidator), ROLLUP_L2_DA_COMMITMENT_SCHEME, true);

        // Note, that the governance still has to accept it.
        // It will happen in a separate voting after the deployment is done.
        rollupDAManager.transferOwnership(_aliasedGovernanceAddress);

        _deployedContracts.daContracts.rollupDAManager = address(rollupDAManager);
        _deployedContracts.daContracts.relayedSLDAValidator = address(relayedSLDAValidator);
        _deployedContracts.daContracts.validiumDAValidator = address(validiumDAValidator);
    }

    /// @notice Deploys DA-related contracts.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _config The deployment config.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployCTM(
        bytes32 _salt,
        GatewayCTMDeployerConfig memory _config,
        DeployedContracts memory _deployedContracts
    ) internal {
        if (_config.isZKsyncOS) {
            _deployedContracts.stateTransition.chainTypeManagerImplementation = address(
                new ZKsyncOSChainTypeManager{salt: _salt}(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0))
            );
        } else {
            _deployedContracts.stateTransition.chainTypeManagerImplementation = address(
                new EraChainTypeManager{salt: _salt}(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0))
            );
        }

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.facets.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.adminSelectors
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.facets.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.gettersSelectors
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.facets.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.mailboxSelectors
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.facets.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.executorSelectors
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(_deployedContracts.stateTransition.verifiers.verifier),
            l2BootloaderBytecodeHash: _config.bootloaderHash,
            l2DefaultAccountBytecodeHash: _config.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: _config.evmEmulatorHash
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: _deployedContracts.stateTransition.facets.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        _deployedContracts.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: _deployedContracts.stateTransition.genesisUpgrade,
            genesisBatchHash: _config.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(_config.genesisRollupLeafIndex),
            genesisBatchCommitment: _config.genesisBatchCommitment,
            diamondCut: diamondCut,
            // Note, it is the same as for contracts that are based on L2
            forceDeploymentsData: _config.forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: _config.aliasedGovernanceAddress,
            validatorTimelock: _deployedContracts.stateTransition.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: _config.protocolVersion,
            serverNotifier: _deployedContracts.stateTransition.serverNotifierProxy
        });

        bytes memory initCalldata = abi.encodeCall(IChainTypeManager.initialize, (diamondInitData));

        _deployedContracts.stateTransition.chainTypeManagerProxy = address(
            new TransparentUpgradeableProxy{salt: _salt}(
                _deployedContracts.stateTransition.chainTypeManagerImplementation,
                address(_deployedContracts.stateTransition.chainTypeManagerProxyAdmin),
                initCalldata
            )
        );
    }

    /// @notice Sets the previously deployed CTM inside the ServerNotifier
    /// @param _aliasedGovernanceAddress The aliased address of the governnace.
    /// @param _serverNotifier The address of the server notifier
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _setChainTypeManagerInServerNotifier(
        address _aliasedGovernanceAddress,
        ServerNotifier _serverNotifier,
        DeployedContracts memory _deployedContracts
    ) internal {
        ServerNotifier(_serverNotifier).setChainTypeManager(
            IChainTypeManager(_deployedContracts.stateTransition.chainTypeManagerProxy)
        );
        // Note, that the governance still has to accept it.
        // It will happen in a separate voting after the deployment is done.
        _serverNotifier.transferOwnership(_aliasedGovernanceAddress);
    }
}
