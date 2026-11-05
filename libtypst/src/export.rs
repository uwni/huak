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

pub fn pdf(document: &PagedDocument, standard: Option<&str>) -> Result<Vec<u8>, Error> {
    let mut options = PdfOptions::default();
    if let Some(standard) = standard.filter(|value| !value.is_empty()) {
        let value = PdfStandard::deserialize(serde::de::value::BorrowedStrDeserializer::<
            serde::de::value::Error,
        >::new(standard))
        .map_err(|error| Error::invalid(error.to_string()))?;
        options.standards = PdfStandards::new(&[value])
            .map_err(|error| Error::invalid(error.message().to_string()))?;
    }
    typst_pdf::pdf(document, &options)
        .map_err(|errors| Error::compile(Report::from_native_unlocated(&errors, usize::MAX)))
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
        assert!(pdf(&document, None).unwrap().starts_with(b"%PDF-"));
        assert!(pdf(&document, Some("1.4"))
            .unwrap()
            .starts_with(b"%PDF-1.4"));
    }

    #[test]
    fn options_use_upstream_standard_names_and_range_errors() {
        let document = from_frame(&frame());
        assert!(pdf(&document, Some("not-a-pdf-standard")).is_err());
        assert!(svg(&document, 1).is_err());
    }
}
