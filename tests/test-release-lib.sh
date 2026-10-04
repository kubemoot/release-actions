#!/usr/bin/env bash
# Tests for release-lib.sh against a throwaway git repository.
# Usage: bash tests/test-release-lib.sh   (exit 0 = all passed)
set -euo pipefail

lib="$(cd "$(dirname "$0")/.." && pwd)/release-lib.sh"
# shellcheck source-path=SCRIPTDIR source=../release-lib.sh
source "${lib}"

failures=0
check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: want [${want}] got [${got}]"
    failures=$((failures + 1))
  fi
}
check_status() {
  local name="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  [ "$got" -ne 0 ] && got=1
  check "$name" "$want" "$got"
}

# Pure functions: expected and unexpected inputs.
check_status "rc is rc" 0 rl_is_rc 0.1.2-rc.3
check_status "final is not rc" 1 rl_is_rc 0.1.2
check_status "rc without number is not rc" 1 rl_is_rc 0.1.2-rc
check_status "other pre-release is not rc" 1 rl_is_rc 0.1.2-beta.1
check_status "prefixed tag is not a version" 1 rl_is_rc v0.1.2-rc.1
check "final of rc" "0.1.2" "$(rl_final_of 0.1.2-rc.11)"
check "final of final" "0.1.2" "$(rl_final_of 0.1.2)"
check "breaking change on 0.x bumps the minor" "0.345.0-rc.2" "$(rl_hold_zero_major 1.0.0-rc.2 0.344.0 false)"
check "breaking change before any final" "0.1.0-rc.0" "$(rl_hold_zero_major 1.0.0-rc.0 "" false)"
check "minor bump on 0.x unchanged" "0.345.0-rc.1" "$(rl_hold_zero_major 0.345.0-rc.1 0.344.0 false)"
check "patch bump on 0.x unchanged" "0.344.1-rc.3" "$(rl_hold_zero_major 0.344.1-rc.3 0.344.0 false)"
check "leaving 0.x when allowed" "1.0.0-rc.0" "$(rl_hold_zero_major 1.0.0-rc.0 0.344.0 true)"
check "allow is exactly true" "0.345.0-rc.0" "$(rl_hold_zero_major 1.0.0-rc.0 0.344.0 yes)"
check "major bump after 1.0 unchanged" "2.0.0-rc.1" "$(rl_hold_zero_major 2.0.0-rc.1 1.4.2 false)"
check "non-candidate unchanged" "1.0.0" "$(rl_hold_zero_major 1.0.0 0.344.0 false)"
check "fix before any final" "0.0.1-rc.0" "$(rl_hold_zero_major 0.0.1-rc.0 "" false)"
check "breaking after a patch release" "0.345.0-rc.1" "$(rl_hold_zero_major 1.0.0-rc.1 0.344.5 false)"
check "two-digit rc counter kept" "0.345.0-rc.10" "$(rl_hold_zero_major 1.0.0-rc.10 0.344.0 false)"
check "candidate already on the next minor" "0.345.0-rc.3" "$(rl_hold_zero_major 0.345.0-rc.3 0.344.0 false)"
check "candidate of the promoted final unchanged" "0.344.0-rc.0" "$(rl_hold_zero_major 0.344.0-rc.0 0.344.0 false)"
check "zero-padded minor is decimal" "0.9.0-rc.2" "$(rl_hold_zero_major 1.0.0-rc.2 0.08.0 false)"
check "empty allow holds" "0.345.0-rc.0" "$(rl_hold_zero_major 1.0.0-rc.0 0.344.0 "")"
check "empty version unchanged" "" "$(rl_hold_zero_major "" 0.344.0 false)"
check_status "malformed last final fails" 1 rl_hold_zero_major 1.0.0-rc.0 0.x false
check_status "prefixed last final fails" 1 rl_hold_zero_major 1.0.0-rc.0 v0.344.0 false
check_status "empty computed version fails" 1 rl_held_version v "" false
check "next chart rc from a final" "0.92.582-rc.0" "$(rl_next_chart_rc 0.92.581 false)"
check "next chart rc counts up" "0.92.582-rc.4" "$(rl_next_chart_rc 0.92.582-rc.3 false)"
check "next chart rc 9 -> 10" "0.92.582-rc.10" "$(rl_next_chart_rc 0.92.582-rc.9 false)"
check "next chart rc after promotion" "0.92.583-rc.0" "$(rl_next_chart_rc 0.92.582-rc.3 true)"

