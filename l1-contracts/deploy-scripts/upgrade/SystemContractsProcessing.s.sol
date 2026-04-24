// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2 as console} from "forge-std/Script.sol";
import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {
    GW_ASSET_TRACKER_ADDR,
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_INTEROP_ROOT_STORAGE,
    L2_MESSAGE_ROOT_ADDR,
    L2_MESSAGE_VERIFICATION,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    CoreContract,
    EraVmSystemContract,
    Language,
    ZkSyncOsSystemContract,
    ZKsyncOSUpgradeType
} from "../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";
import {DeduplicateBytecodesCountMismatch} from "../ecosystem/DeployScriptErrors.sol";
import {EraForceDeploymentsLib} from "./default-upgrade/EraForceDeploymentsLib.sol";

// solhint-disable no-console

/// @notice Struct representing a system contract's details
struct SystemContract {
    address addr; // Contract address
    string codeName; // Name of the contract code
    Language lang; // Programming language used
    bool isPrecompile; // Whether precompile or not
}

/// @dev The number of built-in contracts that reside within the "system-contracts" folder
uint256 constant SYSTEM_CONTRACTS_COUNT = 30;
/// @dev The number of built-in contracts that reside within the `l1-contracts` folder
uint256 constant OTHER_BUILT_IN_CONTRACTS_COUNT = 13;
/// @dev Era factory dependencies based in `l1-contracts`: other built-ins plus runtime deployment preimages.
uint256 constant OTHER_FACTORY_DEPENDENCY_CONTRACTS_COUNT = 15;
/// @dev System contracts (0x800x) with l1-contracts EVM bytecodes for ZKsyncOS proxy upgrades.
uint256 constant ZKOS_EXTRA_SYSTEM_CONTRACTS_COUNT = 3;

/// @notice A built-in contract's identity plus its Era bytecode.
struct BuiltinContractDeployInfo {
    CoreContract id;
    address addr;
    bytes bytecode;
}

