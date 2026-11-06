//! Optional editable paths decoded from native, already shaped layout objects.
use crate::{abi::*, error::Error, layout::Layout};
use ttf_parser::{GlyphId, OutlineBuilder};

#[cfg(test)]
// The shared native-reference fixture also exposes integration-only helpers.
#[allow(dead_code)]
#[path = "../tests/support/world.rs"]
mod test_world;
use typst_core::{
    layout::{Frame, FrameItem, Point, Ratio, Transform},
    text::TextItem,
    visualize::{
        Curve, CurveItem, FillRule, FixedStroke, Geometry, LineCap, LineJoin, Paint, Shape,
    },
};

#[derive(Default)]
pub struct Outline {
    pub paths: Vec<TypstOutlinedPath>,
    pub segments: Vec<TypstPathSegment>,
    pub dashes: Vec<f64>,
    run_texts: Vec<String>,
}

// Path string views borrow only this object's immutable owned strings. Moving
// String descriptors or Outline does not move their heap buffers.
unsafe impl Send for Outline {}
unsafe impl Sync for Outline {}

pub fn extract(layout: &Layout) -> Result<Outline, Error> {
    from_frame(&layout.frame)
}

fn from_frame(frame: &Frame) -> Result<Outline, Error> {
    let mut output = Outline::default();
    enum Pending<'a> {
        Item(Point, &'a FrameItem, Transform),
        EndClip,
    }
    // Traverse iteratively so deeply nested native groups do not consume the
    // host's call stack. Reversing pending items preserves native paint order.
    let mut pending: Vec<_> = frame
        .items()
        .rev()
        .map(|(pos, item)| Pending::Item(*pos, item, Transform::identity()))
        .collect();
    while let Some(next) = pending.pop() {
        let Pending::Item(position, item, parent) = next else {
            output.paths.push(TypstOutlinedPath {
                kind: TYPST_OUTLINE_END_CLIP,
                ..Default::default()
            });
            continue;
        };
        let at = parent.pre_concat(Transform::translate(position.x, position.y));
        match item {
            FrameItem::Group(group) => {
                let transform = at.pre_concat(group.transform);
                if let Some(clip) = &group.clip {
                    let segment_offset = output.segments.len();
                    output.curve(clip)?;
                    output.paths.push(TypstOutlinedPath {
                        kind: TYPST_OUTLINE_BEGIN_CLIP,
                        segment_offset,
                        segment_count: output.segments.len() - segment_offset,
                        transform: affine(transform)?,
                        ..Default::default()
                    });
                    pending.push(Pending::EndClip);
                }
                pending.extend(
                    group
                        .frame
                        .items()
                        .rev()
                        .map(|(pos, item)| Pending::Item(*pos, item, transform)),
                );
            }
            FrameItem::Text(text) => output.text(text, at)?,
            FrameItem::Shape(shape, _) => output.shape(shape, at)?,
            FrameItem::Image(_, _, _) => {
                return Err(Error::unsupported(
                    "editable paths do not support embedded images",
                ))
            }
            FrameItem::Link(_, _) | FrameItem::Tag(_) => {}
        }
    }
    Ok(output)
}

impl Outline {
    pub fn run_count(&self) -> usize {
        self.run_texts.len()
    }

    fn style(
        &mut self,
        fill: Option<&Paint>,
        rule: FillRule,
        stroke: Option<&FixedStroke>,
    ) -> Result<TypstOutlinedPath, Error> {
        let mut style = TypstOutlinedPath {
            fill_rule: match rule {
                FillRule::NonZero => TYPST_FILL_NONZERO,
                FillRule::EvenOdd => TYPST_FILL_EVENODD,
            },
            ..Default::default()
        };
        if let Some(fill) = fill {
            style.flags |= TYPST_STYLE_FILL;
            style.fill = color(fill)?;
        }
        if let Some(stroke) = stroke {
            style.flags |= TYPST_STYLE_STROKE;
            style.stroke = color(&stroke.paint)?;
            style.stroke_width_pt = stroke.thickness.to_pt();
            style.line_cap = match stroke.cap {
                LineCap::Butt => TYPST_CAP_BUTT,
                LineCap::Round => TYPST_CAP_ROUND,
                LineCap::Square => TYPST_CAP_SQUARE,
            };
            style.line_join = match stroke.join {
                LineJoin::Miter => TYPST_JOIN_MITER,
                LineJoin::Round => TYPST_JOIN_ROUND,
                LineJoin::Bevel => TYPST_JOIN_BEVEL,
            };
            style.miter_limit = stroke.miter_limit.get();
            if let Some(dash) = &stroke.dash {
                style.dash_offset = self.dashes.len();
                style.dash_count = dash.array.len();
                style.dash_phase_pt = dash.phase.to_pt();
                self.dashes
                    .extend(dash.array.iter().map(|value| value.to_pt()));
            }
        }
        Ok(style)
    }

