// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2 as console} from "forge-std/Script.sol";
import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {
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
import {
    L2_REMOVED_GW_ASSET_TRACKER_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {CoreContract, ZkSyncOsSystemContract, ZKsyncOSUpgradeType} from "../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";
import {DeduplicateBytecodesCountMismatch} from "../ecosystem/DeployScriptErrors.sol";

// solhint-disable no-console

/// @dev Fixed-address CoreContract entries backed by l1-contracts bytecodes,
///      upgraded on ZKsyncOS via universal force deployments.
uint256 constant FIXED_ADDRESS_CORE_CONTRACTS_COUNT = 12;
/// @dev System contracts (0x800x) with l1-contracts EVM bytecodes for ZKsyncOS proxy upgrades.
uint256 constant ZKOS_EXTRA_SYSTEM_CONTRACTS_COUNT = 3;

/// @dev Core contracts that only exist on ZKsync OS chains.
uint256 constant ZKOS_ONLY_CONTRACTS_COUNT = 2;

library SystemContractsProcessing {
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

    /// @notice CoreContract entries with canonical fixed L2 addresses.
    function getFixedAddressCoreContracts() internal pure returns (CoreContract[] memory ids) {
        ids = new CoreContract[](FIXED_ADDRESS_CORE_CONTRACTS_COUNT);
        _fillFixedAddressCoreContracts(ids);
    }

    function _fillFixedAddressCoreContracts(CoreContract[] memory ids) private pure {
        // NOTE: L2WrappedBaseToken is intentionally NOT in this list. v31 must not touch the
        // WrappedBaseToken impl on either VM, so it is excluded from both the force-deployment list
        // and the factory deps.
        uint256 i = 0;
        ids[i++] = CoreContract.L2Bridgehub;
        ids[i++] = CoreContract.L2AssetRouter;
        ids[i++] = CoreContract.L2NativeTokenVault;
        ids[i++] = CoreContract.L2MessageRoot;
        ids[i++] = CoreContract.L2MessageVerification;
        ids[i++] = CoreContract.L2ChainAssetHandler;
        ids[i++] = CoreContract.L2InteropRootStorage;
        ids[i++] = CoreContract.BaseTokenHolder;
        ids[i++] = CoreContract.L2AssetTracker;
        ids[i++] = CoreContract.InteropCenter;
        // Stateless parser called by the InteropCenter on every send; must be co-deployed with it.
        ids[i++] = CoreContract.InteropAttributeParser;
        ids[i++] = CoreContract.L2InteropHandler;
        // Under-filling would silently leave `CoreContract(0)` entries; over-filling
        // already reverts with an out-of-bounds access on the fixed-length array.
        require(i == FIXED_ADDRESS_CORE_CONTRACTS_COUNT, "fixed-address core contract count mismatch");
    }

    /// @notice Core contracts that a ZKsync OS chain has and an Era chain does not, on top of the
    /// fixed-address core contracts. Currently the atomic-interop built-ins, see
    /// {protocol-docs/chain-lifecycle.md#zksync-os-genesis-force-deployments-atomic-interop-built-ins}.
    function getZKsyncOSOnlyContracts() internal pure returns (CoreContract[] memory ids) {
        ids = new CoreContract[](ZKOS_ONLY_CONTRACTS_COUNT);
        uint256 i;
        ids[i++] = CoreContract.L2InteropCommitmentTree;
        ids[i++] = CoreContract.AtomicFlowManager;
        // Same guard as `getFixedAddressCoreContracts`: under-filling would leave `CoreContract(0)` entries.
        require(i == ZKOS_ONLY_CONTRACTS_COUNT, "ZKsync-OS-only contract count mismatch");
    }

    /// @notice System contracts that have l1-contracts EVM bytecodes and need ZKsyncOS proxy upgrades.
    /// @dev Separate from getFixedAddressCoreContracts because these are ZKsyncOS system-space contracts
    ///      with l1-contracts EVM bytecodes.
    ///      ContractDeployer (0x8006) is intentionally excluded: it's a sequencer hook dispatcher,
    ///      not a wrappable contract. Attempting to force-deploy a SystemContractProxy at 0x8006
    ///      and then calling forceInitAdmin on it hits the hook with an unknown selector and reverts.
    function getZKsyncOSExtraSystemContracts() internal pure returns (ZkSyncOsSystemContract[] memory ids) {
        ids = new ZkSyncOsSystemContract[](ZKOS_EXTRA_SYSTEM_CONTRACTS_COUNT);
        ids[0] = ZkSyncOsSystemContract.L2BaseToken;
        ids[1] = ZkSyncOsSystemContract.L1Messenger;
        ids[2] = ZkSyncOsSystemContract.SystemContext;
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

    function getBaseListOfDependencies() internal view returns (bytes[] memory factoryDeps) {
        // Baselines, none in the CoreContract enum:
        //  - `SystemContractProxy`: every `updateZKsyncOSContract` call that needs
        //    to materialize a proxy at a previously-empty system address force-deploys
        //    this bytecode.
        //  - `SystemContractProxyAdmin` (at 0x1000c): a direct-deployed ProxyAdmin present from
        //    genesis. v31 no longer force-deploys it (see getBaseZKsyncOSForceDeployments), but its
        //    bytecode preimage is still published as a ZKsyncOS baseline.
        factoryDeps = new bytes[](3);
        factoryDeps[0] = BytecodeUtils.readDeployedBytecodeL1(true, "SystemContractProxy.sol", "SystemContractProxy");
        factoryDeps[1] = BytecodeUtils.readDeployedBytecodeL1(
            true,
            "SystemContractProxyAdmin.sol",
            "SystemContractProxyAdmin"
        );
        // The implementation the upgrade installs behind the removed trackers' proxies (see
        // getRemovedTrackerNeutralizations) — not a CoreContract, so published here.
        factoryDeps[2] = BytecodeUtils.readDeployedBytecodeL1(true, "EmptyContract.sol", "EmptyContract");
    }

    /// @notice Build the base ZKsyncOS force deployment array.
    /// Loads bytecode info per contract instead of materializing one large shared cache for this path.
    function getBaseZKsyncOSForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        CoreContract[] memory fixedAddressCoreContracts = getFixedAddressCoreContracts();
        CoreContract[] memory zksyncOSOnlyContracts = getZKsyncOSOnlyContracts();
        ZkSyncOsSystemContract[] memory sysContracts = getZKsyncOSExtraSystemContracts();

        // SystemContractProxyAdmin is intentionally NOT force-deployed here: it's a direct-deployed
        // ProxyAdmin already present from genesis (owned by the ComplexUpgrader), so re-deploying it
        // would require an unsafe overwrite. _setupProxyAdmin only reads its owner(), which is already
        // correct. (L2WrappedBaseToken is likewise excluded — it is no longer in
        // getFixedAddressCoreContracts.) The L2V32Upgrade delegate target remains the only legitimate
        // ZKsyncOS unsafe force deployment (added in CTMUpgrade_v31); the PUVT guards that no other
        // unsafe force deployment is present.
        // The removed v31 GWAssetTracker's proxy gets its implementation swapped for EmptyContract.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory neutralizations = getRemovedTrackerNeutralizations();

        uint256 totalBase = fixedAddressCoreContracts.length +
            zksyncOSOnlyContracts.length +
            sysContracts.length +
            neutralizations.length;

        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](totalBase);

        uint256 index;
        // Fixed-address core contracts (0x10000+)
        for (uint256 i = 0; i < fixedAddressCoreContracts.length; i++) {
            deployments[index++] = _buildZKsyncOSEntry(fixedAddressCoreContracts[i]);
        }
        // ZKsync-OS-only contracts (currently the atomic-interop built-ins at 0x10012 / 0x10014).
        // Predeployed in the ZKsync OS genesis, so a from-scratch chain already has them; a chain that
        // predates the release gets them here, which is what lets `_initializeV32Contracts` initialize
        // them on the upgrade path too.
        for (uint256 i = 0; i < zksyncOSOnlyContracts.length; i++) {
            deployments[index++] = _buildZKsyncOSEntry(zksyncOSOnlyContracts[i]);
        }
        // System contracts with l1-contracts EVM bytecodes (0x800x)
        for (uint256 i = 0; i < sysContracts.length; i++) {
            deployments[index++] = _buildZKsyncOSEntryForSystemContract(sysContracts[i]);
        }

        for (uint256 i = 0; i < neutralizations.length; i++) {
            deployments[index++] = neutralizations[i];
        }
    }

    /// @notice Proxy upgrades that neutralize the removed v31 GWAssetTracker.
    /// @dev v31 deployed the GWAssetTracker as a system-proxied built-in on every ZKsync OS chain.
    /// v32 deletes the contract, so the upgrade swaps its proxy's implementation for `EmptyContract`
    /// — otherwise the retired tracker code would stay callable. Chains created on v32 get the same
    /// EmptyContract-backed proxy from genesis, so fresh and upgraded chains match at the reserved
    /// address.
    /// @dev The v31 GWAssetTracker could collect wrapped-ZK settlement fees on a live gateway, but no
    /// gateway ever accrued any, so the swap strands nothing. It destroys no state either way: the
    /// proxy stays upgradable, so a later governance upgrade can always restore recovery logic.
    function getRemovedTrackerNeutralizations()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        bytes memory emptyContractInfo = Utils.getZKOSProxyUpgradeBytecodeInfo("EmptyContract.sol", "EmptyContract");

        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        deployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
            deployedBytecodeInfo: emptyContractInfo,
            newAddress: L2_REMOVED_GW_ASSET_TRACKER_ADDR
        });
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

    /// @dev Build a single ZKsyncOS force deployment entry for a fixed-address CoreContract.
    function _buildZKsyncOSEntry(
        CoreContract _id
    ) private returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(_id);

        // Note: L2WrappedBaseToken is excluded from the ZKsyncOS force-deployment list (see
        // getBaseZKsyncOSForceDeployments), so this builder only handles system-proxy upgrades.
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
}
