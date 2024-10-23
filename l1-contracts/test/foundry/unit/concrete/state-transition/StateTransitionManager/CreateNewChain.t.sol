// // SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Unauthorized, HashMismatch} from "contracts/common/L1ContractErrors.sol";

contract createNewChainTest is StateTransitionManagerTest {
    function setUp() public {
        deploy();
    }

    function test_RevertWhen_InitialDiamondCutHashMismatch() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(sharedBridge);
        Diamond.DiamondCutData memory correctDiamondCutData = getDiamondCutData(address(diamondInit));

        vm.expectRevert(
            abi.encodeWithSelector(
                HashMismatch.selector,
                keccak256(abi.encode(correctDiamondCutData)),
                keccak256(abi.encode(initialDiamondCutData))
            )
        );
        createNewChain(initialDiamondCutData);
    }

    function test_RevertWhen_CalledNotByBridgehub() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(diamondInit);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governor));
        chainContractAddress.createNewChain({
            _chainId: chainId,
            _baseToken: baseToken,
            _sharedBridge: sharedBridge,
            _admin: admin,
            _inputData: abi.encode(initialDiamondCutData)
        });
    }

    function test_SuccessfulCreationOfNewChain() public {
        createNewChain(getDiamondCutData(diamondInit));

        address admin = chainContractAddress.getChainAdmin(chainId);
        address newChainAddress = chainContractAddress.getHyperchain(chainId);

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }

    function test_SuccessfulCreationOfNewChainWithEvmEmulator() public {
        createNewChainWithEvmEmulator(getDiamondCutData(diamondInit));

        address admin = chainContractAddress.getChainAdmin(chainId);
        address newChainAddress = chainContractAddress.getHyperchain(chainId);

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }
}
