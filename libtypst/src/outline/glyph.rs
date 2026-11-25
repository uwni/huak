//! Editable glyph outlines decoded from the font tables of shaped text.
use super::{affine, point, segment, Outline};
use crate::{abi::*, error::Error};
use ttf_parser::{GlyphId, OutlineBuilder};
use typst_core::{
    layout::{Point, Ratio, Transform},
    text::TextItem,
    visualize::FillRule,
};

impl Outline {
    pub(super) fn text(&mut self, text: &TextItem, at: Transform) -> Result<(), Error> {
        let style = self.style(Some(&text.fill), FillRule::NonZero, text.stroke.as_ref())?;
        let run_index = self.run_texts.len();
        self.run_texts.push(text.text.to_string());
        let run_text = self.run_texts[run_index].as_str();
        let scale = text.size.to_pt() / text.font.units_per_em();
        if !scale.is_finite() || scale <= 0.0 {
            return Err(Error::unsupported(
                "font metrics cannot produce finite glyph paths",
            ));
        }
        let upright = at.pre_concat(Transform::scale(Ratio::one(), -Ratio::one()));
        let linear = Transform {
            tx: Default::default(),
            ty: Default::default(),
            ..upright
        };
        let face = text.font.ttf();
        let mut cursor = Point::zero();
        for glyph in &text.glyphs {
            let range = glyph.range();
            if run_text.get(range.clone()).is_none() {
                return Err(Error::unsupported(
                    "native glyph cluster does not identify valid UTF-8 text",
                ));
            }
            let id = GlyphId(glyph.id);
            if !typst_core::text::color::should_outline(&text.font, id) {
                return Err(Error::unsupported(
                    "editable paths do not support bitmap, SVG, color, or fallback-image glyphs",
                ));
            }
            let offset =
                cursor + Point::new(glyph.x_offset.at(text.size), glyph.y_offset.at(text.size));
            let transform = upright.pre_concat(Transform::translate(offset.x, offset.y));
            let first = self.segments.len();
            let mut builder = GlyphBuilder {
                segments: &mut self.segments,
                scale,
                current: TypstPoint::default(),
                start: TypstPoint::default(),
            };
            let bounds = face.outline_glyph(id, &mut builder);
            let count = self.segments.len() - first;
            if bounds.is_none() && (count != 0 || !empty_glyph(face, id)) {
                return Err(Error::unsupported(
                    "a glyph outline could not be decoded completely",
                ));
            }
            if self.segments[first..].iter().any(|segment| {
                [segment.p1, segment.p2, segment.p3]
                    .iter()
                    .any(|p| !p.x.is_finite() || !p.y.is_finite())
            }) {
                return Err(Error::unsupported(
                    "a glyph outline contains nonfinite coordinates",
                ));
            }
            let advance = Point::new(glyph.x_advance.at(text.size), glyph.y_advance.at(text.size));
            self.paths.push(TypstOutlinedPath {
                segment_offset: first,
                segment_count: count,
                transform: affine(transform)?,
                kind: TYPST_OUTLINE_GLYPH,
                glyph_id: u32::from(glyph.id),
                run_index,
                run_text: TypstStr::view(run_text),
                cluster_start: range.start,
                cluster_end: range.end,
                advance: point(advance.transform(linear))?,
                ..style
            });
            cursor += advance;
        }
        Ok(())
    }
}

// The high-level decoder conflates empty and malformed outlines. Ask its
// public table APIs for the distinction instead of parsing font data here.
fn empty_glyph(face: &ttf_parser::Face<'_>, glyph: GlyphId) -> bool {
    let id = glyph.0;
    if id >= face.number_of_glyphs() {
        return false;
    }
    let tables = face.tables();
    if tables.glyf.is_some() {
        let empty = (|| {
            let next = id.checked_add(1)?;
            let loca = ttf_parser::loca::Table::parse(
                tables.maxp.number_of_glyphs,
                tables.head.index_to_location_format,
                face.raw_face()
                    .table(ttf_parser::Tag::from_bytes(b"loca"))?,
            )?;
            let (start, end) = match loca {
                ttf_parser::loca::Table::Short(offsets) => (
                    usize::from(offsets.get(id)?) * 2,
                    usize::from(offsets.get(next)?) * 2,
                ),
                ttf_parser::loca::Table::Long(offsets) => (
                    usize::try_from(offsets.get(id)?).ok()?,
                    usize::try_from(offsets.get(next)?).ok()?,
                ),
            };
            let data = face
                .raw_face()
                .table(ttf_parser::Tag::from_bytes(b"glyf"))?;
            Some(start == end && end <= data.len())
        })();
        return empty == Some(true);
    }
    let mut emitted = HasContour::default();
    let result = if let Some(cff) = &tables.cff {
        cff.outline(glyph, &mut emitted)
    } else if let Some(cff) = &tables.cff2 {
        cff.outline(face.variation_coordinates(), glyph, &mut emitted)
    } else {
        return false;
    };
    result == Err(ttf_parser::CFFError::ZeroBBox) && !emitted.0
}

