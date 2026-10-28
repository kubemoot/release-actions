#!/usr/bin/env bash
# Tests for release-lib.sh against a throwaway git repository and stubs of cosign and helm.
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

# Image pins: a values file as git holds it, with two placeholder images (one twice,
# one with a registry path), a third-party image, and look-alike names.
values="$(mktemp)"
values_yaml() {
  printf '%s\n' "global:" "  imageRegistry: ghcr.io/kubemoot" "tools:" \
    "  sandbox:" "    image: \"code-sandbox:0.0.0\"" \
    "  access:" "    image: artifact-access:0.0.0" \
    "  readops:" "    image: 'ghcr.io/kubemoot/artifact-access:0.0.0'" \
    "  other:" "    image: \"quay.io/acme/kubernetes-server:v0.0.63\"" \
    "  lookalike:" "    image: \"my-code-sandbox:0.0.0x\"" \
    "version: 0.0.0"
}
values_yaml > "$values"
check "placeholders found once each" "artifact-access code-sandbox" "$(rl_image_placeholders "$values" | tr '\n' ' ' | sed 's/ $//')"
check_status "placeholders of a missing file fail" 1 rl_image_placeholders "$values.none"
printf 'image: "agent:0.4.2"\n' > "$values.final"
check "no placeholders in a stamped file" "" "$(rl_image_placeholders "$values.final")"
check_status "stamp an image" 0 rl_stamp_image "$values" code-sandbox 0.17.0
check "image stamped in its quotes" "1" "$(grep -c '^    image: "code-sandbox:0.17.0"$' "$values")"
rl_stamp_image "$values" artifact-access 0.343.0-rc.2 2>/dev/null
check "every reference of the image stamped" "2" "$(grep -c 'artifact-access:0.343.0-rc.2' "$values")"
check "registry path and quotes kept" "1" "$(grep -c "^    image: 'ghcr.io/kubemoot/artifact-access:0.343.0-rc.2'$" "$values")"
check "other images and versions untouched" "$(values_yaml | grep -v -e code-sandbox:0 -e artifact-access:0)" \
  "$(grep -v -e code-sandbox:0 -e artifact-access:0 "$values")"
check "tag of a stamped image" "0.17.0" "$(rl_image_tag "$values" code-sandbox)"
check_status "stamping a stamped image is refused" 1 rl_stamp_image "$values" code-sandbox 0.18.0
values_yaml > "$values"
for bad in v0.17.0 latest 0.17 0.17.0-beta.1 "" "0.17.0#evil"; do
  check_status "image stamp refuses tag [${bad}]" 1 rl_stamp_image "$values" code-sandbox "$bad"
done
for bad in "" "Code-Sandbox" "code sandbox" "code-sandbox#" "-x"; do
  check_status "image stamp refuses name [${bad}]" 1 rl_stamp_image "$values" "$bad" 0.17.0
done
check_status "image stamp refuses a name with no placeholder" 1 rl_stamp_image "$values" kubernetes-server 0.17.0
check_status "image stamp refuses a look-alike name" 1 rl_stamp_image "$values" my-code-sandbox 0.17.0
check_status "image stamp refuses a missing file" 1 rl_stamp_image "$values.none" code-sandbox 0.17.0
check "a refused image stamp leaves the file unchanged" "$(values_yaml)" "$(< "$values")"

# rl_stamp_images_like: the final pins what the candidate pinned.
printf '%s\n' "a:" "  image: \"ghcr.io/kubemoot/code-sandbox:0.17.0\"" "b:" "  image: artifact-access:0.343.0" \
  "c:" "  image: artifact-access:0.343.0" > "$values.ref"
got="$(rl_stamp_images_like "$values" "$values.ref" 2>/dev/null)"
check "images like the reference" "artifact-access 0.343.0|code-sandbox 0.17.0" "$(tr '\n' '|' <<<"$got" | sed 's/|$//')"
check "no placeholder left" "" "$(rl_image_placeholders "$values")"
values_yaml > "$values"
printf 'a:\n  image: "code-sandbox:0.17.0"\n' > "$values.partial"
check_status "a reference without an image fails" 1 rl_stamp_images_like "$values" "$values.partial"
check "a failed like-stamp leaves the file unchanged" "$(values_yaml)" "$(< "$values")"
printf '%s\n' "image: code-sandbox:0.17.0" "image: code-sandbox:0.16.0" "image: artifact-access:0.343.0" > "$values.twice"
check_status "a reference with two tags for an image fails" 1 rl_stamp_images_like "$values" "$values.twice"
printf '%s\n' "image: code-sandbox:0.0.0" "image: artifact-access:0.343.0" > "$values.unstamped"
check_status "an unstamped reference fails" 1 rl_stamp_images_like "$values" "$values.unstamped"
printf '%s\n' "image: code-sandbox:137268e5" "image: artifact-access:0.343.0" > "$values.sha"
check_status "a reference with a non-version tag fails" 1 rl_stamp_images_like "$values" "$values.sha"
check_status "a missing reference fails" 1 rl_stamp_images_like "$values" "$values.none"
check "unchanged after every refused like-stamp" "$(values_yaml)" "$(< "$values")"
check_status "like-stamp of a file without placeholders succeeds" 0 rl_stamp_images_like "$values.final" "$values.partial"
check "and prints nothing" "" "$(rl_stamp_images_like "$values.final" "$values.partial" 2>/dev/null)"

# rl_latest_remote_final and rl_stamp_remote_images against a bare repository.
upstream="$(mktemp -d)"
git init -q -b main "$upstream/src"
git -C "$upstream/src" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
for t in code-sandbox-v0.14.4 code-sandbox-v0.17.0 code-sandbox-v0.9.9 code-sandbox-v0.18.0-rc.126 \
  artifact-access-v0.343.0 artifact-access-v0.342.31 artifact-access-v0.344.0-rc.1 \
  my-code-sandbox-v9.0.0 code-sandbox-vx v0.99.0 rc-only-v0.1.0-rc.0; do
  git -C "$upstream/src" tag "$t"
