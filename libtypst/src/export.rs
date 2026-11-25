//! Export native documents and frames through Typst's public exporters.
use crate::{abi::*, diagnostics::Report, error::Error};
use serde::Deserialize;
use typst_core::{
    foundations::{Content, Smart},
    layout::{Abs, Frame, Sides},
    model::DocumentInfo,
};
use typst_layout::{Page, PagedDocument};
use typst_pdf::{PdfOptions, PdfStandard, PdfStandards};

pub fn page_from_frame(frame: Frame) -> Page {
    Page {
        frame,
        bleed: Sides::splat(Abs::zero()),
        fill: Smart::Custom(None),
        numbering: None,
        supplement: Content::empty(),
        number: 1,
    }
}

pub fn from_frame(frame: &Frame) -> PagedDocument {
    PagedDocument::new(
        vec![page_from_frame(frame.clone())].into(),
        DocumentInfo::default(),
    )
}

pub fn svg(document: &PagedDocument, page: usize) -> Result<Vec<u8>, Error> {
    let page = document
        .pages()
        .get(page)
        .ok_or_else(|| Error::new(TYPST_OUT_OF_RANGE, "SVG page index is out of range"))?;
    Ok(typst_svg::svg(page, &typst_svg::SvgOptions::default()).into_bytes())
}

pub fn pdf(document: &PagedDocument, standard: &str, creator: &str) -> Result<Vec<u8>, Error> {
    let mut options = PdfOptions::default();
    if !standard.is_empty() {
        let value = PdfStandard::deserialize(serde::de::value::BorrowedStrDeserializer::<
            serde::de::value::Error,
        >::new(standard))
        .map_err(|error| Error::invalid(error.to_string()))?;
        options.standards = PdfStandards::new(&[value])
            .map_err(|error| Error::invalid(error.message().to_string()))?;
    }
    if !creator.is_empty() {
        options.creator = Smart::Custom(Some(creator.into()));
    }
    typst_pdf::pdf(document, &options)
        .map_err(|errors| Error::compile(Report::from_native_unlocated(&errors, usize::MAX)))
}