#[derive(Default)]
struct HasContour(bool);
impl OutlineBuilder for HasContour {
    fn move_to(&mut self, _: f32, _: f32) {
        self.0 = true;
    }
    fn line_to(&mut self, _: f32, _: f32) {
        self.0 = true;
    }
    fn quad_to(&mut self, _: f32, _: f32, _: f32, _: f32) {
        self.0 = true;
    }
    fn curve_to(&mut self, _: f32, _: f32, _: f32, _: f32, _: f32, _: f32) {
        self.0 = true;
    }
    fn close(&mut self) {
        self.0 = true;
    }
}

struct GlyphBuilder<'a> {
    segments: &'a mut Vec<TypstPathSegment>,
    scale: f64,
    current: TypstPoint,
    start: TypstPoint,
}
impl GlyphBuilder<'_> {
    fn point(&self, x: f32, y: f32) -> TypstPoint {
        TypstPoint {
            x: f64::from(x) * self.scale,
            y: f64::from(y) * self.scale,
        }
    }
}
impl OutlineBuilder for GlyphBuilder<'_> {
    fn move_to(&mut self, x: f32, y: f32) {
        let point = self.point(x, y);
        self.segments.push(segment(
            TYPST_SEGMENT_MOVE,
            point,
            TypstPoint::default(),
            TypstPoint::default(),
        ));
        self.current = point;
        self.start = point;
    }
    fn line_to(&mut self, x: f32, y: f32) {
        let point = self.point(x, y);
        self.segments.push(segment(
            TYPST_SEGMENT_LINE,
            point,
            TypstPoint::default(),
            TypstPoint::default(),
        ));
        self.current = point;
    }
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        let control = self.point(x1, y1);
        let end = self.point(x, y);
        let cubic = kurbo::QuadBez::new(
            (self.current.x, self.current.y),
            (control.x, control.y),
            (end.x, end.y),
        )
        .raise();
        let [a, b] = [cubic.p1, cubic.p2].map(|p| TypstPoint { x: p.x, y: p.y });
        self.segments.push(segment(TYPST_SEGMENT_CUBIC, a, b, end));
        self.current = end;
    }
    fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
        let a = self.point(x1, y1);
        let b = self.point(x2, y2);
        let end = self.point(x, y);
        self.segments.push(segment(TYPST_SEGMENT_CUBIC, a, b, end));
        self.current = end;
    }
    fn close(&mut self) {
        self.segments.push(segment(
            TYPST_SEGMENT_CLOSE,
            TypstPoint::default(),
            TypstPoint::default(),
            TypstPoint::default(),
        ));
        self.current = self.start;
    }
}

#[cfg(test)]
// The shared native-reference fixture also exposes integration-only helpers.
#[allow(dead_code)]
#[path = "../../tests/support/world.rs"]
mod test_world;

#[cfg(test)]
mod tests {
    use super::super::from_frame;
    use super::*;

    #[test]
    fn quadratic_decoder_segments_convert_exactly_to_cubic() {
        let mut segments = Vec::new();
        let mut builder = GlyphBuilder {
            segments: &mut segments,
            scale: 2.0,
            current: TypstPoint::default(),
            start: TypstPoint::default(),
        };
        builder.move_to(0.0, 0.0);
        builder.quad_to(3.0, 6.0, 9.0, 0.0);
        assert_eq!(segments[1].kind, TYPST_SEGMENT_CUBIC);
        assert_eq!((segments[1].p1.x, segments[1].p1.y), (4.0, 8.0));
        assert_eq!((segments[1].p2.x, segments[1].p2.y), (10.0, 8.0));
        assert_eq!((segments[1].p3.x, segments[1].p3.y), (18.0, 0.0));
    }

