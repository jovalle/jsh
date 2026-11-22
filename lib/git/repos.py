"""Summarizes every Git repository below a directory, one line each, for `git status` outside one.

Usage: repos.py COLOR [-R] [-l] [DIR]. COLOR is "true" for color; JSH_GIT_BIN names the real git.
With -l, each repository with changes also lists its files the way status.py condenses them.
Without DIR, a directory holding no repositories falls back to $GIT_BASE (default ~/Projects).
Rows use the prompt's git symbols and colors, and shrink to fit the terminal like the prompt does.

Usage: repos.py --branch COLOR [OPTIONS]. Lists the branches of each repository directly below
the current directory with `git branch --list OPTIONS`, so it never creates or deletes one.
"""

import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

SKIP = {"node_modules"}
SGR = re.compile(r"\033\[[0-9;]*m")
USAGE = "usage: git status [-R] [-l] [DIR]   (outside a repository)"
SECTIONS = (
    "Changes to be committed:",
    "Changes not staged for commit:",
    "Unmerged paths:",
    "Untracked files:",
)
GAP = "  "
INDENT = "  "
NAME_MIN = 6
BRANCH_MIN = 4
BRANCH_MAX = 24

# Same as dotfiles/.zshrc.
ICONS = {
    "nerdfont-v3": {"branch": "\uf126 ", "ahead": "⇡", "behind": "⇣"},
    "unicode": {"branch": "", "ahead": "⇡", "behind": "⇣"},
    "ascii": {"branch": "", "ahead": "^", "behind": "v"},
}
COLORS = {
    "directory": "1;38;2;0;191;255",
    "clean": "38;2;95;255;0",
    "modified": "38;2;255;215;0",
    "untracked": "38;2;0;215;255",
    "error": "38;2;255;59;48",
}
# Status columns after the name and branch, in prompt order: (key, symbol, color).
MARKS = (
    ("stash", "*", "clean"),
    ("conflicted", "~", "error"),
    ("staged", "+", "modified"),
    ("unstaged", "!", "modified"),
    ("untracked", "?", "untracked"),
)


def find(root, recursive):
    """Returns repositories directly below root, or at any depth when recursive, sorted."""
    found, seen = [], set()

    def walk(directory):
        try:
            stat = directory.stat()
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name.lower())
        except OSError:
            return
        if (stat.st_dev, stat.st_ino) in seen:
            return
        seen.add((stat.st_dev, stat.st_ino))
        for entry in entries:
            try:
                if not entry.is_dir():
                    continue
                is_repo = (Path(entry.path) / ".git").exists()
            except OSError:
                continue
            path = Path(entry.path)
            if is_repo:
                found.append(path)
            elif recursive and not entry.name.startswith(".") and entry.name not in SKIP:
                walk(path)

    walk(root)
    return found


def git_output(git, repo, *args):
    return subprocess.run(
        [git, "-C", str(repo), *args], capture_output=True, text=True, check=False
    )


def parse(text) -> dict[str, Any]:
    """Returns the summary dict for `git status --porcelain=v2 --branch --show-stash` output."""
    info: dict[str, Any] = dict.fromkeys(("ahead", "behind") + tuple(key for key, _, _ in MARKS), 0)
    info.update(branch="", state="")
    oid = ""
    for line in text.splitlines():
        words = line.split(" ")
        if line.startswith("# branch.oid "):
            oid = words[2]
        elif line.startswith("# branch.head "):
            info["branch"] = line.split(" ", 2)[2]
        elif line.startswith("# branch.ab "):
            info["ahead"], info["behind"] = int(words[2]), -int(words[3])
        elif line.startswith("# stash "):
            info["stash"] = int(words[2])
        elif words[0] in ("1", "2"):
            info["staged"] += words[1][0] != "."
            info["unstaged"] += words[1][1] != "."
        elif words[0] in ("u", "?"):
            info["conflicted" if words[0] == "u" else "untracked"] += 1
    if not info["branch"] or info["branch"] == "(detached)":
        info["branch"] = "@" + oid[:7]
    return info


