// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotL1} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

contract AllowEvmEmulationTest is AdminTest {
    event EnableEvmEmulator();

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.allowEvmEmulation();
    }

    function test_revertWhen_notL1() public {
        uint256 fakeChainId = 1337;
        vm.chainId(fakeChainId);
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, fakeChainId));
        adminFacet.allowEvmEmulation();
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
