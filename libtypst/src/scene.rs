//! Immutable native scenes. Typst owns drawing, clipping, and frame semantics.
use crate::{abi::*, error::Error, layout::Layout};
use std::sync::Arc;
use typst_core::{
    foundations::Label,
    layout::{Abs, Frame, FrameItem, FrameKind, GroupItem, Point, Ratio, Size, Transform},
    syntax::Span,
    utils::PicoStr,
    visualize::{
        Color, Curve, CurveItem, DashPattern, FillRule, FixedStroke, Geometry, LineCap, LineJoin,
        Paint, Rgb, Shape,
    },
};

pub struct Scene {
    pub(crate) frame: Frame,
}

pub enum SceneContent<'a> {
    Path {
        segments: &'a [TypstPathSegment],
        style: PathStyle<'a>,
    },
    Layout(Arc<Layout>),
    Scene(Arc<Scene>),
}

pub struct SceneCommand<'a> {
    pub content: SceneContent<'a>,
    pub transform: TypstTransform,
    pub clip: Option<&'a [TypstPathSegment]>,
    pub tag: Option<String>,
    pub isolate_transform: bool,
}

#[derive(Default)]
pub struct PathStyle<'a> {
    pub fill: Option<TypstColor>,
    pub fill_rule: u32,
    pub stroke: Option<StrokeStyle<'a>>,
}

pub struct StrokeStyle<'a> {
    pub color: TypstColor,
    pub width_pt: f64,
    pub line_cap: u32,
    pub line_join: u32,
    pub miter_limit: f64,
    pub dashes: &'a [f64],
    pub dash_phase_pt: f64,
}

impl Scene {
    pub fn new(
        width_pt: f64,
        height_pt: f64,
        commands: Vec<SceneCommand<'_>>,
    ) -> Result<Self, Error> {
        if !width_pt.is_finite() || !height_pt.is_finite() || width_pt <= 0.0 || height_pt <= 0.0 {
            return Err(Error::invalid(
                "scene dimensions must be finite positive point values",
            ));
        }
        let size = Size::new(Abs::pt(width_pt), Abs::pt(height_pt));
        let mut frame = Frame::hard(size);
        let mut items = Vec::with_capacity(commands.len());
        for command in commands {
            let transform = transform(command.transform)?;
            let clip = command.clip.map(curve).transpose()?;
            let mut child = match command.content {
                SceneContent::Path { segments, style } => {
                    let shape = Shape {
                        geometry: Geometry::Curve(curve(segments)?),
                        fill: style.fill.map(color).transpose()?.map(Paint::Solid),
                        fill_rule: fill_rule(style.fill_rule)?,
                        stroke: style.stroke.map(stroke).transpose()?,
                    };
                    let mut child = Frame::soft(size);
                    child.push(Point::zero(), FrameItem::Shape(shape, Span::detached()));
                    child
                }
                // Native Frame clones already own every item and its resources.
                SceneContent::Layout(layout) => layout.frame.clone(),
                SceneContent::Scene(scene) => scene.frame.clone(),
            };
            if command.isolate_transform {
                child.set_kind(FrameKind::Hard);
            }
            let mut group = GroupItem::new(child);
            group.transform = transform;
            group.clip = clip;
            group.label = command
                .tag
                .map(|tag| {
                    Label::new(PicoStr::intern(&tag))
                        .ok_or_else(|| Error::invalid("scene item tag cannot be empty"))
                })
                .transpose()?;
            items.push((Point::zero(), FrameItem::Group(group)));
        }
        frame.push_multiple(items);
        Ok(Self { frame })
    }
}

pub(crate) fn transform(value: TypstTransform) -> Result<Transform, Error> {
    if ![value.xx, value.yx, value.xy, value.yy, value.dx, value.dy]
        .into_iter()
        .all(f64::is_finite)
    {
        return Err(Error::invalid("affine transform components must be finite"));
    }
    Ok(Transform {
        sx: Ratio::new(value.xx),
        ky: Ratio::new(value.yx),
        kx: Ratio::new(value.xy),
        sy: Ratio::new(value.yy),
        tx: Abs::pt(value.dx),
        ty: Abs::pt(value.dy),
    })
}

