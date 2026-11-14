//! Labeled elements of a layout, read from the introspection tags that Typst
//! places around every labeled element when it realizes content.
use std::ops::Range;

use typst_core::introspection::{Location, Tag};
use typst_core::layout::{Abs, Frame, FrameItem, Point, Rect, Transform};
use typst_core::utils::Numeric;

use super::bounds;
use crate::abi::*;

/// Element records whose label views borrow `names`.
pub(crate) struct Labels {
    elements: Vec<TypstLabeledElement>,
    // Never changed after the records are made. Moving the String or Labels
    // does not move its heap buffer.
    _names: String,
}

unsafe impl Send for Labels {}
unsafe impl Sync for Labels {}

impl Labels {
    pub(crate) fn elements(&self) -> &[TypstLabeledElement] {
        &self.elements
    }
}

struct Element {
    name: Range<usize>,
    position: Point,
    /// Empty while its minimum exceeds its maximum.
    extent: Rect,
}

/// A frame being walked. A group's frame also records how many elements had
/// started before it.
struct Pending<'a> {
    items: std::slice::Iter<'a, (Point, FrameItem)>,
    transform: Transform,
    group: Option<(&'a Frame, usize)>,
}

/// Walks the frame in paint order. An element's extent covers what is laid out
/// between its start and end tags, as `bounds` measures a whole layout: what
/// the items paint and the logical rectangle of each frame. A frame counts
/// only for elements open across all of it; Typst places the tags of an
/// element that begins or ends a paragraph outside the paragraph's frame.
/// None marks non-finite geometry.
pub(super) fn collect(frame: &Frame) -> Option<Labels> {
    let mut names = String::new();
    let mut elements: Vec<Element> = Vec::new();
    // Labeled elements whose end tag is still ahead, by their index.
    let mut open: Vec<(Location, usize)> = Vec::new();
    let mut pending = vec![Pending {
        items: frame.items(),
        transform: Transform::identity(),
        group: None,
    }];
    while let Some(current) = pending.last_mut() {
        let parent = current.transform;
        let mut extent = empty();
        let Some((position, item)) = current.items.next() else {
            if let Some((frame, started)) = current.group {
                // Elements that started before this frame and are still open
                // enclose the whole frame.
                if open.iter().any(|&(_, index)| index < started) {
                    let logical = Rect::from_pos_size(Point::zero(), frame.size());
                    bounds::include(&mut extent, logical, parent)?;
                    extend(&mut elements, &open, started, &extent);
                }
            }
            pending.pop();
            continue;
        };
        let at = parent.pre_concat(Transform::translate(position.x, position.y));
        match item {
            FrameItem::Tag(tag @ Tag::Start(content, _)) => {
                if let Some(label) = content.label() {
                    let start = names.len();
                    names.push_str(&label.resolve());
                    open.push((tag.location(), elements.len()));
                    elements.push(Element {
                        name: start..names.len(),
                        position: finite(Point::zero().transform(at))?,
                        extent: empty(),
                    });
                }
            }
            FrameItem::Tag(Tag::End(location, ..)) => {
                if let Some(index) = open.iter().rposition(|(open, _)| open == location) {
                    open.remove(index);
                }
            }
            FrameItem::Group(group) => pending.push(Pending {
                items: group.frame.items(),
                transform: at.pre_concat(group.transform),
                group: Some((&group.frame, elements.len())),
            }),
            item => {
                if !open.is_empty() {
                    bounds::painted(&mut extent, item, at)?;
                    let started = elements.len();
                    extend(&mut elements, &open, started, &extent);
                }
            }
        }
    }
    let elements = elements
        .into_iter()
        .map(|element| {
            let label = &names[element.name];
            let (min, max, flags) = if is_empty(&element.extent) {
                (TypstPoint::default(), TypstPoint::default(), 0)
            } else {
                (
                    point(element.extent.min),
                    point(element.extent.max),
                    TYPST_LABEL_EXTENT,
                )
            };
            TypstLabeledElement {
                label: TypstStr::view(label),
                position: point(element.position),
                min,
                max,
                flags,
            }
        })
        .collect();
    Some(Labels {
        elements,
        _names: names,
    })
}

/// Adds a nonempty extent to the open elements that started before `started`.
fn extend(elements: &mut [Element], open: &[(Location, usize)], started: usize, extent: &Rect) {
    if is_empty(extent) {
        return;
    }
    for &(_, index) in open {
        if index < started {
            let element = &mut elements[index].extent;
            element.min = element.min.min(extent.min);
            element.max = element.max.max(extent.max);
        }
    }
}

fn empty() -> Rect {
    Rect::new(Point::splat(Abs::inf()), Point::splat(-Abs::inf()))
}

fn is_empty(rect: &Rect) -> bool {
    rect.min.x > rect.max.x
}

fn finite(point: Point) -> Option<Point> {
    (point.x.is_finite() && point.y.is_finite()).then_some(point)
}

