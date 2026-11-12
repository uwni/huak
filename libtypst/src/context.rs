//! Shared, immutable resources for independent Typst jobs.
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use typst_core::diag::{FileError, FileResult};
use typst_core::foundations::{Binding, Bytes, Datetime, Dict, Duration, Scope, Value};
use typst_core::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst_core::text::{Font, FontBook, FontInfo};
use typst_core::utils::LazyHash;
use typst_core::{Library, LibraryExt, World};
use typst_kit::fonts::FontStore;

use crate::abi::{
    TYPST_CONTEXT_DISABLE_PLUGINS, TYPST_CONTEXT_NO_BUILTIN_FONTS, TYPST_CONTEXT_SYSTEM_FONTS,
};
use crate::error::Error;

pub(crate) const CONTEXT_FLAGS: u32 =
    TYPST_CONTEXT_NO_BUILTIN_FONTS | TYPST_CONTEXT_DISABLE_PLUGINS | TYPST_CONTEXT_SYSTEM_FONTS;

pub(crate) struct Resources {
    pub(crate) library: LazyHash<Library>,
    /// typst-kit's font slots in priority order: supplied sources, scanned
    /// directories, system fonts, then embedded fonts. It provides the World
    /// font book and loads discovered fonts on first use.
    pub(crate) fonts: FontStore,
    files: HashMap<FileId, MemoryFile>,
}

struct MemoryFile {
    bytes: Bytes,
    source: OnceLock<FileResult<Source>>,
}

/// No mutable current document or error slot is shared between requests.
pub(crate) struct Context {
    pub(crate) resources: Arc<Resources>,
}

impl Context {
    pub(crate) fn new(
        fonts: Vec<Vec<u8>>,
        font_dirs: Vec<PathBuf>,
        files: Vec<(String, Vec<u8>)>,
        inputs_json: &str,
        flags: u32,
    ) -> Result<Self, Error> {
        if flags & !CONTEXT_FLAGS != 0 {
            return Err(Error::invalid("unknown context flags"));
        }

        let mut store = FontStore::new();
        for (source_index, data) in fonts.into_iter().enumerate() {
            let data = Bytes::new(data);
            // Font::iter silently skips invalid collection faces. A supplied
            // font source must instead validate every face before committing.
            let count = ttf_parser::fonts_in_collection(&data).unwrap_or(1);
            if count == 0 {
                return Err(Error::invalid(format!(
                    "font source {source_index} is empty"
                )));
            }
            for face in 0..count {
                let font = Font::new(data.clone(), face).ok_or_else(|| {
                    Error::invalid(format!("invalid font source {source_index}, face {face}"))
                })?;
                let info = font.info().clone();
                store.push((font, info));
            }
        }

        let inputs = if inputs_json.is_empty() {
            Dict::new()
        } else {
            match serde_json::from_str::<Value>(inputs_json)
                .map_err(|err| Error::invalid(format!("invalid inputs JSON: {err}")))?
            {
                Value::Dict(dict) => dict,
                _ => return Err(Error::invalid("inputs JSON must be an object")),
            }
        };

        let mut memory_files = HashMap::with_capacity(files.len());
        for (path, data) in files {
            if path.is_empty() {
                return Err(Error::invalid("a memory file path cannot be empty"));
            }
            let id = file_id(&path)?;
            if memory_files
                .insert(
                    id,
                    MemoryFile {
                        bytes: Bytes::new(data),
                        source: OnceLock::new(),
                    },
                )
                .is_some()
            {
                return Err(Error::invalid(format!(
                    "duplicate memory file path: {path}"
                )));
            }
        }

        // Discovery scans files, so it follows every cheaper validation.
        discover(
            &mut store,
            &font_dirs,
            flags & TYPST_CONTEXT_SYSTEM_FONTS != 0,
        )?;
        if flags & TYPST_CONTEXT_NO_BUILTIN_FONTS == 0 {
            static EMBEDDED: OnceLock<Vec<(Font, FontInfo)>> = OnceLock::new();
            store.extend(
                EMBEDDED
                    .get_or_init(|| typst_kit::fonts::embedded().collect())
                    .iter()
                    .cloned(),
            );
        }

        let mut library = Library::builder().with_inputs(inputs).build();
        if flags & TYPST_CONTEXT_DISABLE_PLUGINS != 0 {
            let mut filtered = Scope::new();
            for (name, binding) in library.global.scope().iter() {
                if name != "plugin" {
                    filtered.bind(name.clone(), binding.clone());
                }
            }
            *library.global.scope_mut() = filtered;
            library.std = Binding::detached(Value::Module(library.global.clone()));
        }
        Ok(Self {
            resources: Arc::new(Resources {
                library: LazyHash::new(library),
                fonts: store,
                files: memory_files,
            }),
        })
    }

