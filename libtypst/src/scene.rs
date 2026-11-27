//! Immutable native scenes. Typst owns drawing, clipping, and frame semantics.
use crate::{abi::*, error::Error};
use comemo::Track;
use std::sync::Arc;
use typst_core::{
    engine::{Engine, Route, Sink, Traced},
    foundations::{Bytes, Derived, Label, Packed, Smart, StyleChain},
    introspection::EmptyIntrospector,
    layout::{
        Abs, Angle, Axes, Frame, FrameItem, FrameKind, GroupItem, Point, Ratio, Size, Transform,
    },
    loading::{DataSource, LoadSource, Loaded},
    syntax::{Span, Spanned},
    utils::{PicoStr, Protected},
    visualize::{
        Color, Curve, CurveItem, DashPattern, FillRule, FixedStroke, Geometry, Gradient, Image,
        ImageElem, ImageFormat, ImageKind, LineCap, LineJoin, LinearGradient, Paint, PixelEncoding,
        PixelFormat, ProcessColorSpace, RadialGradient, RasterFormat, RasterImage, RelativeTo, Rgb,
        Shape, VectorFormat,
    },
    World,
};

pub struct Scene {
    pub(crate) frame: Frame,
}

pub enum SceneContent<'a> {
    Path {
        segments: &'a [TypstPathSegment],
        style: PathStyle<'a>,
    },
    Frame(&'a Frame),
}

pub struct SceneCommand<'a> {
    pub content: SceneContent<'a>,
    pub transform: TypstTransform,
    pub clip: Option<&'a [TypstPathSegment]>,
    pub tag: Option<&'a str>,
    pub isolate_transform: bool,
}

