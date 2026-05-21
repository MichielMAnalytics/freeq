# freeq preview platform

One-shot wiring that turns a freeq-running boxd VM into a "golden" that
answers `/boxd-preview` on PRs and issues by forking itself and checking
out the right branch.

Adapted from the langwatch preview-platform pattern, minus the docker-compose
machinery — freeq's stack runs natively on the host so a `git reset --hard`
plus vite's file watch is all the deploy step a frontend-only change needs.

## Layout

```
scripts/preview/
├── enable-preview.sh         one-time install (idempotent)
├── config/
│   └── webhook.conf.json.template
├── systemd/
│   └── freeq-webhook.service
└── scripts/
    ├── preview-webhook.sh    detach wrapper for /boxd-preview
    ├── golden-sync-webhook.sh detach wrapper for push events
    ├── golden-sync.sh        push event → fetch + reset + deploy
    ├── preview-handler.sh    /boxd-preview → fork + sync + URL poll
    └── freeq-deploy.sh       decide action based on changed paths
```

## Install

On the golden VM (where vite + freeq-server + freeq-auth-broker are running),
authenticate `gh` once and run the installer:

```sh
gh auth login                          # interactive, one-time
bash scripts/preview/enable-preview.sh
```

`enable-preview.sh` is idempotent: re-running it picks up edits to the
templates, rotates the webhook secret if you delete `/etc/freeq-webhook-secret`,
and replaces existing GitHub webhooks on the repo with current-secret copies.

## Deploy logic

`freeq-deploy.sh` looks at `git diff PREV..HEAD --name-only` and picks the
cheapest correct action:

| Changed paths | Action |
|---|---|
| Only `freeq-app/src/**`, `.css`, `.tsx`, etc. | **None.** Vite HMR picks it up from disk within seconds. |
| `freeq-app/package.json` or lockfile | `npm install` in `freeq-app/` (vite restarts itself). |
| `freeq-sdk-js/**` | Rebuild the SDK so vite picks up the new `dist/`. |
| `freeq-server/**`, `freeq-auth-broker/**`, `*.rs`, `Cargo.*` | **Stub only.** Writes `/tmp/freeq-restart-note` with copy-pasteable rebuild + restart instructions. `preview-handler.sh` pulls this back to the calling PR/issue and appends it to the ✅ comment. |

The stub-only approach for Rust changes is deliberate: debug rebuilds of
`freeq-server` take 2–10 min and the restart kicks every connected client.
That's the wrong trade-off to make on every PR push.

## Bot UX

```
@you on PR/issue: /boxd-preview
↳ ~1s   👀  reaction on the trigger comment
↳ ~2s   ⏳  "creating boxd preview env for `branch` → https://freeq-pr-N.boxd.sh"
↳ 5–60s ✅  ready (or 🔧 warming, or ⚠️ failed with diagnostics)
            + 🦀 "rust restart required" note if applicable
```

Issue comments default to `main`; override with `/boxd-preview branch=foo/bar`.
PR comments always use the PR's head branch.

## Cleanup

To remove the platform:

```sh
sudo systemctl disable --now freeq-webhook.service
sudo rm /etc/systemd/system/freeq-webhook.service
sudo rm /etc/freeq-webhook.conf.json /etc/freeq-webhook-secret /etc/freeq-preview.conf
sudo systemctl daemon-reload
# Then in the GitHub UI delete the two webhooks pointing at hooks.<vm>.boxd.sh
```
