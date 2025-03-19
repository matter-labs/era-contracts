// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxFacet} from "./facets/Mailbox.sol";
import {ExecutorFacet} from "./facets/Executor.sol";
import {GettersFacet} from "./facets/Getters.sol";
import {AdminFacet} from "./facets/Admin.sol";
import {Multicall3} from "../../dev-contracts/Multicall3.sol";

import {RollupDAManager} from "../data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "../data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "../data-availability/ValidiumL1DAValidator.sol";

import {DualVerifier} from "../verifiers/DualVerifier.sol";
import {L2VerifierFflonk} from "../verifiers/L2VerifierFflonk.sol";
import {L2VerifierPlonk} from "../verifiers/L2VerifierPlonk.sol";

import {VerifierParams, IVerifier} from "../chain-interfaces/IVerifier.sol";
import {TestnetVerifier} from "../verifiers/TestnetVerifier.sol";
import {ValidatorTimelock} from "../ValidatorTimelock.sol";
import {FeeParams} from "../chain-deps/ZKChainStorage.sol";

import {DiamondInit} from "./DiamondInit.sol";
import {L1GenesisUpgrade} from "../../upgrades/L1GenesisUpgrade.sol";
import {Diamond} from "../libraries/Diamond.sol";

import {ChainTypeManager} from "../ChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR} from "../../common/L2ContractAddresses.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "../chain-interfaces/IDiamondInit.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams, IChainTypeManager} from "../IChainTypeManager.sol";
import {ServerNotifier} from "../../governance/ServerNotifier.sol";