def read_first(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def operation(gitdir):
    """Returns the prompt's label for a rebase, am, merge, cherry-pick, revert, or bisect."""
    label, step = "", ("", "")
    if (gitdir / "rebase-merge").is_dir():
        label = "REBASE"
        step = (gitdir / "rebase-merge/msgnum", gitdir / "rebase-merge/end")
    elif (gitdir / "rebase-apply").is_dir():
        label = "AM" if (gitdir / "rebase-apply/applying").exists() else "REBASE"
        step = (gitdir / "rebase-apply/next", gitdir / "rebase-apply/last")
    else:
        for name, text in (
            ("MERGE_HEAD", "MERGE"),
            ("CHERRY_PICK_HEAD", "CHERRY-PICK"),
            ("REVERT_HEAD", "REVERT"),
            ("BISECT_LOG", "BISECT"),
        ):
            if (gitdir / name).is_file():
                return text
        return ""
    current, total = (read_first(path) for path in step)
    return f"{label} {current}/{total}" if current.isdigit() and total.isdigit() else label


def summarize(git, repo):
    """Returns a dict describing repo's branch, upstream distance, changes, state, and stashes."""
    result = git_output(
        git,
        repo,
        "status",
        "--porcelain=v2",
        "--branch",
        "--show-stash",
        "--untracked-files=normal",
        "--ignore-submodules=dirty",
    )
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        info = parse("")
        info.update(branch="", error=lines[0] if lines else "git status failed")
        return info
    info = parse(result.stdout)
    gitdir = git_output(git, repo, "rev-parse", "--absolute-git-dir").stdout.strip()
    if gitdir:
        info["state"] = operation(Path(gitdir))
    return info


def details(git, repo, color, width):
    """Returns repo's changed files as lines condensed by status.py, without branch notes."""
    result = git_output(
        git,
        repo,
        "-c",
        "advice.statusHints=false",
        "-c",
        "status.relativePaths=false",
        "-c",
        "color.status=never",
        "status",
        "--untracked-files=normal",
        "--ignore-submodules=dirty",
    )
    lines = [
        line for line in result.stdout.splitlines() if line in SECTIONS or line.startswith("\t")
    ]
    if not lines:
        return []
    condensed = subprocess.run(
        [sys.executable, str(Path(__file__).with_name("status.py")), str(color).lower()],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "COLUMNS": str(max(width, 20))},
    )
    return condensed.stdout.splitlines()


def clean(info):
    return not (
        info.get("error")
        or info["state"]
        or any(info[key] for key in ("ahead", "behind") + tuple(key for key, _, _ in MARKS))
    )


def tilde(path):
    home = str(Path.home())
    text = str(path)
    return "~" + text[len(home) :] if text == home or text.startswith(home + "/") else text


def abbreviate(value, size):
    """Shortens value to size like the prompt: …/leaf, or …tail when the leaf is too long."""
    if size <= 0 or len(value) <= size:
        return value
    leaf = value.rstrip("/").rpartition("/")[2]
    if len(leaf) + 2 <= size:
        return "…/" + leaf
    return "…" + value[-(size - 1) :] if size > 1 else "…"


def clip(text, size):
    """Cuts painted text to size visible characters, ending in … when anything was cut."""
    if visible(text) <= size:
        return text
    plain = SGR.sub("", text)
    return plain[: size - 1] + "…" if size > 1 else ""


def visible(text):
    return len(SGR.sub("", text))


def mode():
    """Returns the prompt's symbol set: JSH_PROMPT_MODE, or ascii outside a UTF-8 locale."""
    chosen = os.environ.get("JSH_PROMPT_MODE", "nerdfont-v3")
    chosen = chosen if chosen in ICONS else "nerdfont-v3"
    locale = os.environ.get("LC_ALL") or os.environ.get("LC_CTYPE") or os.environ.get("LANG")
    if not re.search(r"utf-?8", (locale or "C").lower()):
        chosen = "ascii"
    return ICONS[chosen]


