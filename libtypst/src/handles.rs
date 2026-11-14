//! The C handle owns one strong reference to the whole opaque object.

pub struct TypstContext {
    pub(crate) inner: crate::context::Context,
}
pub struct TypstLayout {
    pub(crate) inner: crate::layout::Layout,
}
pub struct TypstDocument {
    pub(crate) inner: crate::document::Document,
}
pub struct TypstScene {
    pub(crate) inner: crate::scene::Scene,
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
pub struct TypstMemberUses {
    pub(crate) inner: crate::syntax::MemberUses,
}
pub struct TypstModule {
    pub(crate) inner: crate::layout::EvaluatedModule,
}