done
git clone -q --bare "$upstream/src" "$upstream/remote.git"
check "remote final ignores candidates and sorts" "code-sandbox-v0.17.0" "$(rl_latest_remote_final "$upstream/remote.git" code-sandbox-v)"
check "remote final per prefix" "artifact-access-v0.343.0" "$(rl_latest_remote_final "$upstream/remote.git" artifact-access-v)"
check_status "remote with only candidates fails" 1 rl_latest_remote_final "$upstream/remote.git" rc-only-v
check_status "remote without the prefix fails" 1 rl_latest_remote_final "$upstream/remote.git" none-v
check_status "unreadable remote fails" 1 rl_latest_remote_final "$upstream/missing.git" code-sandbox-v
check_status "remote needs a prefix" 1 rl_latest_remote_final "$upstream/remote.git" ""
check "a remote with a credential is not echoed" "0" \
  "$(rl_latest_remote_final "https://x-access-token:s3cret@127.0.0.1:9/none.git" v 2>&1 | grep -c s3cret || true)"
values_yaml > "$values"
got="$(rl_stamp_remote_images "$values" "$upstream/remote.git" 2>/dev/null)"
check "remote images resolved" "artifact-access 0.343.0|code-sandbox 0.17.0" "$(tr '\n' '|' <<<"$got" | sed 's/|$//')"
check "remote images stamped" "3" "$(grep -cE '(code-sandbox:0\.17\.0|artifact-access:0\.343\.0)' "$values")"
values_yaml > "$values"
printf 'image: "agent-runtime:0.0.0"\nimage: code-sandbox:0.0.0\n' > "$values.unreleased"
check_status "an image without a final fails" 1 rl_stamp_remote_images "$values.unreleased" "$upstream/remote.git"
check "and leaves the file unchanged" "1" "$(grep -c 'code-sandbox:0.0.0' "$values.unreleased")"
check_status "an unreadable remote fails the stamp" 1 rl_stamp_remote_images "$values" "$upstream/missing.git"
check "unchanged after a failed remote stamp" "$(values_yaml)" "$(< "$values")"
check "a file without placeholders needs no remote" "" "$(rl_stamp_remote_images "$values.final" "$upstream/missing.git")"
rm -rf "$upstream" "$values" "$values".*

# rl_latest_remote_candidate: newest rc, the final once it exists, base version first.
cand="$(mktemp -d)"
git init -q -b main "$cand/src"
git -C "$cand/src" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
ctag() { git -C "$cand/src" tag "$@"; git -C "$cand/src" update-server-info 2>/dev/null || true; }
for t in code-sandbox-v0.20.0 code-sandbox-v0.21.0-rc.9 code-sandbox-v0.21.0-rc.10 code-sandbox-v0.21.0-rc.258 \
  artifact-access-v0.9.0-rc.2 artifact-access-v0.10.0-rc.1 artifact-access-v0.10.0 \
  scheduling-mcp-v1.0.0-rc.3 scheduling-mcp-v0.99.9 \
  my-code-sandbox-v9.0.0 code-sandbox-v0.30.0-beta.1 code-sandbox-v0.30.0-rc.x only-final-v1.2.3; do
  ctag "$t"
done
git clone -q --bare "$cand/src" "$cand/remote.git"
check "newest rc by number, not text" "code-sandbox-v0.21.0-rc.258" "$(rl_latest_remote_candidate "$cand/remote.git" code-sandbox-v)"
check "a higher rc outranks an older final" "scheduling-mcp-v1.0.0-rc.3" "$(rl_latest_remote_candidate "$cand/remote.git" scheduling-mcp-v)"
check "the final outranks its own rcs" "artifact-access-v0.10.0" "$(rl_latest_remote_candidate "$cand/remote.git" artifact-access-v)"
check "a final alone is a candidate" "only-final-v1.2.3" "$(rl_latest_remote_candidate "$cand/remote.git" only-final-v)"
check_status "no candidate at all fails" 1 rl_latest_remote_candidate "$cand/remote.git" none-v
check_status "other pre-releases do not count" 1 rl_latest_remote_candidate "$cand/remote.git" my-v
check_status "unreadable remote fails" 1 rl_latest_remote_candidate "$cand/missing.git" code-sandbox-v
check_status "remote needs a prefix" 1 rl_latest_remote_candidate "$cand/remote.git" ""
git -C "$cand/src" tag code-sandbox-v0.21.0
git -C "$cand/src" tag code-sandbox-v0.22.0-rc.1
git -C "$cand/src" push -q "$cand/remote.git" --tags
check "the final of the same base wins over rc.258" "code-sandbox-v0.22.0-rc.1" "$(rl_latest_remote_candidate "$cand/remote.git" code-sandbox-v)"
git -C "$cand/src" tag -d code-sandbox-v0.22.0-rc.1 >/dev/null
git -C "$cand/src" push -q "$cand/remote.git" :refs/tags/code-sandbox-v0.22.0-rc.1
check "0.21.0 ranks above 0.21.0-rc.258" "code-sandbox-v0.21.0" "$(rl_latest_remote_candidate "$cand/remote.git" code-sandbox-v)"
check "a credential in the remote is not echoed" "0" \
  "$(rl_latest_remote_candidate "https://x-access-token:s3cret@127.0.0.1:9/none.git" v 2>&1 | grep -c s3cret || true)"

# rl_stamp_remote_candidate_images
values="$(mktemp)"
git -C "$cand/src" tag -d code-sandbox-v0.21.0 >/dev/null
git -C "$cand/src" push -q "$cand/remote.git" :refs/tags/code-sandbox-v0.21.0
values_yaml > "$values"
printf '%s\n' "  k:" "    image: \"scheduling-mcp:0.0.0\"" >> "$values"
got="$(rl_stamp_remote_candidate_images "$values" "$cand/remote.git" 2>/dev/null)"
check "candidate images resolved" "artifact-access 0.10.0|code-sandbox 0.21.0-rc.258|scheduling-mcp 1.0.0-rc.3" \
  "$(tr '\n' '|' <<<"$got" | sed 's/|$//')"