#[derive(Default)]
pub struct PathStyle<'a> {
    pub fill: Option<TypstColor>,
    pub fill_gradient: Option<(Paint, GradientFrame)>,
    pub stroke_gradient: Option<(Paint, GradientFrame)>,
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
    /// Import one native PDF page. Typst owns parsing and final PDF embedding.
    pub(crate) fn from_pdf(
        context: &crate::context::Context,
        data: &[u8],
        page: usize,
    ) -> Result<(Self, crate::diagnostics::Report), Error> {
        let page = page
            .checked_add(1)
            .and_then(std::num::NonZeroUsize::new)
            .ok_or_else(|| Error::range("PDF page index is out of range"))?;
        let data = Bytes::new(data.to_vec());
        let element = Packed::new(
            ImageElem::new(Derived::new(
                DataSource::Bytes(data.clone()),
                Loaded::new(Spanned::new(LoadSource::Bytes, Span::detached()), data),
            ))
            .with_page(page)
            .with_format(Smart::Custom(ImageFormat::Vector(VectorFormat::Pdf))),
        );
        let world = context.world("", "image.pdf")?;
        let library = world.library();
        let traced = Traced::default();
        let introspector = EmptyIntrospector;
        let mut sink = Sink::new();
        let image = element
            .decode(
                &mut Engine {
                    world: (&world as &dyn World).track(),
                    library,
                    introspector: Protected::new(introspector.track()),
                    traced: traced.track(),
                    sink: sink.track_mut(),
                    route: Route::default(),
                },
                StyleChain::new(&library.styles),
            )
            .map_err(|errors| {
                Error::compile(crate::diagnostics::Report::from_native(&world, &errors, 0))
            })?;
        let ImageKind::Pdf(pdf) = image.kind() else {
            unreachable!()
        };
        let size = Size::new(Abs::pt(pdf.width().into()), Abs::pt(pdf.height().into()));
        let mut frame = Frame::soft(size);
        frame.push(
            Point::zero(),
            FrameItem::Image(image, size, Span::detached()),
        );
        Ok((
            Self { frame },
            crate::diagnostics::Report::from_native(&world, &sink.warnings(), 0),
        ))
    }

    /// Create a reusable native scene containing one raster image from raw
    /// row-major pixel data, sized to `width_pt` by `height_pt` in points.
    pub(crate) fn from_pixels(
        pixels: &[u8],
        width_px: u32,
        height_px: u32,
        encoding: u32,
        width_pt: f64,
        height_pt: f64,
    ) -> Result<Self, Error> {
        if !width_pt.is_finite() || !height_pt.is_finite() || width_pt <= 0.0 || height_pt <= 0.0 {
            return Err(Error::invalid(
                "image dimensions must be finite positive point values",
            ));
        }
        if width_px == 0 || height_px == 0 {
            return Err(Error::invalid("pixel dimensions must be positive"));
        }
        let (pixel_encoding, channels): (PixelEncoding, u32) = match encoding {
            TYPST_PIXEL_RGB8 => (PixelEncoding::Rgb8, 3),
            TYPST_PIXEL_RGBA8 => (PixelEncoding::Rgba8, 4),
            _ => return Err(Error::unsupported("unknown pixel encoding")),
        };
        let expected = width_px
            .checked_mul(height_px)
            .and_then(|count| count.checked_mul(channels))
            .ok_or_else(|| Error::range("pixel dimensions overflow byte length"))?;
        if pixels.len() != expected as usize {
            return Err(Error::invalid(
                "pixel byte length does not match dimensions and encoding",
            ));
        }
        let raster = RasterImage::plain(
            Bytes::new(pixels.to_vec()),
            RasterFormat::Pixel(PixelFormat {
                encoding: pixel_encoding,
                width: width_px,
                height: height_px,
            }),
        )
        .map_err(|message| Error::invalid(message.as_str()))?;
        let image = Image::plain(ImageKind::Raster(raster));
        let size = Size::new(Abs::pt(width_pt), Abs::pt(height_pt));
        let mut frame = Frame::soft(size);
        frame.push(
            Point::zero(),
            FrameItem::Image(image, size, Span::detached()),
        );
        Ok(Self { frame })
    }

    pub fn new<'a>(
        width_pt: f64,
        height_pt: f64,
        commands: impl IntoIterator<Item = Result<SceneCommand<'a>, Error>>,
    ) -> Result<Self, Error> {
        if !width_pt.is_finite() || !height_pt.is_finite() || width_pt <= 0.0 || height_pt <= 0.0 {
            return Err(Error::invalid(
                "scene dimensions must be finite positive point values",
            ));
        }
        let size = Size::new(Abs::pt(width_pt), Abs::pt(height_pt));
        let mut frame = Frame::hard(size);
        for command in commands {
            let command = command?;
            let transform = transform(command.transform)?;
            let clip = command.clip.map(curve).transpose()?;
            let plain = transform == Transform::identity()
                && clip.is_none()
                && command.tag.is_none()
                && !command.isolate_transform;
            if plain {
                if let SceneContent::Path { segments, style } = command.content {
                    style.push_into(segments, &mut frame)?;
                    continue;
                }
            }
            let mut child = match command.content {
                SceneContent::Path { segments, style } => {
                    let mut child = Frame::soft(size);
                    style.push_into(segments, &mut child)?;
                    child
                }
                // Typst frames share their immutable item storage.
                SceneContent::Frame(frame) => frame.clone(),
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
                    Label::new(PicoStr::intern(tag))
                        .ok_or_else(|| Error::invalid("scene item tag cannot be empty"))
                })
                .transpose()?;
            frame.push(Point::zero(), FrameItem::Group(group));
        }
        Ok(Self { frame })
    }
}

