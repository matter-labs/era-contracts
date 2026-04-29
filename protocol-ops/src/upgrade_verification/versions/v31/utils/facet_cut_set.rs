use alloy::hex;
use alloy::primitives::Address;
use std::cmp::Ordering;
use std::collections::HashSet;
use std::hash::{Hash, Hasher};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Action {
    Add,
    Remove,
}

#[derive(Clone, PartialEq, Eq)]
pub struct FacetInfo {
    pub(crate) facet: Address,
    pub(crate) action: Action,
    pub(crate) is_freezable: bool,
    pub(crate) selectors: HashSet<[u8; 4]>,
}

impl Hash for FacetInfo {
    fn hash<H: Hasher>(&self, state: &mut H) {
        // Hash the fields that are already in a deterministic order.
        self.facet.hash(state);
        self.action.hash(state);
        self.is_freezable.hash(state);

        // For the selectors (a HashSet), sort them first so that the order is deterministic.
        // Note: [u8; 4] implements Ord, so sorting is available.
        let mut selectors: Vec<&[u8; 4]> = self.selectors.iter().collect();
        selectors.sort();
        for selector in selectors {
            selector.hash(state);
        }
    }
}

impl std::fmt::Debug for FacetInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut selectors = self
            .selectors
            .iter()
            .map(|e| hex::encode(e))
            .collect::<Vec<String>>();
        selectors.sort();
        f.debug_struct("FacetInfo")
            .field("facet", &self.facet)
            .field("action", &self.action)
            .field("is_freezable", &self.is_freezable)
            .field("selectors", &selectors)
            .finish()
    }
}

#[derive(Debug, Clone, Eq)]
pub struct FacetCutSet {
    facets: HashSet<FacetInfo>,
}

impl PartialEq for FacetCutSet {
    fn eq(&self, other: &Self) -> bool {
        self.facets == other.facets
    }
}

impl Default for FacetCutSet {
    fn default() -> Self {
        Self::new()
    }
}

impl FacetCutSet {
    pub fn new() -> Self {
        Self {
            facets: HashSet::new(),
        }
    }

    pub fn add_facet(&mut self, facet: FacetInfo) {
        self.facets.insert(facet);
    }

    pub fn merge(mut self, another_set: FacetCutSet) -> Self {
        for new_facet in another_set.facets {
            self.facets.insert(new_facet);
        }

        self
    }
}

impl PartialOrd for FacetCutSet {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.facets.len().cmp(&other.facets.len()))
    }
}

impl Ord for FacetCutSet {
    fn cmp(&self, other: &Self) -> Ordering {
        self.facets.len().cmp(&other.facets.len())
    }
}
