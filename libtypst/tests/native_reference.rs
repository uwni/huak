//! A native reference for the binding acceptance tests. This verifies the test
//! host independently; it is not a substitute for calling the dynamic library.
mod support;

use std::sync::Arc;
use support::world::{MemoryWorld, Resources, MIXED_SOURCE};
use typst_layout::PagedDocument;

#[test]
fn native_reference_produces_real_vector_output_with_font_text() {
    let world = MemoryWorld::new(Resources::shared(), MIXED_SOURCE);
    let result = typst_core::compile::<PagedDocument>(&world);
    assert!(result.warnings.is_empty(), "{:?}", result.warnings);
    let document = result.output.expect("native reference compilation failed");
    assert_eq!(document.pages().len(), 1);

    let svg = typst_svg::svg(&document.pages()[0], &typst_svg::SvgOptions::default());
    assert!(svg.starts_with("<svg"));
    assert!(svg.ends_with("</svg>"));
    assert!(svg.contains("<path"));
    assert!(svg.contains("<use"));
    assert!(svg.contains("fill=\"#68a8d8\""));

    let pdf = typst_pdf::pdf(&document, &typst_pdf::PdfOptions::default())
        .expect("native reference PDF export failed");
    assert!(pdf.starts_with(b"%PDF-"));
    assert!(pdf.windows(b"/FontFile".len()).any(|v| v == b"/FontFile"));
    assert!(pdf.windows(b"/ToUnicode".len()).any(|v| v == b"/ToUnicode"));
}

#[test]
fn native_reference_reuses_resources_across_errors_and_source_changes() {
    let resources = Resources::shared();
    let mut world = MemoryWorld::new(resources.clone(), MIXED_SOURCE);
    let other = MemoryWorld::new(Resources::shared(), "Independent document");
    assert!(Arc::ptr_eq(&world.resources, &other.resources));

    for _ in 0..3 {
        let document = typst_core::compile::<PagedDocument>(&world)
            .output
            .expect("repeated native reference compilation failed");
        assert_eq!(document.pages().len(), 1);
    }
    world.replace_source("#unknown_reference_name");
    let errors = typst_core::compile::<PagedDocument>(&world)
        .output
        .expect_err("unknown names must produce source diagnostics");
    assert!(errors
        .iter()
        .any(|error| error.message.contains("unknown_reference_name")));

    world.replace_source(MIXED_SOURCE);
    let recovered = typst_core::compile::<PagedDocument>(&world)
        .output
        .expect("source replacement must recover after a normal error");
    assert_eq!(recovered.pages().len(), 1);
    assert!(Arc::ptr_eq(&resources, &world.resources));
}
