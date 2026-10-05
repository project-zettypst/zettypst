#!/usr/bin/env python3
"""Install the workspace's Typst packages locally. Requires Python 3.11+."""

import argparse
from pathlib import Path

from package_typst import assemble, package_files


def install(package_root: Path, package_path: Path, *, link: bool = False) -> None:
    package_root = package_root.resolve()
    config, _ = package_files(package_root)
    package = config["package"]
    name, version = package["name"], package["version"]
    destination = package_path / "preview" / name / version
    for directory in destination.parents:
        if directory.is_symlink():
            raise ValueError(f"Refusing to install through a symlink: {directory}")
    # Migrate the old whole-package link to an assembled directory. Never remove
    # an unrelated link or follow it when replacing an installation.
    if destination.is_symlink():
        if destination.resolve() != package_root:
            raise ValueError(f"Refusing to replace an unrelated symlink: {destination}")
        destination.unlink()

    assemble(package_root, package_path, link=link)
    mode = "Linked" if link else "Copied"
    print(f"{mode} @preview/{name}:{version} to {destination}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--link",
        action="store_true",
        help="Link package source files instead of copying them.",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    package_path = root / ".dev" / "packages"
    for directory in ("core", "lsp/typst", "site/typst", "host/typst"):
        install(root / directory, package_path, link=args.link)
    print(f"Package path: {package_path}")


if __name__ == "__main__":
    main()
