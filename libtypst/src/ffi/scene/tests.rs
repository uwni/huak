use super::*;
use crate::ffi::{export::*, lifetime::*};

#[test]
fn native_scene_owns_path_clip_and_dash_inputs_after_create_returns() {
    unsafe {
        let (scene, before) = {
            let mut segments = vec![
                TypstPathSegment {
                    kind: TYPST_SEGMENT_MOVE,
                    p1: TypstPoint { x: 2.0, y: 3.0 },
                    ..Default::default()
                },
                TypstPathSegment {
                    kind: TYPST_SEGMENT_CUBIC,
                    p1: TypstPoint { x: 8.0, y: 1.0 },
                    p2: TypstPoint { x: 15.0, y: 21.0 },
                    p3: TypstPoint { x: 25.0, y: 13.0 },
                    ..Default::default()
                },
            ];
            let mut clip_segments = vec![
                TypstPathSegment {
                    kind: TYPST_SEGMENT_MOVE,
                    ..Default::default()
                },
                TypstPathSegment {
                    kind: TYPST_SEGMENT_LINE,
                    p1: TypstPoint { x: 30.0, y: 0.0 },
                    ..Default::default()
                },
                TypstPathSegment {
                    kind: TYPST_SEGMENT_LINE,
                    p1: TypstPoint { x: 30.0, y: 25.0 },
                    ..Default::default()
                },
                TypstPathSegment {
                    kind: TYPST_SEGMENT_CLOSE,
                    ..Default::default()
                },
            ];
            let mut dashes = vec![3.0, 1.0];
            let path = TypstPath {
                segments: segments.as_ptr(),
                segment_count: segments.len(),
            };
            let clip = TypstPath {
                segments: clip_segments.as_ptr(),
                segment_count: clip_segments.len(),
            };
            let style = TypstStyle {
                flags: TYPST_STYLE_STROKE,
                fill_rule: TYPST_FILL_NONZERO,
                fill: TypstColor::default(),
                stroke: TypstColor {
                    r: 0.1,
                    g: 0.2,
                    b: 0.3,
                    a: 1.0,
                },
                stroke_width_pt: 2.5,
                line_cap: TYPST_CAP_ROUND,
                line_join: TYPST_JOIN_BEVEL,
                miter_limit: 7.0,
                dashes: dashes.as_ptr(),
                dash_count: dashes.len(),
                dash_phase_pt: 0.5,
            };
            let item = TypstSceneItem {
                kind: TYPST_ITEM_PATH,
                reserved: 0,
                transform: TypstTransform::default(),
                path: &path,
                style: &style,
                layout: ptr::null(),
                scene: ptr::null(),
                clip: &clip,
                options: ptr::null(),
            };
            let options = TypstSceneOptions {
                width_pt: 50.0,
                height_pt: 30.0,
                items: &item,
                item_count: 1,
                ..Default::default()
            };
            let mut scene = ptr::null_mut();
            assert_eq!(
                typst_scene_create(&options, &mut scene, ptr::null_mut()),
                TYPST_OK
            );
            let mut before = ptr::null_mut();
            assert_eq!(
                typst_scene_export_svg(scene, &mut before, ptr::null_mut()),
                TYPST_OK
            );

            segments.fill(TypstPathSegment::default());
            clip_segments.fill(TypstPathSegment::default());
            dashes.fill(f64::NAN);
            // All caller-owned arrays and input records drop at this boundary.
            (scene, before)
        };
        let mut after = ptr::null_mut();
        assert_eq!(
            typst_scene_export_svg(scene, &mut after, ptr::null_mut()),
            TYPST_OK
        );
        assert_eq!((*before).inner, (*after).inner);
        assert!((*after).inner.starts_with(b"<svg"));
        for expected in [b"stroke-dasharray".as_slice(), b"clip-path".as_slice()] {
            assert!((*after)
                .inner
                .windows(expected.len())
                .any(|part| part == expected));
        }
        let mut pdf = ptr::null_mut();
        assert_eq!(
            typst_scene_export_pdf(scene, ptr::null(), &mut pdf, ptr::null_mut()),
            TYPST_OK
        );
        assert!((*pdf).inner.starts_with(b"%PDF-"));
        typst_buffer_release(before);
        typst_buffer_release(after);
        typst_buffer_release(pdf);
        typst_scene_release(scene);
    }
}

