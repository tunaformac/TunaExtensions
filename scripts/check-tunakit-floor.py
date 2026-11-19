#!/usr/bin/env python3
"""Fail when a built extension needs more than its declared minimum Tuna / TunaKit.

Two checks:

1. Every TunaKit symbol the extension binary imports (non-weak) must be exported by the TunaKit
   release named by its minimum. That release's published xcframework is downloaded once, verified
   against the checksum in TunaKit's Package.swift at that tag, and its exported symbols are cached
   under build/tunakit-floor/<version>/<arch>.exports, so a warm cache needs no network.
2. The minimum Tuna must ship at least the minimum TunaKit (scripts/tuna-tunakit-versions.tsv).
"""
import argparse
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TUNAKIT_REPO_URL = os.environ.get("TUNAKIT_REPO_URL", "https://github.com/tunaformac/TunaKit")
IMPORT_LINE = re.compile(r"^\s*0x[0-9A-Fa-f]+\s+(\S+)(.*)\(from ([^)]+)\)\s*$")
EXPORT_LINE = re.compile(r"^\s*0x[0-9A-Fa-f]+\s+(\S+)")


class CheckError(Exception):
    pass


def version_key(version):
    return tuple(int(part) for part in re.findall(r"\d+", version))


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


# --- Extension binary -----------------------------------------------------------------------------


def bundle_executable(bundle):
    for plist_path in (
        os.path.join(bundle, "Contents", "Info.plist"),
        os.path.join(bundle, "Resources", "Info.plist"),
        os.path.join(bundle, "Versions", "Current", "Resources", "Info.plist"),
        os.path.join(bundle, "Info.plist"),
    ):
        if os.path.isfile(plist_path):
            with open(plist_path, "rb") as fh:
                name = plistlib.load(fh).get("CFBundleExecutable")
            break
    else:
        raise CheckError("Info.plist not found in %s" % bundle)
    if not name:
        return None
    for candidate in (
        os.path.join(bundle, "Contents", "MacOS", name),
        os.path.join(bundle, "Versions", "Current", name),
        os.path.join(bundle, name),
    ):
        if os.path.isfile(candidate):
            return candidate
    raise CheckError("Executable %s not found in %s" % (name, bundle))


def binary_archs(path):
    return run(["lipo", "-archs", path]).split()


def tunakit_imports(binary, arch):
    """Non-weak symbols the binary binds from TunaKit for one architecture."""
    symbols = set()
    for line in run(["dyld_info", "-arch", arch, "-imports", binary]).splitlines():
        match = IMPORT_LINE.match(line)
        if match and match.group(3) == "TunaKit" and "[weak-import]" not in match.group(2):
            symbols.add(match.group(1))
    return symbols


def read_symbol_file(path):
    with open(path, encoding="utf-8") as fh:
        return {line.strip() for line in fh if line.strip() and not line.startswith("#")}


# --- TunaKit releases -----------------------------------------------------------------------------


