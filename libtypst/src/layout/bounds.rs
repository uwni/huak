//! Conservative native frame bounds, without extracting or flattening glyphs.
use typst_core::layout::{Frame, FrameItem, Point, Ratio, Rect, Transform};
use typst_core::text::color::{glyph_frame, should_outline, GlyphFrameItem};
use typst_core::utils::Numeric;
use typst_core::visualize::FixedStroke;

/// Includes the logical frame and all painted items. Native clips can only
/// reduce this extent, so ignoring them preserves a conservative result.
#[comemo::memoize]
pub(super) fn bounds(frame: &Frame) -> Option<Rect> {
    let mut result = Rect::from_pos_size(Point::zero(), frame.size());
    if !result.max.x.is_finite() || !result.max.y.is_finite() {
        return None;
    }
    let mut pending = vec![(frame, Transform::identity())];
    while let Some((frame, parent)) = pending.pop() {
        for (position, item) in frame.items() {
            let at = parent.pre_concat(Transform::translate(position.x, position.y));
            match item {
                FrameItem::Group(group) => {
                    pending.push((&group.frame, at.pre_concat(group.transform)));
                }
                FrameItem::Text(text) => {
                    let bbox = text.bbox();
                    // Empty/space-only runs have no font bounding box.
                    if bbox.min.x.is_finite() && bbox.max.x.is_finite() {
                        let bbox = Rect::new(bbox.min.min(bbox.max), bbox.min.max(bbox.max));
                        include(&mut result, with_stroke(bbox, text.stroke.as_ref()), at)?;
                    }
                    let mut cursor = Point::zero();
                    for glyph in &text.glyphs {
                        if !should_outline(&text.font, ttf_parser::GlyphId(glyph.id)) {
                            if let Some(frame) = glyph_frame(&text.font, glyph.id) {
                                let offset = cursor
                                    + Point::new(
                                        glyph.x_offset.at(text.size),
                                        glyph.y_offset.at(text.size),
                                    );
                                let scale =
                                    Ratio::new(text.size.to_pt() / text.font.units_per_em());
                                let transform = at
                                    .pre_concat(Transform::translate(offset.x, -offset.y))
                                    .pre_concat(Transform::scale(scale, scale));
                                let (position, bbox) = match frame.item {
                                    GlyphFrameItem::Tofu(pos, shape) => {
                                        (pos, with_stroke(shape.bbox(false), shape.stroke.as_ref()))
                                    }
                                    GlyphFrameItem::Image(pos, _, size) => {
                                        (pos, Rect::from_pos_size(Point::zero(), size))
                                    }
                                };
                                include(
                                    &mut result,
                                    bbox,
                                    transform
                                        .pre_concat(Transform::translate(position.x, position.y)),
                                )?;
                            }
                        }
                        cursor += Point::new(
                            glyph.x_advance.at(text.size),
                            glyph.y_advance.at(text.size),
                        );
                    }
                }
                FrameItem::Shape(shape, _) => include(
                    &mut result,
                    with_stroke(shape.bbox(false), shape.stroke.as_ref()),
                    at,
                )?,
                FrameItem::Image(_, size, _) => {
                    include(&mut result, Rect::from_pos_size(Point::zero(), *size), at)?
                }
                FrameItem::Link(_, _) | FrameItem::Tag(_) => {}
            }
        }
    }
    Some(result)
}

// Native curve stroke bounding reconstructs an approximate offset curve.
// A conservative extent only needs the native centerline/glyph box plus the
// maximum cap/join reach; no outline construction or flattening is necessary.
fn with_stroke(mut bbox: Rect, stroke: Option<&FixedStroke>) -> Rect {
    if let Some(stroke) = stroke {
        let pad = Point::splat(stroke.thickness * (stroke.miter_limit.get().max(2.0) / 2.0));
        bbox.min -= pad;
        bbox.max += pad;
    }
    bbox
}

fn include(result: &mut Rect, bbox: Rect, transform: Transform) -> Option<()> {
    for point in [
        bbox.min,
        bbox.max,
        Point::new(bbox.min.x, bbox.max.y),
        Point::new(bbox.max.x, bbox.min.y),
    ] {
        let point = point.transform(transform);
        if !point.x.is_finite() || !point.y.is_finite() {
            return None;
        }
        result.min = result.min.min(point);
        result.max = result.max.max(point);
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::Context;
    use typst_core::layout::Abs;

    #[test]
    fn overflow_shapes_images_and_transforms_keep_native_bounds() {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        let (text, _) = context
            .layout(
                "#box(width: 1pt, height: 20pt)[#text(size: 20pt)[WWW]]",
                "text.typ",
                &Default::default(),
                0,
            )
            .unwrap();
        let bbox = bounds(&text.frame).unwrap();
        assert_eq!(text.metrics().width_pt, 1.0);
        assert!(bbox.max.x > Abs::pt(50.0));
        for body in [
            "rect(width: 40pt, height: 30pt, fill: gradient.linear(red, blue), stroke: 4pt)",
            "image(bytes(\"<svg xmlns='http://www.w3.org/2000/svg' width='40' height='30'><rect width='40' height='30' fill='red'/></svg>\"), width: 40pt, height: 30pt)",
        ] {
            let source = format!("#box(width: 1pt, height: 1pt)[#move(dx: -20pt, dy: -10pt)[#{body}]]");
            let (layout, _) = context.layout(&source, "paint.typ", &Default::default(), 0).unwrap();
            let bbox = bounds(&layout.frame).unwrap();
            assert!(bbox.min.x <= Abs::pt(-20.0) && bbox.max.x >= Abs::pt(20.0));
            assert!(bbox.min.y <= Abs::pt(-10.0) && bbox.max.y >= Abs::pt(20.0));
        }
    }
}
