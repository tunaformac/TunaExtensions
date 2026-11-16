#!/usr/bin/env python3
"""Validate and rewrite one extension's TunaKit package references for local builds."""

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path


REMOTE_URL = "https://github.com/tunaformac/TunaKit"
SEMANTIC_VERSION = re.compile(
    r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


class RewriteError(Exception):
    pass


def fail(message):
    raise RewriteError(message)


def matching_brace(text, opening):
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    fail("malformed project.pbxproj: unterminated object")


def masked_noncode(text, mask_strings):
    masked = list(text)
    quote = None
    escaped = False
    line_comment = False
    block_comment = False
    index = 0
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
            else:
                masked[index] = " "
        elif block_comment:
            masked[index] = " "
            if char == "*" and following == "/":
                masked[index + 1] = " "
                block_comment = False
                index += 1
        elif quote:
            if mask_strings:
                masked[index] = " "
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char == "/" and following == "/":
            masked[index] = masked[index + 1] = " "
            line_comment = True
            index += 1
        elif char == "/" and following == "*":
            masked[index] = masked[index + 1] = " "
            block_comment = True
            index += 1
        elif char in "\"'":
            quote = char
            if mask_strings:
                masked[index] = " "
        index += 1
    return "".join(masked)


def package_reference_blocks(text):
    structure = masked_noncode(text, mask_strings=True)
    ranges = []
    for match in re.finditer(r"\bisa\s*=\s*XCRemoteSwiftPackageReference\s*;", structure):
        openings = list(re.finditer(r"=\s*\{", structure[: match.start()]))
        if not openings:
            fail("malformed project.pbxproj: package reference has no object")
        opening = None
        closing = None
        for candidate in reversed(openings):
            candidate_opening = candidate.end() - 1
            candidate_closing = matching_brace(structure, candidate_opening)
            if match.end() <= candidate_closing:
                opening = candidate_opening
                closing = candidate_closing
                break
        if opening is None:
            fail("malformed project.pbxproj: package reference is outside its object")
        item = (opening, closing + 1)
        if item not in ranges:
            ranges.append(item)
    return ranges


def unquote(value):
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            fail("malformed project.pbxproj: invalid quoted repositoryURL")
    return value


def quote(value):
    return json.dumps(value, ensure_ascii=False)


def rewritten_project(path, package_url):
    text = path.read_text()
    matches = []
    repository_pattern = re.compile(r"\brepositoryURL\s*=\s*(\"(?:\\.|[^\"])*\"|[^;]+?)\s*;")
    for opening, closing in package_reference_blocks(text):
        block = text[opening:closing]
        searchable_block = masked_noncode(block, mask_strings=False)
        repositories = list(repository_pattern.finditer(searchable_block))
        if len(repositories) != 1:
            fail(
                f"{path}: each XCRemoteSwiftPackageReference must contain exactly one repositoryURL"
            )
        repository = repositories[0]
        if unquote(repository.group(1)) == REMOTE_URL:
            matches.append((opening + repository.start(1), opening + repository.end(1)))

    if len(matches) != 1:
        fail(f"{path}: expected exactly one TunaKit package reference, found {len(matches)}")
    start, end = matches[0]
    return text[:start] + quote(package_url) + text[end:]


def load_resolved(path):
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{path}: malformed Package.resolved: {error}")
    if not isinstance(document, dict):
        fail(f"{path}: Package.resolved must contain a JSON object")
    return document


def resolved_pin(document, path):
    version = document.get("version")
    if version == 1:
        container = document.get("object")
        pins = container.get("pins") if isinstance(container, dict) else None
        identity_key = "package"
        location_key = "repositoryURL"
        expected_identity = "TunaKit"
    elif version in (2, 3):
        pins = document.get("pins")
        identity_key = "identity"
        location_key = "location"
        expected_identity = "tunakit"
    else:
        fail(f"{path}: unsupported Package.resolved version {version!r}; expected 1, 2, or 3")

    if not isinstance(pins, list):
        fail(f"{path}: Package.resolved pins must be an array")
    matches = [pin for pin in pins if isinstance(pin, dict) and pin.get(identity_key) == expected_identity]
    if len(matches) != 1:
        fail(f"{path}: expected exactly one TunaKit resolved pin, found {len(matches)}")

    pin = matches[0]
    if version in (2, 3) and pin.get("kind") != "remoteSourceControl":
        fail(f"{path}: TunaKit resolved pin has unexpected kind: {pin.get('kind')!r}")
    if pin.get(location_key) != REMOTE_URL:
        fail(f"{path}: TunaKit resolved pin has unexpected {location_key}: {pin.get(location_key)!r}")
    state = pin.get("state")
    if not isinstance(state, dict) or not isinstance(state.get("version"), str):
        fail(f"{path}: TunaKit resolved pin must contain a semantic version state")
    if not SEMANTIC_VERSION.fullmatch(state["version"]):
        fail(f"{path}: TunaKit resolved pin has invalid semantic version: {state['version']!r}")
    if not isinstance(state.get("revision"), str) or not state["revision"]:
        fail(f"{path}: TunaKit resolved pin must contain a revision")
    if "branch" in state:
        fail(f"{path}: TunaKit resolved pin cannot contain both version and branch state")
    return pin, location_key


def resolved_version(path):
    document = load_resolved(path)
    pin, _ = resolved_pin(document, path)
    return pin["state"]["version"]


def package_identity(location):
    """Mirror SwiftPM: a location's identity is its last path component, minus .git, lowercased."""
    name = location.rstrip("/").rsplit("/", 1)[-1]
    if name.endswith(".git"):
        name = name[: -len(".git")]
    return name.lower()


def validate_package_identity(package_url):
    # The pin keeps its "tunakit" identity. A location with any other identity makes SwiftPM fetch
    # the same repository twice in one resolve (once per identity), racing into one clone path.
    if package_identity(package_url) != "tunakit":
        fail(
            f"local package location must end in TunaKit to match the TunaKit pin identity: "
            f"{package_url!r}"
        )


def rewritten_resolved(path, package_url, revision):
    document = load_resolved(path)
    pin, location_key = resolved_pin(document, path)
    pin[location_key] = package_url
    pin["state"]["revision"] = revision
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def replace_files(contents):
    temporary_paths = []
    try:
        for path, content in contents:
            descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
            with os.fdopen(descriptor, "w") as output:
                output.write(content)
            temporary_paths.append((path, Path(temporary)))
        for path, temporary in temporary_paths:
            os.replace(temporary, path)
    finally:
        for _, temporary in temporary_paths:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    versions = subparsers.add_parser("versions")
    versions.add_argument("files", nargs="+")

    rewrite = subparsers.add_parser("rewrite")
    rewrite.add_argument("--project", required=True)
    rewrite.add_argument("--resolved", required=True)
    rewrite.add_argument("--package-url", required=True)
    rewrite.add_argument("--revision", required=True)
    arguments = parser.parse_args()

    try:
        if arguments.command == "versions":
            for filename in arguments.files:
                print(resolved_version(Path(filename)))
        else:
            project = Path(arguments.project)
            resolved = Path(arguments.resolved)
            validate_package_identity(arguments.package_url)
            project_content = rewritten_project(project, arguments.package_url)
            resolved_content = rewritten_resolved(resolved, arguments.package_url, arguments.revision)
            replace_files(((project, project_content), (resolved, resolved_content)))
    except (OSError, RewriteError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