class TunaKitReleases:
    def __init__(self, cache_dir):
        self.cache_dir = cache_dir
        self.repo = os.path.join(cache_dir, "TunaKit.git")

    def _git(self, *args):
        return run(["git", "--git-dir", self.repo, *args])

    def _ensure_repo(self, tag=None):
        if not os.path.isdir(self.repo):
            os.makedirs(self.cache_dir, exist_ok=True)
            run(["git", "clone", "--quiet", "--bare", TUNAKIT_REPO_URL, self.repo])
        elif tag and not self._has_tag(tag):
            self._git("fetch", "--quiet", "--tags", "--force", "origin")

    def _has_tag(self, tag):
        return subprocess.run(
            ["git", "--git-dir", self.repo, "rev-parse", "--verify", "--quiet", "refs/tags/" + tag],
            capture_output=True,
        ).returncode == 0

    def known_versions(self):
        """Versions with cached exports, plus every tag of a cached clone (no network)."""
        versions = set()
        if os.path.isdir(self.cache_dir):
            versions.update(
                name for name in os.listdir(self.cache_dir)
                if re.fullmatch(r"\d+(\.\d+)*", name)
            )
        if os.path.isdir(self.repo):
            versions.update(
                tag[1:] for tag in self._git("tag", "--list", "v*").split()
                if re.fullmatch(r"v\d+(\.\d+)*", tag)
            )
        return sorted(versions, key=version_key)

    def exports(self, version, arch):
        path = os.path.join(self.cache_dir, version, arch + ".exports")
        if not os.path.isfile(path):
            self._download(version)
        if not os.path.isfile(path):
            raise CheckError("TunaKit %s has no %s slice" % (version, arch))
        return read_symbol_file(path)

    def _download(self, version):
        tag = "v" + version
        try:
            self._ensure_repo(tag)
            manifest = self._git("show", tag + ":Package.swift")
        except subprocess.CalledProcessError as error:
            raise CheckError(
                "Could not read TunaKit %s's Package.swift from %s (%s)"
                % (version, TUNAKIT_REPO_URL, (error.stderr or "").strip() or "git failed")
            )
        url = re.search(r'url:\s*"([^"]+)"', manifest)
        checksum = re.search(r'checksum:\s*"([0-9a-f]{64})"', manifest)
        if not url or not checksum:
            raise CheckError("TunaKit %s's Package.swift has no binary target url/checksum" % version)

        with tempfile.TemporaryDirectory(dir=self.cache_dir) as work:
            archive = os.path.join(work, "TunaKit.xcframework.zip")
            try:
                run(["curl", "--fail", "--silent", "--show-error", "--location",
                     "--output", archive, url.group(1)])
            except subprocess.CalledProcessError as error:
                raise CheckError("Could not download %s (%s)" % (url.group(1), error.stderr.strip()))
            with open(archive, "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
            if digest != checksum.group(1):
                raise CheckError(
                    "TunaKit %s download checksum %s does not match Package.swift's %s"
                    % (version, digest, checksum.group(1))
                )
            extracted = os.path.join(work, "x")
            run(["ditto", "-x", "-k", archive, extracted])
            binary = self._framework_binary(extracted, version)
            staged = os.path.join(work, "exports")
            os.makedirs(staged)
            for arch in binary_archs(binary):
                symbols = []
                for line in run(["dyld_info", "-arch", arch, "-exports", binary]).splitlines():
                    match = EXPORT_LINE.match(line)
                    if match:
                        symbols.append(match.group(1))
                with open(os.path.join(staged, arch + ".exports"), "w", encoding="utf-8") as fh:
                    fh.write("".join(symbol + "\n" for symbol in sorted(set(symbols))))
            destination = os.path.join(self.cache_dir, version)
            shutil.rmtree(destination, ignore_errors=True)
            os.replace(staged, destination)

    @staticmethod
    def _framework_binary(extracted, version):
        for root, _, files in os.walk(extracted):
            if "macos" in root and root.endswith("TunaKit.framework") and "TunaKit" in files:
                return os.path.realpath(os.path.join(root, "TunaKit"))
        raise CheckError("No macOS TunaKit.framework binary in TunaKit %s's xcframework" % version)


# --- Tuna ↔ TunaKit -------------------------------------------------------------------------------


def read_tuna_versions(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip() and not line.startswith("#"):
                tuna, tunakit = line.split()
                rows.append((tuna, tunakit))
    return sorted(rows, key=lambda row: version_key(row[0]))


def first_tuna_shipping(rows, tunakit):
    for tuna, shipped in rows:
        if version_key(shipped) >= version_key(tunakit):
            return tuna
    return None


def check_tuna_floor(rows, min_tuna, min_tunakit, table_path):
    shipped = [tunakit for tuna, tunakit in rows if version_key(tuna) <= version_key(min_tuna)]
    if not shipped:
        return ["Tuna %s predates every row of %s." % (min_tuna, table_path)]
    bundled = shipped[-1]
    if version_key(bundled) >= version_key(min_tunakit):
        return []
    first = first_tuna_shipping(rows, min_tunakit)
    if first:
        return ["Tuna %s ships TunaKit %s, older than the declared minimum TunaKit %s: "
                "raise the minimum Tuna to %s." % (min_tuna, bundled, min_tunakit, first)]
    return ["No known Tuna ships TunaKit %s: add the Tuna release that does to %s."
            % (min_tunakit, table_path)]


def demangled(symbols):
    """Pairs each symbol with its readable Swift name when swift-demangle is available."""
    try:
        output = subprocess.run(
            ["xcrun", "swift-demangle", "--simplified"],
            input="".join(symbol[1:] + "\n" if symbol.startswith("_$s") else symbol + "\n"
                          for symbol in symbols),
            capture_output=True, text=True, check=True, timeout=10,
        ).stdout.splitlines()
    except (OSError, subprocess.SubprocessError):
        output = []
    if len(output) != len(symbols):
        output = symbols
    return list(zip(symbols, output))


# --- Main -----------------------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--bundle", help="built extension bundle")
    source.add_argument("--imports-file", help="TunaKit symbols to check, one per line (tests)")
    parser.add_argument("--arch", action="append", help="architectures for --imports-file")
    parser.add_argument("--min-tuna", required=True)
    parser.add_argument("--min-tunakit", required=True)
    parser.add_argument("--label", help="name used in messages")
    parser.add_argument(
        "--cache-dir",
        default=os.environ.get("TUNAKIT_FLOOR_CACHE", os.path.join(ROOT, "build", "tunakit-floor")),
    )
    parser.add_argument(
        "--tuna-versions", default=os.path.join(ROOT, "scripts", "tuna-tunakit-versions.tsv")
    )
    args = parser.parse_args()

    for name, value in (("--min-tuna", args.min_tuna), ("--min-tunakit", args.min_tunakit)):
        if not re.fullmatch(r"\d+(\.\d+)*", value):
            parser.error("%s must be a version like 1.22.0, got %r" % (name, value))

    label = args.label or os.path.basename((args.bundle or args.imports_file).rstrip("/"))
    releases = TunaKitReleases(args.cache_dir)
    rows = read_tuna_versions(args.tuna_versions)
    problems = check_tuna_floor(rows, args.min_tuna, args.min_tunakit, args.tuna_versions)

    try:
        if args.bundle:
            binary = bundle_executable(args.bundle)
            imports = {arch: tunakit_imports(binary, arch) for arch in binary_archs(binary)} if binary else {}
        else:
            symbols = read_symbol_file(args.imports_file)
            imports = {arch: symbols for arch in (args.arch or ["arm64"])}

        missing = set()
        for arch, symbols in imports.items():
            if symbols:
                missing |= symbols - releases.exports(args.min_tunakit, arch)
    except CheckError as error:
        print("%s: TunaKit floor check could not run: %s" % (label, error), file=sys.stderr)
        for problem in problems:
            print("- " + problem, file=sys.stderr)
        return 1

    if missing:
        first = None
        for version in releases.known_versions():
            if version_key(version) <= version_key(args.min_tunakit):
                continue
            try:
                if all(missing <= releases.exports(version, arch) for arch in imports):
                    first = version
                    break
            except CheckError:
                break
        listed = "\n".join(
            "  %s  (%s)" % (symbol, name) if name not in (symbol, symbol[1:]) else "  " + symbol
            for symbol, name in demangled(sorted(missing))
        )
        if first:
            tuna = first_tuna_shipping(rows, first)
            fix = "First TunaKit with them: %s%s; raise the minimum to that." % (
                first, " (Tuna %s)" % tuna if tuna else "")
        else:
            fix = "Raise the minimum TunaKit to the version this build was compiled against."
        problems.insert(0, "Uses %d TunaKit symbol(s) missing from its minimum TunaKit %s:\n%s\n%s"
                        % (len(missing), args.min_tunakit, listed, fix))

    if problems:
        print("%s: declared minimum Tuna %s / TunaKit %s is too low." %
              (label, args.min_tuna, args.min_tunakit), file=sys.stderr)
        for problem in problems:
            print("- " + problem, file=sys.stderr)
        return 1

    print("%s: TunaKit floor OK (Tuna %s / TunaKit %s)." %
          (label, args.min_tuna, args.min_tunakit), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
