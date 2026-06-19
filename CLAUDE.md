# CLAUDE.md

Guidance for working on **rtorred**, an Emacs rtorrent client. Single file,
zero external dependencies (built-in `xml.el`, `url.el`, `tabulated-list`,
`auth-source`, `cl-lib`, `subr-x` only).

## This is a public repo

Never commit anything personal or secret: no real hostnames, usernames,
passwords, torrent names/hashes, IPs, or work identities. The source uses
generic placeholders (`HOST`, `myhost.example.com`, `~/.rtorrent.rpc`). Keep it
that way. Test output, diagnostics, and live-server data stay out of commits.

## Architecture (all in `rtorred.el`, top to bottom)

Layers are deliberately separable:

1. **Transport** — turns a request string into rtorrent's raw reply. Sync
   (`rtorred--rpc-call`) and async (`rtorred--rpc-call-async`) variants,
   dispatched on `rtorred-rpc-url`: local unix socket / SCGI-TCP via
   `make-network-process`, HTTP(S) via `url-retrieve`. SCGI framing is a
   netstring header block (`rtorred--scgi-wrap`).
2. **Encoding (XML-RPC)** — hand-rolled encode/decode on `xml.el`. Knows
   nothing about transport or rtorrent. Supports strings, ints, base64
   (`(:base64 . BYTES)`), arrays, structs, and faults.
3. **Command** — `rtorred-rpc` (sync) and `rtorred-rpc-async` (callback +
   errback). A `system.listMethods` probe is cached per URL so fetches can drop
   methods the server lacks (`d.multicall2` faults if *any* requested method is
   unknown).
4. **Column model** — `rtorred--all-columns` is the single source of truth: each
   column declares `:label :width :fields :format :sort`. `rtorred-columns`
   picks which show. The fetch requests exactly the union of needed fields
   (plus active filters' fields).
5. **Data model / UI** — `tabulated-list-mode`; `rtorred--render` filters,
   stores only visible torrents, prints, and re-applies mark tags.

Feature sections: marking, actions, erase (+server-side data deletion),
filtering (`/` prefix), adding torrents, detail view (`f`/`t`/`p.multicall`),
diagnostics (`rtorred-detect-time-methods`), the major mode + keymap.

## Conventions

- **Keymaps**: `defvar map (make-sparse-keymap)` then top-level `keymap-set`
  calls — NOT bindings inside the `defvar`. A plain `defvar` is a no-op on
  re-eval, which would silently keep stale bindings; the `keymap-set` calls
  re-run on every `eval-buffer` and mutate the map in place.
- **Async hot paths**: refresh and actions are async and never block. Actions
  batch over marked-or-current via `rtorred--run-batch` and refresh once on
  completion. Keep the sync API for one-off/diagnostic use.
- **marked-or-current**: actions operate on `rtorred--marked-or-current` — the
  marked set, else the torrent at point.
- **Filters** declare the `:fields` they need so the fetch pulls them even when
  the matching column is hidden; they compose with AND and hide rows from the
  data model (so hidden rows can't be acted on).
- **Server-side `rm`** (delete data): only when an `execute*` method exists;
  always confirm, showing the exact commands. Paths come only from
  `d.base_path` (never the `d.directory` fallback — that can be the shared
  root). Every target is screened by `rtorred--rm-unsafe-reason`, which refuses
  the download root or above, paths that contain another torrent's data, and
  paths shared by multiple torrents — so a delete can never escape one torrent.
  (A regression here once `rm -rf`'d a user's whole data dir; keep these layers.)

## Performance

Large views (~1000 torrents) make each auto-refresh a synchronous burst in the
async callback. Keep it cheap:

- **Parse with `libxml`** (`rtorred--parse-xml`): ~30x faster than `xml.el` on a
  500KB+ multicall response (≈860ms → ≈30ms).
- **Lean value walk**: `rtorred--xmlrpc-parse-value` avoids per-node
  `cl-remove-if-not`/`mapconcat` allocation; decode + render bind a high
  `gc-cons-threshold` so the allocation spike doesn't trigger GC pauses.
- **Memoize** computed colours (`rtorred--gradient-cache`); skip the per-row tag
  pass when nothing is marked; skip refresh entirely when the buffer is not
  visible (`get-buffer-window BUF 'visible`).
- Fewer/narrower columns and a longer `rtorred-auto-refresh-interval` both cut
  per-refresh cost. To profile, time `rtorred--xmlrpc-decode` and
  `rtorred--render` separately via the live IDE eval.

## rtorrent RPC gotchas

- `d.multicall2` is all-or-nothing — hence the availability filtering.
- Custom values (e.g. `d.custom=addtime`) can have a trailing newline;
  `string-to-number` tolerates it.
- "added/completed" time is build-specific: prefer built-in
  `d.timestamp.finished`; for a *persistent* add time prefer a custom field
  (`addtime`/`tm_loaded`) over `d.load_date` (which resets on restart).
- Multicalls take `(HASH "" cmd...)` for files/trackers/peers; `d.multicall2`
  takes `("" VIEW cmd...)`. Bare methods get a trailing `=`; methods carrying an
  argument (`d.custom=KEY`) are passed as-is.

## Testing

Run from the repo root.

- **Byte-compile** (the real lint):
  ```
  emacs -Q --batch -L . --eval '(byte-compile-file "rtorred.el")' 2>/tmp/bc.log; cat /tmp/bc.log
  ```
  Empty log = no warnings. Remove the stray `rtorred.elc` afterward.
- **Batch stdout is swallowed in this sandbox** (SIGPIPE → exit 1). Don't rely on
  `princ`/`message` to stdout; have tests `write-region` their output to a file
  and `cat` it. Wrap test bodies in `condition-case` and write the error too.
- **Logic tests**: build a buffer with `rtorred-mode`, set data via
  `rtorred--render`, and `cl-letf` `rtorred-rpc-async` to canned responses to
  assert which RPCs fire. `#'fn` not `#(fn)` (the latter is propertized-string
  read syntax and breaks the reader).
- **Transport tests**: a small mock SCGI server over a real unix socket (Python)
  verifies framing/sentinel/roundtrip end-to-end; pump with
  `accept-process-output` for the async path.
- **Live testing**: the Emacs the user runs has a configured connection; Elisp
  can be evaluated there (e.g. via the IDE integration) to probe a real server.
  Prefer the sync API for one-shot probes so results return inline.
- **Package lint** (MELPA gate): `package-lint`, `checkdoc`, and a clean
  byte-compile must all pass. `package-lint` can be installed in a throwaway
  batch Emacs (`package-user-dir` → /tmp) pointed at MELPA. Keep the header
  fields (Author, URL, Version, Package-Requires, license notice) intact and the
  summary line free of the word "Emacs".

## Releasing to MELPA

The package is package-lint clean. To publish:

1. Tag a release (`git tag -a 0.1.0 -m ...`) — MELPA Stable uses tags; plain
   MELPA uses the latest commit.
2. Fork `melpa/melpa`, add `recipes/rtorred`:
   ```elisp
   (rtorred :fetcher github :repo "re5et/rtorred")
   ```
3. Build/test it: `make recipes/rtorred` then `make sandbox INSTALL=rtorred`.
4. Open a PR to melpa/melpa.

Bump the `;; Version:` header on releases. Autoloads are generated by
package.el from the `;;;###autoload` cookies (currently on `rtorred` and
`rtorred-detect-time-methods`) — no checked-in autoloads file.
