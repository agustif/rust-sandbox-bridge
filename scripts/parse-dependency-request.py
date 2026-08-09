#!/usr/bin/env python3
"""Parse and validate a cargo dependency request from a GitHub issue body.

Security model:
  - Issue text is treated as untrusted data only.
  - Never exec/eval/source issue content.
  - Never pass crate names/versions through a shell without quoting as data.
  - crates.io only; no git/path/registry URLs in schema v1.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MAX_ROOT_DEPS = 40
MAX_BODY_BYTES = 64 * 1024
MAX_FEATURES_PER_CRATE = 64
MAX_NAME_LEN = 64
MAX_FEATURE_LEN = 64
MAX_VERSION_LEN = 64
MAX_ALIAS_LEN = 64

# crates.io package names: alphanumeric, -, _
CRATE_NAME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_-]{0,63}$")
# Cargo feature names are identifiers (allow - and _)
FEATURE_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
# Practical Cargo version requirement (single or comma-separated)
VERSION_SIMPLE_RE = re.compile(
    r"^(?:"
    r"\*|"
    r"(?:[=^~]|>=|<=|>|<)?\s*"
    r"[0-9]+(?:\.[0-9x*]+)?(?:\.[0-9x*]+)?(?:[-+][A-Za-z0-9._-]+)?"
    r"(?:\s*,\s*(?:[=^~]|>=|<=|>|<)?\s*"
    r"[0-9]+(?:\.[0-9x*]+)?(?:\.[0-9x*]+)?(?:[-+][A-Za-z0-9._-]+)?)*"
    r")$"
)

JSON_FENCE_RE = re.compile(
    r"```(?:json)?\s*\n(.*?)\n```",
    re.DOTALL | re.IGNORECASE,
)

FORBIDDEN_KEYS = {
    "git",
    "path",
    "registry",
    "registry-index",
    "base",
    "workspace",
}


class RequestError(Exception):
    pass


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def extract_json_blob(text: str) -> dict[str, Any]:
    if len(text.encode("utf-8")) > MAX_BODY_BYTES:
        raise RequestError(f"issue body exceeds {MAX_BODY_BYTES} bytes")

    # Prefer fenced ```json block
    matches = JSON_FENCE_RE.findall(text)
    candidates: list[str] = []
    if matches:
        candidates.extend(matches)
    # Also try whole body as JSON
    stripped = text.strip()
    if stripped.startswith("{"):
        candidates.append(stripped)

    last_err: Exception | None = None
    for blob in candidates:
        try:
            data = json.loads(blob)
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError as e:
            last_err = e
            continue

    if last_err:
        raise RequestError(f"failed to parse JSON: {last_err}")
    raise RequestError(
        "no valid JSON object found; put a fenced ```json block in the issue body"
    )


def validate_crate_name(name: str, field: str) -> str:
    if not isinstance(name, str) or not CRATE_NAME_RE.match(name):
        raise RequestError(f"invalid crate name in {field}: {name!r}")
    if name.lower() in {"null", "true", "false"}:
        raise RequestError(f"reserved crate name in {field}: {name!r}")
    return name


def validate_version(version: str, field: str) -> str:
    if not isinstance(version, str) or not version.strip():
        raise RequestError(f"missing/invalid version in {field}")
    version = version.strip()
    if len(version) > MAX_VERSION_LEN:
        raise RequestError(f"version too long in {field}")
    # Reject URLs/paths (crates.io version reqs only)
    if any(x in version for x in ("://", "git@", "..", "/", "\\")):
        raise RequestError(f"version must not be a URL/path in {field}: {version!r}")
    normalized = re.sub(r"\s*,\s*", ",", version)
    normalized = re.sub(r"\s+", "", normalized)
    if not VERSION_SIMPLE_RE.match(normalized):
        raise RequestError(f"unsupported version requirement in {field}: {version!r}")
    return version


def validate_features(features: Any, field: str) -> list[str]:
    if features is None:
        return []
    if not isinstance(features, list):
        raise RequestError(f"features must be a list in {field}")
    if len(features) > MAX_FEATURES_PER_CRATE:
        raise RequestError(f"too many features in {field} (max {MAX_FEATURES_PER_CRATE})")
    out: list[str] = []
    for f in features:
        if not isinstance(f, str) or not FEATURE_RE.match(f):
            raise RequestError(f"invalid feature name in {field}: {f!r}")
        out.append(f)
    return out


def normalize_dep(key: str, value: Any, section: str) -> tuple[str, dict[str, Any]]:
    """Return (toml_key, cargo_dep_table_or_string)."""
    validate_crate_name(key, f"{section}.{key}")

    if isinstance(value, str):
        version = validate_version(value, f"{section}.{key}")
        return key, {"version": version}

    if not isinstance(value, dict):
        raise RequestError(f"{section}.{key} must be a string or object")

    for bad in FORBIDDEN_KEYS:
        if bad in value:
            raise RequestError(
                f"{section}.{key} must not use {bad!r} (crates.io only in schema v1)"
            )

    # Optional package rename: cargo key is alias, package is real crate name
    package = value.get("package")
    if package is not None:
        package = validate_crate_name(package, f"{section}.{key}.package")

    if "version" not in value:
        raise RequestError(f"{section}.{key} requires a version field")
    version = validate_version(value["version"], f"{section}.{key}.version")

    dep: dict[str, Any] = {"version": version}
    features = validate_features(value.get("features"), f"{section}.{key}.features")
    if features:
        dep["features"] = features

    if "default-features" in value:
        df = value["default-features"]
        if not isinstance(df, bool):
            raise RequestError(f"{section}.{key}.default-features must be boolean")
        dep["default-features"] = df
    # also accept snake_case default_features
    if "default_features" in value:
        df = value["default_features"]
        if not isinstance(df, bool):
            raise RequestError(f"{section}.{key}.default_features must be boolean")
        dep["default-features"] = df

    if "optional" in value:
        opt = value["optional"]
        if not isinstance(opt, bool):
            raise RequestError(f"{section}.{key}.optional must be boolean")
        dep["optional"] = opt

    if package is not None:
        dep["package"] = package

    # Reject unknown keys to keep surface small
    allowed = {
        "version",
        "features",
        "default-features",
        "default_features",
        "optional",
        "package",
    }
    unknown = set(value.keys()) - allowed
    if unknown:
        raise RequestError(f"{section}.{key} has unsupported keys: {sorted(unknown)}")

    return key, dep


def normalize_dep_map(raw: Any, section: str) -> dict[str, dict[str, Any]]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise RequestError(f"{section} must be an object")
    out: dict[str, dict[str, Any]] = {}
    for k, v in raw.items():
        if not isinstance(k, str):
            raise RequestError(f"{section} keys must be strings")
        name, dep = normalize_dep(k, v, section)
        out[name] = dep
    return out


def validate_request(data: dict[str, Any], rust_version_file: str | None) -> dict[str, Any]:
    schema = data.get("schema", SCHEMA_VERSION)
    if schema != SCHEMA_VERSION:
        raise RequestError(f"unsupported schema version: {schema!r} (want {SCHEMA_VERSION})")

    name = data.get("name", "dependency-request")
    if not isinstance(name, str) or not re.match(r"^[a-zA-Z0-9._-]{1,64}$", name):
        raise RequestError("name must match [a-zA-Z0-9._-]{1,64}")

    rust_version = data.get("rust_version", "same-as-rust-version.txt")
    if not isinstance(rust_version, str):
        raise RequestError("rust_version must be a string")
    if rust_version in ("same-as-rust-version.txt", "from-repo", "auto"):
        if not rust_version_file:
            raise RequestError("rust_version_file required to resolve same-as-rust-version.txt")
        rust_version = Path(rust_version_file).read_text(encoding="utf-8").strip()
    if not re.match(r"^\d+\.\d+\.\d+(-[\w.]+)?$", rust_version):
        raise RequestError(f"invalid rust_version: {rust_version!r}")

    deps = normalize_dep_map(data.get("dependencies"), "dependencies")
    dev = normalize_dep_map(data.get("dev_dependencies") or data.get("dev-dependencies"), "dev_dependencies")
    build = normalize_dep_map(
        data.get("build_dependencies") or data.get("build-dependencies"),
        "build_dependencies",
    )

    total = len(deps) + len(dev) + len(build)
    if total == 0:
        raise RequestError("at least one dependency is required")
    if total > MAX_ROOT_DEPS:
        raise RequestError(f"too many root dependencies ({total} > {MAX_ROOT_DEPS})")

    # Reject empty package names and enforce no local/git leftovers in raw
    for section_name, section in (
        ("dependencies", data.get("dependencies") or {}),
        ("dev_dependencies", data.get("dev_dependencies") or data.get("dev-dependencies") or {}),
        ("build_dependencies", data.get("build_dependencies") or data.get("build-dependencies") or {}),
    ):
        if not isinstance(section, dict):
            continue
        for k, v in section.items():
            if isinstance(v, dict):
                for bad in FORBIDDEN_KEYS:
                    if bad in v:
                        raise RequestError(f"{section_name}.{k} forbids {bad}")

    return {
        "schema": SCHEMA_VERSION,
        "name": name,
        "rust_version": rust_version,
        "dependencies": deps,
        "dev_dependencies": dev,
        "build_dependencies": build,
    }


def toml_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def dep_to_toml(name: str, dep: dict[str, Any]) -> str:
    # Always emit table form for consistency
    parts = [f'version = "{toml_escape(dep["version"])}"']
    if "package" in dep:
        parts.append(f'package = "{toml_escape(dep["package"])}"')
    if "default-features" in dep:
        parts.append(f'default-features = {"true" if dep["default-features"] else "false"}')
    if "optional" in dep:
        parts.append(f'optional = {"true" if dep["optional"] else "false"}')
    if dep.get("features"):
        feats = ", ".join(f'"{toml_escape(f)}"' for f in dep["features"])
        parts.append(f"features = [{feats}]")
    inner = ", ".join(parts)
    return f'{name} = {{ {inner} }}'


def write_cargo_toml(request: dict[str, Any], path: Path) -> None:
    lines = [
        "[package]",
        f'name = "{toml_escape(request["name"])}"',
        'version = "0.1.0"',
        'edition = "2021"',
        "publish = false",
        "",
    ]
    if request["dependencies"]:
        lines.append("[dependencies]")
        for name, dep in sorted(request["dependencies"].items()):
            lines.append(dep_to_toml(name, dep))
        lines.append("")
    if request["dev_dependencies"]:
        lines.append("[dev-dependencies]")
        for name, dep in sorted(request["dev_dependencies"].items()):
            lines.append(dep_to_toml(name, dep))
        lines.append("")
    if request["build_dependencies"]:
        lines.append("[build-dependencies]")
        for name, dep in sorted(request["build_dependencies"].items()):
            lines.append(dep_to_toml(name, dep))
        lines.append("")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_smoke_main(request: dict[str, Any], path: Path) -> None:
    """Generate a main.rs that references at least one non-optional dependency."""
    deps = request["dependencies"]
    usable = [
        (name, dep)
        for name, dep in deps.items()
        if not dep.get("optional", False)
    ]
    lines = ["// Auto-generated smoke test — references requested crates.", ""]
    if not usable:
        lines.extend(
            [
                "fn main() {",
                '    println!("vendor smoke: no non-optional deps to reference");',
                "}",
            ]
        )
    else:
        # Reference crates via extern crate style is unnecessary on 2018+;
        # use a simple type/path that forces linking for common crates.
        # We only need cargo to resolve/build the graph; a trivial use is enough
        # when the crate exports something at the root. Fall back to `use crate as _`.
        for name, dep in usable[:8]:
            crate = dep.get("package", name).replace("-", "_")
            alias = name.replace("-", "_")
            lines.append(f"use {crate} as _{alias};")
        lines.append("")
        lines.append("fn main() {")
        lines.append('    println!("vendor smoke ok");')
        # Force the uses to not be dead-code optimized away in some edge cases
        lines.append("    let _ = std::mem::size_of::<usize>();")
        lines.append("}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "input",
        nargs="?",
        help="Path to issue body text (default: stdin)",
    )
    parser.add_argument(
        "--rust-version-file",
        default="rust-version.txt",
        help="Path to rust-version.txt for same-as-rust-version.txt resolution",
    )
    parser.add_argument(
        "--out-request",
        required=True,
        help="Write normalized request JSON here",
    )
    parser.add_argument(
        "--out-cargo-toml",
        help="Write generated Cargo.toml here",
    )
    parser.add_argument(
        "--out-main",
        help="Write generated smoke-test src/main.rs here",
    )
    parser.add_argument(
        "--print-rust-version",
        action="store_true",
        help="Print resolved rust_version to stdout",
    )
    args = parser.parse_args()

    if args.input:
        text = Path(args.input).read_text(encoding="utf-8")
    else:
        text = sys.stdin.read()

    try:
        raw = extract_json_blob(text)
        request = validate_request(raw, args.rust_version_file)
    except RequestError as e:
        die(str(e))

    out_req = Path(args.out_request)
    out_req.parent.mkdir(parents=True, exist_ok=True)
    out_req.write_text(json.dumps(request, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.out_cargo_toml:
        write_cargo_toml(request, Path(args.out_cargo_toml))
    if args.out_main:
        write_smoke_main(request, Path(args.out_main))

    if args.print_rust_version:
        print(request["rust_version"])
    else:
        print(f"ok: wrote normalized request to {out_req}")
        print(f"  name={request['name']} rust_version={request['rust_version']}")
        print(
            f"  deps={len(request['dependencies'])} "
            f"dev={len(request['dev_dependencies'])} "
            f"build={len(request['build_dependencies'])}"
        )


if __name__ == "__main__":
    main()