    #[test]
    fn empty_glyphs_are_distinguished_from_damaged_outline_data() {
        let resources = test_world::Resources::shared();
        for font in &resources.fonts {
            let face = ttf_parser::Face::parse(font.data().as_slice(), font.index()).unwrap();
            if let Some(space) = face.glyph_index(' ') {
                assert!(empty_glyph(&face, space));
            }
            if let Some(ink) = face.glyph_index('A') {
                assert!(!empty_glyph(&face, ink));
            }
            assert!(!empty_glyph(&face, GlyphId(face.number_of_glyphs())));
        }

        let (font, face) = resources
            .fonts
            .iter()
            .find_map(|font| {
                let face = ttf_parser::Face::parse(font.data().as_slice(), font.index()).unwrap();
                face.tables().glyf.is_some().then_some((font, face))
            })
            .unwrap();
        let ink = face.glyph_index('A').unwrap();
        let tables = face.tables();
        let loca = ttf_parser::loca::Table::parse(
            tables.maxp.number_of_glyphs,
            tables.head.index_to_location_format,
            face.raw_face()
                .table(ttf_parser::Tag::from_bytes(b"loca"))
                .unwrap(),
        )
        .unwrap();
        let range = loca.glyph_range(ink).unwrap();
        let record = face
            .raw_face()
            .table_records
            .into_iter()
            .find(|record| record.tag == ttf_parser::Tag::from_bytes(b"glyf"))
            .unwrap();
        let mut data = font.data().as_slice().to_vec();
        let start = record.offset as usize;
        data[start + range.start..start + range.end].fill(0x7f);
        let damaged = ttf_parser::Face::parse(&data, font.index()).unwrap();
        assert!(damaged
            .outline_glyph(ink, &mut HasContour::default())
            .is_none());
        assert!(!empty_glyph(&damaged, ink));
    }

    #[test]
    fn real_text_and_math_rules_round_trip_as_native_scene_paths() {
        use crate::scene::{PathStyle, Scene, SceneCommand, SceneContent, StrokeStyle};
        use test_world::{MemoryWorld, Resources};
        let world = MemoryWorld::new(Resources::shared(), "#set page(width: auto, height: auto, margin: 0pt)\n#set text(font: \"Libertinus Serif\", size: 20pt)\ncafé office $ frac(1, 2) + x^2 $");
        let document = typst_core::compile::<typst_layout::PagedDocument>(&world)
            .output
            .unwrap();
        let frame = &document.pages()[0].frame;
        let outline = from_frame(frame).unwrap();
        let width = frame.width().to_pt();
        let height = frame.height().to_pt();
        drop(document);
        drop(world);
        assert!(outline.run_count() > 0);
        let mut saw_space = false;
        for path in &outline.paths {
            if path.kind == TYPST_OUTLINE_GLYPH {
                assert!(path.run_index < outline.run_count());
                let bytes =
                    unsafe { std::slice::from_raw_parts(path.run_text.data, path.run_text.len) };
                let text = std::str::from_utf8(bytes).unwrap();
                let cluster = text.get(path.cluster_start..path.cluster_end).unwrap();
                if cluster == " " {
                    saw_space = true;
                    assert_eq!(path.segment_count, 0);
                }
            } else {
                assert_eq!(path.kind, TYPST_OUTLINE_SHAPE);
                assert_eq!(path.glyph_id, u32::MAX);
                assert_eq!(path.run_index, usize::MAX);
            }
        }
        assert!(saw_space);
        assert!(outline.paths.len() > 8);
        assert!(outline
            .paths
            .iter()
            .any(|path| path.flags & TYPST_STYLE_STROKE != 0));
        let commands = outline
            .paths
            .iter()
            .map(|path| SceneCommand {
                content: SceneContent::Path {
                    segments: &outline.segments[path.segment_offset..][..path.segment_count],
                    style: PathStyle {
                        fill: (path.flags & TYPST_STYLE_FILL != 0).then_some(path.fill),
                        fill_gradient: None,
                        stroke_gradient: None,
                        fill_rule: path.fill_rule,
                        stroke: (path.flags & TYPST_STYLE_STROKE != 0).then(|| StrokeStyle {
                            color: path.stroke,
                            width_pt: path.stroke_width_pt,
                            line_cap: path.line_cap,
                            line_join: path.line_join,
                            miter_limit: path.miter_limit,
                            dashes: &outline.dashes[path.dash_offset..][..path.dash_count],
                            dash_phase_pt: path.dash_phase_pt,
                        }),
                    },
                },
                transform: path.transform,
                clip: None,
                tag: None,
                isolate_transform: false,
            })
            .collect();
        let scene = Scene::new(width, height, commands).unwrap();
        drop(outline);
        let output = crate::export::svg(&crate::export::from_frame(&scene.frame), 0).unwrap();
        assert!(output.starts_with(b"<svg"));
        assert!(output.windows(b"<path".len()).any(|part| part == b"<path"));
    }
}