check_status "final is final" 0 rl_is_final 0.1.2
check_status "rc is not final" 1 rl_is_final 0.1.2-rc.3
check_status "prefixed final is not final" 1 rl_is_final v0.1.2
check_status "final is a version" 0 rl_is_version 0.1.2
check_status "rc is a version" 0 rl_is_version 0.1.2-rc.3
check_status "prefixed tag is not a version" 1 rl_is_version v0.1.2
check_status "two-part version is not a version" 1 rl_is_version 0.1
check_status "other pre-release is not a version" 1 rl_is_version 0.1.2-beta.1
check_status "empty is not a version" 1 rl_is_version ""

# rl_stamp_chart: a chart as git holds it (0.0.0), with a dependency whose version
# must stay, and a chart without appVersion.
charts="$(mktemp -d)"
chart_yaml() {
  printf '%s\n' "apiVersion: v2" "name: demo" "# set at build from the git tags" \
    "version: 0.0.0" "appVersion: 0.0.0" "dependencies:" "  - name: sub" "    version: 1.2.3" \
    "    repository: oci://example.com/charts"
}
fresh_chart() { rm -rf "$charts/demo"; mkdir -p "$charts/demo"; chart_yaml > "$charts/demo/Chart.yaml"; }
field() { sed -n "s/^$1: //p" "$charts/demo/Chart.yaml"; }

fresh_chart
check_status "stamp an rc" 0 rl_stamp_chart "$charts/demo" 0.17.2-rc.3
check "rc version stamped" "0.17.2-rc.3" "$(field version)"
check "rc appVersion follows the version" "0.17.2-rc.3" "$(field appVersion)"
check "dependency version untouched" "1" "$(grep -c '^    version: 1.2.3$' "$charts/demo/Chart.yaml")"
check "other lines untouched" "$(chart_yaml | grep -v -e '^version:' -e '^appVersion:')" \
  "$(grep -v -e '^version:' -e '^appVersion:' "$charts/demo/Chart.yaml")"
check_status "stamp the final over the rc" 0 rl_stamp_chart "$charts/demo" 0.17.2
check "final version stamped" "0.17.2" "$(field version)"
check "final appVersion stamped" "0.17.2" "$(field appVersion)"
check "one version line after two stamps" "1" "$(grep -c '^version:' "$charts/demo/Chart.yaml")"
fresh_chart
rl_stamp_chart "$charts/demo" 0.5.0-rc.1 0.342.32 2>/dev/null
check "app version given separately" "0.5.0-rc.1|0.342.32" "$(field version)|$(field appVersion)"
printf '%s\n' "apiVersion: v2" "name: demo" "version: 0.0.0" "" "keywords:" "  - demo" > "$charts/demo/Chart.yaml"
rl_stamp_chart "$charts/demo" 1.0.0 2>/dev/null
check "missing appVersion is added" "1.0.0|1" "$(field appVersion)|$(grep -c '^appVersion:' "$charts/demo/Chart.yaml")"
check "missing appVersion lands after version" "appVersion: 1.0.0" "$(sed -n 4p "$charts/demo/Chart.yaml")"
printf '%s\n' "apiVersion: v2" "name: demo" "version: 0.0.0 # stamped at build" > "$charts/demo/Chart.yaml"
rl_stamp_chart "$charts/demo" 1.0.0 2>/dev/null
check "a comment on a stamped line is dropped" "1.0.0" "$(field version)"

fresh_chart
for bad in v0.17.2 0.17 0.17.2-beta.1 0.17.2-rc "" "0.17.2; rm -rf /"; do
  check_status "stamp refuses version [${bad}]" 1 rl_stamp_chart "$charts/demo" "$bad"
