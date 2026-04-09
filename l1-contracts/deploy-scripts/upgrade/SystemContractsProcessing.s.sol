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
import {CoreContract, ZKsyncOSUpgradeType} from "../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";

// solhint-disable no-console, gas-custom-errors

/// @notice Enum representing the programming language of the contract
enum Language {
    Solidity,
    Yul
}

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

/// @notice A built-in contract's identity plus its Era bytecode.
struct BuiltinContractDeployInfo {
    CoreContract id;
    address addr;
    bytes bytecode;
}

library SystemContractsProcessing {
    /// @notice Retrieves the entire list of system contracts as a memory array
    /// @dev Note that it does not include all built-in contracts. Rather all those
    /// that are based in the `system-contracts` folder.
    /// @return An array of SystemContract structs containing all system contracts
    function getSystemContracts() public pure returns (SystemContract[] memory) {
        // Initialize the in-memory array
        SystemContract[] memory systemContracts = new SystemContract[](SYSTEM_CONTRACTS_COUNT);
        uint256 i = 0;

        // Populate the array with system contract details
        // Populate the array with system contract details using named parameters
        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000000,
            codeName: "EmptyContract",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000001,
            codeName: "Ecrecover",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000002,
            codeName: "SHA256",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000004,
            codeName: "Identity",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000006,
            codeName: "EcAdd",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000007,
            codeName: "EcMul",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000008,
            codeName: "EcPairing",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000005,
            codeName: "Modexp",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008001,
            codeName: "EmptyContract",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008002,
            codeName: "AccountCodeStorage",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008003,
            codeName: "NonceHolder",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008004,
            codeName: "KnownCodesStorage",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008005,
            codeName: "ImmutableSimulator",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008006,
            codeName: "ContractDeployer",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008008,
            codeName: "L1Messenger",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008009,
            codeName: "MsgValueSimulator",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x000000000000000000000000000000000000800A,
            codeName: "L2BaseToken",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x000000000000000000000000000000000000800B,
            codeName: "SystemContext",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x000000000000000000000000000000000000800c,
            codeName: "BootloaderUtilities",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x000000000000000000000000000000000000800d,
            codeName: "EventWriter",
            lang: Language.Yul,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x000000000000000000000000000000000000800E,
            codeName: "Compressor",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008010,
            codeName: "Keccak256",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008012,
            codeName: "CodeOracle",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008013,
            codeName: "EvmGasManager",
            lang: Language.Yul,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008014,
            codeName: "EvmPredeploysManager",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008015,
            codeName: "EvmHashesStorage",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000000100,
            codeName: "P256Verify",
            lang: Language.Yul,
            isPrecompile: true
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000008011,
            codeName: "PubdataChunkPublisher",
            lang: Language.Solidity,
            isPrecompile: false
        });

        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000010000,
            codeName: "Create2Factory",
            lang: Language.Solidity,
            isPrecompile: false
        });
        systemContracts[i++] = SystemContract({
            addr: 0x0000000000000000000000000000000000010006,
            codeName: "SloadContract",
            lang: Language.Solidity,
            isPrecompile: false
        });
        // Note, that we do not populate the system contract for the genesis upgrade address,
        // as it is used during the genesis upgrade or during upgrades (and so it should be populated
        // as part of the upgrade script).

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
        require(included == toInclude, "Internal error: included != toInclude");
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

        // Special case: L2ChainAssetHandler needs constructor call
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

    function getBaseForceDeployments()
        internal
        view
        returns (
            // For purpose of making compilation of earlier upgrade scripts possible.
            IL2ContractDeployer.ForceDeployment[] memory forceDeployments
        )
    {
        getBaseForceDeployments(0, address(0));
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
        CoreContract[] memory ids = getOtherBuiltinCoreContracts();

        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](ids.length + _additionalDeployments.length);

        for (uint256 i = 0; i < ids.length; i++) {
            address addr = CoreOnGatewayHelper._resolveAddress(ids[i]);
            // Try to reuse bytecodeInfo from FixedForceDeploymentsData to avoid double-loading.
            bytes memory bytecodeInfo = _getFixedBytecodeInfo(_fixedData, addr);

            if (bytecodeInfo.length == 0) {
                // Not in FixedForceDeploymentsData — load from disk.
                (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(true, ids[i]);
                ZKsyncOSUpgradeType zkosType = CoreOnGatewayHelper._resolveUpgradeType(ids[i]);
                if (zkosType == ZKsyncOSUpgradeType.SystemProxy) {
                    bytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);
                } else {
                    bytecodeInfo = Utils.getZKOSBytecodeInfoForContract(fileName, contractName);
                }
            }

            ZKsyncOSUpgradeType zkosType = CoreOnGatewayHelper._resolveUpgradeType(ids[i]);
            IComplexUpgrader.ContractUpgradeType upgradeType = zkosType == ZKsyncOSUpgradeType.SystemProxy
                ? IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade
                : IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment;

            deployments[i] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: upgradeType,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: addr
            });
        }

        // Append version-specific entries
        for (uint256 i = 0; i < _additionalDeployments.length; i++) {
            deployments[ids.length + i] = _additionalDeployments[i];
        }
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
