#!/usr/bin/env python3
"""Writes modules/jemalloc/<version>/ into a Bazel Central Registry checkout from a committed fork ref.

The entry fetches upstream's release tarball. Every committed file the tarball lacks ships in overlay/, except the
fork's own tooling listed in .bcr/fork_only.txt, and every committed edit to an upstream file ships as a patch in
patches/. The entry is written only if the tarball, then the overlay, then the patches, as Bazel applies them, rebuild
the fork byte for byte.

usage: export_bcr_entry.py --registry BCR_DIR [--ref REF] [--tarball PATH] [--replace]
"""

import argparse
import base64
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

MODULE_NAME = "jemalloc"
UPSTREAM_URL = "https://github.com/jemalloc/jemalloc/releases/download/{upstream}/jemalloc-{upstream}.tar.bz2"
FORK_ONLY = ".bcr/fork_only.txt"
PRESUBMIT = ".bcr/presubmit.yml"


class ExportError(Exception):
    pass


def integrity(data):
    return "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()


def version_key(version):
    """Bazel's module version order, as tools/registry.py's Version implements it for metadata.json."""
    match = re.fullmatch(r"([a-zA-Z0-9.]+)(?:-([a-zA-Z0-9.-]+))?(?:\+[a-zA-Z0-9.-]+)?", version)
    if not match:
        raise ExportError(f"{version!r} is not a valid module version")

    def identifiers(part):
        if "" in part.split("."):
            raise ExportError(f"{version!r} has an empty identifier")
        return [(0, int(i), "") if i.isnumeric() else (1, 0, i) for i in part.split(".")]

    release, prerelease = match.groups()
    return identifiers(release), (1, []) if prerelease is None else (0, identifiers(prerelease))


def read_fork(repo, ref):
    """Returns {path: (mode, bytes)} for every file committed at ref.

    git ls-tree rather than git archive: .gitattributes export-ignore would hide .bcr/ and .github/ from the archive,
    and they must be classified like every other file.
    """
    listing = subprocess.run(
        ["git", "-C", repo, "ls-tree", "-r", "-z", "--full-tree", ref], check=True, capture_output=True
    ).stdout
    entries = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, kind, sha = meta.decode().split()
        if kind != "blob":
            raise ExportError(f"{path.decode()}: {kind} entries are not supported")
        entries.append((path.decode(), mode, sha))

    batch = subprocess.run(
        ["git", "-C", repo, "cat-file", "--batch"],
        input="".join(sha + "\n" for _, _, sha in entries).encode(),
        check=True,
        capture_output=True,
    ).stdout
    files = {}
    offset = 0
    for path, mode, sha in entries:
        header_end = batch.index(b"\n", offset)
        header_sha, _, size = batch[offset:header_end].decode().split()
        if header_sha != sha:
            raise ExportError(f"git cat-file returned {header_sha} for {path} ({sha})")
        start = header_end + 1
        files[path] = (mode, batch[start : start + int(size)])
        offset = start + int(size) + 1
    return files


