// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {L2GenesisUpgrade} from "contracts/l2-upgrades/L2GenesisUpgrade.sol";
import {IL2GenesisUpgrade, FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_GENESIS_UPGRADE_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_MESSAGE_ROOT_ADDR, L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, L2_NTV_BEACON_DEPLOYER_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_CENTER_ADDR, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {UpgradeableBeaconDeployer} from "contracts/bridge/UpgradeableBeaconDeployer.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";
import {SystemContractsArgs} from "./L2Utils.sol";
import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {Create2FactoryUtils} from "deploy-scripts/utils/deploy/Create2FactoryUtils.s.sol";
import {TokenMetadata, TokenBridgingData} from "contracts/common/Messaging.sol";
import {L2GenesisUpgradeTestHelper, BytecodeInfo} from "./L2GenesisUpgradeTestHelper.sol";
import {ChainCreationParamsConfig} from "deploy-scripts/utils/Types.sol";
import {DeployCTMUtils} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";

contract L2GenesisUpgradeTest is Test, SharedL2ContractDeployer, SharedL2ContractL2Deployer {
    using stdStorage for StdStorage;

    uint256 constant CHAIN_ID = 270;
    address ctmDeployerAddress = makeAddr("ctmDeployer");
    address bridgehubOwnerAddress = makeAddr("bridgehubOwner");

    bytes fixedForceDeploymentsData;
    bytes additionalForceDeploymentsData;

    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {}

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

    function setUp() public override {
        super.setUp();

        vm.store(
            L2_INTEROP_HANDLER_ADDR,
            bytes32(0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4),
            bytes32(uint256(0))
        );

        // Deploy and etch L2ComplexUpgrader
        bytes memory complexUpgraderCode = Utils.readZKFoundryBytecodeL1("L2ComplexUpgrader.sol", "L2ComplexUpgrader");
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, complexUpgraderCode);

        // Deploy and etch L2GenesisUpgrade
        bytes memory genesisUpgradeCode = Utils.readZKFoundryBytecodeL1("L2GenesisUpgrade.sol", "L2GenesisUpgrade");
        vm.etch(L2_GENESIS_UPGRADE_ADDR, genesisUpgradeCode);

        // Deploy and etch SystemContext
        bytes memory systemContextCode = Utils.readZKFoundryBytecodeSystemContracts(
            "SystemContext.sol",
            "SystemContext"
        );
        vm.etch(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, systemContextCode);

        // Deploy and etch L2WrappedBaseToken
        bytes memory wrappedBaseTokenCode = Utils.readZKFoundryBytecodeL1(
            "L2WrappedBaseToken.sol",
            "L2WrappedBaseToken"
        );
        vm.etch(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, wrappedBaseTokenCode);

        // Deploy and etch UpgradeableBeaconDeployer
        new UpgradeableBeaconDeployer();
        bytes memory upgradeableBeaconDeployerCode = Utils.readZKFoundryBytecodeL1(
            "UpgradeableBeaconDeployer.sol",
            "UpgradeableBeaconDeployer"
        );
        vm.etch(L2_NTV_BEACON_DEPLOYER_ADDR, upgradeableBeaconDeployerCode);

        // Deploy and etch SystemContractProxyAdmin
        bytes memory systemContractProxyAdminCode = Utils.readZKFoundryBytecodeL1(
            "SystemContractProxyAdmin.sol",
            "SystemContractProxyAdmin"
        );
        vm.etch(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, systemContractProxyAdminCode);

        additionalForceDeploymentsData = L2GenesisUpgradeTestHelper.getAdditionalForceDeploymentsData();
        BytecodeInfo memory bytecodeInfo = L2GenesisUpgradeTestHelper.getBytecodeInfo();
        fixedForceDeploymentsData = L2GenesisUpgradeTestHelper.getFixedForceDeploymentsData(CHAIN_ID, bytecodeInfo);

        L2GenesisUpgradeTestHelper.setupMockCalls(
            vm,
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            L2_BRIDGEHUB_ADDR,
            L2_ASSET_ROUTER_ADDR,
            L2_CHAIN_ASSET_HANDLER_ADDR,
            L2_INTEROP_CENTER_ADDR,
            L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR,
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
            L2_COMPLEX_UPGRADER_ADDR
        );
    }

    function test_SuccessfulGenesisUpgrade() public {
        bytes memory genesisUpgradeCalldata = abi.encodeWithSelector(
            IL2GenesisUpgrade.genesisUpgrade.selector,
            false, // _isZKsyncOS
            CHAIN_ID,
            ctmDeployerAddress,
            fixedForceDeploymentsData,
            additionalForceDeploymentsData
        );

        vm.expectEmit(true, false, false, true, L2_COMPLEX_UPGRADER_ADDR);
        emit IL2GenesisUpgrade.UpgradeComplete(CHAIN_ID);

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(L2_GENESIS_UPGRADE_ADDR, genesisUpgradeCalldata);
    }

    function getChainCreationParamsConfig(
        string memory _config
    ) internal override(DeployCTMUtils, SharedL2ContractL2Deployer) returns (ChainCreationParamsConfig memory) {
        return SharedL2ContractL2Deployer.getChainCreationParamsConfig(_config);
    }
}
