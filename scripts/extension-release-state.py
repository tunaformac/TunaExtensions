#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import sys


STATE_KEYS = {
    "schema_version",
    "resolved_target",
    "project",
    "source_commit",
    "package",
    "item",
}
PACKAGE_KEYS = {"filename", "size_bytes", "checksum_sha256"}


def fail(message: str) -> None:
    raise SystemExit(f"Frozen release state is invalid: {message}")


def load_json(path: str, label: str) -> object:
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} cannot be read ({error})")


def require_regular_file(path: str, label: str) -> None:
    if not os.path.isfile(path) or os.path.islink(path):
        fail(f"missing regular {label}: {path}")


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def item_identity(item: object) -> tuple[str, str, str]:
    if not isinstance(item, dict):
        fail("item metadata is not an object")

    item_id = item.get("id")
    version = item.get("version")
    if not isinstance(item_id, str) or not re.fullmatch(
        r"[A-Za-z0-9]+(?:\.[A-Za-z0-9-]+)+", item_id
    ):
        fail(f"item id is invalid: {item_id!r}")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        fail(f"item version is invalid: {version!r}")

    return item_id, version, f"{item_id.replace('/', '_')}-{version}.tunaextension"


def validate_package(item: object, package: object, package_path: str) -> None:
    _, _, expected_filename = item_identity(item)
    if not isinstance(package, dict) or set(package) != PACKAGE_KEYS:
        fail("package metadata has an unexpected schema")
    if package.get("filename") != expected_filename:
        fail(f"package filename is {package.get('filename')!r}, expected {expected_filename!r}")

    actual_size = os.path.getsize(package_path)
    actual_checksum = sha256(package_path)
    size = package.get("size_bytes")
    checksum = package.get("checksum_sha256")
    if isinstance(size, bool) or not isinstance(size, int) or size < 1:
        fail("package size is not a positive integer")
    if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        fail("package checksum is not a SHA-256 digest")
    if size != actual_size:
        fail("package size no longer matches state.json")
    if checksum != actual_checksum:
        fail("package checksum no longer matches state.json")

    download = item.get("download")
    if not isinstance(download, dict):
        fail("item download metadata is not an object")
    if download.get("size_bytes") != actual_size:
        fail("item download size no longer matches the package")
    if str(download.get("checksum_sha256", "")).lower() != actual_checksum:
        fail("item download checksum no longer matches the package")


def load_state(args: argparse.Namespace) -> None:
    require_regular_file(args.state, "state file")
    require_regular_file(args.package, "package file")
    state = load_json(args.state, "state.json")

    if not isinstance(state, dict) or set(state) != STATE_KEYS:
        fail("state.json has an unexpected schema")
    if state["schema_version"] != "1":
        fail(f"unsupported schema version {state['schema_version']!r}")

    expected_identity = {
        "resolved_target": args.resolved_target,
        "project": args.project,
        "source_commit": args.source_commit,
    }
    for key, expected in expected_identity.items():
        if state.get(key) != expected:
            fail(f"{key} is {state.get(key)!r}, expected {expected!r}")

    validate_package(state.get("item"), state.get("package"), args.package)
    print(json.dumps(state["item"], separators=(",", ":"), sort_keys=True))


def freeze_state(args: argparse.Namespace) -> None:
    require_regular_file(args.item, "item metadata file")
    require_regular_file(args.package, "package file")
    item = load_json(args.item, "item metadata")
    _, _, package_filename = item_identity(item)
    package = {
        "filename": package_filename,
        "size_bytes": os.path.getsize(args.package),
        "checksum_sha256": sha256(args.package),
    }
    validate_package(item, package, args.package)

    state = {
        "schema_version": "1",
        "resolved_target": args.resolved_target,
        "project": args.project,
        "source_commit": args.source_commit,
        "package": package,
        "item": item,
    }
    try:
        with open(args.state, "x", encoding="utf-8") as file:
            json.dump(state, file, indent=2, sort_keys=True)
            file.write("\n")
    except OSError as error:
        fail(f"state.json cannot be written ({error})")


def parser() -> argparse.ArgumentParser:
    command_parser = argparse.ArgumentParser(description="Manage frozen extension release state.")
    subparsers = command_parser.add_subparsers(dest="command", required=True)

    def add_identity_arguments(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--resolved-target", required=True)
        subparser.add_argument("--project", required=True)
        subparser.add_argument("--source-commit", required=True)
        subparser.add_argument("--package", required=True)

    load_parser = subparsers.add_parser("load")
    add_identity_arguments(load_parser)
    load_parser.add_argument("--state", required=True)
    load_parser.set_defaults(handler=load_state)

    freeze_parser = subparsers.add_parser("freeze")
    add_identity_arguments(freeze_parser)
    freeze_parser.add_argument("--item", required=True)
    freeze_parser.add_argument("--state", required=True)
    freeze_parser.set_defaults(handler=freeze_state)
    return command_parser


def main() -> int:
    args = parser().parse_args()
    args.handler(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
