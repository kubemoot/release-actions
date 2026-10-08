# release-actions

[![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/kubemoot/release-actions?label=openssf%20scorecard)](https://scorecard.dev/viewer/?uri=github.com/kubemoot/release-actions)

The release pipeline pieces that every Kubemoot repository shares, kept in one place:

| Path | What it is |
| --- | --- |
| `release-candidate-version/` | Composite action: computes the next release candidate `X.Y.Z-rc.N` for a tag prefix from the conventional commits since the last final `<prefix>X.Y.Z` tag, and decides whether to build it |
| `setup/` | Composite action: exports `RELEASE_LIB` for a job that does not compute a version (Publish Release, script tests), and `BUILD_IMAGE_DIR` |
| `release-lib.sh` | Bash helpers for release candidates, publishing releases, and release signing (`rl_*` functions), sourced by both actions and by the repositories' release scripts |
| `build-image/` | Scripts that build an image in the cluster and push it to the registry: `build-image-buildpacks.sh` (Paketo buildpacks), `build-image-buildah.sh` (a Dockerfile with Buildah), the shared `build-image-lib.sh`, and the builder, run and Buildah images pinned by tag and digest in `buildpacks/images.yaml` and `buildah/images.yaml` |
| `tests/test-release-lib.sh` | Tests for `release-lib.sh` |
| `tests/test-build-image-*.sh` | Tests for the build-image scripts |
| `.github/workflows/all-checks.yaml` | Reusable workflow: the one required check for a pull request; waits for every other check on the commit and passes only when all passed or were skipped |

## Use

Pin the full commit sha of a release, with its tag in a comment, so Dependabot can bump it:

```yaml
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0 # the version reads the commit history and tags

      - id: version
        uses: kubemoot/release-actions/release-candidate-version@<sha> # vX.Y.Z
        with:
          tag_prefix: "v"            # required
          change_path: ""            # count only commits under this path
          force: "false"             # "true" builds without new commits, as the next free rc.N
          allow_major: "false"       # "true" lets a breaking change leave 0.x
```

Outputs: `version` (`X.Y.Z-rc.N`), `version_tag` (`<prefix>X.Y.Z-rc.N`), and
`release_created` (`"true"` when the candidate should be built).

A candidate never reuses an rc.N that a tag already holds, and sorts above every earlier
candidate of its X.Y.Z (`rl_free_rc`). With `force: "true"` on an unchanged commit, for
example to rebuild a site for content from another repository, the run gets the next free
rc.N, or the next patch's rc.0 when the commit's version is published. Give the release
workflow a `concurrency` group so two runs of one prefix never overlap.

Both actions export `RELEASE_LIB`, the path of `release-lib.sh`, to the job's later
steps. A step or script sources the helpers from there instead of keeping a copy:

```yaml
      - uses: kubemoot/release-actions/setup@<sha> # vX.Y.Z

      - run: |
          source "${RELEASE_LIB}"
          rl_promote_single v MyProject promotion
```

A script run from such a step does the same: `source "${RELEASE_LIB:?}"`.

Versions live only in git tags: a `Chart.yaml` in git holds `0.0.0`, and the build
stamps the version it computed into its own copy before packaging, never committing it:

```yaml
      - run: |
          source "${RELEASE_LIB}"
          rl_stamp_chart charts/my-chart "${{ steps.version.outputs.version }}"
          helm package charts/my-chart
```

`rl_stamp_chart CHART_DIR VERSION [APP_VERSION]` sets `version` and `appVersion`
(default `VERSION`) and refuses anything but `X.Y.Z` or `X.Y.Z-rc.N`. Image tags that
default to `.Chart.AppVersion` need no stamping of their own.

An image of another repository is written in a values file with the tag `0.0.0`
(`image: "code-sandbox:0.0.0"`) and stamped the same way:

- `rl_stamp_remote_images VALUES REMOTE` gives each `NAME:0.0.0` image the version of
  the latest final `NAME-vX.Y.Z` tag of the repository at `REMOTE`, so a chart pins only
  released images (a release candidate build of a crew chart).
- `rl_stamp_images_like VALUES REFERENCE` gives each one the tag `REFERENCE` (another
  values file) has for it, so a published chart pins exactly what its candidate ran.
- `rl_stamp_local_images VALUES COMMIT rc|final` gives each one the version of the
  latest `NAME-vX.Y.Z-rc.N` (or final `NAME-vX.Y.Z`) tag of this repository reachable
  from `COMMIT`, for a chart that pins images the same repository builds (Kubemoot's
  operator chart and its components).

All of them resolve every image before changing the file and fail on an image they
cannot resolve; `rl_stamp_image`, `rl_image_placeholders`, `rl_image_tag`,
`rl_latest_remote_final`, and `rl_latest_version` are the pieces they use.

## Build an image

The `setup` action also exports `BUILD_IMAGE_DIR`, the path of `build-image/`. A job on a
self-hosted runner in the cluster (with `kubectl` and RBAC to run pods in its namespace)
builds an image in a short-lived pod and pushes it to the registry:

```yaml
      - uses: kubemoot/release-actions/setup@<sha> # vX.Y.Z

      - env:
          REGISTRY: registry.example.org
          REGISTRY_HOST_IP: 192.0.2.10   # the in-cluster address the registry name points at
        run: |
          "${BUILD_IMAGE_DIR}/build-image-buildpacks.sh" \
            --pod "buildpacks-app-${GITHUB_SHA:0:8}-${GITHUB_RUN_NUMBER}" \
            --sha "${GITHUB_SHA}" --ref "${GITHUB_REF}" \
            --builder builder --run-image run-base \
            --buildpack paketo-buildpacks/nodejs \
            --env BP_NODE_RUN_SCRIPTS=build \
            app-dir "${REGISTRY}/project/app"
```

- `build-image-buildpacks.sh` runs the lifecycle `creator` from a pinned Paketo builder.
  The pod runs as a non-root user with every capability dropped, which Pod Security
  "restricted" admits. `--builder` and `--run-image` name entries of
  `buildpacks/images.yaml`; `--buildpack` (repeatable) replaces the builder's detection
  order with the named buildpacks; `--env KEY=VALUE` sets a build-time variable.
- `build-image-buildah.sh` builds a Dockerfile with Buildah in a user-namespaced pod
  (`hostUsers: false`), which Pod Security "baseline" admits. The nodes must allow user
  namespaces and install the Localhost seccomp profile `SECCOMP_PROFILE`. `--file`,
  `--label` and `--extra-tag` (main only) are its options.

Both push `:<sha>` and `:latest` from `refs/heads/main` and only `:branch-<sha>` from any
other ref, so a branch build never moves a tag main uses. The push credentials are the
docker config secret `PUSH_SECRET` (default `harbor-push`) in `NAMESPACE` (default
`arc-runners`). The header of each script lists all of its options and variables.

## Signing

A publish script signs what it releases with the `rl_sign_*` helpers: keyless cosign,
by digest, under the GitHub OIDC identity of the running workflow (the job needs
`id-token: write`), so no key is stored anywhere.

- `rl_sign_preflight OUT_DIR` runs before anything is published: cosign must run, the
  job must be able to mint the OIDC token, and a real run logs cosign in to
  `RELEASE_REGISTRY` with `GHCR_USERNAME` and `GHCR_TOKEN`. A dry run only prints the
  identity the signatures would carry.
- `rl_sign_artifact REPOSITORY DIGEST [earlier]` signs `REPOSITORY@DIGEST`, unless this
  workflow signed it already, and records it in `OUT_DIR/subjects.tsv`; `earlier` leaves
  out an artifact an earlier release published and attested. A failure stops the
  release before any tag.
- `rl_chart_repo TGZ` is the release registry repository of a packaged chart.
- `rl_sign_subjects_json` prints the recorded references as the `[{name, digest}]`
  matrix of the workflow's `actions/attest` job, which records SLSA build provenance.

Verify a signature:

```bash
cosign verify <repository>@<digest> \
  --certificate-identity https://github.com/<owner>/<repo>/.github/workflows/publish-release.yaml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Versions

Every push to main that passes CI is tagged `vX.Y.Z` and gets a GitHub Release. The
version comes from this repository's own `release-candidate-version` action: `feat`
bumps the minor version, any other commit the patch, and a breaking change the major,
except that on 0.x it bumps the minor until a maintainer runs the Release workflow with
`allow_major`.

## Tests

```bash
bash tests/test-release-lib.sh
bash tests/test-build-image-buildpacks.sh
bash tests/test-build-image-buildah.sh
```

CI runs them, plus shellcheck and both actions, on every pull request and push.

## License

Apache License 2.0, see [LICENSE](LICENSE).