check "candidate images stamped" "1" "$(grep -c 'image: "code-sandbox:0.21.0-rc.258"' "$values")"
check "no placeholder left after the candidate stamp" "" "$(rl_image_placeholders "$values")"
values_yaml > "$values"
printf 'image: "agent-runtime:0.0.0"\nimage: code-sandbox:0.0.0\n' > "$values.unreleased"
check_status "an image with no tag at all fails" 1 rl_stamp_remote_candidate_images "$values.unreleased" "$cand/remote.git"
check "and leaves the file unchanged" "1" "$(grep -c 'code-sandbox:0.0.0' "$values.unreleased")"
check_status "an unreadable remote fails the candidate stamp" 1 rl_stamp_remote_candidate_images "$values" "$cand/missing.git"
check "unchanged after a failed candidate stamp" "$(values_yaml)" "$(< "$values")"
printf 'image: "code-sandbox:0.21.0"\n' > "$values.final"
check "a file without placeholders needs no remote" "" "$(rl_stamp_remote_candidate_images "$values.final" "$cand/missing.git")"

# rl_rc_image_pins, rl_rc_pin_final, rl_map_rc_images: the digest command is a stub
# that reads "<name>:<tag>=<digest>" lines from a table.
table="$(mktemp)"
digest_stub() {
  local ref="${1##*/}"
  grep -m1 "^${ref}=" "$table" | cut -d= -f2 | grep .
}
export RL_DIGEST_CMD=digest_stub
export -f digest_stub
for t in artifact-access-v0.343.0 code-sandbox-v0.21.0; do ctag "$t"; done
git -C "$cand/src" push -q "$cand/remote.git" --tags
printf '%s\n' "code-sandbox:0.21.0-rc.258=sha256:aaa" "code-sandbox:0.21.0=sha256:aaa" \
  "artifact-access:0.343.0-rc.2=sha256:bbb" "artifact-access:0.343.0=sha256:bbb" \
  "scheduling-mcp:1.0.0-rc.3=sha256:ccc" "scheduling-mcp:1.0.0=sha256:ddd" \
  "agent-runtime:0.5.0-rc.1=sha256:eee" "orphan:2.0.0-rc.1=sha256:fff" "orphan:2.0.0=sha256:fff" > "$table"
remote="$cand/remote.git"
rcv() {
  printf '%s\n' "a:" "  image: \"code-sandbox:0.21.0-rc.258\"" "b:" "  image: ghcr.io/kubemoot/artifact-access:0.343.0-rc.2" \
    "c:" "  image: artifact-access:0.343.0-rc.2" "d:" "  image: quay.io/acme/other:v0.0.63" "e: 0.21.0-rc.258"
}
rcv > "$values"
check "candidate pins found once each" "artifact-access 0.343.0-rc.2|code-sandbox 0.21.0-rc.258" \
  "$(rl_rc_image_pins "$values" | tr '\n' '|' | sed 's/|$//')"
check_status "pins of a missing file fail" 1 rl_rc_image_pins "$values.none"
check "pin accepted when the digests match" "0.21.0" "$(rl_rc_pin_final "$remote" reg code-sandbox 0.21.0-rc.258 2>/dev/null)"
check_status "pin refused when the final tag is missing" 1 rl_rc_pin_final "$remote" reg agent-runtime 0.5.0-rc.1
check "the missing final says to publish Kubemoot first" "1" \
  "$(rl_rc_pin_final "$remote" reg agent-runtime 0.5.0-rc.1 2>&1 | grep -c 'publish Kubemoot first')"
check_status "pin refused when the digests differ" 1 rl_rc_pin_final "$remote" reg scheduling-mcp 1.0.0-rc.3
ctag scheduling-mcp-v1.0.0
git -C "$cand/src" push -q "$remote" --tags
check_status "pin refused when the digests differ and the tag exists" 1 rl_rc_pin_final "$remote" reg scheduling-mcp 1.0.0-rc.3
check "the mismatch says to rebuild with force" "1" \
  "$(rl_rc_pin_final "$remote" reg scheduling-mcp 1.0.0-rc.3 2>&1 | grep -c 'with force')"
check_status "pin refused when a digest cannot be read" 1 rl_rc_pin_final "$remote" reg orphan 2.0.0-rc.9
ctag orphan-v2.0.0
git -C "$cand/src" push -q "$remote" --tags
check_status "pin refused when the rc digest is unreadable" 1 rl_rc_pin_final "$remote" reg orphan 2.0.0-rc.9
check_status "pin refuses a final as the candidate" 1 rl_rc_pin_final "$remote" reg code-sandbox 0.21.0
check_status "pin refuses a bad image name" 1 rl_rc_pin_final "$remote" reg "Bad Name" 0.21.0-rc.258
check_status "pin refuses an unreadable remote" 1 rl_rc_pin_final "$cand/missing.git" reg code-sandbox 0.21.0-rc.258
check_status "pin refuses an empty registry" 1 rl_rc_pin_final "$remote" "" code-sandbox 0.21.0-rc.258
# shellcheck disable=SC2016 # the inner script expands its own arguments
check_status "pin refuses an empty digest" 1 env RL_DIGEST_CMD=true bash -c 'source "$1"; rl_rc_pin_final "$2" reg code-sandbox 0.21.0-rc.258' _ "$lib" "$remote"

