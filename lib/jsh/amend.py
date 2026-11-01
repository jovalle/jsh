"""Move commit timestamps while preserving commit contents and the working tree."""

import subprocess
import sys
from pathlib import Path


def run(git, *args, data=None):
    return subprocess.run(
        [git, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True
    ).stdout


def rewrite(git, target, timestamp, single):  # pylint: disable=too-many-locals,too-many-branches
    branch = run(git, "symbolic-ref", "-q", "HEAD").strip().decode()
    head = run(git, "rev-parse", "--verify", "HEAD").strip().decode()
    for state in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
        path = run(git, "rev-parse", "--git-path", state).strip().decode()
        if Path(path).exists():
            raise ValueError(f"finish the current Git operation first ({state})")
    history = run(git, "rev-list", "--first-parent", "--reverse", head).decode().splitlines()
    if target not in history:
        raise ValueError("commit is not on the current branch's first-parent history")
    position = history.index(target)
    commits = history[position:]
    objects = []
    for commit in commits:
        raw = run(git, "cat-file", "commit", commit)
        headers, message = raw.split(b"\n\n", 1)
        lines = headers.split(b"\n")
        parents = [line[7:].decode() for line in lines if line.startswith(b"parent ")]
        if len(parents) > 1:
            raise ValueError("cannot rewrite merge commits")
        if any(line.startswith((b"gpgsig ", b"gpgsig-sha256 ", b"mergetag ")) for line in lines):
            raise ValueError("cannot rewrite signed commits or merge tags")
        committer = next(line for line in lines if line.startswith(b"committer "))
        objects.append((lines, message, int(committer.rsplit(b" ", 2)[1])))

    delta = timestamp - objects[0][2]
    previous = None
    if position:
        previous = int(run(git, "show", "-s", "--format=%ct", history[position - 1]).strip())
    for index, (_, _, old_time) in enumerate(objects):
        new_time = old_time + (delta if not single or index == 0 else 0)
        if previous is not None and new_time < previous:
            raise ValueError("new timestamp would put a commit before its parent")
        previous = new_time

    parent = None
    for index, (lines, message, _) in enumerate(objects):
        changed = []
        shift = delta if not single or index == 0 else 0
        for line in lines:
            if parent is not None and line.startswith(b"parent "):
                line = b"parent " + parent.encode()
            elif shift and line.startswith((b"author ", b"committer ")):
                identity, seconds, zone = line.rsplit(b" ", 2)
                line = b" ".join((identity, str(int(seconds) + shift).encode(), zone))
            changed.append(line)
        parent = (
            run(
                git,
                "hash-object",
                "-t",
                "commit",
                "-w",
                "--stdin",
                data=b"\n".join(changed) + b"\n\n" + message,
            )
            .strip()
            .decode()
        )
    run(git, "update-ref", "-m", "amend: move commit timestamps", branch, parent, head)
    print(f"Moved {1 if single else len(commits)} commit timestamp(s).")


if __name__ == "__main__":
    try:
        rewrite(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1")
    except (ValueError, StopIteration, subprocess.CalledProcessError) as error:
        print(f"git amend: {error}", file=sys.stderr)
        sys.exit(1)
