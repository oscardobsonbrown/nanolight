"""Select a release tag and write notes for the commits it adds."""

import json
import os
import re
import subprocess
import sys


FIRST_TAG = "v0.3.0"
FORK_BASE = "de4833e7ce3c9c385a2dfd117913276e2f774c10"


def run(*command):
    return subprocess.check_output(command, text=True).rstrip("\n")


def git(*args):
    return run("git", *args)


def github(path):
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", path))
    return [item for page in pages for item in page]


def next_tag(previous, target, tags):
    if previous:
        parts = previous.removeprefix("v").split(".")
        major, minor, patch = map(int, parts)
        patch += 1
    else:
        major, minor, patch = map(int, FIRST_TAG[1:].split("."))
    while True:
        tag = f"v{major}.{minor}.{patch}"
        if tag not in tags or tags[tag] == target:
            return tag
        patch += 1


def plan(repo, target):
    releases = github(f"repos/{repo}/releases?per_page=100")
    stable = [
        release["tag_name"]
        for release in releases
        if not release["draft"] and not release["prerelease"]
        and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", release["tag_name"])
    ]
    previous = max(stable, key=lambda tag: tuple(map(int, tag[1:].split("."))), default="")
    base = previous or FORK_BASE
    if subprocess.run(["git", "merge-base", "--is-ancestor", target, base], check=False).returncode == 0:
        print("The target commit is already covered.")
        return
    if git("rev-parse", f"{base}^{{tree}}") == git("rev-parse", f"{target}^{{tree}}"):
        print("The release tree has no changes.")
        return

    tags = {}
    for line in git("for-each-ref", "--format=%(refname:short) %(objectname) %(*objectname)", "refs/tags").splitlines():
        tag, sha, *peeled = line.split()
        tags[tag] = peeled[0] if peeled else sha
    tag = next_tag(previous, target, tags)
    print(f"Release candidate {tag} at {target}")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        print(f"tag={tag}\nprevious={previous}", file=output)


def markdown(text):
    return re.sub(r"([\\\[\]<>`*_~])", r"\\\1", " ".join(text.split()))


def note_lines(commits, pulls, repo, base, target):
    positions = {sha: index for index, (sha, _, _) in enumerate(commits)}
    merged = sorted(
        (pr for pr in pulls if pr["merged_at"] and pr["merge_commit_sha"] in positions),
        key=lambda pr: positions[pr["merge_commit_sha"]],
    )
    covered = set()
    for pr in merged:
        sha = pr["merge_commit_sha"]
        covered.add(sha)
        if len(commits[positions[sha]][1].split()) > 1:
            covered.update(git("rev-list", f"{sha}^1..{sha}").splitlines())
        author = "@" + pr["user"]["login"] if pr["user"] else "a deleted account"
        yield f"- {markdown(pr['title'])} by {author} in [#{pr['number']}]({pr['html_url']})"
    for sha, parents, subject in commits:
        if sha not in covered and len(parents.split()) <= 1:
            yield f"- {markdown(subject)} ([`{sha[:7]}`](https://github.com/{repo}/commit/{sha}))"
    yield ""
    yield f"[Full change history](https://github.com/{repo}/compare/{base}...{target})"


def notes(repo, target):
    base = os.environ.get("PREVIOUS") or FORK_BASE
    commits = [
        line.split("\t", 2)
        for line in git("log", "--reverse", "--format=%H%x09%P%x09%s", f"{base}..{target}").splitlines()
    ]
    pulls = [
        pr for branch in ("dev", "main")
        for pr in github(f"repos/{repo}/pulls?state=closed&base={branch}&per_page=100")
    ]
    print("## What's changed\n")
    for line in note_lines(commits, pulls, repo, base, target):
        print(line)


if __name__ == "__main__":
    {"plan": plan, "notes": notes}[sys.argv[1]](os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"])