/// @notice Configuration parameters for deploying the GatewayCTMDeployer contract.
struct GatewayCTMDeployerConfig {
    /// @notice Address of the aliased governance contract.
    address aliasedGovernanceAddress;
    /// @notice Salt used for deterministic deployments via CREATE2.
    bytes32 salt;
    /// @notice Chain ID of the Era chain.
    uint256 eraChainId;
    /// @notice Chain ID of the L1 chain.
    uint256 l1ChainId;
    /// @notice Address of the Rollup L2 Data Availability Validator.
    address rollupL2DAValidatorAddress;
    /// @notice Flag indicating whether to use the testnet verifier.
    bool testnetVerifier;
    /// @notice Array of function selectors for the Admin facet.
    bytes4[] adminSelectors;
    /// @notice Array of function selectors for the Executor facet.
    bytes4[] executorSelectors;
    /// @notice Array of function selectors for the Mailbox facet.
    bytes4[] mailboxSelectors;
    /// @notice Array of function selectors for the Getters facet.
    bytes4[] gettersSelectors;
    /// @notice Parameters for the verifier contract.
    VerifierParams verifierParams;
    /// @notice Parameters related to fees.
    /// @dev They are mainly related to the L1->L2 transactions, fees for
    /// which are not processed on Gateway. However, we still need these
    /// values to deploy new chain's instances on Gateway.
    FeeParams feeParams;
    /// @notice Hash of the bootloader bytecode.
    bytes32 bootloaderHash;
    /// @notice Hash of the default account bytecode.
    bytes32 defaultAccountHash;
    /// @notice Hash of the EVM emulator bytecode.
    bytes32 evmEmulatorHash;
    /// @notice Maximum gas limit for priority transactions.
    uint256 priorityTxMaxGasLimit;
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

/// @notice Addresses of state transition related contracts.
// solhint-disable-next-line gas-struct-packing
struct StateTransitionContracts {
    /// @notice Address of the ChainTypeManager proxy contract.
    address chainTypeManagerProxy;
    /// @notice Address of the ChainTypeManager implementation contract.
    address chainTypeManagerImplementation;
    /// @notice Address of the Verifier contract.
    address verifier;
    /// @notice Address of the VerifierPlonk contract.
    address verifierPlonk;
    /// @notice Address of the VerifierFflonk contract.
    address verifierFflonk;
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
    /// @notice Address of the GenesisUpgrade contract.
    address genesisUpgrade;
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

/// @dev The constant address to be used for the blobHashRetriever inside the contracts.
/// At the time of this writing the blob hash retriever is not used at all, but the zero-address
/// check is still yet present, so we use address one as the substitution.
address constant BLOB_HASH_RETRIEVER_ADDR = address(uint160(1));

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
            _rollupL2DAValidatorAddress: _config.rollupL2DAValidatorAddress,
            _aliasedGovernanceAddress: _config.aliasedGovernanceAddress,
            _deployedContracts: contracts
        });
        _deployVerifier(salt, _config.testnetVerifier, contracts);

        ValidatorTimelock timelock = new ValidatorTimelock{salt: salt}(address(this), 0);
        contracts.stateTransition.validatorTimelock = address(timelock);

        _deployProxyAdmin(salt, _config.aliasedGovernanceAddress, contracts);

        _deployServerNotifier(salt, contracts);

        _deployCTM(salt, _config, contracts);
        _setChainTypeManagerInValidatorTimelock(_config.aliasedGovernanceAddress, timelock, contracts);
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
    /// @param _rollupL2DAValidatorAddress The expected L2 DA Validator to be
    /// used by permanent rollups.
    /// @param _aliasedGovernanceAddress The aliased address of the governnace.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployFacetsAndUpgrades(
        bytes32 _salt,
        uint256 _eraChainId,
        uint256 _l1ChainId,
        address _rollupL2DAValidatorAddress,
        address _aliasedGovernanceAddress,
        DeployedContracts memory _deployedContracts
    ) internal {
        _deployedContracts.stateTransition.mailboxFacet = address(
            new MailboxFacet{salt: _salt}(_eraChainId, _l1ChainId)
        );
        _deployedContracts.stateTransition.executorFacet = address(new ExecutorFacet{salt: _salt}(_l1ChainId));
        _deployedContracts.stateTransition.gettersFacet = address(new GettersFacet{salt: _salt}());

        RollupDAManager rollupDAManager = _deployRollupDAContracts(
            _salt,
            _rollupL2DAValidatorAddress,
            _aliasedGovernanceAddress,
            _deployedContracts
        );
        _deployedContracts.stateTransition.adminFacet = address(
            new AdminFacet{salt: _salt}(_l1ChainId, rollupDAManager)
        );

        _deployedContracts.stateTransition.diamondInit = address(new DiamondInit{salt: _salt}());
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

    /// @notice Deploys a ServerNotifier contract.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployServerNotifier(bytes32 _salt, DeployedContracts memory _deployedContracts) internal {
        address serverNotifierImplementation = address(new ServerNotifier{salt: _salt}(true));
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
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployVerifier(
        bytes32 _salt,
        bool _testnetVerifier,
        DeployedContracts memory _deployedContracts
    ) internal {
        L2VerifierFflonk fflonkVerifier = new L2VerifierFflonk{salt: _salt}();
        _deployedContracts.stateTransition.verifierFflonk = address(fflonkVerifier);
        L2VerifierPlonk verifierPlonk = new L2VerifierPlonk{salt: _salt}();
        _deployedContracts.stateTransition.verifierPlonk = address(verifierPlonk);
        if (_testnetVerifier) {
            _deployedContracts.stateTransition.verifier = address(
                new TestnetVerifier{salt: _salt}(fflonkVerifier, verifierPlonk)
            );
        } else {
            _deployedContracts.stateTransition.verifier = address(
                new DualVerifier{salt: _salt}(fflonkVerifier, verifierPlonk)
            );
        }
    }

    /// @notice Deploys DA-related contracts.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _rollupL2DAValidatorAddress The expected L2 DA Validator to be
    /// used by permanent rollups.
    /// @param _aliasedGovernanceAddress The aliased address of the governnace.
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _deployRollupDAContracts(
        bytes32 _salt,
        address _rollupL2DAValidatorAddress,
        address _aliasedGovernanceAddress,
        DeployedContracts memory _deployedContracts
    ) internal returns (RollupDAManager rollupDAManager) {
        rollupDAManager = new RollupDAManager{salt: _salt}();

        ValidiumL1DAValidator validiumDAValidator = new ValidiumL1DAValidator{salt: _salt}();

        RelayedSLDAValidator relayedSLDAValidator = new RelayedSLDAValidator{salt: _salt}();
        rollupDAManager.updateDAPair(address(relayedSLDAValidator), _rollupL2DAValidatorAddress, true);

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
        _deployedContracts.stateTransition.chainTypeManagerImplementation = address(
            new ChainTypeManager{salt: _salt}(L2_BRIDGEHUB_ADDR)
        );

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.adminSelectors
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _config.gettersSelectors
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.mailboxSelectors
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: _deployedContracts.stateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: _config.executorSelectors
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(_deployedContracts.stateTransition.verifier),
            verifierParams: _config.verifierParams,
            l2BootloaderBytecodeHash: _config.bootloaderHash,
            l2DefaultAccountBytecodeHash: _config.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: _config.evmEmulatorHash,
            priorityTxMaxGasLimit: _config.priorityTxMaxGasLimit,
            feeParams: _config.feeParams,
            blobVersionedHashRetriever: BLOB_HASH_RETRIEVER_ADDR
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: _deployedContracts.stateTransition.diamondInit,
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

        _deployedContracts.stateTransition.chainTypeManagerProxy = address(
            new TransparentUpgradeableProxy{salt: _salt}(
                _deployedContracts.stateTransition.chainTypeManagerImplementation,
                address(_deployedContracts.stateTransition.chainTypeManagerProxyAdmin),
                abi.encodeCall(ChainTypeManager.initialize, (diamondInitData))
            )
        );
    }

    /// @notice Sets the previously deployed CTM inside the ValidatorTimelock
    /// @param _aliasedGovernanceAddress The aliased address of the governnace.
    /// @param _timelock The address of the validator timelock
    /// @param _deployedContracts The struct with deployed contracts, that will be mofiied
    /// in the process of the execution of this function.
    function _setChainTypeManagerInValidatorTimelock(
        address _aliasedGovernanceAddress,
        ValidatorTimelock _timelock,
        DeployedContracts memory _deployedContracts
    ) internal {
        _timelock.setChainTypeManager(IChainTypeManager(_deployedContracts.stateTransition.chainTypeManagerProxy));

        // Note, that the governance still has to accept it.
        // It will happen in a separate voting after the deployment is done.
        _timelock.transferOwnership(_aliasedGovernanceAddress);
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
