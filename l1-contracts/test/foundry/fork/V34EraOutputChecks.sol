// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {
    MAX_NEW_FACTORY_DEPS,
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SEMVER_MINOR_OFFSET} from "contracts/common/libraries/SemVer.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {Call} from "contracts/governance/Common.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {Bytes} from "contracts/vendor/Bytes.sol";

/// @title V34EraOutputChecks
/// @notice What the v34 Era upgrade's output must hold, given the facts it was generated from: the base
/// `contracts_config` keys, the chain upgrade cut and its L2 transaction, the new chains' creation params, the
/// governance stages, the ServerNotifier upgrade, the test calls and every deployment's constructor arguments.
/// @dev Reads `ecosystem.toml` in `DefaultCTMUpgrade.saveOutput`'s layout and protocol-ops' `deployments.json`; the
/// caller supplies the facts. `V34EraUpgrade.t.sol` reads them from the chain, the build and the env TOML;
/// `V34EraOutputChecks.t.sol` from a fixture, to show each check failing on a tampered output.
library V34EraOutputChecks {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `DefaultCTMUpgrade.getCreationCalldata`'s for the governance upgrade timer.
    uint256 internal constant TIMER_MAX_ADDITIONAL_DELAY = 2 weeks;
    /// @dev The bootloader, the default account and the EVM emulator lead the L2 upgrade tx's factory deps.
    uint256 internal constant BASE_SYSTEM_FACTORY_DEPS = 3;
    /// @dev v34's facets: Admin, Getters, Mailbox, Executor, Migrator, Committer.
    uint256 private constant FACETS = 6;
    /// @dev `FixedForceDeploymentsData`'s `*BytecodeInfo` / `beaconDeployerInfo` fields.
    uint256 private constant BYTECODE_INFO_FIELDS = 10;

    /// @notice A check failed.
    error OutputCheckFailed(string check);
    /// @notice A value differs from the expected one. A zero `got` means an expected item is missing, a zero
    /// `expected` that an item is not expected.
    error OutputMismatch(string check, bytes32 got, bytes32 expected);

    /// @dev The `ecosystem.toml` keys the checks read.
    struct Output {
        bytes chainUpgradeDiamondCut;
        bytes diamondCutData;
        bytes forceDeploymentsData;
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        bool isTestnet;
        uint256 timerDelay;
        Call[] stage0;
        Call[] stage1;
        Call[] stage2;
        address ctmAdmin;
        address ctmAdminOwner;
        Call[] serverNotifierUpgrade;
        Call[] testUpgradeChain;
        address testUpgradeChainCaller;
        Call[] testCreateChain;
        address testCreateChainCaller;
        Addresses addresses;
    }

    /// @dev `[state_transition]` and `[deployed_addresses]`: the deployed contracts, then the reused ones.
    struct Addresses {
        address adminFacet;
        address gettersFacet;
        address mailboxFacet;
        address executorFacet;
        address migratorFacet;
        address committerFacet;
        address diamondInit;
        address eip7702Checker;
        address verifier;
        address verifierFflonk;
        address airbenderVerifier;
        address defaultUpgrade;
        address ctmImplementation;
        address serverNotifierImplementation;
        address timer;
        address stageValidator;
        address ctm;
        address genesisUpgrade;
        address bytecodesSupplier;
        address permissionlessValidator;
        address ctmProxyAdmin;
        address rollupDAManager;
    }

    /// @dev One entry of `deployments.json`.
    struct Deployment {
        /// @dev As `AllContractsHashes.json` names it, e.g. `l1-contracts/AdminFacet`.
        string contractName;
        address deployed;
        bytes args;
    }

    /// @dev The facts the output must match.
    struct References {
        /// @dev From `upgrade-envs/v0.34.0-era/<env>.toml`.
        bool isTestnet;
        uint256 timerDelay;
        bytes32 salt;
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        L1Facts l1;
        Genesis genesis;
        L2Bytecodes l2;
    }

    /// @dev The L1 before the upgrade.
    struct L1Facts {
        uint256 l1ChainId;
        uint256 eraChainId;
        uint256 maxNumberOfZKChains;
        address bridgehub;
        address ctm;
        address ctmOwner;
        address ctmProxyAdmin;
        address bytecodesSupplier;
        address permissionlessValidator;
        address interopCenter;
        address genesisUpgrade;
        address rollupDAManager;
        address chainAssetHandler;
        address l1AssetRouter;
        address chainRegistrationSender;
        address serverNotifier;
        address serverNotifierProxyAdmin;
        address ecosystemAdmin;
        address ecosystemAdminOwner;
        bytes32 zkTokenAssetId;
        /// @dev The chain the script introspects: the bridgehub's first chain of the CTM on its version.
        address referenceChain;
        address referenceChainAdmin;
        bytes4[] referenceChainSelectors;
        uint256 testChainId;
    }

    struct Genesis {
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        bytes32 root;
        uint64 leafIndex;
        bytes32 batchCommitment;
        bytes32 airbenderBatchCommitment;
    }

    struct L2Bytecodes {
        /// @dev The L2 upgrade tx's, in order.
        IL2ContractDeployer.ForceDeployment[] forceDeployments;
        /// @dev The L2 upgrade tx's, as a set.
        bytes32[] factoryDeps;
        bytes32 beaconProxy;
        /// @dev `FixedForceDeploymentsData`'s, in field order.
        bytes32[] bytecodeInfos;
    }

    /// @dev A call a stage holds exactly once, with exactly this calldata.
    struct StageCall {
        string name;
        address target;
        bytes data;
    }

    /// @dev A contract the upgrade deploys, with its constructor arguments and their names.
    struct ExpectedDeployment {
        string contractName;
        address deployed;
        bytes args;
        string[] argNames;
    }

    // ─── Reading ─────────────────────────────────────────────────────────────────────

    function readOutput(string memory _toml) internal pure returns (Output memory out) {
        out.chainUpgradeDiamondCut = vm.parseTomlBytes(_toml, "$.chain_upgrade_diamond_cut");
        out.diamondCutData = vm.parseTomlBytes(_toml, "$.contracts_config.diamond_cut_data");
        out.forceDeploymentsData = vm.parseTomlBytes(_toml, "$.contracts_config.force_deployments_data");
        out.oldProtocolVersion = vm.parseTomlUint(_toml, "$.contracts_config.old_protocol_version");
        out.newProtocolVersion = vm.parseTomlUint(_toml, "$.contracts_config.new_protocol_version");
        out.isTestnet = vm.parseTomlBool(_toml, "$.contracts_config.is_testnet");
        out.timerDelay = vm.parseTomlUint(_toml, "$.contracts_config.governance_upgrade_timer_initial_delay");
        out.stage0 = _readCalls(_toml, "$.governance_calls.stage0_calls");
        out.stage1 = _readCalls(_toml, "$.governance_calls.stage1_calls");
        out.stage2 = _readCalls(_toml, "$.governance_calls.stage2_calls");
        out.ctmAdmin = vm.parseTomlAddress(_toml, "$.ctm_admin_calls.chain_admin");
        out.ctmAdminOwner = vm.parseTomlAddress(_toml, "$.ctm_admin_calls.chain_admin_owner");
        out.serverNotifierUpgrade = _readCalls(_toml, "$.ctm_admin_calls.server_notifier_upgrade");
        out.testUpgradeChain = _readCalls(_toml, "$.test_upgrade_calls.test_upgrade_chain");
        out.testUpgradeChainCaller = vm.parseTomlAddress(_toml, "$.test_upgrade_calls.test_upgrade_chain_caller");
        out.testCreateChain = _readCalls(_toml, "$.test_upgrade_calls.test_create_chain");
        out.testCreateChainCaller = vm.parseTomlAddress(_toml, "$.test_upgrade_calls.test_create_chain_caller");
        out.addresses = _readAddresses(_toml);
    }

    /// @dev `deployments.json`: `{salt, deployments: [{contract, address, args}]}`.
    function readDeployments(
        string memory _json
    ) internal view returns (bytes32 salt, Deployment[] memory deployments) {
        salt = vm.parseJsonBytes32(_json, "$.salt");
        uint256 count = 0;
        while (vm.keyExistsJson(_json, _deploymentKey(count, ""))) {
            ++count;
        }
        deployments = new Deployment[](count);
        for (uint256 i = 0; i < count; ++i) {
            deployments[i] = Deployment({
                contractName: vm.parseJsonString(_json, _deploymentKey(i, ".contract")),
                deployed: vm.parseJsonAddress(_json, _deploymentKey(i, ".address")),
                args: vm.parseJsonBytes(_json, _deploymentKey(i, ".args"))
            });
        }
    }

    // ─── Decoding, shared with the tests ─────────────────────────────────────────────

    function proposedUpgrade(Diamond.DiamondCutData memory _cut) internal pure returns (ProposedUpgrade memory) {
        _eqWord(
            bytes4(_cut.initCalldata),
            IDefaultUpgrade.upgrade.selector,
            "upgrade cut: initCalldata calls upgrade(ProposedUpgrade)"
        );
        return abi.decode(Bytes.slice(_cut.initCalldata, 4), (ProposedUpgrade));
    }

    function forceDeployments(
        bytes memory _l2TxData
    ) internal pure returns (IL2ContractDeployer.ForceDeployment[] memory) {
        _eqWord(
            bytes4(_l2TxData),
            IL2ContractDeployer.forceDeployOnAddresses.selector,
            "L2 upgrade tx: calls forceDeployOnAddresses"
        );
        return abi.decode(Bytes.slice(_l2TxData, 4), (IL2ContractDeployer.ForceDeployment[]));
    }

    /// @dev The params of stage 1's one `setChainCreationParams` call.
    function creationParams(
        Call[] memory _stage1Calls,
        address _ctm
    ) internal pure returns (ChainCreationParams memory) {
        uint256 at = _indexOf(
            _stage1Calls,
            _ctm,
            IChainTypeManager.setChainCreationParams.selector,
            "stage 1: setChainCreationParams exactly once"
        );
        return abi.decode(Bytes.slice(_stage1Calls[at].data, 4), (ChainCreationParams));
    }

    function bytecodeInfos(FixedForceDeploymentsData memory _data) internal pure returns (bytes[] memory infos) {
        infos = new bytes[](BYTECODE_INFO_FIELDS);
        infos[0] = _data.bridgehubBytecodeInfo;
        infos[1] = _data.l2AssetRouterBytecodeInfo;
        infos[2] = _data.l2NtvBytecodeInfo;
        infos[3] = _data.messageRootBytecodeInfo;
        infos[4] = _data.chainAssetHandlerBytecodeInfo;
        infos[5] = _data.interopCenterBytecodeInfo;
        infos[6] = _data.interopHandlerBytecodeInfo;
        infos[7] = _data.assetTrackerBytecodeInfo;
        infos[8] = _data.beaconDeployerInfo;
        infos[9] = _data.baseTokenHolderBytecodeInfo;
    }

    /// @dev The cut's facet cuts after its leading Removes.
    function adds(Diamond.DiamondCutData memory _cut) internal pure returns (Diamond.FacetCut[] memory added) {
        uint256 removes = _removeCount(_cut.facetCuts);
        added = new Diamond.FacetCut[](_cut.facetCuts.length - removes);
        for (uint256 i = 0; i < added.length; ++i) {
            added[i] = _cut.facetCuts[removes + i];
        }
    }

    function removedSelectors(Diamond.DiamondCutData memory _cut) internal pure returns (bytes4[] memory) {
        return _selectorsOf(_cut.facetCuts, 0, _removeCount(_cut.facetCuts));
    }

    // ─── The checks ──────────────────────────────────────────────────────────────────

    /// @notice Reverts with `OutputCheckFailed` or `OutputMismatch` at the first check the output fails.
    function check(
        Output memory _out,
        bytes32 _salt,
        Deployment[] memory _deployments,
        References memory _refs
    ) internal pure {
        _checkBaseKeys(_out, _refs);
        Diamond.DiamondCutData memory cut = abi.decode(_out.chainUpgradeDiamondCut, (Diamond.DiamondCutData));
        _checkProposedUpgrade(cut, _refs);
        _checkUpgradeCut(cut, _out.addresses, _refs.l1.referenceChainSelectors);
        _checkCreationParams(_out, cut, _refs);
        _checkStages(_out, _refs);
        _checkCtmAdminCalls(_out, _refs);
        _checkTestCalls(_out, cut, _refs);
        _checkDeployments(_out.addresses, _salt, _deployments, _refs);
    }

    function _checkBaseKeys(Output memory _out, References memory _refs) private pure {
        _eqUint(_out.oldProtocolVersion, _refs.oldProtocolVersion, "contracts_config.old_protocol_version");
        _eqUint(_out.newProtocolVersion, _refs.newProtocolVersion, "contracts_config.new_protocol_version");
        _eqBool(_out.isTestnet, _refs.isTestnet, "contracts_config.is_testnet = the env's testnet_verifier");
        _eqUint(_out.timerDelay, _refs.timerDelay, "contracts_config.governance_upgrade_timer_initial_delay");
        Addresses memory a = _out.addresses;
        L1Facts memory l1 = _refs.l1;
        _eqAddress(a.ctm, l1.ctm, "state_transition.chain_type_manager_proxy");
        _eqAddress(a.genesisUpgrade, l1.genesisUpgrade, "state_transition.genesis_upgrade_addr");
        _eqAddress(a.bytecodesSupplier, l1.bytecodesSupplier, "state_transition.bytecodes_supplier_addr");
        _eqAddress(
            a.permissionlessValidator,
            l1.permissionlessValidator,
            "state_transition.permissionless_validator_addr"
        );
        _eqAddress(a.ctmProxyAdmin, l1.ctmProxyAdmin, "deployed_addresses.transparent_proxy_admin");
        _eqAddress(a.rollupDAManager, l1.rollupDAManager, "deployed_addresses.l1_rollup_da_manager");
    }

    function _checkProposedUpgrade(Diamond.DiamondCutData memory _cut, References memory _refs) private pure {
        ProposedUpgrade memory upgrade = proposedUpgrade(_cut);
        Genesis memory genesis = _refs.genesis;
        _eqWord(upgrade.bootloaderHash, genesis.bootloaderHash, "ProposedUpgrade: bootloader hash");
        _eqWord(upgrade.defaultAccountHash, genesis.defaultAccountHash, "ProposedUpgrade: default account hash");
        _eqWord(upgrade.evmEmulatorHash, genesis.evmEmulatorHash, "ProposedUpgrade: EVM emulator hash");
        VerifierParams memory noParams;
        _eqAddress(upgrade.verifier, address(0), "ProposedUpgrade: verifier unset");
        _eqBytes(abi.encode(upgrade.verifierParams), abi.encode(noParams), "ProposedUpgrade: verifier params unset");
        _eqBytes(upgrade.l1ContractsUpgradeCalldata, "", "ProposedUpgrade: l1ContractsUpgradeCalldata empty");
        _eqBytes(upgrade.postUpgradeCalldata, "", "ProposedUpgrade: postUpgradeCalldata empty");
        _eqUint(upgrade.upgradeTimestamp, 0, "ProposedUpgrade: upgradeTimestamp zero");
        _eqUint(upgrade.newProtocolVersion, _refs.newProtocolVersion, "ProposedUpgrade: newProtocolVersion");
        _checkL2UpgradeTx(upgrade.l2ProtocolUpgradeTx, _refs);
    }

    function _checkL2UpgradeTx(L2CanonicalTransaction memory _tx, References memory _refs) private pure {
        _eqUint(_tx.txType, SYSTEM_UPGRADE_L2_TX_TYPE, "L2 upgrade tx: type");
        _eqUint(_tx.from, uint256(uint160(L2_FORCE_DEPLOYER_ADDR)), "L2 upgrade tx: from the force deployer");
        _eqUint(_tx.to, uint256(uint160(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR)), "L2 upgrade tx: to the ContractDeployer");
        _eqUint(_tx.gasLimit, PRIORITY_TX_MAX_GAS_LIMIT, "L2 upgrade tx: gas limit");
        _eqUint(_tx.gasPerPubdataByteLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, "L2 upgrade tx: gas per pubdata byte");
        _check(
            _tx.maxFeePerGas == 0 && _tx.maxPriorityFeePerGas == 0 && _tx.paymaster == 0 && _tx.value == 0,
            "L2 upgrade tx: no fees, paymaster or value"
        );
        _eqUint(_tx.nonce, _refs.newProtocolVersion >> SEMVER_MINOR_OFFSET, "L2 upgrade tx: nonce = the new minor");
        _check(
            _tx.reserved[0] == 0 && _tx.reserved[1] == 0 && _tx.reserved[2] == 0 && _tx.reserved[3] == 0,
            "L2 upgrade tx: reserved fields zero"
        );
        _check(
            _tx.signature.length == 0 && _tx.paymasterInput.length == 0 && _tx.reservedDynamic.length == 0,
            "L2 upgrade tx: no signature, paymaster input or reserved dynamic"
        );
        _checkForceDeployments(forceDeployments(_tx.data), _refs.l2.forceDeployments);
        _checkFactoryDeps(_tx.factoryDeps, _refs);
    }

    function _checkForceDeployments(
        IL2ContractDeployer.ForceDeployment[] memory _got,
        IL2ContractDeployer.ForceDeployment[] memory _expected
    ) private pure {
        _eqUint(_got.length, _expected.length, "L2 upgrade tx: number of force deployments");
        for (uint256 i = 0; i < _got.length; ++i) {
            if (_got[i].newAddress != _expected[i].newAddress) {
                revert OutputMismatch(
                    _indexed("L2 upgrade tx: force deployment ", i, " address"),
                    _addressWord(_got[i].newAddress),
                    _addressWord(_expected[i].newAddress)
                );
            }
            if (_got[i].bytecodeHash != _expected[i].bytecodeHash) {
                revert OutputMismatch(
                    _indexed("L2 upgrade tx: force deployment ", i, " bytecode hash"),
                    _got[i].bytecodeHash,
                    _expected[i].bytecodeHash
                );
            }
            _check(
                !_got[i].callConstructor && _got[i].value == 0 && _got[i].input.length == 0,
                "L2 upgrade tx: force deployments run no constructor"
            );
        }
    }

    function _checkFactoryDeps(uint256[] memory _deps, References memory _refs) private pure {
        _check(
            _deps.length >= BASE_SYSTEM_FACTORY_DEPS && _deps.length <= MAX_NEW_FACTORY_DEPS,
            "L2 upgrade tx: 3 to MAX_NEW_FACTORY_DEPS factory deps"
        );
        _eqWord(bytes32(_deps[0]), _refs.genesis.bootloaderHash, "L2 upgrade tx: factory dep 0 = bootloader");
        _eqWord(bytes32(_deps[1]), _refs.genesis.defaultAccountHash, "L2 upgrade tx: factory dep 1 = default account");
        _eqWord(bytes32(_deps[2]), _refs.genesis.evmEmulatorHash, "L2 upgrade tx: factory dep 2 = EVM emulator");
        bytes32[] memory expected = _refs.l2.factoryDeps;
        for (uint256 i = 0; i < _deps.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (_deps[i] == _deps[j]) {
                    revert OutputMismatch("L2 upgrade tx: factory dep listed twice", bytes32(_deps[i]), bytes32(0));
                }
            }
            if (!_contains(expected, bytes32(_deps[i]))) {
                revert OutputMismatch("L2 upgrade tx: unexpected factory dep", bytes32(_deps[i]), bytes32(0));
            }
        }
        for (uint256 i = 0; i < expected.length; ++i) {
            bool found = false;
            for (uint256 j = 0; j < _deps.length && !found; ++j) {
                found = bytes32(_deps[j]) == expected[i];
            }
            if (!found) {
                revert OutputMismatch("L2 upgrade tx: expected factory dep missing", bytes32(0), expected[i]);
            }
        }
    }

    function _checkUpgradeCut(
        Diamond.DiamondCutData memory _cut,
        Addresses memory _a,
        bytes4[] memory _liveSelectors
    ) private pure {
        Diamond.FacetCut[] memory cuts = _cut.facetCuts;
        uint256 removes = _removeCount(cuts);
        for (uint256 i = 0; i < cuts.length; ++i) {
            if (i < removes) {
                _check(
                    cuts[i].facet == address(0) && !cuts[i].isFreezable,
                    "upgrade cut: Removes name no facet and aren't freezable"
                );
            } else {
                _check(cuts[i].action == Diamond.Action.Add, "upgrade cut: Removes, then only Adds");
            }
        }
        bytes4[] memory removed = _selectorsOf(cuts, 0, removes);
        _eqUint(removed.length, _liveSelectors.length, "upgrade cut: Removes as many selectors as the chain routes");
        for (uint256 i = 0; i < _liveSelectors.length; ++i) {
            if (_count(removed, _liveSelectors[i]) != 1) {
                revert OutputMismatch(
                    "upgrade cut: a selector the reference chain routes isn't removed exactly once",
                    bytes32(0),
                    bytes32(_liveSelectors[i])
                );
            }
        }
        _checkAdds(adds(_cut), _a);
        _eqAddress(_cut.initAddress, _a.defaultUpgrade, "upgrade cut: initAddress = default_upgrade_addr");
    }

    function _checkAdds(Diamond.FacetCut[] memory _adds, Addresses memory _a) private pure {
        address[] memory facets = new address[](FACETS);
        bool[] memory freezable = new bool[](FACETS);
        (facets[0], freezable[0]) = (_a.adminFacet, false);
        (facets[1], freezable[1]) = (_a.gettersFacet, false);
        (facets[2], freezable[2]) = (_a.mailboxFacet, true);
        (facets[3], freezable[3]) = (_a.executorFacet, true);
        (facets[4], freezable[4]) = (_a.migratorFacet, false);
        (facets[5], freezable[5]) = (_a.committerFacet, true);
        _eqUint(_adds.length, facets.length, "upgrade cut: Adds the six facets");
        for (uint256 k = 0; k < facets.length; ++k) {
            uint256 found = 0;
            for (uint256 i = 0; i < _adds.length; ++i) {
                if (_adds[i].facet == facets[k]) {
                    ++found;
                    _eqBool(
                        _adds[i].isFreezable,
                        freezable[k],
                        "upgrade cut: only Mailbox, Executor and Committer freezable"
                    );
                }
            }
            if (found != 1) {
                revert OutputMismatch("upgrade cut: a new facet isn't added once", bytes32(0), _addressWord(facets[k]));
            }
        }
        bytes4[] memory added = _selectorsOf(_adds, 0, _adds.length);
        for (uint256 i = 0; i < added.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                _check(added[i] != added[j], "upgrade cut: no selector added twice");
            }
        }
        // v34's new selectors, on their facets.
        bytes4[] memory admin = _selectorsAddedBy(_adds, _a.adminFacet);
        bytes4[] memory getters = _selectorsAddedBy(_adds, _a.gettersFacet);
        _check(
            _count(admin, IAdmin.setProofSystemStatus.selector) == 1,
            "upgrade cut: AdminFacet adds setProofSystemStatus"
        );
        _check(
            _count(getters, IGetters.disabledProofSystems.selector) == 1,
            "upgrade cut: GettersFacet adds disabledProofSystems"
        );
        _check(
            _count(getters, IGetters.getUserPriorityTxMaxGasLimit.selector) == 1,
            "upgrade cut: GettersFacet adds getUserPriorityTxMaxGasLimit"
        );
    }

    /// @dev The selectors of `_facet`'s one Add.
    function _selectorsAddedBy(Diamond.FacetCut[] memory _adds, address _facet) private pure returns (bytes4[] memory) {
        for (uint256 i = 0; i < _adds.length; ++i) {
            if (_adds[i].facet == _facet) {
                return _adds[i].selectors;
            }
        }
        return new bytes4[](0);
    }

    function _checkCreationParams(
        Output memory _out,
        Diamond.DiamondCutData memory _cut,
        References memory _refs
    ) private pure {
        ChainCreationParams memory params = creationParams(_out.stage1, _refs.l1.ctm);
        Genesis memory genesis = _refs.genesis;
        _eqAddress(params.genesisUpgrade, _refs.l1.genesisUpgrade, "creation params: genesis upgrade");
        _eqWord(params.genesisBatchHash, genesis.root, "creation params: genesis batch hash");
        _eqUint(params.genesisIndexRepeatedStorageChanges, genesis.leafIndex, "creation params: genesis leaf index");
        _eqWord(params.genesisBatchCommitment, genesis.batchCommitment, "creation params: genesis batch commitment");
        _eqWord(
            params.genesisAirbenderBatchCommitment,
            genesis.airbenderBatchCommitment,
            "creation params: genesis Airbender batch commitment"
        );
        _eqAddress(params.diamondCut.initAddress, _out.addresses.diamondInit, "creation params: cut initAddress");
        InitializeDataNewChain memory init = InitializeDataNewChain({
            l2BootloaderBytecodeHash: genesis.bootloaderHash,
            l2DefaultAccountBytecodeHash: genesis.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: genesis.evmEmulatorHash
        });
        _eqBytes(params.diamondCut.initCalldata, abi.encode(init), "creation params: cut initCalldata");
        _eqBytes(
            abi.encode(params.diamondCut.facetCuts),
            abi.encode(adds(_cut)),
            "creation params: cut facets = the upgrade cut's Adds"
        );
        _checkForceDeploymentsData(params.forceDeploymentsData, _refs);
        _eqBytes(_out.diamondCutData, abi.encode(params.diamondCut), "contracts_config.diamond_cut_data");
        _eqBytes(_out.forceDeploymentsData, params.forceDeploymentsData, "contracts_config.force_deployments_data");
    }

    function _checkForceDeploymentsData(bytes memory _data, References memory _refs) private pure {
        FixedForceDeploymentsData memory data = abi.decode(_data, (FixedForceDeploymentsData));
        L1Facts memory l1 = _refs.l1;
        _eqUint(data.l1ChainId, l1.l1ChainId, "force deployments data: l1ChainId");
        _eqUint(data.eraChainId, l1.eraChainId, "force deployments data: eraChainId");
        _eqAddress(data.l1AssetRouter, l1.l1AssetRouter, "force deployments data: l1AssetRouter");
        _eqWord(data.l2TokenProxyBytecodeHash, _refs.l2.beaconProxy, "force deployments data: BeaconProxy hash");
        _eqAddress(
            data.aliasedL1Governance,
            AddressAliasHelper.applyL1ToL2Alias(l1.ctmOwner),
            "force deployments data: aliasedL1Governance = alias(the CTM's owner)"
        );
        _eqUint(data.maxNumberOfZKChains, l1.maxNumberOfZKChains, "force deployments data: maxNumberOfZKChains");
        bytes[] memory infos = bytecodeInfos(data);
        _eqUint(_refs.l2.bytecodeInfos.length, infos.length, "force deployments data: number of bytecode infos");
        for (uint256 i = 0; i < infos.length; ++i) {
            _eqBytes(
                infos[i],
                abi.encode(_refs.l2.bytecodeInfos[i]),
                _indexed("force deployments data: bytecode info ", i, "")
            );
        }
        _eqAddress(data.l2SharedBridgeLegacyImpl, address(0), "force deployments data: l2SharedBridgeLegacyImpl");
        _eqAddress(data.l2BridgedStandardERC20Impl, address(0), "force deployments data: l2BridgedStandardERC20Impl");
        _eqAddress(
            data.aliasedChainRegistrationSender,
            AddressAliasHelper.applyL1ToL2Alias(l1.chainRegistrationSender),
            "force deployments data: aliasedChainRegistrationSender"
        );
        _eqAddress(data.dangerousTestOnlyForcedBeacon, address(0), "force deployments data: no forced beacon");
        _eqWord(data.zkTokenAssetId, l1.zkTokenAssetId, "force deployments data: zkTokenAssetId");
    }

    /// @dev Each stage holds exactly its calls, with no value; their order matters only where the invariants below
    /// say so (they hold for any order that executes).
    function _checkStages(Output memory _out, References memory _refs) private pure {
        _checkSetNewVersionUpgrade(_out, _refs);
        StageCall[] memory stage0 = _stage0(_out.addresses, _refs.l1);
        StageCall[] memory stage1 = _stage1(_out, _refs);
        StageCall[] memory stage2 = _stage2(_out.addresses, _refs.l1);
        _checkStage(_out.stage0, stage0, "stage 0");
        _checkStage(_out.stage1, stage1, "stage 1");
        _checkStage(_out.stage2, stage2, "stage 2");
        // Stage 1's indices as `_stage1` lists them.
        _checkOrder(_out.stage1, stage1[1], stage1[2], "stage 1: pauseMigration before checkMigrationsPaused");
        _checkOrder(_out.stage1, stage1[2], stage1[3], "stage 1: checkMigrationsPaused before the CTM's upgrade");
        _checkOrder(_out.stage1, stage1[3], stage1[4], "stage 1: the CTM's upgrade before setNewVersionUpgrade");
        // setChainCreationParams records its block under the CTM's current version, so it must follow.
        _checkOrder(_out.stage1, stage1[4], stage1[5], "stage 1: setNewVersionUpgrade before setChainCreationParams");
        _checkOrder(_out.stage1, stage1[0], stage1[3], "stage 1: checkDeadline before the CTM's upgrade");
        _checkOrder(_out.stage2, stage2[0], stage2[2], "stage 2: unpauseMigration before checkMigrationsUnpaused");
    }

    function _stage0(Addresses memory _a, L1Facts memory _l1) private pure returns (StageCall[] memory calls) {
        calls = new StageCall[](2);
        calls[0] = StageCall(
            "pauseMigration",
            _l1.chainAssetHandler,
            abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
        );
        calls[1] = StageCall("startTimer", _a.timer, abi.encodeCall(GovernanceUpgradeTimer.startTimer, ()));
    }

    function _stage1(Output memory _out, References memory _refs) private pure returns (StageCall[] memory calls) {
        Addresses memory a = _out.addresses;
        L1Facts memory l1 = _refs.l1;
        calls = new StageCall[](6);
        calls[0] = StageCall("checkDeadline", a.timer, abi.encodeCall(GovernanceUpgradeTimer.checkDeadline, ()));
        calls[1] = StageCall(
            "pauseMigration",
            l1.chainAssetHandler,
            abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
        );
        calls[2] = StageCall(
            "checkMigrationsPaused",
            a.stageValidator,
            abi.encodeCall(UpgradeStageValidator.checkMigrationsPaused, ())
        );
        calls[3] = StageCall(
            "ProxyAdmin.upgrade(CTM, chain_type_manager_implementation_addr)",
            l1.ctmProxyAdmin,
            abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(l1.ctm), a.ctmImplementation))
        );
        calls[4] = StageCall(
            "setNewVersionUpgrade",
            l1.ctm,
            abi.encodeCall(
                IChainTypeManager.setNewVersionUpgrade,
                (
                    abi.decode(_out.chainUpgradeDiamondCut, (Diamond.DiamondCutData)),
                    _refs.oldProtocolVersion,
                    type(uint256).max,
                    _refs.newProtocolVersion,
                    a.verifier
                )
            )
        );
        // The output's own params re-encoded: this pins the calldata; `_checkCreationParams` checks the content.
        calls[5] = StageCall(
            "setChainCreationParams",
            l1.ctm,
            abi.encodeCall(IChainTypeManager.setChainCreationParams, (creationParams(_out.stage1, l1.ctm)))
        );
    }

    function _stage2(Addresses memory _a, L1Facts memory _l1) private pure returns (StageCall[] memory calls) {
        calls = new StageCall[](3);
        calls[0] = StageCall(
            "unpauseMigration",
            _l1.chainAssetHandler,
            abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        );
        calls[1] = StageCall(
            "checkProtocolUpgradePresence",
            _a.stageValidator,
            abi.encodeCall(UpgradeStageValidator.checkProtocolUpgradePresence, ())
        );
        calls[2] = StageCall(
            "checkMigrationsUnpaused",
            _a.stageValidator,
            abi.encodeCall(UpgradeStageValidator.checkMigrationsUnpaused, ())
        );
    }

    /// @dev The arguments one by one, before `_checkStage` compares the whole calldata.
    function _checkSetNewVersionUpgrade(Output memory _out, References memory _refs) private pure {
        uint256 at = _indexOf(
            _out.stage1,
            _refs.l1.ctm,
            IChainTypeManager.setNewVersionUpgrade.selector,
            "stage 1: setNewVersionUpgrade exactly once"
        );
        (
            Diamond.DiamondCutData memory cut,
            uint256 oldVersion,
            uint256 oldVersionDeadline,
            uint256 newVersion,
            address verifier
        ) = abi.decode(
                Bytes.slice(_out.stage1[at].data, 4),
                (Diamond.DiamondCutData, uint256, uint256, uint256, address)
            );
        _eqBytes(abi.encode(cut), _out.chainUpgradeDiamondCut, "setNewVersionUpgrade: cut = chain_upgrade_diamond_cut");
        _eqUint(oldVersion, _refs.oldProtocolVersion, "setNewVersionUpgrade: old version");
        _eqUint(oldVersionDeadline, type(uint256).max, "setNewVersionUpgrade: the old version never expires");
        _eqUint(newVersion, _refs.newProtocolVersion, "setNewVersionUpgrade: new version");
        _eqAddress(verifier, _out.addresses.verifier, "setNewVersionUpgrade: verifier = verifier_addr");
    }

    function _checkStage(Call[] memory _calls, StageCall[] memory _expected, string memory _stage) private pure {
        _eqUint(_calls.length, _expected.length, string.concat(_stage, ": number of calls"));
        for (uint256 i = 0; i < _calls.length; ++i) {
            _eqUint(_calls[i].value, 0, string.concat(_stage, ": no value"));
        }
        for (uint256 i = 0; i < _expected.length; ++i) {
            uint256 at = _indexOf(
                _calls,
                _expected[i].target,
                bytes4(_expected[i].data),
                string.concat(_stage, ": ", _expected[i].name, " exactly once")
            );
            _eqBytes(_calls[at].data, _expected[i].data, string.concat(_stage, ": ", _expected[i].name, " calldata"));
        }
    }

    function _checkOrder(
        Call[] memory _calls,
        StageCall memory _first,
        StageCall memory _then,
        string memory _what
    ) private pure {
        _check(
            _indexOf(_calls, _first.target, bytes4(_first.data), _what) <
                _indexOf(_calls, _then.target, bytes4(_then.data), _what),
            _what
        );
    }

    function _checkCtmAdminCalls(Output memory _out, References memory _refs) private pure {
        L1Facts memory l1 = _refs.l1;
        _eqAddress(_out.ctmAdmin, l1.ecosystemAdmin, "ctm_admin_calls.chain_admin = the bridgehub's admin");
        _eqAddress(_out.ctmAdminOwner, l1.ecosystemAdminOwner, "ctm_admin_calls.chain_admin_owner");
        _eqUint(_out.serverNotifierUpgrade.length, 1, "server_notifier_upgrade: one call");
        Call memory upgrade = _out.serverNotifierUpgrade[0];
        _eqAddress(upgrade.target, l1.serverNotifierProxyAdmin, "server_notifier_upgrade: to its ProxyAdmin");
        _eqUint(upgrade.value, 0, "server_notifier_upgrade: no value");
        _eqBytes(
            upgrade.data,
            abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(l1.serverNotifier), _out.addresses.serverNotifierImplementation)
            ),
            "server_notifier_upgrade: upgrade(ServerNotifier, server_notifier_implementation_addr)"
        );
    }

    function _checkTestCalls(
        Output memory _out,
        Diamond.DiamondCutData memory _cut,
        References memory _refs
    ) private pure {
        L1Facts memory l1 = _refs.l1;
        _eqUint(_out.testUpgradeChain.length, 1, "test_upgrade_chain: one call");
        Call memory upgrade = _out.testUpgradeChain[0];
        _eqAddress(upgrade.target, l1.referenceChain, "test_upgrade_chain: to the reference chain");
        _eqUint(upgrade.value, 0, "test_upgrade_chain: no value");
        _eqBytes(
            upgrade.data,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (l1.referenceChain, _refs.oldProtocolVersion, _cut)),
            "test_upgrade_chain: upgradeChainFromVersion(the chain, the old version, chain_upgrade_diamond_cut)"
        );
        _eqAddress(_out.testUpgradeChainCaller, l1.referenceChainAdmin, "test_upgrade_chain_caller");
        _eqUint(_out.testCreateChain.length, 1, "test_create_chain: one call");
        Call memory create = _out.testCreateChain[0];
        _eqAddress(create.target, l1.bridgehub, "test_create_chain: to the bridgehub");
        _eqUint(create.value, 0, "test_create_chain: no value");
        _eqWord(bytes4(create.data), IL1Bridgehub.createNewChain.selector, "test_create_chain: createNewChain");
        // Its first two arguments: the chain id and the CTM.
        (uint256 chainId, address ctm) = abi.decode(Bytes.slice(create.data, 4), (uint256, address));
        _eqUint(chainId, l1.testChainId, "test_create_chain: the test chain's id");
        _eqAddress(ctm, l1.ctm, "test_create_chain: on the CTM");
        _eqAddress(_out.testCreateChainCaller, l1.ecosystemAdmin, "test_create_chain_caller = the bridgehub's admin");
    }

    /// @dev The salt, then each contract exactly once at its output address with its constructor arguments, which
    /// are all static: word i is argument i.
    function _checkDeployments(
        Addresses memory _a,
        bytes32 _salt,
        Deployment[] memory _deployments,
        References memory _refs
    ) private pure {
        _eqWord(_salt, _refs.salt, "deployments: CREATE2 salt = the env's create2_factory_salt");
        ExpectedDeployment[] memory expected = _expectedDeployments(_a, _refs);
        _eqUint(_deployments.length, expected.length, "deployments: number of contracts");
        for (uint256 i = 0; i < expected.length; ++i) {
            _checkDeployment(_deployments, expected[i]);
        }
    }

    function _checkDeployment(Deployment[] memory _deployments, ExpectedDeployment memory _expected) private pure {
        string memory name = _expected.contractName;
        uint256 found = 0;
        uint256 at = 0;
        for (uint256 i = 0; i < _deployments.length; ++i) {
            if (keccak256(bytes(_deployments[i].contractName)) == keccak256(bytes(name))) {
                ++found;
                at = i;
            }
        }
        _check(found == 1, string.concat("deployments: ", name, " exactly once"));
        Deployment memory deployment = _deployments[at];
        _eqAddress(deployment.deployed, _expected.deployed, string.concat(name, ": the output's address"));
        for (uint256 i = 0; i < _expected.argNames.length; ++i) {
            _eqWord(
                _wordAt(deployment.args, i),
                _wordAt(_expected.args, i),
                string.concat(name, ": ", _expected.argNames[i])
            );
        }
        _eqUint(deployment.args.length, _expected.args.length, string.concat(name, ": constructor args length"));
    }

    function _expectedDeployments(
        Addresses memory _a,
        References memory _refs
    ) private pure returns (ExpectedDeployment[] memory e) {
        L1Facts memory l1 = _refs.l1;
        string memory verifierName = _refs.isTestnet
            ? string("l1-contracts/EraMultiProofTestnetVerifier")
            : string("l1-contracts/EraMultiProofVerifier");
        e = new ExpectedDeployment[](16);
        e[0] = ExpectedDeployment(
            "l1-contracts/AdminFacet",
            _a.adminFacet,
            abi.encode(l1.l1ChainId, l1.rollupDAManager),
            _names("L1 chain id", "RollupDAManager")
        );
        e[1] = ExpectedDeployment("l1-contracts/GettersFacet", _a.gettersFacet, "", _names());
        e[2] = ExpectedDeployment(
            "l1-contracts/MailboxFacet",
            _a.mailboxFacet,
            abi.encode(l1.eraChainId, l1.l1ChainId, l1.chainAssetHandler, _a.eip7702Checker, _refs.isTestnet),
            _names("era chain id", "L1 chain id", "ChainAssetHandler", "EIP-7702 checker", "testnet")
        );
        e[3] = ExpectedDeployment(
            "l1-contracts/ExecutorFacet",
            _a.executorFacet,
            abi.encode(l1.l1ChainId),
            _names("L1 chain id")
        );
        e[4] = ExpectedDeployment(
            "l1-contracts/MigratorFacet",
            _a.migratorFacet,
            abi.encode(l1.l1ChainId, _refs.isTestnet),
            _names("L1 chain id", "testnet")
        );
        e[5] = ExpectedDeployment(
            "l1-contracts/CommitterFacet",
            _a.committerFacet,
            abi.encode(l1.l1ChainId),
            _names("L1 chain id")
        );
        e[6] = ExpectedDeployment("l1-contracts/DiamondInit", _a.diamondInit, abi.encode(false), _names("ZKsync OS"));
        e[7] = ExpectedDeployment("da-contracts/EIP7702Checker", _a.eip7702Checker, "", _names());
        e[8] = ExpectedDeployment("l1-contracts/EraVerifierFflonk", _a.verifierFflonk, "", _names());
        e[9] = ExpectedDeployment("l1-contracts/AirbenderVerifierPlonk", _a.airbenderVerifier, "", _names());
        e[10] = ExpectedDeployment(
            verifierName,
            _a.verifier,
            abi.encode(_a.verifierFflonk, _a.airbenderVerifier),
            _names("Boojum verifier", "Airbender verifier")
        );
        e[11] = ExpectedDeployment("l1-contracts/EraSettlementLayerV34Upgrade", _a.defaultUpgrade, "", _names());
        e[12] = ExpectedDeployment(
            "l1-contracts/EraChainTypeManager",
            _a.ctmImplementation,
            abi.encode(l1.bridgehub, l1.interopCenter, l1.bytecodesSupplier, l1.permissionlessValidator),
            _names("bridgehub", "InteropCenter", "BytecodesSupplier", "PermissionlessValidator")
        );
        e[13] = ExpectedDeployment("l1-contracts/ServerNotifier", _a.serverNotifierImplementation, "", _names());
        e[14] = ExpectedDeployment(
            "l1-contracts/GovernanceUpgradeTimer",
            _a.timer,
            abi.encode(_refs.timerDelay, TIMER_MAX_ADDITIONAL_DELAY, l1.ctmOwner, l1.ctmOwner),
            _names("initial delay", "max additional delay", "timer governance = the CTM's owner", "owner")
        );
        e[15] = ExpectedDeployment(
            "l1-contracts/UpgradeStageValidator",
            _a.stageValidator,
            abi.encode(l1.ctm, _refs.newProtocolVersion),
            _names("CTM", "new protocol version")
        );
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────────

    function _readCalls(string memory _toml, string memory _key) private pure returns (Call[] memory) {
        return abi.decode(vm.parseTomlBytes(_toml, _key), (Call[]));
    }

    function _readAddresses(string memory _toml) private pure returns (Addresses memory a) {
        a.adminFacet = _stateTransition(_toml, "admin_facet_addr");
        a.gettersFacet = _stateTransition(_toml, "getters_facet_addr");
        a.mailboxFacet = _stateTransition(_toml, "mailbox_facet_addr");
        a.executorFacet = _stateTransition(_toml, "executor_facet_addr");
        a.migratorFacet = _stateTransition(_toml, "migrator_facet_addr");
        a.committerFacet = _stateTransition(_toml, "committer_facet_addr");
        a.diamondInit = _stateTransition(_toml, "diamond_init_addr");
        a.eip7702Checker = _stateTransition(_toml, "eip7702_checker_addr");
        a.verifier = _stateTransition(_toml, "verifier_addr");
        a.verifierFflonk = _stateTransition(_toml, "verifier_fflonk_addr");
        a.airbenderVerifier = _stateTransition(_toml, "airbender_verifier_addr");
        a.defaultUpgrade = _stateTransition(_toml, "default_upgrade_addr");
        a.ctmImplementation = _stateTransition(_toml, "chain_type_manager_implementation_addr");
        a.serverNotifierImplementation = _stateTransition(_toml, "server_notifier_implementation_addr");
        a.timer = vm.parseTomlAddress(_toml, "$.deployed_addresses.l1_governance_upgrade_timer");
        a.stageValidator = vm.parseTomlAddress(_toml, "$.deployed_addresses.upgrade_stage_validator");
        a.ctm = _stateTransition(_toml, "chain_type_manager_proxy");
        a.genesisUpgrade = _stateTransition(_toml, "genesis_upgrade_addr");
        a.bytecodesSupplier = _stateTransition(_toml, "bytecodes_supplier_addr");
        a.permissionlessValidator = _stateTransition(_toml, "permissionless_validator_addr");
        a.ctmProxyAdmin = vm.parseTomlAddress(_toml, "$.deployed_addresses.transparent_proxy_admin");
        a.rollupDAManager = vm.parseTomlAddress(_toml, "$.deployed_addresses.l1_rollup_da_manager");
    }

    function _stateTransition(string memory _toml, string memory _key) private pure returns (address) {
        return vm.parseTomlAddress(_toml, string.concat("$.state_transition.", _key));
    }

    function _deploymentKey(uint256 _index, string memory _field) private pure returns (string memory) {
        return string.concat("$.deployments[", vm.toString(_index), "]", _field);
    }

    /// @dev The number of leading Removes.
    function _removeCount(Diamond.FacetCut[] memory _cuts) private pure returns (uint256 removes) {
        while (removes < _cuts.length && _cuts[removes].action == Diamond.Action.Remove) {
            ++removes;
        }
    }

    function _selectorsOf(
        Diamond.FacetCut[] memory _cuts,
        uint256 _from,
        uint256 _to
    ) private pure returns (bytes4[] memory selectors) {
        uint256 total = 0;
        for (uint256 i = _from; i < _to; ++i) {
            total += _cuts[i].selectors.length;
        }
        selectors = new bytes4[](total);
        uint256 next = 0;
        for (uint256 i = _from; i < _to; ++i) {
            for (uint256 j = 0; j < _cuts[i].selectors.length; ++j) {
                selectors[next++] = _cuts[i].selectors[j];
            }
        }
    }

    /// @dev The index of the one call to `_target` with `_selector`; fails `_what` unless there is exactly one.
    function _indexOf(
        Call[] memory _calls,
        address _target,
        bytes4 _selector,
        string memory _what
    ) private pure returns (uint256 at) {
        uint256 found = 0;
        for (uint256 i = 0; i < _calls.length; ++i) {
            if (_calls[i].target == _target && bytes4(_calls[i].data) == _selector) {
                ++found;
                at = i;
            }
        }
        _check(found == 1, _what);
    }

    function _count(bytes4[] memory _list, bytes4 _item) private pure returns (uint256 n) {
        for (uint256 i = 0; i < _list.length; ++i) {
            if (_list[i] == _item) {
                ++n;
            }
        }
    }

    function _contains(bytes32[] memory _list, bytes32 _item) private pure returns (bool) {
        for (uint256 i = 0; i < _list.length; ++i) {
            if (_list[i] == _item) {
                return true;
            }
        }
        return false;
    }

    function _wordAt(bytes memory _data, uint256 _index) private pure returns (bytes32) {
        return bytes32(Bytes.slice(_data, _index * 32, _index * 32 + 32));
    }

    function _addressWord(address _value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(_value)));
    }

    function _indexed(
        string memory _prefix,
        uint256 _index,
        string memory _suffix
    ) private pure returns (string memory) {
        return string.concat(_prefix, vm.toString(_index), _suffix);
    }

    function _names() private pure returns (string[] memory) {
        return new string[](0);
    }

    function _names(string memory _a) private pure returns (string[] memory names) {
        names = new string[](1);
        names[0] = _a;
    }

    function _names(string memory _a, string memory _b) private pure returns (string[] memory names) {
        names = new string[](2);
        (names[0], names[1]) = (_a, _b);
    }

    function _names(
        string memory _a,
        string memory _b,
        string memory _c,
        string memory _d
    ) private pure returns (string[] memory names) {
        names = new string[](4);
        (names[0], names[1], names[2], names[3]) = (_a, _b, _c, _d);
    }

    function _names(
        string memory _a,
        string memory _b,
        string memory _c,
        string memory _d,
        string memory _e
    ) private pure returns (string[] memory names) {
        names = new string[](5);
        (names[0], names[1], names[2], names[3], names[4]) = (_a, _b, _c, _d, _e);
    }

    function _check(bool _ok, string memory _what) private pure {
        if (!_ok) {
            revert OutputCheckFailed(_what);
        }
    }

    function _eqWord(bytes32 _got, bytes32 _expected, string memory _what) private pure {
        if (_got != _expected) {
            revert OutputMismatch(_what, _got, _expected);
        }
    }

    function _eqUint(uint256 _got, uint256 _expected, string memory _what) private pure {
        _eqWord(bytes32(_got), bytes32(_expected), _what);
    }

    function _eqAddress(address _got, address _expected, string memory _what) private pure {
        _eqWord(_addressWord(_got), _addressWord(_expected), _what);
    }

    function _eqBool(bool _got, bool _expected, string memory _what) private pure {
        _eqUint(_got ? uint256(1) : uint256(0), _expected ? uint256(1) : uint256(0), _what);
    }

    function _eqBytes(bytes memory _got, bytes memory _expected, string memory _what) private pure {
        _eqWord(keccak256(_got), keccak256(_expected), _what);
    }
}