def read_tarball(data, strip_prefix):
    """Returns ({path: bytes}, {path: mode}) for the regular files under strip_prefix/ in a tarball, each mode as git
    records it: 100755 if the owner may execute the file, else 100644."""
    files, modes = {}, {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile():
                raise ExportError(f"tarball: {member.name} is not a regular file")
            prefix, _, path = member.name.partition("/")
            # Every component must be a plain name, so no path can leave the tree it is written into.
            if prefix != strip_prefix or any(part in ("", ".", "..") for part in path.split("/")):
                raise ExportError(f"tarball: {member.name} is not a plain path under {strip_prefix}/")
            files[path] = archive.extractfile(member).read()
            modes[path] = "100755" if member.mode & 0o100 else "100644"
    return files, modes


def module_attribute(module_bazel, attribute):
    match = re.search(r"^module\((.*?)^\)", module_bazel, re.M | re.S)
    value = match and re.search(rf'^\s*{attribute}\s*=\s*"([^"]*)"', match.group(1), re.M)
    if not value:
        raise ExportError(f"MODULE.bazel: no module({attribute} = ...)")
    return value.group(1)


def load_fork_only(fork):
    """Reads FORK_ONLY: one path per line, a trailing / for a whole directory, # for comments."""
    if FORK_ONLY not in fork:
        raise ExportError(f"{FORK_ONLY} is not committed")
    entries = []
    for line in fork[FORK_ONLY][1].decode().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.append(line)
    if entries != sorted(set(entries)):
        raise ExportError(f"{FORK_ONLY}: entries must be sorted and free of duplicates")
    return entries


def classify(fork, upstream, upstream_modes, fork_only):
    """Splits the fork into overlay files and fork-only files; the overlay is everything upstream lacks.

    Returns (overlay, kept_upstream): the overlay paths, and the upstream files the fork changes for its own use, which
    the registry serves as upstream ships them.
    """

    def covers(entry, path):
        return path.startswith(entry) if entry.endswith("/") else path == entry

    def excluded(path):
        return any(covers(entry, path) for entry in fork_only)

    errors = []
    for entry in fork_only:
        matches = [path for path in fork if covers(entry, path)]
        if not matches:
            errors.append(f"{FORK_ONLY}: {entry} matches no committed file")
        for path in matches:
            # Only root dotfiles with no build effect may keep the fork's edits out of the registry; any other edit to
            # an upstream file ships as a patch, or the fork would test different code than the registry serves. An
            # unedited upstream file under a fork-only directory (5.3.1's tarball ships .github/workflows/) has no
            # edits to lose; unedited means the tarball's bytes as the same kind of file, so a symlink or a changed
            # executable bit is an edit too.
            edited = path in upstream and fork[path] != (upstream_modes[path], upstream[path])
            if edited and ("/" in path or not path.startswith(".")):
                errors.append(f"{FORK_ONLY}: {entry} covers the upstream file {path}, whose edits must ship")
    if errors:
        raise ExportError("\n  ".join(["fork-only list does not match the trees:"] + errors))

    overlay = sorted(path for path in fork if path not in upstream and not excluded(path))
    kept_upstream = sorted(path for path in fork if path in upstream and excluded(path))
    return overlay, kept_upstream


def check_overlay(fork, overlay):
    errors = []
    for path in overlay:
        mode = fork[path][0]
        if mode != "100644":
            # Bazel 7 delivers overlay files without an executable bit, so nothing in the overlay may rely on one.
            errors.append(f"{path}: mode {mode}; overlay files must be plain 100644 files")
    if errors:
        raise ExportError("overlay:\n  " + "\n  ".join(errors))


def derive_patches(fork, upstream, upstream_modes, kept_upstream):
    """One unified diff per upstream file the fork edits, named after its path, for patch_strip 1.

    A diff carries contents only, so an upstream file the fork commits as a symlink or with a changed executable bit
    stops the export rather than ship as the tarball's kind of file; kept_upstream ships as upstream's anyway.
    """
    mismatches = [
        f"{path}: committed as {fork[path][0]}, but the tarball ships it as {upstream_modes[path]}"
        for path in sorted(fork)
        if path in upstream and path not in kept_upstream and fork[path][0] != upstream_modes[path]
    ]
    if mismatches:
        raise ExportError(
            "upstream files whose kind or executable bit the fork changes, which a patch cannot carry:\n  "
            + "\n  ".join(mismatches)
        )
    patches = {}
    with tempfile.TemporaryDirectory() as temporary:
        original, edited = Path(temporary, "original"), Path(temporary, "edited")
        for path in sorted(fork):
            if path not in upstream or path in kept_upstream or fork[path][1] == upstream[path]:
                continue
            if b"\0" in fork[path][1] or b"\0" in upstream[path]:
                raise ExportError(f"{path}: edits to binary upstream files cannot ship as patches")
            original.write_bytes(upstream[path])
            edited.write_bytes(fork[path][1])
            # diff exits 1 when the files differ, which they do here; 2 is trouble.
            result = subprocess.run(
                ["diff", "-u", "--label", f"a/{path}", "--label", f"b/{path}", str(original), str(edited)],
                capture_output=True,
            )
            if result.returncode != 1:
                raise ExportError(f"{path}: diff failed:\n{result.stderr.decode()}")
            name = path.replace("/", "_") + ".patch"
            if name in patches:
                raise ExportError(f"{path}: another edited upstream file also maps to patches/{name}")
            patches[name] = result.stdout
    return patches


def write_entry(entry, fork, overlay, patches, tarball_url, tarball_integrity, strip_prefix):
    overlay_dir = entry / "overlay"
    for path in overlay:
        target = overlay_dir / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(fork[path][1])
    (entry / "MODULE.bazel").write_bytes(fork["MODULE.bazel"][1])
    (entry / "presubmit.yml").write_bytes(fork[PRESUBMIT][1])
    source = {
        "integrity": tarball_integrity,
        "overlay": {path: integrity(fork[path][1]) for path in overlay},
        "strip_prefix": strip_prefix,
        "url": tarball_url,
    }
    if patches:
        (entry / "patches").mkdir()
        for name, data in patches.items():
            (entry / "patches" / name).write_bytes(data)
        source["patch_strip"] = 1
        source["patches"] = {name: integrity(data) for name, data in patches.items()}
    (entry / "source.json").write_text(json.dumps(source, indent=4, sort_keys=True) + "\n")


def rebuild_from_entry(entry, upstream, work):
    """Rebuilds the source tree as Bazel does: tarball, then overlay files, then patches, each checked by source.json."""
    source = json.loads((entry / "source.json").read_text())
    tree = work / "tree"
    for path, data in upstream.items():
        (tree / path).parent.mkdir(parents=True, exist_ok=True)
        (tree / path).write_bytes(data)
    for path, expected in source["overlay"].items():
        data = (entry / "overlay" / path).read_bytes()
        if integrity(data) != expected:
            raise ExportError(f"entry: overlay/{path} does not match source.json")
        (tree / path).parent.mkdir(parents=True, exist_ok=True)
        (tree / path).write_bytes(data)
    for name, expected in source.get("patches", {}).items():
        patch = entry / "patches" / name
        if integrity(patch.read_bytes()) != expected:
            raise ExportError(f"entry: patches/{name} does not match source.json")
        # Bazel's own patcher applies hunks exactly: no fuzz, no whitespace leniency.
        result = subprocess.run(
            ["patch", f"-p{source['patch_strip']}", "--fuzz=0", "--batch", "--forward", "--no-backup-if-mismatch",
             "-d", str(tree), "-i", str(patch.resolve())],
            capture_output=True,
            text=True,
        )
        if result.returncode:
            raise ExportError(f"patches/{name} does not apply exactly:\n{result.stdout}{result.stderr}")
    return {str(path.relative_to(tree)): path.read_bytes() for path in tree.rglob("*") if path.is_file()}


def expected_tree(fork, upstream, overlay, kept_upstream):
    """What consumers get: the tarball, the overlay, and every fork edit to an upstream file except kept_upstream's."""
    tree = dict(upstream)
    for path in overlay:
        tree[path] = fork[path][1]
    for path, (_, data) in fork.items():
        if path in upstream and path not in kept_upstream:
            tree[path] = data
    return tree


def updated_metadata(module_dir, version):
    """metadata.json's text with version added, versions sorted by Bazel's module version order."""
    metadata = json.loads((module_dir / "metadata.json").read_text())
    metadata["versions"] = sorted(set(metadata["versions"]) | {version}, key=version_key)
    return json.dumps(metadata, indent=4) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--registry", required=True, type=Path, help="Bazel Central Registry checkout to write into")
    parser.add_argument("--ref", default="HEAD", help="fork commit to export (default: HEAD)")
    parser.add_argument(
        "--tarball",
        type=Path,
        help="local copy of the upstream tarball instead of downloading it; source.json still names the upstream URL, "
        "and bcr_validation.py re-downloads it and checks the integrity",
    )
    parser.add_argument("--replace", action="store_true", help="delete and rewrite an existing entry")
    args = parser.parse_args()

    repo = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True,
        cwd=Path(__file__).resolve().parent,
    ).stdout.strip()
    commit = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--verify", args.ref + "^{commit}"], check=True, capture_output=True,
        text=True,
    ).stdout.strip()
    fork = read_fork(repo, commit)

    module_bazel = fork["MODULE.bazel"][1].decode()
    if module_attribute(module_bazel, "name") != MODULE_NAME:
        raise ExportError(f"MODULE.bazel: module name is not {MODULE_NAME}")
    version = module_attribute(module_bazel, "version")
    match = re.fullmatch(r"(\d+\.\d+\.\d+)(?:\.bcr\.\d+)?", version)
    if not match:
        raise ExportError(f"MODULE.bazel: version {version} is neither <upstream> nor <upstream>.bcr.<N>")
    upstream_version = match.group(1)
    if not fork["VERSION"][1].decode().startswith(upstream_version + "-"):
        raise ExportError(f"VERSION does not describe upstream {upstream_version}")

    fork_only = load_fork_only(fork)

    url = UPSTREAM_URL.format(upstream=upstream_version)
    if args.tarball:
        tarball = args.tarball.read_bytes()
    else:
        print(f"Downloading {url}", file=sys.stderr)
        with urllib.request.urlopen(url) as response:
            tarball = response.read()
    strip_prefix = f"jemalloc-{upstream_version}"
    upstream, upstream_modes = read_tarball(tarball, strip_prefix)

    overlay, kept_upstream = classify(fork, upstream, upstream_modes, fork_only)
    if "MODULE.bazel" not in overlay:
        raise ExportError("MODULE.bazel is not in the overlay")
    check_overlay(fork, overlay)
    patches = derive_patches(fork, upstream, upstream_modes, kept_upstream)

    module_dir = args.registry / "modules" / MODULE_NAME
    if not (module_dir / "metadata.json").is_file():
        raise ExportError(f"{module_dir}/metadata.json does not exist; is {args.registry} a registry checkout?")
    entry = module_dir / version
    if entry.exists() and not args.replace:
        raise ExportError(f"{entry} exists; pass --replace to rewrite it")
    # Computed before anything is written, so a malformed metadata.json stops the export with the registry untouched.
    metadata = updated_metadata(module_dir, version)

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        staged = work / "entry"
        staged.mkdir()
        write_entry(staged, fork, overlay, patches, url, integrity(tarball), strip_prefix)

        rebuilt = rebuild_from_entry(staged, upstream, work)
        expected = expected_tree(fork, upstream, overlay, kept_upstream)
        differences = sorted(
            [f"missing from the entry: {path}" for path in expected.keys() - rebuilt.keys()]
            + [f"not in the fork: {path}" for path in rebuilt.keys() - expected.keys()]
            + [f"differs from the fork: {path}" for path in expected.keys() & rebuilt.keys()
               if expected[path] != rebuilt[path]]
        )
        if differences:
            raise ExportError("the entry does not rebuild the fork:\n  " + "\n  ".join(differences))
        if (staged / "MODULE.bazel").read_bytes() != (staged / "overlay" / "MODULE.bazel").read_bytes():
            raise ExportError("entry: MODULE.bazel differs from overlay/MODULE.bazel")

        # Copy beside the entry, then swap by rename, so a failed copy leaves any existing entry in place.
        incoming = module_dir / f".{version}.incoming"
        outgoing = module_dir / f".{version}.outgoing"
        for leftover in (incoming, outgoing):
            if leftover.exists():
                shutil.rmtree(leftover)
        shutil.copytree(staged, incoming)
        if entry.exists():
            entry.rename(outgoing)
        incoming.rename(entry)
        if outgoing.exists():
            shutil.rmtree(outgoing)
    metadata_path = module_dir / "metadata.json"
    metadata_temporary = module_dir / ".metadata.json.incoming"
    metadata_temporary.write_text(metadata)
    metadata_temporary.replace(metadata_path)

    print(f"Wrote {entry} from {commit} ({len(overlay)} overlay files, {len(patches)} patches)")


if __name__ == "__main__":
    try:
        main()
    except ExportError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
