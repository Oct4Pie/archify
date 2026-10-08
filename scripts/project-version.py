#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


def parse_target(project_text: str, bundle_identifier: str) -> dict[str, str]:
    block_pattern = re.compile(
        r"[A-F0-9]+ /\* Release \*/ = \{\s*"
        r"isa = XCBuildConfiguration;\s*"
        r"buildSettings = \{(?P<settings>.*?)\n\s*\};\s*"
        r"name = Release;\s*\};",
        re.DOTALL,
    )

    for match in block_pattern.finditer(project_text):
        settings = match.group("settings")
        if f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_identifier};" not in settings:
            continue

        marketing = re.search(
            r"MARKETING_VERSION = ([^;]+);",
            settings,
        )
        build = re.search(
            r"CURRENT_PROJECT_VERSION = ([^;]+);",
            settings,
        )
        if marketing and build:
            return {
                "version": marketing.group(1).strip().strip('"'),
                "build": build.group(1).strip().strip('"'),
            }

    raise SystemExit(
        f"Release settings not found for {bundle_identifier}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--project",
        default="archify.xcodeproj/project.pbxproj",
    )
    parser.add_argument(
        "--format",
        choices=("plain", "json", "shell"),
        default="plain",
    )
    parser.add_argument(
        "--target",
        choices=("app", "helper", "both"),
        default="both",
    )
    args = parser.parse_args()

    project = Path(args.project)
    text = project.read_text(encoding="utf-8")
    app = parse_target(text, "com.oct4pie.archify")
    helper = parse_target(text, "com.oct4pie.archifyhelper")

    if args.target == "both" and app != helper:
        raise SystemExit(
            "App/helper Release versions differ: "
            f"app={app['version']}+{app['build']} "
            f"helper={helper['version']}+{helper['build']}"
        )

    payload = helper if args.target == "helper" else app

    if args.format == "json":
        print(json.dumps(payload, sort_keys=True))
    elif args.format == "shell":
        print(f"ARCHIFY_VERSION={payload['version']}")
        print(f"ARCHIFY_BUILD={payload['build']}")
    else:
        print(f"{payload['version']}+{payload['build']}")


if __name__ == "__main__":
    main()