    pub(crate) fn world(&self, source: &str, source_name: &str) -> Result<JobWorld, Error> {
        let path = if source_name.is_empty() {
            "main.typ"
        } else {
            source_name
        };
        let source = parsed_source(file_id(path)?, source);
        Ok(JobWorld {
            resources: Arc::clone(&self.resources),
            bytes: Bytes::from_string(source.clone()),
            source,
            setup: None,
        })
    }
}

/// Reported only when the library can discover fonts on a file system.
#[cfg(not(target_family = "wasm"))]
pub(crate) const FONT_DISCOVERY: u64 = crate::abi::TYPST_CAP_FONT_DISCOVERY;
#[cfg(target_family = "wasm")]
pub(crate) const FONT_DISCOVERY: u64 = 0;

/// typst-kit discovers the fonts and keeps them as lazily loaded file slots;
/// which directories to scan and whether to add system fonts is the caller's.
#[cfg(not(target_family = "wasm"))]
fn discover(store: &mut FontStore, dirs: &[PathBuf], system: bool) -> Result<(), Error> {
    for dir in dirs {
        store.extend(typst_kit::fonts::scan(dir));
    }
    if system {
        store.extend(typst_kit::fonts::system());
    }
    Ok(())
}

#[cfg(target_family = "wasm")]
fn discover(_: &mut FontStore, dirs: &[PathBuf], system: bool) -> Result<(), Error> {
    if dirs.is_empty() && !system {
        return Ok(());
    }
    Err(Error::unsupported(
        "font discovery is not available in this build",
    ))
}

fn file_id(path: &str) -> Result<FileId, Error> {
    let vpath = VirtualPath::new(path)
        .map_err(|err| Error::invalid(format!("invalid virtual path {path:?}: {err}")))?;
    Ok(RootedPath::new(VirtualRoot::Project, vpath).intern())
}

// Repeated immutable requests reuse Typst's Source tree through its existing
// comemo cache rather than reparsing identical input or maintaining a new cache.
#[comemo::memoize]
fn parsed_source(id: FileId, text: &str) -> Source {
    Source::new(id, text.to_owned())
}

pub(crate) struct JobWorld {
    pub(crate) resources: Arc<Resources>,
    pub(crate) source: Source,
    bytes: Bytes,
    pub(crate) setup: Option<Source>,
}

impl JobWorld {
    pub(crate) fn set_setup(&mut self, text: &str, name: &str) -> Result<(), Error> {
        let name = if name.is_empty() { "setup.typ" } else { name };
        let id = file_id(name)?;
        if id == self.source.id() {
            return Err(Error::invalid(
                "setup and body must have distinct source names",
            ));
        }
        self.setup = Some(parsed_source(id, text));
        Ok(())
    }
}

