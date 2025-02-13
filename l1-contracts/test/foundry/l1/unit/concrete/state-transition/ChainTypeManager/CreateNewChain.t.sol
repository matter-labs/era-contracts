// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {Unauthorized, HashMismatch, ZeroAddress, ZKChainLimitReached} from "contracts/common/L1ContractErrors.sol";
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

        uint256[] memory chainIds = _getAllZKChainIDs();
        assertEq(chainIds.length, 2);
        assertEq(chainIds[0], chainId);
        assertEq(chainIds[1], 10);
    }

    function test_SuccessfulCreationOfNewChainAndReturnChainAddresses() public {
        createNewChain(getDiamondCutData(diamondInit));
        createNewChainWithId(getDiamondCutData(diamondInit), 10);

        address[] memory zkchainAddresses = _getAllZKChains();
        assertEq(zkchainAddresses.length, 2);
        assertEq(zkchainAddresses[0], chainContractAddress.getZKChain(chainId));
        assertEq(zkchainAddresses[1], chainContractAddress.getZKChain(10));
    }

    function test_RevertWhen_AlreadyDeployedZKChainAddressIsZero() public {
        vm.expectRevert(ZeroAddress.selector);

        _registerAlreadyDeployedZKChain(chainId, address(0));
    }

    function test_SuccessfulRegisterAlreadyDeployedZKChain() public {
        address randomZKChain = makeAddr("randomZKChain");

        _registerAlreadyDeployedZKChain(10, randomZKChain);

        assertEq(chainContractAddress.getZKChain(10), randomZKChain);
    }

    function test_RevertWhen_ZKChainLimitReached() public {
        for (uint256 i = 0; i < MAX_NUMBER_OF_ZK_CHAINS; i++) {
            createNewChainWithId(getDiamondCutData(diamondInit), 10 + i);
        }

        uint256[] memory chainIds = _getAllZKChainIDs();
        assertEq(chainIds.length, MAX_NUMBER_OF_ZK_CHAINS);

        vm.expectRevert(ZKChainLimitReached.selector);
        _registerAlreadyDeployedZKChain(100, makeAddr("randomZKChain"));
    }
}
