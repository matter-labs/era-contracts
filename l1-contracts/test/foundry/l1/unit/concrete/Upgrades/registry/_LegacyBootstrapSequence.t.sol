// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {ICoreTransition} from "contracts/upgrades/registry/objects/ICoreTransition.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";

/// @notice The bootstrap edge's governance bundles EXACTLY as the two v34 prepare scripts authored
///         them before the sequence was derived on-chain: the calls
///         `CoreUpgrade_v34._declareBootstrapActions` and `CTMUpgrade_v34._declareBootstrapActions`
///         pushed into each phase's ledger, in the order protocol-ops merged them (the core
///         prepare's calls ahead of the CTM prepare's).
/// @dev A deliberate duplicate of retired script code, kept only so `RegistryBootstrapSequence`
///         can be held against the sequence it replaced. Transcribed here and nowhere else.
library LegacyBootstrapSequence {
    /// @param chainAssetHandler The ecosystem's handler, read off the Bridgehub by both scripts.
    /// @param upgradeTimer The timer the CTM prepare deployed.
    /// @param ecosystemProxyAdmin The shared ecosystem `ProxyAdmin`.
    /// @param coreUpgradeExecutor The bound ecosystem executor the core prepare deployed.
    /// @param coreTransition The ecosystem inventory the core prepare pinned.
    /// @param ctm The CTM proxy.
    /// @param ctmProxyAdmin The CTM domain's own `ProxyAdmin`.
    /// @param bootstrapMigration The write-once edge object.
    /// @param coordinator The lifecycle coordinator the core prepare deployed.
    /// @param ctmUpgradeExecutor The bound CTM executor the CTM prepare deployed.
    // solhint-disable-next-line gas-struct-packing
    struct Inputs {
        address chainAssetHandler;
        address upgradeTimer;
        address ecosystemProxyAdmin;
        address coreUpgradeExecutor;
        address coreTransition;
        address ctm;
        address ctmProxyAdmin;
        address bootstrapMigration;
        address coordinator;
        address ctmUpgradeExecutor;
    }

    function stage0(Inputs memory _in) internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        // Core prepare.
        calls[0] = _pause(_in.chainAssetHandler);
        // CTM prepare.
        calls[1] = Call({
            target: _in.upgradeTimer,
            value: 0,
            data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ())
        });
    }

    function stage1(Inputs memory _in) internal pure returns (Call[] memory calls) {
        calls = new Call[](6);
        // Core prepare.
        calls[0] = _pause(_in.chainAssetHandler);
        calls[1] = Call({
            target: _in.ecosystemProxyAdmin,
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (_in.coreUpgradeExecutor))
        });
        calls[2] = Call({
            target: _in.coreUpgradeExecutor,
            value: 0,
            data: abi.encodeCall(CoreUpgradeExecutor.applyL1Upgrade, (ICoreTransition(_in.coreTransition)))
        });
        // CTM prepare.
        calls[3] = Call({
            target: _in.ctm,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (_in.bootstrapMigration))
        });
        calls[4] = Call({
            target: _in.ctmProxyAdmin,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (_in.bootstrapMigration))
        });
        calls[5] = Call({
            target: _in.bootstrapMigration,
            value: 0,
            data: abi.encodeCall(RegistryBootstrapMigration.migrate, ())
        });
    }

    function stage2(Inputs memory _in) internal pure returns (Call[] memory calls) {
        calls = new Call[](5);
        // Core prepare.
        calls[0] = Call({
            target: _in.coreUpgradeExecutor,
            value: 0,
            data: abi.encodeCall(CoreUpgradeExecutor.validateUpgradeApplied, (ICoreTransition(_in.coreTransition)))
        });
        calls[1] = Call({
            target: _in.coreUpgradeExecutor,
            value: 0,
            data: abi.encodeCall(CoreUpgradeExecutor.setCoordinator, (_in.coordinator))
        });
        calls[2] = Call({
            target: _in.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        });
        // CTM prepare.
        calls[3] = Call({
            target: _in.coordinator,
            value: 0,
            data: abi.encodeCall(EcosystemUpgradeExecutor.setCTMExecutor, (ICTMUpgradeExecutor(_in.ctmUpgradeExecutor)))
        });
        calls[4] = Call({
            target: _in.bootstrapMigration,
            value: 0,
            data: abi.encodeCall(RegistryBootstrapMigration.validateApplied, ())
        });
    }

    function _pause(address _chainAssetHandler) private pure returns (Call memory) {
        return
            Call({
                target: _chainAssetHandler,
                value: 0,
                data: abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
            });
    }
}