impl World for JobWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.resources.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.resources.fonts.book()
    }

    fn main(&self) -> FileId {
        self.source.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main() {
            return Ok(self.source.clone());
        }
        if let Some(setup) = &self.setup {
            if id == setup.id() {
                return Ok(setup.clone());
            }
        }
        let file = self
            .resources
            .files
            .get(&id)
            .ok_or_else(|| FileError::NotFound(id.vpath().get_with_slash().into()))?;
        file.source
            .get_or_init(|| {
                let text = std::str::from_utf8(&file.bytes).map_err(|_| FileError::InvalidUtf8)?;
                Ok(Source::new(id, text.to_owned()))
            })
            .clone()
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if id == self.main() {
            return Ok(self.bytes.clone());
        }
        if let Some(setup) = &self.setup {
            if id == setup.id() {
                return Ok(Bytes::from_string(setup.clone()));
            }
        }
        self.resources
            .files
            .get(&id)
            .map(|file| file.bytes.clone())
            .ok_or_else(|| FileError::NotFound(id.vpath().get_with_slash().into()))
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.resources.fonts.font(index)
    }

    // No clock or filesystem policy is implicit in an in-memory context.
    fn today(&self, _: Option<Duration>) -> Option<Datetime> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_fonts_are_validated_and_builtins_are_optional() {
        let data = typst_assets::fonts().next().unwrap().to_vec();
        let context = Context::new(
            vec![data],
            vec![],
            vec![],
            "",
            TYPST_CONTEXT_NO_BUILTIN_FONTS,
        )
        .unwrap();
        assert!(context.resources.fonts.font(0).is_some());
        assert!(Context::new(vec![vec![0, 1, 2]], vec![], vec![], "", 0).is_err());
        let empty =
            Context::new(vec![], vec![], vec![], "", TYPST_CONTEXT_NO_BUILTIN_FONTS).unwrap();
        assert!(empty.resources.fonts.font(0).is_none());
    }

    fn font_count(context: &Context) -> usize {
        let book = context.resources.fonts.book();
        (0..)
            .take_while(|&index| book.info(index).is_some())
            .count()
    }

    /// Discovered faces stay typst-kit file slots until a layout uses them.
    #[cfg(not(target_family = "wasm"))]
    fn path_backed(context: &Context, index: usize) -> bool {
        let source: &dyn std::any::Any = context.resources.fonts.source(index).unwrap();
        source
            .downcast_ref::<typst_kit::fonts::FontPath>()
            .is_some()
    }

    #[cfg(not(target_family = "wasm"))]
    #[test]
    fn font_directories_follow_supplied_fonts_and_load_on_first_use() {
        let mut embedded = typst_assets::fonts();
        let supplied = embedded.next().unwrap().to_vec();
        let root = std::env::temp_dir().join(format!("libtypst-font-dir-{}", std::process::id()));
        let nested = root.join("nested");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(nested.join("scanned.otf"), embedded.next().unwrap()).unwrap();

        let context = Context::new(
            vec![supplied.clone()],
            vec![root.clone()],
            vec![],
            "",
            TYPST_CONTEXT_NO_BUILTIN_FONTS,
        )
        .unwrap();
        std::fs::remove_dir_all(&root).unwrap();
        let fonts = &context.resources.fonts;
        let supplied_family = Font::new(Bytes::new(supplied), 0)
            .unwrap()
            .info()
            .family
            .clone();
        assert_eq!(fonts.book().info(0).unwrap().family, supplied_family);
        assert!(!path_backed(&context, 0));
        let last = font_count(&context) - 1;
        assert!(last > 0 && path_backed(&context, last));
        // The directory was removed before first use, so the lazily read face
        // is unavailable while the supplied font still loads.
        assert!(fonts.font(last).is_none());
        assert!(fonts.font(0).is_some());
    }

    #[cfg(not(target_family = "wasm"))]
    #[test]
    fn system_fonts_are_discovered_as_unread_file_slots() {
        let flags = TYPST_CONTEXT_NO_BUILTIN_FONTS | TYPST_CONTEXT_SYSTEM_FONTS;
        let context = Context::new(vec![], vec![], vec![], "", flags).unwrap();
        // A machine may have no system fonts; whatever is found stays unread.
        assert!((0..font_count(&context)).all(|index| path_backed(&context, index)));
    }

    #[test]
    fn file_paths_and_inputs_are_checked_before_context_creation() {
        assert!(Context::new(vec![], vec![], vec![], "[]", 0).is_err());
        assert!(Context::new(vec![], vec![], vec![], "{", 0).is_err());
        assert!(Context::new(vec![], vec![], vec![], "", 8).is_err());
        assert!(Context::new(
            vec![],
            vec![],
            vec![("a.typ".into(), vec![]), ("./a.typ".into(), vec![])],
            "",
            0,
        )
        .is_err());
        assert!(Context::new(vec![], vec![], vec![("../a.typ".into(), vec![])], "", 0).is_err());
    }

    #[test]
    fn memory_sources_are_cached_and_binary_files_remain_binary() {
        let context = Context::new(
            vec![],
            vec![],
            vec![
                ("parts/a.typ".into(), b"cached".to_vec()),
                ("data.bin".into(), vec![0, 255]),
            ],
            "",
            0,
        )
        .unwrap();
        let world = context.world("main", "main.typ").unwrap();
        let id = file_id("parts/a.typ").unwrap();
        let first = world.source(id).unwrap();
        let second = world.source(id).unwrap();
        assert!(std::ptr::eq(first.text().as_ptr(), second.text().as_ptr()));
        let binary = file_id("data.bin").unwrap();
        assert_eq!(world.file(binary).unwrap().as_slice(), [0, 255]);
        assert_eq!(world.source(binary).unwrap_err(), FileError::InvalidUtf8);
        assert!(world.font(usize::MAX).is_none());
    }
}