/// A page of the size of page `page` of `data` that draws it inside one
/// transparency group at `opacity`, so that it blends with what lies under it
/// as a whole. Typst's groups have no opacity; krilla, the writer typst-pdf
/// drives, has. The result declares the input's PDF version, at least 1.4,
/// so it embeds wherever the input does.
pub fn pdf_page_with_opacity(data: &[u8], page: usize, opacity: f64) -> Result<Vec<u8>, Error> {
    use hayro_syntax::PdfVersion as Declared;
    use krilla::configure::{ConfigurationBuilder, PdfVersion};
    use krilla::{geom::Size, num::NormalizedF32, page::PageSettings, pdf, Document};

    let opacity = (0.0..=1.0)
        .contains(&opacity)
        .then(|| NormalizedF32::new(opacity as f32))
        .flatten()
        .ok_or_else(|| Error::invalid("opacity must lie between 0 and 1"))?;
    let source = pdf::Pdf::new(data.to_vec())
        .map_err(|error| Error::invalid(format!("PDF data cannot be read: {error:?}")))?;
    let (width, height) = source
        .pages()
        .get(page)
        .ok_or_else(|| Error::range("PDF page index is out of range"))?
        .render_dimensions();
    let size =
        Size::from_wh(width, height).ok_or_else(|| Error::invalid("PDF page has no area"))?;
    let version = match source.version() {
        Declared::Pdf10 | Declared::Pdf11 | Declared::Pdf12 | Declared::Pdf13 | Declared::Pdf14 => {
            PdfVersion::Pdf14
        }
        Declared::Pdf15 => PdfVersion::Pdf15,
        Declared::Pdf16 => PdfVersion::Pdf16,
        Declared::Pdf17 => PdfVersion::Pdf17,
        Declared::Pdf20 => PdfVersion::Pdf20,
    };
    let configuration = ConfigurationBuilder::new()
        .with_version(version)
        .finish()
        .map_err(|error| Error::invalid(format!("{error:?}")))?;
    let mut document = Document::new_with(krilla::SerializeSettings {
        configuration,
        ..Default::default()
    });
    let mut sheet = document.start_page_with(PageSettings::new(size));
    let mut surface = sheet.surface();
    surface.push_opacity(opacity);
    surface.draw_pdf_page(
        &pdf::PdfDocument::new(std::sync::Arc::new(source)),
        size,
        page,
    );
    surface.pop();
    surface.finish();
    sheet.finish();
    document
        .finish()
        .map_err(|error| Error::invalid(format!("PDF page cannot be embedded: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use typst_core::{
        layout::{FrameItem, Point, Size},
        syntax::Span,
        visualize::{Color, Curve, Geometry, Paint, Shape},
    };

    fn frame() -> Frame {
        let mut frame = Frame::hard(Size::new(Abs::pt(50.0), Abs::pt(30.0)));
        frame.push(
            Point::zero(),
            FrameItem::Shape(
                Shape {
                    geometry: Geometry::Curve(Curve::rect(Size::new(Abs::pt(20.0), Abs::pt(10.0)))),
                    fill: Some(Paint::Solid(Color::from_u8(20, 40, 80, 200))),
                    fill_rule: Default::default(),
                    stroke: None,
                },
                Span::detached(),
            ),
        );
        frame
    }

    #[test]
    fn native_frame_exports_real_svg_and_pdf() {
        let frame = frame();
        let page = page_from_frame(frame.clone());
        let svg = typst_svg::svg(&page, &typst_svg::SvgOptions::default()).into_bytes();
        assert!(svg.starts_with(b"<svg") && svg.ends_with(b"</svg>"));
        assert!(svg.windows(b"<path".len()).any(|part| part == b"<path"));
        let document = from_frame(&frame);
        assert_eq!(svg, super::svg(&document, 0).unwrap());
        assert!(pdf(&document, "", "").unwrap().starts_with(b"%PDF-"));
        assert!(pdf(&document, "1.4", "").unwrap().starts_with(b"%PDF-1.4"));
    }

    #[test]
    fn options_use_upstream_standard_names_and_range_errors() {
        let document = from_frame(&frame());
        assert!(pdf(&document, "not-a-pdf-standard", "").is_err());
        assert!(svg(&document, 1).is_err());
    }

    #[test]
    fn page_with_opacity_is_one_group_on_a_page_of_the_same_size_and_version() {
        let document = from_frame(&frame());
        for (standard, version) in [
            ("", hayro_syntax::PdfVersion::Pdf17),
            ("1.4", hayro_syntax::PdfVersion::Pdf14),
            ("2.0", hayro_syntax::PdfVersion::Pdf20),
        ] {
            let bytes = pdf(&document, standard, "").unwrap();
            let wrapped = pdf_page_with_opacity(&bytes, 0, 0.5).unwrap();
            let result = hayro_syntax::Pdf::new(wrapped.clone()).unwrap();
            assert_eq!(result.version(), version);
            assert_eq!(result.pages().len(), 1);
            let source = hayro_syntax::Pdf::new(bytes).unwrap();
            assert_eq!(
                result.pages()[0].render_dimensions(),
                source.pages()[0].render_dimensions()
            );
            let text = String::from_utf8_lossy(&wrapped);
            assert!(text.contains("/Group<</Type/Group/S/Transparency/I true"));
            assert!(text.contains("/ca 0.5"));
        }
        let bytes = pdf(&document, "", "").unwrap();
        for opacity in [-0.1, 1.5, f64::NAN] {
            let error = pdf_page_with_opacity(&bytes, 0, opacity).unwrap_err();
            assert_eq!(error.status, TYPST_INVALID_ARGUMENT);
        }
        assert_eq!(
            pdf_page_with_opacity(&bytes, 1, 0.5).unwrap_err().status,
            TYPST_OUT_OF_RANGE
        );
        assert_eq!(
            pdf_page_with_opacity(b"not a PDF", 0, 0.5)
                .unwrap_err()
                .status,
            TYPST_INVALID_ARGUMENT
        );
    }
}
