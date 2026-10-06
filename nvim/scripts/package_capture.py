#!/usr/bin/env python3
"""Assemble or locally install the zettyp-capture Typst package."""
import argparse
from pathlib import Path
import shutil
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def assemble(package_path: Path, *, link: bool = False) -> Path:
    source = ROOT / 'capture'
    package = tomllib.loads((source / 'typst.toml').read_text())['package']
    destination = package_path.absolute() / 'preview' / package['name'] / package['version']
    files = ['typst.toml', 'lib.typ', 'LICENSE']
    if (source / 'README.md').exists():
        files.append('README.md')
    for parent in (destination, *destination.parents):
        if parent.is_symlink():
            raise ValueError(f'Refusing to install through symlink: {parent}')
    destination.mkdir(parents=True, exist_ok=True)
    for name in files:
        target = destination / name
        if target.is_symlink():
            if target.resolve() != (source / name).resolve():
                raise ValueError(f'Refusing to replace unrelated symlink: {target}')
            target.unlink()
        if link:
            if target.exists():
                target.unlink()
            target.symlink_to(source / name)
        else:
            shutil.copy2(source / name, target)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package-path', type=Path, default=ROOT / '.dev/dist')
    parser.add_argument('--link', action='store_true')
    args = parser.parse_args()
    print(assemble(args.package_path, link=args.link))


if __name__ == '__main__':
    main()
