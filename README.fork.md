# Fork notes

This is a fork of [ajilach/clamav-rest](https://github.com/ajilach/clamav-rest). It exists to provide a build of the image tuned for **offline / airgapped deployments** where the container must not attempt to reach the public ClamAV mirrors at runtime.

The upstream image runs `freshclam` as a daemon at container startup. In an offline environment that daemon cannot reach the mirrors and produces continuous update-failure log noise. The fix we use here is to rebuild the image daily — `freshclam` runs once at image build time and bakes current signatures into the image — and then skip the daemon entirely at runtime.

## Runtime differences

### `DISABLE_FRESHCLAM=true` is the default

Baked into the image via `Dockerfile`. When set to `true`, [entrypoint.sh](entrypoint.sh) does not start the `freshclam --daemon` background process. `clamd` and `clamav-rest` still start normally and serve scans using whatever signatures are in `/clamav/data`.

Override if you need live updates (e.g. during testing):

```bash
docker run -e DISABLE_FRESHCLAM=false ...
```

When `DISABLE_FRESHCLAM=true`, these env vars become no-ops because freshclam never runs: `SIGNATURE_CHECKS`, `PROXY_SERVER`, `PROXY_PORT`, `PROXY_USERNAME`, `PROXY_PASSWORD`.

### Signature freshness = image age

With `DISABLE_FRESHCLAM=true`, the signatures inside the container are only as current as the image build. The daily CI workflow rebuilds and republishes the image so that a freshly-pulled `:latest` is never more than ~24 hours old. To update signatures in an airgapped environment, transfer a newer image in — there is no runtime update path by design.

### 120s RELOAD hack removed

Upstream's `entrypoint.sh` sleeps 120 seconds after startup and then sends `RELOAD` to `clamd` over the TCP socket to work around a race between `freshclam` and `clamd` at first boot. Since we do not run `freshclam` at runtime, that race cannot happen and the workaround is unnecessary.

## Build-pipeline differences

All in [.github/workflows/release.yaml](.github/workflows/release.yaml):

| Change | Why |
|---|---|
| `schedule: cron '37 0 * * *'` | Rebuild daily so baked-in signatures stay current. Odd minute to be polite to the mirrors. |
| `no-cache: true` on `docker/build-push-action` | Without this, GHA layer caching would skip the `RUN freshclam` step on rebuilds and the signature DB would never actually refresh. |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secret names | Matches our org convention. Upstream uses `vars.DOCKER_USER` / `secrets.DOCKER_PASSWORD`. |

### Semver tagging on scheduled runs

Upstream's release workflow derives a semver tag from conventional commit messages via `mathieudutour/github-tag-action`. On a nightly cron run with no new commits since the last tag, the tag action is a no-op but the downstream jobs still expect `needs.version.outputs.new_version` to be populated. Expect scheduled runs to either skip the merge/release job or push with an empty version. The `:latest` tag will still update correctly, which is what we rely on. If this becomes an issue, split the nightly rebuild into its own workflow that pushes `:latest` + date-tagged without invoking the tag action.

## What we did NOT change from upstream

- The Go server code — upstream already ships unencrypted HTTP/2 (h2c) support via the `http.Protocols` API, plus CORS middleware and optional TLS. Our earlier local h2c implementation was dropped during the upstream merge because it was redundant.
- The test suite — upstream migrated from Python/behave to Go tests. Our earlier local behave tests for h2c were dropped for the same reason.
- `freshclam` still runs at **image build time** (see the `RUN freshclam --quiet --no-dns` step in [Dockerfile](Dockerfile)). That is the only source of signature updates for this fork.

## Pulling in future upstream changes

This fork keeps upstream's history on an `upstream-master` branch of `origin`. The sync flow is GitHub-UI + local merge, no `upstream` git remote.

### 1. Sync `upstream-master` on GitHub

1. Open `https://github.com/elemdiscovery/clamav-rest/tree/upstream-master` in a browser.
2. Click the **Sync fork** button near the top of the file list.
3. GitHub shows how many commits behind `ajilach/clamav-rest:master` the branch is; click **Update branch**. This fast-forwards `origin/upstream-master` without needing a local checkout.

If the "Sync fork" button shows a conflict, that means someone has committed directly to `upstream-master` on our fork — which should not happen. Treat it as `upstream-master` being corrupted: hard-reset it to `ajilach/clamav-rest:master` (via CLI or by deleting and re-creating the branch) before proceeding.

### 2. Merge locally into a throwaway branch

```bash
git fetch origin
git checkout -b merge-upstream-$(date +%Y%m%d) master
git merge origin/upstream-master
```

### 3. Resolve conflicts

Walk the three known pressure points:

- **[entrypoint.sh](entrypoint.sh)** — make sure the `DISABLE_FRESHCLAM` guard around `freshclam --daemon` survives, and that the 120s RELOAD block stays deleted.
- **[.github/workflows/release.yaml](.github/workflows/release.yaml)** — re-apply the schedule cron, `DOCKERHUB_*` secret names, and `no-cache: true`. If upstream has split or renamed the workflow again, find the job that pushes the image and port the three tweaks there.
- **[Dockerfile](Dockerfile)** — confirm `ENV DISABLE_FRESHCLAM=true` is still in the env block.

Anything else — Go code, test files, docs — take upstream's version unless we have a specific reason not to. Smaller diff vs upstream is a goal.

### 4. Sanity check

```bash
docker build -t clamav-rest:merge-test .
docker run --rm -p 9000:9000 -e DISABLE_FRESHCLAM=true clamav-rest:merge-test
# In another shell:
curl http://localhost:9000/version
```

Look for: `clamd` starts, `clamav-rest` responds on `/version`, no `freshclam` process running, no update-failure log spam.

### 5. PR into master

Push the branch and open a PR from `merge-upstream-YYYYMMDD` → `master`. Let CI run. Squash-merge is fine; a merge commit is also fine — whichever matches the repo convention at the time. Delete the branch after.
