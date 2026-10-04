# release-actions

The release pipeline pieces that every Kubemoot repository shares, kept in one place:

| Path | What it is |
| --- | --- |
| `release-candidate-version/` | Composite action: computes the next release candidate `X.Y.Z-rc.N` for a tag prefix from the conventional commits since the last final `<prefix>X.Y.Z` tag, and decides whether to build it |
| `setup/` | Composite action: exports `RELEASE_LIB` for a job that does not compute a version (promotion, script tests) |
| `release-lib.sh` | Bash helpers for release candidates and promotion (`rl_*` functions), sourced by both actions and by the repositories' release scripts |
| `tests/test-release-lib.sh` | Tests for `release-lib.sh` |

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
          force: "false"             # "true" builds without new commits
          allow_major: "false"       # "true" lets a breaking change leave 0.x
```

Outputs: `version` (`X.Y.Z-rc.N`), `version_tag` (`<prefix>X.Y.Z-rc.N`), and
`release_created` (`"true"` when the candidate should be built).

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
  values file) has for it, so a promoted chart pins exactly what its candidate ran.

Both resolve every image before changing the file and fail on an image they cannot
resolve; `rl_stamp_image`, `rl_image_placeholders`, `rl_image_tag`, and
`rl_latest_remote_final` are the pieces they use.

## Versions

Every push to main that passes CI is tagged `vX.Y.Z` and gets a GitHub Release. The
version comes from this repository's own `release-candidate-version` action: `feat`
bumps the minor version, any other commit the patch, and a breaking change the major,
except that on 0.x it bumps the minor until a maintainer runs the Release workflow with
`allow_major`.

## Tests

```bash
bash tests/test-release-lib.sh
```

CI runs them, plus shellcheck and both actions, on every pull request and push.

## License

Apache License 2.0, see [LICENSE](LICENSE).
