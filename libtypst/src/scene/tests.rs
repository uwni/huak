use super::*;

#[test]
fn pdf_import_uses_native_decoding_and_owns_its_page() {
    let context =
        crate::context::Context::new(vec![], vec![], vec![], "", TYPST_CONTEXT_NO_BUILTIN_FONTS)
            .unwrap();
    let frame = Frame::hard(Size::new(Abs::pt(50.0), Abs::pt(30.0)));
    let bytes = crate::export::pdf(&crate::export::from_frame(&frame), "", "").unwrap();
    assert!(Scene::from_pdf(&context, b"not a PDF", 0).is_err());
    assert!(Scene::from_pdf(&context, &bytes, 1).is_err());
    assert!(Scene::from_pdf(&context, &bytes, usize::MAX).is_err());
    let (scene, _) = Scene::from_pdf(&context, &bytes, 0).unwrap();
    assert_eq!(scene.frame.size(), frame.size());
    drop(bytes);
    drop(context);
    let document = crate::export::from_frame(&scene.frame);
    assert!(crate::export::pdf(&document, "", "")
        .unwrap()
        .starts_with(b"%PDF-"));
    // Upstream explicitly rejects imported PDF pages for these standards.
    assert!(crate::export::pdf(&document, "a-2b", "").is_err());
}

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
                        fill_gradient: None,
                        stroke_gradient: None,
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
            content: SceneContent::Frame(&child.frame),
            transform: TypstTransform {
                xx: 2.0,
                dy: 11.0,
                ..Default::default()
            },
            clip: Some(&line()),
            tag: Some("stable-scene-item"),
            isolate_transform: true,
        }],
    )
    .unwrap();
    drop(child);
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
    let context = crate::context::Context::new(vec![], vec![], vec![], "", 0).unwrap();
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
                content: SceneContent::Frame(&layout.frame),
                transform: TypstTransform::default(),
                clip: None,
                tag: None,
                isolate_transform: false,
            }],
        )
        .unwrap(),
    );
    drop(layout);
    assert!(weak_layout.upgrade().is_none());
    let weak_scene = Arc::downgrade(&child);
    let parent = Scene::new(
        180.0,
        80.0,
        vec![SceneCommand {
            content: SceneContent::Frame(&child.frame),
            transform: TypstTransform::default(),
            clip: None,
            tag: None,
            isolate_transform: false,
        }],
    )
    .unwrap();
    drop(child);
    assert!(weak_scene.upgrade().is_none());
    drop(context);

    let document = crate::export::from_frame(&parent.frame);
    let svg = crate::export::svg(&document, 0).unwrap();
    assert!(svg.starts_with(b"<svg"));
    assert!(svg.windows(b"<use".len()).any(|part| part == b"<use"));
    let pdf = crate::export::pdf(&document, "", "").unwrap();
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
