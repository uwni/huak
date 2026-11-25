use super::*;
use typst_core::foundations::{Binding, Dict, Value};
use typst_core::layout::FrameItem;

mod bindings;
mod frames;
mod templates;

fn glyph_count(frame: &Frame) -> usize {
    frame
        .items()
        .map(|(_, item)| match item {
            FrameItem::Text(text) => text.glyphs.len(),
            FrameItem::Group(group) => glyph_count(&group.frame),
            _ => 0,
        })
        .sum()
}

fn data(entries: &[(&str, Value)]) -> Scope {
    let mut payload = Dict::new();
    for (name, value) in entries {
        payload.insert((*name).into(), value.clone());
    }
    let mut scope = Scope::new();
    scope.bind("payload".into(), Binding::detached(payload));
    scope
}
