// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract createNewChainTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    // Note: the old `HashMismatch`-on-passed-cut test is gone: from v32 the CTM builds the genesis
    // cut itself from its registry, so `createNewChain` no longer accepts (or validates) a cut.

    function test_RevertWhen_CalledNotByBridgehub() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governor));
        chainContractAddress.createNewChain({_chainId: chainId, _admin: admin});
    }

    function test_SuccessfulCreationOfNewChain() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));

        address admin = IZKChain(newChainAddress).getAdmin();

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }

    function test_SuccessfulCreationOfNewChainAndReturnChainId() public {
        createNewChain(getDiamondCutData(diamondInit));

        uint256[] memory mockData = new uint256[](1);
        mockData[0] = chainId;

        vm.mockCall(address(bridgehub), abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(mockData));
        uint256[] memory chainIds = _getAllZKChainIDs();

        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId);
    }
}