pub(crate) fn curve(segments: &[TypstPathSegment]) -> Result<Curve, Error> {
    let mut items = Vec::with_capacity(segments.len());
    let mut started = false;
    for segment in segments {
        if segment.reserved != 0 {
            return Err(Error::invalid("path segment reserved field must be zero"));
        }
        let item = match segment.kind {
            TYPST_SEGMENT_MOVE => {
                started = true;
                CurveItem::Move(point(segment.p1)?)
            }
            TYPST_SEGMENT_LINE if started => CurveItem::Line(point(segment.p1)?),
            TYPST_SEGMENT_CUBIC if started => {
                CurveItem::Cubic(point(segment.p1)?, point(segment.p2)?, point(segment.p3)?)
            }
            TYPST_SEGMENT_CLOSE if started => CurveItem::Close,
            TYPST_SEGMENT_LINE | TYPST_SEGMENT_CUBIC | TYPST_SEGMENT_CLOSE => {
                return Err(Error::invalid(
                    "each path subpath must start with a move segment",
                ))
            }
            _ => return Err(Error::invalid("unknown path segment kind")),
        };
        items.push(item);
    }
    Ok(Curve(items))
}

fn point(value: TypstPoint) -> Result<Point, Error> {
    if !value.x.is_finite() || !value.y.is_finite() {
        return Err(Error::invalid(
            "path coordinates must be finite point values",
        ));
    }
    Ok(Point::new(Abs::pt(value.x), Abs::pt(value.y)))
}

pub(crate) fn color(value: TypstColor) -> Result<Color, Error> {
    if ![value.r, value.g, value.b, value.a]
        .into_iter()
        .all(|channel| channel.is_finite() && (0.0..=1.0).contains(&channel))
    {
        return Err(Error::invalid(
            "RGBA channels must be finite values between zero and one",
        ));
    }
    Ok(Color::Process(
        Rgb::new(
            value.r as f32,
            value.g as f32,
            value.b as f32,
            value.a as f32,
        )
        .into(),
    ))
}

fn fill_rule(value: u32) -> Result<FillRule, Error> {
    match value {
        TYPST_FILL_NONZERO => Ok(FillRule::NonZero),
        TYPST_FILL_EVENODD => Ok(FillRule::EvenOdd),
        _ => Err(Error::invalid("unknown fill rule")),
    }
}

