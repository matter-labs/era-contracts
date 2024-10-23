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

import {Verifier} from "../Verifier.sol";
import {VerifierParams, IVerifier} from "../chain-interfaces/IVerifier.sol";
import {TestnetVerifier} from "../TestnetVerifier.sol";
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

// solhint-disable gas-custom-errors

/// Needed to deterministically deploy everything related to CTM
/// We can not just use Create2Factory mainly because some of the contracts deployed are Ownable and so 
/// we need the contract to actually transfer the ownership to the governance.
/// To ensure deterministic addresses, this contract does have to be deployed via Create2Factory
struct GatewayCTMDeployerConfig {
    address governanceAddress;
    bytes32 salt;
    uint256 eraChainId;
    uint256 l1ChainId;
    address rollupL2DAValidatorAddress;
    bool testnetVerifier;

    bytes4[] adminSelectors;
    bytes4[] executorSelectors;
    bytes4[] mailboxSelectors;
    bytes4[] gettersSelectors;

    VerifierParams verifierParams;
    FeeParams feeParams;

    bytes32 bootloaderHash;
    bytes32 defaultAccountHash;
    uint256 priorityTxMaxGasLimit;

    bytes32 genesisRoot;
    uint256 genesisRollupLeafIndex;
    bytes32 genesisBatchCommitment;

    bytes forceDeploymentsData;

    uint256 protocolVersion;
}

struct StateTransitionContracts {
    address chainTypeManagerProxy;
    address chainTypeManagerImplementation;
    address verifier;
    address adminFacet;
    address mailboxFacet;
    address executorFacet;
    address gettersFacet;
    address diamondInit;
    address genesisUpgrade;
    address validatorTimelock;
    address chainTypeManagerProxyAdmin;
}

struct DAContracts {
    address rollupDAManager;
    address relayedSLDAValidator;
    address validiumDAValidator;
}

struct DeployedContracts {
    address multicall3;
    StateTransitionContracts stateTransition;
    DAContracts daContracts;
    bytes diamondCutData;
}

address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;