    fn shape(&mut self, shape: &Shape, transform: Transform) -> Result<(), Error> {
        let mut path = self.style(shape.fill.as_ref(), shape.fill_rule, shape.stroke.as_ref())?;
        path.kind = TYPST_OUTLINE_SHAPE;
        path.glyph_id = u32::MAX;
        path.run_index = usize::MAX;
        path.transform = affine(transform)?;
        path.segment_offset = self.segments.len();
        match &shape.geometry {
            Geometry::Line(end) => {
                self.segments.push(segment(
                    TYPST_SEGMENT_MOVE,
                    point(Point::zero())?,
                    TypstPoint::default(),
                    TypstPoint::default(),
                ));
                self.segments.push(segment(
                    TYPST_SEGMENT_LINE,
                    point(*end)?,
                    TypstPoint::default(),
                    TypstPoint::default(),
                ));
            }
            Geometry::Rect(size) => self.curve(&Curve::rect(*size))?,
            Geometry::Curve(curve) => self.curve(curve)?,
        }
        path.segment_count = self.segments.len() - path.segment_offset;
        self.paths.push(path);
        Ok(())
    }

    fn curve(&mut self, curve: &Curve) -> Result<(), Error> {
        for item in &curve.0 {
            self.segments.push(match item {
                CurveItem::Move(p) => segment(
                    TYPST_SEGMENT_MOVE,
                    point(*p)?,
                    TypstPoint::default(),
                    TypstPoint::default(),
                ),
                CurveItem::Line(p) => segment(
                    TYPST_SEGMENT_LINE,
                    point(*p)?,
                    TypstPoint::default(),
                    TypstPoint::default(),
                ),
                CurveItem::Cubic(a, b, c) => {
                    segment(TYPST_SEGMENT_CUBIC, point(*a)?, point(*b)?, point(*c)?)
                }
                CurveItem::Close => segment(
                    TYPST_SEGMENT_CLOSE,
                    TypstPoint::default(),
                    TypstPoint::default(),
                    TypstPoint::default(),
                ),
            });
        }
        Ok(())
    }

