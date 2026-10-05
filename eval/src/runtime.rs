use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Result;
use typst::diag::Warned;
use typst::foundations::{Dict, Value};

use crate::{Dependencies, ProjectWorld, SourceSnapshot, WorldOptions, eval};

/// One completed attempt, successful or not, with its original source provenance.
/// Retaining this value keeps ordinary Typst Content spans usable after edits.
pub struct Evaluation {
    pub revision: u64,
    pub result: Warned<Result<Value>>,
    pub sources: SourceSnapshot,
    pub dependencies: Dependencies,
    pub reads: BTreeMap<PathBuf, Option<String>>,
}

/// A single project's long-lived evaluator. Requests are evaluated sequentially.
pub struct Runtime {
    world: ProjectWorld,
    revision: u64,
    latest: Option<Arc<Evaluation>>,
}

impl Runtime {
    pub fn new(root: impl AsRef<Path>) -> Result<Self> {
        Self::new_with_options(root, WorldOptions::default())
    }

    pub fn new_with_options(root: impl AsRef<Path>, options: WorldOptions) -> Result<Self> {
        // The placeholder does not need to exist; evaluate() selects the entry.
        let world = ProjectWorld::new_with_options(root, "main.typ", Dict::new(), options)?;
        Ok(Self {
            world,
            revision: 0,
            latest: None,
        })
    }

    /// Read current disk files and evaluate an entry. Inputs replace the previous
    /// request's inputs; an empty dictionary resets them.
    ///
    /// Invalid configuration returns an outer error without advancing revision.
    /// Compilation/announcement errors are stored in the returned evaluation and
    /// replace latest just like successful attempts. Old success is never reused
    /// as a substitute for a failed attempt.
    ///
    /// Typst's process-wide cache is aged after each attempt, retaining recently
    /// used entries for ten rounds. This also ages caches of other Typst users in
    /// the same process, but does not invalidate any retained Evaluation values.
    pub fn evaluate(&mut self, entry: impl AsRef<Path>, inputs: Dict) -> Result<Arc<Evaluation>> {
        self.evaluate_with_sources(entry, inputs, BTreeMap::new())
    }

    /// Evaluate with a complete set of project-relative source overrides.
    /// Source text is input, not an instruction to write files to disk.
    pub fn evaluate_with_sources(
        &mut self,
        entry: impl AsRef<Path>,
        inputs: Dict,
        sources: BTreeMap<PathBuf, Option<String>>,
    ) -> Result<Arc<Evaluation>> {
        self.world.prepare_with_sources(entry, inputs, sources)?;
        self.revision += 1;
        let result = eval(&self.world);
        let sources = self.world.snapshot();
        let evaluation = Arc::new(Evaluation {
            revision: self.revision,
            result,
            sources,
            dependencies: self.world.dependencies(),
            reads: self.world.reads(),
        });
        self.latest = Some(evaluation.clone());
        typst::comemo::evict(10);
        Ok(evaluation)
    }

    pub fn validates(
        &self,
        dependencies: &Dependencies,
        sources: &BTreeMap<PathBuf, String>,
    ) -> bool {
        self.world.validates(dependencies, sources)
    }

    pub fn latest(&self) -> Option<&Arc<Evaluation>> {
        self.latest.as_ref()
    }
}
