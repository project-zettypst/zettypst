use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::ops::Range;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::dependencies::{Dependencies, Dependency, PackageDependency, content_hash, value_hash};

use anyhow::{Context, Result, bail};
use chrono::{DateTime, Datelike, FixedOffset, Local};
use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime, Dict, Duration};
use typst::syntax::package::PackageSpec;
use typst::syntax::{DiagSpan, DiagSpanKind, FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_kit::downloader::SystemDownloader;
use typst_kit::fonts::{self, FontStore};
use typst_kit::packages::{FsPackages, SystemPackages, UniversePackages};

/// Host environment shared by all evaluations in a runtime.
/// Fonts are discovered when the runtime is created.
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct WorldOptions {
    pub font_paths: Vec<PathBuf>,
    pub ignore_system_fonts: bool,
    pub package_path: Option<PathBuf>,
    pub package_cache_path: Option<PathBuf>,
}

/// Files and configuration retained across Typst evaluations.
pub struct ProjectWorld {
    root: PathBuf,
    main: FileId,
    inputs: Dict,
    library: LazyHash<Library>,
    book: LazyHash<FontBook>,
    fonts: FontStore,
    slots: Mutex<HashMap<FileId, FileSlot>>,
    overrides: HashMap<FileId, Option<Bytes>>,
    packages: SystemPackages,
    package_roots: Mutex<HashMap<PackageSpec, PathBuf>>,
    now: DateTime<Local>,
    observed_book: AtomicBool,
    observed_font: AtomicBool,
    observed_today: AtomicBool,
}

impl ProjectWorld {
    pub fn new(root: impl AsRef<Path>, entry: impl AsRef<Path>, inputs: Dict) -> Result<Self> {
        Self::new_with_options(root, entry, inputs, WorldOptions::default())
    }

    pub fn new_with_options(
        root: impl AsRef<Path>,
        entry: impl AsRef<Path>,
        inputs: Dict,
        options: WorldOptions,
    ) -> Result<Self> {
        let root = root.as_ref().canonicalize().with_context(|| {
            format!("failed to resolve project root {}", root.as_ref().display())
        })?;
        if !root.is_dir() {
            bail!("project root must be a directory");
        }
        let main = entry_id(entry.as_ref())?;
        let mut fonts = FontStore::new();
        for path in &options.font_paths {
            fonts.extend(fonts::scan(path));
        }
        if !options.ignore_system_fonts {
            fonts.extend(fonts::system());
        }
        fonts.extend(fonts::embedded());
        let packages = SystemPackages::from_parts(
            options
                .package_path
                .map(FsPackages::new)
                .or_else(FsPackages::system_data),
            options
                .package_cache_path
                .map(FsPackages::new)
                .or_else(FsPackages::system_cache),
            UniversePackages::new(SystemDownloader::new(concat!(
                "zettyp-eval/",
                env!("CARGO_PKG_VERSION")
            ))),
        );
        let library = Library::builder().with_inputs(inputs.clone()).build();

        Ok(Self {
            root,
            main,
            inputs,
            library: LazyHash::new(library),
            book: fonts.book().clone(),
            fonts,
            slots: Mutex::new(HashMap::new()),
            overrides: HashMap::new(),
            packages,
            package_roots: Mutex::new(HashMap::new()),
            now: Local::now(),
            observed_book: AtomicBool::new(false),
            observed_font: AtomicBool::new(false),
            observed_today: AtomicBool::new(false),
        })
    }

    /// Begin another evaluation. This does not discard unchanged sources.
    ///
    /// Files are read once on their first access in the new evaluation, including
    /// files that previously failed to load. Inputs replace, rather than merge
    /// with, the previous inputs. Invalid entries leave the world unchanged.
    pub fn prepare(&mut self, entry: impl AsRef<Path>, inputs: Dict) -> Result<()> {
        self.prepare_with_sources(entry, inputs, BTreeMap::new())
    }

    /// Replace the complete in-memory source set for this evaluation. Omitted
    /// files fall back to disk, including files whose buffers were closed.
    pub fn prepare_with_sources(
        &mut self,
        entry: impl AsRef<Path>,
        inputs: Dict,
        sources: BTreeMap<PathBuf, Option<String>>,
    ) -> Result<()> {
        let main = entry_id(entry.as_ref())?;
        let overrides = sources
            .into_iter()
            .map(|(path, text)| {
                Ok((
                    entry_id(&path)?,
                    text.map(|text| Bytes::new(text.into_bytes())),
                ))
            })
            .collect::<Result<_>>()?;
        self.main = main;
        self.overrides = overrides;
        self.now = Local::now();
        self.package_roots.get_mut().unwrap().clear();
        if self.inputs != inputs {
            self.library = LazyHash::new(Library::builder().with_inputs(inputs.clone()).build());
            self.inputs = inputs;
        }
        let slots = self.slots.get_mut().unwrap();
        // Do not accumulate files from every entry ever evaluated. Snapshots
        // independently retain any sources still needed by their callers.
        slots.retain(|_, slot| slot.accessed);
        for slot in slots.values_mut() {
            slot.accessed = false;
        }
        Ok(())
    }

    pub fn path_for(&self, id: FileId) -> FileResult<PathBuf> {
        let VirtualRoot::Package(spec) = id.root() else {
            return id
                .vpath()
                .realize(&self.root)
                .map_err(|_| FileError::AccessDenied);
        };
        let mut roots = self.package_roots.lock().unwrap();
        if !roots.contains_key(spec) {
            let root = self.packages.obtain(spec)?.path().to_path_buf();
            roots.insert(spec.clone(), root);
        }
        id.vpath()
            .realize(&roots[spec])
            .map_err(|_| FileError::AccessDenied)
    }

    /// Capture the sources actually observed in this evaluation, without disk IO.
    pub fn snapshot(&self) -> SourceSnapshot {
        let sources = self
            .slots
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, slot)| slot.accessed && !slot.source_stale)
            .filter_map(|(&id, slot)| {
                slot.source
                    .as_ref()?
                    .as_ref()
                    .ok()
                    .map(|source| (id, source.clone()))
            })
            .collect();
        SourceSnapshot {
            root: self.root.clone(),
            package_roots: self.package_roots.lock().unwrap().clone(),
            sources,
        }
    }

    /// Capture hashes of bytes actually consumed, not a later disk observation.
    pub fn dependencies(&self) -> Dependencies {
        let mut result = Dependencies {
            files: Vec::new(),
            packages: Vec::new(),
            font_book: self
                .observed_book
                .load(Ordering::Relaxed)
                .then(|| value_hash(&*self.book)),
            unsupported: None,
        };
        // Sticky for this Runtime: cached Typst calls may retain earlier values.
        if self.observed_today.load(Ordering::Relaxed) {
            result.unsupported = Some("time-dependent evaluation".into());
        }
        if self.observed_font.load(Ordering::Relaxed) {
            result.unsupported =
                Some("font bytes were used; persistent validation is unsupported".into());
        }
        for (id, slot) in self
            .slots
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, slot)| slot.accessed)
        {
            match (&slot.bytes, self.path_for(*id)) {
                (Some(Ok(bytes)), Ok(path)) => result.files.push(Dependency {
                    path,
                    hash: content_hash(bytes),
                }),
                _ => result.unsupported = Some("failed or unresolved file read".into()),
            }
        }
        for (spec, resolved) in self.package_roots.lock().unwrap().iter() {
            let suffix = format!("{}/{}/{}", spec.namespace, spec.name, spec.version);
            let candidates = [
                self.packages.data().map(FsPackages::path),
                self.packages.cache().map(FsPackages::path),
            ]
            .into_iter()
            .flatten()
            .map(|path| path.join(&suffix))
            .collect();
            result.packages.push(PackageDependency {
                candidates,
                resolved: resolved.clone(),
            });
        }
        result.files.sort_by(|a, b| a.path.cmp(&b.path));
        result
    }

    /// Project-relative disk reads only; overlays and packages are excluded.
    pub fn reads(&self) -> BTreeMap<PathBuf, Option<String>> {
        self.slots
            .lock()
            .unwrap()
            .iter()
            .filter(|(id, slot)| {
                slot.accessed
                    && matches!(id.root(), VirtualRoot::Project)
                    && !self.overrides.contains_key(id)
            })
            .filter_map(|(id, slot)| match &slot.bytes {
                Some(Ok(bytes)) => Some((
                    PathBuf::from(id.vpath().get_without_slash()),
                    Some(content_hash(bytes)),
                )),
                Some(Err(FileError::NotFound(_))) => {
                    Some((PathBuf::from(id.vpath().get_without_slash()), None))
                }
                _ => None,
            })
            .collect()
    }

    pub fn validates(
        &self,
        dependencies: &Dependencies,
        sources: &BTreeMap<PathBuf, String>,
    ) -> bool {
        dependencies
            .font_book
            .as_ref()
            .is_none_or(|hash| *hash == value_hash(&*self.book))
            && dependencies.matches(&self.root, sources)
    }

    fn with_slot<T>(&self, id: FileId, f: impl FnOnce(&mut FileSlot) -> T) -> T {
        let mut slots = self.slots.lock().unwrap();
        let slot = slots.entry(id).or_default();
        if !slot.accessed {
            let bytes = if let Some(bytes) = self.overrides.get(&id) {
                bytes
                    .clone()
                    .ok_or_else(|| FileError::NotFound(id.vpath().get_without_slash().into()))
            } else {
                self.path_for(id).and_then(|path| {
                    fs::read(&path)
                        .map(Bytes::new)
                        .map_err(|error| FileError::from_io(error, &path))
                })
            };
            if slot.bytes.as_ref() != Some(&bytes) {
                slot.source_stale = true;
                slot.bytes = Some(bytes);
            }
            slot.accessed = true;
        }
        f(slot)
    }
}

