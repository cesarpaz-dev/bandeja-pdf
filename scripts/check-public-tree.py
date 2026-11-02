#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Check the working-tree files eligible for a public source commit.

Uses tracked files (even when ignored) plus non-ignored untracked files. It does
not change the index, inspect Git history, run project code, or contact links.
The allowlist is intentionally narrow; extend it deliberately for new assets.
This is a release guard, not a substitute for reviewing the proposed commit.
"""

import argparse
import html
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import stat
import subprocess
import sys
import unicodedata
from urllib.parse import unquote, urlsplit


MAX_TEXT_BYTES = 2 * 1024 * 1024
MAX_DISPLAY_ISSUES = 25
ROOT_FILES = {
    ".gitignore", ".gitattributes", ".editorconfig", "README.md",
    "CHANGELOG.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md", "SECURITY.md",
    "CODE_OF_CONDUCT.md", "LICENSE", "LICENSE.md", "LICENSE.txt", "requirements-dev.txt",
}
LOCAL_COMPONENTS = {
    "local", "private", "phase0", "phase1", "build", ".build", ".swiftpm",
    ".standalone", "runs", "artifacts", "evidence", "output", "outputs",
    "tmp", "temp", "__pycache__", ".venv", "venv", "node_modules",
    "capture", "captures", "spool", "backup", "backups", ".git",
}
SOURCE_TARGETS = {
    "BandejaAgent", "BandejaCLI", "BandejaCore", "BandejaShared", "BandejaUI",
}
NATIVE_FILES = {
    "native/Package.swift", "native/README.md",
    "native/Resources/Info.plist", "native/Resources/BandejaPDF.ppd",
    "native/Tests/BandejaCoreTests/.gitignore",
    "native/Tests/BandejaCoreTests/run-standalone.sh",
}
PRIVATE_PATH = re.compile(r"/Users/" + r'''[^/\s"'<>]+/''')
SECRET_PATTERNS = {
    "private-key": re.compile(
        r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "github-token": re.compile(
        r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{25,})\b"),
    "api-token": re.compile(
        r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b"),
    "aws-access-key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "google-api-key": re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    "slack-token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "credential-url": re.compile(r"https?://[^\s/:@]+:[^\s/@]+@"),
    "jwt": re.compile(r"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b"),
    "literal-credential": re.compile(
        r'''(?ix)\b(?:api[_-]?key|client[_-]?secret|secret[_-]?key|password|passwd|'''
        r'''access[_-]?token|auth[_-]?token)\s*[=:]\s*["']'''
        r'''[A-Za-z0-9_+./=!-]{16,}["']'''),
}
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
REFERENCE = re.compile(r"^ {0,3}\[([^\]\n]+)\]:[ \t]*(.*)$")


class AuditError(Exception):
    pass


def git(directory, *arguments):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    result = subprocess.run(
        ["git", "-C", str(directory), *arguments], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=environment, check=False)
    if result.returncode:
        # Git diagnostics can contain private paths or remote credentials.
        raise AuditError("Cannot read Git metadata; run inside a Git working tree.")
    return result.stdout


def candidate_files(root):
    files = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    try:
        names = sorted(set(name.decode("utf-8") for name in files.split(b"\0") if name))
        staged_links = set()
        for entry in git(root, "ls-files", "--stage", "-z").split(b"\0"):
            if entry:
                metadata, name = entry.split(b"\t", 1)
                if metadata.split()[0] == b"120000":
                    staged_links.add(name.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise AuditError("Git contains an unsupported filename or index entry.")
    return names, staged_links


def allowed_path(name):
    parts = PurePosixPath(name).parts
    if any(part.casefold() in LOCAL_COMPONENTS for part in parts):
        return False
    if name in ROOT_FILES or name in NATIVE_FILES:
        return True
    suffix = PurePosixPath(name).suffix
    if len(parts) >= 2 and parts[0] == "docs":
        return suffix in {".md", ".mmd"} and all(not p.startswith(".") for p in parts[1:])
    if len(parts) == 2 and parts[0] == "scripts":
        return suffix in {".py", ".sh"} and not parts[1].startswith(".")
    if len(parts) >= 4 and parts[:2] == ("native", "Sources"):
        return parts[2] in SOURCE_TARGETS and suffix == ".swift"
    if len(parts) >= 4 and parts[:3] == ("native", "Tests", "BandejaCoreTests"):
        return suffix == ".swift"
    if len(parts) == 3 and parts[:2] == ("native", "scripts"):
        return suffix in {".py", ".sh"} and not parts[2].startswith(".")
    if len(parts) == 3 and parts[:2] == (".github", "workflows"):
        return suffix in {".yml", ".yaml"}
    if len(parts) == 3 and parts[:2] == (".github", "ISSUE_TEMPLATE"):
        return suffix in {".md", ".yml", ".yaml"}
    return name in {".github/PULL_REQUEST_TEMPLATE.md", ".github/pull_request_template.md",
                    ".github/CODEOWNERS"}


def mask_code(text, inline=True):
    """Keep line offsets while hiding fenced (including Mermaid) and inline code."""
    result = []
    fence = None
    for line in text.splitlines(keepends=True):
        match = FENCE.match(line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= len(fence):
                if not line[match.end():].strip():
                    fence = None
            result.append(re.sub(r"[^\n]", " ", line))
        elif match:
            fence = match[1]
            result.append(re.sub(r"[^\n]", " ", line))
        elif line.startswith("    ") or line.startswith("\t"):
            result.append(re.sub(r"[^\n]", " ", line))
        else:
            result.append(line)
    masked = "".join(result)
    if inline:
        masked = re.sub(r"(`+)(?!`)(.*?)(?<!`)\1(?!`)",
                        lambda m: re.sub(r"[^\n]", " ", m[0]), masked, flags=re.S)
    return masked


def escaped(text, index):
    count = 0
    while index > 0 and text[index - 1] == "\\":
        count += 1
        index -= 1
    return bool(count % 2)


def destination(text, start):
    """Parse a Markdown destination, including angle brackets and balanced ()."""
    position = start
    while position < len(text) and text[position].isspace():
        position += 1
    if position >= len(text):
        return None, position
    if text[position] == "<":
        end = position + 1
        while end < len(text):
            if text[end] == ">" and not escaped(text, end):
                return text[position + 1:end], end + 1
            if text[end] == "\n":
                return None, end
            end += 1
        return None, end
    begin, depth = position, 0
    while position < len(text):
        char = text[position]
        if not escaped(text, position):
            if char.isspace():
                break
            if char == "(":
                depth += 1
            elif char == ")":
                if depth == 0:
                    break
                depth -= 1
        position += 1
    if depth:
        return None, position
    return text[begin:position], position


def label_key(label):
    return " ".join(label.split()).casefold()


def markdown_links(text):
    """Return (line, destination, error) for inline and reference-style links."""
    masked = mask_code(text)
    definitions, references, rows = {}, [], []
    for number, line in enumerate(masked.splitlines(keepends=True), 1):
        match = REFERENCE.match(line)
        if match:
            target, _ = destination(match[2], 0)
            if target is not None:
                definitions.setdefault(label_key(match[1]), target)
                references.append((number, target, None))
            rows.append(re.sub(r"[^\n]", " ", line))
        else:
            rows.append(line)
    masked = "".join(rows)
    position = 0
    while position < len(masked):
        if masked[position] != "[" or escaped(masked, position):
            position += 1
            continue
        begin, end, depth = position, position + 1, 1
        while end < len(masked) and depth:
            if not escaped(masked, end):
                if masked[end] == "[":
                    depth += 1
                elif masked[end] == "]":
                    depth -= 1
            end += 1
        if depth:
            position += 1
            continue
        label = masked[begin + 1:end - 1]
        line = masked.count("\n", 0, begin) + 1
        if end < len(masked) and masked[end] == "(":
            target, after = destination(masked, end + 1)
            if target is not None:
                references.append((line, target, None))
            else:
                references.append((line, None, "Malformed Markdown link destination."))
            position = max(after, end + 1)
        elif end < len(masked) and masked[end] == "[":
            close = masked.find("]", end + 1)
            if close != -1:
                key = label_key(masked[end + 1:close] or label)
                if key in definitions:
                    references.append((line, definitions[key], None))
                else:
                    references.append((line, None, "Undefined Markdown link reference."))
                position = close + 1
            else:
                position = end
        else:
            key = label_key(label)
            if key in definitions:
                references.append((line, definitions[key], None))
            position = end
    return references


def heading_anchors(text):
    visible = mask_code(text, inline=False)
    anchors, used = set(), set()
    for match in re.finditer(r'''(?i)\b(?:id|name)=["']([^"']+)["']''', visible):
        anchors.add(html.unescape(match[1]).casefold())
    lines = visible.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^ {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+[ \t]*)?$", line)
        title = match[1] if match else None
        if title is None and index + 1 < len(lines) and line.strip():
            if re.fullmatch(r" {0,3}(?:=+|-+)[ \t]*", lines[index + 1]):
                title = line.strip()
        if title is None:
            continue
        title = re.sub(r"!?\[([^\]]+)\]\([^)]*\)", r"\1", title)
        title = html.unescape(re.sub(r"<[^>]*>", "", title)).casefold()
        title = title.replace("`", "").replace("*", "").replace("~", "")
        slug = "".join(char for char in title if char.isspace() or char in "-_"
                       or unicodedata.category(char)[0] in {"L", "N", "M"})
        slug = re.sub(r"\s", "-", slug)
        candidate, suffix = slug, 0
        while candidate in used:
            suffix += 1
            candidate = slug + "-" + str(suffix)
        used.add(candidate)
        anchors.add(candidate)
    return anchors


def check_link(source, target, public, texts, anchors):
    target = html.unescape(re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~ ])", r"\1", target))
    try:
        parsed = urlsplit(target)
    except ValueError:
        return "Malformed link URL."
    if parsed.scheme.casefold() in {"http", "https", "mailto", "tel"} or target.startswith("//"):
        return None
    if parsed.scheme:
        return "Link uses a local or unsupported URL scheme."
    path = unquote(parsed.path)
    if path.startswith(("/", "~")) or "\\" in path:
        return "Local link must be relative to the repository."
    name = posixpath.normpath(posixpath.join(posixpath.dirname(source), path)) if path else source
    if name == ".." or name.startswith("../"):
        return "Local link escapes the repository."
    is_directory = name == "." or any(p.startswith(name.rstrip("/") + "/") for p in public)
    if name not in public and not is_directory:
        return "Local link target is missing or excluded from the public tree."
    fragment = unquote(parsed.fragment).casefold()
    if not fragment:
        return None
    if is_directory:
        readme = posixpath.join("" if name == "." else name, "README.md")
        if readme not in public:
            return "Directory anchor has no public README target."
        name = readme
    if name.endswith(".md"):
        if fragment not in anchors.get(name, set()):
            return "Markdown anchor does not exist in the public target."
    else:
        match = re.fullmatch(r"l([1-9]\d*)(?:-l([1-9]\d*))?", fragment)
        if not match:
            return "Unsupported anchor on a non-Markdown target."
        first, last = int(match[1]), int(match[2] or match[1])
        if first > last or last > len(texts[name].splitlines()):
            return "Source line anchor is outside the public target."
    return None


def audit(root):
    names, staged_links = candidate_files(root)
    issues, texts = [], {}

    def issue(name, code, message, line=None):
        item = {"path": name, "code": code, "message": message}
        if line is not None:
            item["line"] = line
        if item not in issues:
            issues.append(item)

    for name in names:
        parts = PurePosixPath(name).parts
        if not parts or PurePosixPath(name).is_absolute() or ".." in parts:
            issue(name, "path", "Invalid repository-relative path.")
            continue
        if name in staged_links or any(root.joinpath(*parts[:i]).is_symlink() for i in range(1, len(parts) + 1)):
            issue(name, "symlink", "Symbolic links are not part of the public source tree.")
            continue
        if not allowed_path(name):
            issue(name, "allowlist", "Local, generated, or unexpected file; excluded by the public allowlist.")
            continue
        path = root / name
        try:
            info = path.stat()
            if not stat.S_ISREG(info.st_mode):
                issue(name, "file-type", "Only regular text files may be published.")
                continue
            if info.st_size > MAX_TEXT_BYTES:
                issue(name, "file-size", "Text file exceeds the public source size limit.")
                continue
            raw = path.read_bytes()
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            issue(name, "binary", "File is not UTF-8 text.")
            continue
        except OSError:
            issue(name, "unreadable", "Candidate file is missing or unreadable.")
            continue
        if any(ord(c) < 32 and c not in "\n\r\t" for c in text) or raw.startswith((b"%PDF-", b"%!PS")):
            issue(name, "binary", "Binary content or an unexpected document is not publishable here.")
            continue
        texts[name] = text
        for number, line in enumerate(text.splitlines(), 1):
            if PRIVATE_PATH.search(line):
                issue(name, "private-path", "Contains an absolute user-specific path.", number)
            for label, pattern in SECRET_PATTERNS.items():
                if pattern.search(line):
                    issue(name, "credential", "Possible credential detected (" + label + "); value omitted.", number)
    public = set(texts)
    anchors = {name: heading_anchors(text) for name, text in texts.items() if name.endswith(".md")}
    for name, text in texts.items():
        if not name.endswith(".md"):
            continue
        for line, target, error in markdown_links(text):
            problem = error or check_link(name, target, public, texts, anchors)
            if problem:
                issue(name, "markdown-link", problem, line)
    return {"ok": not issues, "files_checked": len(names), "issues": issues}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="Git working tree to inspect (default: this script's repository)")
    parser.add_argument("--json", action="store_true", help="print a machine-readable report")
    args = parser.parse_args()
    try:
        root = Path(git(args.root, "rev-parse", "--show-toplevel").decode().strip())
        result = audit(root)
    except (AuditError, OSError, UnicodeDecodeError) as error:
        message = str(error) if isinstance(error, AuditError) else "Unable to inspect the working tree."
        if args.json:
            print(json.dumps({"ok": False, "error": message}, sort_keys=True))
        else:
            print("Public-tree audit: " + message, file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=True, sort_keys=True))
    else:
        status = "PASS" if result["ok"] else "FAIL"
        print(f"{status}: {result['files_checked']} candidate files; {len(result['issues'])} issue(s).")
        for item in result["issues"][:MAX_DISPLAY_ISSUES]:
            location = json.dumps(item["path"], ensure_ascii=True)
            if "line" in item:
                location += ":" + str(item["line"])
            print(f"  {location}: [{item['code']}] {item['message']}")
        remaining = len(result["issues"]) - MAX_DISPLAY_ISSUES
        if remaining > 0:
            print(f"  {remaining} additional issue(s); use --json for the full report.")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
