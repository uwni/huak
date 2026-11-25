//! Laying out requests, alone or in batches, and reading a layout's metrics, bounds and labels.
use super::request::request;
use super::*;

/// Lays out one request into an independently owned native layout.
///
/// # Safety
/// `context` must be live and `input` must point to one initialized request, with
/// readable source/setup views and an optional valid options prefix. `out` must
/// be a non-null writable handle slot. All pointers follow the module contract.
/// Release returned layout and optional diagnostic owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_context_layout(
    context: *const TypstContext,
    input: *const TypstLayoutRequest,
    out: *mut *mut TypstLayout,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let context = required(context, "context")?;
            let input = request(&context.inner, required(input, "layout request")?)?;
            let prepared = crate::layout::Prepared {
                templates: &input.templates,
                retained: &input.retained,
                shows: &input.shows,
            };
            let (layout, warnings) = context
                .inner
                .layout_with_setup(
                    input.source,
                    input.source_name,
                    &input.options(),
                    input.setup_code,
                    input.setup_source_name,
                    input.bindings,
                    prepared,
                    usize::MAX,
                )
                .map_err(|error| error.with_source(input.source_name))?;
            out.write(owned(TypstLayout { inner: layout }));
            let mut report = input.warnings;
            report.merge(warnings);
            Ok(report)
        })
    }
}

/// Processes independent requests in parallel and publishes results in input
/// order. Global success means all requests were processed; inspect each result
/// status. Every result owns its layout and diagnostics, including mixed errors.
/// A global argument error starts no work and initializes the result slots when
/// their pointer and count are valid. All input memory is borrowed for this call.
///
/// # Safety
/// `context` must be live. For nonzero `count`, `inputs` must expose that many
/// initialized requests, including their nested views/options, and `outputs`
/// must expose that many aligned writable result slots. Their storage and the
/// optional diagnostic slot must be disjoint and follow the module contract.
/// Release every populated result layout/diagnostic and the global diagnostic
/// independently, including on failure; the caller owns the output array itself.
#[no_mangle]
pub unsafe extern "C" fn typst_context_layout_many(
    context: *const TypstContext,
    inputs: *const TypstLayoutRequest,
    count: usize,
    outputs: *mut TypstLayoutResult,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            check_values(outputs.cast_const(), count, "layout results")?;
            for index in 0..count {
                outputs.add(index).write(TypstLayoutResult::default());
            }
            let context = required(context, "context")?;
            let requests = values(inputs, count, "layout requests")?
                .iter()
                .map(|value| request(&context.inner, value))
                .collect::<Vec<_>>();
            let outcomes = requests
                .into_par_iter()
                .enumerate()
                .map(|(index, input)| {
                    catch_unwind(AssertUnwindSafe(|| {
                        let input = input?;
                        let prepared = crate::layout::Prepared {
                            templates: &input.templates,
                            retained: &input.retained,
                            shows: &input.shows,
                        };
                        let (layout, warnings) = context
                            .inner
                            .layout_with_setup(
                                input.source,
                                input.source_name,
                                &input.options(),
                                input.setup_code,
                                input.setup_source_name,
                                input.bindings,
                                prepared,
                                index,
                            )
                            .map_err(|error| error.with_source(input.source_name))?;
                        let mut report = input.warnings;
                        report.merge(warnings);
                        Ok((layout, report))
                    }))
                    .unwrap_or_else(|payload| Err(panic_error(payload)))
                })
                .collect::<Vec<_>>();
            for (index, result) in outcomes.into_iter().enumerate() {
                let result = match result {
                    Ok((layout, report)) => TypstLayoutResult {
                        status: TYPST_OK,
                        reserved: 0,
                        layout: owned(TypstLayout { inner: layout }),
                        diagnostics: if report.entries.is_empty() {
                            ptr::null_mut()
                        } else {
                            owned(TypstDiagnostics {
                                inner: report.with_request(index),
                            })
                        },
                    },
                    Err(error) => TypstLayoutResult {
                        status: error.status,
                        reserved: 0,
                        layout: ptr::null_mut(),
                        diagnostics: owned(TypstDiagnostics {
                            inner: error.report.with_request(index),
                        }),
                    },
                };
                outputs.add(index).write(result);
            }
            Ok(Report::default())
        })
    }
}

