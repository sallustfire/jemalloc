#!/usr/bin/env python3
"""Writes modules/jemalloc/<version>/ into a Bazel Central Registry checkout from a committed fork ref.

The entry fetches upstream's release tarball. Every committed file the tarball lacks ships in overlay/, except the
fork's own tooling listed in .bcr/fork_only.txt, and every committed edit to an upstream file ships as a patch in
patches/, beside, where the fork has .bcr/tarball_removals.txt, one generated from it that deletes tarball files the
fork leaves out. Without that file the entry has no removal patch.

Every tarball file must be accounted for, since the registry serves any the entry does not delete: committed by the
fork, listed in .bcr/release_generated.txt as a file the release process generates and the fork does not commit (it
ships as the tarball has it), or listed in .bcr/tarball_removals.txt. A tarball file the fork deleted or renamed
without listing it stops the export.

The entry is written only if the tarball, then the overlay, then the patches rebuild the distribution tree the fork
defines, file for file, byte for byte and mode for mode. That tree is built from the fork's side, not from the
tarball: every upstream file the fork commits, and every overlay file, as committed, plus the tarball's copy of the
files that are deliberately not the fork's, each root dotfile kept as upstream's by .bcr/fork_only.txt and each file
listed in .bcr/release_generated.txt.

The check applies the patches with GNU patch, without fuzz, not with Bazel's patcher, so it shows what Bazel builds
only because the export restricts patches and the files they touch to what Bazel's patcher reproduces exactly: plain
ASCII paths, # description lines, UTF-8 text without CR that ends in a newline on both sides of an edit, and
deletions only of non-empty text files. A patch carries contents only, so the export also stops before writing one if
the fork commits a shipped upstream file as a symlink or with another executable bit; overlay files are plain 100644
files.

Every entry for one upstream release must fetch the same tarball, so the export stops if one already in the registry
names a different integrity than the tarball being exported.

usage: export_bcr_entry.py --registry BCR_DIR [--ref REF] [--tarball PATH] [--replace]
"""