class Table:
    """Lays out one row per repository, fitting the terminal like the prompt does."""

    def __init__(self, rows, paint, icons):
        self.rows, self.paint, self.icons = rows, paint, icons
        self.columns = ["distance", "state"] + [key for key, _, _ in MARKS]
        self.columns = [key for key in self.columns if any(self.cell(r, key) for r in rows)]

    def cell(self, row, key):
        """Returns the painted text of one status cell."""
        info = row[1]
        if key == "distance":
            text = self.icons["behind"] + str(info["behind"]) if info["behind"] else ""
            text += self.icons["ahead"] + str(info["ahead"]) if info["ahead"] else ""
            return self.paint(COLORS["clean"], text)
        if key == "state":
            return self.paint(COLORS["error"], info["state"])
        symbol, color = next((s, c) for k, s, c in MARKS if k == key)
        return self.paint(COLORS[color], f"{symbol}{info[key]}") if info[key] else ""

    def fit(self, names, branches, fixed, width):
        """Returns (icon, name size, branch size): the widest layout within width.

        The branch column is as wide as the longest branch that fits, or as wide as it can be,
        up to BRANCH_MAX, when a longer one has to be cut. Names shorten only when even a
        BRANCH_MIN column will not fit, and the column disappears when that is still too narrow.
        """
        icon = self.icons["branch"]
        name_size, longest = max(map(len, names)), max(map(len, branches))
        if fixed + name_size + len(GAP) + len(icon) + longest > width:
            icon = ""
        room = width - fixed - len(GAP)
        while room - name_size < BRANCH_MIN and name_size > NAME_MIN:
            name_size -= 1
        room = min(room - name_size, BRANCH_MAX)
        if room < BRANCH_MIN:
            return "", max(NAME_MIN, min(max(map(len, names)), width - fixed)), 0
        fitting = max((len(b) for b in branches if len(b) <= room), default=0)
        return icon, name_size, room if fitting < longest else fitting

    def lines(self, width):
        """Returns each row's lines no wider than width, long branches in full on the next line."""
        names = [row[0] for row in self.rows]
        branches = [row[1]["branch"] for row in self.rows]
        status = [[self.cell(row, key) for key in self.columns] for row in self.rows]
        widths = [max(visible(cells[i]) for cells in status) for i in range(len(self.columns))]
        fixed = len(INDENT) + sum(size + len(GAP) for size in widths)
        if fixed + NAME_MIN > width:
            # Collapsed: status cells packed with single spaces, so the name keeps more room.
            status = [[" ".join(cell for cell in cells if cell)] for cells in status]
            widths = [max(visible(cells[0]) for cells in status)]
            fixed = len(INDENT) + widths[0] + len(GAP)
        layout = self.fit(names, branches, fixed, width)
        out = []
        for name, branch, cells in zip(names, branches, status):
            row = [INDENT + GAP.join(self.parts(name, branch, cells, widths, layout))]
            if branch and len(branch) > layout[2]:
                row.append(self.overflow(branch, layout, width))
            out.append([clip(line.rstrip(), width) for line in row])
        return out

    def overflow(self, branch, layout, width):
        """Returns the line under a row whose branch was cut or left out."""
        icon, name_size, branch_size = layout
        if not branch_size:
            return INDENT * 2 + self.paint(COLORS["clean"], self.icons["branch"] + branch)
        # The leading … sits just left of the cut branch above, shifted left to fit.
        text = "…" + branch
        start = len(INDENT + GAP) + name_size + len(icon) - 1
        start = max(len(INDENT) * 2, min(start, width - len(text)))
        return " " * start + self.paint(COLORS["clean"], text)

    def parts(self, name, branch, cells, widths, layout):
        """Returns the padded, painted cells of one row."""
        icon, name_size, branch_size = layout
        out = [self.paint(COLORS["directory"], abbreviate(name, name_size).ljust(name_size))]
        if branch_size:
            cut = branch if len(branch) <= branch_size else branch[: branch_size - 1] + "…"
            text = icon + cut
            out.append(
                self.paint(COLORS["clean"], text) + " " * (branch_size + len(icon) - len(text))
            )
        return out + [cell + " " * (size - visible(cell)) for cell, size in zip(cells, widths)]


def reason(error):
    """Returns git's error without its fatal: prefix or the parent-directory boilerplate."""
    error = re.sub(r"^(fatal|error): ", "", error)
    return re.sub(r" \(or any of the parent directories\).*$", "", error)


def wrap(words, width, prefix):
    """Returns words joined by ", " in lines no wider than width, after prefix."""
    lines, line = [], prefix
    for number, word in enumerate(words):
        piece = word + ("," if number < len(words) - 1 else "")
        if line.strip() and len(line) + 1 + len(piece) > width:
            lines.append(line)
            line = INDENT + piece
        else:
            line += (" " if line.strip() else "") + piece
    lines.append(line)
    return lines


def arguments(args):
    """Returns (recursive, long, target), or None for arguments this summary does not take."""
    recursive, long, target = False, False, None
    for arg in args:
        if arg == "--recursive":
            recursive = True
        elif arg == "--long":
            long = True
        elif re.fullmatch(r"-[Rl]+", arg):
            recursive = recursive or "R" in arg
            long = long or "l" in arg
        elif arg.startswith("-") or target is not None:
            return None
        else:
            target = arg
    return recursive, long, target


