// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The helper library for managing the EIP-2535 diamond proxy.
library Diamond {
    using UncheckedMath for uint256;
    using SafeCast for uint256;

    /// @dev Magic value that should be returned by diamond cut initialize contracts.
    /// @dev Used to distinguish calls to contracts that were supposed to be used as diamond initializer from other contracts.
    bytes32 internal constant DIAMOND_INIT_SUCCESS_RETURN_VALUE =
        0x33774e659306e47509050e97cb651e731180a42d458212294d30751925c551a2; // keccak256("diamond.zksync.init") - 1

    /// @dev Storage position of `DiamondStorage` structure.
    bytes32 private constant DIAMOND_STORAGE_POSITION =
        0xc8fcad8db84d3cc18b4c41d551ea0ee66dd599cde068d998e57d5e09332c131b; // keccak256("diamond.standard.diamond.storage") - 1;

    event DiamondCut(FacetCut[] facetCuts, address initAddress, bytes initCalldata);

    /// @dev Utility struct that contains associated facet & meta information of selector
    /// @param facetAddress address of the facet which is connected with selector
    /// @param selectorPosition index in `FacetToSelectors.selectors` array, where is selector stored
    /// @param isFreezable denotes whether the selector can be frozen.
    struct SelectorToFacet {
        address facetAddress;
        uint16 selectorPosition;
        bool isFreezable;
    }

    /// @dev Utility struct that contains associated selectors & meta information of facet
    /// @param selectors list of all selectors that belong to the facet
    /// @param facetPosition index in `DiamondStorage.facets` array, where is facet stored
    struct FacetToSelectors {
        bytes4[] selectors;
        uint16 facetPosition;
    }

    /// @notice The structure that holds all diamond proxy associated parameters
    /// @dev According to the EIP-2535 should be stored on a special storage key - `DIAMOND_STORAGE_POSITION`
    /// @param selectorToFacet A mapping from the selector to the facet address and its meta information
    /// @param facetToSelectors A mapping from facet address to its selectors with meta information
    /// @param facets The array of all unique facet addresses that belong to the diamond proxy
    /// @param isFrozen Denotes whether the diamond proxy is frozen and all freezable facets are not accessible
    struct DiamondStorage {
        mapping(bytes4 selector => SelectorToFacet selectorInfo) selectorToFacet;
        mapping(address facetAddress => FacetToSelectors facetInfo) facetToSelectors;
        address[] facets;
        bool isFrozen;
    }

    /// @dev Parameters for diamond changes that touch one of the facets
    /// @param facet The address of facet that's affected by the cut
    /// @param action The action that is made on the facet
    /// @param isFreezable Denotes whether the facet & all their selectors can be frozen
    /// @param selectors An array of unique selectors that belongs to the facet address
    struct FacetCut {
        address facet;
        Action action;
        bool isFreezable;
        bytes4[] selectors;
    }

    /// @dev Structure of the diamond proxy changes
    /// @param facetCuts The set of changes (adding/removing/replacement) of implementation contracts
    /// @param initAddress The address that's delegate called after setting up new facet changes
    /// @param initCalldata Calldata for the delegate call to `initAddress`
    struct DiamondCutData {
        FacetCut[] facetCuts;
        address initAddress;
        bytes initCalldata;
    }

    /// @dev Type of change over diamond: add/replace/remove facets
    enum Action {
        Add,
        Replace,
        Remove
    }

    /// @return diamondStorage The pointer to the storage where all specific diamond proxy parameters stored
    function getDiamondStorage() internal pure returns (DiamondStorage storage diamondStorage) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            diamondStorage.slot := position
        }
    }

    /// @dev Add/replace/remove any number of selectors and optionally execute a function with delegatecall
    /// @param _diamondCut Diamond's facet changes and the parameters to optional initialization delegatecall
    function diamondCut(DiamondCutData memory _diamondCut) internal {
        FacetCut[] memory facetCuts = _diamondCut.facetCuts;
        address initAddress = _diamondCut.initAddress;
        bytes memory initCalldata = _diamondCut.initCalldata;
        uint256 facetCutsLength = facetCuts.length;
        for (uint256 i = 0; i < facetCutsLength; i = i.uncheckedInc()) {
            Action action = facetCuts[i].action;
            address facet = facetCuts[i].facet;
            bool isFacetFreezable = facetCuts[i].isFreezable;
            bytes4[] memory selectors = facetCuts[i].selectors;

            require(selectors.length > 0, "B"); // no functions for diamond cut

            if (action == Action.Add) {
                _addFunctions(facet, selectors, isFacetFreezable);
            } else if (action == Action.Replace) {
                _replaceFunctions(facet, selectors, isFacetFreezable);
            } else if (action == Action.Remove) {
                _removeFunctions(facet, selectors);
            } else {
                revert("C"); // undefined diamond cut action
            }
        }

        _initializeDiamondCut(initAddress, initCalldata);
        emit DiamondCut(facetCuts, initAddress, initCalldata);
    }

    /// @dev Add new functions to the diamond proxy
    /// NOTE: expect but NOT enforce that `_selectors` is NON-EMPTY array
    function _addFunctions(address _facet, bytes4[] memory _selectors, bool _isFacetFreezable) private {
        DiamondStorage storage ds = getDiamondStorage();

        // Facet with no code cannot be added.
        // This check also verifies that the facet does not have zero address, since it is the
        // address with which 0x00000000 selector is associated.
        require(_facet.code.length > 0, "G");

        // Add facet to the list of facets if the facet address is new one
        _saveFacetIfNew(_facet);

        uint256 selectorsLength = _selectors.length;
        for (uint256 i = 0; i < selectorsLength; i = i.uncheckedInc()) {
            bytes4 selector = _selectors[i];
            SelectorToFacet memory oldFacet = ds.selectorToFacet[selector];
            require(oldFacet.facetAddress == address(0), "J"); // facet for this selector already exists

            _addOneFunction(_facet, selector, _isFacetFreezable);
        }
    }

    /// @dev Change associated facets to already known function selectors
    /// NOTE: expect but NOT enforce that `_selectors` is NON-EMPTY array
    function _replaceFunctions(address _facet, bytes4[] memory _selectors, bool _isFacetFreezable) private {
        DiamondStorage storage ds = getDiamondStorage();

        // Facet with no code cannot be added.
        // This check also verifies that the facet does not have zero address, since it is the
        // address with which 0x00000000 selector is associated.
        require(_facet.code.length > 0, "K");

        uint256 selectorsLength = _selectors.length;
        for (uint256 i = 0; i < selectorsLength; i = i.uncheckedInc()) {
            bytes4 selector = _selectors[i];
            SelectorToFacet memory oldFacet = ds.selectorToFacet[selector];
            require(oldFacet.facetAddress != address(0), "L"); // it is impossible to replace the facet with zero address

            _removeOneFunction(oldFacet.facetAddress, selector);
            // Add facet to the list of facets if the facet address is a new one
            _saveFacetIfNew(_facet);
            _addOneFunction(_facet, selector, _isFacetFreezable);
        }
    }

    /// @dev Remove association with function and facet
    /// NOTE: expect but NOT enforce that `_selectors` is NON-EMPTY array
    function _removeFunctions(address _facet, bytes4[] memory _selectors) private {
        DiamondStorage storage ds = getDiamondStorage();

        require(_facet == address(0), "a1"); // facet address must be zero

        uint256 selectorsLength = _selectors.length;
        for (uint256 i = 0; i < selectorsLength; i = i.uncheckedInc()) {
            bytes4 selector = _selectors[i];
            SelectorToFacet memory oldFacet = ds.selectorToFacet[selector];
            require(oldFacet.facetAddress != address(0), "a2"); // Can't delete a non-existent facet

            _removeOneFunction(oldFacet.facetAddress, selector);
        }
    }

    /// @dev Add address to the list of known facets if it is not on the list yet
    /// NOTE: should be called ONLY before adding a new selector associated with the address
    function _saveFacetIfNew(address _facet) private {
        DiamondStorage storage ds = getDiamondStorage();

        uint256 selectorsLength = ds.facetToSelectors[_facet].selectors.length;
        // If there are no selectors associated with facet then save facet as new one
        if (selectorsLength == 0) {
            ds.facetToSelectors[_facet].facetPosition = ds.facets.length.toUint16();
            ds.facets.push(_facet);
        }
    }

    /// @dev Add one function to the already known facet
    /// NOTE: It is expected but NOT enforced that:
    /// - `_facet` is NON-ZERO address
    /// - `_facet` is already stored address in `DiamondStorage.facets`
    /// - `_selector` is NOT associated by another facet
    function _addOneFunction(address _facet, bytes4 _selector, bool _isSelectorFreezable) private {
        DiamondStorage storage ds = getDiamondStorage();

        uint16 selectorPosition = (ds.facetToSelectors[_facet].selectors.length).toUint16();

        // if selectorPosition is nonzero, it means it is not a new facet
        // so the freezability of the first selector must be matched to _isSelectorFreezable
        // so all the selectors in a facet will have the same freezability
        if (selectorPosition != 0) {
            bytes4 selector0 = ds.facetToSelectors[_facet].selectors[0];
            require(_isSelectorFreezable == ds.selectorToFacet[selector0].isFreezable, "J1");
        }

        ds.selectorToFacet[_selector] = SelectorToFacet({
            facetAddress: _facet,
            selectorPosition: selectorPosition,
            isFreezable: _isSelectorFreezable
        });
        ds.facetToSelectors[_facet].selectors.push(_selector);
    }

    /// @dev Remove one associated function with facet
    /// NOTE: It is expected but NOT enforced that `_facet` is NON-ZERO address
    function _removeOneFunction(address _facet, bytes4 _selector) private {
        DiamondStorage storage ds = getDiamondStorage();

        // Get index of `FacetToSelectors.selectors` of the selector and last element of array
        uint256 selectorPosition = ds.selectorToFacet[_selector].selectorPosition;
        uint256 lastSelectorPosition = ds.facetToSelectors[_facet].selectors.length - 1;

        // If the selector is not at the end of the array then move the last element to the selector position
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetToSelectors[_facet].selectors[lastSelectorPosition];

            ds.facetToSelectors[_facet].selectors[selectorPosition] = lastSelector;
            ds.selectorToFacet[lastSelector].selectorPosition = selectorPosition.toUint16();
        }

        // Remove last element from the selectors array
        ds.facetToSelectors[_facet].selectors.pop();

        // Finally, clean up the association with facet
        delete ds.selectorToFacet[_selector];

        // If there are no selectors for facet then remove the facet from the list of known facets
        if (lastSelectorPosition == 0) {
            _removeFacet(_facet);
        }
    }

    /// @dev remove facet from the list of known facets
    /// NOTE: It is expected but NOT enforced that there are no selectors associated with `_facet`
    function _removeFacet(address _facet) private {
        DiamondStorage storage ds = getDiamondStorage();

        // Get index of `DiamondStorage.facets` of the facet and last element of array
        uint256 facetPosition = ds.facetToSelectors[_facet].facetPosition;
        uint256 lastFacetPosition = ds.facets.length - 1;

        // If the facet is not at the end of the array then move the last element to the facet position
        if (facetPosition != lastFacetPosition) {
            address lastFacet = ds.facets[lastFacetPosition];

            ds.facets[facetPosition] = lastFacet;
            ds.facetToSelectors[lastFacet].facetPosition = facetPosition.toUint16();
        }

        // Remove last element from the facets array
        ds.facets.pop();
    }

    /// @dev Delegates call to the initialization address with provided calldata
    /// @dev Used as a final step of diamond cut to execute the logic of the initialization for changed facets
    function _initializeDiamondCut(address _init, bytes memory _calldata) private {
        if (_init == address(0)) {
            require(_calldata.length == 0, "H"); // Non-empty calldata for zero address
        } else {
            // Do not check whether `_init` is a contract since later we check that it returns data.
            (bool success, bytes memory data) = _init.delegatecall(_calldata);
            if (!success) {
                // If the returndata is too small, we still want to produce some meaningful error
                if (data.length <= 4) {
                    revert("I"); // delegatecall failed
                }

                assembly {
                    revert(add(data, 0x20), mload(data))
                }
            }

            // Check that called contract returns magic value to make sure that contract logic
            // supposed to be used as diamond cut initializer.
            require(data.length == 32, "lp");
            require(abi.decode(data, (bytes32)) == DIAMOND_INIT_SUCCESS_RETURN_VALUE, "lp1");
        }
    }
}