got="$(rl_map_rc_images "$values" "$remote" reg 2>/dev/null)"
check "pins mapped" "artifact-access 0.343.0-rc.2 0.343.0|code-sandbox 0.21.0-rc.258 0.21.0" "$(tr '\n' '|' <<<"$got" | sed 's/|$//')"
check "no candidate pin left" "" "$(rl_rc_image_pins "$values")"
check "every reference mapped" "3" "$(grep -cE '(code-sandbox:0\.21\.0"|artifact-access:0\.343\.0$)' "$values")"
check "registry path kept" "1" "$(grep -c '^  image: ghcr.io/kubemoot/artifact-access:0.343.0$' "$values")"
check "third-party and unrelated lines untouched" "2" "$(grep -cE '(quay.io/acme/other:v0.0.63|^e: 0.21.0-rc.258)' "$values")"
rcv > "$values"
printf '%s\n' "f:" "  image: scheduling-mcp:1.0.0-rc.3" "g:" "  image: agent-runtime:0.5.0-rc.1" >> "$values"
cp "$values" "$values.before"
errs="$(rl_map_rc_images "$values" "$remote" reg 2>&1 >/dev/null || true)"
check_status "one refusal fails the whole map" 1 rl_map_rc_images "$values" "$remote" reg
check "every refusal is reported" "2" "$(grep -c '^ERROR' <<<"$errs")"
check "a refused map leaves the file unchanged" "$(< "$values.before")" "$(< "$values")"
printf 'image: "code-sandbox:0.21.0"\n' > "$values"
check_status "a file with no candidate pins passes" 0 rl_map_rc_images "$values" "$remote" reg
check "and prints nothing" "" "$(rl_map_rc_images "$values" "$remote" reg 2>/dev/null)"
check_status "a missing file fails the map" 1 rl_map_rc_images "$values.none" "$remote" reg
unset RL_DIGEST_CMD
rm -rf "$cand" "$values" "$values".* "$table"

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

# rl_free_rc: candidates never share a version and only grow within an X.Y.Z.
git tag -a free-v0.3.0 -m final "$c3"
git tag -a free-v0.4.0-rc.2 -m rc "$c3"
git tag -a free-v0.4.0-rc.5 -m rc "$c4"
git tag -a xfree-v0.4.0-rc.99 -m rc "$c4"
git tag -a free-v0.4.0-rc.9x -m rc "$c4"
check "free: a computed version that is free is kept" "0.4.0-rc.6" "$(rl_free_rc free-v 0.4.0-rc.6 false "$c4")"
check "free: a re-run on the tagged commit keeps its version" "0.4.0-rc.5" "$(rl_free_rc free-v 0.4.0-rc.5 false "$c4")"
check "free: a version taken by another commit moves up" "0.4.0-rc.6" "$(rl_free_rc free-v 0.4.0-rc.2 false "$c4")"
check "free: a free version below the highest moves up" "0.4.0-rc.6" "$(rl_free_rc free-v 0.4.0-rc.3 false "$c4")"
check "free: a forced rebuild of a tagged commit gets the next rc" "0.4.0-rc.6" "$(rl_free_rc free-v 0.4.0-rc.5 true "$c4")"
check "free: a forced free version is kept" "0.4.0-rc.8" "$(rl_free_rc free-v 0.4.0-rc.8 true "$c4")"
check "free: a forced rebuild of a promoted version starts the next patch" "0.3.1-rc.0" "$(rl_free_rc free-v 0.3.0-rc.0 true "$c3")"
check "free: and the promoted candidate is still skipped unforced" "0.3.0-rc.0" "$(rl_free_rc free-v 0.3.0-rc.0 false "$c3")"
check "free: unforced candidate of a promoted version is not released" "release_created=false" \
  "$(needed free-v "$(rl_free_rc free-v 0.3.0-rc.0 false "$c3")" true false)"
check "free: forced candidate after a promotion is released" "release_created=true" \
  "$(needed free-v "$(rl_free_rc free-v 0.3.0-rc.0 true "$c3")" false true)"
git tag -a free-v0.3.1-rc.0 -m rc "$c4"
check "free: the next patch counts its own candidates" "0.3.1-rc.1" "$(rl_free_rc free-v 0.3.0-rc.0 true "$c3")"
git tag -a free-v0.4.0-rc.10 -m rc "$c4"
check "free: rc.10 counts above rc.9" "0.4.0-rc.11" "$(rl_free_rc free-v 0.4.0-rc.9 false "$c3")"
check "free: a zero-padded counter is decimal" "0.4.0-rc.11" "$(rl_free_rc free-v 0.4.0-rc.08 false "$c4")"
check "free: a version of another X.Y.Z is not moved" "0.5.0-rc.1" "$(rl_free_rc free-v 0.5.0-rc.1 true "$c4")"
check "free: a non-candidate is unchanged" "0.4.0" "$(rl_free_rc free-v 0.4.0 true "$c4")"
check "free: an empty version is unchanged" "" "$(rl_free_rc free-v "" true "$c4")"
check "free: commit defaults to HEAD for a re-run" "0.4.0-rc.10" "$(rl_free_rc free-v 0.4.0-rc.10 false)"
check "free: commit defaults to HEAD for a forced run" "0.4.0-rc.11" "$(rl_free_rc free-v 0.4.0-rc.10 true)"
git tag -a free-v0.3.1-rc.1 -m rc "$c4"
check "free: repeated forced rebuilds of a promoted commit count up" "0.3.1-rc.2" "$(rl_free_rc free-v 0.3.0-rc.0 true "$c3")"
git tag -a free-v0.3.1 -m final "$c4"
check "free: when the next patch is promoted too" "0.3.1-rc.2" "$(rl_free_rc free-v 0.3.0-rc.0 true "$c3")"
check "free: and that candidate is not released" "release_created=false" \
  "$(needed free-v "$(rl_free_rc free-v 0.3.0-rc.0 true "$c3")" false true)"
check "free: a zero-major hold onto a minor with candidates moves up" "0.4.0-rc.11" \
  "$(rl_free_rc free-v "$(rl_held_version free-v 1.0.0-rc.2 false "$c4")" false "$c4")"
