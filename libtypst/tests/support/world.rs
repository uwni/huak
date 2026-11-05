//! An in-memory test host. Resource policy belongs to this consumer, not to
//! libtypst. The same resources serve independent documents and repeated runs.
use std::sync::{Arc, OnceLock};

use typst_core::{
    diag::{FileError, FileResult},
    foundations::{Bytes, Datetime, Duration},
    syntax::{FileId, Source},
    text::{Font, FontBook},
    utils::LazyHash,
    Library, LibraryExt, World,
};

pub const MIXED_SOURCE: &str = r##"
#set page(width: auto, height: auto, margin: 8pt)
#set text(font: "Libertinus Serif", size: 12pt)
C ABI café Ω

$ integral_0^1 x^2 dif x = 1/3 $

#rect(width: 72pt, height: 16pt, fill: rgb("68a8d8"), stroke: 0.5pt)
"##;

pub struct Resources {
    pub library: LazyHash<Library>,
    pub book: LazyHash<FontBook>,
    pub fonts: Vec<Font>,
}

impl Resources {
    pub fn shared() -> Arc<Self> {
        static RESOURCES: OnceLock<Arc<Resources>> = OnceLock::new();
        RESOURCES
            .get_or_init(|| {
                let fonts: Vec<_> = typst_assets::fonts()
                    .flat_map(|data| Font::iter(Bytes::new(data)))
                    .collect();
                assert!(!fonts.is_empty(), "the test host needs bundled fonts");
                let book = LazyHash::new(FontBook::from_fonts(fonts.iter()));
                Arc::new(Resources {
                    library: LazyHash::new(Library::default()),
                    book,
                    fonts,
                })
            })
            .clone()
    }
}

pub struct MemoryWorld {
    pub resources: Arc<Resources>,
    pub source: Source,
    file: Bytes,
}

impl MemoryWorld {
    pub fn new(resources: Arc<Resources>, text: impl Into<String>) -> Self {
        let source = Source::detached(text);
        let file = Bytes::from_string(source.clone());
        Self {
            resources,
            source,
            file,
        }
    }

    pub fn replace_source(&mut self, text: &str) {
        self.source.replace(text);
        self.file = Bytes::from_string(self.source.clone());
    }
}

impl World for MemoryWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.resources.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &self.resources.book
    }

    fn main(&self) -> FileId {
        self.source.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main() {
            Ok(self.source.clone())
        } else {
            Err(FileError::NotFound(id.vpath().get_with_slash().into()))
        }
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if id == self.main() {
            Ok(self.file.clone())
        } else {
            Err(FileError::NotFound(id.vpath().get_with_slash().into()))
        }
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.resources.fonts.get(index).cloned()
    }

    fn today(&self, _: Option<Duration>) -> Option<Datetime> {
        None
    }
}
