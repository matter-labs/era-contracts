## Diamond

The helper library for managing the EIP-2535 diamond proxy.

### DIAMOND_INIT_SUCCESS_RETURN_VALUE

```solidity
bytes32 DIAMOND_INIT_SUCCESS_RETURN_VALUE
```

_Magic value that should be returned by diamond cut initialize contracts.
Used to distinguish calls to contracts that were supposed to be used as diamond initializer from other contracts._

### DiamondCut

```solidity
event DiamondCut(struct Diamond.FacetCut[] facetCuts, address initAddress, bytes initCalldata)
```

### SelectorToFacet

_Utility struct that contains associated facet & meta information of selector_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct SelectorToFacet {
  address facetAddress;
  uint16 selectorPosition;
  bool isFreezable;
}
```

### FacetToSelectors

_Utility struct that contains associated selectors & meta information of facet_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct FacetToSelectors {
  bytes4[] selectors;
  uint16 facetPosition;
}
```

### DiamondStorage

The structure that holds all diamond proxy associated parameters

_According to the EIP-2535 should be stored on a special storage key - `DIAMOND_STORAGE_POSITION`_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct DiamondStorage {
  mapping(bytes4 => struct Diamond.SelectorToFacet) selectorToFacet;
  mapping(address => struct Diamond.FacetToSelectors) facetToSelectors;
  address[] facets;
  bool isFrozen;
}
```

### FacetCut

_Parameters for diamond changes that touch one of the facets_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct FacetCut {
  address facet;
  enum Diamond.Action action;
  bool isFreezable;
  bytes4[] selectors;
}
```

### DiamondCutData

_Structure of the diamond proxy changes_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct DiamondCutData {
  struct Diamond.FacetCut[] facetCuts;
  address initAddress;
  bytes initCalldata;
}
```

### Action

_Type of change over diamond: add/replace/remove facets_

```solidity
enum Action {
  Add,
  Replace,
  Remove
}
```

### getDiamondStorage

```solidity
function getDiamondStorage() internal pure returns (struct Diamond.DiamondStorage diamondStorage)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| diamondStorage | struct Diamond.DiamondStorage | The pointer to the storage where all specific diamond proxy parameters stored |

### diamondCut

```solidity
function diamondCut(struct Diamond.DiamondCutData _diamondCut) internal
```

_Add/replace/remove any number of selectors and optionally execute a function with delegatecall_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _diamondCut | struct Diamond.DiamondCutData | Diamond's facet changes and the parameters to optional initialization delegatecall |

