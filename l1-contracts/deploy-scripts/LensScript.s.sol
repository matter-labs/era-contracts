// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IStateTransitionManager} from "../contracts/state-transition/IStateTransitionManager.sol";
import {StateTransitionManager} from "../contracts/state-transition/StateTransitionManager.sol";
import {IBridgehub} from "../contracts/bridgehub/IBridgehub.sol";
import {IGovernance} from "../contracts/governance/IGovernance.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {TransitionaryOwner} from "../contracts/governance/TransitionaryOwner.sol";
import {IAdmin} from "../contracts/state-transition/chain-interfaces/IAdmin.sol";
import {Diamond} from "../contracts/state-transition/libraries/Diamond.sol";
import {Migrator, MigrationParams} from "../contracts/upgrades/Migrator.sol";
import {IGetters} from "../contracts/state-transition/chain-interfaces/IGetters.sol";

struct Config {
    uint256 lensChainId;
    address lensDiamondProxy;
    address baseToken;
    address tempProxyAdmin;
    address tempBridgehub;
    address tempStateTransitionManager;
    address tempValidatorTimelock;
    address tempL1SharedBridge;
    address tempErc20Bridge;
    address newStateTransitionManager;
    address newBridgehub;
    address newProxyAdmin;
    address newValidatorTimelock;
    address newVerifier;
}

