//! Stable C entry points and their pointer, ownership and panic contracts.
//!
//! # Pointer and ownership contract
//!
//! Input records and nonempty views must point to aligned, initialized, readable
//! storage covering the declared prefix or array. Views may use null for zero
//! length. Inputs, including nested views, remain immutable for the entire call.
//! A versioned options record must expose its declared prefix, capped at the
//! known record size; a null options pointer selects defaults.
//!
//! Output pointers must address aligned, writable storage of the declared type,
//! disjoint from inputs and other outputs. An optional diagnostics output may be
//! null; otherwise it must be an empty writable handle slot. Reusing a slot or a
//! batch array does not release its previous owners: release those first.
//!
//! Every non-null opaque handle must have the correct type, originate from this
//! loaded library instance, and keep an owned reference alive throughout a call
//! or view read. Handles are immutable and reference counted. Each owned return
//! or retain requires one matching release; never free them with another
//! allocator. Borrowed views must not be mutated or used after the owner's last
//! release. Releasing other references concurrently is allowed while a reference
//! remains alive for each call or borrowed view. Keep the library mapped while
//! its handles, views, native workers, or thread-local destructors can use it.
use crate::{
    abi::*,
    diagnostics::Report,
    error::{discard_panic, panic_error, Error},
    handles::*,
    layout::metrics,
    scene::{PathStyle, SceneCommand, SceneContent, StrokeStyle},
};
use rayon::prelude::*;
use std::{
    mem::{align_of, size_of},
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
    sync::Arc,
};

mod context;
mod export;
mod layout;
mod library;
mod lifetime;
mod request;
mod scene;
mod value;
mod views;

fn owned<T>(value: T) -> *mut T {
    Arc::into_raw(Arc::new(value)).cast_mut()
}

unsafe fn required<'a, T>(value: *const T, label: &str) -> Result<&'a T, Error> {
    check_ptr(value, label)?;
    Ok(unsafe { &*value })
}
fn check_ptr<T>(value: *const T, label: &str) -> Result<(), Error> {
    if value.is_null() || !(value as usize).is_multiple_of(align_of::<T>()) {
        return Err(Error::invalid(format!(
            "{label} must be a non-null aligned pointer"
        )));
    }
    Ok(())
}
fn check_values<T>(data: *const T, len: usize, label: &str) -> Result<(), Error> {
    if len == 0 {
        return Ok(());
    }
    check_ptr(data, label)?;
    if len > isize::MAX as usize / size_of::<T>().max(1) {
        return Err(Error::invalid(format!("invalid {label} length")));
    }
    Ok(())
}
unsafe fn values<'a, T>(data: *const T, len: usize, label: &str) -> Result<&'a [T], Error> {
    if len == 0 {
        return Ok(&[]);
    }
    check_values(data, len, label)?;
    Ok(unsafe { std::slice::from_raw_parts(data, len) })
}
unsafe fn text<'a>(value: TypstStr, label: &str) -> Result<&'a str, Error> {
    let bytes = unsafe { values(value.data, value.len, label)? };
    std::str::from_utf8(bytes).map_err(|error| {
        Error::utf8(format!(
            "invalid UTF-8 in {label} at byte {}",
            error.valid_up_to()
        ))
    })
}

unsafe fn options<T: Copy + Default>(value: *const T) -> Result<T, Error> {
    if value.is_null() {
        return Ok(T::default());
    }
    check_ptr(value, "options")?;
    let length = unsafe { value.cast::<u32>().read() } as usize;
    if length != size_of::<u32>() && (length < 8 || !length.is_multiple_of(align_of::<T>())) {
        return Err(Error::invalid(
            "options.struct_size must contain its header and end at an aligned field boundary",
        ));
    }
    let mut result = T::default();
    unsafe {
        ptr::copy_nonoverlapping(
            value.cast::<u8>(),
            (&mut result as *mut T).cast::<u8>(),
            length.min(size_of::<T>()),
        );
    }
    Ok(result)
}

unsafe fn report(out: *mut *mut TypstDiagnostics, value: Report) {
    if !out.is_null() && !value.entries.is_empty() {
        unsafe {
            out.write(owned(TypstDiagnostics { inner: value }));
        }
    }
}

unsafe fn call(
    out: *mut *mut TypstDiagnostics,
    action: impl FnOnce() -> Result<Report, Error>,
) -> TypstStatus {
    if !out.is_null() {
        unsafe {
            out.write(ptr::null_mut());
        }
    }
    let result =
        catch_unwind(AssertUnwindSafe(action)).unwrap_or_else(|payload| Err(panic_error(payload)));
    match result {
        Ok(value) => {
            unsafe {
                report(out, value);
            }
            TYPST_OK
        }
        Err(error) => {
            unsafe {
                report(out, error.report);
            }
            error.status
        }
    }
}
unsafe fn output<T>(out: *mut *mut T) -> Result<(), Error> {
    if out.is_null() || !(out as usize).is_multiple_of(align_of::<*mut T>()) {
        return Err(Error::invalid(
            "output handle must be a non-null aligned pointer",
        ));
    }
    unsafe {
        out.write(ptr::null_mut());
    }
    Ok(())
}
unsafe fn retain<T>(value: *const T) {
    if !value.is_null() {
        unsafe {
            Arc::increment_strong_count(value);
        }
    }
}
unsafe fn release<T>(value: *const T) {
    if !value.is_null() {
        if let Err(payload) = catch_unwind(AssertUnwindSafe(|| unsafe {
            Arc::decrement_strong_count(value)
        })) {
            discard_panic(payload);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::lifetime::*;

    #[test]
    fn panic_stays_inside_the_ffi_call_and_has_an_owned_diagnostic() {
        let mut diagnostic = ptr::null_mut();
        let status = unsafe {
            call(&mut diagnostic, || {
                panic!("panic payload with unicode Ω and NUL \0")
            })
        };
        assert_eq!(status, TYPST_PANIC);
        assert!(!diagnostic.is_null());
        let owner = unsafe { &*diagnostic };
        let entry = &owner.inner.entries[0];
        assert!(entry.message.contains("Ω and NUL \0"));
        unsafe {
            typst_diagnostics_release(diagnostic);
        }
    }
    #[test]
    fn invalid_views_and_partial_options_are_rejected_before_borrowing() {
        assert!(unsafe { values::<u64>(ptr::null(), 1, "test") }.is_err());
        assert!(unsafe { values::<u64>(ptr::dangling(), usize::MAX, "test") }.is_err());
        let header = [9u32, 0];
        assert!(unsafe { options::<TypstContextOptions>(header.as_ptr().cast()) }.is_err());
        assert!(unsafe {
            text(
                TypstStr {
                    data: [0xff].as_ptr(),
                    len: 1,
                },
                "test",
            )
        }
        .is_err());
    }
}
