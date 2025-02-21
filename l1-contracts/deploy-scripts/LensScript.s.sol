// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IStateTransitionManager} from "../contracts/state-transition/IStateTransitionManager.sol";
import {IBridgehub} from "../contracts/bridgehub/IBridgehub.sol";
import {IGovernance} from "../contracts/governance/IGovernance.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {TransitionaryOwner} from "../contracts/governance/TransitionaryOwner.sol";
import {IAdmin} from "../contracts/state-transition/chain-interfaces/IAdmin.sol";
import {Diamond} from "../contracts/state-transition/libraries/Diamond.sol";
import {MigrationParams} from "../contracts/upgrades/Migrator.sol";

contract LensScript is Script {
    using stdToml for string;

    struct Config {
        uint256 lensChainId;
        address lensDiamondProxy;
        address baseToken;

        address tempProxyAdmin;
        address tempBridgehub;
        address tempStateTransitionManager;
        address tempValidatorTimelock;

        address newStateTransitionManager;
        address newBridgehub;
        address newProxyAdmin;
        address newValidatorTimelock;
        address newVerifier;
    }

    Config public config;

    IGovernance.Call[] public calls;
    bytes public tempEcoScheduleOperation;
    bytes public tempEcoExecuteOperation;

    address public migrationUpgradeAddress;

    address public transitionaryOwner;

    function run() external {
        _initializeConfig();
        // generate call for transitionary owner to transfer ownership
        // create gov ops to transfer ownership of temp contracts to transitionary owner
        //  - schedule
        //  - execute
        _generateTempEcoOwnershipCalls();
        // generate call to accept ownership
        _generateAcceptOwnershipCalls();
        // register chain with stm
        _generateRegisterChainCall();
        // create chain with bh
        _generateCreateChainCall();
        // execute upgrade on lens diamond
        _generateExecuteUpgradeCall();

        // print generated calldata
        _printTempGovernanceScheduleOperation();
        _printTempGovernanceExecuteOperation();
        _printMigrationExecuteUpgradeCall();
    }

    function _initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/lens-migration.toml");
        string memory toml = vm.readFile(path);
        
        config.lensChainId = toml.readUint("$.lens_chain_id");
        config.lensDiamondProxy = toml.readAddress("$.lens_diamond_proxy");
        config.baseToken = toml.readAddress("$.base_token");

        migrationUpgradeAddress = toml.readAddress("$.migration_upgrade_address");
        transitionaryOwner = toml.readAddress("$.transitionary_owner");

        config.tempProxyAdmin = toml.readAddress("$.temp_ecosystem.proxy_admin");
        config.tempBridgehub = toml.readAddress("$.temp_ecosystem.bridgehub");
        config.tempStateTransitionManager = toml.readAddress("$.temp_ecosystem.stm");
        config.tempValidatorTimelock = toml.readAddress("$.temp_ecosystem.validator_timelock");

        config.newProxyAdmin = toml.readAddress("$.canonical_ecosystem.proxy_admin");
        config.newBridgehub = toml.readAddress("$.canonical_ecosystem.bridgehub");
        config.newStateTransitionManager = toml.readAddress("$.canonical_ecosystem.stm");
        config.newValidatorTimelock = toml.readAddress("$.canonical_ecosystem.validator_timelock");
        config.newVerifier = toml.readAddress("$.canonical_ecosystem.verifier");
    }

    function _generateTempEcoOwnershipCalls() internal {
        IGovernance.Call[] memory tempEcoOwnershipCalls = new IGovernance.Call[](8);
        // proxy admin - bh
        tempEcoOwnershipCalls[0] = IGovernance.Call({
            target: config.tempProxyAdmin,
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.changeProxyAdmin,
                (ITransparentUpgradeableProxy(config.tempBridgehub), config.newProxyAdmin)
            )
        });

        // proxy admin - stm
        tempEcoOwnershipCalls[1] = IGovernance.Call({
            target: config.tempProxyAdmin,
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.changeProxyAdmin,
                (ITransparentUpgradeableProxy(config.tempStateTransitionManager), config.newProxyAdmin)
            )
        });

        // bridgehub - transfer ownership
        tempEcoOwnershipCalls[2] = IGovernance.Call({
            target: config.tempBridgehub,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (transitionaryOwner))
        });

        // state transition manager - transfer ownership
        tempEcoOwnershipCalls[3] = IGovernance.Call({
            target: config.tempStateTransitionManager,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (transitionaryOwner))
        });

        // validator timelock - transfer ownership
        tempEcoOwnershipCalls[4] = IGovernance.Call({
            target: config.tempValidatorTimelock,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (transitionaryOwner))
        });

        // transitionary owner Accept and transfer ownership - bh
        tempEcoOwnershipCalls[5] = IGovernance.Call({
            target: transitionaryOwner,
            value: 0,
            data: abi.encodeCall(TransitionaryOwner.claimOwnershipAndGiveToGovernance, (config.tempBridgehub))
        });

        // transitionary owner Accept and transfer ownership - stm
        tempEcoOwnershipCalls[6] = IGovernance.Call({
            target: transitionaryOwner,
            value: 0,
            data: abi.encodeCall(
                TransitionaryOwner.claimOwnershipAndGiveToGovernance,
                (config.tempStateTransitionManager)
            )
        });

        // transitionary owner Accept and transfer ownership - vt
        tempEcoOwnershipCalls[7] = IGovernance.Call({
            target: transitionaryOwner,
            value: 0,
            data: abi.encodeCall(TransitionaryOwner.claimOwnershipAndGiveToGovernance, (config.tempValidatorTimelock))
        });

        tempEcoScheduleOperation = abi.encodeWithSelector(
            IGovernance.scheduleTransparent.selector,
            IGovernance.Operation({
                calls: tempEcoOwnershipCalls,
                predecessor: bytes32(0),
                salt: bytes32(0)
            })
        );
        
        tempEcoExecuteOperation = abi.encodeWithSelector(
            IGovernance.execute.selector,
            IGovernance.Operation({
                calls: tempEcoOwnershipCalls,
                predecessor: bytes32(0),
                salt: bytes32(0)
            })
        );
    }

    function _generateAcceptOwnershipCalls() internal {
        // bh
        calls.push(
            IGovernance.Call({
                target: config.tempBridgehub,
                value: 0,
                data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
            })
        );

        // stm
        calls.push(
            IGovernance.Call({
                target: config.tempStateTransitionManager,
                value: 0,
                data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
            })
        );

        // vt
        calls.push(
            IGovernance.Call({
                target: config.tempValidatorTimelock,
                value: 0,
                data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
            })
        );
    }

    function _generateRegisterChainCall() internal {
        calls.push(
            IGovernance.Call({
                target: config.newStateTransitionManager,
                value: 0,
                data: abi.encodeCall(
                    IStateTransitionManager.registerAlreadyDeployedHyperchain,
                    (config.lensChainId, config.lensDiamondProxy)
                )
            })
        );
    }

    function _generateCreateChainCall() internal {
        calls.push(
            IGovernance.Call({
                target: config.newBridgehub,
                value: 0,
                data: abi.encodeCall(
                    IBridgehub.createNewChain,
                    (
                        config.lensChainId,
                        config.lensDiamondProxy,
                        config.baseToken,
                        uint256(0),
                        address(0),
                        "0x"
                    )
                )
            })
        );
    }

    function _generateExecuteUpgradeCall() internal {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        MigrationParams memory migrationParams = MigrationParams({
            newVerifier: config.newVerifier,
            newCTM: config.newStateTransitionManager,
            newBridgehub: config.newBridgehub
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: migrationUpgradeAddress,
            initCalldata: abi.encode(migrationParams)
        });

        calls.push(
            IGovernance.Call({
                target: config.lensDiamondProxy,
                value: 0,
                data: abi.encodeCall(IAdmin.executeUpgrade, (diamondCut))
            })
        );
    }

    function _printTempGovernanceScheduleOperation() internal view {
        console.log("Temp Governance Schedule Operation:");
        console.logBytes(tempEcoScheduleOperation);
        console.log();
    }

    function _printTempGovernanceExecuteOperation() internal view {
        console.log("Temp Governance Execute Operation:");
        console.logBytes(tempEcoExecuteOperation);
        console.log();
    }

    function _printMigrationExecuteUpgradeCall() internal view {
        console.log("Migration Execute Upgrade Call:");

        for (uint256 i = 0; i < calls.length; ++i) {
            console.log(calls[i].target);
            console.log(calls[i].value);
            console.logBytes(calls[i].data);
            console.log();
        }
    }
}

// todo
// do we need to add a call to add the new validator to the validator timelock?