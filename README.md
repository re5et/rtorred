# rtorred

An [rtorrent](https://rakshasa.github.io/rtorrent/) client for Emacs, in the
spirit of `dired` and `proced`: a live, sortable, filterable buffer of your
downloads that you act on with single-key commands.

> Status: early but usable. Zero external dependencies — just Emacs.

## Features

- **Pluggable transport**, chosen by one URL variable — all carrying the same
  XML-RPC payload:
  - local SCGI **unix socket** (`~/.rtorrent.rpc`)
  - SCGI over **TCP** (`scgi://host:5000`)
  - XML-RPC over **HTTP(S)** (`https://host/RPC2`), with **basic auth** via
    `auth-source`
- **Asynchronous** RPC — Emacs never blocks waiting on rtorrent — with a
  proced-style **auto-refresh** timer.
- **Declarative, configurable columns** (name, size, progress, rates, ratio,
  status, added/completed time, …) with numeric-aware sorting.
- **dired-style marking** (`*` marks, `D` erase flags) and actions on the
  marked-or-current set: start, stop, hash-check, priority.
- **Erase**, optionally **also deleting the data server-side** (via rtorrent's
  `execute`), feature-detected and with path-safety guards.
- **Detail view** (`RET`): overview, files, trackers, peers.
- **Add** a `.torrent` file (uploaded as base64) or a magnet/URL.
- **Filtering** (`/` prefix): done, ratio, status, active, downloading, name —
  composed with AND; hidden rows can't be marked or operated on.

## Requirements

- Emacs 29.1+
- rtorrent with its XML-RPC/SCGI interface enabled (any reasonably recent
  build; everything degrades gracefully when a method is missing).

## Installation

### use-package + `:vc` (Emacs 30+, no package archive needed)

Installs straight from this repo:

```elisp
(use-package rtorred
  :vc (:url "https://github.com/re5et/rtorred" :rev :newest)
  :commands (rtorred rtorred-detect-time-methods)
  :custom (rtorred-rpc-url "https://myhost.example.com/RPC2"))
```

### use-package + MELPA

Once the package is on [MELPA](https://melpa.org):

```elisp
(use-package rtorred
  :ensure t
  :commands (rtorred rtorred-detect-time-methods)
  :custom (rtorred-rpc-url "~/.rtorrent.rpc"))
```

(Ensure MELPA is in `package-archives`.)

### Manual

```elisp
(add-to-list 'load-path "/path/to/rtorred")
(require 'rtorred)
```

`rtorred` and `rtorred-detect-time-methods` are autoloaded, so `M-x rtorred`
works without an explicit `require`.

## Configuration

Point rtorred at rtorrent. The transport is inferred from the URL:

```elisp
;; local unix socket (network.scgi.open_local in rtorrent.rc)
(setq rtorred-rpc-url "~/.rtorrent.rpc")

;; SCGI over TCP (network.scgi.open_port)
(setq rtorred-rpc-url "scgi://localhost:5000")

;; XML-RPC over HTTP(S), e.g. behind nginx/apache or a seedbox panel
(setq rtorred-rpc-url "https://myhost.example.com/RPC2")
```

### Authentication (HTTP only)

Keep credentials out of your config with `auth-source`. Add a line to
`~/.authinfo.gpg` (or `~/.authinfo`):

```
machine myhost.example.com login alice password s3cret port 443
```

Credentials are sent preemptively as HTTP Basic auth. (You can also embed them
in the URL, or set `rtorred-http-auth` to a `(USER . PASS)` cons — both less
private than `auth-source`.)

### Timestamps

"Added" and "Completed" times vary by rtorrent build. Run:

```
M-x rtorred-detect-time-methods
```

once per server. It probes the available methods (and a sample torrent's custom
fields, e.g. ruTorrent's `addtime`) and auto-sets `rtorred-added-time-method` /
`rtorred-completed-time-method` to the best available source. Persist the
chosen values in your init if you like, or just run the command on startup.

(The set of available methods is cached per connection; `M-x
rtorred-refresh-methods` forgets it, e.g. after the server is upgraded.)

### Columns and sorting

```elisp
;; which columns, in order (keys; see the docstring for the full set)
(setq rtorred-columns '(name size done up ratio status added))

;; override individual column widths (Name flexes regardless)
(setq rtorred-column-widths '((status . 11) (ratio . 6)))

;; initial sort: (COLUMN-KEY . DIRECTION), or nil for rtorrent's view order
(setq rtorred-default-sort '(added . descending))   ; newest first
```

The Name column flexes to fill the window width left over by the other
columns (truncating only when it must), down to `rtorred-name-min-width`. With
many columns on a narrow window it bottoms out at that minimum — trim
`rtorred-columns` or widen the window to give names more room.

### Colors

```elisp
;; Done % and Ratio get a red -> yellow -> green gradient
(setq rtorred-percent-gradient t)
(setq rtorred-ratio-gradient t
      rtorred-ratio-good 2.0)   ; ratio coloured fully green
```

Status cells use the customizable faces in the `rtorred-faces` group. The
current line is highlighted via `hl-line`:

```elisp
(setq rtorred-hl-line t)              ; nil to disable; restyle the `hl-line' face
```

### Auto-refresh

```elisp
(setq rtorred-auto-refresh-interval 3)   ; seconds; nil to disable
(setq rtorred-render-idle-delay 0.2)     ; redraw after this much idle; nil = immediate
```

Refreshing is non-blocking and pauses while a minibuffer command (e.g. a
`consult` search) is reading from the buffer.

### Other options

```elisp
(setq rtorred-view "main")            ; rtorrent view to list (main/started/stopped/...)
(setq rtorred-rpc-timeout 10)         ; seconds to wait for a reply
(setq rtorred-time-format "%Y-%m-%d %H:%M")  ; Added / Done-At columns
```

## Usage

`M-x rtorred`.

| Key | Action |
|-----|--------|
| `n` / `p` | move |
| `m` / `u` / `DEL` / `U` / `t` | mark / unmark / unmark-back / unmark-all / toggle |
| `s` / `k` | start / stop |
| `P` | pause / resume (toggles per torrent) |
| `c` | hash-check |
| `+` / `-` | raise / lower priority |
| `d` / `x` | flag for erase / execute flagged erases |
| `D` | erase marked-or-current now |
| `a` / `A` | add torrent file / magnet or URL (prefix arg = don't start) |
| `RET` / `i` | detail view (files, trackers, peers) |
| `S` | sort (completes a column when point isn't on one) |
| `g` / `G` | refresh / toggle auto-refresh |
| `q` | quit |

Actions apply to the **marked** torrents, or the one at point if none are
marked. Statuses are color-coded (seeding / leeching / stopped / hashing /
error), customizable via the `rtorred-faces` group.

### Detail view (`RET` / `i`)

A read-only buffer with the download's overview, files, trackers and peers. It's
interactive:

- on a **file** line, `+` / `-` raise/lower that file's priority (off / normal /
  high), applied immediately;
- on a **tracker** line, `t` enables/disables it;
- `g` refreshes, `q` quits.

### Filtering (`/` prefix)

| Key | Filter |
|-----|--------|
| `/ d` | 100% done |
| `/ r` | ratio greater than N |
| `/ s` | status |
| `/ a` | active (started, not paused) |
| `/ D` | actively downloading (download rate > 0) |
| `/ f` | name matches regexp |
| `/ p` | pop last filter |
| `/ x` (or `/ /`) | clear all filters |

Filters compose with AND and narrow the data model, so hidden torrents are not
markable or operable. The mode-line shows the torrent count — `shown/total`
when filtered, plain total otherwise — alongside a `↻` while refreshing, the
auto-refresh interval, and any active filters.

## Deleting data (security note)

"Erase + delete data" works by asking rtorrent to `rm -rf` the data on its own
host via the `execute` command — the only way for a remote client to remove
remote files. rtorred feature-detects `execute` and hides the option when it's
unavailable, refuses obviously unsafe paths, and — before deleting anything —
lists the exact `rm -rf -- <path>` commands it will run, dired-style, and asks
you to confirm.

Be aware: an rtorrent XML-RPC endpoint that exposes `execute` is effectively a
remote code execution surface. Protect it (TLS, auth, network restrictions) and
run rtorrent as an unprivileged user.

## License

GPL-3.0-or-later.