import argparse
import base64
import hashlib
import io
import json
import os
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
RELEASE_GENERATED = ".bcr/release_generated.txt"
REMOVALS = ".bcr/tarball_removals.txt"
REMOVAL_PATCH = "tarball_removals.patch"


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
    records it: 100755 if the owner may execute the file, else 100644.

    A member name may start with ./, as tar writes for an archive of ., and names the same path without it. Every
    other name, a directory's too, must be strip_prefix or a plain path under it, so no path can leave the tree it is
    written into. Each path must name one thing: no member may appear twice, since extraction would keep only one of
    its copies, nor as both a file and a directory, and no file may sit where another member needs a directory.
    """
    files, modes, kinds = {}, {}, {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        for member in archive.getmembers():
            # tarfile drops a directory name's trailing /, so ./ reads as . here.
            name = member.name.removeprefix("./")
            if member.isdir() and name in (".", strip_prefix):
                continue
            prefix, _, path = name.partition("/")
            if prefix != strip_prefix or any(part in ("", ".", "..") for part in path.split("/")):
                raise ExportError(f"tarball: {member.name} is not a plain path under {strip_prefix}/")
            kind = "directory" if member.isdir() else "file"
            if path in kinds:
                raise ExportError(f"tarball: {path} appears more than once" if kinds[path] == kind
                                  else f"tarball: {path} appears as both a file and a directory")
            kinds[path] = kind
            if member.isdir():
                continue
            if member.issym() or member.islnk():
                raise ExportError(
                    f"tarball: {member.name} is a {'symbolic' if member.issym() else 'hard'} link to "
                    f"{member.linkname}. The exporter supports only regular files in the tarball: it checks upstream "
                    "files by their bytes and executable bit, and patches carry neither a link nor its target, so it "
                    "cannot tell what the registry would serve. Supporting links means extending read_tarball, the "
                    "fork-only check, derive_patches and the rebuild check to compare link targets."
                )
            if not member.isfile():
                raise ExportError(f"tarball: {member.name} is not a regular file")
            files[path] = archive.extractfile(member).read()
            modes[path] = "100755" if member.mode & 0o100 else "100644"
    for path in kinds:
        parts = path.split("/")
        for depth in range(1, len(parts)):
            if kinds.get("/".join(parts[:depth])) == "file":
                raise ExportError(f"tarball: {'/'.join(parts[:depth])} is a file, but {path} sits under it")
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

    Returns (overlay, kept_upstream): the overlay paths, and the upstream root files FORK_ONLY names exactly, which the
    registry serves as upstream ships them whatever the fork commits. An unedited upstream file under a fork-only
    directory is not kept: it ships as the fork commits it, which is as upstream ships it.
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
            # an upstream file ships as a patch, or the fork would test different code than the registry serves. A
            # directory entry cannot cover a root file, so only an entry naming the dotfile exactly keeps it, and that
            # entry is the reviewed approval to ship upstream's copy. An unedited upstream file under a fork-only
            # directory has no edits to lose (a release tarball may ship upstream's .github/workflows/, which the
            # fork does not run); one the fork deletes there must be listed like any other, by account_for_tarball.
            # Unedited means the tarball's bytes as the same kind of file, so a symlink or a changed executable bit is
            # an edit too.
            edited = path in upstream and fork[path] != (upstream_modes[path], upstream[path])
            if edited and ("/" in path or not path.startswith(".")):
                errors.append(f"{FORK_ONLY}: {entry} covers the upstream file {path}, whose edits must ship")
    # The exporter's own inputs describe the entry; none belongs in it.
    for path in (FORK_ONLY, PRESUBMIT, RELEASE_GENERATED, REMOVALS):
        if path in fork and not excluded(path):
            errors.append(f"{FORK_ONLY}: must cover {path}, which the exporter reads and the entry must not ship")
    if errors:
        raise ExportError("\n  ".join(["fork-only list does not match the trees:"] + errors))

    overlay = sorted(path for path in fork if path not in upstream and not excluded(path))
    kept_upstream = sorted(path for path in fork if path in upstream and excluded(path) and "/" not in path)
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


def patchable(path):
    """Whether path may be named in a patch header: plain components of ASCII letters, digits and ._+- only.

    Bazel's patcher reads a header's path up to a tab and trims it with String.trim(), which drops spaces and control
    characters at either end, and git quotes a name holding unusual bytes; either would make a patcher touch a file
    other than the one named.
    """
    return all(re.fullmatch(r"[A-Za-z0-9._+-]+", part) and part not in (".", "..") for part in path.split("/"))


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
            if not patchable(path):
                raise ExportError(f"{path!r}: an edited upstream file's path must hold only ASCII letters, digits and "
                                  "._+- between slashes")
            if b"\0" in fork[path][1] or b"\0" in upstream[path]:
                raise ExportError(f"{path}: edits to binary upstream files cannot ship as patches")
            # Bazel's patcher reads the file and the patch as UTF-8 lines and writes the result back as lines, so it
            # adds a final newline where one is missing and treats a CR as a line end. GNU patch keeps such bytes, so
            # the rebuild check would pass on a patch Bazel applies differently; refuse what Bazel cannot reproduce.
            for side, data in (("tarball's", upstream[path]), ("fork's", fork[path][1])):
                try:
                    data.decode()
                except UnicodeDecodeError:
                    raise ExportError(f"{path}: the {side} copy is not UTF-8, and Bazel's patcher reads lines as "
                                      "UTF-8, so its edits cannot ship as a patch") from None
                if b"\r" in data:
                    raise ExportError(f"{path}: the {side} copy holds a CR, which Bazel's line-based patcher reads "
                                      "as a line end, so its edits cannot ship as a patch")
                if data and not data.endswith(b"\n"):
                    raise ExportError(f"{path}: the {side} copy does not end in a newline, which Bazel's line-based "
                                      "patcher adds, so its edits cannot ship as a patch")
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


def removal_patch(fork, upstream, upstream_modes):
    """The patch that deletes the tarball files REMOVALS lists, generated from the tarball's own bytes.

    A file the tarball ships and the fork leaves out has no committed content to derive a patch from, so where the
    entry must not ship it, REMOVALS lists it to delete instead, one path per line; its # lines become
    the patch's description, copied with their leading #, so no description line can read as patch syntax to either
    patcher: Bazel's takes any line starting with @@ and holding a second @@ for a hunk header, with or without the
    space after the first. Each path must be patchable(), and its deletion is then the full-content diff git writes for
    it (git diff --full-index), so it matches the tarball's file exactly. Each is held to what Bazel's patcher can
    delete: a non-empty UTF-8 text file ending in a newline, without NUL or CR. read_tarball admits only regular files,
    so none is a symlink.

    Returns (patch bytes, or None when nothing is listed; the listed paths).
    """
    if REMOVALS not in fork:
        return None, []
    description, paths, errors = [], [], []
    # Split on \n alone and refuse \r, which Bazel's patcher also ends a line at, so each description line the patch
    # holds is exactly one # line of REMOVALS.
    for line in fork[REMOVALS][1].decode().split("\n"):
        if "\r" in line:
            errors.append(f"{REMOVALS}: the line {line!r} holds a CR")
        elif line.startswith("#"):
            description.append(line)
        elif line.strip():
            paths.append(line)
    if paths != sorted(paths):
        errors.append(f"{REMOVALS}: paths must be sorted")
    chunks = ["".join(line + "\n" for line in description).encode() + b"\n"] if description else []
    seen = set()
    for path in paths:
        problem = None
        if path in seen:
            problem = "is listed twice"
        elif not patchable(path):
            problem = "is not a plain path of ASCII letters, digits and ._+- between slashes"
        elif path not in upstream:
            problem = "is not in the tarball"
        elif path in fork:
            problem = "is committed by the fork"
        elif not upstream[path]:
            problem = "is empty, and Bazel's patcher cannot delete an empty file"
        elif b"\0" in upstream[path] or b"\r" in upstream[path]:
            problem = "holds NUL or CR bytes, which a text patch cannot delete exactly"
        elif not upstream[path].endswith(b"\n"):
            problem = "does not end in a newline"
        else:
            try:
                upstream[path].decode()
            except UnicodeDecodeError:
                problem = "is not UTF-8 text"
        seen.add(path)
        if problem:
            # repr shows the characters that make a path unpatchable.
            errors.append(f"{REMOVALS}: {path if patchable(path) else repr(path)} {problem}")
            continue
        data = upstream[path]
        lines = data[:-1].split(b"\n")
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        old_range = "1" if len(lines) == 1 else f"1,{len(lines)}"
        chunks.append(
            f"diff --git a/{path} b/{path}\ndeleted file mode {upstream_modes[path]}\nindex {blob}..{'0' * 40}\n"
            f"--- a/{path}\n+++ /dev/null\n@@ -{old_range} +0,0 @@\n".encode()
        )
        chunks.extend(b"-" + line + b"\n" for line in lines)
    if errors:
        raise ExportError("tarball removals:\n  " + "\n  ".join(errors))
    return (b"".join(chunks) if paths else None), paths


def account_for_tarball(fork, upstream, removed):
    """Checks that every tarball file is accounted for, and returns the ones RELEASE_GENERATED lists.

    The registry serves every tarball file the entry does not delete, so a tarball file the fork does not commit ships
    unseen: one the fork deleted or renamed would come back in the registry. Each such file must be listed, in
    RELEASE_GENERATED if the release process generates it and it ships as the tarball has it (configure, the manual
    pages), or in REMOVALS (removed, here) if the entry deletes it. RELEASE_GENERATED holds one path per line, sorted,
    # for comments. Like FORK_ONLY, both lists must be exact: each entry names a tarball file the fork does not commit,
    and no file is in both.
    """
    generated = []
    if RELEASE_GENERATED in fork:
        for line in fork[RELEASE_GENERATED][1].decode().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                generated.append(line)
    errors = [] if generated == sorted(set(generated)) else [f"{RELEASE_GENERATED}: paths must be sorted and unique"]
    for path in generated:
        if path not in upstream:
            errors.append(f"{RELEASE_GENERATED}: {path} is not in the tarball")
        elif path in fork:
            errors.append(f"{RELEASE_GENERATED}: {path} is committed by the fork")
        elif path in removed:
            errors.append(f"{path} is listed in both {RELEASE_GENERATED} and {REMOVALS}")
    unaccounted = sorted(upstream.keys() - fork.keys() - set(generated) - set(removed))
    errors.extend(f"{path}: the tarball ships it, but the fork neither commits nor lists it" for path in unaccounted)
    if unaccounted:
        errors.append(
            f"for each, commit it (restore it, if the fork deleted or renamed it), list it in {RELEASE_GENERATED} if "
            f"the release process generates it and it should ship as the tarball has it, or list it in {REMOVALS} "
            "for the entry to delete it"
        )
    if errors:
        raise ExportError("tarball files are not accounted for:\n  " + "\n  ".join(errors))
    return generated


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


def rebuild_from_entry(entry, upstream, upstream_modes, work):
    """Rebuilds the source tree in Bazel's order: tarball, then overlay files, then patches, each checked by
    source.json. GNU patch stands in for Bazel's patcher; the patches' constraints make both apply them the same way.

    Returns {path: (mode, bytes)}, each mode as git records it: a symlink as 120000 and its target.
    """
    source = json.loads((entry / "source.json").read_text())
    tree = work / "tree"
    for path, data in upstream.items():
        (tree / path).parent.mkdir(parents=True, exist_ok=True)
        (tree / path).write_bytes(data)
        (tree / path).chmod(0o755 if upstream_modes[path] == "100755" else 0o644)
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
    rebuilt = {}
    for path in tree.rglob("*"):
        if path.is_symlink():
            rebuilt[str(path.relative_to(tree))] = ("120000", os.fsencode(os.readlink(path)))
        elif path.is_file():
            mode = "100755" if path.stat().st_mode & 0o100 else "100644"
            rebuilt[str(path.relative_to(tree))] = (mode, path.read_bytes())
    return rebuilt


def expected_tree(fork, upstream, upstream_modes, overlay, kept_upstream, generated):
    """The distribution tree the entry must rebuild, {path: (mode, bytes)}, built from the fork's side rather than from
    the tarball: every overlay file and every upstream file the fork commits, as committed, except kept_upstream,
    whose tarball copies stand in for the fork's, as do generated's, which the fork does not commit. A tarball file
    none of these accounts for is not in it, so a rebuilt tree that still holds one fails the check."""
    tree = {path: fork[path] for path in overlay}
    tree.update((path, fork[path]) for path in fork if path in upstream and path not in kept_upstream)
    tree.update((path, (upstream_modes[path], upstream[path])) for path in kept_upstream + generated)
    return tree


def updated_metadata(module_dir, version):
    """metadata.json's text with version added, versions sorted by Bazel's module version order."""
    metadata = json.loads((module_dir / "metadata.json").read_text())
    metadata["versions"] = sorted(set(metadata["versions"]) | {version}, key=version_key)
    return json.dumps(metadata, indent=4) + "\n"


def stage_entry(fork, tarball, tarball_url, strip_prefix, staged, work):
    """Writes the entry for fork, {path: (mode, bytes)}, on the tarball's bytes into staged, using work for scratch,
    and checks that it rebuilds the expected distribution tree. Returns (overlay paths, {patch name: bytes})."""
    fork_only = load_fork_only(fork)
    upstream, upstream_modes = read_tarball(tarball, strip_prefix)

    overlay, kept_upstream = classify(fork, upstream, upstream_modes, fork_only)
    if "MODULE.bazel" not in overlay:
        raise ExportError("MODULE.bazel is not in the overlay")
    check_overlay(fork, overlay)
    patches = derive_patches(fork, upstream, upstream_modes, kept_upstream)
    removal, removed = removal_patch(fork, upstream, upstream_modes)
    generated = account_for_tarball(fork, upstream, removed)
    if removal:
        if REMOVAL_PATCH in patches:
            raise ExportError(f"patches/{REMOVAL_PATCH} is both the patch derived for an edited upstream file and "
                              f"the one generated from {REMOVALS}")
        patches[REMOVAL_PATCH] = removal
    # Consumers on macOS and Windows extract the entry onto case-insensitive filesystems, where two paths that differ
    # only in case are one: an overlay file could land on a tarball file, or on one the removal patch then deletes.
    # Every path the entry touches, the tarball's (removed ones included) and the overlay's, and each of their
    # directories, must therefore stay distinct without case.
    spellings = {}
    for path in [*upstream, *overlay]:
        parts = path.split("/")
        for depth in range(1, len(parts) + 1):
            spellings.setdefault("/".join(parts[:depth]).casefold(), set()).add("/".join(parts[:depth]))
    collisions = sorted(" and ".join(sorted(names)) for names in spellings.values() if len(names) > 1)
    if collisions:
        raise ExportError("paths that differ only in case, which a case-insensitive filesystem holds as one:\n  "
                          + "\n  ".join(collisions))

    write_entry(staged, fork, overlay, patches, tarball_url, integrity(tarball), strip_prefix)
    rebuilt = rebuild_from_entry(staged, upstream, upstream_modes, work)
    expected = expected_tree(fork, upstream, upstream_modes, overlay, kept_upstream, generated)
    shared = expected.keys() & rebuilt.keys()
    differences = sorted(
        [f"missing from the entry: {path}" for path in expected.keys() - rebuilt.keys()]
        + [f"not expected: {path}" for path in rebuilt.keys() - expected.keys()]
        + [f"differs from the expected content: {path}" for path in shared if expected[path][1] != rebuilt[path][1]]
        + [f"has mode {rebuilt[path][0]}, not the expected {expected[path][0]}: {path}" for path in shared
           if expected[path][0] != rebuilt[path][0]]
    )
    if differences:
        raise ExportError("the entry does not rebuild the expected distribution tree:\n  " + "\n  ".join(differences))
    if (staged / "MODULE.bazel").read_bytes() != (staged / "overlay" / "MODULE.bazel").read_bytes():
        raise ExportError("entry: MODULE.bazel differs from overlay/MODULE.bazel")
    return overlay, patches


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

    url = UPSTREAM_URL.format(upstream=upstream_version)
    if args.tarball:
        tarball = args.tarball.read_bytes()
    else:
        print(f"Downloading {url}", file=sys.stderr)
        with urllib.request.urlopen(url) as response:
            tarball = response.read()

    module_dir = args.registry / "modules" / MODULE_NAME
    if not (module_dir / "metadata.json").is_file():
        raise ExportError(f"{module_dir}/metadata.json does not exist; is {args.registry} a registry checkout?")
    entry = module_dir / version
    if entry.exists() and not args.replace:
        raise ExportError(f"{entry} exists; pass --replace to rewrite it")
    # Computed before anything is written, so a malformed metadata.json stops the export with the registry untouched.
    metadata = updated_metadata(module_dir, version)
    # Every entry for this upstream release must fetch the same tarball. A release asset re-rolled upstream would
    # otherwise reach consumers under a new .bcr.N as if only the Bazel build had changed.
    mismatches = []
    for prior in sorted(module_dir.iterdir()):
        if (re.fullmatch(rf"{re.escape(upstream_version)}(?:\.bcr\.\d+)?", prior.name)
                and (prior / "source.json").is_file()):
            named = json.loads((prior / "source.json").read_text())["integrity"]
            if named != integrity(tarball):
                mismatches.append(f"{prior}/source.json names {named}")
    if mismatches:
        raise ExportError(
            f"the tarball being exported ({integrity(tarball)}) is not the one earlier entries for upstream "
            f"{upstream_version} fetch; upstream's release asset has changed, and that needs a deliberate decision, "
            "not a new .bcr.N:\n  " + "\n  ".join(mismatches)
        )

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        staged = work / "entry"
        staged.mkdir()
        overlay, patches = stage_entry(fork, tarball, url, f"jemalloc-{upstream_version}", staged, work)

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
