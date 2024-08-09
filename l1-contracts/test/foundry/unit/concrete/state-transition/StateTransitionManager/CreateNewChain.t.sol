// // SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract createNewChainTest is StateTransitionManagerTest {
    function test_RevertWhen_InitialDiamondCutHashMismatch() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(sharedBridge);

        vm.expectRevert(bytes("STM: initial cutHash mismatch"));

        createNewChain(initialDiamondCutData);
    }

    function test_RevertWhen_CalledNotByBridgehub() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(diamondInit);

        vm.expectRevert(bytes("STM: only bridgehub"));

        chainContractAddress.createNewChain({
            _chainId: chainId,
            _baseToken: baseToken,
            _sharedBridge: sharedBridge,
            _admin: admin,
            _initData: abi.encode(abi.encode(initialDiamondCutData), bytes("")),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_SuccessfulCreationOfNewChain() public {
        createNewChain(getDiamondCutData(diamondInit));

        address admin = chainContractAddress.getChainAdmin(chainId);
        address newChainAddress = chainContractAddress.getHyperchain(chainId);

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));

        address[] memory chainAddresses = chainContractAddress.getAllHyperchains();
        assertEq(chainAddresses.length, 1);
        assertEq(chainAddresses[0], newChainAddress);

        uint256[] memory chainIds = chainContractAddress.getAllHyperchainChainIDs();
        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId);

        uint256 protocolVersion = chainContractAddress.getProtocolVersion(chainId);
        assertEq(protocolVersion, 0);
    }
}
