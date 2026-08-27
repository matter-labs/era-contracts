//! Compatibility surface for the legacy ZKsync crates used by the bootloader tests.
//!
//! The upstream crates only use these derive macros. Keeping the compatibility
//! crate intentionally limited avoids pulling in the vulnerable `KeyValueMap`
//! serializer from `serde_with` 1.x.

#[cfg(feature = "macros")]
pub use serde_with_macros::{DeserializeFromStr, SerializeDisplay};
pub use serde;
