#!/usr/bin/env python3
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile


def openssl_binary() -> str:
    configured = os.environ.get("OPENSSL", "").strip()
    if configured:
        return configured

    preferred = [
        "/opt/homebrew/opt/openssl@3/bin/openssl",
        "/opt/homebrew/bin/openssl",
        "/usr/local/opt/openssl@3/bin/openssl",
        "/usr/local/bin/openssl",
    ]
    for path in preferred:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path

    resolved = shutil.which("openssl")
    if resolved:
        return resolved

    return "/usr/bin/openssl"


def find_info_plist(bundle_path: str) -> str:
    candidates = [
        os.path.join(bundle_path, "Info.plist"),
        os.path.join(bundle_path, "Resources", "Info.plist"),
        os.path.join(bundle_path, "Versions", "A", "Resources", "Info.plist"),
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path

    for root, dirs, files in os.walk(bundle_path):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name == "Info.plist":
                return os.path.join(root, name)
    raise RuntimeError("Info.plist not found in bundle")


def symlink_stays_within_bundle(bundle_root: str, path: str) -> bool:
    resolved = os.path.realpath(path)
    try:
        common_root = os.path.commonpath((bundle_root, resolved))
    except ValueError:
        return False
    return resolved != bundle_root and common_root == bundle_root


def ensure_safe_symlinks(bundle_path: str) -> None:
    bundle_root = os.path.realpath(bundle_path)
    for root, dirs, files in os.walk(bundle_path):
        for name in dirs + files:
            full = os.path.join(root, name)
            if os.path.islink(full) and not symlink_stays_within_bundle(bundle_root, full):
                raise RuntimeError("Symlink escapes bundle: %s" % full)


def compute_payload_hash(bundle_path: str) -> str:
    bundle_root = os.path.realpath(bundle_path)
    entries = []
    for root, dirs, files in os.walk(bundle_path):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.startswith("."):
                continue
            full = os.path.join(root, name)
            if os.path.islink(full):
                if not symlink_stays_within_bundle(bundle_root, full):
                    raise RuntimeError("Symlink escapes bundle: %s" % full)
                continue
            if not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, bundle_path)
            entries.append((rel, full))

    entries.sort(key=lambda x: x[0])
    h = hashlib.sha256()
    for rel, full in entries:
        h.update(rel.encode("utf-8"))
        h.update(b"\x00")
        with open(full, "rb") as fh:
            while True:
                chunk = fh.read(1024 * 1024)
                if not chunk:
                    break
                h.update(chunk)
        h.update(b"\x00")
    return h.hexdigest()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def sign_payload(signing_key: str, payload: bytes) -> bytes:
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp.write(payload)
        tmp_path = tmp.name
    try:
        result = subprocess.run(
            [openssl_binary(), "pkeyutl", "-sign", "-inkey", signing_key, "-rawin", "-in", tmp_path],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result.stdout
    finally:
        os.unlink(tmp_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Package a Tuna extension/theme into .tunaextension")
    parser.add_argument("--bundle", required=True, help="Path to .framework or .bundle")
    parser.add_argument("--out", default="dist/store", help="Output directory")
    parser.add_argument("--declaration-json", default="")
    parser.add_argument("--min-tuna", default="")
    parser.add_argument("--min-tunakit", default="")
    parser.add_argument("--min-macos", default="")
    parser.add_argument("--arch", action="append", default=[])
    parser.add_argument("--signing-key", default="")
    parser.add_argument("--key-id", default="dev-key")
    parser.add_argument("--summary", default="")
    parser.add_argument("--description", default="")
    parser.add_argument("--name", default="")
    parser.add_argument("--developer", default="")
    parser.add_argument("--category", action="append", default=[])
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument("--warning", action="append", default=[])
    return parser.parse_args()


def normalize_arches(raw_values: list[str]) -> list[str]:
    values = []
    seen = set()

    for raw in raw_values:
        for part in str(raw).split(","):
            arch = part.strip()
            if not arch or arch in seen:
                continue
            seen.add(arch)
            values.append(arch)

    return values


def load_declaration_json(value: str) -> dict:
    if not value:
        return {}

    source = value.strip()
    if os.path.isfile(source):
        with open(source, encoding="utf-8") as fh:
            return json.load(fh)

    return json.loads(source)


def parse_numeric_version(value: str) -> tuple[int, ...]:
    cleaned = str(value).strip()
    if not cleaned:
        raise ValueError("empty version")
    parts: list[int] = []
    for token in cleaned.split("."):
        token = token.strip()
        if not token:
            continue
        if not token.isdigit():
            raise ValueError(f"non-numeric token: {token}")
        parts.append(int(token))
    if not parts:
        raise ValueError("no numeric version parts")
    return tuple(parts)


def compare_versions(lhs: str, rhs: str) -> int:
    lhs_parts = parse_numeric_version(lhs)
    rhs_parts = parse_numeric_version(rhs)
    width = max(len(lhs_parts), len(rhs_parts))
    lhs_padded = lhs_parts + (0,) * (width - len(lhs_parts))
    rhs_padded = rhs_parts + (0,) * (width - len(rhs_parts))
    if lhs_padded < rhs_padded:
        return -1
    if lhs_padded > rhs_padded:
        return 1
    return 0


def utc_now_iso8601() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def resolve_min_macos(requested: str, bundle_min_macos: str) -> str:
    value = requested.strip() if requested else ""
    if value:
        return value
    if bundle_min_macos:
        return bundle_min_macos
    return "15.0"


def detect_bundle_arches(bundle_path: str, executable_name: str) -> list[str]:
    if not executable_name:
        return []

    candidates = [
        os.path.join(bundle_path, executable_name),
        os.path.join(bundle_path, "MacOS", executable_name),
        os.path.join(bundle_path, "Versions", "A", executable_name),
        os.path.join(bundle_path, "Versions", "Current", executable_name),
    ]

    for candidate in candidates:
        if not os.path.isfile(candidate):
            continue
        try:
            result = subprocess.run(
                ["/usr/bin/lipo", "-archs", candidate],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
        arches = normalize_arches(result.stdout.split())
        if arches:
            return arches

    return []


def main() -> int:
    args = parse_args()
    bundle_path = os.path.abspath(args.bundle)
    if not os.path.isdir(bundle_path):
        print("Bundle not found: %s" % bundle_path, file=sys.stderr)
        return 1

    info_path = find_info_plist(bundle_path)
    with open(info_path, "rb") as fh:
        info = plistlib.load(fh)

    bundle_id = info.get("CFBundleIdentifier") or ""
    bundle_name = info.get("CFBundleName") or ""
    executable_name = info.get("CFBundleExecutable") or ""
    version = info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "1.0"
    bundle_min_macos = (
        str(info.get("LSMinimumSystemVersion") or info.get("MinimumOSVersion") or "").strip()
    )
    if not bundle_id or not bundle_name:
        print("Missing CFBundleIdentifier or CFBundleName", file=sys.stderr)
        return 1

    min_macos = resolve_min_macos(args.min_macos, bundle_min_macos)

    if bundle_min_macos:
        try:
            if compare_versions(min_macos, bundle_min_macos) < 0:
                print(
                    "min_macos %s is lower than bundle minimum %s"
                    % (min_macos, bundle_min_macos),
                    file=sys.stderr,
                )
                return 1
        except ValueError as error:
            print("Invalid min_macos value: %s" % error, file=sys.stderr)
            return 1

    arches = normalize_arches(args.arch)
    if not arches:
        arches = detect_bundle_arches(bundle_path, executable_name)
    if not arches:
        arches = ["arm64"]

    declaration = load_declaration_json(args.declaration_json)
    manifest_type = ""
    metadata = {}
    if declaration:
        manifest_type = "extension"
        metadata = declaration
    elif "TKTheme" in info:
        manifest_type = "theme"
        metadata = info.get("TKTheme", {})
    else:
        print("Bundle does not define declaration JSON or TKTheme", file=sys.stderr)
        return 1

    name = args.name or metadata.get("Name") or metadata.get("name") or bundle_name
    developer = args.developer or metadata.get("Author") or metadata.get("author") or "Unknown"
    description = args.description or metadata.get("Description") or metadata.get("description") or ""
    if args.summary:
        summary = args.summary
    elif description:
        summary = description.splitlines()[0]
    else:
        summary = ""
    # Extensions no longer declare categories; store categorization is curated
    # web-side (admin or --category at packaging time).
    categories = args.category

    declaration_compatibility = declaration.get("compatibility") or {}
    min_tuna = str(args.min_tuna or declaration_compatibility.get("min_tuna") or "").strip()
    min_tunakit = str(
        args.min_tunakit or declaration_compatibility.get("min_tunakit") or ""
    ).strip()

    if manifest_type == "extension":
        if not min_tuna:
            print(
                "Extension compatibility requires min_tuna in the declaration or --min-tuna.",
                file=sys.stderr,
            )
            return 1
        if not min_tunakit:
            print(
                "Extension compatibility requires min_tunakit in the declaration or --min-tunakit.",
                file=sys.stderr,
            )
            return 1
    elif not min_tuna:
        min_tuna = "1.0"

    compatibility = {
        "min_tuna": min_tuna,
        "min_macos": min_macos,
        "arch": arches,
    }
    if min_tunakit:
        compatibility["min_tunakit"] = min_tunakit

    package_manifest = {
        "schema_version": "1",
        "id": bundle_id,
        "type": manifest_type,
        "version": version,
        "bundle_name": bundle_name,
        "compatibility": compatibility,
    }

    ensure_safe_symlinks(bundle_path)

    staging_root = tempfile.mkdtemp(prefix="tunaextension-")
    try:
        payload_dir = os.path.join(staging_root, "Payload")
        os.makedirs(payload_dir, exist_ok=True)
        bundle_dest = os.path.join(payload_dir, os.path.basename(bundle_path))
        shutil.copytree(bundle_path, bundle_dest, symlinks=True)

        ensure_safe_symlinks(bundle_dest)
        payload_hash = compute_payload_hash(bundle_dest)

        manifest_path = os.path.join(staging_root, "tunaextension.json")
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(package_manifest, fh, indent=2, sort_keys=True)
            fh.write("\n")

        checksum_path = os.path.join(staging_root, "payload.sha256")
        with open(checksum_path, "w", encoding="utf-8") as fh:
            fh.write(payload_hash)
            fh.write("\n")

        signature_summary = None
        if args.signing_key:
            with open(manifest_path, "rb") as fh:
                manifest_bytes = fh.read().rstrip(b"\n")
            payload = manifest_bytes + b"\n" + payload_hash.encode("utf-8")
            signature = sign_payload(args.signing_key, payload)
            signature_b64 = base64.b64encode(signature).decode("ascii")
            signature_doc = {
                "algorithm": "ed25519",
                "key_id": args.key_id,
                "signed_at": utc_now_iso8601(),
                "signature_base64": signature_b64,
            }
            signature_path = os.path.join(staging_root, "store-signature.json")
            with open(signature_path, "w", encoding="utf-8") as fh:
                json.dump(signature_doc, fh, indent=2, sort_keys=True)
                fh.write("\n")
            signature_summary = signature_doc

        os.makedirs(args.out, exist_ok=True)
        safe_id = bundle_id.replace("/", "_")
        package_name = f"{safe_id}-{version}.tunaextension"
        package_path = os.path.join(args.out, package_name)

        if os.path.exists(package_path):
            os.remove(package_path)

        subprocess.run(
            ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", staging_root, package_path],
            check=True,
        )

        package_checksum = sha256_file(package_path)
        package_size = os.path.getsize(package_path)

        download_url = None

        item = {
            "id": bundle_id,
            "type": manifest_type,
            "name": name,
            "summary": summary,
            "developer_name": developer,
            "icon_url": None,
            "version": version,
            "updated_at": utc_now_iso8601(),
            "categories": categories,
            "tags": args.tag,
            "warnings": args.warning,
            "compatibility": compatibility,
            "download": {
                "url": download_url,
                "size_bytes": package_size,
                "checksum_sha256": package_checksum,
                "signature": signature_summary,
            },
        }

        print(json.dumps(item, indent=2, sort_keys=True))
        return 0
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
