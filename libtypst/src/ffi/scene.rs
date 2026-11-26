//! Scenes: importing PDF pages, creating scenes from paths, layouts and nested scenes, and their metrics.
use super::*;

/// A gradient record and, when flagged, its stop positions.
struct GradientRecord<'a> {
    record: TypstGradient,
    offsets: Option<&'a [f64]>,
}

/// Records written before ABI 1.10 end before `offsets`. Fields are read
/// through the pointer, without a reference to the whole record, and
/// `offsets` only when the flag says it is present.
unsafe fn gradient_record<'a>(view: *const TypstGradient) -> Result<GradientRecord<'a>, Error> {
    check_ptr(view, "gradient")?;
    let flags = unsafe { ptr::addr_of!((*view).flags).read() };
    if flags & !TYPST_GRADIENT_STOP_OFFSETS != 0 {
        return Err(Error::unsupported("unknown gradient flags"));
    }
    let mut record = unsafe {
        TypstGradient {
            kind: ptr::addr_of!((*view).kind).read(),
            flags,
            start: ptr::addr_of!((*view).start).read(),
            end: ptr::addr_of!((*view).end).read(),
            colors: ptr::addr_of!((*view).colors).read(),
            count: ptr::addr_of!((*view).count).read(),
            offsets: ptr::null(),
        }
    };
    let offsets = if flags & TYPST_GRADIENT_STOP_OFFSETS != 0 {
        record.offsets = unsafe { ptr::addr_of!((*view).offsets).read() };
        Some(unsafe { values(record.offsets, record.count, "gradient offsets")? })
    } else {
        None
    };
    Ok(GradientRecord { record, offsets })
}

unsafe fn path<'a>(value: *const TypstPath) -> Result<&'a [TypstPathSegment], Error> {
    let value = unsafe { required(value, "path")? };
    unsafe { values(value.segments, value.segment_count, "path segments") }
}

unsafe fn style<'a>(value: *const TypstStyle) -> Result<PathStyle<'a>, Error> {
    let value = unsafe { required(value, "path style")? };
    if value.flags & !(TYPST_STYLE_FILL | TYPST_STYLE_STROKE) != 0 {
        return Err(Error::unsupported("unknown path style flags"));
    }
    let stroke = if value.flags & TYPST_STYLE_STROKE != 0 {
        Some(StrokeStyle {
            color: value.stroke,
            width_pt: value.stroke_width_pt,
            line_cap: value.line_cap,
            line_join: value.line_join,
            miter_limit: value.miter_limit,
            dashes: unsafe { values(value.dashes, value.dash_count, "stroke dashes")? },
            dash_phase_pt: value.dash_phase_pt,
        })
    } else {
        None
    };
    Ok(PathStyle {
        fill: (value.flags & TYPST_STYLE_FILL != 0).then_some(value.fill),
        fill_rule: value.fill_rule,
        fill_gradient: None,
        stroke_gradient: None,
        stroke,
    })
}

/// Imports a zero-based PDF page into a reusable native scene, at its natural
/// page dimensions in points. Copies the input bytes; the scene can outlive them.
/// The context only supplies the environment for Typst's decoder: the result
/// does not depend on its fonts, files or inputs, so any live context will do.
/// PDF output uses Typst's native PDF embedding, including its format restrictions.
///
/// # Safety
/// `context` is borrowed for this call. `data` follows the module pointer contract. `out` must be a writable scene
/// slot; `diagnostics` is optional. Release the scene and diagnostics separately.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_from_pdf(
    context: *const TypstContext,
    data: TypstBytes,
    page: usize,
    out: *mut *mut TypstScene,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let (inner, report) = crate::scene::Scene::from_pdf(
                &required(context, "context")?.inner,
                values(data.data, data.len, "PDF data")?,
                page,
            )?;
            out.write(owned(TypstScene { inner }));
            Ok(report)
        })
    }
}

