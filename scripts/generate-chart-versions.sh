#!/usr/bin/env bash
# Compute each component/CRD chart's own nightly version: its latest real
# (non-nightly) release tag plus the shared nightly suffix. Used by the
# nightly-build workflow so every chart's version reflects its actual
# release history instead of inheriting one invented umbrella version.
#
# Requires the following environment variables to be set:
#   NIGHTLY_SUFFIX  e.g. "nightly.20260709.0d44e56.3"
#   CRD_CHARTS      e.g. "chart_name:submodule_path:chart_path ..."
#   COMPONENTS      e.g. "component:image:submodule_path:mode:chart_path ..."
#
# Writes chart-versions.txt to the current working directory, one line per
# chart: "<name>=<version>|<source_tag>|<source_sha>". The source tag/sha
# are exposed (not just the final version) so callers like the images.txt
# step can reuse the already-resolved, shallow-clone-safe values instead
# of re-running `git describe` themselves.

set -euo pipefail

: "${NIGHTLY_SUFFIX:?NIGHTLY_SUFFIX must be set}"
: "${CRD_CHARTS:?CRD_CHARTS must be set}"
: "${COMPONENTS:?COMPONENTS must be set}"

chart_info_for_path() {
  local path=$1
  local tag sha
  # actions/checkout clones submodules shallow (depth 1) even when the
  # superproject uses fetch-depth: 0. A shallow clone has no ancestor
  # history for `describe` to walk, so fetching tag refs alone isn't
  # enough — the submodule needs to be unshallowed too, or `describe`
  # silently fails. `--unshallow` errors on an already-complete repo,
  # so only use it when needed.
  if [[ "$(git -C "${path}" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    git -C "${path}" fetch --unshallow --tags --quiet 2>/dev/null || true
  else
    git -C "${path}" fetch --tags --quiet 2>/dev/null || true
  fi
  # Fail loudly rather than silently guessing a version: publishing a
  # chart under a made-up placeholder tag would be worse than failing
  # the build, since it could get pushed to the registry unnoticed.
  # --match restricts to plain "vX.Y.Z"-shaped tags: some component repos
  # (e.g. osac-operator) also carry a separate "api/vX.Y.Z" tag namespace
  # (Go API module versioning) that `describe` would otherwise pick up if
  # it happens to be nearer HEAD than the real chart-release tag. --match
  # is still a glob, not a real anchor (its trailing '*' is needed to
  # allow multi-digit version segments, but that same '*' would also
  # accept a stray "-rc1"/".4" suffix) so re-validate with a real regex.
  if ! tag=$(git -C "${path}" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-nightly*' 2>/dev/null); then
    echo "ERROR: no real (non-nightly) release tag reachable from ${path} — refusing to guess a version" >&2
    exit 1
  fi
  if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: nearest release tag '${tag}' reachable from ${path} is not a plain vX.Y.Z tag — refusing to guess a version" >&2
    exit 1
  fi
  sha=$(git -C "${path}" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
  echo "${tag}|${sha}"
}

: > chart-versions.txt
for entry in ${CRD_CHARTS}; do
  chart_name="${entry%%:*}"
  rest="${entry#*:}"
  submodule_path="${rest%%:*}"
  info=$(chart_info_for_path "${submodule_path}")
  src_tag="${info%|*}"
  src_sha="${info#*|}"
  version="${src_tag#v}-${NIGHTLY_SUFFIX}"
  echo "${chart_name}=${version}|${src_tag}|${src_sha}" >> chart-versions.txt
done
for entry in ${COMPONENTS}; do
  component="${entry%%:*}"
  rest="${entry#*:}"
  rest="${rest#*:}"
  submodule_path="${rest%%:*}"
  info=$(chart_info_for_path "${submodule_path}")
  src_tag="${info%|*}"
  src_sha="${info#*|}"
  version="${src_tag#v}-${NIGHTLY_SUFFIX}"
  echo "${component}=${version}|${src_tag}|${src_sha}" >> chart-versions.txt
done

echo "--- Per-chart versions ---"
cat chart-versions.txt
