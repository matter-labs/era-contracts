// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {CTMUpgrade_v31} from "./CTMUpgrade_v31.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";

/// @notice Regenerates the v31 **ZKsync OS** CTM upgrade data after the base-token `totalSupply`
///         fix changed the L2AssetTracker (and dependent) bytecode.
///
/// The fix (`L2AssetTracker._needToForceSetAssetMigrationOnL2` no longer reads the base token
/// `totalSupply()` before it is backfilled) changes the compiled L2AssetTracker bytecode and the
/// bytecode of the L2 contracts that embed its hash. Those zk bytecode hashes are baked into the
/// v31 upgrade `DiamondCutData` / `ChainCreationParams` the CTM stores, and the corrected
/// preimages have to be published — exactly what the normal v31 CTM upgrade prep does.
///
/// So this stays **consistent with the real upgrade scripts** by extending `CTMUpgrade_v31` and
/// running `noGovernancePrepare`, which assembles the full list of factory dependencies and
/// PUBLISHES them via the `BytecodesSupplier`, and rebuilds + serializes the
/// `setNewVersionUpgrade` / `setChainCreationParams` governance calls from the freshly-built
/// (fixed) artifacts into the output TOML.
///
/// All deployed-address parameters are read from the stage upgrade artifact
/// `upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml` (with the few non-address inputs
/// taken from the matching `stage.toml`), so they stay in sync with the original stage run.
///
/// `scripts/patch-total-supply-crosscheck.ts` byte-replaces the stale hashes in the on-chain
/// upgrade cut as a lightweight double-check of the regenerated cut.
contract PatchTotalSupplyV31 is CTMUpgrade_v31 {
    using stdToml for string;

    /// @dev Hardcoded: the L1 RPC for the stage environment (Sepolia).
    string internal constant L1_RPC_URL_ENV = "TENDERLY_SEPOLIA";

    string internal constant ECOSYSTEM_TOML = "/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml";
    string internal constant STAGE_INPUT_TOML = "/upgrade-envs/v0.31.0-interopB/stage.toml";

    /// @dev Stage L1 chain id (Sepolia) and L1 ZK token (BridgedStandardERC20, see
    ///      `sim-descriptions.toml` `l1_zk_token`) used to derive the ZK token asset id that
    ///      `InteropCenter.initL2` requires to be non-zero.
    uint256 internal constant L1_CHAIN_ID = 11155111;
    address internal constant L1_ZK_TOKEN = 0xF41D4478f1D6B8A096c0369B05c0B24AE00cc2DF;

    /// @dev Per-CTM CREATE2 salt for the ZKsync OS (Atlas) CTM, from `stage.toml`
    ///      `[create2_factory_salts]` keyed by the CTM proxy address.
    bytes32 internal constant ZKSYNC_OS_CTM_CREATE2_SALT =
        0xe2fa245eeb7a45aaf8e4add75c988abe4019abc7fd81e2f8593bafc52cb43099;

    function runPatch() public {
        // Run against the stage L1 fork the same way the v31 upgrade scripts are run, i.e. with
        // `--rpc-url $<L1_RPC_URL_ENV>` (forge forks and links the deploy libraries into that fork;
        // self-forking here would wipe them). The L1 chain id is asserted as a guard.
        require(block.chainid == L1_CHAIN_ID, string.concat("run with --rpc-url $", L1_RPC_URL_ENV));

        string memory root = vm.projectRoot();
        string memory eco = vm.readFile(string.concat(root, ECOSYSTEM_TOML));
        string memory stageInput = vm.readFile(string.concat(root, STAGE_INPUT_TOML));

        CTMUpgradeParams memory params = CTMUpgradeParams({
            ctmProxy: eco.readAddress(".ctms.zksync_os.state_transition.chain_type_manager_proxy"),
            bytecodesSupplier: eco.readAddress(".ctms.zksync_os.state_transition.bytecodes_supplier_addr"),
            isZKsyncOS: true,
            rollupDAManager: eco.readAddress(".ctms.zksync_os.deployed_addresses.l1_rollup_da_manager"),
            create2FactorySalt: ZKSYNC_OS_CTM_CREATE2_SALT,
            upgradeInputPath: STAGE_INPUT_TOML,
            outputPath: string.concat(
                root,
                "/deploy-scripts/upgrade/v31/patch-total-supply/patched-ecosystem.toml"
            ),
            governance: stageInput.readAddress(".contracts.protocol_upgrade_handler_proxy_address"),
            chainRegistrationSender: eco.readAddress(
                ".core.upgrade_addresses.bridgehub.chain_registration_sender_proxy_addr"
            ),
            zkTokenAssetId: DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, L1_ZK_TOKEN)
        });

        // Re-run the v31 ZKsync OS CTM upgrade prep against the fixed artifacts: publishes the
        // full list of factory dependencies and rebuilds + serializes the setNewVersionUpgrade /
        // setChainCreationParams governance calls into the output TOML.
        noGovernancePrepare(params);

        bytes32 correctedUpgradeCutHash = keccak256(getChainUpgradeDiamondCutData());
        console2.log("Regenerated ZKsync OS v31 upgrade data for CTM:", params.ctmProxy);
        console2.log("Corrected upgrade cut hash:");
        console2.logBytes32(correctedUpgradeCutHash);

        // Record the regenerated cut (bytes + hash) as TOML for the TypeScript double-check:
        // it confirms the new ZKsync OS blake force-deployment hashes landed in the cut.
        string memory cutOut = string.concat(
            vm.projectRoot(),
            "/deploy-scripts/upgrade/v31/patch-total-supply/patched-upgrade-cut.toml"
        );
        vm.serializeBytes32("patch", "corrected_upgrade_cut_hash", correctedUpgradeCutHash);
        vm.writeToml(vm.serializeBytes("patch", "cut_data", getChainUpgradeDiamondCutData()), cutOut);
    }
}