    fn text(&mut self, text: &TextItem, at: Transform) -> Result<(), Error> {
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

fn affine(value: Transform) -> Result<TypstTransform, Error> {
    let transform = TypstTransform {
        xx: value.sx.get(),
        yx: value.ky.get(),
        xy: value.kx.get(),
        yy: value.sy.get(),
        dx: value.tx.to_pt(),
        dy: value.ty.to_pt(),
    };
    crate::scene::transform(transform)?;
    Ok(transform)
}
fn point(value: Point) -> Result<TypstPoint, Error> {
    let point = TypstPoint {
        x: value.x.to_pt(),
        y: value.y.to_pt(),
    };
    if !point.x.is_finite() || !point.y.is_finite() {
        return Err(Error::unsupported(
            "native geometry contains nonfinite coordinates",
        ));
    }
    Ok(point)
}
fn color(value: &Paint) -> Result<TypstColor, Error> {
    let Paint::Solid(color) = value else {
        return Err(Error::unsupported(
            "editable paths do not support gradient or tiling paints",
        ));
    };
    let rgba = color.to_rgb();
    let color = TypstColor {
        r: f64::from(rgba.color.red),
        g: f64::from(rgba.color.green),
        b: f64::from(rgba.color.blue),
        a: f64::from(rgba.alpha),
    };
    if ![color.r, color.g, color.b, color.a]
        .into_iter()
        .all(|channel| channel.is_finite() && (0.0..=1.0).contains(&channel))
    {
        return Err(Error::unsupported(
            "native paint cannot be represented by finite RGBA channels",
        ));
    }
    Ok(color)
}
fn segment(kind: u32, p1: TypstPoint, p2: TypstPoint, p3: TypstPoint) -> TypstPathSegment {
    TypstPathSegment {
        kind,
        reserved: 0,
        p1,
        p2,
        p3,
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
mod tests {
    use super::*;
    use typst_core::{
        layout::{Abs, Size},
        syntax::Span,
        visualize::{Color, DashPattern},
    };

    #[test]
    fn nested_native_clips_are_ordered_owned_scopes_with_absolute_transforms() {
        use typst_core::layout::GroupItem;
        let size = Size::new(Abs::pt(20.0), Abs::pt(10.0));
        let mut inner = Frame::hard(size);
        inner.push(
            Point::zero(),
            FrameItem::Shape(
                Shape {
                    geometry: Geometry::Rect(size),
                    fill: Some(Paint::Solid(Color::BLACK)),
                    fill_rule: FillRule::NonZero,
                    stroke: None,
                },
                Span::detached(),
            ),
        );
        let mut clipped = GroupItem::new(inner);
        clipped.clip = Some(Curve::rect(size));
        clipped.transform = Transform::translate(Abs::pt(3.0), Abs::pt(4.0));
        let mut outer = Frame::hard(size);
        outer.push(Point::zero(), FrameItem::Group(clipped));
        let mut clipped = GroupItem::new(outer);
        clipped.clip = Some(Curve::rect(size));
        clipped.transform = Transform::translate(Abs::pt(5.0), Abs::pt(6.0));
        let mut frame = Frame::hard(size);
        frame.push(Point::zero(), FrameItem::Group(clipped));
        let outline = from_frame(&frame).unwrap();
        drop(frame);
        assert_eq!(
            outline.paths.iter().map(|p| p.kind).collect::<Vec<_>>(),
            [
                TYPST_OUTLINE_BEGIN_CLIP,
                TYPST_OUTLINE_BEGIN_CLIP,
                TYPST_OUTLINE_SHAPE,
                TYPST_OUTLINE_END_CLIP,
                TYPST_OUTLINE_END_CLIP,
            ]
        );
        for (index, dx, dy) in [(0, 5.0, 6.0), (1, 8.0, 10.0), (2, 8.0, 10.0)] {
            let path = outline.paths[index];
            assert_eq!(path.transform.dx, dx);
            assert_eq!(path.transform.dy, dy);
            assert_eq!(path.segment_count, 5);
            assert_eq!(
                outline.segments[path.segment_offset].kind,
                TYPST_SEGMENT_MOVE
            );
            assert_eq!(
                outline.segments[path.segment_offset + 4].kind,
                TYPST_SEGMENT_CLOSE
            );
        }
    }

    #[test]
    fn native_shape_outline_preserves_transform_and_stroke_without_flattening() {
        let mut child = Frame::soft(Size::new(Abs::pt(20.0), Abs::pt(10.0)));
        let stroke = FixedStroke {
            thickness: Abs::pt(2.5),
            cap: LineCap::Round,
            join: LineJoin::Bevel,
            dash: Some(DashPattern {
                array: vec![Abs::pt(3.0), Abs::pt(1.0)],
                phase: Abs::pt(0.5),
            }),
            ..Default::default()
        };
        child.push(
            Point::new(Abs::pt(3.0), Abs::pt(4.0)),
            FrameItem::Shape(
                Shape {
                    geometry: Geometry::Rect(child.size()),
                    fill: Some(Paint::Solid(Color::BLACK)),
                    fill_rule: FillRule::EvenOdd,
                    stroke: Some(stroke),
                },
                Span::detached(),
            ),
        );
        let mut group = typst_core::layout::GroupItem::new(child);
        group.transform = Transform {
            sx: Ratio::new(2.0),
            kx: Ratio::new(0.3),
            ty: Abs::pt(11.0),
            ..Transform::identity()
        };
        let mut frame = Frame::hard(Size::new(Abs::pt(80.0), Abs::pt(50.0)));
        frame.push(Point::zero(), FrameItem::Group(group));
        let outline = from_frame(&frame).unwrap();
        assert_eq!(outline.paths.len(), 1);
        let path = outline.paths[0];
        assert_eq!(path.segment_count, 5);
        assert_eq!(path.transform.xx, 2.0);
        assert_eq!(path.transform.xy, 0.3);
        assert_eq!(path.transform.dy, 15.0);
        assert_eq!(path.stroke_width_pt, 2.5);
        assert_eq!(path.fill_rule, TYPST_FILL_EVENODD);
        assert_eq!(path.line_cap, TYPST_CAP_ROUND);
        assert_eq!(path.line_join, TYPST_JOIN_BEVEL);
        assert_eq!(
            &outline.dashes[path.dash_offset..][..path.dash_count],
            &[3.0, 1.0]
        );
    }

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
