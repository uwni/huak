use crate::{abi::*, diagnostics::Report};

#[derive(Debug)]
pub struct Error {
    pub status: TypstStatus,
    pub report: Report,
}
impl Error {
    pub fn new(status: TypstStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            report: Report::message(TYPST_DIAGNOSTIC_ERROR, message),
        }
    }
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(TYPST_INVALID_ARGUMENT, message)
    }
    pub fn utf8(message: impl Into<String>) -> Self {
        Self::new(TYPST_INVALID_UTF8, message)
    }
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new(TYPST_UNSUPPORTED, message)
    }
    pub fn compile(report: Report) -> Self {
        Self {
            status: TYPST_COMPILE_FAILED,
            report,
        }
    }
    pub fn range(message: impl Into<String>) -> Self {
        Self::new(TYPST_OUT_OF_RANGE, message)
    }
    pub fn with_source(mut self, name: &str) -> Self {
        self.report = self.report.with_source(name);
        self
    }
}

pub(crate) fn panic_error(payload: Box<dyn std::any::Any + Send>) -> Error {
    let message = if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_owned()
    } else {
        "non-string Rust panic".to_owned()
    };
    discard_panic(payload);
    Error::new(TYPST_PANIC, format!("Typst panicked: {message}"))
}

pub(crate) fn discard_panic(payload: Box<dyn std::any::Any + Send>) {
    // A custom panic payload may itself panic during Drop. Never let that
    // secondary unwind escape an FFI error or destructor path.
    if let Err(secondary) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(payload)))
    {
        std::mem::forget(secondary);
    }
}
