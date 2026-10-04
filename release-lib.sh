#!/usr/bin/env bash
# Shared helpers for release candidates and promotion. Sourced, never run.
#
# The single copy for every Kubemoot repository. A workflow reaches it through
# $RELEASE_LIB, which the release-candidate-version and setup actions of this repository
# export; tests/test-release-lib.sh covers it.
#
# Versions: every push to main builds X.Y.Z-rc.N; a promotion tags the candidate's
# commit with the final <prefix>X.Y.Z. A tag is "<prefix><version>", for example
# agent-runtime-v0.342.32-rc.3 or v0.5.0.

# rl_is_rc VERSION: true when VERSION is a release candidate X.Y.Z-rc.N.
rl_is_rc() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]
}

# rl_is_final VERSION: true when VERSION is a final X.Y.Z.
rl_is_final() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# rl_final_of VERSION: X.Y.Z-rc.N -> X.Y.Z (a final version is returned unchanged).
rl_final_of() {
  printf '%s\n' "${1%-rc.*}"
}

# rl_hold_zero_major VERSION LAST_FINAL ALLOW_MAJOR: keeps a 0.x project at major 0.
# While the last final version (X.Y.Z; empty when none, which counts as 0.0.0) has
# major 0, a candidate that a breaking change bumped to a higher major becomes the next
# minor, 0.(Y+1).0-rc.N, the semver convention for 0.x. Leaving 0.x is a deliberate
# maintainer step (ALLOW_MAJOR=true), never the effect of a commit message. From 1.0
# on, and for anything that is not a candidate, VERSION is printed unchanged. A
# LAST_FINAL that is not X.Y.Z fails, so a bad base never picks a version.
rl_hold_zero_major() {
  local version="$1" last="${2:-0.0.0}" allow="$3"
  if ! rl_is_final "$last"; then
    echo "ERROR: last final version [${last}] is not X.Y.Z" >&2
    return 1
  fi
  local last_major last_minor
  IFS=. read -r last_major last_minor _ <<<"$last"
  if [ "$allow" = "true" ] || ! rl_is_rc "$version" \
    || [ "$((10#${last_major}))" -ne 0 ] || [ "${version%%.*}" = "0" ]; then
    printf '%s\n' "$version"
    return
  fi
  printf '0.%s.0-rc.%s\n' "$((10#${last_minor} + 1))" "${version##*-rc.}"
}

# rl_held_version PREFIX VERSION ALLOW_MAJOR [COMMIT]: rl_hold_zero_major against the
# component's last final <prefix>X.Y.Z tag reachable from COMMIT (default HEAD). An
# empty VERSION fails: semantic-version computed nothing.
rl_held_version() {
  local prefix="$1" version="$2" allow="$3" commit="${4:-HEAD}" last
  if [ -z "$version" ]; then
    echo "ERROR: no version computed for ${prefix}" >&2
    return 1
  fi
  last="$(rl_latest_final "$prefix" "$commit")"
  rl_hold_zero_major "$version" "${last#"${prefix}"}" "$allow"
}

# rl_release_needed PREFIX VERSION CHANGED FORCE: prints release_created=true|false for
# $GITHUB_OUTPUT (the reason goes to stderr). X.Y.Z-rc.N is built only while X.Y.Z is
# not yet promoted: a run on a promoted commit computes X.Y.Z-rc.0 of the final and
# must not release it.
rl_release_needed() {
  local prefix="$1" version="$2" changed="$3" force="$4"
  if ! rl_is_rc "$version"; then
    echo "Skipping: ${version} is not a release-candidate version" >&2
    echo "release_created=false"
  elif rl_tag_exists "${prefix}$(rl_final_of "$version")"; then
    echo "Skipping: ${prefix}$(rl_final_of "$version") is already a promoted release" >&2
    echo "release_created=false"
  elif [ "$changed" = "true" ] || [ "$force" = "true" ]; then
    echo "Will create release candidate ${prefix}${version}" >&2
    echo "release_created=true"
  else
    echo "Skipping: no commits since the last release" >&2
    echo "release_created=false"
  fi
}