contract LensScript is Script {
    using stdToml for string;

    bytes32 public constant PROXY_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    Config public config;

    IGovernance.Call[] internal calls;
    bytes public tempEcoScheduleOperation;
    bytes public tempEcoExecuteOperation;
    bytes public vtOwnershipCall;

    address public migrationUpgradeAddress;

    address public transitionaryOwner;

    function setMigrationUpgradeAddress(address _migrationUpgradeAddress) external {
        migrationUpgradeAddress = _migrationUpgradeAddress;
    }

    function setTransitionaryOwner(address _transitionaryOwner) external {
        transitionaryOwner = _transitionaryOwner;
    }

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
        // _printTempGovernanceScheduleOperation();
        // _printTempGovernanceExecuteOperation();
        // _printMigrationExecuteUpgradeCall();
    }

    function _initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/lens-migration.toml");
        string memory toml = vm.readFile(path);

        // migrationUpgradeAddress = toml.readAddress("$.migration_upgrade_address");
        // transitionaryOwner = toml.readAddress("$.transitionary_owner");

        config.tempStateTransitionManager = toml.readAddress("$.temp_ecosystem.stm");
        config.tempBridgehub = IStateTransitionManager(config.tempStateTransitionManager).BRIDGE_HUB();
        config.tempProxyAdmin = address(uint160(uint256(vm.load(config.tempBridgehub, PROXY_ADMIN_SLOT))));
        config.tempValidatorTimelock = StateTransitionManager(config.tempStateTransitionManager).validatorTimelock();

        config.tempL1SharedBridge = address(IBridgehub(config.tempBridgehub).sharedBridge());
        config.tempErc20Bridge = toml.readAddress("$.temp_ecosystem.erc20_bridge");

        config.newStateTransitionManager = toml.readAddress("$.canonical_ecosystem.stm");
        config.newBridgehub = IStateTransitionManager(config.newStateTransitionManager).BRIDGE_HUB();
        config.newProxyAdmin = address(uint160(uint256(vm.load(config.newBridgehub, PROXY_ADMIN_SLOT))));
        config.newValidatorTimelock = toml.readAddress("$.canonical_ecosystem.validator_timelock");
        config.newVerifier = toml.readAddress("$.canonical_ecosystem.verifier");

        config.lensChainId = toml.readUint("$.lens_chain_id");
        config.lensDiamondProxy = IStateTransitionManager(config.tempStateTransitionManager).getHyperchain(
            config.lensChainId
        );
        config.baseToken = IGetters(config.lensDiamondProxy).getBaseToken();

        console.log("Config:");
        console.log("lensChainId:", config.lensChainId);
        console.log("lensDiamondProxy:", config.lensDiamondProxy);
        console.log("baseToken:", config.baseToken);
        console.log("migrationUpgradeAddress:", migrationUpgradeAddress);
        console.log("transitionaryOwner:", transitionaryOwner);

        console.log("tempStateTransitionManager:", config.tempStateTransitionManager);
        console.log("tempBridgehub:", config.tempBridgehub);
        console.log("tempProxyAdmin:", config.tempProxyAdmin);
        console.log("tempValidatorTimelock:", config.tempValidatorTimelock);

        console.log("tempL1SharedBridge:", config.tempL1SharedBridge);
        console.log("tempErc20Bridge:", config.tempErc20Bridge);

        console.log("newStateTransitionManager:", config.newStateTransitionManager);
        console.log("newBridgehub:", config.newBridgehub);
        console.log("newProxyAdmin:", config.newProxyAdmin);
        console.log("newValidatorTimelock:", config.newValidatorTimelock);
        console.log("newVerifier:", config.newVerifier);
        console.log();
    }

    function _generateTempEcoOwnershipCalls() internal {
        IGovernance.Call[] memory tempEcoOwnershipCalls = new IGovernance.Call[](11);
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

        // proxy admin - l1 shared bridge
        tempEcoOwnershipCalls[2] = IGovernance.Call({
            target: config.tempProxyAdmin,
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.changeProxyAdmin,
                (ITransparentUpgradeableProxy(config.tempL1SharedBridge), config.newProxyAdmin)
            )
        });

        // proxy admin - erc20 bridge
        tempEcoOwnershipCalls[3] = IGovernance.Call({
            target: config.tempProxyAdmin,
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.changeProxyAdmin,
                (ITransparentUpgradeableProxy(config.tempErc20Bridge), config.newProxyAdmin)
            )
        });

        // bridgehub - transfer ownership
        tempEcoOwnershipCalls[4] = IGovernance.Call({
            target: config.tempBridgehub,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (transitionaryOwner))
        });

        // state transition manager - transfer ownership
        tempEcoOwnershipCalls[5] = IGovernance.Call({
            target: config.tempStateTransitionManager,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (transitionaryOwner))
        });

        // validator timelock - transfer ownership
        vtOwnershipCall = abi.encodeWithSelector(Ownable2Step.transferOwnership.selector, transitionaryOwner);

        // IGovernance.Call({
        //     target: config.tempValidatorTimelock,
        //     value: 0,
        //     data: abi.encodeCall(Ownable2Step.transferOwnership, (transitionaryOwner))
        // });

        // l1 shared bridge - transfer ownership
        tempEcoOwnershipCalls[6] = IGovernance.Call({
            target: config.tempL1SharedBridge,
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (transitionaryOwner))
        });

        // transitionary owner Accept and transfer ownership - bh
        tempEcoOwnershipCalls[7] = IGovernance.Call({
            target: transitionaryOwner,
            value: 0,
            data: abi.encodeCall(TransitionaryOwner.claimOwnershipAndGiveToGovernance, (config.tempBridgehub))
        });

        // transitionary owner Accept and transfer ownership - stm
        tempEcoOwnershipCalls[8] = IGovernance.Call({
            target: transitionaryOwner,
            value: 0,
            data: abi.encodeCall(
                TransitionaryOwner.claimOwnershipAndGiveToGovernance,
                (config.tempStateTransitionManager)
            )
        });

        // transitionary owner Accept and transfer ownership - vt
        tempEcoOwnershipCalls[9] = IGovernance.Call({
            target: transitionaryOwner,
            value: 0,
            data: abi.encodeCall(TransitionaryOwner.claimOwnershipAndGiveToGovernance, (config.tempValidatorTimelock))
        });

        // transitionary owner Accept and transfer ownership - l1 shared bridge
        tempEcoOwnershipCalls[10] = IGovernance.Call({
            target: transitionaryOwner,
            value: 0,
            data: abi.encodeCall(TransitionaryOwner.claimOwnershipAndGiveToGovernance, (config.tempL1SharedBridge))
        });

        tempEcoScheduleOperation = abi.encodeWithSelector(
            IGovernance.scheduleTransparent.selector,
            IGovernance.Operation({calls: tempEcoOwnershipCalls, predecessor: bytes32(0), salt: bytes32(0)}),
            0
        );

        tempEcoExecuteOperation = abi.encodeWithSelector(
            IGovernance.execute.selector,
            IGovernance.Operation({calls: tempEcoOwnershipCalls, predecessor: bytes32(0), salt: bytes32(0)})
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

        // l1 shared bridge
        calls.push(
            IGovernance.Call({
                target: config.tempL1SharedBridge,
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
                    (config.lensChainId, config.newStateTransitionManager, config.baseToken, uint256(0), address(0), "0x")
                )
            })
        );
    }

    function _generateExecuteUpgradeCall() internal {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        MigrationParams memory migrationParams = MigrationParams({
            newVerifier: config.newVerifier,
            newCTM: config.newStateTransitionManager,
            newValidatorTimelock: config.newValidatorTimelock
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: migrationUpgradeAddress,
            initCalldata: abi.encodeWithSelector(Migrator.upgrade.selector, migrationParams)
        });

        calls.push(
            IGovernance.Call({
                target: config.tempStateTransitionManager,
                value: 0,
                data: abi.encodeCall(IStateTransitionManager.executeUpgrade, (config.lensChainId, diamondCut))
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

    function govCalls() external view returns (IGovernance.Call[] memory) {
        return calls;
    }
}
