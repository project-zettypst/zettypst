#!/usr/bin/env python3
"""Assemble release packages in .dev/dist/preview. Requires Python 3.11+."""

from pathlib import Path
import re
import shutil
import tomllib


ROOT = Path(__file__).resolve().parents[1]


def package_files(source: Path) -> tuple[dict, dict[Path, Path]]:
    """Map package-relative destinations to source files for copy or link installs."""
    source = source.resolve()
    config = tomllib.loads((source / "typst.toml").read_text(encoding="utf-8"))
    package = config["package"]
    if not re.fullmatch(r"[a-z][a-z0-9-]*", package["name"]):
        raise ValueError(f"Invalid package name: {package['name']!r}")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", package["version"]):
        raise ValueError(f"Invalid package version: {package['version']!r}")

    files = {}
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if "tests" in relative.parts:
            continue
        if path.is_symlink():
            raise ValueError(f"Package source must not contain symlinks: {path}")
        if path.is_file():
            files[relative] = path

    if source == ROOT / "core":
        kickstart = ROOT / "kickstart"
        for path in sorted((kickstart / "template").rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Template must not contain symlinks: {path}")
            if path.is_file():
                files[path.relative_to(kickstart)] = path
        for name in ("thumbnail.png", ".ignore"):
            files[Path(name)] = kickstart / name

    required = ["typst.toml", "LICENSE", "README.md", package["entrypoint"]]
    if template := config.get("template"):
        required.extend(
            [
                str(Path(template["path"]) / template["entrypoint"]),
                template["thumbnail"],
            ]
        )
    for name in required:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or path not in files:
            raise ValueError(f"Missing or invalid package file: {name}")
    for path in files.values():
        if not path.is_file():
            raise FileNotFoundError(path)
    return config, files


def assemble(source: Path, package_path: Path, *, link: bool = False) -> Path:
    config, files = package_files(source)
    package = config["package"]
    destination = package_path / "preview" / package["name"] / package["version"]
    for directory in (destination, *destination.parents):
        if directory.is_symlink():
            raise ValueError(f"Refusing to install through a symlink: {directory}")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for relative, original in files.items():
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if link:
            target.symlink_to(original)
        else:
            shutil.copy2(original, target)
    return destination


def main() -> None:
    for source in (ROOT / "core", ROOT / "lsp/typst", ROOT / "host/typst"):
        print(assemble(source, ROOT / ".dev/dist"))


if __name__ == "__main__":
    main()
