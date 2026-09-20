"""Attest an exact merged client revision against the trusted storage policy.

Run this script from a clean, protected-main checkout, never from the candidate.
It does not publish an app or claim to prevent manual uploads or sideloads.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess


CUTOVER_COMMIT = "01acb77f2d6ab93450b42415e0ec6faac44e9ed2"
SUPPORTED_CONTRACT = {
    "format_version": 1,
    "storage_protocol": 2,
    "rollback_policy": "forward-only",
}


class IncompatibleRelease(ValueError):
    """The candidate cannot be a production release or rollback."""


def git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False, capture_output=True, text=True, encoding="utf-8",
    )
    if result.returncode:
        raise IncompatibleRelease("Git object or ancestry unavailable")
    return result.stdout.strip()


def check_candidate(
    repository: Path, candidate: str, trusted_main: str,
    *, cutover: str = CUTOVER_COMMIT,
) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", candidate):
        raise IncompatibleRelease("Candidate must be an exact full commit SHA")
    if git(repository, "rev-parse", f"{candidate}^{{commit}}") != candidate:
        raise IncompatibleRelease("Candidate is not a commit")
    try:
        git(repository, "merge-base", "--is-ancestor", cutover, candidate)
    except IncompatibleRelease as error:
        raise IncompatibleRelease("Candidate predates the SQLite cutover") from error
    try:
        git(repository, "merge-base", "--is-ancestor", candidate, trusted_main)
    except IncompatibleRelease as error:
        raise IncompatibleRelease("Candidate is not merged into trusted main") from error
    try:
        contract = json.loads(git(
            repository, "show", f"{candidate}:release/storage_contract.json",
        ))
    except (IncompatibleRelease, ValueError) as error:
        raise IncompatibleRelease("Candidate has no valid storage contract") from error
    if contract != SUPPORTED_CONTRACT:
        raise IncompatibleRelease("Candidate storage protocol is unsupported")
    return {
        "candidate_commit": candidate,
        "candidate_tree": git(repository, "rev-parse", f"{candidate}^{{tree}}"),
        "trusted_policy_commit": trusted_main,
        "sqlite_cutover_commit": cutover,
        "storage_contract": contract,
        "eligible": True,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    try:
        trusted_main = git(repository, "rev-parse", "HEAD")
        if trusted_main != git(repository, "rev-parse", "origin/main"):
            raise IncompatibleRelease("Run the policy from fetched protected main")
        if git(repository, "status", "--porcelain", "--untracked-files=no"):
            raise IncompatibleRelease("Trusted policy checkout must be clean")
        result = check_candidate(repository, args.candidate, trusted_main)
    except IncompatibleRelease as error:
        parser.exit(1, f"Release rejected: {error}\n")
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Storage-compatible merged candidate: {result['candidate_commit']}")


if __name__ == "__main__":
    main()
