//! Owned diagnostics, independent of the lifetime of a World or Context.
use crate::abi::*;
use typst_core::diag::{Severity, SourceDiagnostic};
use typst_core::syntax::DiagSpan;
use typst_core::{World, WorldExt};

#[derive(Clone, Debug)]
pub struct Diagnostic {
    pub severity: u32,
    pub flags: u32,
    pub message: String,
    pub source_name: String,
    pub range: Option<std::ops::Range<usize>>,
    pub request_index: usize,
    pub notes: Vec<Diagnostic>,
}

impl Diagnostic {
    pub fn view(&self) -> TypstDiagnosticView {
        let (flags, byte_start, byte_end) = match &self.range {
            Some(range) => (TYPST_DIAGNOSTIC_HAS_RANGE, range.start, range.end),
            None => (0, 0, 0),
        };
        TypstDiagnosticView {
            severity: self.severity,
            flags: flags | self.flags,
            message: TypstStr::view(&self.message),
            source_name: TypstStr::view(&self.source_name),
            byte_start,
            byte_end,
            request_index: self.request_index,
            note_count: self.notes.len(),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Report {
    pub entries: Vec<Diagnostic>,
}
impl Report {
    pub fn message(severity: u32, message: impl Into<String>) -> Self {
        Self {
            entries: vec![Diagnostic {
                severity,
                flags: 0,
                message: message.into(),
                source_name: String::new(),
                range: None,
                request_index: usize::MAX,
                notes: Vec::new(),
            }],
        }
    }
    pub fn merge(&mut self, mut other: Self) {
        self.entries.append(&mut other.entries);
    }
    pub fn with_request(mut self, index: usize) -> Self {
        fn assign(diagnostic: &mut Diagnostic, index: usize) {
            diagnostic.request_index = index;
            for note in &mut diagnostic.notes {
                assign(note, index);
            }
        }
        for entry in &mut self.entries {
            assign(entry, index);
        }
        self
    }
    pub fn with_source(mut self, name: &str) -> Self {
        for entry in &mut self.entries {
            if entry.source_name.is_empty() {
                entry.source_name = if name.is_empty() { "main.typ" } else { name }.to_owned();
            }
        }
        self
    }
    pub fn from_native(
        world: &dyn World,
        entries: &[SourceDiagnostic],
        request_index: usize,
    ) -> Self {
        Self::convert(Some(world), entries, request_index)
    }

    fn convert(
        world: Option<&dyn World>,
        entries: &[SourceDiagnostic],
        request_index: usize,
    ) -> Self {
        fn capture(
            world: Option<&dyn World>,
            span: impl Into<DiagSpan>,
            message: String,
            severity: u32,
            request_index: usize,
        ) -> Diagnostic {
            let span = span.into();
            let source_name = span
                .id()
                .map(|id| id.vpath().get_with_slash().to_string())
                .unwrap_or_default();
            let range = world.and_then(|world| world.range(span));
            Diagnostic {
                severity,
                flags: 0,
                message,
                source_name,
                range,
                request_index,
                notes: Vec::new(),
            }
        }
        let entries = entries
            .iter()
            .map(|entry| {
                let severity = match entry.severity {
                    Severity::Error => TYPST_DIAGNOSTIC_ERROR,
                    Severity::Warning => TYPST_DIAGNOSTIC_WARNING,
                };
                let mut diagnostic = capture(
                    world,
                    entry.span,
                    entry.message.to_string(),
                    severity,
                    request_index,
                );
                for hint in &entry.hints {
                    let mut note = capture(
                        world,
                        hint.span,
                        hint.v.to_string(),
                        TYPST_DIAGNOSTIC_NOTE,
                        request_index,
                    );
                    note.flags = TYPST_DIAGNOSTIC_HINT;
                    diagnostic.notes.push(note);
                }
                for trace in &entry.trace {
                    let mut note = capture(
                        world,
                        trace.span,
                        trace.v.to_string(),
                        TYPST_DIAGNOSTIC_NOTE,
                        request_index,
                    );
                    note.flags = TYPST_DIAGNOSTIC_TRACE;
                    diagnostic.notes.push(note);
                }
                diagnostic
            })
            .collect();
        Self { entries }
    }

    /// Export diagnostics need not have an originating World. Preserve their
    /// structured text and notes without fabricating unavailable source ranges.
    pub fn from_native_unlocated(entries: &[SourceDiagnostic], request_index: usize) -> Self {
        Self::convert(None, entries, request_index)
    }
}