impl World for ProjectWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.observed_book.store(true, Ordering::Relaxed);
        &self.book
    }

    fn main(&self) -> FileId {
        self.main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        self.with_slot(id, |slot| slot.source(id))
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        self.with_slot(id, |slot| slot.bytes.as_ref().unwrap().clone())
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.observed_font.store(true, Ordering::Relaxed);
        self.fonts.font(index)
    }

    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.observed_today.store(true, Ordering::Relaxed);
        let date = match offset {
            None => self.now.date_naive(),
            Some(offset) => {
                let seconds = offset.seconds();
                if !seconds.is_finite() || seconds.abs() >= 86400.0 {
                    return None;
                }
                let seconds = seconds as i32;
                let offset = FixedOffset::east_opt(seconds)?;
                self.now.with_timezone(&offset).date_naive()
            }
        };
        Datetime::from_ymd(
            date.year(),
            date.month().try_into().ok()?,
            date.day().try_into().ok()?,
        )
    }
}

#[derive(Default)]
struct FileSlot {
    // Both source() and file() use these same bytes for the whole evaluation.
    bytes: Option<FileResult<Bytes>>,
    source: Option<FileResult<Source>>,
    source_stale: bool,
    accessed: bool,
}

impl FileSlot {
    fn source(&mut self, id: FileId) -> FileResult<Source> {
        if self.source_stale || self.source.is_none() {
            let previous = self.source.take().and_then(Result::ok);
            let source = self.bytes.as_ref().unwrap().clone().and_then(|bytes| {
                let text = std::str::from_utf8(&bytes)?;
                Ok(if let Some(mut source) = previous {
                    source.replace(text);
                    source
                } else {
                    Source::new(id, text.to_owned())
                })
            });
            self.source = Some(source);
            self.source_stale = false;
        }
        self.source.as_ref().unwrap().clone()
    }
}