library SystemContractsProcessing {
    /// @notice Retrieves the entire list of system contracts as a memory array.
    /// @dev Note that it does not include all built-in contracts. Rather all those
    /// that are based in the `system-contracts` folder plus fixed-address system helpers.
    /// Note, that we do not populate the system contract for the genesis upgrade address,
    /// as it is used during the genesis upgrade or during upgrades (and so it should be populated
    /// as part of the upgrade script).
    /// @return An array of SystemContract structs containing all system contracts
    function getSystemContracts() public pure returns (SystemContract[] memory) {
        SystemContract[] memory systemContracts = new SystemContract[](SYSTEM_CONTRACTS_COUNT);
        for (uint256 i = 0; i < SYSTEM_CONTRACTS_COUNT; i++) {
            EraVmSystemContract id = EraVmSystemContract(i);
            systemContracts[i] = SystemContract({
                addr: CoreOnGatewayHelper._resolveAddress(id),
                codeName: CoreOnGatewayHelper._resolveContractName(id),
                lang: CoreOnGatewayHelper._resolveLanguage(id),
                isPrecompile: CoreOnGatewayHelper._resolveIsPrecompile(id)
            });
        }
        return systemContracts;
    }

    /// @notice Deduplicates the array of bytecodes.
    function deduplicateBytecodes(bytes[] memory input) internal pure returns (bytes[] memory output) {
        // A more efficient way would be to sort + deduplicate, but
        // there is no built-in sorting in Solidity + this function should be only
        // used in scripts, so ineffiency is fine.
        // We'll do it on O(N^2)

        // In O(N^2) we'll mark duplicated hashes as zeroes.
        bytes32[] memory hashes = new bytes32[](input.length);
        for (uint256 i = 0; i < input.length; i++) {
            hashes[i] = keccak256(input[i]);
        }

        uint256 toInclude = 0;

        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] != bytes32(0)) {
                toInclude += 1;
            }

            for (uint j = i + 1; j < hashes.length; j++) {
                if (hashes[i] == hashes[j]) {
                    hashes[j] = bytes32(0);
                }
            }
        }

        output = new bytes[](toInclude);
        uint256 included = 0;
        for (uint256 i = 0; i < input.length; i++) {
            if (hashes[i] != bytes32(0)) {
                output[included] = input[i];
                ++included;
            }
        }

        // Sanity check
        require(included == toInclude, DeduplicateBytecodesCountMismatch());
    }

    function getSystemContractsBytecodes() internal view returns (bytes[] memory result) {
        result = new bytes[](SYSTEM_CONTRACTS_COUNT);

        SystemContract[] memory systemContracts = getSystemContracts();
        for (uint256 i = 0; i < SYSTEM_CONTRACTS_COUNT; i++) {
            if (systemContracts[i].isPrecompile) {
                result[i] = BytecodeUtils.readPrecompileBytecode(systemContracts[i].codeName);
            } else {
                // L2BaseToken is now in l1-contracts as L2BaseTokenEra
                if (Utils.compareStrings(systemContracts[i].codeName, "L2BaseToken")) {
                    result[i] = BytecodeUtils.readBytecodeL1(false, "L2BaseTokenEra.sol", "L2BaseTokenEra");
                } else if (systemContracts[i].lang == Language.Solidity) {
                    result[i] = BytecodeUtils.readSystemContractsBytecode(systemContracts[i].codeName);
                } else {
                    result[i] = BytecodeUtils.readSystemContractsYulBytecode(systemContracts[i].codeName);
                }
            }
        }
    }

    function getSystemContractsForceDeployments()
        internal
        view
        returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments)
    {
        forceDeployments = new IL2ContractDeployer.ForceDeployment[](SYSTEM_CONTRACTS_COUNT);

        SystemContract[] memory systemContracts = getSystemContracts();
        bytes[] memory bytecodes = getSystemContractsBytecodes();
        for (uint256 i = 0; i < SYSTEM_CONTRACTS_COUNT; i++) {
            forceDeployments[i] = IL2ContractDeployer.ForceDeployment({
                bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes[i]),
                newAddress: systemContracts[i].addr,
                callConstructor: false,
                value: 0,
                input: ""
            });
        }
    }

    /// @notice The list of CoreContract entries that are "other built-in" contracts.
    function getOtherBuiltinCoreContracts() internal pure returns (CoreContract[] memory ids) {
        ids = new CoreContract[](OTHER_BUILT_IN_CONTRACTS_COUNT);
        _fillOtherBuiltinCoreContracts(ids);
    }

    function getOtherFactoryDependencyContracts() internal pure returns (CoreContract[] memory ids) {
        ids = new CoreContract[](OTHER_FACTORY_DEPENDENCY_CONTRACTS_COUNT);
        _fillOtherBuiltinCoreContracts(ids);
        ids[OTHER_BUILT_IN_CONTRACTS_COUNT] = CoreContract.TransparentUpgradeableProxy;
        ids[OTHER_BUILT_IN_CONTRACTS_COUNT + 1] = CoreContract.BeaconProxy;
    }

    function _fillOtherBuiltinCoreContracts(CoreContract[] memory ids) private pure {
        ids[0] = CoreContract.L2Bridgehub;
        ids[1] = CoreContract.L2AssetRouter;
        ids[2] = CoreContract.L2NativeTokenVault;
        ids[3] = CoreContract.L2MessageRoot;
        ids[4] = CoreContract.L2WrappedBaseToken;
        ids[5] = CoreContract.L2MessageVerification;
        ids[6] = CoreContract.L2ChainAssetHandler;
        ids[7] = CoreContract.L2InteropRootStorage;
        ids[8] = CoreContract.BaseTokenHolder;
        ids[9] = CoreContract.L2AssetTracker;
        ids[10] = CoreContract.InteropCenter;
        ids[11] = CoreContract.InteropHandler;
        ids[12] = CoreContract.GWAssetTracker;
    }

    /// @notice System contracts that have l1-contracts EVM bytecodes and need ZKsyncOS proxy upgrades.
    /// @dev Separate from getOtherBuiltinCoreContracts because Era handles these via getSystemContractsForceDeployments.
    ///      ContractDeployer (0x8006) is intentionally excluded: it's a sequencer hook dispatcher,
    ///      not a wrappable contract. Attempting to force-deploy a SystemContractProxy at 0x8006
    ///      and then calling forceInitAdmin on it hits the hook with an unknown selector and reverts.
    function getZKsyncOSExtraSystemContracts() internal pure returns (ZkSyncOsSystemContract[] memory ids) {
        ids = new ZkSyncOsSystemContract[](ZKOS_EXTRA_SYSTEM_CONTRACTS_COUNT);
        ids[0] = ZkSyncOsSystemContract.L2BaseToken;
        ids[1] = ZkSyncOsSystemContract.L1Messenger;
        ids[2] = ZkSyncOsSystemContract.SystemContext;
    }

    /// @notice Returns address+bytecode pairs for all "other built-in" contracts.
    /// @dev Loads Era (zkout) bytecodes.
    function getOtherBuiltinContracts() internal view returns (BuiltinContractDeployInfo[] memory contracts) {
        CoreContract[] memory ids = getOtherBuiltinCoreContracts();
        contracts = new BuiltinContractDeployInfo[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            string memory eraName = CoreOnGatewayHelper._resolveContractName(false, ids[i]);
            contracts[i] = BuiltinContractDeployInfo({
                id: ids[i],
                addr: CoreOnGatewayHelper._resolveAddress(ids[i]),
                bytecode: ContractsBytecodesLib.getCreationCodeEra(eraName)
            });
        }
    }

    function getOtherFactoryDependencyBytecodes() internal view returns (bytes[] memory bytecodes) {
        CoreContract[] memory contracts = getOtherFactoryDependencyContracts();
        bytecodes = new bytes[](contracts.length);
        for (uint256 i = 0; i < contracts.length; i++) {
            string memory eraName = CoreOnGatewayHelper._resolveContractName(false, contracts[i]);
            bytecodes[i] = ContractsBytecodesLib.getCreationCodeEra(eraName);
        }
    }

    /// @notice Build Era-style ForceDeployment[] from the built-in contracts list.
    function getOtherBuiltinForceDeployments(
        uint256 l1ChainId,
        address owner
    ) internal view returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments) {
        BuiltinContractDeployInfo[] memory contracts = getOtherBuiltinContracts();
        forceDeployments = new IL2ContractDeployer.ForceDeployment[](contracts.length);

        for (uint256 i = 0; i < contracts.length; i++) {
            forceDeployments[i] = IL2ContractDeployer.ForceDeployment({
                bytecodeHash: L2ContractHelper.hashL2Bytecode(contracts[i].bytecode),
                newAddress: contracts[i].addr,
                callConstructor: false,
                value: 0,
                input: ""
            });
        }

        // Special case: L2ChainAssetHandler needs an initializer call after force deployment.
        // Find it by address rather than hardcoding an array index.
        for (uint256 i = 0; i < contracts.length; i++) {
            if (contracts[i].addr == L2_CHAIN_ASSET_HANDLER_ADDR) {
                forceDeployments[i].callConstructor = true;
                // solhint-disable-next-line func-named-parameters
                forceDeployments[i].input = abi.encode(
                    l1ChainId,
                    AddressAliasHelper.applyL1ToL2Alias(owner),
                    L2_BRIDGEHUB_ADDR,
                    L2_ASSET_ROUTER_ADDR,
                    L2_MESSAGE_ROOT_ADDR
                );
                break;
            }
        }
    }

    function forceDeploymentsToHashes(
        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments
    ) internal pure returns (bytes32[] memory hashes) {
        hashes = new bytes32[](baseForceDeployments.length);
        for (uint256 i = 0; i < baseForceDeployments.length; i++) {
            hashes[i] = baseForceDeployments[i].bytecodeHash;
        }
    }

    function mergeForceDeployments(
        IL2ContractDeployer.ForceDeployment[] memory left,
        IL2ContractDeployer.ForceDeployment[] memory right
    ) internal pure returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments) {
        forceDeployments = new IL2ContractDeployer.ForceDeployment[](left.length + right.length);
        for (uint256 i = 0; i < left.length; i++) {
            forceDeployments[i] = left[i];
        }
        for (uint256 i = 0; i < right.length; i++) {
            forceDeployments[left.length + i] = right[i];
        }
    }

    function mergeBytesArrays(bytes[] memory left, bytes[] memory right) internal pure returns (bytes[] memory result) {
        result = new bytes[](left.length + right.length);
        for (uint256 i = 0; i < left.length; i++) {
            result[i] = left[i];
        }
        for (uint256 i = 0; i < right.length; i++) {
            result[left.length + i] = right[i];
        }
    }

    function getBaseForceDeployments(
        uint256 l1ChainId,
        address owner
    ) internal view returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments) {
        IL2ContractDeployer.ForceDeployment[] memory otherForceDeployments = getOtherBuiltinForceDeployments(
            l1ChainId,
            owner
        );
        IL2ContractDeployer.ForceDeployment[] memory systemForceDeployments = getSystemContractsForceDeployments();

        forceDeployments = mergeForceDeployments(systemForceDeployments, otherForceDeployments);
    }

    function getBaseListOfDependencies(bool _isZKsyncOS) internal view returns (bytes[] memory factoryDeps) {
        if (_isZKsyncOS) {
            // ZKsyncOS has no bootloader / DefaultAccount / EVM emulator — those
            // are Era-VM concepts.
            //
            // Two additional baselines, neither in the CoreContract enum:
            //  - `SystemContractProxy`: every `updateZKsyncOSContract` call that needs
            //    to materialize a proxy at a previously-empty system address force-deploys
            //    this bytecode.
            //  - `SystemContractProxyAdmin` (at 0x1000c): force-deployed once during every
            //    upgrade via `_buildZKsyncOSProxyAdminEntry`, so its preimage must be
            //    published too.
            factoryDeps = new bytes[](2);
            factoryDeps[0] = BytecodeUtils.readDeployedBytecodeL1(
                true,
                "SystemContractProxy.sol",
                "SystemContractProxy"
            );
            factoryDeps[1] = BytecodeUtils.readDeployedBytecodeL1(
                true,
                "SystemContractProxyAdmin.sol",
                "SystemContractProxyAdmin"
            );
            return factoryDeps;
        }

        // Note that it is *important* that these go first in this exact order,
        // since the server will rely on it.
        bytes[] memory basicBytecodes = new bytes[](3);
        basicBytecodes[0] = Utils.getBatchBootloaderBytecodeHash();
        basicBytecodes[1] = BytecodeUtils.readSystemContractsBytecode("DefaultAccount");
        basicBytecodes[2] = Utils.getEvmEmulatorBytecodeHash();

        bytes[] memory systemBytecodes = getSystemContractsBytecodes();
        bytes[] memory otherBytecodes = getOtherFactoryDependencyBytecodes();

        factoryDeps = mergeBytesArrays(mergeBytesArrays(basicBytecodes, systemBytecodes), otherBytecodes);
    }

    /// @notice Build the base ZKsyncOS force deployment array.
    /// Parallel to `getBaseForceDeployments()` for Era — this is the ZKsyncOS equivalent.
    /// Loads bytecode info per contract instead of materializing one large shared cache for this path.
    function getBaseZKsyncOSForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        CoreContract[] memory builtins = getOtherBuiltinCoreContracts();
        ZkSyncOsSystemContract[] memory sysContracts = getZKsyncOSExtraSystemContracts();
        uint256 totalBase = builtins.length + sysContracts.length + 1;

        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](totalBase);

        // Built-in contracts (0x10000+)
        for (uint256 i = 0; i < builtins.length; i++) {
            deployments[i] = _buildZKsyncOSEntry(builtins[i]);
        }
        // System contracts with l1-contracts EVM bytecodes (0x800x)
        for (uint256 i = 0; i < sysContracts.length; i++) {
            deployments[builtins.length + i] = _buildZKsyncOSEntryForSystemContract(sysContracts[i]);
        }
        // ProxyAdmin is direct-deployed on ZKsyncOS genesis and must also be available during upgrades.
        deployments[totalBase - 1] = _buildZKsyncOSProxyAdminEntry();
    }

    function mergeUniversalForceDeployments(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _left,
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _right
    ) internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory result) {
        result = new IComplexUpgrader.UniversalContractUpgradeInfo[](_left.length + _right.length);
        for (uint256 i = 0; i < _left.length; i++) {
            result[i] = _left[i];
        }
        for (uint256 i = 0; i < _right.length; i++) {
            result[_left.length + i] = _right[i];
        }
    }

    /// @dev Build a single ZKsyncOS force deployment entry for a CoreContract (user-space built-in).
    function _buildZKsyncOSEntry(
        CoreContract _id
    ) private returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(true, _id);

        // L2WrappedBaseToken sits directly at L2_WRAPPED_BASE_TOKEN_IMPL_ADDR as the
        // implementation contract — it's *not* behind a TransparentUpgradeableProxy.
        // User-space WETH proxies reference this address directly. So its upgrade is
        // a plain bytecode replacement (Unsafe), not a system-proxy upgrade.
        if (_id == CoreContract.L2WrappedBaseToken) {
            return
                IComplexUpgrader.UniversalContractUpgradeInfo({
                    upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                    deployedBytecodeInfo: Utils.getZKOSBytecodeInfoForContract(fileName, contractName),
                    newAddress: CoreOnGatewayHelper._resolveAddress(_id)
                });
        }

        bytes memory bytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);

        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: CoreOnGatewayHelper._resolveAddress(_id)
            });
    }

    /// @dev Build a single ZKsyncOS force deployment entry for a ZkSyncOsSystemContract.
    function _buildZKsyncOSEntryForSystemContract(
        ZkSyncOsSystemContract _id
    ) private returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        address addr = CoreOnGatewayHelper._resolveZkOsSystemContractAddress(_id);
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolveZkOsSystemContract(_id);
        bytes memory bytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);

        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: addr
            });
    }

    function _buildZKsyncOSProxyAdminEntry() private returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract(
            "SystemContractProxyAdmin.sol",
            "SystemContractProxyAdmin"
        );

        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
            });
    }
}
