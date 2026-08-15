# mkApp { name; runtimeInputs; excludeShellChecks; text; } -> a flake app.
#
# Every app gets the same prelude:
#   - writeShellApplication's own errexit/nounset/pipefail
#   - a trap naming the command that failed, so no app has to narrate its own
#     progress to be debuggable
#   - the repo root as both cwd and $REPO_ROOT, so relative paths like
#     secrets/foo.age work wherever the app was invoked from
{ pkgs }:

{
  name,
  runtimeInputs ? [ ],
  excludeShellChecks ? [ ],
  text,
}:

pkgs.writeShellApplication {
  inherit name runtimeInputs excludeShellChecks;
  text = ''
    trap 'echo "FAILED: line $LINENO: $BASH_COMMAND" >&2' ERR
    # Fail loudly rather than fall back to $PWD: every app here reads repo
    # files, and silently operating on whatever directory you happened to be
    # in is worse than refusing.
    # shellcheck disable=SC2034
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$REPO_ROOT" ]; then
      echo "FATAL: not inside the nixos-config checkout" >&2
      exit 1
    fi
    cd "$REPO_ROOT"
  ''
  + text;
}