impl PathStyle<'_> {
    fn push_into(self, segments: &[TypstPathSegment], child: &mut Frame) -> Result<(), Error> {
        let mut shape = Shape {
            geometry: Geometry::Curve(curve(segments)?),
            fill: self.fill.map(color).transpose()?.map(Paint::Solid),
            fill_rule: fill_rule(self.fill_rule)?,
            stroke: self.stroke.map(stroke).transpose()?,
        };
        let mut placement = None;
        if let Some((paint, bounds)) = self.fill_gradient {
            if shape.fill.is_none() {
                return Err(Error::invalid("gradient fill requires a filled path"));
            }
            shape.fill = Some(paint);
            placement = Some(bounds);
        }
        if let Some((paint, bounds)) = self.stroke_gradient {
            shape
                .stroke
                .as_mut()
                .ok_or_else(|| Error::invalid("gradient stroke requires a stroked path"))?
                .paint = paint;
            // Typst uses one parent coordinate frame for both paints.
            if let Some(fill) = placement.filter(|fill| *fill != bounds) {
                let base = Shape {
                    geometry: shape.geometry.clone(),
                    fill: shape.fill.take(),
                    fill_rule: shape.fill_rule,
                    stroke: None,
                };
                fill.push(child, base);
            }
            placement = Some(bounds);
        }
        if let Some(bounds) = placement {
            bounds.push(child, shape);
        } else {
            child.push(Point::zero(), FrameItem::Shape(shape, Span::detached()));
        }
        Ok(())
    }
}

#[derive(PartialEq)]
pub struct GradientFrame {
    origin: Point,
    size: Size,
}

impl GradientFrame {
    fn push(self, child: &mut Frame, shape: Shape) {
        let mut frame = Frame::hard(self.size);
        frame.push(-self.origin, FrameItem::Shape(shape, Span::detached()));
        child.push_frame(self.origin, frame);
    }
}

/// Without `offsets` the stops are equally spaced.
pub(crate) fn gradient(
    g: &TypstGradient,
    colors: &[TypstColor],
    offsets: Option<&[f64]>,
) -> Result<(Paint, GradientFrame), Error> {
    if colors.len() < 2 {
        return Err(Error::invalid("a gradient needs at least two colors"));
    }
    if let Some(offsets) = offsets {
        if offsets.first() != Some(&0.0)
            || offsets.last() != Some(&1.0)
            || offsets.windows(2).any(|pair| !(pair[0] <= pair[1]))
        {
            return Err(Error::invalid(
                "gradient offsets must rise from 0 to 1 without decreasing",
            ));
        }
    }
    let last = (colors.len() - 1) as f64;
    let stops = colors
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let offset = offsets.map_or(i as f64 / last, |offsets| offsets[i]);
            Ok((color(*c)?, Ratio::new(offset)))
        })
        .collect::<Result<Vec<_>, Error>>()?;
    let dx = g.end.x - g.start.x;
    let dy = g.end.y - g.start.y;
    let radius = dx.hypot(dy);
    if radius <= 0.0 || !radius.is_finite() {
        return Err(Error::invalid(
            "gradient endpoints must be finite and distinct",
        ));
    }
    let space = ProcessColorSpace::Srgb.into();
    let relative = Smart::Custom(RelativeTo::Parent);
    let (paint, side, cx, cy) = match g.kind {
        TYPST_GRADIENT_LINEAR => {
            let angle = Angle::rad(dy.atan2(dx));
            let side = radius / ((dx / radius).abs() + (dy / radius).abs());
            (
                Gradient::Linear(Arc::new(LinearGradient {
                    stops,
                    angle,
                    space,
                    relative,
                    anti_alias: true,
                })),
                side,
                g.start.x + dx / 2.0,
                g.start.y + dy / 2.0,
            )
        }
        TYPST_GRADIENT_RADIAL => {
            let center = Axes::splat(Ratio::new(0.5));
            (
                Gradient::Radial(Arc::new(RadialGradient {
                    stops,
                    center,
                    radius: Ratio::new(0.5),
                    focal_center: center,
                    focal_radius: Ratio::zero(),
                    space,
                    relative,
                    anti_alias: true,
                })),
                2.0 * radius,
                g.start.x,
                g.start.y,
            )
        }
        _ => return Err(Error::unsupported("unknown gradient kind")),
    };
    if !side.is_finite() {
        return Err(Error::invalid("gradient extent exceeds coordinate range"));
    }
    Ok((
        Paint::Gradient(paint),
        GradientFrame {
            origin: point(TypstPoint {
                x: cx - side / 2.0,
                y: cy - side / 2.0,
            })?,
            size: Size::splat(Abs::pt(side)),
        },
    ))
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
mod tests;
