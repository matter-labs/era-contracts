//SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";


import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {TestnetERC20Token} from "solpp/dev-contracts/TestnetERC20Token.sol";
import {IBridgehub, Bridgehub} from "solpp/bridgehub/Bridgehub.sol";
import {DummyStateTransitionManagerWBH} from "solpp/dev-contracts/test/DummyStateTransitionManagerWithBridgeHubAddress.sol";
import {IL1SharedBridge} from "solpp/bridge/interfaces/IL1SharedBridge.sol";

contract ExperimentalBridgeTest is Test {

    Bridgehub bridgeHub;
    address public bridgeOwner;
    DummyStateTransitionManagerWBH mockSTM;
    TestnetERC20Token testToken;

    function setUp() public {
        bridgeHub = new Bridgehub();
        bridgeOwner = makeAddr("BRIDGE_OWNER");
        mockSTM = new DummyStateTransitionManagerWBH(address(bridgeHub));
        testToken = new TestnetERC20Token("ZKSTT", "ZkSync Test Token", 18);

        // test if the ownership of the bridgeHub is set correctly or not
        address defaultOwner = bridgeHub.owner();

        // The defaultOwner should be the same as this contract address, since this is the one deploying the bridgehub contract
        assertEq(defaultOwner, address(this));

        // Now, the `reentrancyGuardInitializer` should prevent anyone from calling `initialize` since we have called the constructor of the contract
        // @follow-up Is this the intended behavior? @Vlad @kalman
        vm.expectRevert(bytes("1B"));
        bridgeHub.initialize(bridgeOwner);

        // The ownership can only be transfered by the current owner to a new owner via the two-step approach
        
        // Default owner calls transferOwnership
        bridgeHub.transferOwnership(bridgeOwner);

        // bridgeOwner calls acceptOwnership
        vm.prank(bridgeOwner);
        bridgeHub.acceptOwnership();

        // Ownership should have changed
        assertEq(bridgeHub.owner(), bridgeOwner);
    }

    function test_ownerCanSetDeployer(address randomCaller, address randomDeployer) public {
        /**
            Case I: A random address tries to call the `setDeployer` method and the call fails with the error: `Ownable: caller is not the owner`
            Case II: The bridgeHub owner calls the `setDeployer` method on `randomDeployer` and it becomes the deployer
        */
        
        if(randomCaller != bridgeHub.owner()) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.setDeployer(randomDeployer);

            // The deployer shouldn't have changed.
            assertEq(address(0), bridgeHub.deployer());
        } else { 
            vm.prank(randomCaller);
            bridgeHub.setDeployer(randomDeployer);

            assertEq(randomDeployer, bridgeHub.deployer());
        }
    }

    // @follow-up Concern:
    // 1. Addresses that do not implement the correct interface or any interface whatsoever (EOAs and address(0)) can also be added as a StateTransitionManager
    // 2. After being added, if the contracts are upgradable, they can change their logic to include malicious code as well.
    function test_addStateTransitionManager(address randomAddressWithoutTheCorrectInterface, address randomCaller) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            
            bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        }
        
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        
        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // An address that has already been registered, cannot be registered again (atleast not before calling `removeStateTransitionManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition already registered"));
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);
    }

    function test_removeStateTransitionManager(address randomAddressWithoutTheCorrectInterface, address randomCaller) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            
            bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        } 
        
        // A non-existent STM cannot be removed
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        
        // Let's first register our particular stateTransitionManager
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        
        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // Only an address that has already been registered, can be removed.
        vm.prank(bridgeOwner);
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        // An already removed STM cannot be removed again
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
    }

    function test_addToken(address randomCaller, address randomAddress) public {
        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.addToken(randomAddress);
        }

        assertTrue(!bridgeHub.tokenIsRegistered(randomAddress), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgeHub.addToken(randomAddress);

        assertTrue(bridgeHub.tokenIsRegistered(randomAddress), "after call from the bridgeowner, this randomAddress should be a registered token");
        
        // Testing to see if an actual ERC20 implementation can also be added or not
        vm.prank(bridgeOwner);
        bridgeHub.addToken(address(testToken));

        assertTrue(bridgeHub.tokenIsRegistered(address(testToken)));
    }

    function test_setSharedBridge(address randomCaller, address randomAddress) public {
        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.setSharedBridge(randomAddress);
        }

        assertTrue(bridgeHub.sharedBridge() == IL1SharedBridge(address(0)), "This random address is not registered as sharedBridge");

        vm.prank(bridgeOwner);
        bridgeHub.setSharedBridge(randomAddress);

        assertTrue(bridgeHub.sharedBridge() == IL1SharedBridge(randomAddress), "after call from the bridgeowner, this randomAddress should be the registered sharedBridge");
    }


    uint256 newChainId;
    address admin;
    function test_createNewChain(
        address randomCaller, 
        uint256 chainId,
        bool isFreezable, 
        bytes4[] memory mockSelectors, 
        address mockInitAddress, 
        bytes memory mockInitCalldata
    ) public {
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        address mockSharedBridge = makeAddr("MOCK_SHARED_BRIDGE");
        admin = makeAddr("NEW_CHAIN_ADMIN");
        Diamond.DiamondCutData memory dcData;

        vm.startPrank(bridgeOwner);
        bridgeHub.setDeployer(deployerAddress);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        bridgeHub.addToken(address(testToken));
        bridgeHub.setSharedBridge(mockSharedBridge);
        vm.stopPrank();

        if(randomCaller != deployerAddress && randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Bridgehub: not owner or deployer"));
            bridgeHub.createNewChain(
                chainId,
                address(mockSTM),
                address(testToken),
                uint256(123),
                admin,
                bytes("")
            );
        }

        chainId = bound(chainId, 1, type(uint48).max);
        bytes memory _newChainInitData = _createNewChainInitData(isFreezable, mockSelectors, mockInitAddress, mockInitCalldata);

        emit log_named_bytes32("ICH", mockSTM.initialCutHash());

        vm.startPrank(deployerAddress);
        vm.mockCall(
            address(mockSTM),
            abi.encodeWithSelector(mockSTM.createNewChain.selector, chainId, address(mockSTM), address(testToken), uint256(chainId * 2), admin, _newChainInitData),
            bytes('')
        );
        newChainId = bridgeHub.createNewChain(
            chainId,
            address(mockSTM),
            address(testToken),
            uint256(chainId * 2),
            admin,
            _newChainInitData
        );
        vm.stopPrank();

        assertTrue(bridgeHub.stateTransitionManager(newChainId) == address(mockSTM));
        assertTrue(bridgeHub.baseToken(newChainId) == address(testToken));
    }

    function _createNewChainInitData(bool isFreezable, bytes4[] memory mockSelectors, address mockInitAddress, bytes memory mockInitCalldata) internal returns (bytes memory) {
        bytes4[] memory singleSelector = new bytes4[](1);
        singleSelector[0] = bytes4(0xabcdef12);
        
        Diamond.FacetCut memory facetCut;
        Diamond.DiamondCutData memory diamondCutData;


        facetCut.facet = address(this); // for a random address, it will fail the check of _facet.code.length > 0
        facetCut.action = Diamond.Action.Add;
        facetCut.isFreezable = isFreezable;
        if(mockSelectors.length == 0) {
            mockSelectors = singleSelector;
        }
        facetCut.selectors = mockSelectors;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = facetCut;

        diamondCutData.facetCuts = facetCuts;
        diamondCutData.initAddress = address(0);
        diamondCutData.initCalldata = "";

        mockSTM.setInitialCutHash(diamondCutData);

        return abi.encode(diamondCutData);
    }
}