done
check_status "stamp refuses a malformed app version" 1 rl_stamp_chart "$charts/demo" 0.17.2 latest
check_status "stamp refuses a missing version argument" 1 rl_stamp_chart "$charts/demo"
check_status "stamp refuses no arguments" 1 rl_stamp_chart
check "a refused stamp leaves the chart unchanged" "$(chart_yaml)" "$(< "$charts/demo/Chart.yaml")"
check_status "stamp refuses a missing chart directory" 1 rl_stamp_chart "$charts/none" 0.17.2
mkdir -p "$charts/empty"
check_status "stamp refuses a directory without Chart.yaml" 1 rl_stamp_chart "$charts/empty" 0.17.2
printf '%s\n' "apiVersion: v2" "name: demo" "dependencies:" "  - name: sub" "    version: 1.2.3" \
  > "$charts/demo/Chart.yaml"
check_status "stamp refuses a chart without a top-level version" 1 rl_stamp_chart "$charts/demo" 0.17.2
check "a chart without a version stays unchanged" "0" "$(grep -c 'appVersion' "$charts/demo/Chart.yaml")"
printf '%s\n' "apiVersion: v2" "version: 0.0.0" "name: demo" "version: 0.0.0" > "$charts/demo/Chart.yaml"
check_status "stamp refuses two top-level versions" 1 rl_stamp_chart "$charts/demo" 0.17.2
printf 'apiVersion: v2\r\nname: demo\r\nversion: 0.0.0\r\n' > "$charts/demo/Chart.yaml"
check_status "stamp refuses CRLF line endings" 1 rl_stamp_chart "$charts/demo" 0.17.2
check "a CRLF chart stays unchanged" "1" "$(grep -c '^version: 0.0.0' "$charts/demo/Chart.yaml")"
rm -rf "$charts"

# rl_release_needed: expected and unexpected inputs (tags checked in the repo below).
needed() { rl_release_needed "$@" 2>/dev/null; }

# Git-backed functions.
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main
git config user.email test@example.com
git config user.name test
commit() { git commit -q --allow-empty -m "$1"; git rev-parse HEAD; }

c0=$(commit "chore: init")
git tag -a v0.1.0 -m final "$c0"
c1=$(commit "feat: add widgets")
git tag -a v0.2.0-rc.0 -m rc "$c1"
commit "chore: update chart [skip ci]" >/dev/null
c3=$(commit "fix(api): handle empty input")
git tag -a v0.2.0-rc.9 -m rc "$c3"
c4=$(commit "feat!: rename the field")
git tag -a v0.2.0-rc.10 -m rc "$c4"
git tag -a agent-v0.9.0-rc.1 -m rc "$c4"
git update-ref refs/remotes/origin/main "$c4"

check "latest rc sorts rc.10 above rc.9" "v0.2.0-rc.10" "$(rl_latest_rc v "$c4")"
check "latest rc at an older commit" "v0.2.0-rc.9" "$(rl_latest_rc v "$c3")"
check "latest rc ignores other prefixes" "agent-v0.9.0-rc.1" "$(rl_latest_rc agent-v "$c4")"
check "latest rc with none" "" "$(rl_latest_rc other-v "$c4")"
check "latest final ignores rcs" "v0.1.0" "$(rl_latest_final v "$c4")"
git tag -a v0.2.0 -m final "$c4"
check "latest final excluding the new one" "v0.1.0" "$(rl_latest_final v "$c4" v0.2.0)"
check "latest final" "v0.2.0" "$(rl_latest_final v "$c4")"
check "held version reads the prefix's last final" "0.3.0-rc.1" "$(rl_held_version v 1.0.0-rc.1 false "$c4")"
check "held version per component" "0.1.0-rc.1" "$(rl_held_version agent-v 1.0.0-rc.1 false "$c4")"
git tag -a agent-v0.9.0 -m final "$c4"
check "held version after a component final" "0.10.0-rc.2" "$(rl_held_version agent-v 1.0.0-rc.2 false "$c4")"
check "held version when allowed" "1.0.0-rc.2" "$(rl_held_version agent-v 1.0.0-rc.2 true "$c4")"
check_status "tag exists" 0 rl_tag_exists v0.2.0
check_status "tag missing" 1 rl_tag_exists v9.9.9

check "release needed for a new candidate" "release_created=true" "$(needed v 0.3.0-rc.1 true false)"
check "no release without changes" "release_created=false" "$(needed v 0.3.0-rc.1 false false)"
check "forced release without changes" "release_created=true" "$(needed v 0.3.0-rc.1 false true)"
check "no candidate of a promoted version" "release_created=false" "$(needed v 0.2.0-rc.0 true true)"
check "no release of a non-candidate version" "release_created=false" "$(needed v 0.3.0 true true)"
check "no release of an empty version" "release_created=false" "$(needed v "" true true)"

