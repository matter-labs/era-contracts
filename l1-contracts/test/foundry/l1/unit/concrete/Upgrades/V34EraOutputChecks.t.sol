// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {V34EraOutputChecks} from "foundry-test/fork/V34EraOutputChecks.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";

/// @title V34EraOutputChecksTest
/// @notice `V34EraOutputChecks` passes testnet3's committed output and fails each tampered copy with the check that
/// catches it.
/// @dev No fork and no build artifacts. The references come from a fixture (the facts `V34EraUpgrade.t.sol` reads
/// from Sepolia at the output's fork block and from `testnet3.toml`) and from the committed output itself: the
/// genesis values, the L2 bytecode hashes and the reference chain's selectors, which the fork test compares with the
/// genesis, the build and the chain. So nothing here changes with a later build. The deployments are synthetic, with
/// the fixture's constructor arguments: protocol-ops identifies the real ones on a fork.
contract V34EraOutputChecksTest is Test {
    string internal constant OUTPUT = "/upgrade-envs/v0.34.0-era/output/testnet3/ecosystem.toml";
    string internal constant FIXTURE = "/test/foundry/l1/unit/concrete/Upgrades/fixtures/v34-era-testnet3.toml";
    bytes32 internal constant TAMPERED = keccak256("V34EraOutputChecksTest: tampered");

    /// @dev External, so `vm.expectRevert` sees the library's revert as the call's.
    function runChecks(
        V34EraOutputChecks.Output memory _out,
        bytes32 _salt,
        V34EraOutputChecks.Deployment[] memory _deployments,
        V34EraOutputChecks.References memory _refs
    ) external pure {
        V34EraOutputChecks.check(_out, _salt, _deployments, _refs);
    }

    function test_committedOutputPasses() public view {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        this.runChecks(out, refs.salt, deployments, refs);
    }

    /// @dev protocol-ops' `deployments.json` format, contracts without constructor arguments included.
    function test_readsDeploymentsJson() public view {
        (, V34EraOutputChecks.References memory refs, V34EraOutputChecks.Deployment[] memory deployments) = _load();
        (bytes32 salt, V34EraOutputChecks.Deployment[] memory parsed) = V34EraOutputChecks.readDeployments(
            _deploymentsJson(refs.salt, deployments)
        );
        assertEq(salt, refs.salt, "salt");
        assertEq(parsed.length, deployments.length, "number of deployments");
        for (uint256 i = 0; i < parsed.length; ++i) {
            assertEq(parsed[i].contractName, deployments[i].contractName, "contract");
            assertEq(parsed[i].deployed, deployments[i].deployed, "address");
            assertEq(parsed[i].args, deployments[i].args, "args");
        }
    }

    function test_swappedStage1CallsFail() public {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        uint256 pause = _stage1Index(out, IChainAssetHandlerBase.pauseMigration.selector);
        uint256 check = _stage1Index(out, UpgradeStageValidator.checkMigrationsPaused.selector);
        (out.stage1[pause], out.stage1[check]) = (out.stage1[check], out.stage1[pause]);

        vm.expectRevert(
            abi.encodeWithSelector(
                V34EraOutputChecks.OutputCheckFailed.selector,
                "stage 1: pauseMigration before checkMigrationsPaused"
            )
        );
        this.runChecks(out, refs.salt, deployments, refs);
    }

    /// @dev The order that matters: with `setChainCreationParams` first, its block is recorded under the old version
    /// and new chains can't find their creation params.
    function test_setChainCreationParamsFirstFails() public {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        uint256 newVersion = _stage1Index(out, IChainTypeManager.setNewVersionUpgrade.selector);
        uint256 creation = _stage1Index(out, IChainTypeManager.setChainCreationParams.selector);
        (out.stage1[newVersion], out.stage1[creation]) = (out.stage1[creation], out.stage1[newVersion]);

        vm.expectRevert(
            abi.encodeWithSelector(
                V34EraOutputChecks.OutputCheckFailed.selector,
                "stage 1: setNewVersionUpgrade before setChainCreationParams"
            )
        );
        this.runChecks(out, refs.salt, deployments, refs);
    }

    function test_changedStageSelectorFails() public {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        uint256 check = _stage1Index(out, UpgradeStageValidator.checkMigrationsPaused.selector);
        out.stage1[check].data = abi.encodeCall(UpgradeStageValidator.checkMigrationsUnpaused, ());

        vm.expectRevert(
            abi.encodeWithSelector(
                V34EraOutputChecks.OutputCheckFailed.selector,
                "stage 1: checkMigrationsPaused exactly once"
            )
        );
        this.runChecks(out, refs.salt, deployments, refs);
    }

    function test_changedForceDeployedHashFails() public {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        Diamond.DiamondCutData memory cut = abi.decode(out.chainUpgradeDiamondCut, (Diamond.DiamondCutData));
        ProposedUpgrade memory upgrade = V34EraOutputChecks.proposedUpgrade(cut);
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = V34EraOutputChecks.forceDeployments(
            upgrade.l2ProtocolUpgradeTx.data
        );
        uint256 last = forceDeployments.length - 1;
        bytes32 original = forceDeployments[last].bytecodeHash;
        forceDeployments[last].bytecodeHash = TAMPERED;
        upgrade.l2ProtocolUpgradeTx.data = abi.encodeCall(
            IL2ContractDeployer.forceDeployOnAddresses,
            (forceDeployments)
        );
        out.chainUpgradeDiamondCut = _withUpgrade(cut, upgrade);

        vm.expectRevert(
            abi.encodeWithSelector(
                V34EraOutputChecks.OutputMismatch.selector,
                string.concat("L2 upgrade tx: force deployment ", vm.toString(last), " bytecode hash"),
                TAMPERED,
                original
            )
        );
        this.runChecks(out, refs.salt, deployments, refs);
    }

    function test_droppedFactoryDepFails() public {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        Diamond.DiamondCutData memory cut = abi.decode(out.chainUpgradeDiamondCut, (Diamond.DiamondCutData));
        ProposedUpgrade memory upgrade = V34EraOutputChecks.proposedUpgrade(cut);
        uint256[] memory deps = upgrade.l2ProtocolUpgradeTx.factoryDeps;
        uint256[] memory fewer = new uint256[](deps.length - 1);
        for (uint256 i = 0; i < fewer.length; ++i) {
            fewer[i] = deps[i];
        }
        upgrade.l2ProtocolUpgradeTx.factoryDeps = fewer;
        out.chainUpgradeDiamondCut = _withUpgrade(cut, upgrade);

        vm.expectRevert(
            abi.encodeWithSelector(
                V34EraOutputChecks.OutputMismatch.selector,
                "L2 upgrade tx: expected factory dep missing",
                bytes32(0),
                bytes32(deps[deps.length - 1])
            )
        );
        this.runChecks(out, refs.salt, deployments, refs);
    }

    function test_changedGenesisRootFails() public {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        ChainCreationParams memory params = V34EraOutputChecks.creationParams(out.stage1, refs.l1.ctm);
        bytes32 original = params.genesisBatchHash;
        params.genesisBatchHash = TAMPERED;
        uint256 at = _stage1Index(out, IChainTypeManager.setChainCreationParams.selector);
        out.stage1[at].data = abi.encodeCall(IChainTypeManager.setChainCreationParams, (params));

        vm.expectRevert(
            abi.encodeWithSelector(
                V34EraOutputChecks.OutputMismatch.selector,
                "creation params: genesis batch hash",
                TAMPERED,
                original
            )
        );
        this.runChecks(out, refs.salt, deployments, refs);
    }

    /// @dev The MailboxFacet built for another era chain id, as with `config.eraChainId = 271` in the script.
    function test_wrongConstructorArgFails() public {
        (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        ) = _load();
        V34EraOutputChecks.L1Facts memory l1 = refs.l1;
        uint256 wrongEraChainId = l1.eraChainId + 1;
        uint256 mailbox = _deploymentIndex(deployments, "l1-contracts/MailboxFacet");
        deployments[mailbox].args = abi.encode(
            wrongEraChainId,
            l1.l1ChainId,
            l1.chainAssetHandler,
            out.addresses.eip7702Checker,
            refs.isTestnet
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                V34EraOutputChecks.OutputMismatch.selector,
                "l1-contracts/MailboxFacet: era chain id",
                bytes32(wrongEraChainId),
                bytes32(l1.eraChainId)
            )
        );
        this.runChecks(out, refs.salt, deployments, refs);
    }

    function _load()
        internal
        view
        returns (
            V34EraOutputChecks.Output memory out,
            V34EraOutputChecks.References memory refs,
            V34EraOutputChecks.Deployment[] memory deployments
        )
    {
        out = V34EraOutputChecks.readOutput(vm.readFile(string.concat(vm.projectRoot(), OUTPUT)));
        refs = _references(out);
        deployments = _deployments(out.addresses, refs);
    }

    function _references(
        V34EraOutputChecks.Output memory _out
    ) internal view returns (V34EraOutputChecks.References memory refs) {
        string memory fixture = vm.readFile(string.concat(vm.projectRoot(), FIXTURE));
        refs.isTestnet = vm.parseTomlBool(fixture, "$.env.testnet_verifier");
        refs.timerDelay = vm.parseTomlUint(fixture, "$.env.governance_upgrade_timer_initial_delay");
        refs.salt = vm.parseTomlBytes32(fixture, "$.env.create2_factory_salt");
        refs.oldProtocolVersion = vm.parseTomlUint(fixture, "$.versions.old");
        refs.newProtocolVersion = vm.parseTomlUint(fixture, "$.versions.new");
        refs.l1 = _l1Facts(fixture);
        _referencesFromOutput(_out, refs);
    }

    function _l1Facts(string memory _fixture) internal pure returns (V34EraOutputChecks.L1Facts memory l1) {
        l1.l1ChainId = vm.parseTomlUint(_fixture, "$.l1.l1_chain_id");
        l1.eraChainId = vm.parseTomlUint(_fixture, "$.l1.era_chain_id");
        l1.maxNumberOfZKChains = vm.parseTomlUint(_fixture, "$.l1.max_number_of_zk_chains");
        l1.bridgehub = vm.parseTomlAddress(_fixture, "$.l1.bridgehub");
        l1.ctm = vm.parseTomlAddress(_fixture, "$.l1.ctm");
        l1.ctmOwner = vm.parseTomlAddress(_fixture, "$.l1.ctm_owner");
        l1.ctmProxyAdmin = vm.parseTomlAddress(_fixture, "$.l1.ctm_proxy_admin");
        l1.bytecodesSupplier = vm.parseTomlAddress(_fixture, "$.l1.bytecodes_supplier");
        l1.permissionlessValidator = vm.parseTomlAddress(_fixture, "$.l1.permissionless_validator");
        l1.interopCenter = vm.parseTomlAddress(_fixture, "$.l1.interop_center");
        l1.genesisUpgrade = vm.parseTomlAddress(_fixture, "$.l1.genesis_upgrade");
        l1.rollupDAManager = vm.parseTomlAddress(_fixture, "$.l1.rollup_da_manager");
        l1.chainAssetHandler = vm.parseTomlAddress(_fixture, "$.l1.chain_asset_handler");
        l1.l1AssetRouter = vm.parseTomlAddress(_fixture, "$.l1.l1_asset_router");
        l1.chainRegistrationSender = vm.parseTomlAddress(_fixture, "$.l1.chain_registration_sender");
        l1.serverNotifier = vm.parseTomlAddress(_fixture, "$.l1.server_notifier");
        l1.serverNotifierProxyAdmin = vm.parseTomlAddress(_fixture, "$.l1.server_notifier_proxy_admin");
        l1.ecosystemAdmin = vm.parseTomlAddress(_fixture, "$.l1.ecosystem_admin");
        l1.ecosystemAdminOwner = vm.parseTomlAddress(_fixture, "$.l1.ecosystem_admin_owner");
        l1.zkTokenAssetId = vm.parseTomlBytes32(_fixture, "$.l1.zk_token_asset_id");
        l1.referenceChain = vm.parseTomlAddress(_fixture, "$.l1.reference_chain");
        l1.referenceChainAdmin = vm.parseTomlAddress(_fixture, "$.l1.reference_chain_admin");
        l1.testChainId = vm.parseTomlUint(_fixture, "$.l1.test_chain_id");
    }

    /// @dev The genesis values, the L2 bytecode hashes and the reference chain's selectors, as the output has them.
    function _referencesFromOutput(
        V34EraOutputChecks.Output memory _out,
        V34EraOutputChecks.References memory _refs
    ) internal pure {
        Diamond.DiamondCutData memory cut = abi.decode(_out.chainUpgradeDiamondCut, (Diamond.DiamondCutData));
        ProposedUpgrade memory upgrade = V34EraOutputChecks.proposedUpgrade(cut);
        ChainCreationParams memory params = V34EraOutputChecks.creationParams(_out.stage1, _refs.l1.ctm);
        _refs.genesis = V34EraOutputChecks.Genesis({
            bootloaderHash: upgrade.bootloaderHash,
            defaultAccountHash: upgrade.defaultAccountHash,
            evmEmulatorHash: upgrade.evmEmulatorHash,
            root: params.genesisBatchHash,
            leafIndex: params.genesisIndexRepeatedStorageChanges,
            batchCommitment: params.genesisBatchCommitment,
            airbenderBatchCommitment: params.genesisAirbenderBatchCommitment
        });
        _refs.l2.forceDeployments = V34EraOutputChecks.forceDeployments(upgrade.l2ProtocolUpgradeTx.data);
        uint256[] memory deps = upgrade.l2ProtocolUpgradeTx.factoryDeps;
        _refs.l2.factoryDeps = new bytes32[](deps.length);
        for (uint256 i = 0; i < deps.length; ++i) {
            _refs.l2.factoryDeps[i] = bytes32(deps[i]);
        }
        FixedForceDeploymentsData memory data = abi.decode(params.forceDeploymentsData, (FixedForceDeploymentsData));
        _refs.l2.beaconProxy = data.l2TokenProxyBytecodeHash;
        bytes[] memory infos = V34EraOutputChecks.bytecodeInfos(data);
        _refs.l2.bytecodeInfos = new bytes32[](infos.length);
        for (uint256 i = 0; i < infos.length; ++i) {
            _refs.l2.bytecodeInfos[i] = bytes32(infos[i]);
        }
        _refs.l1.referenceChainSelectors = V34EraOutputChecks.removedSelectors(cut);
    }

    /// @dev The 16 deployments in the order the script makes them, at the output's addresses.
    function _deployments(
        V34EraOutputChecks.Addresses memory _a,
        V34EraOutputChecks.References memory _refs
    ) internal pure returns (V34EraOutputChecks.Deployment[] memory d) {
        V34EraOutputChecks.L1Facts memory l1 = _refs.l1;
        d = new V34EraOutputChecks.Deployment[](16);
        d[0] = _deployment(
            "l1-contracts/UpgradeStageValidator",
            _a.stageValidator,
            abi.encode(l1.ctm, _refs.newProtocolVersion)
        );
        d[1] = _deployment(
            "l1-contracts/GovernanceUpgradeTimer",
            _a.timer,
            abi.encode(_refs.timerDelay, V34EraOutputChecks.TIMER_MAX_ADDITIONAL_DELAY, l1.ctmOwner, l1.ctmOwner)
        );
        d[2] = _deployment("l1-contracts/EraSettlementLayerV34Upgrade", _a.defaultUpgrade, "");
        d[3] = _deployment("l1-contracts/EraVerifierFflonk", _a.verifierFflonk, "");
        d[4] = _deployment("l1-contracts/AirbenderVerifierPlonk", _a.airbenderVerifier, "");
        d[5] = _deployment(
            "l1-contracts/EraMultiProofTestnetVerifier",
            _a.verifier,
            abi.encode(_a.verifierFflonk, _a.airbenderVerifier)
        );
        d[6] = _deployment("da-contracts/EIP7702Checker", _a.eip7702Checker, "");
        d[7] = _deployment(
            "l1-contracts/EraChainTypeManager",
            _a.ctmImplementation,
            abi.encode(l1.bridgehub, l1.interopCenter, l1.bytecodesSupplier, l1.permissionlessValidator)
        );
        d[8] = _deployment("l1-contracts/ServerNotifier", _a.serverNotifierImplementation, "");
        d[9] = _deployment("l1-contracts/ExecutorFacet", _a.executorFacet, abi.encode(l1.l1ChainId));
        d[10] = _deployment("l1-contracts/AdminFacet", _a.adminFacet, abi.encode(l1.l1ChainId, l1.rollupDAManager));
        d[11] = _deployment(
            "l1-contracts/MailboxFacet",
            _a.mailboxFacet,
            abi.encode(l1.eraChainId, l1.l1ChainId, l1.chainAssetHandler, _a.eip7702Checker, _refs.isTestnet)
        );
        d[12] = _deployment("l1-contracts/GettersFacet", _a.gettersFacet, "");
        d[13] = _deployment("l1-contracts/MigratorFacet", _a.migratorFacet, abi.encode(l1.l1ChainId, _refs.isTestnet));
        d[14] = _deployment("l1-contracts/CommitterFacet", _a.committerFacet, abi.encode(l1.l1ChainId));
        d[15] = _deployment("l1-contracts/DiamondInit", _a.diamondInit, abi.encode(false));
    }

    function _deployment(
        string memory _contractName,
        address _deployed,
        bytes memory _args
    ) internal pure returns (V34EraOutputChecks.Deployment memory) {
        return V34EraOutputChecks.Deployment({contractName: _contractName, deployed: _deployed, args: _args});
    }

    /// @dev As protocol-ops writes it: checksummed addresses, `0x` hex args.
    function _deploymentsJson(
        bytes32 _salt,
        V34EraOutputChecks.Deployment[] memory _deployments
    ) internal pure returns (string memory) {
        string memory items = "";
        for (uint256 i = 0; i < _deployments.length; ++i) {
            items = string.concat(
                items,
                i == 0 ? string("") : string(","),
                '{"contract":"',
                _deployments[i].contractName,
                '","address":"',
                vm.toString(_deployments[i].deployed),
                '","args":"',
                vm.toString(_deployments[i].args),
                '"}'
            );
        }
        return string.concat('{"salt":"', vm.toString(_salt), '","deployments":[', items, "]}");
    }

    function _withUpgrade(
        Diamond.DiamondCutData memory _cut,
        ProposedUpgrade memory _upgrade
    ) internal pure returns (bytes memory) {
        _cut.initCalldata = abi.encodeCall(IDefaultUpgrade.upgrade, (_upgrade));
        return abi.encode(_cut);
    }

    function _stage1Index(V34EraOutputChecks.Output memory _out, bytes4 _selector) internal pure returns (uint256) {
        for (uint256 i = 0; i < _out.stage1.length; ++i) {
            if (bytes4(_out.stage1[i].data) == _selector) {
                return i;
            }
        }
        revert("no such stage 1 call");
    }

    function _deploymentIndex(
        V34EraOutputChecks.Deployment[] memory _deployments,
        string memory _contractName
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < _deployments.length; ++i) {
            if (keccak256(bytes(_deployments[i].contractName)) == keccak256(bytes(_contractName))) {
                return i;
            }
        }
        revert("no such deployment");
    }
}
