//! A stable native C API backed by upstream Typst.
//!
//! Public C records describe libtypst's contract. Upstream Rust types and
//! version-specific construction are confined to the internal implementation.
pub mod abi;
mod context;
mod diagnostics;
mod document;
mod error;
mod export;
mod ffi;
pub mod handles;
mod layout;
mod outline;
mod scene;
mod syntax;

pub use abi::*;
pub use ffi::*;
pub use handles::*;
