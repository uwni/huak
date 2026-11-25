//! Optional editable paths decoded from native, already shaped layout objects.
use crate::{abi::*, error::Error, layout::Layout};

use typst_core::{
    layout::{Frame, FrameItem, Point, Transform},
    visualize::{
        Curve, CurveItem, FillRule, FixedStroke, Geometry, LineCap, LineJoin, Paint, Shape,
    },
};

mod glyph;

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

#[cfg(test)]
mod tests {
    use super::*;
    use typst_core::{
        layout::{Abs, Ratio, Size},
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
}