fn stroke(value: StrokeStyle<'_>) -> Result<FixedStroke, Error> {
    if !value.width_pt.is_finite()
        || value.width_pt < 0.0
        || !value.miter_limit.is_finite()
        || value.miter_limit < 1.0
        || !value.dash_phase_pt.is_finite()
    {
        return Err(Error::invalid(
            "stroke width, miter limit, or dash phase is invalid",
        ));
    }
    let cap = match value.line_cap {
        TYPST_CAP_BUTT => LineCap::Butt,
        TYPST_CAP_ROUND => LineCap::Round,
        TYPST_CAP_SQUARE => LineCap::Square,
        _ => return Err(Error::invalid("unknown line cap")),
    };
    let join = match value.line_join {
        TYPST_JOIN_MITER => LineJoin::Miter,
        TYPST_JOIN_ROUND => LineJoin::Round,
        TYPST_JOIN_BEVEL => LineJoin::Bevel,
        _ => return Err(Error::invalid("unknown line join")),
    };
    let dash = if value.dashes.is_empty() {
        None
    } else {
        if value
            .dashes
            .iter()
            .any(|dash| !dash.is_finite() || *dash < 0.0)
            || !value.dashes.iter().any(|dash| *dash > 0.0)
        {
            return Err(Error::invalid(
                "dash lengths must be finite and nonnegative, with at least one positive entry",
            ));
        }
        Some(DashPattern {
            array: value.dashes.iter().copied().map(Abs::pt).collect(),
            phase: Abs::pt(value.dash_phase_pt),
        })
    };
    Ok(FixedStroke {
        paint: Paint::Solid(color(value.color)?),
        thickness: Abs::pt(value.width_pt),
        cap,
        join,
        dash,
        miter_limit: Ratio::new(value.miter_limit),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line() -> Vec<TypstPathSegment> {
        vec![
            TypstPathSegment {
                kind: TYPST_SEGMENT_MOVE,
                p1: TypstPoint { x: 2.0, y: 3.0 },
                ..Default::default()
            },
            TypstPathSegment {
                kind: TYPST_SEGMENT_LINE,
                p1: TypstPoint { x: 20.0, y: 13.0 },
                ..Default::default()
            },
        ]
    }

    #[test]
    fn native_scene_preserves_nested_content_transform_clip_and_stroke() {
        let child = Arc::new(
            Scene::new(
                50.0,
                30.0,
                vec![SceneCommand {
                    content: SceneContent::Path {
                        segments: &line(),
                        style: PathStyle {
                            fill: None,
                            fill_rule: TYPST_FILL_EVENODD,
                            stroke: Some(StrokeStyle {
                                color: TypstColor {
                                    r: 0.1,
                                    g: 0.2,
                                    b: 0.3,
                                    a: 0.8,
                                },
                                width_pt: 2.5,
                                line_cap: TYPST_CAP_ROUND,
                                line_join: TYPST_JOIN_BEVEL,
                                miter_limit: 7.0,
                                dashes: &[3.0, 1.0],
                                dash_phase_pt: 0.5,
                            }),
                        },
                    },
                    transform: TypstTransform::default(),
                    clip: None,
                    tag: None,
                    isolate_transform: false,
                }],
            )
            .unwrap(),
        );
        let weak = Arc::downgrade(&child);
        let parent = Scene::new(
            80.0,
            50.0,
            vec![SceneCommand {
                content: SceneContent::Scene(child),
                transform: TypstTransform {
                    xx: 2.0,
                    dy: 11.0,
                    ..Default::default()
                },
                clip: Some(&line()),
                tag: Some("stable-scene-item".into()),
                isolate_transform: true,
            }],
        )
        .unwrap();
        assert!(weak.upgrade().is_none());
        let (_, FrameItem::Group(group)) = parent.frame.items().next().unwrap() else {
            panic!("expected native group")
        };
        assert_eq!(group.transform.sx.get(), 2.0);
        assert_eq!(group.transform.ty.to_pt(), 11.0);
        assert!(group.clip.is_some());
        assert!(group.frame.kind().is_hard());
        assert_eq!(group.label.unwrap().resolve().as_str(), "stable-scene-item");
    }

    #[test]
    fn native_frame_owns_text_after_layout_scene_and_context_owners_drop() {
        let context = crate::context::Context::new(vec![], vec![], "", 0).unwrap();
        let (layout, _) = context
            .layout(
                "Owned café $x^2$",
                "ownership.typ",
                &TypstLayoutOptions::default(),
                0,
            )
            .unwrap();
        let layout = Arc::new(layout);
        let weak_layout = Arc::downgrade(&layout);
        let child = Arc::new(
            Scene::new(
                150.0,
                60.0,
                vec![SceneCommand {
                    content: SceneContent::Layout(layout),
                    transform: TypstTransform::default(),
                    clip: None,
                    tag: None,
                    isolate_transform: false,
                }],
            )
            .unwrap(),
        );
        assert!(weak_layout.upgrade().is_none());
        let weak_scene = Arc::downgrade(&child);
        let parent = Scene::new(
            180.0,
            80.0,
            vec![SceneCommand {
                content: SceneContent::Scene(child),
                transform: TypstTransform::default(),
                clip: None,
                tag: None,
                isolate_transform: false,
            }],
        )
        .unwrap();
        assert!(weak_scene.upgrade().is_none());
        drop(context);

        let document = crate::export::from_frame(&parent.frame);
        let svg = crate::export::svg(&document, 0).unwrap();
        assert!(svg.starts_with(b"<svg"));
        assert!(svg.windows(b"<use".len()).any(|part| part == b"<use"));
        let pdf = crate::export::pdf(&document, None).unwrap();
        assert!(pdf.starts_with(b"%PDF-"));
        assert!(pdf
            .windows(b"/ToUnicode".len())
            .any(|part| part == b"/ToUnicode"));
    }

    #[test]
    fn invalid_curve_and_style_fail_before_native_rendering() {
        assert!(curve(&line()[1..]).is_err());
        let mut path = line();
        path[0].p1.x = f64::NAN;
        assert!(curve(&path).is_err());
        assert!(Scene::new(f64::INFINITY, 30.0, Vec::new()).is_err());
    }
}