/// Source provenance for one evaluation. Never reads from the live world or disk.
///
/// Typst sources are cheap, copy-on-write clones: later edits cannot change this
/// snapshot's text or span resolution. This is a record of the bytes observed
/// while evaluating, not an atomic snapshot of the entire filesystem.
#[derive(Clone)]
pub struct SourceSnapshot {
    root: PathBuf,
    package_roots: HashMap<PackageSpec, PathBuf>,
    sources: HashMap<FileId, Source>,
}

impl SourceSnapshot {
    pub fn source(&self, id: FileId) -> Option<&Source> {
        self.sources.get(&id)
    }

    pub fn path_for(&self, id: FileId) -> FileResult<PathBuf> {
        let root = match id.root() {
            VirtualRoot::Package(spec) => self
                .package_roots
                .get(spec)
                .ok_or_else(|| FileError::NotFound(id.vpath().get_without_slash().into()))?,
            VirtualRoot::Project => &self.root,
        };
        id.vpath()
            .realize(root)
            .map_err(|_| FileError::AccessDenied)
    }

    pub fn range(&self, span: impl Into<DiagSpan>) -> Option<Range<usize>> {
        let span = span.into();
        let source = self.source(span.id()?)?;
        match span.get() {
            DiagSpanKind::Detached => None,
            DiagSpanKind::Number { num, sub_range, .. } => source.range(num, sub_range),
            DiagSpanKind::Range { range, .. } => Some(range),
        }
    }
}

fn entry_id(entry: &Path) -> Result<FileId> {
    if entry.is_absolute()
        || entry
            .components()
            .any(|part| matches!(part, Component::ParentDir))
        || !entry
            .components()
            .any(|part| matches!(part, Component::Normal(_)))
    {
        bail!("entry must be a non-empty project-relative path without '..'");
    }
    let path = entry.to_str().context("entry path is not valid UTF-8")?;
    let path = VirtualPath::new(path.replace(std::path::MAIN_SEPARATOR, "/"))?;
    Ok(FileId::new(RootedPath::new(VirtualRoot::Project, path)))
}
