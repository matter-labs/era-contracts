// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2 as console} from "forge-std/Script.sol";
import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {
    L2_REMOVED_GW_ASSET_TRACKER_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2EcosystemContract, L2SystemContract} from "../ecosystem/CoreContract.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {TransitionDerivationLib} from "contracts/upgrades/registry/libraries/TransitionDerivationLib.sol";
import {CoreOnGatewayHelper} from "../ecosystem/CoreOnGatewayHelper.sol";
import {DeduplicateBytecodesCountMismatch} from "../ecosystem/DeployScriptErrors.sol";

// solhint-disable no-console

/// @dev Fixed-address L2EcosystemContract entries backed by l1-contracts bytecodes,
///      upgraded via universal force deployments.
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

    /// @notice L2EcosystemContract entries with canonical fixed L2 addresses.
    function getFixedAddressCoreContracts() internal pure returns (L2EcosystemContract[] memory ids) {
        ids = new L2EcosystemContract[](FIXED_ADDRESS_CORE_CONTRACTS_COUNT);
        _fillFixedAddressCoreContracts(ids);
    }

    function _fillFixedAddressCoreContracts(L2EcosystemContract[] memory ids) private pure {
        // L2WrappedBaseToken must retain its implementation across the upgrade, so it is
        // intentionally NOT in this list: neither force-deployed nor published as a factory dep.
        uint256 i = 0;
        ids[i++] = L2EcosystemContract.L2Bridgehub;
        ids[i++] = L2EcosystemContract.L2AssetRouter;
        ids[i++] = L2EcosystemContract.L2NativeTokenVault;
        ids[i++] = L2EcosystemContract.L2MessageRoot;
        ids[i++] = L2EcosystemContract.L2MessageVerification;
        ids[i++] = L2EcosystemContract.L2ChainAssetHandler;
        ids[i++] = L2EcosystemContract.L2InteropRootStorage;
        ids[i++] = L2EcosystemContract.BaseTokenHolder;
        ids[i++] = L2EcosystemContract.L2AssetTracker;
        ids[i++] = L2EcosystemContract.InteropCenter;
        // Stateless parser called by the InteropCenter on every send; must be co-deployed with it.
        ids[i++] = L2EcosystemContract.InteropAttributeParser;
        ids[i++] = L2EcosystemContract.L2InteropHandler;
        // Atomic-interop built-ins, see
        // {protocol-docs/chain-lifecycle.md#zksync-os-genesis-force-deployments-atomic-interop-built-ins}.
        ids[i++] = L2EcosystemContract.L2InteropCommitmentTree;
        ids[i++] = L2EcosystemContract.AtomicFlowManager;
        // Under-filling would silently leave `L2EcosystemContract(0)` entries; over-filling
        // already reverts with an out-of-bounds access on the fixed-length array.
        require(i == FIXED_ADDRESS_CORE_CONTRACTS_COUNT, "fixed-address core contract count mismatch");
    }

    /// @notice System contracts that have l1-contracts EVM bytecodes and need proxy upgrades.
    /// @dev Kept separate from the L2EcosystemContract lists because these use a distinct enum and
    ///      artifact source.
    ///      ContractDeployer (0x8006) is intentionally excluded: it's a sequencer hook dispatcher,
    ///      not a wrappable contract. Attempting to force-deploy a SystemContractProxy at 0x8006
    ///      and then calling forceInitAdmin on it hits the hook with an unknown selector and reverts.
    function getSystemProxyUpgradeContracts() internal pure returns (L2SystemContract[] memory ids) {
        ids = new L2SystemContract[](SYSTEM_PROXY_UPGRADE_CONTRACTS_COUNT);
        ids[0] = L2SystemContract.L2BaseToken;
        ids[1] = L2SystemContract.L1Messenger;
        ids[2] = L2SystemContract.SystemContext;
        // See {protocol-docs/chain-lifecycle.md} for the ComplexUpgrader transition.
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
        // Baselines, none in the L2EcosystemContract enum:
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
        // getRemovedTrackerNeutralizations) — not an L2EcosystemContract, so published here.
        factoryDeps[2] = BytecodeUtils.readDeployedBytecodeL1("EmptyContract.sol", "EmptyContract");
    }

    /// @notice Build the base force deployment array.
    /// @dev DERIVED from the release's L2 bytecode table via the SAME function the on-chain
    ///      transition derivation uses, so the script-composed bootstrap L2 leg and every
    ///      registry-driven edge after it are one code path. Which contracts participate is
    ///      encoded once, in which table rows `buildL2BytecodeInfoTable` fills.
    function getBaseForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        return
            TransitionDerivationLib.deriveL2DeploymentsFromTable(buildL2BytecodeInfoTable(), systemProxyBytecodeInfo());
    }

    /// @notice The release's shared system-proxy shell descriptor
    ///         (`ReleaseManifest.l2SystemProxyBytecodeInfo`): the ZKsync OS bytecode info of
    ///         `SystemContractProxy`, which every table member sits behind.
    function systemProxyBytecodeInfo() internal returns (bytes memory) {
        return Utils.getZKOSBytecodeInfoForContract("SystemContractProxy.sol", "SystemContractProxy");
    }

    /// @notice Builds the release manifest's enum-indexed L2 bytecode table
    ///         (`ReleaseManifest.l2BytecodeInfos`): per force-deployed member, the ZKsync OS
    ///         bytecode info of its IMPLEMENTATION; every other slot stays an explicit empty.
    /// @dev Deliberately UNFILLED rows, and why:
    ///      - SystemContractProxyAdmin: a direct-deployed ProxyAdmin already present from genesis
    ///        (owned by the ComplexUpgrader); re-deploying it would require an unsafe overwrite.
    ///      - L2WrappedBaseToken: upgrades must not touch the impl (since v31).
    ///      - L2V34Upgrade: the version-specific delegate is an UNSAFE deployment at a
    ///        bytecode-derived address — constructed from the pinned
    ///        `AuthoredL2Plan.delegateBytecodeInfo`, never table-derived. That no OTHER unsafe
    ///        deployment rides along is established by reviewing this table: the pre-registry
    ///        verifier that used to assert it has been retired.
    function buildL2BytecodeInfoTable() internal returns (bytes[] memory rows) {
        return buildL2BytecodeInfoTable(Utils.getZKOSBytecodeInfoForContract);
    }

    /// @dev Variant for deployers that precompute the expensive bytecode hashes and provide a
    ///      cache-backed descriptor builder (artifact file + contract name -> the implementation's
    ///      bytecode info). Keeping the table assembly here prevents the genesis and upgrade paths
    ///      from growing separate contract inventories.
    function buildL2BytecodeInfoTable(
        function(string memory, string memory) internal returns (bytes memory) _buildBytecodeInfo
    ) internal returns (bytes[] memory rows) {
        rows = new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
        L2EcosystemContract[] memory core = getFixedAddressCoreContracts();
        for (uint256 i = 0; i < core.length; i++) {
            rows[uint256(core[i])] = _implementationBytecodeInfo(core[i], _buildBytecodeInfo);
        }
        // Kernel built-ins with l1-contracts EVM bytecodes (system space, 0x800x).
        L2SystemContract[] memory sysContracts = getSystemProxyUpgradeContracts();
        for (uint256 i = 0; i < sysContracts.length; i++) {
            (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolveL2SystemContract(
                sysContracts[i]
            );
            rows[uint256(_l2MemberForSystemContract(sysContracts[i]))] = _buildBytecodeInfo(fileName, contractName);
        }
        // The removed v31 GWAssetTracker's proxy keeps its neutralizing EmptyContract
        // implementation (see `getRemovedTrackerNeutralizations`).
        rows[uint256(L2EcosystemContract.RemovedGWAssetTracker)] = _buildBytecodeInfo(
            "EmptyContract.sol",
            "EmptyContract"
        );
    }

    /// @dev The table row of a fixed-address `L2EcosystemContract`: its implementation's bytecode info.
    function _implementationBytecodeInfo(
        L2EcosystemContract _id,
        function(string memory, string memory) internal returns (bytes memory) _buildBytecodeInfo
    ) private returns (bytes memory) {
        (string memory fileName, string memory contractName) = CoreOnGatewayHelper.resolve(_id);
        return _buildBytecodeInfo(fileName, contractName);
    }

    /// @dev The appended `L2EcosystemContract` member a ZKsyncOS kernel built-in occupies in the
    ///      release's L2 bytecode table.
    function _l2MemberForSystemContract(L2SystemContract _id) private pure returns (L2EcosystemContract) {
        if (_id == L2SystemContract.L2BaseToken) {
            return L2EcosystemContract.L2BaseToken;
        }
        if (_id == L2SystemContract.L1Messenger) {
            return L2EcosystemContract.L1Messenger;
        }
        if (_id == L2SystemContract.SystemContext) {
            return L2EcosystemContract.SystemContext;
        }
        if (_id == L2SystemContract.L2ComplexUpgrader) {
            return L2EcosystemContract.L2ComplexUpgrader;
        }
        revert("L2SystemContract has no L2EcosystemContract member");
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
}
