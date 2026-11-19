#!/usr/bin/env bash
# Tests for the last step of all-checks.yaml (fail on any unsuccessful or duplicate-named
# check) against a stub gh that serves fixture check runs and statuses.
# Usage: bash tests/test-all-checks-gate.sh   (exit 0 = all passed)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"

yq -r '.jobs.all-checks.steps[-1].run' "${root}/.github/workflows/all-checks.yaml" > "${work}/step.sh"
ignore="$(yq -r '.jobs.all-checks.env.IGNORE_PATTERN' "${root}/.github/workflows/all-checks.yaml")"

# The stub applies the --jq filter it is given to the fixture for the requested endpoint. Poll
# number N (counted per check-runs call) reads runs.N.json and status.N.json, falling back to the
# highest numbered file, so a test can change what the commit shows between polls.
cat > "${work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
url="" jqf=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift ;;
    repos/*) url="$1" ;;
  esac
  shift
done
pick() { # pick KIND: newest fixture numbered at most the current poll
  local n f
  n="$(cat "${FIXTURE_DIR}/poll")"
  while [ "${n}" -gt 1 ] && [ ! -f "${FIXTURE_DIR}/$1.${n}.json" ]; do n=$((n - 1)); done
  f="${FIXTURE_DIR}/$1.${n}.json"
  echo "${f}"
}
case "${url}" in
  */check-runs*) echo $(($(cat "${FIXTURE_DIR}/poll") + 1)) > "${FIXTURE_DIR}/poll"
    jq -c "${jqf}" "$(pick runs)" ;;
  */status*) jq -c "${jqf}" "$(pick status)" ;;
  */actions/runs*) jq -c "${jqf}" "${FIXTURE_DIR}/workflows.json" ;;
esac
STUB
chmod +x "${work}/bin/gh"

failures=0
# set_poll N RUNS_JSON STATUSES_JSON: what the commit shows on poll N (N starts at 1).
set_poll() {
  echo "{\"check_runs\": $2}" > "${work}/runs.$1.json"
  echo "{\"statuses\": $3}" > "${work}/status.$1.json"
}
# expect NAME WANT [WORKFLOWS_JSON] [OUTPUT_PATTERN]: run the step against the fixtures set so
# far; WANT is the exit code (0 pass, 1 fail). The poll interval and deadline are short so a
# check that never settles fails the step quickly.
expect() {
  local name="$1" want="$2" wf="${3:-[]}" pattern="${4:-}" got=0
  echo "{\"workflow_runs\": ${wf}}" > "${work}/workflows.json"
  echo 1 > "${work}/poll"
  PATH="${work}/bin:${PATH}" FIXTURE_DIR="${work}" REPO=o/r SHA=abc IGNORE_PATTERN="${ignore}" \
    POLL_INTERVAL=1 DEADLINE=2 bash "${work}/step.sh" >"${work}/out.txt" 2>&1 || got=$?
  if [ "${want}" = "${got}" ] && { [ -z "${pattern}" ] || grep -qF -- "${pattern}" "${work}/out.txt"; }; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: want exit ${want} got ${got} (output pattern: ${pattern:-none})"
    sed 's/^/     /' "${work}/out.txt"
    failures=$((failures + 1))
  fi
  rm -f "${work}"/runs.*.json "${work}"/status.*.json
}
# run_gate NAME WANT RUNS_JSON STATUSES_JSON [WORKFLOWS_JSON]: a single settled snapshot.
run_gate() {
  set_poll 1 "$3" "$4"
  expect "$1" "$2" "${5:-[]}"
}

ok='{"name":"build","status":"completed","conclusion":"success"}'
skipped='{"name":"deploy","status":"completed","conclusion":"skipped"}'
bad() { echo "{\"name\":\"$1\",\"status\":\"completed\",\"conclusion\":\"$2\"}"; }
# A check run made by workflow run $2 (details_url points at the run).
from_run() { echo "{\"name\":\"$1\",\"status\":\"completed\",\"conclusion\":\"${3:-success}\",\"details_url\":\"https://github.com/o/r/actions/runs/$2/job/9\"}"; }
wfs='[{"id":1,"path":".github/workflows/a.yaml"},{"id":2,"path":".github/workflows/b.yaml"},{"id":3,"path":".github/workflows/a.yaml"}]'

