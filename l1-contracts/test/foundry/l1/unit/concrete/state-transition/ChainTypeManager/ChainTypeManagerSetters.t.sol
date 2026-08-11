// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {NotAVerifierOnlyUpgrade} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract ChainTypeManagerSetters is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    // setPriorityTxMaxGasLimit
    function test_SuccessfulSetPriorityTxMaxGasLimit() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        GettersFacet gettersFacet = GettersFacet(chainAddress);

        uint256 newMaxGasLimit = 1000;

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor); // In the ChainTypeManagerTest contract, governor is set as the owner of chainContractAddress
        chainContractAddress.setPriorityTxMaxGasLimit(chainId, newMaxGasLimit);

        uint256 maxGasLimit = gettersFacet.getPriorityTxMaxGasLimit();

        assertEq(maxGasLimit, newMaxGasLimit);
    }

    // setTokenMultiplier
    function test_SuccessfulSetTokenMultiplier() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        GettersFacet gettersFacet = GettersFacet(chainAddress);

        uint128 newNominator = 1;
        uint128 newDenominator = 1000;

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setTokenMultiplier(chainId, newNominator, newDenominator);

        uint128 nominator = gettersFacet.baseTokenGasPriceMultiplierNominator();
        uint128 denominator = gettersFacet.baseTokenGasPriceMultiplierDenominator();

        assertEq(newNominator, nominator);
        assertEq(newDenominator, denominator);
    }

    // changeFeeParams
    function test_SuccessfulChangeFeeParams() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        UtilsFacet utilsFacet = UtilsFacet(chainAddress);

        FeeParams memory newFeeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1_000_000,
            maxPubdataPerBatch: 120_000,
            maxL2GasPerBatch: 80_000_000,
            priorityTxMaxPubdata: 99_000,
            minimalL2GasPrice: 250_000_000
        });

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.changeFeeParams(chainId, newFeeParams);

        FeeParams memory feeParams = utilsFacet.util_getFeeParams();

        assertEq(feeParams.batchOverheadL1Gas, newFeeParams.batchOverheadL1Gas);
        assertEq(feeParams.maxPubdataPerBatch, newFeeParams.maxPubdataPerBatch);
        assertEq(feeParams.maxL2GasPerBatch, newFeeParams.maxL2GasPerBatch);
        assertEq(feeParams.priorityTxMaxPubdata, newFeeParams.priorityTxMaxPubdata);
        assertEq(feeParams.minimalL2GasPrice, newFeeParams.minimalL2GasPrice);
    }

    // setValidator
    function test_SuccessfulSetValidator() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        GettersFacet gettersFacet = GettersFacet(chainAddress);
        address new_validator = makeAddr("new_validator");

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setValidator(chainId, new_validator, true);

        bool isActive = gettersFacet.isValidator(new_validator);
        assertTrue(isActive);
    }

    // setPorterAvailability
    function test_SuccessfulSetPorterAvailability() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setPorterAvailability(chainId, true);

        bool isAvailable = utilsFacet.util_getZkPorterAvailability();
        assertTrue(isAvailable);
    }

    // setProtocolVersionVerifier - happy path by owner
    function test_SuccessfulSetProtocolVersionVerifierByOwner() public {
        uint256 protocolVersionToSet = 100;
        address newVerifier = makeAddr("newVerifier");

        vm.prank(governor);
        vm.expectEmit(true, true, true, true);
        emit IChainTypeManager.NewProtocolVersionVerifier(protocolVersionToSet, newVerifier);
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, newVerifier);

        address storedVerifier = chainContractAddress.protocolVersionVerifier(protocolVersionToSet);
        assertEq(storedVerifier, newVerifier);
    }

    // setProtocolVersionVerifier - unhappy path by admin
    function test_RevertWhen_SetProtocolVersionVerifierByAdmin() public {
        uint256 protocolVersionToSet = 200;
        address newVerifier = makeAddr("newVerifier");
        address ctmAdmin = makeAddr("ctmAdmin");

        vm.prank(governor);
        chainContractAddress.setPendingAdmin(ctmAdmin);

        vm.prank(ctmAdmin);
        chainContractAddress.acceptAdmin();

        vm.prank(ctmAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, newVerifier);
    }

    // setProtocolVersionVerifier - unhappy path (zero address)
    function test_RevertWhen_SetProtocolVersionVerifierWithZeroAddress() public {
        uint256 protocolVersionToSet = 100;

        vm.prank(governor);
        vm.expectRevert(ZeroAddress.selector);
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, address(0));
    }

    // setProtocolVersionVerifier - unhappy path (unauthorized)
    function test_RevertWhen_SetProtocolVersionVerifierUnauthorized() public {
        uint256 protocolVersionToSet = 100;
        address newVerifier = makeAddr("newVerifier");
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, newVerifier);
    }

    // setProtocolVersionVerifier - can overwrite existing verifier
    function test_CanOverwriteExistingProtocolVersionVerifier() public {
        uint256 protocolVersionToSet = 400;
        address firstVerifier = makeAddr("firstVerifier");
        address secondVerifier = makeAddr("secondVerifier");

        vm.startPrank(governor);
        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, firstVerifier);
        assertEq(chainContractAddress.protocolVersionVerifier(protocolVersionToSet), firstVerifier);

        chainContractAddress.setProtocolVersionVerifier(protocolVersionToSet, secondVerifier);
        assertEq(chainContractAddress.protocolVersionVerifier(protocolVersionToSet), secondVerifier);
        vm.stopPrank();
    }

    // setDefaultUpgrade - happy path
    function test_SuccessfulSetDefaultUpgrade() public {
        address firstDefaultUpgrade = makeAddr("firstDefaultUpgrade");
        address secondDefaultUpgrade = makeAddr("secondDefaultUpgrade");

        vm.prank(governor);
        vm.expectEmit(true, true, true, true);
        emit IChainTypeManager.NewDefaultUpgrade(address(0), firstDefaultUpgrade);
        chainContractAddress.setDefaultUpgrade(firstDefaultUpgrade);
        assertEq(chainContractAddress.defaultUpgrade(), firstDefaultUpgrade);

        vm.prank(governor);
        vm.expectEmit(true, true, true, true);
        emit IChainTypeManager.NewDefaultUpgrade(firstDefaultUpgrade, secondDefaultUpgrade);
        chainContractAddress.setDefaultUpgrade(secondDefaultUpgrade);
        assertEq(chainContractAddress.defaultUpgrade(), secondDefaultUpgrade);
    }

    // setDefaultUpgrade - unhappy path (zero address)
    function test_RevertWhen_SetDefaultUpgradeWithZeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(ZeroAddress.selector);
        chainContractAddress.setDefaultUpgrade(address(0));
    }

    // setDefaultUpgrade - unhappy path (unauthorized)
    function test_RevertWhen_SetDefaultUpgradeUnauthorized() public {
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setDefaultUpgrade(makeAddr("defaultUpgrade"));
    }

    // createNewVerifierOnlyUpgrade - happy path (patch version bump)
    function test_SuccessfulCreateNewVerifierOnlyUpgradePatchVersion() public {
        // Pack protocol versions: 0.25.0 -> 0.25.1 (patch upgrade)
        uint256 oldProtocolVersion = SemVer.packSemVer(0, 25, 0);
        uint256 newProtocolVersion = SemVer.packSemVer(0, 25, 1);
        uint256 oldProtocolVersionDeadline = block.timestamp + 1 days;
        address newVerifier = makeAddr("verifierOnlyVerifier");
        address upgradeContract = _setDefaultUpgrade();

        _advanceProtocolVersionTo(oldProtocolVersion);

        vm.prank(governor);
        vm.expectEmit(true, true, true, true);
        emit IChainTypeManager.NewProtocolVersion(oldProtocolVersion, newProtocolVersion);
        chainContractAddress.createNewVerifierOnlyUpgrade(
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion,
            newVerifier
        );

        // Verify the new protocol version is set
        assertEq(chainContractAddress.protocolVersion(), newProtocolVersion);
        // Verify the verifier is set for the new protocol version
        assertEq(chainContractAddress.protocolVersionVerifier(newProtocolVersion), newVerifier);
        // Verify the upgrade cut runs the stored default upgrade contract with an otherwise empty upgrade
        assertEq(
            chainContractAddress.upgradeCutHash(oldProtocolVersion),
            _expectedVerifierOnlyCutHash(upgradeContract, newProtocolVersion)
        );
        // Verify the old protocol version deadline is set
        assertEq(chainContractAddress.protocolVersionDeadline(oldProtocolVersion), oldProtocolVersionDeadline);
    }

    // createNewVerifierOnlyUpgrade - happy path (minor version bump)
    function test_SuccessfulCreateNewVerifierOnlyUpgradeMinorVersion() public {
        // Pack protocol versions: 0.25.1 -> 0.26.0 (minor upgrade)
        uint256 oldProtocolVersion = SemVer.packSemVer(0, 25, 1);
        uint256 newProtocolVersion = SemVer.packSemVer(0, 26, 0);
        uint256 oldProtocolVersionDeadline = block.timestamp + 1 days;
        address newVerifier = makeAddr("verifierOnlyVerifier");
        address upgradeContract = _setDefaultUpgrade();

        _advanceProtocolVersionTo(oldProtocolVersion);

        vm.prank(governor);
        vm.expectEmit(true, true, true, true);
        emit IChainTypeManager.NewProtocolVersion(oldProtocolVersion, newProtocolVersion);
        chainContractAddress.createNewVerifierOnlyUpgrade(
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion,
            newVerifier
        );

        assertEq(chainContractAddress.protocolVersion(), newProtocolVersion);
        assertEq(chainContractAddress.protocolVersionVerifier(newProtocolVersion), newVerifier);
        assertEq(
            chainContractAddress.upgradeCutHash(oldProtocolVersion),
            _expectedVerifierOnlyCutHash(upgradeContract, newProtocolVersion)
        );
    }

    // createNewVerifierOnlyUpgrade - revert when major version changes
    function test_RevertWhen_CreateNewVerifierOnlyUpgradeMajorVersionChanges() public {
        // Pack protocol versions: 0.25.0 -> 1.25.0 (major upgrade)
        uint256 oldProtocolVersion = SemVer.packSemVer(0, 25, 0);
        uint256 newProtocolVersion = SemVer.packSemVer(1, 25, 0);
        uint256 oldProtocolVersionDeadline = block.timestamp + 1 days;
        address newVerifier = makeAddr("verifierOnlyVerifier");
        _setDefaultUpgrade();

        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(NotAVerifierOnlyUpgrade.selector, oldProtocolVersion, newProtocolVersion)
        );
        chainContractAddress.createNewVerifierOnlyUpgrade(
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion,
            newVerifier
        );
    }

    // createNewVerifierOnlyUpgrade - revert when the new version does not increase
    function test_RevertWhen_CreateNewVerifierOnlyUpgradeVersionNotIncreased() public {
        // Pack protocol versions: 0.25.2 -> 0.25.2 (no version change at all)
        uint256 oldProtocolVersion = SemVer.packSemVer(0, 25, 2);
        uint256 oldProtocolVersionDeadline = block.timestamp + 1 days;
        address newVerifier = makeAddr("verifierOnlyVerifier");
        _setDefaultUpgrade();

        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(NotAVerifierOnlyUpgrade.selector, oldProtocolVersion, oldProtocolVersion)
        );
        chainContractAddress.createNewVerifierOnlyUpgrade(
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            oldProtocolVersion,
            newVerifier
        );

        // Pack protocol versions: 0.25.2 -> 0.24.3 (minor version goes backwards)
        uint256 lowerProtocolVersion = SemVer.packSemVer(0, 24, 3);
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(NotAVerifierOnlyUpgrade.selector, oldProtocolVersion, lowerProtocolVersion)
        );
        chainContractAddress.createNewVerifierOnlyUpgrade(
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            lowerProtocolVersion,
            newVerifier
        );
    }

    // createNewVerifierOnlyUpgrade - revert when the default upgrade contract is not set
    function test_RevertWhen_CreateNewVerifierOnlyUpgradeWithoutDefaultUpgrade() public {
        uint256 oldProtocolVersion = SemVer.packSemVer(0, 25, 0);
        uint256 newProtocolVersion = SemVer.packSemVer(0, 25, 1);
        uint256 oldProtocolVersionDeadline = block.timestamp + 1 days;
        address newVerifier = makeAddr("verifierOnlyVerifier");

        vm.prank(governor);
        vm.expectRevert(ZeroAddress.selector);
        chainContractAddress.createNewVerifierOnlyUpgrade(
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion,
            newVerifier
        );
    }

    // createNewVerifierOnlyUpgrade - revert when not owner
    function test_RevertWhen_CreateNewVerifierOnlyUpgradeUnauthorized() public {
        uint256 oldProtocolVersion = SemVer.packSemVer(0, 25, 0);
        uint256 newProtocolVersion = SemVer.packSemVer(0, 25, 1);
        uint256 oldProtocolVersionDeadline = block.timestamp + 1 days;
        address newVerifier = makeAddr("verifierOnlyVerifier");
        address randomUser = makeAddr("randomUser");
        _setDefaultUpgrade();

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.createNewVerifierOnlyUpgrade(
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion,
            newVerifier
        );
    }

    /// @dev Deploys an upgrade contract and stores it in the CTM as the default one.
    function _setDefaultUpgrade() private returns (address defaultUpgrade) {
        defaultUpgrade = address(new DefaultUpgrade());
        vm.prank(governor);
        chainContractAddress.setDefaultUpgrade(defaultUpgrade);
    }

    /// @dev Moves the CTM's protocolVersion from the initial `0` to `_protocolVersion` with an empty upgrade,
    /// so that a verifier-only upgrade on top of it has the correct base.
    function _advanceProtocolVersionTo(uint256 _protocolVersion) private {
        _mockMigrationPausedFromBridgehub();

        Diamond.DiamondCutData memory emptyCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: ""
        });
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(
            emptyCut,
            0,
            block.timestamp + 1 days,
            _protocolVersion,
            testnetVerifier
        );
    }

    /// @dev The diamond cut a verifier-only upgrade is expected to store: no facet changes, the stored default
    /// upgrade contract and an otherwise empty upgrade.
    function _expectedVerifierOnlyCutHash(
        address _defaultUpgrade,
        uint256 _newProtocolVersion
    ) private pure returns (bytes32) {
        Diamond.DiamondCutData memory expectedCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: _defaultUpgrade,
            initCalldata: abi.encodeCall(
                IDefaultUpgrade.upgrade,
                (ProposedUpgradeLib.emptyProposedUpgrade(_newProtocolVersion))
            )
        });
        return keccak256(abi.encode(expectedCut));
    }

    // deactivatePriorityMode
    function test_SuccessfulDeactivatePriorityMode() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);

        utilsFacet.util_setPriorityModeActivated(true);
        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.deactivatePriorityMode(chainId);

        assertFalse(utilsFacet.util_getPriorityModeActivated());
    }
}
