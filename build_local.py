#!/usr/bin/env python3
"""Build an unminified material-osc.lua for a local mpv install.

Reuses bundle.py (module bundling + version embedding) but skips
minification and font subsetting, so the output stays readable (it contains
every source module verbatim). Install the full fonts from fonts/ into mpv's
fonts folder once.

Usage:
  python build_local.py [version] [--output PATH]

By default the script is written to build/material-osc.lua. Point --output at
mpv's scripts folder to install it, e.g.
  python build_local.py --output "C:/path/to/mpv/portable_config/scripts/material-osc.lua"
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import bundle  # noqa: E402

DEFAULT_OUTPUT = ROOT / "build" / "material-osc.lua"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("version", nargs="?", default="0.0.13")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    source, module_count = bundle.build_bundle(bundle.DEFAULT_SOURCE_DIR, bundle.ENTRY_FILE)
    source = bundle.embed_version(source, args.version)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source, encoding="utf-8", newline="\n")
    print(f"Built material-osc {args.version} ({module_count} modules) -> {args.output}")


if __name__ == "__main__":
    main()