check "free: the glob matches one X.Y.Z only" "0.4.1-rc.0" "$(rl_free_rc free-v 0.4.1-rc.0 false "$c4")"
check "rc tags of one X.Y.Z, lowest first" "free-v0.4.0-rc.2 free-v0.4.0-rc.5 free-v0.4.0-rc.10" \
  "$(rl_rc_tags free-v 0.4.0 | paste -sd' ')"
check "rc tags reachable from a commit" "free-v0.4.0-rc.2" "$(rl_rc_tags free-v 0.4.0 "$c3" | paste -sd' ')"
check "rc tags with none" "" "$(rl_rc_tags free-v 9.9.9)"
check "next patch" "0.3.10" "$(rl_next_patch 0.3.9)"
check_status "tag at its commit" 0 rl_tag_at free-v0.4.0-rc.5 "$c4"
check_status "tag at another commit" 1 rl_tag_at free-v0.4.0-rc.5 "$c3"
check_status "missing tag is at no commit" 1 rl_tag_at free-v9.9.9-rc.0 "$c4"

# rl_latest_version and rl_stamp_local_images: images this repository builds.
check "latest local candidate" "0.2.0-rc.10" "$(rl_latest_version v "$c4" rc)"
check "latest local candidate at an older commit" "0.2.0-rc.9" "$(rl_latest_version v "$c3" rc)"
check "latest local final" "0.9.0" "$(rl_latest_version agent-v "$c4" final)"
check_status "no local tag of the kind fails" 1 rl_latest_version agent-v "$c3" final
check_status "an unknown prefix fails" 1 rl_latest_version none-v "$c4" rc
check_status "a kind other than rc or final fails" 1 rl_latest_version v "$c4" latest
check_status "a missing commit fails" 1 rl_latest_version v 0000000000000000000000000000000000000000 rc
check_status "an empty prefix fails" 1 rl_latest_version "" "$c4" rc
local_values="$(mktemp)"
printf '%s\n' "a:" "  image: agent:0.0.0" "b:" "  image: \"ghcr.io/kubemoot/agent:0.0.0\"" \
  "c:" "  image: quay.io/acme/other:1.2.3" > "$local_values"
got="$(rl_stamp_local_images "$local_values" "$c4" rc 2>/dev/null)"
check "local candidate resolved" "agent 0.9.0-rc.1" "$got"
check "local candidate stamped everywhere" "2" "$(grep -c 'agent:0.9.0-rc.1' "$local_values")"
check "third-party image untouched" "1" "$(grep -c 'other:1.2.3' "$local_values")"
printf 'image: agent:0.0.0\n' > "$local_values"
check "local final resolved" "agent 0.9.0" "$(rl_stamp_local_images "$local_values" "$c4" final 2>/dev/null)"
printf 'image: agent:0.0.0\nimage: unbuilt:0.0.0\n' > "$local_values"
check_status "an image with no local tag fails" 1 rl_stamp_local_images "$local_values" "$c4" rc
check "and leaves the file unchanged" "2" "$(grep -c ':0.0.0' "$local_values")"
check_status "a bad kind fails the stamp" 1 rl_stamp_local_images "$local_values" "$c4" newest
printf 'image: agent:0.4.2\n' > "$local_values"
check "a file without placeholders is left alone" "" "$(rl_stamp_local_images "$local_values" "$c4" rc)"
rm -f "$local_values"

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
b0=$(git rev-parse HEAD)
git -c user.name="github-actions[bot]" -c user.email="bot@example.org" commit -q --allow-empty -m "docs: republish (synced @ abc123)"
git -c user.name="dependabot[bot]" -c user.email="bot@example.org" commit -q --allow-empty -m "fix: bump a library"
commit "docs: a page a person wrote" >/dev/null
botnotes="$(RL_NOTES_DOCS=true rl_release_notes "$b0" HEAD)"
check "notes leave out commits a bot authored" "0" "$(grep -ciE 'republish|bump a library' <<<"$botnotes" || true)"
check "notes keep a person's commit beside bot commits" "1" "$(grep -c '^- A page a person wrote (' <<<"$botnotes")"
git reset -q --hard "$b0"
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
check "single dry run output" "final_tag=v0.4.0|previous_tag=v0.3.0|commit=${c6}|rc_tag=v0.4.0-rc.0" "$(tr '\n' '|' <<<"$got" | sed 's/|$//')"
git tag -a v0.4.0-rc.1 -m "forced rebuild" "$c6"
got="$(RC_TAG=v0.4.0-rc.0 DRY_RUN=true rl_promote_single v Thing "$single_out" 2>/dev/null)"
check "single promotes the named candidate of a commit with two" "rc_tag=v0.4.0-rc.0" "$(grep '^rc_tag=' <<<"$got")"
got="$(RC_TAG=latest DRY_RUN=true rl_promote_single v Thing "$single_out" 2>/dev/null)"
check "single latest takes the commit's highest candidate" "rc_tag=v0.4.0-rc.1" "$(grep '^rc_tag=' <<<"$got")"
git tag -a other-v0.1.0-rc.0 -m rc "$c6"
got="$(RC_TAG=other-v0.1.0-rc.0 DRY_RUN=true rl_promote_single v Thing "$single_out" 2>/dev/null)"
check "single takes its own prefix's highest candidate for another prefix's tag" "rc_tag=v0.4.0-rc.1" "$(grep '^rc_tag=' <<<"$got")"
git tag -a v0.4.0-rc.2 -m rc "$c6"
git tag -a v0.4.0 -m final "$c6"
check_status "single refuses a named candidate whose final the commit's highest already took" 1 \
  env RC_TAG=v0.4.0-rc.0 DRY_RUN=true bash -c "source '${lib}'; rl_promote_single v Thing '${single_out}'"
