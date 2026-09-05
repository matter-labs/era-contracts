// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2 as console} from "forge-std/Script.sol";
import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_INTEROP_ROOT_STORAGE,
    L2_MESSAGE_VERIFICATION,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {
    L2_REMOVED_GW_ASSET_TRACKER_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {CoreContract, L2SystemContract} from "../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";
import {DeduplicateBytecodesCountMismatch} from "../ecosystem/DeployScriptErrors.sol";

// solhint-disable no-console

/// @dev Fixed-address CoreContract entries backed by l1-contracts bytecodes.
uint256 constant FIXED_ADDRESS_CORE_CONTRACTS_COUNT = 14;
/// @dev System contracts (0x800x) with l1-contracts EVM bytecodes for proxy upgrades.
uint256 constant SYSTEM_PROXY_UPGRADE_CONTRACTS_COUNT = 4;

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

            for (uint256 j = i + 1; j < hashes.length; j++) {
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
        // L2WrappedBaseToken must retain its implementation across the upgrade.
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
        ids[i++] = CoreContract.L2InteropCommitmentTree;
        ids[i++] = CoreContract.AtomicFlowManager;
        // Under-filling would silently leave `CoreContract(0)` entries; over-filling
        // already reverts with an out-of-bounds access on the fixed-length array.
        require(i == FIXED_ADDRESS_CORE_CONTRACTS_COUNT, "fixed-address core contract count mismatch");
    }

    /// @notice System contracts that have l1-contracts EVM bytecodes and need proxy upgrades.
    /// @dev Kept separate from the CoreContract lists because these use a distinct enum and artifact source.
    ///      ContractDeployer (0x8006) is intentionally excluded: it's a sequencer hook dispatcher,
    ///      not a wrappable contract. Attempting to force-deploy a SystemContractProxy at 0x8006
    ///      and then calling forceInitAdmin on it hits the hook with an unknown selector and reverts.
    function getSystemProxyUpgradeContracts() internal pure returns (L2SystemContract[] memory ids) {
        ids = new L2SystemContract[](SYSTEM_PROXY_UPGRADE_CONTRACTS_COUNT);
        ids[0] = L2SystemContract.L2BaseToken;
        ids[1] = L2SystemContract.L1Messenger;
        ids[2] = L2SystemContract.SystemContext;
        // Existing OS chains entered this release through the previous ComplexUpgrader implementation.
        // Upgrade its proxy as part of the same loop so subsequent upgrades cannot reach retired Era paths.
        ids[3] = L2SystemContract.L2ComplexUpgrader;
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
        //  - `SystemContractProxy`: every `upgradeSystemContractProxy` call that needs
        //    to materialize a proxy at a previously-empty system address force-deploys
        //    this bytecode.
        //  - `SystemContractProxyAdmin` (at 0x1000c): a direct-deployed ProxyAdmin present from
        //    genesis. v31 no longer force-deploys it (see getBaseForceDeployments), but its
        //    bytecode preimage is still published as a baseline dependency.
        factoryDeps = new bytes[](3);
        factoryDeps[0] = BytecodeUtils.readDeployedBytecodeL1("SystemContractProxy.sol", "SystemContractProxy");
        factoryDeps[1] = BytecodeUtils.readDeployedBytecodeL1(
            "SystemContractProxyAdmin.sol",
            "SystemContractProxyAdmin"
        );
        // The implementation the upgrade installs behind the removed trackers' proxies (see
        // getRemovedTrackerNeutralizations) — not a CoreContract, so published here.
        factoryDeps[2] = BytecodeUtils.readDeployedBytecodeL1("EmptyContract.sol", "EmptyContract");
    }

    /// @notice Build the base force-deployment array.
    /// Loads bytecode info per contract instead of materializing one large shared cache for this path.
    function getBaseForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        CoreContract[] memory fixedAddressCoreContracts = getFixedAddressCoreContracts();
        L2SystemContract[] memory systemProxyUpgradeContracts = getSystemProxyUpgradeContracts();

        // SystemContractProxyAdmin is intentionally NOT force-deployed here: it's a direct-deployed
        // ProxyAdmin already present from genesis (owned by the ComplexUpgrader), so re-deploying it
        // would require an unsafe overwrite. _setupProxyAdmin only reads its owner(), which is already
        // correct. (L2WrappedBaseToken is likewise excluded — it is no longer in
        // getFixedAddressCoreContracts.) The L2V32Upgrade delegate target remains the only legitimate
        // unsafe force deployment (added in CTMUpgrade_v31); the PUVT guards that no other
        // unsafe force deployment is present.
        // The removed v31 GWAssetTracker's proxy gets its implementation swapped for EmptyContract.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory neutralizations = getRemovedTrackerNeutralizations();

        uint256 totalBase = fixedAddressCoreContracts.length +
            systemProxyUpgradeContracts.length +
            neutralizations.length;

        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](totalBase);

        uint256 index;
        // Fixed-address core contracts (0x10000+)
        for (uint256 i = 0; i < fixedAddressCoreContracts.length; i++) {
            deployments[index++] = _buildCoreContractProxyUpgrade(fixedAddressCoreContracts[i]);
        }
        // System contracts with l1-contracts EVM bytecodes (0x800x)
        for (uint256 i = 0; i < systemProxyUpgradeContracts.length; i++) {
            deployments[index++] = _buildSystemContractProxyUpgrade(systemProxyUpgradeContracts[i]);
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

    /// @dev Build a proxy-upgrade entry for a fixed-address CoreContract.
    function _buildCoreContractProxyUpgrade(
        CoreContract _id
    ) private returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(_id);

        // L2WrappedBaseToken is excluded from the force-deployment list, so every entry built here
        // uses the system-proxy upgrade mode.
        bytes memory bytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);

        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: CoreOnGatewayHelper._resolveAddress(_id)
            });
    }

    /// @dev Build a proxy-upgrade entry for a L2SystemContract.
    function _buildSystemContractProxyUpgrade(
        L2SystemContract _id
    ) private returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        address addr = CoreOnGatewayHelper._resolveL2SystemContractAddress(_id);
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolveL2SystemContract(_id);
        bytes memory bytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo(fileName, contractName);

        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
                deployedBytecodeInfo: bytecodeInfo,
                newAddress: addr
            });
    }
}