contract GatewayCTMDeployer {
    // Public getters for deployed contracts.
    // Can be used in tests for generating the final addresses or
    // generally for easier accessibility.
    DeployedContracts internal deployedContracts;

    function getDeployedContracts() external view returns (DeployedContracts memory contracts) {
        contracts = deployedContracts;
    }

    constructor(
        GatewayCTMDeployerConfig memory _config
    ) {
        // Caching some values
        bytes32 salt = _config.salt;
        uint256 eraChainId = _config.eraChainId;
        uint256 l1ChainId = _config.l1ChainId;
        
        // All the action is done inside constructor.
        // It may seem like a lot is going for as for a single tx, but 
        // note that on Era all deployments are done by hash and not by bytecode,
        // so it is actually relatively lightweight tx.

        DeployedContracts memory contracts;

        contracts.multicall3 = address(new Multicall3{salt: salt}());

        _deployFacetsAndUpgrades(
            salt,
            eraChainId,
            l1ChainId,
            _config.rollupL2DAValidatorAddress,
            _config.governanceAddress,
            contracts
        );
        _deployVerifier(salt, _config.testnetVerifier, contracts);

        ValidatorTimelock timelock = new ValidatorTimelock{salt: salt}(address(this), 0, eraChainId);
        contracts.stateTransition.validatorTimelock = address(timelock);

        _deployCTM(salt, _config, contracts);
        _setChainTypeManagerInValidatorTimelock(_config.governanceAddress, timelock, contracts);

        deployedContracts = contracts;
    }

    function _deployFacetsAndUpgrades(
        bytes32 _salt,
        uint256 _eraChainId,
        uint256 _l1ChainId,
        address _rollupL2DAValidatorAddress,
        address _governanceAddress,
        DeployedContracts memory _deployedContracts
    ) internal {
        _deployedContracts.stateTransition.mailboxFacet = address(new MailboxFacet{salt: _salt}(_eraChainId, _l1ChainId));
        _deployedContracts.stateTransition.executorFacet = address(new ExecutorFacet{salt: _salt}(_l1ChainId));
        _deployedContracts.stateTransition.gettersFacet = address(new GettersFacet{salt: _salt}());

        RollupDAManager rollupDAManager = _deployRollupDAManager(
            _salt,
            _rollupL2DAValidatorAddress,
            _governanceAddress,
            _deployedContracts
        );
        _deployedContracts.stateTransition.adminFacet = address(new AdminFacet{salt: _salt}(_l1ChainId, rollupDAManager));

        _deployedContracts.stateTransition.diamondInit = address(new DiamondInit{salt: _salt}());
        _deployedContracts.stateTransition.genesisUpgrade = address(new L1GenesisUpgrade{salt: _salt}());

    }

    function _deployVerifier(
        bytes32 _salt,
        bool _testnetVerifier,
        DeployedContracts memory _deployedContracts
    ) internal {
        if (_testnetVerifier) {
            _deployedContracts.stateTransition.verifier = address(new TestnetVerifier{salt: _salt}());
        } else {
            _deployedContracts.stateTransition.verifier = address(new Verifier{salt: _salt}());
        }
    }

    function _deployRollupDAManager(
        bytes32 _salt, 
        address _rollupL2DAValidatorAddress,
        address _governanceAddress,
        DeployedContracts memory _deployedContracts
    ) internal returns (RollupDAManager rollupDAManager) {
        rollupDAManager = new RollupDAManager{salt: _salt}();

        ValidiumL1DAValidator validiumDAValidator = new ValidiumL1DAValidator{salt: _salt}();

        RelayedSLDAValidator relayedSLDAValidator = new RelayedSLDAValidator{salt: _salt}();
        rollupDAManager.updateDAPair(address(relayedSLDAValidator), _rollupL2DAValidatorAddress, true);

        // Note, that the governance still has to accept it. 
        // It will happen in a separate voting after the deployment is done.
        rollupDAManager.transferOwnership(_governanceAddress);

        _deployedContracts.daContracts.rollupDAManager = address(rollupDAManager);
        _deployedContracts.daContracts.relayedSLDAValidator = address(relayedSLDAValidator);
        _deployedContracts.daContracts.validiumDAValidator = address(validiumDAValidator);
    }

    function _deployCTM(
        bytes32 _salt,
        GatewayCTMDeployerConfig memory _config,
        DeployedContracts memory _deployedContracts
    ) internal {
        _deployedContracts.stateTransition.chainTypeManagerImplementation = address(new ChainTypeManager{salt: _salt}(
            L2_BRIDGEHUB_ADDR
        ));
        ProxyAdmin proxyAdmin = new ProxyAdmin{salt: _salt}();
        proxyAdmin.transferOwnership(_config.governanceAddress);
        _deployedContracts.stateTransition.chainTypeManagerProxyAdmin = address(proxyAdmin);

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
            priorityTxMaxGasLimit: _config.priorityTxMaxGasLimit,
            feeParams: _config.feeParams,
            // We can not provide zero value there. At the same time, there is no such contract on gateway
            blobVersionedHashRetriever: ADDRESS_ONE
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
            owner: _config.governanceAddress,
            validatorTimelock: _deployedContracts.stateTransition.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: _config.protocolVersion
        });

        _deployedContracts.stateTransition.chainTypeManagerProxy = address(new TransparentUpgradeableProxy{salt: _salt}(
            _deployedContracts.stateTransition.chainTypeManagerImplementation,
            address(proxyAdmin),
            abi.encodeCall(ChainTypeManager.initialize, (diamondInitData))
        ));
    }

    function _setChainTypeManagerInValidatorTimelock(
        address _governanceAddress,
        ValidatorTimelock timelock,
        DeployedContracts memory _deployedContracts
    ) internal {
        timelock.setChainTypeManager(
            IChainTypeManager(_deployedContracts.stateTransition.chainTypeManagerProxy)
        );

        // Note, that the governance still has to accept it. 
        // It will happen in a separate voting after the deployment is done.
        timelock.transferOwnership(_governanceAddress);
    }

}
