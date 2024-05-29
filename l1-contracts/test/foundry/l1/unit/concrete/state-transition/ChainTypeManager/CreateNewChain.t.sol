// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {Unauthorized, HashMismatch} from "contracts/common/L1ContractErrors.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

contract createNewChainTest is ChainTypeManagerTest {
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
            _baseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, baseToken),
            _admin: admin,
            _initData: abi.encode(abi.encode(initialDiamondCutData), bytes("")),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_SuccessfulCreationOfNewChain() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));

        address admin = IZKChain(newChainAddress).getAdmin();

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }

    function test_SuccessfulCreationOfNewChainAndReturnChainIds() public {
        createNewChain(getDiamondCutData(diamondInit));
        createNewChainWithId(getDiamondCutData(diamondInit), 10);

        uint256[] memory chainIds = chainContractAddress.getAllHyperchainChainIDs();
        assertEq(chainIds.length, 2);
        assertEq(chainIds[0], chainId);
        assertEq(chainIds[1], 10);
    }

    function test_SuccessfulCreationOfNewChainAndReturnChainAddresses() public {
        createNewChain(getDiamondCutData(diamondInit));
        createNewChainWithId(getDiamondCutData(diamondInit), 10);

        address[] memory hyperchainAddresses = chainContractAddress.getAllHyperchains();
        assertEq(hyperchainAddresses.length, 2);
        assertEq(hyperchainAddresses[0], chainContractAddress.getHyperchain(chainId));
        assertEq(hyperchainAddresses[1], chainContractAddress.getHyperchain(10));
    }

    function test_RevertWhen_AlreadyDeployedHyperchainAddressIsZero() public {
        vm.expectRevert(bytes("STM: hyperchain zero"));

        chainContractAddress.registerAlreadyDeployedHyperchain(chainId, address(0));
    }

    function test_SuccessfulRegisterAlreadyDeployedHyperchain() public {
        address randomHyperchain = makeAddr("randomHyperchain");

        chainContractAddress.registerAlreadyDeployedHyperchain(10, randomHyperchain);

        assertEq(chainContractAddress.getHyperchain(10), randomHyperchain);
    }

    function test_RevertWhen_HyperchainLimitReached() public {
        for (uint256 i = 0; i < MAX_NUMBER_OF_HYPERCHAINS; i++) {
            createNewChainWithId(getDiamondCutData(diamondInit), 10 + i);
        }

        uint256[] memory chainIds = chainContractAddress.getAllHyperchainChainIDs();
        assertEq(chainIds.length, MAX_NUMBER_OF_HYPERCHAINS);

        vm.expectRevert("STM: Hyperchain limit reached");
        chainContractAddress.registerAlreadyDeployedHyperchain(100, makeAddr("randomHyperchain"));
    }
}
