// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";

import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";
import {UserActorHandler} from "../handlers/UserActorHandler.sol";

import {AssetRouterProperties} from "../AssetRouterProperties.sol";
import {SharedL2ContractL2DeployerUtils, SystemContractsArgs} from
    "../../foundry/l2/integration/_SharedL2ContractL2DeployerUtils.sol";
import {SharedL2ContractL1DeployerUtils} from
    "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractL1DeployerUtils.sol";
import {SharedL2ContractDeployer} from "../../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

contract AssetRouterTest is Test, SharedL2ContractL2DeployerUtils, SharedL2ContractDeployer, AssetRouterProperties {
    function test() internal virtual override(DeployUtils, SharedL2ContractL2DeployerUtils) {}

    function initSystemContracts(SystemContractsArgs memory _args)
        internal
        virtual
        override(SharedL2ContractDeployer, SharedL2ContractL2DeployerUtils)
    {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(DeployUtils, SharedL2ContractL2DeployerUtils) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(uint256 _l1ChainId)
        public
        virtual
        override(SharedL2ContractDeployer, SharedL2ContractL1DeployerUtils)
    {
        super.deployL2Contracts(_l1ChainId);

        userActorHandlers.push(new UserActorHandler());
        l1AssetRouterActorHandler = new L1AssetRouterActorHandler(userActorHandlers);
        for (uint256 i; i < userActorHandlers.length; i++) {
            targetContract(address(userActorHandlers[i]));
        }
        targetContract(address(l1AssetRouterActorHandler));

        address ts = makeAddr("targetSender");
        deal(ts, 10_000 ether);
        targetSender(ts);
    }

    function test_nothing() public {
        assertTrue(true);
    }
}