run_gate "all success and skipped pass" 0 "[${ok},${skipped}]" "[]"
run_gate "no checks pass" 0 "[]" "[]"
run_gate "failure fails" 1 "[${ok},$(bad lint failure)]" "[]"
run_gate "cancelled fails" 1 "[$(bad lint cancelled)]" "[]"
run_gate "timed_out fails" 1 "[$(bad lint timed_out)]" "[]"
run_gate "action_required fails" 1 "[$(bad lint action_required)]" "[]"
run_gate "failed run hidden by passing run of the same name in another workflow fails" 1 \
  "[$(from_run test 1 failure),$(from_run test 2)]" "[]" "${wfs}"
run_gate "same name from two workflows fails even when all pass" 1 \
  "[$(from_run test 1),$(from_run test 2)]" "[]" "${wfs}"
run_gate "same name from two apps fails even when all pass" 1 \
  '[{"name":"x","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},{"name":"x","status":"completed","conclusion":"success","app":{"slug":"other"}}]' "[]"
run_gate "same workflow run on push and pull_request is not a collision" 0 \
  "[$(from_run test 1),$(from_run test 3)]" "[]" "${wfs}"
run_gate "same workflow on push and pull_request still fails when one failed" 1 \
  "[$(from_run test 1 failure),$(from_run test 3)]" "[]" "${wfs}"
run_gate "ignored own check run is skipped" 0 \
  "[${ok},{\"name\":\"all-checks / all-checks\",\"status\":\"in_progress\",\"conclusion\":null}]" "[]"
run_gate "ignored CodeQL failure is skipped" 0 "[${ok},$(bad CodeQL failure)]" "[]"
run_gate "failure status fails" 1 "[${ok}]" '[{"context":"ci/x","state":"failure"}]'
run_gate "error status fails" 1 "[${ok}]" '[{"context":"ci/x","state":"error"}]'
run_gate "success status passes" 0 "[${ok}]" '[{"context":"ci/x","state":"success"}]'
run_gate "neutral passes" 0 "[$(bad lint neutral)]" "[]"
run_gate "stale fails" 1 "[$(bad lint stale)]" "[]"
run_gate "startup_failure fails" 1 "[$(bad lint startup_failure)]" "[]"
run_gate "completed without a conclusion fails" 1 \
  '[{"name":"lint","status":"completed","conclusion":null}]' "[]"

# Unfinished checks make the step wait, then fail closed at the deadline listing them.
queued='{"name":"slow","status":"queued","conclusion":null}'
running='{"name":"slow","status":"in_progress","conclusion":null}'
set_poll 1 "[${ok},${queued}]" "[]"
expect "queued check waits then fails at the deadline" 1 "[]" "check run slow is queued"
set_poll 1 "[${ok},${running}]" "[]"
expect "in_progress check waits then fails at the deadline" 1 "[]" "check run slow is in_progress"
set_poll 1 "[${ok}]" '[{"context":"ci/x","state":"pending"}]'
expect "pending status waits then fails at the deadline" 1 "[]" "status ci/x is pending"
set_poll 1 "[${ok},${running}]" "[]"
set_poll 2 "[${ok},$(bad slow success)]" "[]"
expect "in_progress check that then succeeds passes" 0
set_poll 1 "[${ok},${running}]" "[]"
set_poll 2 "[${ok},$(bad slow failure)]" "[]"
expect "in_progress check that then fails fails" 1
set_poll 1 "[${ok}]" '[{"context":"ci/x","state":"pending"}]'
set_poll 2 "[${ok}]" '[{"context":"ci/x","state":"success"}]'
expect "pending status that then succeeds passes" 0
set_poll 1 "[${ok},${queued}]" "[]"
set_poll 2 "[${ok},$(bad slow success),$(bad late failure)]" "[]"
expect "a check that appears on a later poll is judged" 1 "[]" "unsuccessful check run: late"
set_poll 1 "[${ok},${queued}]" "[]"
set_poll 2 "[${ok},$(bad slow success),$(bad late success)]" "[]"
expect "a late check that passes lets the step pass" 0

# Names are cleaned before they reach a ::error:: line.
set_poll 1 "[$(bad "evil::error::x%0Ay" failure)]" "[]"
expect "workflow command characters are stripped from names" 1 "[]" "unsuccessful check run: evilerrorx0Ay"
set_poll 1 "[$(bad 'a\r\nb::warning::c' failure)]" "[]"
expect "CR and LF are stripped from names" 1 "[]" "unsuccessful check run: a  bwarningc"

[ "${failures}" -eq 0 ] || { echo "${failures} failed"; exit 1; }
echo "all passed"
