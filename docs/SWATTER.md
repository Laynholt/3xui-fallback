# Optional safe HTTP events

Enable only with `docker compose -f docker-compose.yml -f compose.swatter.yml up -d`.
The default remains disabled. Both TLS entries write `http.jsonl` directly into
`SWATTER_LOG_DIR` (default `./.tmp/swatter-logs`). Preserve this directory through
container recreation and until retention ends; do not clean it as disposable scratch.
Mount it read-only into Guard. Guard needs no Docker socket or Docker API privileges.

Enabled mode replaces combined access logs with safe JSONL and suppresses the
panel/subscription native error logs, whose request context can expose secrets.
The safe diagnostics are final HTTP status, transport peer, route class and gate
verdict. Detailed upstream/TLS error text is unavailable in this mode. Startup
and `nginx -t` diagnostics remain in container stderr. Disabled mode retains
the previous combined and error logs. Do not add raw debug request logs to the
enabled mode.

## Migrating an existing stdout collector

This changes the event transport: `moskit.http.v1` is written to the mounted
`http.jsonl`, not to container stdout. The previous `docker logs` bridge will
receive no new HTTP events after the update. Migrate it before treating the
collector as healthy; pulling and recreating the container alone is insufficient.
There is a collection gap during the cutover, not a lossless handoff.

1. Back up the current Compose/environment configuration and Guard configuration,
   database and cursors using their supported backup procedure. Retain the old
   `3xui-fallback.jsonl` and rotated history with private permissions. Do not
   truncate logs, reset cursors or delete the Guard database.
2. Set `SWATTER_LOG_DIR` in `.env` to a persistent absolute host directory, for
   example `/opt/3xui-fallback/swatter-logs`, and create it with permissions that
   let Nginx write and the collector's chosen group read. New files are created
   by root with mode `0640`: use a setgid directory owned by the reader group
   or an equivalent inherited ACL, and check existing file ownership too.
   Directory read permission alone does not grant access to `http.jsonl`. Keep it through
   container recreation and retention; do not make the directory or logs
   world-readable. Confirm the override mounts it at `/var/log/swatter`.
3. Freeze the old file by stopping and disabling only the previously documented
   forwarding service:

   ```sh
   sudo systemctl disable --now 3xui-fallback-swatter.service
   ```

   Adapt the unit name if it was customized. Then let the old collector consume
   the remaining file to its final offset and confirm that its final cursor is
   persisted. Preserve that latest cursor and remove the old source from the
   active collector configuration. Retain the file/history. The bridge must not
   resume tailing `docker logs` after the cutover. Other Guard sources need no
   configuration changes.
4. Update with **both** Compose files, preserving the enabled event mode:

   ```sh
   docker compose -f docker-compose.yml -f compose.swatter.yml pull
   docker compose -f docker-compose.yml -f compose.swatter.yml up -d
   ```

5. Give Guard a read-only bind mount of the chosen host directory, for example
   at `/var/log/swatter/fallback`. Configure a new, unused source ID so the old
   file's inode/offset is not applied to this file:

   ```json
   {"id":"fallback_http_file_v2","type":"file","path":"/var/log/swatter/fallback/http.jsonl","parser":"nginx_json","service":"fallback","start_at_end":false,"nft_eligible":false,"trusted_success":false,"options":{"log_visits":true}}
   ```

   Apply the collector configuration through its supported reload/restart
   procedure. Keep its database and unrelated sources; do not reuse or reset
   the old cursor. With a fresh ID and `start_at_end:false`, consume the new
   file from its beginning, including events written during collector setup.
   Keep this source observe-only, without `gate_statuses:[404]`.
6. Retire the old bridge's dedicated logrotate stanza after it has stopped
   writing. Keep the old files for their retention period. Install the
   rename/create/USR1 rule below for the **actual new host path**, with the
   chosen reader group. Ensure only one rule owns the new file; the old
   copytruncate rule must not be carried over to it.
7. Send a normal request to each configured TLS entry. Confirm new lines in
   `/var/log/swatter/http.jsonl` inside Nginx **and** newly received events under
   the new Guard source ID, including the expected peer/status. A line in the
   producer file alone does not verify collection. Confirm the old bridge is
   stopped and test rotation/cursor continuation before relying on monitoring.

If cutover fails, keep the source observe-only and retain both log histories.
For routine rollback, restore the previous image, config and Compose files,
then re-enable the old collector source using its retained latest cursor in
the existing Guard database. Do not restore the whole pre-cutover database or
an earlier cursor: that can discard unrelated/new events or recount old ones.
Restart the old stdout bridge only after restoring a producer that writes
stdout; do not point its saved offset at the new file. Full database restoration
is a separate recovery procedure, not part of this routine rollback.

## Producer contract

