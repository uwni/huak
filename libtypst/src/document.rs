//! Full document compilation, including upstream introspection convergence.
use typst_layout::PagedDocument;

use crate::context::Context;
use crate::diagnostics::Report;
use crate::error::Error;

pub(crate) struct Document {
    pub(crate) document: PagedDocument,
}

impl Context {
    pub(crate) fn compile(
        &self,
        source: &str,
        source_name: &str,
    ) -> Result<(Document, Report), Error> {
        let world = self.world(source, source_name)?;
        let result = typst_core::compile::<PagedDocument>(&world);
        let mut report = Report::from_native(&world, &result.warnings, usize::MAX);
        match result.output {
            Ok(document) => Ok((Document { document }, report)),
            Err(errors) => {
                report.merge(Report::from_native(&world, &errors, usize::MAX));
                Err(Error::compile(report))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn documents_compile_imports_inputs_and_multiple_pages() {
        let context = Context::new(
            vec![],
            vec![],
            vec![
                ("parts/title.typ".into(), b"#let title = [Imported title]".to_vec()),
                ("icon.svg".into(), br##"<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><rect width="12" height="8" fill="#2966cc"/></svg>"##.to_vec()),
            ],
            r#"{"name":"reader","count":3}"#,
            0,
        )
        .unwrap();
        let (document, _) = context.compile(
            "#import \"parts/title.typ\": title\n#set heading(numbering: \"1.\")\n= #title <title>\nHello #sys.inputs.name\n#image(\"icon.svg\", width: 12pt)\nSee @title.\n#pagebreak()\n$ x^2 $",
            "book.typ",
        ).unwrap();
        assert_eq!(document.document.pages().len(), 2);
        let resources = Arc::downgrade(&context.resources);
        drop(context);
        assert!(resources.upgrade().is_none());
        let svg = typst_svg::svg(&document.document.pages()[0], &Default::default());
        assert!(svg.starts_with("<svg"));
        assert!(svg.contains("<use"));
        let pdf = typst_pdf::pdf(&document.document, &Default::default()).unwrap();
        assert!(pdf.starts_with(b"%PDF-"));
    }

    #[test]
    fn a_failed_document_does_not_poison_later_jobs() {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        let failure = context.compile("#unknown_value", "broken.typ");
        assert!(failure.is_err());
        let (document, _) = context.compile("Recovered", "valid.typ").unwrap();
        assert_eq!(document.document.pages().len(), 1);
    }
}