git tag -d v0.4.0 v0.4.0-rc.2 >/dev/null
check "single dry run tags nothing" "" "$(git tag -l v0.4.0)"
check "single notes" "1" "$(grep -c '^- Another widget (' "${single_out}/notes.md")"
check "single release line" "v0.4.0|Thing 0.4.0|notes.md" "$(tr '\t' '|' < "${single_out}/releases.tsv")"
RL_NEW_TAGS=(); RL_NEW_TAG_SOURCES=()
RC_TAG=latest DRY_RUN=false rl_promote_single v Thing "$single_out" >/dev/null 2>&1
check "single real run tags the candidate" "$c6" "$(git rev-list -n 1 v0.4.0)"
check "and the final message names the candidate" "1" "$(git tag -l --format='%(contents)' v0.4.0 | grep -c 'v0.4.0-rc.1')"
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

# Release signing, against stubs: cosign keeps a signature as a file in signed/ named for
# the reference, and verify finds it; COSIGN_BROKEN makes cosign not run, COSIGN_FAIL
# makes signing a reference that contains it fail, COSIGN_LOGIN_FAIL makes login fail.
# helm show chart prints the chart's name.
sign_dir="$(mktemp -d)"
mkdir -p "${sign_dir}/bin" "${sign_dir}/signed" "${sign_dir}/out"
export SIGN_LOG="${sign_dir}/calls.log" SIGNED_STATE="${sign_dir}/signed"
cat > "${sign_dir}/bin/cosign" <<'STUB'
#!/usr/bin/env bash
echo "cosign $*" >> "$SIGN_LOG"
[ -z "${COSIGN_BROKEN:-}" ] || exit 127
case "$1" in
  version) printf 'GitVersion:    v3.0.2\nGitCommit:     abc\n' ;;
  login) cat >/dev/null; [ -z "${COSIGN_LOGIN_FAIL:-}" ] ;;
  verify) [ -f "$SIGNED_STATE/$(echo "$2" | tr '/:@' '___')" ] ;;
  sign)
    ref="${*: -1}"
    [ -z "${COSIGN_FAIL:-}" ] || [[ "$ref" != *"${COSIGN_FAIL}"* ]] || exit 1
    touch "$SIGNED_STATE/$(echo "$ref" | tr '/:@' '___')" ;;
