/* Native scenes, from a layout and from an outline. */
#include "host.h"

static TypstTransform identity(void) {
    TypstTransform value = { .xx = 1, .yy = 1 };
    return value;
}


TypstScene *create_scene(TypstLayout const *layout) {
    TypstPathSegment segments[] = {
        { .kind = TYPST_SEGMENT_MOVE, .p1 = { 5, 5 } },
        { .kind = TYPST_SEGMENT_LINE, .p1 = { 90, 5 } },
        { .kind = TYPST_SEGMENT_CUBIC, .p1 = { 110, 15 }, .p2 = { 110, 50 }, .p3 = { 90, 60 } },
        { .kind = TYPST_SEGMENT_LINE, .p1 = { 5, 60 } },
        { .kind = TYPST_SEGMENT_CLOSE }
    };
    TypstPath path = { .segments = segments, .segment_count = 5 };
    double dashes[] = { 6, 2 };
    TypstStyle style = {
        .flags = TYPST_STYLE_FILL | TYPST_STYLE_STROKE,
        .fill_rule = TYPST_FILL_EVENODD,
        .fill = { .r = 1, .g = 0.7, .b = 0.3, .a = 0.7 },
        .stroke = { .r = 0.1, .g = 0.2, .b = 0.8, .a = 1 },
        .stroke_width_pt = 3,
        .line_cap = TYPST_CAP_ROUND,
        .line_join = TYPST_JOIN_BEVEL,
        .miter_limit = 4,
        .dashes = dashes, .dash_count = 2, .dash_phase_pt = 1
    };
    TypstColor stops[] = { style.stroke, style.fill };
    TypstGradient fill = { .kind = TYPST_GRADIENT_RADIAL, .start = {40,30}, .end = {65,30}, .colors = stops, .count = 2 };
    TypstGradient stroke = { .kind = TYPST_GRADIENT_LINEAR, .start = {5,5}, .end = {90,5}, .colors = stops, .count = 2 };
    TypstSceneItemOptions paints = { .struct_size = sizeof paints, .fill_gradient = &fill, .stroke_gradient = &stroke };
    TypstSceneItem child_item = { .kind = TYPST_ITEM_PATH, .transform = {0}, .path = &path, .style = &style, .options = &paints };
    child_item.transform = identity();
    TypstSceneOptions child_options = { .struct_size = sizeof child_options, .width_pt = 120, .height_pt = 80,
                                        .items = &child_item, .item_count = 1 };
    TypstScene *child = NULL;
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.scene_create(&child_options, &child, &diagnostics));
    TypstSceneItem items[] = {
        { .kind = TYPST_ITEM_SCENE, .scene = child, .clip = &path },
        { .kind = TYPST_ITEM_LAYOUT, .layout = layout }
    };
    items[0].transform = identity();
    items[0].transform.xx = 1.3;
    items[0].transform.yy = 0.8;
    items[0].transform.xy = 0.15;
    items[0].transform.dx = 12;
    items[0].transform.dy = 10;
    items[1].transform = identity();
    items[1].transform.dx = 12;
    items[1].transform.dy = 100;
    TypstSceneOptions options = { .struct_size = sizeof options, .width_pt = 280, .height_pt = 250,
                                  .items = items, .item_count = 2 };
    TypstScene *scene = NULL;
    CHECK(api.scene_create(&options, &scene, &diagnostics));
    api.scene_release(child); /* Parent independently owns the nested frame. */
    memset(segments, 0, sizeof segments); /* Input geometry/style are only borrowed during creation. */
    memset(dashes, 0, sizeof dashes);
    memset(stops, 0, sizeof stops);
    api.scene_retain(scene);
    api.scene_release(scene);
    TypstMetrics metrics = {0};
    CHECK(api.scene_metrics(scene, &metrics));
    require(metrics.width_pt == 280 && metrics.height_pt == 250, "native scene dimensions");
    return scene;
}


TypstScene *outline_scene(TypstOutline const *outline, TypstMetrics metrics) {
    TypstOutlineView view = {0};
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.outline_view(outline, &view));
    require(view.path_count > 0 && view.segment_count > 0, "real glyph outlines returned in bulk");
    TypstPath *paths = calloc(view.path_count, sizeof *paths);
    TypstStyle *styles = calloc(view.path_count, sizeof *styles);
    TypstSceneItem *items = calloc(view.path_count, sizeof *items);
    require(paths != NULL && styles != NULL && items != NULL, "allocate caller outline scene");
    for (size_t index = 0; index < view.path_count; ++index) {
        TypstOutlinedPath const *source = &view.paths[index];
        require(source->segment_offset <= view.segment_count &&
                source->segment_count <= view.segment_count - source->segment_offset, "outline segment bounds");
        require(source->dash_offset <= view.dash_count &&
                source->dash_count <= view.dash_count - source->dash_offset, "outline dash bounds");
        paths[index].segments = view.segments + source->segment_offset;
        paths[index].segment_count = source->segment_count;
        styles[index] = (TypstStyle){
            .flags = source->flags, .fill_rule = source->fill_rule,
            .fill = source->fill, .stroke = source->stroke,
            .stroke_width_pt = source->stroke_width_pt,
            .line_cap = source->line_cap, .line_join = source->line_join,
            .miter_limit = source->miter_limit,
            .dashes = source->dash_count ? view.dashes + source->dash_offset : NULL,
            .dash_count = source->dash_count, .dash_phase_pt = source->dash_phase_pt
        };
        items[index] = (TypstSceneItem){ .kind = TYPST_ITEM_PATH, .transform = source->transform,
                                        .path = &paths[index], .style = &styles[index] };
    }
    TypstSceneOptions options = { .struct_size = sizeof options,
        .width_pt = metrics.width_pt, .height_pt = metrics.height_pt,
        .items = items, .item_count = view.path_count };
    TypstScene *scene = NULL;
    CHECK(api.scene_create(&options, &scene, &diagnostics));
    free(items);
    free(styles);
    free(paths);
    return scene;
}