# rl_tag_exists TAG: true when the tag exists locally (the caller fetched tags).
rl_tag_exists() {
  git rev-parse -q --verify "refs/tags/$1" >/dev/null
}

# rl_latest_rc PREFIX COMMIT: the highest <prefix>X.Y.Z-rc.N tag reachable from
# COMMIT, or nothing. sort -V orders rc.10 above rc.9 within the candidate tags.
rl_latest_rc() {
  local prefix="$1" commit="$2"
  git tag --merged "$commit" --list "${prefix}[0-9]*-rc.*" \
    | grep -E "^${prefix}[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$" \
    | sort -V | tail -n 1 || true
}

# rl_latest_final PREFIX COMMIT [EXCLUDE]: the highest final <prefix>X.Y.Z tag
# reachable from COMMIT, other than EXCLUDE, or nothing.
rl_latest_final() {
  local prefix="$1" commit="$2" exclude="${3:-}"
  git tag --merged "$commit" --list "${prefix}[0-9]*" \
    | grep -E "^${prefix}[0-9]+\.[0-9]+\.[0-9]+$" \
    | grep -vxF -- "${exclude:-/}" \
    | sort -V | tail -n 1 || true
}

# rl_next_chart_rc CURRENT FINAL_PROMOTED: the next release-candidate version of a
# chart whose version is a counter (the operator chart). CURRENT is the version in
# Chart.yaml; FINAL_PROMOTED is "true" when the final of CURRENT's X.Y.Z is tagged.
#   0.92.581            -> 0.92.582-rc.0  (a final: start the next patch)
#   0.92.582-rc.3 false -> 0.92.582-rc.4
#   0.92.582-rc.3 true  -> 0.92.583-rc.0  (0.92.582 was promoted)
rl_next_chart_rc() {
  local current="$1" promoted="$2" base major minor patch
  base=$(rl_final_of "$current")
  IFS=. read -r major minor patch <<<"$base"
  if rl_is_rc "$current" && [ "$promoted" != "true" ]; then
    printf '%s-rc.%s\n' "$base" "$(( ${current##*-rc.} + 1 ))"
  else
    printf '%s.%s.%s-rc.0\n' "$major" "$minor" "$(( patch + 1 ))"
  fi
}

# rl_is_version VERSION: true when VERSION is a final X.Y.Z or a candidate X.Y.Z-rc.N.
rl_is_version() {
  rl_is_final "$1" || rl_is_rc "$1"
}

# rl_stamp_chart CHART_DIR VERSION [APP_VERSION]: writes the version a build computed
# from the tags into CHART_DIR/Chart.yaml before the chart is packaged. Git holds
# 0.0.0; the build stamps its own copy and never commits it. Sets the top-level version
# to VERSION and appVersion to APP_VERSION (default VERSION), adding appVersion right
# after version when the chart has none; a chart whose images default their tag to
# .Chart.AppVersion needs nothing else. Indented version keys (dependencies) are left
# alone, and a comment on a stamped line is dropped. Both versions must be X.Y.Z or
# X.Y.Z-rc.N, and the chart needs exactly one top-level version and LF line endings;
# a refused stamp leaves the file unchanged.
rl_stamp_chart() {
  local dir="${1:-}" version="${2:-}" app="${3:-${2:-}}" chart="${1:-}/Chart.yaml" stamped
  if [ ! -f "$chart" ]; then
    echo "ERROR: no Chart.yaml in [${dir}]" >&2
    return 1
  fi
  if ! rl_is_version "$version" || ! rl_is_version "$app"; then
    echo "ERROR: chart version [${version}] and app version [${app}] must be X.Y.Z or X.Y.Z-rc.N" >&2
    return 1
  fi
  if [ "$(grep -c '^version:' "$chart")" -ne 1 ]; then
    echo "ERROR: ${chart} needs exactly one top-level version" >&2
    return 1
  fi
  if grep -q $'\r' "$chart"; then
    echo "ERROR: ${chart} has CRLF line endings" >&2
    return 1
  fi
  stamped="$(awk -v version="$version" -v app="$app" \
    -v has_app="$(grep -c '^appVersion:' "$chart")" '
    /^appVersion:/ { print "appVersion: " app; next }
    /^version:/ { print "version: " version; if (!has_app) print "appVersion: " app; next }
    { print }
  ' "$chart")" || return 1
  printf '%s\n' "$stamped" > "$chart"
  echo "Stamped ${chart}: version ${version}, appVersion ${app}" >&2
}

