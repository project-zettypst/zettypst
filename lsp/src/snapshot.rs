//! Private, bounded, disposable announcement snapshots. Never a semantic source.
use std::{
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use zettyp_eval::{Dependencies, Runtime, WorldOptions, content_hash};

use crate::worker::EvalParams;

#[cfg(test)]
mod tests;

const VERSION: u32 = 2;
const MAX_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Payload {
    pub dependencies: Dependencies,
    pub output: Value,
    pub warnings: Vec<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    key: String,
    checksum: String,
    payload: Payload,
}

pub struct Store {
    root: PathBuf,
    directory: PathBuf,
    identity: Value,
}

impl Store {
    pub fn new(root: &Path, options: &WorldOptions) -> Result<Self> {
        ensure!(
            std::env::var_os("ZETTYP_LSP_SNAPSHOT").as_deref() != Some(std::ffi::OsStr::new("0")),
            "disabled by ZETTYP_LSP_SNAPSHOT=0"
        );
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .context("HOME unavailable")?;
        let base = std::env::var_os("ZETTYP_LSP_CACHE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                if cfg!(target_os = "macos") {
                    home.join("Library/Caches/zettyp-lsp")
                } else {
                    std::env::var_os("XDG_CACHE_HOME")
                        .map(PathBuf::from)
                        .filter(|p| p.is_absolute())
                        .unwrap_or_else(|| home.join(".cache"))
                        .join("zettyp-lsp")
                }
            });
        ensure!(base.is_absolute(), "cache directory must be absolute");
        // No cache writes within the watched workspace.
        private_directory(&base)?;
        let directory = base.canonicalize()?;
        ensure!(
            !directory.starts_with(root),
            "cache directory is inside project"
        );
        let executable = fs::read(std::env::current_exe()?)?;
        let identity = serde_json::json!({
            "root": root, "executable": content_hash(&executable), "options": options,
            "home": home, "xdg_data": std::env::var_os("XDG_DATA_HOME"),
            "xdg_cache": std::env::var_os("XDG_CACHE_HOME"),
        });
        Ok(Self {
            root: root.to_owned(),
            directory,
            identity,
        })
    }

    // Stable slot avoids retaining a full index for every executable rebuild.
    fn key(&self, params: &EvalParams) -> Result<String> {
        Ok(content_hash(&serde_json::to_vec(&(
            &self.root,
            &params.entry,
            &params.inputs,
        ))?))
    }

    fn fingerprint(&self, params: &EvalParams) -> Result<String> {
        Ok(content_hash(&serde_json::to_vec(&(
            &self.identity,
            &params.entry,
            &params.inputs,
        ))?))
    }

    pub fn load(
        &self,
        runtime: &Runtime,
        params: &EvalParams,
        sources: &BTreeMap<PathBuf, String>,
    ) -> Result<Payload> {
        let key = self.fingerprint(params)?;
        let path = self.directory.join(format!("{}.json", self.key(params)?));
        private_file(&path)?;
        let mut open = fs::OpenOptions::new();
        open.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            open.custom_flags(libc::O_NOFOLLOW);
        }
        let file = open.open(&path)?;
        ensure!(file.metadata()?.len() <= MAX_BYTES, "snapshot too large");
        let mut bytes = Vec::new();
        file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() as u64 <= MAX_BYTES, "snapshot too large");
        let envelope: Envelope = serde_json::from_slice(&bytes)?;
        ensure!(
            envelope.version == VERSION && envelope.key == key,
            "incompatible snapshot"
        );
        ensure!(
            content_hash(&serde_json::to_vec(&envelope.payload)?) == envelope.checksum,
            "snapshot checksum mismatch"
        );
        ensure!(
            runtime.validates(&envelope.payload.dependencies, sources),
            "dependencies changed or unsupported"
        );
        Ok(envelope.payload)
    }

    pub fn save(
        &self,
        params: &EvalParams,
        payload: Payload,
        sources: &BTreeMap<PathBuf, String>,
    ) -> Result<()> {
        ensure!(
            payload.dependencies.matches(&self.root, sources),
            "dependencies changed, unsaved, or unsupported"
        );
        let key = self.fingerprint(params)?;
        let checksum = content_hash(&serde_json::to_vec(&payload)?);
        let bytes = serde_json::to_vec(&Envelope {
            version: VERSION,
            key: key.clone(),
            checksum,
            payload,
        })?;
        ensure!(bytes.len() as u64 <= MAX_BYTES, "snapshot too large");
        let mut temp = tempfile::NamedTempFile::new_in(&self.directory)?;
        temp.write_all(&bytes)?;
        // Last writer wins safely: every reader validates exact provenance.
        temp.persist(self.directory.join(format!("{}.json", self.key(params)?)))?;
        Ok(())
    }
}

#[cfg(unix)]
fn private_directory(path: &Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_dir() && meta.mode() & 0o077 == 0 && meta.uid() == unsafe { libc::geteuid() },
        "cache directory is not private or owned"
    );
    Ok(())
}
#[cfg(unix)]
fn private_file(path: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_file() && meta.mode() & 0o077 == 0 && meta.uid() == unsafe { libc::geteuid() },
        "snapshot is not a private owned regular file"
    );
    Ok(())
}
#[cfg(not(unix))]
fn private_directory(_: &Path) -> Result<()> {
    anyhow::bail!("private snapshot storage unsupported on this platform")
}
#[cfg(not(unix))]
fn private_file(_: &Path) -> Result<()> {
    anyhow::bail!("private snapshot storage unsupported on this platform")
}