check "resolve latest" "$c4" "$(rl_resolve_point latest)"
check "resolve an rc tag" "$c3" "$(rl_resolve_point v0.2.0-rc.9)"
check_status "resolve refuses a final tag" 1 rl_resolve_point v0.2.0
check_status "resolve refuses a missing tag" 1 rl_resolve_point v7.0.0-rc.1
git checkout -q -b side "$c0"
c5=$(commit "fix: off main")
git tag -a v0.1.1-rc.0 -m rc "$c5"
check_status "resolve refuses an rc off main" 1 rl_resolve_point v0.1.1-rc.0
git checkout -q main

notes="$(rl_release_notes v0.1.0 "$c4")"
check "notes breaking section" "1" "$(grep -c '^### Breaking changes' <<<"$notes")"
check "notes breaking entry drops the prefix" "1" "$(grep -c '^- Rename the field (' <<<"$notes")"
check "notes feature under New" "1" "$(grep -A2 '^### New' <<<"$notes" | grep -c '^- Add widgets (')"
check "notes scoped fix drops the prefix" "1" "$(grep -c '^- Handle empty input (' <<<"$notes")"
check "notes never show a type prefix" "0" "$(grep -cE '^- (feat|fix|perf)' <<<"$notes" || true)"
check "notes leave out bot commits" "0" "$(grep -c 'skip ci' <<<"$notes" || true)"
check "notes range excludes the base" "0" "$(grep -ci 'init' <<<"$notes" || true)"
bot=$(commit "chore: update chart [skip ci]")
check_status "notes over bot commits only succeed" 0 rl_release_notes "$c4" "$bot"
check "notes over bot commits only are empty" "" "$(rl_release_notes "$c4" "$bot")"
check "notes with no base include features" "1" "$(rl_release_notes "" "$c4" | grep -c '^- Add widgets (')"
check "notes with no base leave out chores" "0" "$(rl_release_notes "" "$c4" | grep -ci 'init' || true)"
m0=$(git rev-parse HEAD)
for subject in "ci: tune the runner" "docs: reword the contributing guide" "test: cover the parser" \
  "build: bump the toolchain" "refactor: split the module" "chore(deps): bump a library" \
  "fix(test): flaky wait" "fix(ci): pin an action" "fix(deps): bump a library" "Merge-like subject without a type"; do
  commit "$subject" >/dev/null
done
check "notes leave out maintenance" "" "$(rl_release_notes "$m0" HEAD)"
m1=$(git rev-parse HEAD)
commit "perf: answer twice as fast" >/dev/null
commit "fix(ui): keep the selection" >/dev/null
maint="$(rl_release_notes "$m1" HEAD)"
check "notes perf section" "1" "$(grep -c '^### Faster' <<<"$maint")"
check "notes user-facing scoped fix kept" "1" "$(grep -c '^- Keep the selection (' <<<"$maint")"
check "notes leave out docs by default" "0" "$(rl_release_notes "$m0" "$m1" | grep -c 'Reword the contributing guide' || true)"
docnotes="$(RL_NOTES_DOCS=true rl_release_notes "$m0" "$m1")"
check "notes include docs when the docs are the product" "1" "$(grep -A2 '^### Documentation' <<<"$docnotes" | grep -c '^- Reword the contributing guide (')"
check "docs notes still leave out other maintenance" "0" "$(grep -ciE 'tune the runner|cover the parser|split the module' <<<"$docnotes" || true)"
check "notes treat any other RL_NOTES_DOCS value as off" "0" "$(RL_NOTES_DOCS=yes rl_release_notes "$m0" "$m1" | grep -c 'Documentation' || true)"
doc="$(GITHUB_REPOSITORY=acme/thing rl_notes_document "$m0" "$m1" v9.9.9)"
check "document says when nothing affects users" "1" "$(grep -c '^No user-facing changes' <<<"$doc")"
check "document links every commit" "1" "$(grep -c '^All commits: https://github.com/acme/thing/compare/'"$m0"'...v9.9.9$' <<<"$doc")"
check "document without a repository has no link" "0" "$(GITHUB_REPOSITORY='' rl_notes_document "$m0" "$m1" v9.9.9 | grep -c 'All commits' || true)"
check "document separates the notes from the link" "1" "$(GITHUB_REPOSITORY=acme/thing rl_notes_document "$m1" HEAD v9.9.10 | grep -B1 '^All commits' | head -1 | grep -c '^$')"
check "document limited to a path" "1" "$(rl_notes_document "$m1" HEAD v9.9.10 some/path | grep -c '^No user-facing changes')"
git reset -q --hard "$bot"