#[test]
fn gradient_stops_follow_their_offsets() {
    let segments = [
        TypstPathSegment {
            kind: TYPST_SEGMENT_MOVE,
            ..Default::default()
        },
        TypstPathSegment {
            kind: TYPST_SEGMENT_LINE,
            p1: TypstPoint { x: 40.0, y: 0.0 },
            ..Default::default()
        },
        TypstPathSegment {
            kind: TYPST_SEGMENT_LINE,
            p1: TypstPoint { x: 40.0, y: 10.0 },
            ..Default::default()
        },
        TypstPathSegment {
            kind: TYPST_SEGMENT_CLOSE,
            ..Default::default()
        },
    ];
    let path = TypstPath {
        segments: segments.as_ptr(),
        segment_count: segments.len(),
    };
    let style = TypstStyle {
        flags: TYPST_STYLE_FILL,
        fill_rule: TYPST_FILL_NONZERO,
        fill: TypstColor {
            r: 1.0,
            g: 0.0,
            b: 0.0,
            a: 1.0,
        },
        stroke: TypstColor::default(),
        stroke_width_pt: 0.0,
        line_cap: TYPST_CAP_BUTT,
        line_join: TYPST_JOIN_MITER,
        miter_limit: 4.0,
        dashes: ptr::null(),
        dash_count: 0,
        dash_phase_pt: 0.0,
    };
    let colors = [
        TypstColor {
            r: 1.0,
            g: 0.0,
            b: 0.0,
            a: 1.0,
        },
        TypstColor {
            r: 0.0,
            g: 1.0,
            b: 0.0,
            a: 1.0,
        },
        TypstColor {
            r: 0.0,
            g: 0.0,
            b: 1.0,
            a: 1.0,
        },
    ];
    let render = |flags: u32, offsets: &[f64]| unsafe {
        let gradient = TypstGradient {
            kind: TYPST_GRADIENT_LINEAR,
            flags,
            start: TypstPoint { x: 0.0, y: 5.0 },
            end: TypstPoint { x: 40.0, y: 5.0 },
            colors: colors.as_ptr(),
            count: colors.len(),
            offsets: offsets.as_ptr(),
        };
        let paints = TypstSceneItemOptions {
            fill_gradient: &gradient,
            ..Default::default()
        };
        let item = TypstSceneItem {
            kind: TYPST_ITEM_PATH,
            reserved: 0,
            transform: TypstTransform {
                xx: 1.0,
                yy: 1.0,
                ..Default::default()
            },
            path: &path,
            style: &style,
            layout: ptr::null(),
            scene: ptr::null(),
            clip: ptr::null(),
            options: &paints,
        };
        let options = TypstSceneOptions {
            width_pt: 40.0,
            height_pt: 10.0,
            items: &item,
            item_count: 1,
            ..Default::default()
        };
        let mut scene = ptr::null_mut();
        let mut diagnostics = ptr::null_mut();
        let status = typst_scene_create(&options, &mut scene, &mut diagnostics);
        typst_diagnostics_release(diagnostics);
        if status != TYPST_OK {
            return Err(status);
        }
        let mut svg = ptr::null_mut();
        assert_eq!(
            typst_scene_export_svg(scene, &mut svg, ptr::null_mut()),
            TYPST_OK
        );
        let text = String::from_utf8((*svg).inner.to_vec()).unwrap();
        typst_buffer_release(svg);
        typst_scene_release(scene);
        Ok(text)
    };

    let placed = render(TYPST_GRADIENT_STOP_OFFSETS, &[0.0, 0.25, 1.0]).unwrap();
    assert!(placed.contains(r#"offset="25%""#), "{placed}");
    let spaced = render(0, &[f64::NAN; 3]).unwrap();
    assert!(spaced.contains(r#"offset="50%""#), "{spaced}");
    for invalid in [
        [0.1, 0.5, 1.0],
        [0.0, 0.5, 0.9],
        [0.0, 0.6, 0.4],
        [0.0, f64::NAN, 1.0],
    ] {
        assert_eq!(
            render(TYPST_GRADIENT_STOP_OFFSETS, &invalid),
            Err(TYPST_INVALID_ARGUMENT)
        );
    }
    assert_eq!(render(2, &[0.0, 0.5, 1.0]), Err(TYPST_UNSUPPORTED));
}

#[test]
fn pixel_scene_owns_data_exports_svg_and_pdf_and_validates_inputs() {
    unsafe {
        let (scene, before_svg) = {
            let mut rgb = vec![255u8, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0];
            let mut scene = ptr::null_mut();
            assert_eq!(
                typst_scene_from_pixels(
                    TypstBytes {
                        data: rgb.as_ptr(),
                        len: rgb.len(),
                    },
                    2,
                    2,
                    TYPST_PIXEL_RGB8,
                    40.0,
                    20.0,
                    &mut scene,
                    ptr::null_mut(),
                ),
                TYPST_OK
            );
            let mut before = ptr::null_mut();
            assert_eq!(
                typst_scene_export_svg(scene, &mut before, ptr::null_mut()),
                TYPST_OK
            );
            rgb.fill(0);
            (scene, before)
        };
        let mut metrics = TypstMetrics::default();
        assert_eq!(typst_scene_metrics(scene, &mut metrics), TYPST_OK);
        assert_eq!(metrics.width_pt, 40.0);
        assert_eq!(metrics.height_pt, 20.0);

        let mut after_svg = ptr::null_mut();
        assert_eq!(
            typst_scene_export_svg(scene, &mut after_svg, ptr::null_mut()),
            TYPST_OK
        );
        assert_eq!((*before_svg).inner, (*after_svg).inner);
        let svg_text = String::from_utf8((*after_svg).inner.to_vec()).unwrap();
        assert!(svg_text.contains("<image"), "{svg_text}");
        assert!(svg_text.contains("data:image/png;base64,"), "{svg_text}");
        assert!(svg_text.contains(r#"preserveAspectRatio="none""#), "{svg_text}");

        let mut pdf = ptr::null_mut();
        assert_eq!(
            typst_scene_export_pdf(scene, ptr::null(), &mut pdf, ptr::null_mut()),
            TYPST_OK
        );
        assert!((*pdf).inner.starts_with(b"%PDF-"));

        typst_buffer_release(before_svg);
        typst_buffer_release(after_svg);
        typst_buffer_release(pdf);
        typst_scene_release(scene);

        // RGBA8 round-trip
        let rgba = [10u8, 20, 30, 128, 40, 50, 60, 255];
        let mut rgba_scene = ptr::null_mut();
        assert_eq!(
            typst_scene_from_pixels(
                TypstBytes {
                    data: rgba.as_ptr(),
                    len: rgba.len(),
                },
                2,
                1,
                TYPST_PIXEL_RGBA8,
                12.0,
                6.0,
                &mut rgba_scene,
                ptr::null_mut(),
            ),
            TYPST_OK
        );
        let mut rgba_svg = ptr::null_mut();
        assert_eq!(
            typst_scene_export_svg(rgba_scene, &mut rgba_svg, ptr::null_mut()),
            TYPST_OK
        );
        let rgba_text = String::from_utf8((*rgba_svg).inner.to_vec()).unwrap();
        assert!(rgba_text.contains("data:image/png;base64,"), "{rgba_text}");
        typst_buffer_release(rgba_svg);
        typst_scene_release(rgba_scene);

        // Invalid arguments & unsupported encoding
        let mut invalid = ptr::null_mut();
        assert_eq!(
            typst_scene_from_pixels(
                TypstBytes {
                    data: rgba.as_ptr(),
                    len: 0,
                },
                0,
                1,
                TYPST_PIXEL_RGB8,
                10.0,
                10.0,
                &mut invalid,
                ptr::null_mut(),
            ),
            TYPST_INVALID_ARGUMENT
        );
        assert!(invalid.is_null());
        assert_eq!(
            typst_scene_from_pixels(
                TypstBytes {
                    data: rgba.as_ptr(),
                    len: 5,
                },
                2,
                1,
                TYPST_PIXEL_RGB8,
                10.0,
                10.0,
                &mut invalid,
                ptr::null_mut(),
            ),
            TYPST_INVALID_ARGUMENT
        );
        assert_eq!(
            typst_scene_from_pixels(
                TypstBytes {
                    data: rgba.as_ptr(),
                    len: 6,
                },
                2,
                1,
                TYPST_PIXEL_RGB8,
                f64::NAN,
                10.0,
                &mut invalid,
                ptr::null_mut(),
            ),
            TYPST_INVALID_ARGUMENT
        );
        assert_eq!(
            typst_scene_from_pixels(
                TypstBytes {
                    data: rgba.as_ptr(),
                    len: 6,
                },
                2,
                1,
                99,
                10.0,
                10.0,
                &mut invalid,
                ptr::null_mut(),
            ),
            TYPST_UNSUPPORTED
        );
        assert_eq!(
            typst_scene_from_pixels(
                TypstBytes {
                    data: rgba.as_ptr(),
                    len: 4,
                },
                u32::MAX,
                u32::MAX,
                TYPST_PIXEL_RGBA8,
                10.0,
                10.0,
                &mut invalid,
                ptr::null_mut(),
            ),
            TYPST_OUT_OF_RANGE
        );
    }
}