# Image pins. A values file in git references another repository's image with the tag
# 0.0.0 (name:0.0.0, or registry/path/name:0.0.0, bare or quoted); the build stamps the
# tag, so no version of that image is typed in git either.
RL_IMAGE_BEFORE="(^|[\"' /])"
RL_IMAGE_AFTER="([\"' ]|$)"

# rl_image_placeholders FILE: the names of the images FILE references with the tag
# 0.0.0, sorted, each once; nothing when there are none.
rl_image_placeholders() {
  if [ ! -f "${1:-}" ]; then
    echo "ERROR: no file [${1:-}]" >&2
    return 1
  fi
  { grep -oE "${RL_IMAGE_BEFORE}[a-z0-9][a-z0-9._-]*:0\.0\.0${RL_IMAGE_AFTER}" "$1" || true; } \
    | sed -E "s/^[\"' \/]//; s/:0\.0\.0.*$//" | sort -u
}

# rl_image_tag FILE NAME: the one tag FILE gives image NAME (any tag but 0.0.0). Fails
# when FILE has no such reference, or pins NAME with two different tags.
rl_image_tag() {
  local file="$1" name="$2" tags
  tags="$({ grep -oE "${RL_IMAGE_BEFORE}${name//./\\.}:[A-Za-z0-9._-]+" "$file" || true; } \
    | sed -E 's/^.*://' | grep -vxF 0.0.0 | sort -u)"
  if [ -z "$tags" ] || [ "$(wc -l <<<"$tags")" -ne 1 ]; then
    echo "ERROR: ${file} needs exactly one tag for image ${name}, has [${tags//$'\n'/ }]" >&2
    return 1
  fi
  printf '%s\n' "$tags"
}

