//! The reference counts of every handle: one retain and one release per handle type.
use super::*;

/// Acquires one additional context reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live context from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_context_retain(value: *const TypstContext) {
    unsafe { retain(value) }
}
/// Releases one owned context reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a context reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_context_release(value: *const TypstContext) {
    unsafe { release(value) }
}
/// Acquires one additional layout reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live layout from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_retain(value: *const TypstLayout) {
    unsafe { retain(value) }
}
/// Releases one owned layout reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a layout reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_release(value: *const TypstLayout) {
    unsafe { release(value) }
}
/// Acquires one additional document reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live document from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_document_retain(value: *const TypstDocument) {
    unsafe { retain(value) }
}
/// Releases one owned document reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a document reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_document_release(value: *const TypstDocument) {
    unsafe { release(value) }
}
/// Acquires one additional scene reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live scene from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_retain(value: *const TypstScene) {
    unsafe { retain(value) }
}
/// Releases one owned scene reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a scene reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_release(value: *const TypstScene) {
    unsafe { release(value) }
}
/// Acquires one additional outline reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live outline from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_outline_retain(value: *const TypstOutline) {
    unsafe { retain(value) }
}
/// Releases one owned outline reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be an outline reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_outline_release(value: *const TypstOutline) {
    unsafe { release(value) }
}
/// Acquires one additional buffer reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live buffer from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_buffer_retain(value: *const TypstBuffer) {
    unsafe { retain(value) }
}
/// Releases one owned buffer reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a buffer reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_buffer_release(value: *const TypstBuffer) {
    unsafe { release(value) }
}
/// Acquires one additional diagnostic report reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live report from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_diagnostics_retain(value: *const TypstDiagnostics) {
    unsafe { retain(value) }
}
/// Releases one owned diagnostic report reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a report reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_diagnostics_release(value: *const TypstDiagnostics) {
    unsafe { release(value) }
}
/// Acquires one additional module reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live module from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_module_retain(value: *const TypstModule) {
    unsafe { retain(value) }
}
/// Releases one owned module reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a module reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_module_release(value: *const TypstModule) {
    unsafe { release(value) }
}