fn point(point: Point) -> TypstPoint {
    TypstPoint {
        x: point.x.to_pt(),
        y: point.y.to_pt(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::Context;

    fn layout(source: &str, syntax: u32) -> crate::layout::Layout {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        let options = TypstLayoutOptions {
            syntax,
            ..Default::default()
        };
        context.layout(source, "labels.typ", &options, 0).unwrap().0
    }

    fn name(element: &TypstLabeledElement) -> &str {
        let bytes = unsafe { std::slice::from_raw_parts(element.label.data, element.label.len) };
        std::str::from_utf8(bytes).unwrap()
    }

    fn find<'a>(elements: &'a [TypstLabeledElement], label: &str) -> &'a TypstLabeledElement {
        let mut matches = elements.iter().filter(|element| name(element) == label);
        let element = matches.next().unwrap();
        assert!(matches.next().is_none());
        element
    }

    fn within(inner: &TypstLabeledElement, outer: [TypstPoint; 2]) -> bool {
        inner.min.x >= outer[0].x - 1e-9
            && inner.min.y >= outer[0].y - 1e-9
            && inner.max.x <= outer[1].x + 1e-9
            && inner.max.y <= outer[1].y + 1e-9
    }

    #[test]
    fn inline_elements_report_their_box_and_typst_position() {
        let layout = layout("Hi #box[$a$] <a> and *bold* <b> end", TYPST_SYNTAX_MARKUP);
        let elements = layout.labels().unwrap();
        assert_eq!(elements.len(), 2);
        assert_eq!(name(&elements[0]), "a");
        assert_eq!(name(&elements[1]), "b");
        let baseline = layout.metrics().baseline_pt;
        let a = find(elements, "a");
        let b = find(elements, "b");
        for element in [a, b] {
            assert_eq!(element.flags, TYPST_LABEL_EXTENT);
            assert!(element.min.x < element.max.x && element.min.y < element.max.y);
            assert!(within(element, layout.bounds().unwrap()));
            // Inline elements start on the line's baseline.
            assert!((element.position.y - baseline).abs() < 1e-9);
        }
        // The box's own frame starts where the box does and reaches the
        // baseline; the glyph's ink may overshoot it slightly.
        assert!((a.position.x - a.min.x).abs() < 1e-9 && a.min.y.abs() < 1e-9);
        assert!(a.max.y >= baseline - 1e-9 && a.max.y < baseline + 1.0);
        assert!(a.max.x < b.min.x);
    }

    #[test]
    fn math_cells_keep_their_labels_and_unlabeled_elements_are_skipped() {
        let layout = layout(
            "mat(#[#box[$a$] <tl>], b; c, #[#box[$d^2$] <br>])",
            TYPST_SYNTAX_MATH,
        );
        let elements = layout.labels().unwrap();
        // The equation and the boxes are tagged; only the boxes are labeled.
        assert_eq!(elements.len(), 2);
        let top = find(elements, "tl");
        let bottom = find(elements, "br");
        assert!(top.max.x < bottom.min.x);
        // Cells start on their row's baseline.
        assert!(top.position.y < bottom.position.y);
        assert!(top.min.y < bottom.min.y && top.max.y < bottom.max.y);
        assert!(within(top, layout.bounds().unwrap()));
        assert!(within(bottom, layout.bounds().unwrap()));
    }

    #[test]
    fn nested_and_transformed_elements_cover_their_contents() {
        let nested = layout("#box[outer #box[inner] <i>] <o>", TYPST_SYNTAX_MARKUP);
        let elements = nested.labels().unwrap();
        let outer = find(elements, "o");
        let inner = find(elements, "i");
        assert!(within(inner, [outer.min, outer.max]));
        assert!(inner.min.x > outer.min.x);

        let plain = layout("#box[X] <r>", TYPST_SYNTAX_MARKUP);
        let rotated = layout("#rotate(30deg)[#box[X] <r>]", TYPST_SYNTAX_MARKUP);
        let upright = find(plain.labels().unwrap(), "r");
        let turned = find(rotated.labels().unwrap(), "r");
        let size = |element: &TypstLabeledElement| {
            (element.max.x - element.min.x, element.max.y - element.min.y)
        };
        // The rotated box's axis-aligned extent is wider and taller.
        assert!(size(turned).0 > size(upright).0 && size(turned).1 > size(upright).1);
    }

    #[test]
    fn repeated_labels_and_elements_without_content_are_reported_as_they_are() {
        let labeled = layout(
            "#box[A] <same> #box[B] <same> #metadata(1) <data> Café #box[Ω] <名前>",
            TYPST_SYNTAX_MARKUP,
        );
        let elements = labeled.labels().unwrap();
        let names: Vec<_> = elements.iter().map(name).collect();
        assert_eq!(names, ["same", "same", "data", "名前"]);
        // The first and last boxes start and end the paragraph, whose frame
        // lies between their tags only in part.
        assert!(elements[0].max.x < elements[1].min.x);
        assert!(elements[3].min.x > elements[1].max.x);
        assert!(elements[0].position.x == 0.0 && elements[0].position.y == 0.0);
        assert_eq!(elements[2].flags, 0);
        assert_eq!(elements[3].flags, TYPST_LABEL_EXTENT);
        // Repeated requests borrow the same records.
        assert_eq!(labeled.labels().unwrap().as_ptr(), elements.as_ptr());
        let plain = layout("Plain text", TYPST_SYNTAX_MARKUP);
        assert!(plain.labels().unwrap().is_empty());
    }
}
