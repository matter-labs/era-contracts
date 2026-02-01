// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {SystemContractsArgs} from "./L2Utils.sol";

import {L2NativeTokenVaultBridgeBurnRegressionTestAbstract} from "../../l1/integration/l2-tests-abstract/L2NativeTokenVaultBridgeBurnRegressionTestAbstract.t.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {Create2FactoryUtils} from "deploy-scripts/utils/deploy/Create2FactoryUtils.s.sol";
import {ChainCreationParamsConfig} from "deploy-scripts/utils/Types.sol";
import {DeployCTMUtils} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";

contract L2NativeTokenVaultBridgeBurnRegressionTest is
    Test,
    SharedL2ContractL2Deployer,
    L2NativeTokenVaultBridgeBurnRegressionTestAbstract
{
    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {}

    function getChainCreationParamsConfig(
        string memory _config
    ) internal override(DeployCTMUtils, SharedL2ContractL2Deployer) returns (ChainCreationParamsConfig memory) {
        return SharedL2ContractL2Deployer.getChainCreationParamsConfig(_config);
    }

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(Create2FactoryUtils, SharedL2ContractL2Deployer) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public override(SharedL2ContractL2Deployer, SharedL2ContractDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        return super.getCreationCode(contractName, false);
    }

    /// @notice Skip this test in L2 (zkfoundry) context because stdstore doesn't work with ZK bytecode
    /// @dev The test is verified in L1 context (L2NativeTokenVaultBridgeBurnRegressionL1Test)
    function test_regression_bridgeBurnRegularBridgedTokenStillCallsBridgeBurn() external override {
        vm.skip(true);
    }

    /// @notice Skip this test in L2 (zkfoundry) context because system contracts don't work properly
    /// @dev The test is verified in L1 context (L2NativeTokenVaultBridgeBurnRegressionL1Test)
    function test_regression_bridgeBurnBaseTokenAsBridgedTokenCallsBurnMsgValue() external override {
        vm.skip(true);
    }

    /// @notice Skip this test in L2 (zkfoundry) context because system contracts don't work properly
    /// @dev The test is verified in L1 context (L2NativeTokenVaultBridgeBurnRegressionL1Test)
    function testFuzz_regression_bridgeBurnBaseTokenVariousAmounts(uint256) external override {
        vm.skip(true);
    }
}