esac
STUB
cat > "${sign_dir}/bin/helm" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "show chart" ] && printf 'apiVersion: v2\nname: %s\nversion: 1.2.3\n' "$(basename "$3" .tgz)"
STUB
chmod +x "${sign_dir}/bin/cosign" "${sign_dir}/bin/helm"
saved_path="$PATH"
PATH="${sign_dir}/bin:${PATH}"
digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
oidc=(ACTIONS_ID_TOKEN_REQUEST_URL=https://token.test ACTIONS_ID_TOKEN_REQUEST_TOKEN=t)
workflow=(GITHUB_SERVER_URL=https://github.com GITHUB_WORKFLOW_REF=kubemoot/demo/.github/workflows/publish-release.yaml@refs/heads/main)
creds=(RELEASE_REGISTRY=ghcr.test/kubemoot GHCR_USERNAME=u GHCR_TOKEN=tok)
# preflight RUN_ENV...: rl_sign_preflight in a clean shell with only RUN_ENV set; prints
# its output, then the subjects file's line count.
preflight() {
  env -i PATH="$PATH" SIGN_LOG="$SIGN_LOG" SIGNED_STATE="$SIGNED_STATE" "$@" bash -c \
    "source '${lib}'; rl_sign_preflight '${sign_dir}/out' 2>&1 && wc -l < '${sign_dir}/out/subjects.tsv' | tr -d ' '"
}
id_line="signing: cosign v3.0.2, identity https://github.com/kubemoot/demo/.github/workflows/publish-release.yaml@refs/heads/main, issuer https://token.actions.githubusercontent.com"

check "preflight dry run names cosign, identity, and issuer" "${id_line}|0" \
  "$(preflight DRY_RUN=true "${oidc[@]}" "${workflow[@]}" | paste -sd'|')"
check "preflight dry run outside Actions needs no OIDC token" \
  "signing: cosign v3.0.2, identity <workflow>@<ref>, issuer https://token.actions.githubusercontent.com|0" \
  "$(preflight DRY_RUN=true | paste -sd'|')"
check "preflight identity defaults the server to github.com" 1 \
  "$(preflight DRY_RUN=true GITHUB_WORKFLOW_REF=o/r/.github/workflows/p.yaml@refs/heads/main \
    | grep -c '^signing: cosign v3.0.2, identity https://github.com/o/r/.github/workflows/p.yaml@refs/heads/main, ')"
: > "$SIGN_LOG"
check "preflight dry run logs nothing in" 0 "$(preflight DRY_RUN=true "${oidc[@]}" >/dev/null; grep -c '^cosign login' "$SIGN_LOG" || true)"
check_status "preflight dry run in Actions without an OIDC token fails" 1 \
  preflight DRY_RUN=true GITHUB_ACTIONS=true ACTIONS_ID_TOKEN_REQUEST_URL=https://token.test
check "and says the job needs id-token: write" 1 \
  "$(preflight DRY_RUN=true GITHUB_ACTIONS=true | grep -c '^ERROR: no GitHub OIDC token for keyless signing: the job needs permissions id-token: write$')"
check_status "preflight real run without an OIDC token fails" 1 preflight DRY_RUN=false "${creds[@]}"
check_status "preflight where cosign does not run fails" 1 preflight DRY_RUN=true COSIGN_BROKEN=1
check "and says cosign is required" 1 \
  "$(preflight DRY_RUN=true COSIGN_BROKEN=1 | grep -c '^ERROR: cosign is required to sign the release and does not run$')"
check_status "preflight real run without registry credentials fails" 1 \
  preflight DRY_RUN=false "${oidc[@]}" RELEASE_REGISTRY=ghcr.test/kubemoot GHCR_USERNAME=u
check "and names them" 1 "$(preflight DRY_RUN=false "${oidc[@]}" RELEASE_REGISTRY=ghcr.test/kubemoot \
  | grep -c '^ERROR: GHCR_USERNAME and GHCR_TOKEN are required to store the signatures$')"
: > "$SIGN_LOG"
check "preflight real run logs cosign in to the registry host" "${id_line}|0" \
  "$(preflight DRY_RUN=false "${oidc[@]}" "${workflow[@]}" "${creds[@]}" | paste -sd'|')"
check "with the user and the token on stdin" 1 "$(grep -cx 'cosign login ghcr.test -u u --password-stdin' "$SIGN_LOG")"
check_status "preflight fails when cosign cannot log in" 1 \
  preflight DRY_RUN=false COSIGN_LOGIN_FAIL=1 "${oidc[@]}" "${creds[@]}"
check "and names the registry" 1 "$(preflight DRY_RUN=false COSIGN_LOGIN_FAIL=1 "${oidc[@]}" "${creds[@]}" \
  | grep -c '^ERROR: cosign cannot log in to ghcr.test$')"
echo stale > "${sign_dir}/out/subjects.tsv"
preflight DRY_RUN=true >/dev/null
check "preflight empties the subjects file" 0 "$(wc -c < "${sign_dir}/out/subjects.tsv" | tr -d ' ')"

RL_SIGN_SUBJECTS="${sign_dir}/out/subjects.tsv"
RL_SIGN_IDENTITY="https://github.com/kubemoot/demo/.github/workflows/publish-release.yaml@refs/heads/main"
: > "$RL_SIGN_SUBJECTS"; : > "$SIGN_LOG"
check "dry run plans the signature" "sign ghcr.test/kubemoot/a@<digest after the push> (dry run: not signed)" \
  "$(DRY_RUN=true rl_sign_artifact ghcr.test/kubemoot/a "<digest after the push>")"
check "dry run signs and records nothing" "0|0" \
  "$(grep -c '^cosign sign' "$SIGN_LOG" || true)|$(wc -l < "$RL_SIGN_SUBJECTS" | tr -d ' ')"
for bad in "" "sha256:abc" "latest" "${digest_a^^}" "sha512:${digest_a#sha256:}"; do
  check_status "refuses to sign without a sha256 digest [${bad}]" 1 env DRY_RUN=false bash -c \
    "source '${lib}'; RL_SIGN_SUBJECTS='${RL_SIGN_SUBJECTS}'; rl_sign_artifact ghcr.test/kubemoot/a '${bad}'"
done
check "and says so" "ERROR: refusing to sign ghcr.test/kubemoot/a without a sha256 digest (got [1.0.0])" \
  "$(DRY_RUN=false rl_sign_artifact ghcr.test/kubemoot/a 1.0.0 2>&1 >/dev/null || true)"
check "a refused digest signs nothing" 0 "$(grep -c '^cosign sign' "$SIGN_LOG" || true)"
check "signs by digest" "signed ghcr.test/kubemoot/a@${digest_a}" \
  "$(DRY_RUN=false rl_sign_artifact ghcr.test/kubemoot/a "$digest_a")"
check "with cosign sign --yes" 1 "$(grep -cx "cosign sign --yes ghcr.test/kubemoot/a@${digest_a}" "$SIGN_LOG")"
check "and records it" "ghcr.test/kubemoot/a|${digest_a}" "$(tr '\t' '|' < "$RL_SIGN_SUBJECTS")"
: > "$SIGN_LOG"
check_status "signed finds a signature from this workflow" 0 rl_signed "ghcr.test/kubemoot/a@${digest_a}"
check_status "signed finds none on another artifact" 1 rl_signed "ghcr.test/kubemoot/a@${digest_b}"
check_status "signed is false without a signing identity" 1 env bash -c \
  "source '${lib}'; rl_signed 'ghcr.test/kubemoot/a@${digest_a}'"
check "checks the signature against identity and issuer" 1 \
  "$(grep -cx "cosign verify ghcr.test/kubemoot/a@${digest_a} --certificate-identity ${RL_SIGN_IDENTITY} --certificate-oidc-issuer https://token.actions.githubusercontent.com" "$SIGN_LOG")"
: > "$SIGN_LOG"
check "does not sign again what this workflow signed" "already signed ghcr.test/kubemoot/a@${digest_a}" \
  "$(DRY_RUN=false rl_sign_artifact ghcr.test/kubemoot/a "$digest_a")"
check "but records it again for this release" "0|2" \
  "$(grep -c '^cosign sign' "$SIGN_LOG" || true)|$(wc -l < "$RL_SIGN_SUBJECTS" | tr -d ' ')"
DRY_RUN=false rl_sign_artifact ghcr.test/kubemoot/a "$digest_a" earlier >/dev/null
check "an earlier release's signed artifact is not recorded" 2 "$(wc -l < "$RL_SIGN_SUBJECTS" | tr -d ' ')"
DRY_RUN=false rl_sign_artifact ghcr.test/kubemoot/b "$digest_b" earlier >/dev/null
check "an earlier release's unsigned artifact is signed and recorded" "1|3" \
  "$(grep -cx "cosign sign --yes ghcr.test/kubemoot/b@${digest_b}" "$SIGN_LOG")|$(wc -l < "$RL_SIGN_SUBJECTS" | tr -d ' ')"
check_status "a signing failure fails" 1 env DRY_RUN=false COSIGN_FAIL=kubemoot/c bash -c \
  "source '${lib}'; RL_SIGN_SUBJECTS='${RL_SIGN_SUBJECTS}'; rl_sign_artifact ghcr.test/kubemoot/c '${digest_a}'"
check "and names the reference" "ERROR: signing ghcr.test/kubemoot/c@${digest_a} failed" \
  "$( (DRY_RUN=false COSIGN_FAIL=kubemoot/c rl_sign_artifact ghcr.test/kubemoot/c "$digest_a" 2>&1 >/dev/null) || true)"
check "and records nothing" 3 "$(wc -l < "$RL_SIGN_SUBJECTS" | tr -d ' ')"

check "chart repository from the packaged chart's name" "ghcr.test/kubemoot/charts/kubemoot-operator" \
  "$(RELEASE_REGISTRY=ghcr.test/kubemoot rl_chart_repo /x/kubemoot-operator.tgz)"
check "subjects as the attest matrix" \
  "[{\"name\":\"ghcr.test/kubemoot/a\",\"digest\":\"${digest_a}\"},{\"name\":\"ghcr.test/kubemoot/a\",\"digest\":\"${digest_a}\"},{\"name\":\"ghcr.test/kubemoot/b\",\"digest\":\"${digest_b}\"}]" \
  "$(rl_sign_subjects_json)"
: > "$RL_SIGN_SUBJECTS"
check "no subjects is an empty matrix" "[]" "$(rl_sign_subjects_json)"
PATH="$saved_path"
rm -rf "$sign_dir"

# rl_commit_bump, rl_bump_version, rl_next_chart_version: a chart's candidate comes from
# the conventional commits since its last final, limited to the chart's paths.
check "bump major" "2.0.0" "$(rl_bump_version 1.4.2 major)"
check "bump minor" "0.93.0" "$(rl_bump_version 0.92.594 minor)"
check "bump patch" "0.92.595" "$(rl_bump_version 0.92.594 patch)"
check "bump is decimal" "0.9.0" "$(rl_bump_version 0.08.3 minor)"
check_status "unknown bump fails" 1 rl_bump_version 0.1.0 huge

cd "$(mktemp -d)"
git init -q -b main
git config user.email test@example.com
git config user.name test
mkdir chart other
ccommit() { # SUBJECT DIR [BODY]: a commit that adds a file in DIR
  echo "$RANDOM" > "$2/f$RANDOM"
  git add "$2"
  if [ -n "${3:-}" ]; then git commit -q -m "$1" -m "$3"; else git commit -q -m "$1"; fi
  git rev-parse HEAD
}
next() { rl_next_chart_version chart-v "$1" "${2:-false}" "${3:-}" chart; }

k0=$(ccommit "chore: init" chart)
check_status "no final and no first version fails" 1 rl_next_chart_version chart-v "$k0" false "" chart
check "no final starts at the first version" "0.1.0-rc.0" "$(rl_next_chart_version chart-v "$k0" false 0.1.0-rc.0 chart)"
git tag -a chart-v0.1.0-rc.0 -m rc "$k0"
check "no final counts up the first version" "0.1.0-rc.1" "$(rl_next_chart_version chart-v "$k0" false 0.1.0-rc.0 chart)"

git tag -a chart-v0.3.0-rc.7 -m rc "$k0"
check "no final continues the latest candidate's stream" "0.3.0-rc.8" "$(rl_next_chart_version chart-v "$k0" false 0.1.0-rc.0 chart)"
git tag -a chart-v0.92.594 -m final "$k0"
git tag -a chart-v0.92.595-rc.152 -m rc "$k0"
check "no new commits: next patch, past a stale rc counter" "0.92.595-rc.153" "$(next "$k0")"
k1=$(ccommit "docs: explain values" chart)
check "docs only is a patch" "0.92.595-rc.153" "$(next "$k1")"
k2=$(ccommit "fix(api): empty input" chart)
check "fix is a patch" "0.92.595-rc.153" "$(next "$k2")"
k3=$(ccommit "chore: elsewhere" other)
check "a commit outside the path is ignored" "0.92.595-rc.153" "$(next "$k3")"
check "only commits outside the path: no bump" "none" "$(rl_commit_bump "${k2}..${k3}" chart)"
k4=$(ccommit "feat: new value" chart)
check "feat is a minor" "0.93.0-rc.0" "$(next "$k4")"
git tag -a chart-v0.93.0-rc.0 -m rc "$k4"
check "an unpublished target counts its rc up" "0.93.0-rc.1" "$(next "$k4")"
k5=$(ccommit "fix: later" chart)
check "later fix keeps the minor target" "0.93.0-rc.1" "$(next "$k5")"
git tag -a chart-v0.93.0-rc.1 -m rc "$k5"
k6=$(ccommit "feat!: rename the kind" chart)
check "feat! at major 0 is held to the next minor" "0.93.0-rc.2" "$(next "$k6")"
check "feat! leaves major 0 only when allowed" "1.0.0-rc.0" "$(next "$k6" true)"
k7=$(ccommit "refactor: tidy" chart "BREAKING CHANGE: values renamed")
check "BREAKING CHANGE footer is major" "major" "$(rl_commit_bump "${k6}..${k7}" chart)"
check "BREAKING CHANGE footer is held at major 0" "0.93.0-rc.2" "$(next "$k7")"
kx=$(git commit -q --allow-empty -m "fix(x)!: gone"; git rev-parse HEAD)
check "fix! is major" "major" "$(rl_commit_bump "${k7}..${kx}")"
git reset -q --hard "$k7"
kd=$(git commit -q --allow-empty -m "docs: mention BREAKING CHANGE rules"; git rev-parse HEAD)
check "BREAKING CHANGE words in a subject are not breaking" "patch" "$(rl_commit_bump "${kx}..${kd}")"
git reset -q --hard "$k7"
git tag -a chart-v0.93.0 -m final "$k7"
check "a published target starts the next bump from the commits after it" "0.93.1-rc.0" "$(next "$k7")"
k8=$(ccommit "feat: after the release" chart)
check "feat after the final is the next minor" "0.94.0-rc.0" "$(next "$k8")"
check "another prefix is not counted" "0.1.0-rc.0" "$(rl_next_chart_version other-v "$k8" false 0.1.0-rc.0 chart)"
check "after 1.0 a breaking change is a major" "2.0.0-rc.0" "$( git tag -a chart-v1.4.0 -m final "$k8"; k9=$(ccommit "feat!: big" chart); next "$k9")"
cd "$repo"

if [ "$failures" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "all release-lib tests passed"
