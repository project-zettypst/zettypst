mod ast_edits;
mod host;
mod progress;
mod server;
mod snapshot;
mod values;
mod worker;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, ValueHint};
use lsp_server::Connection;
use zettyp_eval::WorldOptions;

#[derive(Parser)]
#[command(
    name = "zettyp-lsp",
    version,
    about = "LSP adapter for Typst announcements"
)]
struct Arguments {
    /// Override the project root supplied during LSP initialization.
    #[arg(long, value_name = "DIR", value_hint = ValueHint::DirPath)]
    root: Option<PathBuf>,

    #[arg(long = "font-path", env = "TYPST_FONT_PATHS", value_delimiter = if cfg!(windows) { ';' } else { ':' }, value_hint = ValueHint::DirPath)]
    font_paths: Vec<PathBuf>,

    #[arg(long)]
    ignore_system_fonts: bool,

    #[arg(long, env = "TYPST_PACKAGE_PATH", value_hint = ValueHint::DirPath)]
    package_path: Option<PathBuf>,

    #[arg(long, env = "TYPST_PACKAGE_CACHE_PATH", value_hint = ValueHint::DirPath)]
    package_cache_path: Option<PathBuf>,
}

fn main() -> Result<()> {
    let args = Arguments::parse();
    let options = WorldOptions {
        font_paths: args.font_paths,
        ignore_system_fonts: args.ignore_system_fonts,
        package_path: args.package_path,
        package_cache_path: args.package_cache_path,
    };
    let (connection, threads) = Connection::stdio();
    server::run(&connection, args.root, options)?;
    drop(connection);
    threads.join()?;
    Ok(())
}