def locate(target, recursive, note):
    """Returns (root, repositories), falling back to $GIT_BASE when target is not given."""
    root = Path(target or os.getcwd()).expanduser().resolve()
    repos = find(root, recursive)
    if not repos and target is None:
        base = Path(os.environ.get("GIT_BASE") or Path.home() / "Projects").expanduser()
        if base.is_dir() and base.resolve() != root:
            note(f"No repositories in {tilde(root)}; showing {tilde(base)}")
            root = base.resolve()
            repos = find(root, recursive)
    return root, repos


def main(argv):
    color = argv[:1] == ["true"]
    parsed = arguments(argv[1:])
    if parsed is None:
        print(USAGE, file=sys.stderr)
        return 2
    recursive, long, target = parsed

    def paint(code, text):
        return f"\033[{code}m{text}\033[0m" if color and code and text else text

    def note(text):
        print(paint("2", text))

    if target and not Path(target).expanduser().is_dir():
        print(f"git status: not a directory: {target}", file=sys.stderr)
        return 1
    root, repos = locate(target, recursive, note)
    if not repos:
        note(f"No repositories in {tilde(root)}")
        return 0
    report(root, repos, paint, note, color if long else None)
    return 0


def report(root, repos, paint, note, long=None):
    """Prints the header, a row per repository with changes, then broken and clean ones folded.

    long, when not None, is the color flag for the file lists printed under each changed row.
    """
    git = os.environ.get("JSH_GIT_BIN", "git")
    width = shutil.get_terminal_size().columns
    indent = INDENT * 2

    def inspect(repo):
        info = summarize(git, repo)
        skip = long is None or clean(info) or info.get("error")
        files = [] if skip else details(git, repo, long, width - len(indent))
        return info, files

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        infos, files = zip(*pool.map(inspect, repos))
    count = "1 repo" if len(repos) == 1 else f"{len(repos)} repos"
    print(paint(COLORS["directory"], tilde(root)) + paint("2", f" ({count})"))
    names = [str(repo.relative_to(root)) for repo in repos]
    rows = list(zip(names, infos, files))
    dirty = [(name, info) for name, info, _ in rows if not clean(info) and not info.get("error")]
    listed = [lines for _, info, lines in rows if not clean(info) and not info.get("error")]
    broken: dict[str, list[str]] = {}
    for name, info, _ in rows:
        if info.get("error"):
            broken.setdefault(reason(info["error"]), []).append(name)
    tidy = [name for name, info, _ in rows if clean(info)]
    if dirty:
        for row, lines in zip(Table(dirty, paint, mode()).lines(width), listed):
            print("\n".join(row + [indent + line for line in lines]))
    for error, group in broken.items():
        for line in wrap(group, width, f"{len(group)} {error}:"):
            print(paint(COLORS["error"], line))
    if tidy:
        for line in wrap(tidy, width, f"{len(tidy)} clean:"):
            note(line)


def branches(argv):
    """Prints each repository's `git branch` listing under its name; returns the exit code."""
    color = argv[:1] == ["true"]
    args = argv[1:]
    git = os.environ.get("JSH_GIT_BIN", "git")

    def paint(code, text):
        return f"\033[{code}m{text}\033[0m" if color and code and text else text

    root = Path.cwd().resolve()
    repos = find(root, False)
    if not repos:
        print("fatal: not a git repository, and no repositories below it", file=sys.stderr)
        return 128
    mode = [] if "--show-current" in args else ["--list"]
    if not any(arg == "--no-color" or arg.startswith("--color") for arg in args):
        mode.append("--color=always" if color else "--no-color")

    def listing(repo):
        return git_output(git, repo, "branch", *mode, *args)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(listing, repos))
    if any(result.returncode == 129 for result in results):
        print("git branch: outside a repository, only listing options work", file=sys.stderr)
        return 129
    code = 0
    for repo, result in zip(repos, results):
        if not result.stdout.strip() and not result.stderr.strip():
            continue
        print(paint(COLORS["directory"], str(repo.relative_to(root))))
        for line in result.stdout.splitlines():
            print(INDENT + line)
        for line in result.stderr.strip().splitlines():
            print(INDENT + paint(COLORS["error"], line))
        code = code or result.returncode
    return code


if __name__ == "__main__":
    if sys.argv[1:2] == ["--branch"]:
        sys.exit(branches(sys.argv[2:]))
    sys.exit(main(sys.argv[1:]))