/// Copies native scene commands and retains referenced layouts/nested scenes.
///
/// # Safety
/// A non-null `config`, its declared prefix, items, paths, styles, dash arrays,
/// clips and option views must follow the module pointer contract. Referenced
/// layout/scene handles must be live and originate from this library. `out` must
/// be a non-null writable scene slot; `diagnostics` is optional. Release both
/// returned owners separately; the scene may outlive its input handles/views.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_create(
    config: *const TypstSceneOptions,
    out: *mut *mut TypstScene,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let config: TypstSceneOptions = options(config)?;
            if config.flags != 0 {
                return Err(Error::unsupported("unknown scene flags"));
            }
            let commands = values(config.items, config.item_count, "scene items")?
                .iter()
                .map(|item| {
                    if item.reserved != 0 {
                        return Err(Error::invalid("scene item reserved field must be zero"));
                    }
                    let item_options: TypstSceneItemOptions = options(item.options)?;
                    if (!item_options.fill_gradient.is_null()
                        || !item_options.stroke_gradient.is_null())
                        && item.kind != TYPST_ITEM_PATH
                    {
                        return Err(Error::invalid("gradient paint requires a path"));
                    }
                    let content = match item.kind {
                        TYPST_ITEM_PATH if item.layout.is_null() && item.scene.is_null() => {
                            let mut style = style(item.style)?;
                            let gradient = |view: *const TypstGradient| {
                                if view.is_null() {
                                    return Ok(None);
                                }
                                let g = gradient_record(view)?;
                                crate::scene::gradient(
                                    &g.record,
                                    values(g.record.colors, g.record.count, "gradient colors")?,
                                    g.offsets,
                                )
                                .map(Some)
                            };
                            style.fill_gradient = gradient(item_options.fill_gradient)?;
                            style.stroke_gradient = gradient(item_options.stroke_gradient)?;
                            SceneContent::Path {
                                segments: path(item.path)?,
                                style,
                            }
                        }
                        TYPST_ITEM_LAYOUT
                            if item.path.is_null()
                                && item.scene.is_null()
                                && item.style.is_null() =>
                        {
                            SceneContent::Frame(&required(item.layout, "item layout")?.inner.frame)
                        }
                        TYPST_ITEM_SCENE
                            if item.path.is_null()
                                && item.layout.is_null()
                                && item.style.is_null() =>
                        {
                            SceneContent::Frame(&required(item.scene, "nested scene")?.inner.frame)
                        }
                        _ => {
                            return Err(Error::invalid(
                                "scene item must select one supported content kind",
                            ))
                        }
                    };
                    if item_options.flags & !TYPST_SCENE_ITEM_ISOLATE_TRANSFORM != 0 {
                        return Err(Error::unsupported("unknown scene item flags"));
                    }
                    let tag = text(item_options.tag, "scene item tag")?;
                    Ok(SceneCommand {
                        content,
                        transform: item.transform,
                        clip: if item.clip.is_null() {
                            None
                        } else {
                            Some(path(item.clip)?)
                        },
                        tag: (!tag.is_empty()).then_some(tag),
                        isolate_transform: item_options.flags & TYPST_SCENE_ITEM_ISOLATE_TRANSFORM
                            != 0,
                    })
                });
            let scene = crate::scene::Scene::new(config.width_pt, config.height_pt, commands)?;
            out.write(owned(TypstScene { inner: scene }));
            Ok(Report::default())
        })
    }
}

/// Reads scene dimensions and baseline.
///
/// # Safety
/// `scene` must be live and `out` must point to one aligned writable
/// `TypstMetrics`, disjoint from the scene, for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_metrics(
    scene: *const TypstScene,
    out: *mut TypstMetrics,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "metrics output")?;
            out.write(TypstMetrics::default());
            let scene = required(scene, "scene")?;
            out.write(metrics(&scene.inner.frame));
            Ok(Report::default())
        })
    }
}

#[cfg(test)]
mod tests;