# rl_stamp_image FILE NAME VERSION: writes VERSION as the tag of every NAME:0.0.0 image
# reference in FILE. VERSION must be X.Y.Z or X.Y.Z-rc.N. A FILE without a NAME:0.0.0
# reference is refused, so a typed version or a renamed image fails the build instead
# of shipping unstamped; a refused stamp leaves FILE unchanged.
rl_stamp_image() {
  local file="${1:-}" name="${2:-}" version="${3:-}" stamped
  if ! [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    echo "ERROR: [${name}] is not an image name" >&2
    return 1
  fi
  if ! rl_is_version "$version"; then
    echo "ERROR: image tag [${version}] must be X.Y.Z or X.Y.Z-rc.N" >&2
    return 1
  fi
  if ! rl_image_placeholders "$file" | grep -qxF -- "$name"; then
    echo "ERROR: [${file}] has no ${name}:0.0.0 image to stamp" >&2
    return 1
  fi
  stamped="$(sed -E "s#${RL_IMAGE_BEFORE}${name//./\\.}:0\.0\.0${RL_IMAGE_AFTER}#\1${name}:${version}\2#g" "$file")" \
    || return 1
  printf '%s\n' "$stamped" > "$file"
  echo "Stamped ${file}: ${name}:${version}" >&2
}

# rl_latest_remote_final REMOTE PREFIX: the highest final <prefix>X.Y.Z tag of the
# repository at REMOTE (a URL or a path), read with git ls-remote. Fails when REMOTE
# cannot be read or has no final tag with that prefix.
rl_latest_remote_final() {
  local remote="${1:-}" prefix="${2:-}" shown tags latest
  shown="$(sed -E 's#//[^/@]*@#//#' <<<"$remote")"
  if [ -z "$remote" ] || [ -z "$prefix" ]; then
    echo "ERROR: a remote and a tag prefix are required" >&2
    return 1
  fi
  if ! tags="$(git ls-remote --tags --refs "$remote" 2>/dev/null)"; then
    echo "ERROR: cannot read the tags of ${shown}" >&2
    return 1
  fi
  latest="$(awk '{ sub("^refs/tags/", "", $2); print $2 }' <<<"$tags" \
    | grep -E "^${prefix}[0-9]+\.[0-9]+\.[0-9]+$" | sort -V | tail -n 1 || true)"
  if [ -z "$latest" ]; then
    echo "ERROR: ${shown} has no final ${prefix}X.Y.Z tag" >&2
    return 1
  fi
  printf '%s\n' "$latest"
}

# rl_stamp_images_with FILE RESOLVER [ARGS...]: stamps every NAME:0.0.0 image in FILE
# with the tag `RESOLVER ARGS... NAME` prints. Every tag is resolved before FILE changes,
# so a name that cannot be resolved leaves FILE as it was. Prints "NAME TAG" per image.
rl_stamp_images_with() {
  local file="$1" resolver="$2" names name tag work pin
  shift 2
  names="$(rl_image_placeholders "$file")" || return 1
  local pins=()
  for name in $names; do
    tag="$("$resolver" "$@" "$name")" || return 1
    pins+=("${name} ${tag}")
  done
  work="$(mktemp)"
  cp "$file" "$work"
  for pin in "${pins[@]}"; do
    if ! rl_stamp_image "$work" "${pin% *}" "${pin#* }"; then
      rm -f "$work"
      return 1
    fi
  done
  cat "$work" > "$file"
  rm -f "$work"
  [ "${#pins[@]}" -eq 0 ] || printf '%s\n' "${pins[@]}"
}

_rl_remote_final_of() {
  local tag
  tag="$(rl_latest_remote_final "$1" "${2}-v")" || return 1
  printf '%s\n' "${tag#"${2}-v"}"
}

# rl_stamp_remote_images FILE REMOTE: stamps every NAME:0.0.0 image in FILE with the
# version of the latest final NAME-vX.Y.Z tag of the repository at REMOTE, so a chart
# pins only released images of another repository (Kubemoot's component images in a
# crew chart) and git holds none of their versions. Prints "NAME VERSION" per image; a
# file without placeholders is left alone.
rl_stamp_remote_images() {
  rl_stamp_images_with "$1" _rl_remote_final_of "$2"
}

# rl_stamp_images_like FILE REFERENCE: stamps every NAME:0.0.0 image in FILE with the
# tag REFERENCE (another values file, such as the one a tested release candidate was
# packaged with) gives the same image, so a promoted chart pins exactly the images its
# candidate ran. Prints "NAME TAG" per image; an image REFERENCE lacks fails.
rl_stamp_images_like() {
  if [ ! -f "${2:-}" ]; then
    echo "ERROR: no reference file [${2:-}]" >&2
    return 1
  fi
  rl_stamp_images_with "$1" rl_image_tag "$2"
}

# rl_resolve_point REF: the commit a promotion starts from. "latest" (or empty) is
# the tip of origin/main; otherwise REF must be a release-candidate tag on main.
rl_resolve_point() {
  local ref="${1:-latest}" commit
  if [ "$ref" = "latest" ]; then
    git rev-parse origin/main
    return
  fi
  if ! [[ "$ref" =~ -rc\.[0-9]+$ ]] || ! rl_tag_exists "$ref"; then
    echo "ERROR: ${ref} is not a release-candidate tag in this repository" >&2
    return 1
  fi
  commit=$(git rev-list -n 1 "$ref")
  if ! git merge-base --is-ancestor "$commit" origin/main; then
    echo "ERROR: ${ref} is not on main" >&2
    return 1
  fi
  printf '%s\n' "$commit"
}

# rl_notes_document PREV SRC FINAL [PATH]: the release body: the user-facing notes since
# PREV (limited to PATH when given), a single line when there are none, and a link to
# every commit when the repository is known (GITHUB_SERVER_URL and GITHUB_REPOSITORY, set
# in Actions).
rl_notes_document() {
  local prev="$1" src="$2" final="$3" notes
  notes="$(rl_release_notes "$prev" "$src" "${4:-}")"
  echo "## Changes${prev:+ since ${prev}}"
  echo
  if [ -n "$notes" ]; then printf '%s\n\n' "$notes"; else printf 'No user-facing changes: maintenance only.\n\n'; fi
  if [ -n "$prev" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    echo "All commits: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/compare/${prev}...${final}"
  fi
}

# rl_release_notes FROM TO [PATH]: Markdown notes for the people who use the release,
# from the conventional commits in FROM..TO (FROM empty: all history up to TO), limited to
# commits touching PATH when given. Only user-facing types appear: breaking changes,
# feat, fix, and perf, each as its description without the type prefix, plus docs when
# RL_NOTES_DOCS=true (a repository whose product is its documentation). Maintenance
# (ci, chore, docs elsewhere, test, build, refactor, style), fixes scoped to tests, CI,
# the build, or dependency bumps, [skip ci] commits, and every commit a bot authored
# (an author name ending in [bot]) are left out.
# Prints nothing when no commit in the range affects users.
rl_release_notes() {
  local from="$1" to="$2" range paths=()
  range="$to"
  [ -n "$from" ] && range="${from}..${to}"
  [ -n "${3:-}" ] && paths=(-- "$3")
  git log --no-merges --format='%h%x09%s%x09%an' "$range" "${paths[@]}" \
    | { grep -vF '[skip ci]' || true; } \
    | awk -F '\t' -v docs="${RL_NOTES_DOCS:-false}" '
        function add(section, desc) {
          desc = toupper(substr(desc, 1, 1)) substr(desc, 2)
          body[section] = body[section] "- " desc " (" $1 ")\n"
        }
        {
          if ($3 ~ /\[bot\]$/) next
          if (!match($2, /^[a-z]+(\([^)]*\))?!?: /)) next
          head = substr($2, 1, RLENGTH - 2); desc = substr($2, RLENGTH + 1)
          type = head; sub(/[(!].*/, "", type)
          scope = ""
          if (match(head, /\([^)]*\)/)) scope = substr(head, RSTART + 1, RLENGTH - 2)
          if (head ~ /!$/) { add("breaking", desc); next }
          if (scope ~ /^(test|tests|ci|build|deps|deps-dev|release)$/) next
          if (type == "feat") add("feat", desc)
          else if (type == "fix") add("fix", desc)
          else if (type == "perf") add("perf", desc)
          else if (type == "docs" && docs == "true") add("docs", desc)
        }
        END {
          split("breaking feat fix perf docs", order, " ")
          title["breaking"] = "Breaking changes"; title["feat"] = "New"
          title["fix"] = "Fixed"; title["perf"] = "Faster"; title["docs"] = "Documentation"
          for (i = 1; i <= 5; i++) {
            s = order[i]
            if (body[s] != "") printf "### %s\n\n%s\n", title[s], body[s]
          }
        }'
}

# Promotion bookkeeping. DRY_RUN="true" (the default) records what would happen and
# changes nothing: no tag, no push.
RL_NEW_TAGS=()
RL_NEW_TAG_SOURCES=()
RL_WORKTREES=()

rl_is_dry() {
  [ "${DRY_RUN:-true}" = "true" ]
}

# rl_make_tag FINAL_TAG FROM_TAG: plan an annotated final tag on FROM_TAG's commit.
# Nothing is created until rl_push_new_tags, so a run that stops early leaves no tag.
rl_make_tag() {
  RL_NEW_TAGS+=("$1")
  RL_NEW_TAG_SOURCES+=("$2")
}

# rl_push_new_tags: create every planned tag and push them all or none. A rejected
# push deletes the local tags again, so a re-run starts from the same state.
rl_push_new_tags() {
  local i
  echo "Final tags: ${RL_NEW_TAGS[*]:-none}"
  rl_is_dry && return 0
  [ "${#RL_NEW_TAGS[@]}" -gt 0 ] || return 0
  for i in "${!RL_NEW_TAGS[@]}"; do
    git tag -a "${RL_NEW_TAGS[$i]}" -m "Release ${RL_NEW_TAGS[$i]} (promoted from ${RL_NEW_TAG_SOURCES[$i]})" \
      "$(git rev-list -n 1 "${RL_NEW_TAG_SOURCES[$i]}")"
  done
  if ! git push --atomic origin "${RL_NEW_TAGS[@]/#/refs/tags/}"; then
    git tag -d "${RL_NEW_TAGS[@]}" >/dev/null
    echo "ERROR: pushing the final tags failed; none was created" >&2
    return 1
  fi
}

# rl_checkout_at COMMIT: a scratch worktree of COMMIT, its path in RL_CHECKOUT (call it
# directly, not in $(...), so rl_remove_worktrees can find it).
rl_checkout_at() {
  RL_CHECKOUT="$(mktemp -d)/src"
  git worktree add --quiet --detach "$RL_CHECKOUT" "$1"
  RL_WORKTREES+=("$RL_CHECKOUT")
}

rl_remove_worktrees() {
  local wt
  for wt in "${RL_WORKTREES[@]}"; do git worktree remove --force "$wt" 2>/dev/null || true; done
  return 0
}

# rl_add_release OUT_DIR TAG TITLE NOTES_FILE: one line of OUT_DIR/releases.tsv, which
# the workflow's release job turns into GitHub Releases (NOTES_FILE is relative to OUT_DIR).
rl_add_release() {
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$1/releases.tsv"
}

# rl_promote_single PREFIX TITLE OUT_DIR: promote the latest release candidate of a
# repository with one version stream (kmctl, kubemoot-docs), up to RC_TAG ("latest"
# or a candidate tag on main). Plans the final <prefix>X.Y.Z tag on the candidate's
# commit, writes OUT_DIR/notes.md and OUT_DIR/releases.tsv, pushes the tag unless
# DRY_RUN, and prints final_tag=, previous_tag=, and commit= lines for $GITHUB_OUTPUT
# (everything else goes to stderr).
rl_promote_single() {
  local prefix="$1" title="$2" out="$3" point rc_tag final src prev
  point=$(rl_resolve_point "${RC_TAG:-latest}") || return 1
  rc_tag=$(rl_latest_rc "$prefix" "$point")
  if [ -z "$rc_tag" ]; then
    echo "ERROR: no ${prefix}X.Y.Z-rc.N tag at or before ${RC_TAG:-latest}" >&2
    return 1
  fi
  final="${prefix}$(rl_final_of "${rc_tag#"$prefix"}")"
  if rl_tag_exists "$final"; then
    echo "ERROR: ${final} is already released" >&2
    return 1
  fi
  src=$(git rev-list -n 1 "$rc_tag")
  prev=$(rl_latest_final "$prefix" "$src")
  echo "Promoting ${rc_tag} (commit ${src}) to ${final}; dry run: ${DRY_RUN:-true}" >&2
  mkdir -p "$out"
  rl_notes_document "$prev" "$src" "$final" > "${out}/notes.md"
  : > "${out}/releases.tsv"
  rl_add_release "$out" "$final" "${title} ${final#"$prefix"}" notes.md
  rl_make_tag "$final" "$rc_tag"
  rl_push_new_tags >&2
  printf 'final_tag=%s\nprevious_tag=%s\ncommit=%s\n' "$final" "$prev" "$src"
}
