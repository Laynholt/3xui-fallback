# F01–F03 local producer qualification

Base: `a219c7804ca2f69a4cc8dee069cc000a28b84c0b`. Scope: accepted Task 2 and
producer metadata contract; no VPS, collector implementation, push or deployment.

Pinned runtime: official `nginx:1.30.6-alpine` at
`sha256:583b7f2fce1cdb8da5ad5c39ebd3c33b98b87d493190e548bdee1fa8c619c311`.
Observed nginx 1.30.6, Alpine 3.24.4, njs 1.0.2 and installed
`/usr/lib/nginx/modules/ngx_http_js_module.so`. Actual runtime `nginx -t` and
requests load/use this module. No custom image or source build was needed.

| Criterion | Source and local evidence | Remaining acceptance |
| --- | --- | --- |
| F01 persistence | Compose bind mount; real container recreation retains previous JSONL, rename/create/USR1 writes new inode. Actual Swatter FileReader restarts with saved cursor without recounting, then follows rotation. | Production mount/retention/permissions and persistent Guard DB qualification. Arbitrary collector outage across rotation needs backfill; see operations notes. |
| F02 original path/privacy | `swatter.js` hashes query-free original request URI after fixed secret-route aliases; fixed sensitive labels survive redirects. Unit tests check same/different paths and redaction before hashing. Real Nginx fixture has distinct probe hashes and no query/subscription/panel values. | Root-owned strict metadata adapter and normalized distinct-path fixtures; live ingress evidence. |
| F03 attribution/gate | Both TLS entries listen IPv4/IPv6. Real Nginx TCP peers and overwritten upstream XFF/X-Real-IP tested against spoofed input. Actual denied IPv6 panel request is the sole true gate; upstream403, missing404 and wrong-Host444 remain false. Gate body/status policy preserved. | Production two-source ingress chain and normalized collector/Hub evidence. Source remains observe-only. |

Fresh local checks passed:

- Existing baseline before edits: `report-findings.sh`, `sensitive-paths.sh`,
  `SWATTER_EVENTS_TEST=1 sensitive-paths.sh` (exit 0).
- Same three scripts after image/config change (exit 0).
- `node --test tests/swatter.test.mjs`: 5 passed. Initial run failed because the
  required producer module did not exist.
- `SWATTER_SOURCE=/swatter-source python3 tests/swatter-runtime.py`: passed with
  actual Compose-rendered startup command, real njs, one event per request,
  empty legacy request logs, private event mode, recreation, reopening and cursor.
- `git diff --check`: passed.

`tests/fixtures/fallback-http.jsonl` is the sanitized output from 18 actual local
TLS requests, captured on 2026-11-11. It retains actual loopback IPv4/IPv6 peers
and timestamps; it is producer evidence, not a fabricated public-IP/live fixture
or normalized parser output. The current runtime test writes a fresh capture to
`.tmp/swatter-runtime-fixture.jsonl` without modifying the committed snapshot.

The Windows/WSL Docker socket/path/network split initially prevented the old
scripts from reaching their test upstream. A test-only Linux helper on the Docker
VM host network, with the worktree mounted at the same VM path and a task-local
Docker CLI, ran them unchanged in behavior. All helper/target containers and
upstream threads from this packet were cleaned; no production collector gains
Docker privileges. Logs and copied CLI/plugin binaries stay ignored in `.tmp`.
