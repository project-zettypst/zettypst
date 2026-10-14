#!/usr/bin/env python3
"""Install the workspace's zettyp package locally. Requires Python 3.11+."""

import argparse
from pathlib import Path
import re
import shutil
import tomllib


def install(package_root: Path, package_path: Path, *, link: bool = False) -> None:
    package_root = package_root.resolve()
    config = tomllib.loads((package_root / "typst.toml").read_text(encoding="utf-8"))
    package = config["package"]
    name, version = package["name"], package["version"]
    if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
        raise ValueError(f"Invalid package name: {name!r}")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError(f"Invalid package version: {version!r}")
    entrypoint = Path(package["entrypoint"])
    if entrypoint.is_absolute() or ".." in entrypoint.parts:
        raise ValueError(f"Invalid entrypoint: {entrypoint}")
    if not (package_root / entrypoint).is_file():
        raise FileNotFoundError(package_root / entrypoint)
    destination = package_path.absolute() / "preview" / name / version
    for directory in destination.parents:
        if directory.is_symlink():
            raise ValueError(f"Refusing to install through a symlink: {directory}")
    # Only replace links that already point to this source package.
    if destination.is_symlink():
        if destination.resolve() != package_root:
            raise ValueError(f"Refusing to replace an unrelated symlink: {destination}")
        destination.unlink()

    elif destination.exists():
        if not destination.is_dir():
            raise ValueError(f"Package destination is not a directory: {destination}")
        shutil.rmtree(destination)

    destination.parent.mkdir(parents=True, exist_ok=True)
    if link:
        destination.symlink_to(package_root, target_is_directory=True)
    else:
        shutil.copytree(package_root, destination)
    mode = "Linked" if link else "Copied"
    print(f"{mode} @preview/{name}:{version} to {destination}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--link",
        action="store_true",
        help="Link the package directory instead of copying it.",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    package_path = root / ".dev" / "packages"
    install(root / "typst", package_path, link=args.link)
    print(f"Package path: {package_path}")


if __name__ == "__main__":
    main()