check "notes limited to a path" "" "$(rl_release_notes v0.1.0 "$c4" some/path)"

# Promotion bookkeeping.
rl_make_tag v0.3.0 v0.2.0-rc.9
check "make_tag plans" "v0.3.0" "${RL_NEW_TAGS[*]}"
check_status "make_tag creates nothing yet" 1 rl_tag_exists v0.3.0
check "dry push pushes nothing" "Final tags: v0.3.0" "$(DRY_RUN=true rl_push_new_tags)"
check_status "dry push creates no tag" 1 rl_tag_exists v0.3.0
check_status "push without an origin fails" 1 env DRY_RUN=false bash -c "source '${lib}'; RL_NEW_TAGS=(v0.3.0); RL_NEW_TAG_SOURCES=(v0.2.0-rc.9); rl_push_new_tags"
check_status "a failed push leaves no tag" 1 rl_tag_exists v0.3.0
git init -q --bare "${repo}.origin"
git remote add origin "${repo}.origin"
DRY_RUN=false rl_push_new_tags >/dev/null 2>&1
check "push tags the candidate commit" "$c3" "$(git rev-list -n 1 v0.3.0)"
check "push reaches origin" "1" "$(git ls-remote --tags origin refs/tags/v0.3.0 | wc -l | tr -d ' ')"

# rl_promote_single: the latest candidate here is v0.2.0-rc.10, already released as
# v0.2.0, so add a new one.
c6=$(commit "feat: another widget")
git tag -a v0.4.0-rc.0 -m rc "$c6"
git update-ref refs/remotes/origin/main "$c6"
single_out="$(mktemp -d)"
got="$(RC_TAG=latest DRY_RUN=true rl_promote_single v Thing "$single_out" 2>/dev/null)"
check "single dry run output" "final_tag=v0.4.0|previous_tag=v0.3.0|commit=${c6}" "$(tr '\n' '|' <<<"$got" | sed 's/|$//')"
check "single dry run tags nothing" "" "$(git tag -l v0.4.0)"
check "single notes" "1" "$(grep -c '^- Another widget (' "${single_out}/notes.md")"
check "single release line" "v0.4.0|Thing 0.4.0|notes.md" "$(tr '\t' '|' < "${single_out}/releases.tsv")"
RL_NEW_TAGS=(); RL_NEW_TAG_SOURCES=()
RC_TAG=latest DRY_RUN=false rl_promote_single v Thing "$single_out" >/dev/null 2>&1
check "single real run tags the candidate" "$c6" "$(git rev-list -n 1 v0.4.0)"
check_status "single refuses a released candidate" 1 env RC_TAG=v0.4.0-rc.0 bash -c "source '${lib}'; rl_promote_single v Thing '${single_out}'"
check_status "single refuses a repository without candidates" 1 env RC_TAG=latest bash -c "source '${lib}'; rl_promote_single none-v Thing '${single_out}'"
rm -rf "$single_out"
git remote remove origin
rm -rf "${repo}.origin"
rl_checkout_at "$c3"
check "checkout_at makes a worktree" "$c3" "$(git -C "$RL_CHECKOUT" rev-parse HEAD)"
rl_remove_worktrees
check "remove_worktrees cleans up" "1" "$(git worktree list | wc -l | tr -d ' ')"
out="$(mktemp -d)"
rl_add_release "$out" v0.3.0 "Title with spaces" notes.md
check "add_release writes a tsv line" "v0.3.0|Title with spaces|notes.md" "$(tr '\t' '|' < "$out/releases.tsv")"
rm -rf "$out"

if [ "$failures" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "all release-lib tests passed"
