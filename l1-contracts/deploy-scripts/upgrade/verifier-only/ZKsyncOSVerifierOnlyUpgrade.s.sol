// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ZKsyncOSVerifierPlonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";

import {GetDiamondCutData} from "../../utils/GetDiamondCutData.sol";

/// @dev `Governance.minDelay()` is not part of {IGovernance}.
interface IGovernanceMinDelay {
    function minDelay() external view returns (uint256);
}

/// @notice Prepares a verifier-only upgrade of a ZKsync OS CTM ({protocol-docs/system/contracts/chain_management/upgrade_process.md}):
/// the CREATE2 deployments of the new verifier, the governance calls (stage 0 `pauseMigration`, stage 1
/// `createNewVerifierOnlyUpgrade`, stage 2 `unpauseMigration`), each chain's `upgradeChainFromVersion`
/// ChainAdmin calldata, and the transaction-simulator test calls.
/// @dev Never broadcasts. The deployments run on the local fork only, so the deployed VK can be checked
/// against `configs/genesis/zksync-os/latest.json`; the output carries them as calldata to the CREATE2
/// factory, which any sender can submit. Entry point: `prepare(inputPath, outputPath)`, both relative to
/// the l1-contracts root.
contract ZKsyncOSVerifierOnlyUpgrade is Script {
    using stdToml for string;

    /// @dev The previous version stays usable until every chain has moved; a verifier-only upgrade
    /// has nothing that forces chains over at a deadline (same as the v29.3 stage VK patch).
    uint256 internal constant OLD_PROTOCOL_VERSION_DEADLINE = type(uint256).max;

    /// @notice Parsed input, see `upgrade-envs/<release>/<env>.toml`.
    // solhint-disable-next-line gas-struct-packing
    struct Input {
        address bridgehub;
        address ctm;
        uint256 oldProtocolVersion;
        bool testnetVerifier;
        bool ownerIsGovernance;
        address create2Factory;
        bytes32 create2Salt;
        address deployer;
        uint256 testCreateChainId;
        uint256 testUpgradeChainId;
        uint256[] chainIds;
    }

    /// @notice Everything derived from the input and the live state.
    // solhint-disable-next-line gas-struct-packing
    struct Derived {
        uint256 newProtocolVersion;
        bytes32 expectedVkHash;
        bytes32 oldVkHash;
        address oldVerifier;
        address governance;
        address chainAssetHandler;
        address defaultUpgrade;
        address bridgehubAdmin;
        bytes32 plonkSalt;
        bytes32 verifierSalt;
        address verifierPlonk;
        address verifier;
    }

    Input internal input;
    Derived internal derived;
    /// @dev abi-encoded `Call[]` per deploy / stage; nested dynamic structs stay out of storage.
    bytes internal deployCalls;
    bytes[3] internal stageCalls;
    /// @dev abi-encoded `Diamond.DiamondCutData` the CTM will store for the old version.
    bytes internal upgradeCut;
    /// @dev `abi.encode(initialCut, forceDeploymentsData)`, the `_initData` of `createNewChain`.
    bytes internal creationInitData;

    function prepare(string memory _inputPath, string memory _outputPath) public {
        string memory root = vm.projectRoot();
        _loadInput(string.concat(root, _inputPath));
        _loadTargetVersion(string.concat(root, "/../configs/genesis/zksync-os/latest.json"));
        _checkLiveState();

        _deployVerifiers();
        _buildGovernanceCalls();
        upgradeCut = abi.encode(_expectedUpgradeCut());

        _saveOutput(string.concat(root, _outputPath));
    }

    // ======================== Input and live-state checks ========================

    function _loadInput(string memory _path) internal {
        string memory toml = vm.readFile(_path);
        input.bridgehub = toml.readAddress("$.bridgehub");
        input.ctm = toml.readAddress("$.ctm");
        input.oldProtocolVersion = toml.readUint("$.old_protocol_version");
        input.testnetVerifier = toml.readBool("$.testnet_verifier");
        input.ownerIsGovernance = toml.readBool("$.owner_is_governance");
        input.create2Factory = toml.readAddress("$.create2_factory_addr");
        input.create2Salt = toml.readBytes32("$.create2_factory_salt");
        input.deployer = toml.readAddress("$.deployer");
        input.testCreateChainId = toml.readUint("$.test_create_chain_id");
        input.testUpgradeChainId = toml.readUint("$.test_upgrade_chain_id");
        input.chainIds = toml.readUintArray("$.chain_ids");
    }

    /// @dev The new version and its VK come from the genesis config this branch's VK was released with.
    function _loadTargetVersion(string memory _path) internal {
        string memory json = vm.readFile(_path);
        derived.newProtocolVersion = SemVer.packSemVer(
            uint32(vm.parseJsonUint(json, ".protocol_semantic_version.major")),
            uint32(vm.parseJsonUint(json, ".protocol_semantic_version.minor")),
            uint32(vm.parseJsonUint(json, ".protocol_semantic_version.patch"))
        );
        derived.expectedVkHash = vm.parseJsonBytes32(json, ".prover.recursion_scheduler_level_vk_hash");
    }

    /// @dev Fail before emitting anything if the input does not describe the live ecosystem.
    function _checkLiveState() internal {
        IChainTypeManager ctm = IChainTypeManager(input.ctm);
        require(ctm.isZKsyncOS(), "vk-only: not a ZKsync OS CTM");
        require(ctm.BRIDGE_HUB() == input.bridgehub, "vk-only: CTM belongs to another bridgehub");
        require(ctm.protocolVersion() == input.oldProtocolVersion, "vk-only: CTM not on old_protocol_version");
        require(derived.newProtocolVersion > input.oldProtocolVersion, "vk-only: genesis version not newer");

        derived.defaultUpgrade = ctm.defaultUpgrade();
        require(derived.defaultUpgrade.code.length > 0, "vk-only: CTM has no default upgrade");

        derived.oldVerifier = ctm.protocolVersionVerifier(input.oldProtocolVersion);
        require(derived.oldVerifier != address(0), "vk-only: no verifier for old version");
        derived.oldVkHash = IVerifier(derived.oldVerifier).verificationKeyHash();
        require(derived.oldVkHash != derived.expectedVkHash, "vk-only: VK unchanged");
        if (input.testnetVerifier) {
            // Reverts on the production flavour, which has no such getter.
            require(
                ZKsyncOSTestnetVerifier(derived.oldVerifier).IS_TESTNET_VERIFIER(),
                "vk-only: old verifier flavour"
            );
        }

        derived.governance = IOwnable(input.ctm).owner();
        derived.chainAssetHandler = IL1Bridgehub(input.bridgehub).chainAssetHandler();
        require(
            IOwnable(derived.chainAssetHandler).owner() == derived.governance,
            "vk-only: CTM and ChainAssetHandler owners differ"
        );
        require(!IChainAssetHandlerBase(derived.chainAssetHandler).migrationPaused(), "vk-only: migrations paused");
        derived.bridgehubAdmin = IL1Bridgehub(input.bridgehub).admin();

        // The chain creation params are carried over by the CTM, but the test chain is created from them, so
        // they are read from the CTM's last `NewChainCreationParams` event and checked against its hashes.
        (bytes memory cut, bytes memory forceDeployments) = GetDiamondCutData._getDiamondCutAndForceDeployment(
            input.ctm
        );
        require(keccak256(cut) == ctm.initialCutHash(), "vk-only: creation cut does not match the CTM");
        require(
            keccak256(abi.encode(forceDeployments)) == ChainTypeManagerBase(input.ctm).initialForceDeploymentHash(),
            "vk-only: force deployments do not match the CTM"
        );
        creationInitData = abi.encode(cut, forceDeployments);

        for (uint256 i = 0; i < input.chainIds.length; ++i) {
            uint256 chainId = input.chainIds[i];
            require(
                IL1Bridgehub(input.bridgehub).chainTypeManager(chainId) == input.ctm,
                "vk-only: chain on other CTM"
            );
            address chain = IL1Bridgehub(input.bridgehub).getZKChain(chainId);
            require(
                IGetters(chain).getProtocolVersion() == input.oldProtocolVersion,
                "vk-only: chain not on old_protocol_version"
            );
        }
        require(
            IL1Bridgehub(input.bridgehub).getZKChain(input.testCreateChainId) == address(0),
            "vk-only: test_create_chain_id taken"
        );
    }

    // ======================== Verifier deployment ========================

    /// @dev Each contract gets its own salt so the factory calldata (whose first word is the salt) can be
    /// told apart by the simulator's description registry.
    function _deployVerifiers() internal {
        derived.plonkSalt = keccak256(abi.encode(input.create2Salt, "ZKsyncOSVerifierPlonk"));
        derived.verifierSalt = keccak256(abi.encode(input.create2Salt, "ZKsyncOSVerifier"));

        bytes memory plonkInitCode = type(ZKsyncOSVerifierPlonk).creationCode;
        derived.verifierPlonk = vm.computeCreate2Address(
            derived.plonkSalt,
            keccak256(plonkInitCode),
            input.create2Factory
        );
        bytes memory verifierInitCode = abi.encodePacked(
            input.testnetVerifier ? type(ZKsyncOSTestnetVerifier).creationCode : type(ZKsyncOSVerifier).creationCode,
            abi.encode(derived.verifierPlonk)
        );
        derived.verifier = vm.computeCreate2Address(
            derived.verifierSalt,
            keccak256(verifierInitCode),
            input.create2Factory
        );

        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: input.create2Factory,
            value: 0,
            data: abi.encodePacked(derived.plonkSalt, plonkInitCode)
        });
        calls[1] = Call({
            target: input.create2Factory,
            value: 0,
            data: abi.encodePacked(derived.verifierSalt, verifierInitCode)
        });
        deployCalls = abi.encode(calls);

        // Local only: there is no `vm.broadcast`, so nothing here reaches the network.
        _deployIfAbsent(calls[0], derived.verifierPlonk);
        _deployIfAbsent(calls[1], derived.verifier);

        require(
            IVerifier(derived.verifier).verificationKeyHash() == derived.expectedVkHash,
            "vk-only: deployed VK differs from the genesis config"
        );
        require(
            ZKsyncOSVerifier(derived.verifier).PLONK_VERIFIER() == IVerifier(derived.verifierPlonk),
            "vk-only: verifier wraps another plonk verifier"
        );
        if (input.testnetVerifier) {
            require(ZKsyncOSTestnetVerifier(derived.verifier).IS_TESTNET_VERIFIER(), "vk-only: new verifier flavour");
        }
        console.log("vk-only: verifier", derived.verifier);
        console.log("vk-only: verifier plonk", derived.verifierPlonk);
    }

    function _deployIfAbsent(Call memory _call, address _expected) internal {
        if (_expected.code.length > 0) {
            return;
        }
        (bool success, bytes memory returnData) = _call.target.call(_call.data);
        require(success && address(bytes20(returnData)) == _expected, "vk-only: CREATE2 deployment failed");
    }

    // ======================== Calls ========================

    function _buildGovernanceCalls() internal {
        Call[] memory stage0 = new Call[](1);
        stage0[0] = Call({
            target: derived.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
        });

        Call[] memory stage1 = new Call[](1);
        stage1[0] = Call({
            target: input.ctm,
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.createNewVerifierOnlyUpgrade,
                (input.oldProtocolVersion, OLD_PROTOCOL_VERSION_DEADLINE, derived.newProtocolVersion, derived.verifier)
            )
        });

        Call[] memory stage2 = new Call[](1);
        stage2[0] = Call({
            target: derived.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        });

        stageCalls[0] = abi.encode(stage0);
        stageCalls[1] = abi.encode(stage1);
        stageCalls[2] = abi.encode(stage2);
    }

    /// @dev Mirrors `ChainTypeManagerBase.createNewVerifierOnlyUpgrade`; the rehearsal checks the CTM
    /// stores exactly this cut's hash.
    function _expectedUpgradeCut() internal view returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: derived.defaultUpgrade,
                initCalldata: abi.encodeCall(IDefaultUpgrade.upgradeVerifierOnly, (derived.newProtocolVersion))
            });
    }

    function _upgradeChainCalls(address _chain) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: _chain,
            value: 0,
            data: abi.encodeCall(
                IAdmin.upgradeChainFromVersion,
                (_chain, input.oldProtocolVersion, abi.decode(upgradeCut, (Diamond.DiamondCutData)))
            )
        });
    }

    function _createChainCalls() internal view returns (Call[] memory calls) {
        bytes32 baseTokenAssetId = IL1Bridgehub(input.bridgehub).baseTokenAssetId(input.testUpgradeChainId);
        calls = new Call[](1);
        calls[0] = Call({
            target: input.bridgehub,
            value: 0,
            data: abi.encodeCall(
                IL1Bridgehub.createNewChain,
                (
                    input.testCreateChainId,
                    input.ctm,
                    baseTokenAssetId,
                    5,
                    derived.bridgehubAdmin,
                    creationInitData,
                    new bytes[](0)
                )
            )
        });
    }

    /// @dev `Governance.scheduleTransparent(op, minDelay)` then `execute(op)`, one operation per stage. The salt is
    /// derived from the stage so that no two operations of this upgrade, or of any other, share an id.
    function _governanceOperation(uint256 _stage) internal view returns (IGovernance.Operation memory) {
        return
            IGovernance.Operation({
                calls: abi.decode(stageCalls[_stage], (Call[])),
                predecessor: bytes32(0),
                salt: keccak256(abi.encode(input.create2Salt, "governance stage", _stage))
            });
    }

    // ======================== Output ========================

    function _saveOutput(string memory _path) internal {
        vm.writeToml(_serializeConfig(), _path);
        vm.writeToml(_serializeDeployCalls(), _path, ".deploy_calls");
        vm.writeToml(_serializeGovernanceCalls(), _path, ".governance_calls");
        if (input.ownerIsGovernance) {
            vm.writeToml(_serializeGovernanceOperations(), _path, ".governance_operations");
        }
        vm.writeToml(_serializeChainUpgrades(), _path, ".chain_upgrades");
        vm.writeToml(_serializeTestCalls(), _path, ".test_upgrade_calls");
        console.log("vk-only: output written to", _path);
    }

    function _serializeConfig() internal returns (string memory) {
        string memory o = "contracts_config";
        vm.serializeAddress(o, "bridgehub", input.bridgehub);
        vm.serializeAddress(o, "chain_type_manager", input.ctm);
        vm.serializeAddress(o, "chain_asset_handler", derived.chainAssetHandler);
        vm.serializeAddress(o, "governance", derived.governance);
        vm.serializeAddress(o, "default_upgrade", derived.defaultUpgrade);
        vm.serializeUint(o, "old_protocol_version", input.oldProtocolVersion);
        vm.serializeUint(o, "new_protocol_version", derived.newProtocolVersion);
        vm.serializeString(o, "old_protocol_version_deadline", vm.toString(OLD_PROTOCOL_VERSION_DEADLINE));
        vm.serializeAddress(o, "old_verifier", derived.oldVerifier);
        vm.serializeBytes32(o, "old_vk_hash", derived.oldVkHash);
        vm.serializeAddress(o, "verifier", derived.verifier);
        vm.serializeAddress(o, "verifier_plonk", derived.verifierPlonk);
        vm.serializeBytes32(o, "vk_hash", derived.expectedVkHash);
        vm.serializeBool(o, "testnet_verifier", input.testnetVerifier);
        vm.serializeAddress(o, "create2_factory_addr", input.create2Factory);
        vm.serializeBytes32(o, "create2_factory_salt", input.create2Salt);
        string memory config = vm.serializeBytes(o, "upgrade_cut_data", upgradeCut);
        return vm.serializeString("root", "contracts_config", config);
    }

    function _serializeDeployCalls() internal returns (string memory) {
        vm.serializeAddress("deploy_calls", "deployer", input.deployer);
        return vm.serializeBytes("deploy_calls", "calls", deployCalls);
    }

    function _serializeGovernanceCalls() internal returns (string memory) {
        vm.serializeBytes("governance_calls", "stage0_calls", stageCalls[0]);
        vm.serializeBytes("governance_calls", "stage1_calls", stageCalls[1]);
        return vm.serializeBytes("governance_calls", "stage2_calls", stageCalls[2]);
    }

    function _serializeGovernanceOperations() internal returns (string memory) {
        string memory o = "governance_operations";
        uint256 delay = IGovernanceMinDelay(derived.governance).minDelay();
        vm.serializeAddress(o, "governance_owner", IOwnable(derived.governance).owner());
        vm.serializeUint(o, "delay", delay);
        string memory out;
        for (uint256 stage = 0; stage < 3; ++stage) {
            IGovernance.Operation memory op = _governanceOperation(stage);
            string memory prefix = string.concat("stage", vm.toString(stage));
            vm.serializeBytes32(
                o,
                string.concat(prefix, "_operation_id"),
                IGovernance(derived.governance).hashOperation(op)
            );
            vm.serializeBytes(
                o,
                string.concat(prefix, "_schedule_calldata"),
                abi.encodeCall(IGovernance.scheduleTransparent, (op, delay))
            );
            out = vm.serializeBytes(
                o,
                string.concat(prefix, "_execute_calldata"),
                abi.encodeCall(IGovernance.execute, (op))
            );
        }
        return out;
    }

    function _serializeChainUpgrades() internal returns (string memory out) {
        for (uint256 i = 0; i < input.chainIds.length; ++i) {
            uint256 chainId = input.chainIds[i];
            string memory key = vm.toString(chainId);
            address chain = IL1Bridgehub(input.bridgehub).getZKChain(chainId);
            address chainAdmin = IGetters(chain).getAdmin();
            string memory o = string.concat("chain_upgrade_", key);
            vm.serializeAddress(o, "chain", chain);
            vm.serializeAddress(o, "chain_admin", chainAdmin);
            vm.serializeAddress(o, "chain_admin_owner", IOwnable(chainAdmin).owner());
            string memory entry = vm.serializeBytes(
                o,
                "chain_admin_calldata",
                abi.encodeCall(IChainAdmin.multicall, (_upgradeChainCalls(chain), true))
            );
            out = vm.serializeString("chain_upgrades", key, entry);
        }
    }

    function _serializeTestCalls() internal returns (string memory) {
        string memory o = "test_upgrade_calls";
        address testChain = IL1Bridgehub(input.bridgehub).getZKChain(input.testUpgradeChainId);
        vm.serializeAddress(o, "test_create_chain_zkos_caller", derived.bridgehubAdmin);
        vm.serializeBytes(o, "test_create_chain_zkos", abi.encode(_createChainCalls()));
        vm.serializeAddress(o, "test_upgrade_chain_zkos_caller", IGetters(testChain).getAdmin());
        return vm.serializeBytes(o, "test_upgrade_chain_zkos", abi.encode(_upgradeChainCalls(testChain)));
    }
}