/// Reads the dimensions and baseline of a layout.
///
/// # Safety
/// `layout` must be a live layout from this library and `out` must point to one
/// aligned writable `TypstMetrics`, disjoint from the borrowed layout.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_metrics(
    layout: *const TypstLayout,
    out: *mut TypstMetrics,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "metrics output")?;
            out.write(TypstMetrics::default());
            let layout = required(layout, "layout")?;
            out.write(layout.inner.metrics());
            Ok(Report::default())
        })
    }
}

/// Reads conservative bounds in frame-local, y-down points, including logical
/// dimensions and painted overflow. Clips may make the visible extent smaller.
/// Native text, strokes and images remain native; no outline extraction occurs.
/// Available since ABI 1.1.
///
/// # Safety
/// `layout` must be live. `out` must hold two aligned writable `TypstPoint`s,
/// disjoint from the layout, receiving the minimum and maximum respectively.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_bounds(
    layout: *const TypstLayout,
    out: *mut TypstPoint,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "bounds output")?;
            out.write(TypstPoint::default());
            out.add(1).write(TypstPoint::default());
            let bounds = required(layout, "layout")?.inner.bounds()?;
            ptr::copy_nonoverlapping(bounds.as_ptr(), out, bounds.len());
            Ok(Report::default())
        })
    }
}

/// Borrows every labeled element of a layout, read from the start and end tags
/// Typst places around content that carries a label. Elements appear in
/// document order, a label as often as it occurs. Records are made on the
/// first call and live as long as the layout. Available since ABI 1.6.
///
/// # Safety
/// `layout` must be live. `out` must point to aligned writable storage for one
/// `TypstLabelView`, disjoint from the layout. Keep a layout reference alive
/// for every access to the returned view; do not mutate or free it.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_labels(
    layout: *const TypstLayout,
    out: *mut TypstLabelView,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "labels output")?;
            out.write(TypstLabelView::default());
            let elements = required(layout, "layout")?.inner.labels()?;
            out.write(TypstLabelView {
                elements: elements.as_ptr(),
                element_count: elements.len(),
            });
            Ok(Report::default())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::{context::*, export::*, lifetime::*};

    #[test]
    fn layouts_and_diagnostics_outlive_borrowed_request_text() {
        unsafe {
            let mut context = ptr::null_mut();
            assert_eq!(
                typst_context_create(ptr::null(), &mut context, ptr::null_mut()),
                TYPST_OK
            );
            let results = {
                let sources = [String::from("#title"), String::from("#missing_name")];
                let names = [String::from("good.typ"), String::from("bad.typ")];
                let setup = String::from("let title = [Retained Ω]");
                let setup_name = String::from("shared-setup.typ");
                let options = TypstLayoutOptions {
                    setup_code: TypstStr::view(&setup),
                    setup_source_name: TypstStr::view(&setup_name),
                    ..Default::default()
                };
                let inputs = std::array::from_fn::<_, 2, _>(|index| TypstLayoutRequest {
                    source: TypstStr::view(&sources[index]),
                    source_name: TypstStr::view(&names[index]),
                    options: &options,
                });
                let mut results = [TypstLayoutResult::default(); 2];
                assert_eq!(
                    typst_context_layout_many(
                        context,
                        inputs.as_ptr(),
                        inputs.len(),
                        results.as_mut_ptr(),
                        ptr::null_mut(),
                    ),
                    TYPST_OK
                );
                results
            };
            typst_context_release(context);

            assert_eq!(results[0].status, TYPST_OK);
            assert_eq!(results[1].status, TYPST_COMPILE_FAILED);
            let mut metrics = TypstMetrics::default();
            assert_eq!(
                typst_layout_metrics(results[0].layout, &mut metrics),
                TYPST_OK
            );
            assert!(metrics.width_pt > 0.0);
            let mut svg = ptr::null_mut();
            assert_eq!(
                typst_layout_export_svg(results[0].layout, &mut svg, ptr::null_mut()),
                TYPST_OK
            );
            assert!((*svg).inner.starts_with(b"<svg"));
            assert!((*results[1].diagnostics)
                .inner
                .entries
                .iter()
                .any(|entry| entry.source_name == "/bad.typ"
                    && entry.message.contains("missing_name")
                    && entry.request_index == 1));
            typst_buffer_release(svg);
            for result in results {
                typst_layout_release(result.layout);
                typst_diagnostics_release(result.diagnostics);
            }
        }
    }
}
