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
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {
    CoreContract,
    EraVmSystemContract,
    Language,
    ZkSyncOsSystemContract,
    ZKsyncOSUpgradeType
} from "../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";
import {DeduplicateBytecodesCountMismatch} from "../ecosystem/DeployScriptErrors.sol";

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
/// @dev System contracts (0x800x) with l1-contracts EVM bytecodes for ZKsyncOS proxy upgrades.
uint256 constant ZKOS_EXTRA_SYSTEM_CONTRACTS_COUNT = 4;

/// @notice A built-in contract's identity plus its Era bytecode.
struct BuiltinContractDeployInfo {
    CoreContract id;
    address addr;
    bytes bytecode;
}

library SystemContractsProcessing {
    /// @notice Retrieves the entire list of system contracts as a memory array.
    /// @dev Note that it does not include all built-in contracts. Rather all those
    /// that are based in the `system-contracts` folder.
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
    function getZKsyncOSExtraSystemContracts() internal pure returns (ZkSyncOsSystemContract[] memory ids) {
        ids = new ZkSyncOsSystemContract[](ZKOS_EXTRA_SYSTEM_CONTRACTS_COUNT);
        ids[0] = ZkSyncOsSystemContract.L2BaseToken;
        ids[1] = ZkSyncOsSystemContract.L1Messenger;
        ids[2] = ZkSyncOsSystemContract.SystemContext;
        ids[3] = ZkSyncOsSystemContract.ContractDeployer;
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

        // Special case: L2ChainAssetHandler needs an initializer call after force deployment
        forceDeployments[6].callConstructor = true;
        // solhint-disable-next-line func-named-parameters
        forceDeployments[6].input = abi.encode(
            l1ChainId,
            AddressAliasHelper.applyL1ToL2Alias(owner),
            L2_BRIDGEHUB_ADDR,
            L2_ASSET_ROUTER_ADDR,
            L2_MESSAGE_ROOT_ADDR
        );
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

    function getBaseListOfDependencies() internal view returns (bytes[] memory factoryDeps) {
        // Note that it is *important* that these go first in this exact order,
        // since the server will rely on it.
        bytes[] memory basicBytecodes = new bytes[](3);
        basicBytecodes[0] = Utils.getBatchBootloaderBytecodeHash();
        basicBytecodes[1] = BytecodeUtils.readSystemContractsBytecode("DefaultAccount");
        basicBytecodes[2] = Utils.getEvmEmulatorBytecodeHash();

        bytes[] memory systemBytecodes = getSystemContractsBytecodes();
        BuiltinContractDeployInfo[] memory otherContracts = getOtherBuiltinContracts();
        bytes[] memory otherBytecodes = new bytes[](otherContracts.length);
        for (uint256 i = 0; i < otherContracts.length; i++) {
            otherBytecodes[i] = otherContracts[i].bytecode;
        }

        factoryDeps = mergeBytesArrays(mergeBytesArrays(basicBytecodes, systemBytecodes), otherBytecodes);
    }

    /// @notice Build the full ZKsyncOS force deployment array.
    /// Parallel to `getBaseForceDeployments()` for Era — this is the ZKsyncOS equivalent.
    /// Reuses bytecodeInfo from the already-generated FixedForceDeploymentsData where possible
    /// to avoid loading large bytecodes from disk twice (OOM prevention).
    /// @param _fixedData The already-encoded FixedForceDeploymentsData containing bytecodeInfo.
    /// @param _additionalDeployments Version-specific entries to append (e.g. L2V31Upgrade).
    function buildZKsyncOSForceDeployments(
        FixedForceDeploymentsData memory _fixedData,
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _additionalDeployments
    ) internal returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        CoreContract[] memory builtins = getOtherBuiltinCoreContracts();
        ZkSyncOsSystemContract[] memory sysContracts = getZKsyncOSExtraSystemContracts();
        uint256 totalBase = builtins.length + sysContracts.length;

        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](totalBase + _additionalDeployments.length);

        // Built-in contracts (0x10000+)
        for (uint256 i = 0; i < builtins.length; i++) {
            deployments[i] = _buildZKsyncOSEntry(_fixedData, builtins[i]);
        }
        // System contracts with l1-contracts EVM bytecodes (0x800x)
        for (uint256 i = 0; i < sysContracts.length; i++) {
            deployments[builtins.length + i] = _buildZKsyncOSEntryForSystemContract(sysContracts[i]);
        }
        // Version-specific entries
        for (uint256 i = 0; i < _additionalDeployments.length; i++) {
            deployments[totalBase + i] = _additionalDeployments[i];
        }
    }

    /// @dev Build a single ZKsyncOS force deployment entry for a CoreContract (user-space built-in).
    function _buildZKsyncOSEntry(
        FixedForceDeploymentsData memory _fixedData,
        CoreContract _id
    ) private returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        address addr = CoreOnGatewayHelper._resolveAddress(_id);
        // Try to reuse bytecodeInfo from FixedForceDeploymentsData to avoid double-loading.
        bytes memory bytecodeInfo = _getFixedBytecodeInfo(_fixedData, addr);

        if (bytecodeInfo.length == 0) {
            // Not in FixedForceDeploymentsData — load from disk.
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(true, _id);
            bytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
        }

        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: addr
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

    /// @dev Map a contract address to its bytecodeInfo field in FixedForceDeploymentsData.
    /// Returns empty bytes if the contract doesn't have a corresponding field.
    function _getFixedBytecodeInfo(
        FixedForceDeploymentsData memory _data,
        address _addr
    ) private pure returns (bytes memory) {
        if (_addr == L2_BRIDGEHUB_ADDR) return _data.bridgehubBytecodeInfo;
        if (_addr == L2_ASSET_ROUTER_ADDR) return _data.l2AssetRouterBytecodeInfo;
        if (_addr == L2_NATIVE_TOKEN_VAULT_ADDR) return _data.l2NtvBytecodeInfo;
        if (_addr == L2_MESSAGE_ROOT_ADDR) return _data.messageRootBytecodeInfo;
        if (_addr == L2_CHAIN_ASSET_HANDLER_ADDR) return _data.chainAssetHandlerBytecodeInfo;
        if (_addr == L2_INTEROP_CENTER_ADDR) return _data.interopCenterBytecodeInfo;
        if (_addr == L2_INTEROP_HANDLER_ADDR) return _data.interopHandlerBytecodeInfo;
        if (_addr == L2_ASSET_TRACKER_ADDR) return _data.assetTrackerBytecodeInfo;
        if (_addr == L2_BASE_TOKEN_HOLDER_ADDR) return _data.baseTokenHolderBytecodeInfo;
        return "";
    }
}
