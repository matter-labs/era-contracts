// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2} from "forge-std/Script.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {EmergencyStageUpgradeCalldata} from "./EmergencyStageUpgradeCalldata.s.sol";

/// @notice One-off emergency proposal for the stage Era v31 RollupDAManager misconfiguration.
///
/// The v31 Era AdminFacet was generated with ROLLUP_DA_MANAGER =
/// 0x064ac968CCad1948fceE025fD59c20b153c88072, which has no code on Sepolia and
/// cannot be deployed deterministically after the fact. The replacement
/// RollupDAManager and AdminFacet are already deployed and verified. The proposal
/// accepts RollupDAManager ownership,
/// configures the allowed DA pairs, patches already-upgraded Era chains, and
/// replaces the Era CTM stored v31 upgrade cut and chain creation params for
/// chains still upgrading from 0.29.4 or created after the fix.
contract EmergencyEraV31RollupDAManagerFix is EmergencyStageUpgradeCalldata {
    address internal constant ERA_CTM = 0x8b448ac7cd0f18F3d8464E2645575772a26A3b6b;
    address internal constant BAD_ERA_ROLLUP_DA_MANAGER = 0x064ac968CCad1948fceE025fD59c20b153c88072;
    address internal constant BAD_ERA_ADMIN_FACET = 0x8Fe736996d140f81d912c9B866111DfcEf3B735e;
    address internal constant NEW_ERA_ROLLUP_DA_MANAGER = 0x5af0d94e50b271005AF1687e363FD104771EAe9d;
    address internal constant NEW_ERA_ADMIN_FACET = 0xb1831AA09c7095554DE4CEF9e5b2Be74870cB553;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant ERA_OLD_PROTOCOL_VERSION = 0x1d00000004; // 0.29.4
    uint256 internal constant V31_PROTOCOL_VERSION = 0x1f00000000; // 0.31.0

    uint256 internal constant CHAIN_STAGE_VALIDIUM = 6475;
    uint256 internal constant CHAIN_STAGE_PROOFS = 499;
    uint256 internal constant CHAIN_LENS = 37111;
    uint256 internal constant IS_PERMANENT_ROLLUP_SLOT = 57;

    // The default Era rollup validator from the generated v31 Era artifact.
    address internal constant DEFAULT_ERA_ROLLUP_L1_DA_VALIDATOR = 0xF9a241A3821BEBE1324FBBC79A3aD60efdfF6ACe;
    // Stage-proofs (499) explicit rollup validator supplied for the fix.
    address internal constant STAGE_PROOFS_ROLLUP_L1_DA_VALIDATOR = 0xCc46b186bD4515Fa996AdF3c40344Ed7D546A65b;
    L2DACommitmentScheme internal constant ERA_ROLLUP_SCHEME = L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256;

    function runAddresses() external pure {
        console2.log("New Era RollupDAManager:", NEW_ERA_ROLLUP_DA_MANAGER);
        console2.log("New Era AdminFacet:", NEW_ERA_ADMIN_FACET);
        console2.log("PUH / Era CTM owner:", address(PUH));
    }

    /// @notice Emits the approveHash txs and final EmergencyUpgradeBoard calldata.
    function runCalldata() external view {
        _checkEmergencyPreconditions(NEW_ERA_ROLLUP_DA_MANAGER, NEW_ERA_ADMIN_FACET);

        IProtocolUpgradeHandler.Call[] memory calls = buildCalls();

        console2.log("New Era RollupDAManager:", NEW_ERA_ROLLUP_DA_MANAGER);
        console2.log("New Era AdminFacet:", NEW_ERA_ADMIN_FACET);
        console2.log("Allowed pair 1:", DEFAULT_ERA_ROLLUP_L1_DA_VALIDATOR);
        console2.log("Allowed pair 2:", STAGE_PROOFS_ROLLUP_L1_DA_VALIDATOR);
        console2.log("Allowed scheme:", uint8(ERA_ROLLUP_SCHEME));
        console2.log("Admin replacement cut hash:");
        console2.logBytes32(keccak256(abi.encode(_adminFacetReplacementCut(NEW_ERA_ADMIN_FACET))));
        console2.log("Corrected full v31 upgrade cut hash:");
        console2.logBytes32(keccak256(abi.encode(_correctedEraV31Cut(NEW_ERA_ADMIN_FACET))));
        console2.log("Corrected chain creation initial cut hash:");
        console2.logBytes32(keccak256(abi.encode(_correctedEraChainCreationParams(NEW_ERA_ADMIN_FACET).diamondCut)));

        _emitForCalls(calls, "ERA V31 ROLLUP DA MANAGER FIX");
    }

    /// @notice Executes the proposal on the local fork, then verifies affected-chain postconditions.
    /// @dev This is a local simulation helper only. Do not run with --broadcast.
    function runForkSimulation() external {
        _checkEmergencyPreconditions(NEW_ERA_ROLLUP_DA_MANAGER, NEW_ERA_ADMIN_FACET);
        _assertStageProofsSetDAPairFailsBeforeFix();

        bytes32 correctedEraV31CutHash = keccak256(abi.encode(_correctedEraV31Cut(NEW_ERA_ADMIN_FACET)));
        bytes32 correctedInitialCutHash =
            keccak256(abi.encode(_correctedEraChainCreationParams(NEW_ERA_ADMIN_FACET).diamondCut));
        _executeEmergencyProposal(buildCalls());

        _assertEmergencyPostconditions(
            NEW_ERA_ROLLUP_DA_MANAGER, NEW_ERA_ADMIN_FACET, correctedEraV31CutHash, correctedInitialCutHash
        );
        _assertStageProofsSetDAPairSucceedsAfterFix();

        console2.log("Fork simulation succeeded");
        console2.log("New Era RollupDAManager:", NEW_ERA_ROLLUP_DA_MANAGER);
        console2.log("New Era AdminFacet:", NEW_ERA_ADMIN_FACET);
        console2.log("Corrected full v31 upgrade cut hash:");
        console2.logBytes32(correctedEraV31CutHash);
        console2.log("Corrected chain creation initial cut hash:");
        console2.logBytes32(correctedInitialCutHash);
    }

    function buildCalls() public view returns (IProtocolUpgradeHandler.Call[] memory calls) {
        Diamond.DiamondCutData memory adminPatchCut = _adminFacetReplacementCut(NEW_ERA_ADMIN_FACET);
        Diamond.DiamondCutData memory correctedEraV31Cut = _correctedEraV31Cut(NEW_ERA_ADMIN_FACET);
        ChainCreationParams memory correctedChainCreationParams = _correctedEraChainCreationParams(NEW_ERA_ADMIN_FACET);

        calls = new IProtocolUpgradeHandler.Call[](7);

        calls[0] = IProtocolUpgradeHandler.Call({
            target: NEW_ERA_ROLLUP_DA_MANAGER, value: 0, data: abi.encodeCall(IOwnable.acceptOwnership, ())
        });

        calls[1] = IProtocolUpgradeHandler.Call({
            target: NEW_ERA_ROLLUP_DA_MANAGER,
            value: 0,
            data: abi.encodeCall(
                RollupDAManager.updateDAPair, (DEFAULT_ERA_ROLLUP_L1_DA_VALIDATOR, ERA_ROLLUP_SCHEME, true)
            )
        });

        calls[2] = IProtocolUpgradeHandler.Call({
            target: NEW_ERA_ROLLUP_DA_MANAGER,
            value: 0,
            data: abi.encodeCall(
                RollupDAManager.updateDAPair, (STAGE_PROOFS_ROLLUP_L1_DA_VALIDATOR, ERA_ROLLUP_SCHEME, true)
            )
        });

        calls[3] = IProtocolUpgradeHandler.Call({
            target: ERA_CTM,
            value: 0,
            data: abi.encodeCall(IChainTypeManager.executeUpgrade, (CHAIN_STAGE_VALIDIUM, adminPatchCut))
        });

        calls[4] = IProtocolUpgradeHandler.Call({
            target: ERA_CTM,
            value: 0,
            data: abi.encodeCall(IChainTypeManager.executeUpgrade, (CHAIN_STAGE_PROOFS, adminPatchCut))
        });

        calls[5] = IProtocolUpgradeHandler.Call({
            target: ERA_CTM,
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setUpgradeDiamondCut, (correctedEraV31Cut, ERA_OLD_PROTOCOL_VERSION))
        });

        calls[6] = IProtocolUpgradeHandler.Call({
            target: ERA_CTM,
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setChainCreationParams, (correctedChainCreationParams))
        });
    }

    function _adminFacetReplacementCut(address adminFacet) internal view returns (Diamond.DiamondCutData memory cut) {
        bytes4[] memory selectors = _eraAdminSelectorsFromGeneratedCut();
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: adminFacet, action: Diamond.Action.Replace, isFreezable: false, selectors: selectors
        });

        cut = Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: ""});
    }

    function _correctedEraV31Cut(address adminFacet) internal view returns (Diamond.DiamondCutData memory cut) {
        (cut,) = _eraStage1Data();

        _replaceBadAdminFacet(cut, adminFacet);
    }

    function _correctedEraChainCreationParams(address adminFacet)
        internal
        view
        returns (ChainCreationParams memory params)
    {
        (, params) = _eraStage1Data();

        _replaceBadAdminFacet(params.diamondCut, adminFacet);
    }

    function _replaceBadAdminFacet(Diamond.DiamondCutData memory cut, address adminFacet) internal pure {
        uint256 replacements;
        for (uint256 i = 0; i < cut.facetCuts.length; ++i) {
            if (cut.facetCuts[i].facet == BAD_ERA_ADMIN_FACET) {
                cut.facetCuts[i].facet = adminFacet;
                ++replacements;
            }
        }
        require(replacements == 1, "expected exactly one Era AdminFacet cut");
    }

    function _eraAdminSelectorsFromGeneratedCut() internal view returns (bytes4[] memory selectors) {
        (Diamond.DiamondCutData memory cut,) = _eraStage1Data();

        for (uint256 i = 0; i < cut.facetCuts.length; ++i) {
            if (cut.facetCuts[i].facet == BAD_ERA_ADMIN_FACET) {
                return cut.facetCuts[i].selectors;
            }
        }
        revert("Era AdminFacet selectors not found");
    }

    function _eraStage1Data()
        internal
        view
        returns (Diamond.DiamondCutData memory cut, ChainCreationParams memory params)
    {
        IProtocolUpgradeHandler.Call[] memory stage1Calls = _loadCalls(1);

        uint256 upgradeMatches;
        uint256 paramsMatches;
        for (uint256 i = 0; i < stage1Calls.length; ++i) {
            if (stage1Calls[i].target != ERA_CTM) {
                continue;
            }

            bytes4 selector = _selector(stage1Calls[i].data);
            if (selector == IChainTypeManager.setNewVersionUpgrade.selector) {
                uint256 oldProtocolVersion;
                uint256 newProtocolVersion;
                (cut, oldProtocolVersion, newProtocolVersion) = _decodeSetNewVersionUpgrade(stage1Calls[i].data);
                require(oldProtocolVersion == ERA_OLD_PROTOCOL_VERSION, "unexpected Era old protocol version");
                require(newProtocolVersion == V31_PROTOCOL_VERSION, "unexpected Era new protocol version");
                ++upgradeMatches;
            } else if (selector == IChainTypeManager.setChainCreationParams.selector) {
                params = abi.decode(_stripSelector(stage1Calls[i].data), (ChainCreationParams));
                ++paramsMatches;
            }
        }

        require(upgradeMatches == 1, "expected exactly one Era setNewVersionUpgrade call");
        require(paramsMatches == 1, "expected exactly one Era setChainCreationParams call");
    }

    function _decodeSetNewVersionUpgrade(bytes memory data)
        internal
        pure
        returns (Diamond.DiamondCutData memory cut, uint256 oldProtocolVersion, uint256 newProtocolVersion)
    {
        bytes memory args = _stripSelector(data);
        (cut, oldProtocolVersion,, newProtocolVersion,) =
            abi.decode(args, (Diamond.DiamondCutData, uint256, uint256, uint256, address));
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory args) {
        require(data.length >= 4, "calldata too short");
        args = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; ++i) {
            args[i - 4] = data[i];
        }
    }

    function _selector(bytes memory data) internal pure returns (bytes4) {
        require(data.length >= 4, "calldata too short");
        return bytes4(data);
    }

    function _executeEmergencyProposal(IProtocolUpgradeHandler.Call[] memory calls) internal {
        address board = PUH.emergencyUpgradeBoard();
        IProtocolUpgradeHandler.UpgradeProposal memory proposal =
            IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: board, salt: SALT});

        vm.prank(board);
        PUH.executeEmergencyUpgrade(proposal);
    }

    function _assertEmergencyPostconditions(
        address rollupDAManager,
        address adminFacet,
        bytes32 correctedEraV31CutHash,
        bytes32 correctedInitialCutHash
    ) internal view {
        RollupDAManager manager = RollupDAManager(rollupDAManager);
        IChainTypeManager eraCTM = IChainTypeManager(ERA_CTM);

        require(rollupDAManager.code.length != 0, "new Era RollupDAManager not deployed");
        require(adminFacet.code.length != 0, "new Era AdminFacet not deployed");
        require(IOwnable(rollupDAManager).owner() == address(PUH), "new Era RollupDAManager owner mismatch");
        require(
            manager.isPairAllowed(DEFAULT_ERA_ROLLUP_L1_DA_VALIDATOR, ERA_ROLLUP_SCHEME),
            "default Era rollup pair not allowed"
        );
        require(
            manager.isPairAllowed(STAGE_PROOFS_ROLLUP_L1_DA_VALIDATOR, ERA_ROLLUP_SCHEME),
            "stage-proofs rollup pair not allowed"
        );
        require(
            eraCTM.upgradeCutHash(ERA_OLD_PROTOCOL_VERSION) == correctedEraV31CutHash,
            "Era CTM corrected cut hash mismatch"
        );
        require(eraCTM.initialCutHash() == correctedInitialCutHash, "Era CTM corrected initial cut hash mismatch");

        _assertAdminFacetReplaced(CHAIN_STAGE_VALIDIUM, rollupDAManager, adminFacet);
        _assertAdminFacetReplaced(CHAIN_STAGE_PROOFS, rollupDAManager, adminFacet);
    }

    function _assertStageProofsSetDAPairFailsBeforeFix() internal {
        address stageProofs = IChainTypeManager(ERA_CTM).getZKChain(CHAIN_STAGE_PROOFS);
        address stageProofsAdmin = IGetters(stageProofs).getAdmin();

        require(
            vm.load(stageProofs, bytes32(IS_PERMANENT_ROLLUP_SLOT)) == bytes32(uint256(1)),
            "stage-proofs is not permanent"
        );

        vm.prank(stageProofsAdmin);
        (bool success,) = stageProofs.call(
            abi.encodeCall(IAdmin.setDAValidatorPair, (STAGE_PROOFS_ROLLUP_L1_DA_VALIDATOR, ERA_ROLLUP_SCHEME))
        );
        require(!success, "pre-fix stage-proofs setDAValidatorPair unexpectedly succeeded");
    }

    function _assertStageProofsSetDAPairSucceedsAfterFix() internal {
        address stageProofs = IChainTypeManager(ERA_CTM).getZKChain(CHAIN_STAGE_PROOFS);
        address stageProofsAdmin = IGetters(stageProofs).getAdmin();

        vm.prank(stageProofsAdmin);
        IAdmin(stageProofs).setDAValidatorPair(STAGE_PROOFS_ROLLUP_L1_DA_VALIDATOR, ERA_ROLLUP_SCHEME);

        (address l1DAValidator, L2DACommitmentScheme l2DACommitmentScheme) = IGetters(stageProofs).getDAValidatorPair();
        require(l1DAValidator == STAGE_PROOFS_ROLLUP_L1_DA_VALIDATOR, "stage-proofs L1 DA validator mismatch");
        require(l2DACommitmentScheme == ERA_ROLLUP_SCHEME, "stage-proofs L2 DA scheme mismatch");
    }

    function _assertAdminFacetReplaced(uint256 chainId, address rollupDAManager, address adminFacet) internal view {
        address chain = IChainTypeManager(ERA_CTM).getZKChain(chainId);
        IAdmin admin = IAdmin(chain);
        IGetters getters = IGetters(chain);

        require(admin.getRollupDAManager() == rollupDAManager, "chain RollupDAManager mismatch");
        require(
            getters.facetAddress(IAdmin.getRollupDAManager.selector) == adminFacet, "getRollupDAManager facet mismatch"
        );
        require(
            getters.facetAddress(IAdmin.setDAValidatorPair.selector) == adminFacet, "setDAValidatorPair facet mismatch"
        );
        require(
            getters.facetAddress(IAdmin.makePermanentRollup.selector) == adminFacet,
            "makePermanentRollup facet mismatch"
        );
    }

    function _checkEmergencyPreconditions(address rollupDAManager, address adminFacet) internal view {
        _checkCommonPreconditions();
        require(rollupDAManager.code.length != 0, "new Era RollupDAManager is not deployed");
        require(adminFacet.code.length != 0, "new Era AdminFacet is not deployed");
        require(IOwnable(rollupDAManager).pendingOwner() == address(PUH), "PUH is not RollupDAManager pending owner");
        require(IOwnable(rollupDAManager).owner() != address(PUH), "PUH already owns RollupDAManager");
        require(IAdmin(adminFacet).getRollupDAManager() == rollupDAManager, "AdminFacet RollupDAManager mismatch");
    }

    function _checkCommonPreconditions() internal view {
        IChainTypeManager eraCTM = IChainTypeManager(ERA_CTM);

        require(block.chainid == SEPOLIA_CHAIN_ID, "run against Sepolia/fork");
        require(BAD_ERA_ROLLUP_DA_MANAGER.code.length == 0, "bad Era manager unexpectedly has code");
        require(BAD_ERA_ADMIN_FACET.code.length != 0, "bad Era AdminFacet missing");
        require(IOwnable(ERA_CTM).owner() == address(PUH), "PUH is not Era CTM owner");
        require(eraCTM.getProtocolVersion(CHAIN_STAGE_VALIDIUM) == V31_PROTOCOL_VERSION, "stage-validium is not v31");
        require(eraCTM.getProtocolVersion(CHAIN_STAGE_PROOFS) == V31_PROTOCOL_VERSION, "stage-proofs is not v31");
        require(
            eraCTM.getProtocolVersion(CHAIN_LENS) == ERA_OLD_PROTOCOL_VERSION, "Lens is not on the old Era protocol"
        );
        require(
            IAdmin(eraCTM.getZKChain(CHAIN_STAGE_VALIDIUM)).getRollupDAManager() == BAD_ERA_ROLLUP_DA_MANAGER,
            "stage-validium manager is not the broken one"
        );
        require(
            IAdmin(eraCTM.getZKChain(CHAIN_STAGE_PROOFS)).getRollupDAManager() == BAD_ERA_ROLLUP_DA_MANAGER,
            "stage-proofs manager is not the broken one"
        );
    }
}
