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
