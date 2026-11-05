//! Immutable opaque objects. No native Rust layout is part of the C ABI.
use std::sync::Arc;

pub struct TypstContext {
    pub(crate) inner: Arc<crate::context::Context>,
}
pub struct TypstLayout {
    pub(crate) inner: Arc<crate::layout::Layout>,
}
pub struct TypstDocument {
    pub(crate) inner: Arc<crate::document::Document>,
}
pub struct TypstScene {
    pub(crate) inner: Arc<crate::scene::Scene>,
}
pub struct TypstOutline {
    pub(crate) inner: crate::outline::Outline,
}
pub struct TypstDiagnostics {
    pub(crate) inner: crate::diagnostics::Report,
}
pub struct TypstBuffer {
    pub(crate) inner: Vec<u8>,
}
