// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {IL2GenesisUpgrade} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_GENESIS_UPGRADE_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, L2_NTV_BEACON_DEPLOYER_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_CENTER_ADDR, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {UpgradeableBeaconDeployer} from "contracts/bridge/UpgradeableBeaconDeployer.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";
import {SystemContractsArgs} from "./L2Utils.sol";
import {Create2FactoryUtils} from "deploy-scripts/utils/deploy/Create2FactoryUtils.s.sol";
import {L2GenesisUpgradeTestHelper, BytecodeNames, ContractName} from "./L2GenesisUpgradeTestHelper.sol";
import {ChainCreationParamsConfig} from "deploy-scripts/utils/Types.sol";
import {DeployCTMUtils} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

contract L2GenesisUpgradeTest is Test, SharedL2ContractDeployer, SharedL2ContractL2Deployer {
    uint256 constant CHAIN_ID = 270;
    address ctmDeployerAddress = makeAddr("ctmDeployer");
    address bridgehubOwnerAddress = makeAddr("bridgehubOwner");

    bytes fixedForceDeploymentsData;
    bytes additionalForceDeploymentsData;

    L2GenesisUpgradeTestHelper testHelper;

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

        // Deploy the test helper contract (not as a library to work with zkfoundry)
        testHelper = new L2GenesisUpgradeTestHelper();
        BytecodeNames memory names = testHelper.getBytecodeNames();

        vm.store(
            L2_INTEROP_HANDLER_ADDR,
            bytes32(0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4),
            bytes32(uint256(0))
        );

        // Deploy and etch contracts (bytecode reading must be done in test, not helper contract)
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, _readL1(names.complexUpgrader));
        vm.etch(L2_GENESIS_UPGRADE_ADDR, _readL1(names.genesisUpgrade));
        vm.etch(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, _readSC(names.systemContext));
        vm.etch(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, _readL1(names.wrappedBaseToken));
        new UpgradeableBeaconDeployer();
        vm.etch(L2_NTV_BEACON_DEPLOYER_ADDR, _readL1(names.beaconDeployer));
        vm.etch(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, _readL1(names.systemContractProxyAdmin));

        additionalForceDeploymentsData = testHelper.getAdditionalForceDeploymentsData();
        fixedForceDeploymentsData = testHelper.getFixedForceDeploymentsData(
            CHAIN_ID,
            testHelper.buildBytecodeInfo(
                [
                    _hashL1(names.messageRoot),
                    _hashL1(names.l2Ntv),
                    _hashL1(names.l2AssetRouter),
                    _hashL1(names.bridgehub),
                    _hashL1(names.chainAssetHandler),
                    _hashL1(names.beaconDeployer),
                    _hashL1(names.interopCenter),
                    _hashL1(names.interopHandler),
                    _hashL1(names.assetTracker)
                ]
            )
        );

        testHelper.setupMockCalls(
            vm,
            L2_NATIVE_TOKEN_VAULT_ADDR,
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
    function _readL1(ContractName memory c) internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeL1(c.file, c.name);
    }

    function _readSC(ContractName memory c) internal view returns (bytes memory) {
        return Utils.readZKFoundryBytecodeSystemContracts(c.file, c.name);
    }

    function _hashL1(ContractName memory c) internal view returns (bytes memory) {
        return abi.encode(L2ContractHelper.hashL2Bytecode(_readL1(c)));
    }

    function getChainCreationParamsConfig(
        string memory _config
    ) internal override(DeployCTMUtils, SharedL2ContractL2Deployer) returns (ChainCreationParamsConfig memory) {
        return SharedL2ContractL2Deployer.getChainCreationParamsConfig(_config);
    }
}