Schema remains `moskit.http.v1`: `ts`, `peer_ip`, original fixed `method`, safe
`uri`, final `status`, configured `host`, plus optional `path_hash`, `route_class`, `gate_denied`.
The pinned full image includes njs 1.0.2; Nginx loads its actual JS module.

`path_hash` is lowercase SHA-256 of the original query-free path after redaction.
Unknown `/probe-a` and `/probe-b` have distinct stable hashes while `uri` stays
`/_other`, even after the same 404 internal redirect. Query changes do not change
the hash. Known panel/subscription prefixes **and their dynamic remainder** are
replaced with `/_panel` and `/_subscription` before hashing. Sensitive suffixes
`/.env`, `/.git/config`, `/wp-login.php`, `/xmlrpc.php` retain fixed labels at any
depth, including percent-encoded dotfiles. Ambiguous paths (dot segments,
duplicate slashes, malformed/nested escapes, backslashes and control characters)
collapse to `/_other` before hashing, sacrificing distinct-path counts for those
spellings. Trailing slashes in configured prefixes do not defeat redaction.
The host is the normalized, validated configured SITE_DOMAIN DNS name; invalid
configuration emits an empty host. It never comes from a request header.
No arbitrary raw path, query, client-supplied Host,
headers or body is written to the primary event.

`peer_ip` is the TCP transport `$remote_addr`, including IPv6. Incoming X-Real-IP
and X-Forwarded-For cannot override it; Nginx overwrites both upstream headers.
There is no HTTP proxy trust configuration here: an upstream proxy that terminates
the connection becomes the peer. Qualify the actual ingress before relying on
client attribution. Both TLS entries explicitly listen on IPv4 and IPv6.

Only the panel allow/deny locations can select the denial error-page marker.
That server-owned marker with no upstream status sets
`gate_denied=true`. Upstream 403, ordinary 404 and wrong-Host 444 set false.
This verdict does not depend on the original path spelling, so normalized panel
paths still report the real gate denial.
Denied panel requests still receive the same public 404 page. The internal
marker itself is not publicly accessible.

The root-owned Swatter adapter must validate/use the optional metadata. An old
parser reads base records but does not preserve the new distinct-path/gate
semantics. Do not claim normalized acceptance until the adapter is qualified.

## Rotation and cursor

One host logrotate owner uses rename/create plus USR1, never copytruncate.
For an installation at `/opt/3xui-fallback` (replace with the actual path):

```text
/opt/3xui-fallback/.tmp/swatter-logs/http.jsonl {
    daily
    maxsize 10M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        /usr/bin/docker kill --signal=USR1 3xui-fallback >/dev/null
    endscript
}
```

Schedule logrotate for the disk budget: `maxsize` is evaluated only when it runs.
USR1 reopens the new inode; until then Nginx writes the renamed file. Guard must
drain the old inode before the next rotation. If Guard is stopped during rotation,
unconsumed rotated files need controlled backfill: this is not a lossless spool
across arbitrary outages or full disks. `delaycompress` preserves the last old
file. Assign read access through the chosen local group and adjust `create`
accordingly; never make private logs world-readable.

Preserve Guard's DB/cursor across restarts and configure its read-only mount:

```json
{"id":"fallback_http","type":"file","path":"/var/log/swatter/http.jsonl","parser":"nginx_json","service":"fallback","start_at_end":false,"nft_eligible":false,"trusted_success":false,"options":{"log_visits":true}}
```

Keep this source observe-only. Do not configure `gate_statuses:[404]`: ordinary
404 responses do not prove an IP gate denial. Disable only this source and roll
back image/config/Compose together, retaining log files for their retention.

## Qualification

Linux requires Docker, Python 3, curl and OpenSSL. Unit checks also require Node:

```sh
node --test tests/swatter.test.mjs
bash tests/report-findings.sh
bash tests/sensitive-paths.sh
SWATTER_EVENTS_TEST=1 bash tests/sensitive-paths.sh
SWATTER_SOURCE=/path/to/swatter python3 tests/swatter-runtime.py
# Each runtime case also works in isolation, with its own container and logs.
python3 tests/swatter-runtime.py Runtime.test_normalized_raw_paths
python3 tests/swatter-runtime.py Runtime.test_end_to_end
```

The runtime test uses real Nginx/njs on both TLS entries, IPv4/IPv6, spoofed
headers, actual gate vs upstream errors, persistent recreation, rename/USR1
and the actual Swatter FileReader with saved cursors and rotation. Without
`SWATTER_SOURCE`, cursor qualification is explicitly NOT_RUN. All temporary
files stay in project `.tmp`; exact owned containers and upstream threads are
cleaned after failures too. This is local source qualification, not production
ingress, live rollout or normalized collector/Hub acceptance.
