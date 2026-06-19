;;; rtorred.el --- Manage rtorrent downloads -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: atom
;; Assisted-by: Claude Code:claude-opus-4-8
;; URL: https://github.com/re5et/rtorred
;; Keywords: comm, files, processes
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; rtorred is an rtorrent client for Emacs, in the spirit of `dired' and
;; `proced': a tabular buffer listing your downloads that you act on with
;; single-key commands.
;;
;; It talks to rtorrent over XML-RPC -- the universal interface every stock
;; rtorrent build understands.  The transport is pluggable and selected by
;; the value of `rtorred-rpc-url':
;;
;;   "~/.rtorrent.rpc"        SCGI over a local unix socket (the common case)
;;   "scgi://localhost:5000"  SCGI over TCP (headless / remote boxes)
;;   "https://host/RPC2"      XML-RPC over HTTP(S) (behind nginx/apache, TLS)
;;
;; The same XML-RPC payload rides every transport, so covering all three is
;; nearly free.  The encoding layer is kept separate from both the transport
;; and the command layer, so a different encoding (e.g. JSON-RPC) could drop
;; in later without disturbing the rest.
;;
;; This first cut is synchronous: each RPC call blocks until rtorrent
;; answers.  The seam is `rtorred--rpc-call'; an async transport can replace
;; it without touching the encoding or UI layers.
;;
;; Usage: M-x rtorred

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)
(require 'hl-line)
(require 'xml)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'auth-source)
(require 'tabulated-list)

;;;; Customization

(defgroup rtorred nil
  "Manage rtorrent downloads from Emacs."
  :group 'comm
  :prefix "rtorred-")

(defcustom rtorred-rpc-url "~/.rtorrent.rpc"
  "How to reach rtorrent's XML-RPC interface.

The transport is chosen by the form of this string:

  a file path (e.g. \"~/.rtorrent.rpc\")  SCGI over a local unix socket
  \"scgi://HOST:PORT\"                      SCGI over TCP
  \"http://...\" or \"https://...\"           XML-RPC over HTTP(S)

The unix-socket path corresponds to rtorrent's
`network.scgi.open_local', the TCP form to `network.scgi.open_port',
and the HTTP form to a web server proxying SCGI (or a built-in httpd)."
  :type 'string)

(defcustom rtorred-view "main"
  "The rtorrent view to list.

Common values are \"main\" (everything), \"started\", \"stopped\",
\"complete\", and \"incomplete\"."
  :type 'string)

(defcustom rtorred-rpc-timeout 10
  "Seconds to wait for rtorrent to answer an RPC call."
  :type 'number)

(defcustom rtorred-never-delete-data nil
  "When non-nil, never delete a torrent's data from the server.
Erase still removes torrents from rtorrent, but the \"also delete data\"
option is never offered and no `rm' is ever sent -- files are always left
on disk.  A hard safety switch above the per-path guards."
  :type 'boolean)

(defcustom rtorred-retry-smart t
  "Whether \\[rtorred-retry] picks its remedy from the error message.
When non-nil, retry re-checks the hash for hash/data errors and
re-announces for tracker errors.  When nil, retry always just clears the
message and re-announces.  A prefix argument forces the latter."
  :type 'boolean)

(defcustom rtorred-http-auth nil
  "HTTP basic-auth credentials for the HTTP(S) transport.

Only consulted when `rtorred-rpc-url' is an http(s) URL.  Either:

  nil           Look credentials up via `auth-source' (the default).
  (USER . PASS) Use these explicit credentials.

With nil, credentials are taken from `auth-source' -- e.g. a line in
~/.authinfo.gpg like

  machine HOST login USER password PASS port 443

which keeps the password out of your configuration (and, with the
.gpg variant, encrypted at rest).  Credentials embedded directly in
`rtorred-rpc-url' (https://user:pass@host/RPC2) are also honoured.
The lookup order is: this variable, then the URL, then `auth-source'."
  :type '(choice (const :tag "Use auth-source / URL" nil)
                 (cons (string :tag "User") (string :tag "Password"))))

(defcustom rtorred-columns
  '(name size done down up ratio status added completed)
  "Columns shown in the rtorred buffer, in order, by key.

Each key must name a column defined in `rtorred--all-columns'; the
available keys are: name, size, done, down, up, uploaded, ratio,
peers, seeds, status, added, completed, directory, priority.  Reorder or trim this
list to taste -- adding a brand-new column means defining it in
`rtorred--all-columns' and adding its key here."
  :type '(repeat symbol))

(defcustom rtorred-name-min-width 20
  "Minimum width of the Name column.
The Name column flexes to fill the window width left over by the other
columns, but never shrinks below this."
  :type 'integer)

(defcustom rtorred-column-widths nil
  "Alist of (COLUMN-KEY . WIDTH) overriding default column widths.
Keys are as in `rtorred-columns'; unlisted columns keep their default
width.  The Name column flexes regardless of any override here.  Takes
effect for buffers opened afterwards."
  :type '(alist :key-type symbol :value-type integer))

(defcustom rtorred-default-sort '(name . ascending)
  "Initial sort for new rtorred buffers.

Either nil (leave the list in rtorrent's own view order), or a cons
\(COLUMN-KEY . DIRECTION) where COLUMN-KEY is one of the keys in
`rtorred-columns' and DIRECTION is `ascending' or `descending'.  If the
chosen column is not shown or not sortable, the first sortable column is
used.  Takes effect for buffers opened afterwards (reopen with
\\[rtorred] to apply)."
  :type '(choice (const :tag "rtorrent view order" nil)
                 (cons :tag "Column and direction"
                       (symbol :tag "Column key")
                       (choice (const :tag "Ascending" ascending)
                               (const :tag "Descending" descending)))))

(defcustom rtorred-added-time-method "d.load_date"
  "RPC method providing a download's \"added\" time, as a Unix epoch.

Stock rtorrent has no stable add-time.  `d.load_date' exists on
newer builds but reflects when the item was loaded into the *current*
session (it resets on restart).  For a persistent add-time, point this
at a custom field your rtorrent.rc populates, e.g. \"d.custom=tm_loaded\"
or \"d.custom=addtime\".  If the method is unavailable, the Added column
simply renders blank."
  :type 'string)

(defcustom rtorred-completed-time-method "d.timestamp.finished"
  "RPC method providing a download's completion time, as a Unix epoch.

`d.timestamp.finished' exists on newer rtorrent (0.9.8+) and persists.
On older builds, point this at a custom field, e.g.
\"d.custom=tm_completed\".  If unavailable, the column renders blank."
  :type 'string)

(defcustom rtorred-time-format "%Y-%m-%d %H:%M"
  "`format-time-string' format for the Added and Done-At columns.
Ignored when `rtorred-time-relative' is non-nil."
  :type 'string)

(defcustom rtorred-time-relative nil
  "When non-nil, show the Added and Done-At columns as relative ages.
E.g. \"3d\", \"5h\", \"2w\" instead of an absolute timestamp."
  :type 'boolean)

(defcustom rtorred-auto-refresh-interval 5
  "Seconds between automatic refreshes of an rtorred buffer.
A number enables auto-refresh (like `proced'); nil disables it, leaving
only manual refresh via \\[revert-buffer].  Toggle per-buffer with
`rtorred-toggle-auto-refresh'."
  :type '(choice (const :tag "Disabled" nil) (number :tag "Seconds")))

(defcustom rtorred-render-idle-delay 0.2
  "Idle delay, in seconds, before redrawing after an async refresh.
Redrawing a large list is the costliest synchronous step of a refresh;
waiting for this much idle time keeps that redraw from interrupting
typing.  nil redraws immediately (no deferral)."
  :type '(choice (const :tag "Immediate" nil) (number :tag "Seconds")))

;;;; Faces

(defgroup rtorred-faces nil
  "Faces used by rtorred."
  :group 'rtorred)

(defface rtorred-seeding '((t :inherit success))
  "Face for the status of seeding (complete, active) torrents.")

(defface rtorred-leeching '((t :inherit font-lock-keyword-face))
  "Face for the status of leeching (downloading) torrents.")

(defface rtorred-stopped '((t :inherit shadow))
  "Face for the status of stopped or paused torrents.")

(defface rtorred-hashing '((t :inherit warning))
  "Face for the status of torrents being hash-checked.")

(defface rtorred-errored '((t :inherit error))
  "Face for the status of torrents with an error message.")

(defface rtorred-refreshing '((t :inherit success))
  "Face for the mode-line refresh icon while a refresh is in flight.
The icon appears only while auto-refresh is on -- in `shadow' when idle
and this face while actually refreshing -- and is absent when off.")

(defcustom rtorred-percent-gradient t
  "Whether to color the Done column by a red-to-green completion gradient.
When non-nil, a torrent's percentage is shown in a colour interpolated
from red (0%) through yellow to green (100%)."
  :type 'boolean
  :group 'rtorred-faces)

(defcustom rtorred-ratio-gradient t
  "Whether to color the Ratio column by a red-to-green gradient.
Red at 0, yellow at break-even (1.0), green at `rtorred-ratio-good'."
  :type 'boolean
  :group 'rtorred-faces)

(defcustom rtorred-ratio-good 2.0
  "Share ratio that the Ratio gradient colours fully green.
Ratios at or above this are green; 1.0 is yellow; 0 is red."
  :type 'number
  :group 'rtorred-faces)

(defcustom rtorred-hl-line t
  "Whether to highlight the current line in an rtorred buffer.
Enables `hl-line-mode'; the highlight uses the `hl-line' face."
  :type 'boolean
  :group 'rtorred-faces)

;;;; Transport layer
;;
;; Everything here turns a finished XML-RPC request string into rtorrent's
;; raw XML-RPC response string.  Nothing above this layer knows whether the
;; bytes travelled over a unix socket, TCP, or HTTP.

(defun rtorred--scgi-wrap (xml)
  "Frame XML, an XML-RPC request string, as an SCGI request.

An SCGI request is a netstring-encoded header block followed by the
body.  The first header must be CONTENT_LENGTH, and an SCGI=1 header
must be present; headers are NUL-separated key/value pairs."
  (let* ((body (encode-coding-string xml 'utf-8))
         (nul (string 0))
         (headers (concat "CONTENT_LENGTH" nul (number-to-string (length body)) nul
                          "SCGI" nul "1" nul)))
    (concat (number-to-string (length headers)) ":" headers "," body)))

(defun rtorred--strip-cgi-headers (raw)
  "Return the body of RAW, a CGI-style response, dropping its headers.
The header block ends at the first blank line."
  (if (string-match "\r?\n\r?\n" raw)
      (substring raw (match-end 0))
    raw))

(defun rtorred--net-roundtrip (make-proc request)
  "Open a connection via MAKE-PROC, send REQUEST, return the raw reply.
MAKE-PROC is a function of one argument (the process buffer) that
returns a connected network process.  Blocks until the peer closes the
connection or `rtorred-rpc-timeout' elapses."
  (let ((buf (generate-new-buffer " *rtorred-conn*" t))
        (done nil)
        (proc nil))
    (unwind-protect
        (progn
          (setq proc (funcall make-proc buf))
          (set-process-coding-system proc 'binary 'binary)
          (set-process-query-on-exit-flag proc nil)
          (set-process-sentinel
           proc
           (lambda (_p event)
             (when (string-match-p
                    "\\(finished\\|exited\\|broken\\|closed\\|deleted\\|failed\\)"
                    event)
               (setq done t))))
          (process-send-string proc request)
          (let ((deadline (+ (float-time) rtorred-rpc-timeout)))
            (while (and (not done) (< (float-time) deadline))
              (accept-process-output proc 0.2)))
          (with-current-buffer buf (buffer-string)))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer buf))))

(defun rtorred--basic-auth (user pass)
  "Return an Authorization header cons for USER and PASS."
  (cons "Authorization"
        (concat "Basic "
                (base64-encode-string
                 (encode-coding-string (concat user ":" pass) 'utf-8) t))))

(defun rtorred--http-auth-header (url)
  "Return a preemptive basic-auth Authorization header for URL, or nil.
Credentials are sought, in order, from `rtorred-http-auth', then from
URL itself, then from `auth-source'."
  (let* ((parsed (url-generic-parse-url url))
         (host (url-host parsed))
         (port (url-port parsed)))
    (cond
     (rtorred-http-auth
      (rtorred--basic-auth (car rtorred-http-auth) (cdr rtorred-http-auth)))
     ((and (url-user parsed) (url-password parsed))
      (rtorred--basic-auth (url-user parsed) (url-password parsed)))
     (host
      (when-let* ((found (or (car (auth-source-search
                                   :host host :port port
                                   :require '(:user :secret) :max 1))
                             (car (auth-source-search
                                   :host host
                                   :require '(:user :secret) :max 1))))
                  (user (plist-get found :user))
                  (secret (plist-get found :secret)))
        (rtorred--basic-auth
         user (if (functionp secret) (funcall secret) secret)))))))

(defun rtorred--http-roundtrip (url xml)
  "POST XML to URL as an XML-RPC call and return the raw response body."
  (let ((url-request-method "POST")
        ;; Disable keep-alive: with frequent polling, url.el reuses cached
        ;; connections the server has since closed, failing with "Writing to
        ;; process: invalid argument".  A fresh connection each call is robust.
        (url-http-attempt-keepalives nil)
        (url-request-extra-headers
         (let ((auth (rtorred--http-auth-header url)))
           (append '(("Content-Type" . "text/xml"))
                   (and auth (list auth)))))
        (url-request-data (encode-coding-string xml 'utf-8)))
    (let ((reply-buf (url-retrieve-synchronously url t t rtorred-rpc-timeout)))
      (unless reply-buf
        (error "rtorred: no response from %s" url))
      (with-current-buffer reply-buf
        (unwind-protect
            (progn
              (goto-char (point-min))
              (if (re-search-forward "\r?\n\r?\n" nil t)
                  (buffer-substring-no-properties (point) (point-max))
                (buffer-string)))
          (kill-buffer reply-buf))))))

(defun rtorred--rpc-call (xml)
  "Send XML, an XML-RPC request string, and return rtorrent's raw reply.
Dispatches on `rtorred-rpc-url' to pick the transport."
  (let ((url rtorred-rpc-url))
    (cond
     ;; XML-RPC over HTTP(S).
     ((string-match-p "\\`https?://" url)
      (rtorred--http-roundtrip url xml))
     ;; SCGI over TCP.
     ((string-match "\\`scgi://\\([^:/]+\\):\\([0-9]+\\)" url)
      (let ((host (match-string 1 url))
            (port (string-to-number (match-string 2 url))))
        (rtorred--strip-cgi-headers
         (rtorred--net-roundtrip
          (lambda (buf)
            (make-network-process :name "rtorred-scgi" :buffer buf
                                  :host host :service port
                                  :coding 'binary :noquery t))
          (rtorred--scgi-wrap xml)))))
     ;; SCGI over a local unix socket (a bare path, optionally scgi://-prefixed).
     (t
      (let ((path (expand-file-name (replace-regexp-in-string "\\`scgi://" "" url))))
        (rtorred--strip-cgi-headers
         (rtorred--net-roundtrip
          (lambda (buf)
            (make-network-process :name "rtorred-scgi" :buffer buf
                                  :family 'local :service path
                                  :coding 'binary :noquery t))
          (rtorred--scgi-wrap xml))))))))

;;;; Asynchronous transport
;;
;; The blocking part of an RPC is waiting for rtorrent to *compute and send*
;; the reply, not the connect.  So we connect synchronously (fast, local or
;; one round-trip) but read the response via a process sentinel, and use
;; `url-retrieve' (async) for HTTP.  Each call takes a CALLBACK invoked with
;; the raw reply body, and an ERRBACK invoked with an error message string.

(defun rtorred--net-timeout (proc)
  "Abort PROC and report a timeout to its errback."
  (when (process-live-p proc)
    (process-put proc 'rtorred-timed-out t)
    (let ((errback (process-get proc 'rtorred-errback))
          (pbuf (process-buffer proc)))
      (delete-process proc)
      (when (buffer-live-p pbuf) (kill-buffer pbuf))
      (funcall errback "timed out"))))

(defun rtorred--net-sentinel (proc event)
  "Sentinel for an async SCGI connection: deliver the reply when PROC closes."
  (unless (process-live-p proc)
    (let ((timer (process-get proc 'rtorred-timer)))
      (when timer (cancel-timer timer)))
    (unless (process-get proc 'rtorred-timed-out)
      (let ((callback (process-get proc 'rtorred-callback))
            (errback (process-get proc 'rtorred-errback))
            (pbuf (process-buffer proc)))
        (let ((raw (and (buffer-live-p pbuf)
                        (with-current-buffer pbuf (buffer-string)))))
          (when (buffer-live-p pbuf) (kill-buffer pbuf))
          (if (and raw (> (length raw) 0))
              (funcall callback raw)
            (funcall errback (format "connection closed (%s)"
                                     (string-trim (or event ""))))))))))

(defun rtorred--net-roundtrip-async (make-proc request callback errback)
  "Open a connection via MAKE-PROC, send REQUEST, deliver the reply async.
On success CALLBACK is called with the raw reply; on connect failure or
timeout ERRBACK is called with a message."
  (let ((buf (generate-new-buffer " *rtorred-conn*" t))
        (proc nil))
    (condition-case err
        (setq proc (funcall make-proc buf))
      (error (kill-buffer buf)
             (funcall errback (error-message-string err))))
    (when proc
      (set-process-coding-system proc 'binary 'binary)
      (set-process-query-on-exit-flag proc nil)
      (process-put proc 'rtorred-callback callback)
      (process-put proc 'rtorred-errback errback)
      (process-put proc 'rtorred-timer
                   (run-at-time rtorred-rpc-timeout nil
                                #'rtorred--net-timeout proc))
      (set-process-sentinel proc #'rtorred--net-sentinel)
      (process-send-string proc request))))

(defun rtorred--http-roundtrip-async (url xml callback errback)
  "POST XML to URL as an XML-RPC call, delivering the reply body async."
  (let ((url-request-method "POST")
        ;; See `rtorred--http-roundtrip': keep-alive reuse of server-closed
        ;; connections is the source of dropped/leaked polls.
        (url-http-attempt-keepalives nil)
        (url-request-extra-headers
         (let ((auth (rtorred--http-auth-header url)))
           (append '(("Content-Type" . "text/xml"))
                   (and auth (list auth)))))
        (url-request-data (encode-coding-string xml 'utf-8)))
    (condition-case err
        (url-retrieve
         url
         (lambda (status)
           ;; Always kill the response buffer -- on the error path too, or
           ;; failed polls leak a buffer (and a connection) each cycle.
           (let ((err (plist-get status :error))
                 (rbuf (current-buffer)))
             (unwind-protect
                 (if err
                     (funcall errback (format "%s" err))
                   (goto-char (point-min))
                   (let ((body (if (re-search-forward "\r?\n\r?\n" nil t)
                                   (buffer-substring-no-properties (point) (point-max))
                                 (buffer-string))))
                     (funcall callback body)))
               (when (buffer-live-p rbuf) (kill-buffer rbuf)))))
         nil t t)
      (error (funcall errback (error-message-string err))))))

(defun rtorred--rpc-call-async (xml callback errback)
  "Send XML asynchronously, dispatching on `rtorred-rpc-url'.
CALLBACK receives the raw XML-RPC reply body; ERRBACK an error string."
  (let ((url rtorred-rpc-url))
    (cond
     ((string-match-p "\\`https?://" url)
      (rtorred--http-roundtrip-async url xml callback errback))
     ((string-match "\\`scgi://\\([^:/]+\\):\\([0-9]+\\)" url)
      (let ((host (match-string 1 url))
            (port (string-to-number (match-string 2 url))))
        (rtorred--net-roundtrip-async
         (lambda (buf)
           (make-network-process :name "rtorred-scgi" :buffer buf
                                 :host host :service port
                                 :coding 'binary :noquery t))
         (rtorred--scgi-wrap xml)
         (lambda (raw) (funcall callback (rtorred--strip-cgi-headers raw)))
         errback)))
     (t
      (let ((path (expand-file-name (replace-regexp-in-string "\\`scgi://" "" url))))
        (rtorred--net-roundtrip-async
         (lambda (buf)
           (make-network-process :name "rtorred-scgi" :buffer buf
                                 :family 'local :service path
                                 :coding 'binary :noquery t))
         (rtorred--scgi-wrap xml)
         (lambda (raw) (funcall callback (rtorred--strip-cgi-headers raw)))
         errback))))))

;;;; Encoding layer: XML-RPC
;;
;; Hand-rolled encode/decode on top of the built-in `xml.el'.  Kept free of
;; any transport or rtorrent specifics so it could be swapped wholesale.

(defun rtorred--xml-escape (s)
  "Escape the XML metacharacters in string S."
  (replace-regexp-in-string
   "[&<>]"
   (lambda (m) (pcase m ("&" "&amp;") ("<" "&lt;") (">" "&gt;")))
   s t t))

(defun rtorred--xmlrpc-encode-value (v)
  "Encode the Lisp value V as an XML-RPC <value> element.
Integers become <i8>, strings <string>, a (:base64 . BYTES) cons a
<base64> value, and any other list an <array>."
  (concat
   "<value>"
   (cond
    ((integerp v) (format "<i8>%d</i8>" v))
    ((stringp v) (format "<string>%s</string>" (rtorred--xml-escape v)))
    ((and (consp v) (eq (car v) :base64))
     (format "<base64>%s</base64>" (base64-encode-string (cdr v) t)))
    ((listp v)
     (concat "<array><data>"
             (mapconcat #'rtorred--xmlrpc-encode-value v "")
             "</data></array>"))
    (t (error "rtorred: cannot encode value %S" v)))
   "</value>"))

(defun rtorred--xmlrpc-encode (method args)
  "Build an XML-RPC <methodCall> string for METHOD with ARGS."
  (concat
   "<?xml version=\"1.0\"?>\n<methodCall><methodName>" method "</methodName><params>"
   (mapconcat (lambda (a) (concat "<param>" (rtorred--xmlrpc-encode-value a) "</param>"))
              args "")
   "</params></methodCall>"))

(defun rtorred--xml-text (node)
  "Return the concatenated text content of xml.el NODE.
Fast-paths the common leaf case of a single text child."
  (if (stringp node)
      node
    (let ((cs (cddr node)))
      (cond ((null cs) "")
            ((and (stringp (car cs)) (null (cdr cs))) (car cs))
            (t (mapconcat (lambda (c) (if (stringp c) c "")) cs ""))))))

(defun rtorred--xml-child (node tag)
  "Return the first child element of NODE with the given TAG, or nil."
  (car (xml-get-children node tag)))

(defun rtorred--xmlrpc-parse-value (value-node)
  "Convert an XML-RPC <value> element VALUE-NODE to a Lisp value."
  ;; Find the first element child without allocating an intermediate list
  ;; -- this runs for every scalar in a ~15k-node multicall response.
  (let ((typed nil) (cs (cddr value-node)))
    (while cs
      (if (consp (car cs)) (setq typed (car cs) cs nil) (setq cs (cdr cs))))
    (if (null typed)
        ;; An untyped <value> is, per spec, a string.
        (rtorred--xml-text value-node)
      (pcase (car typed)
        ((or 'i4 'i8 'int) (string-to-number (rtorred--xml-text typed)))
        ('boolean (equal (rtorred--xml-text typed) "1"))
        ('double (string-to-number (rtorred--xml-text typed)))
        ('string (rtorred--xml-text typed))
        ('base64 (base64-decode-string (rtorred--xml-text typed)))
        ('array
         (let ((data (rtorred--xml-child typed 'data)))
           (mapcar #'rtorred--xmlrpc-parse-value (xml-get-children data 'value))))
        ('struct
         (mapcar (lambda (m)
                   (cons (intern (rtorred--xml-text (rtorred--xml-child m 'name)))
                         (rtorred--xmlrpc-parse-value (rtorred--xml-child m 'value))))
                 (xml-get-children typed 'member)))
        (_ (rtorred--xml-text value-node))))))

(defun rtorred--parse-xml (raw)
  "Parse RAW XML into a root node.
Uses the C `libxml' parser when available -- it is dramatically faster
than `xml-parse-region' on the large multicall responses -- and falls
back to `xml-parse-region' otherwise.  Both yield the same node shape."
  (with-temp-buffer
    (insert (decode-coding-string raw 'utf-8))
    (if (libxml-available-p)
        (libxml-parse-xml-region (point-min) (point-max))
      (car (xml-parse-region (point-min) (point-max))))))

(defun rtorred--xmlrpc-decode (raw)
  "Parse RAW, an XML-RPC <methodResponse> string, into a Lisp value.
Signals an error if rtorrent returned a <fault>."
  (let* ((gc-cons-threshold (max gc-cons-threshold (* 256 1024 1024)))
         (root (rtorred--parse-xml raw))
         (fault (and root (rtorred--xml-child root 'fault)))
         (params (and root (rtorred--xml-child root 'params))))
    (cond
     (fault
      (let ((s (rtorred--xmlrpc-parse-value (rtorred--xml-child fault 'value))))
        (error "rtorrent fault %s: %s"
               (cdr (assq 'faultCode s)) (cdr (assq 'faultString s)))))
     (params
      (rtorred--xmlrpc-parse-value
       (rtorred--xml-child (rtorred--xml-child params 'param) 'value)))
     (t (error "rtorred: malformed XML-RPC response")))))

;;;; Command layer

(defun rtorred-rpc (method &rest args)
  "Call rtorrent RPC METHOD with ARGS and return the decoded result.
This is synchronous and blocks; prefer `rtorred-rpc-async' on hot paths."
  (rtorred--xmlrpc-decode
   (rtorred--rpc-call (rtorred--xmlrpc-encode method args))))

(defun rtorred--rpc-error (msg)
  "Default async error handler: report MSG to the echo area."
  (message "rtorred: %s" msg))

(defun rtorred-rpc-async (method args success &optional errback)
  "Call rtorrent RPC METHOD with ARGS (a list) asynchronously.
SUCCESS is called with the decoded result; ERRBACK with an error
message string (defaulting to `rtorred--rpc-error').  A <fault> reply
or a decode/transport failure routes to ERRBACK."
  (let ((errback (or errback #'rtorred--rpc-error)))
    (rtorred--rpc-call-async
     (rtorred--xmlrpc-encode method args)
     (lambda (raw)
       (condition-case err
           (funcall success (rtorred--xmlrpc-decode raw))
         (error (funcall errback (error-message-string err)))))
     errback)))

;; rtorrent exposes different method sets across versions, and `d.multicall2'
;; faults the whole call if *any* requested method is unknown.  So we probe
;; `system.listMethods' once per connection and drop methods the server lacks.

(defvar rtorred--methods-cache nil
  "Cons (URL . METHODS) caching `system.listMethods' for that URL.
METHODS is the list of available method-name strings, or the symbol
`unknown' if the probe itself failed.")

(defun rtorred--ensure-methods ()
  "Return the available RPC method names for `rtorred-rpc-url'.
Probes and caches `system.listMethods'; the symbol `unknown' means the
probe failed and we should assume everything is available."
  (unless (equal (car rtorred--methods-cache) rtorred-rpc-url)
    (setq rtorred--methods-cache
          (cons rtorred-rpc-url
                (condition-case nil
                    (rtorred-rpc "system.listMethods")
                  (error 'unknown)))))
  (cdr rtorred--methods-cache))

(defun rtorred--ensure-methods-async (callback &optional _errback)
  "Like `rtorred--ensure-methods' but non-blocking.
Calls CALLBACK with the cached/probed methods once available.  A failed
probe is cached as `unknown' and still proceeds (everything assumed
available)."
  (if (equal (car rtorred--methods-cache) rtorred-rpc-url)
      (funcall callback (cdr rtorred--methods-cache))
    (rtorred-rpc-async
     "system.listMethods" nil
     (lambda (methods)
       (setq rtorred--methods-cache (cons rtorred-rpc-url methods))
       (funcall callback methods))
     (lambda (_msg)
       (setq rtorred--methods-cache (cons rtorred-rpc-url 'unknown))
       (funcall callback 'unknown)))))

(defun rtorred--method-available-p (method)
  "Return non-nil if rtorrent provides METHOD (a bare method name)."
  (let ((m (rtorred--ensure-methods)))
    (or (eq m 'unknown) (and (listp m) (member method m)))))

(defun rtorred-refresh-methods ()
  "Forget the cached set of available RPC methods (re-probed on next use)."
  (interactive)
  (setq rtorred--methods-cache nil)
  (message "rtorred: RPC method cache cleared"))

(defconst rtorred--added-custom-keys '("addtime" "tm_loaded")
  "Custom-field keys that conventionally hold a persistent add time.")

(defconst rtorred--completed-custom-keys '("tm_completed" "tm_downloaded" "seedingtime")
  "Custom-field keys that conventionally hold a completion time.")

(defun rtorred--probe-customs (hash keys)
  "Return an alist (KEY . VALUE) for those KEYS holding an epoch on HASH."
  (when hash
    (delq nil
          (mapcar (lambda (key)
                    (let ((v (ignore-errors (rtorred-rpc "d.custom" hash key))))
                      (and (stringp v) (> (string-to-number v) 0)
                           (cons key (string-trim v)))))
                  keys))))

(defun rtorred--report-time-methods (version methods added completed exec customs)
  "Render a *rtorred-diagnostics* report.
VERSION and METHODS describe the server; ADDED/COMPLETED are the chosen
method strings (or nil); EXEC is the chosen execute method (or nil);
CUSTOMS is an alist of populated custom timestamp fields found."
  (cl-flet ((have (m) (and (member m methods) t))
            (yn (x) (if x "yes" "no")))
    (with-current-buffer (get-buffer-create "*rtorred-diagnostics*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (propertize "rtorred timestamp diagnostics\n" 'face 'bold)
                (make-string 44 ?─) "\n\n"
                (format "rtorrent version : %s\n\n" version)
                (propertize "Built-in timestamp methods\n" 'face 'bold)
                (format "  d.timestamp.finished : %s\n" (yn (have "d.timestamp.finished")))
                (format "  d.timestamp.started  : %s\n" (yn (have "d.timestamp.started")))
                (format "  d.load_date          : %s\n" (yn (have "d.load_date")))
                (format "  d.creation_date      : %s\n\n" (yn (have "d.creation_date")))
                (propertize "Custom timestamp fields (from a sample torrent)\n" 'face 'bold))
        (if customs
            (dolist (c customs)
              (insert (format "  d.custom=%-12s : %s\n" (car c)
                              (format-time-string "%Y-%m-%d %H:%M"
                                                  (string-to-number (cdr c))))))
          (insert "  (none found)\n"))
        (insert "\n" (propertize "Auto-configured\n" 'face 'bold)
                (format "  added-time     : %s\n" (or added "none -- column will be blank"))
                (format "  completed-time : %s\n\n" (or completed "none -- column will be blank"))
                (propertize "Data deletion (erase + delete data)\n" 'face 'bold)
                (format "  execute method : %s\n" (or exec "none -- delete-data disabled")))
        (goto-char (point-min)))
      (display-buffer (current-buffer)))))

;;;###autoload
(defun rtorred-detect-time-methods ()
  "Probe rtorrent and auto-configure the added/completed-time columns.

Checks `system.listMethods' for the built-in timestamp methods and
inspects a sample torrent's custom fields for a persistent add time
\(e.g. ruTorrent's \"addtime\").  Sets `rtorred-added-time-method' and
`rtorred-completed-time-method' to the best available source and shows
the findings in a *rtorred-diagnostics* buffer.  Run once per server;
needs a working `rtorred-rpc-url'.  Synchronous (it blocks briefly)."
  (interactive)
  (let* ((version (condition-case nil (rtorred-rpc "system.client_version")
                    (error "unknown")))
         (methods (rtorred-rpc "system.listMethods"))
         (sample (car (ignore-errors (rtorred-rpc "download_list"))))
         (added-customs (rtorred--probe-customs sample rtorred--added-custom-keys))
         (completed-customs (rtorred--probe-customs sample rtorred--completed-custom-keys))
         (customs (append added-customs completed-customs))
         (have (lambda (m) (and (member m methods) t)))
         ;; Prefer a persistent custom add time over d.load_date (which
         ;; resets on every rtorrent restart).
         (added (cond ((car added-customs) (concat "d.custom=" (caar added-customs)))
                      ((funcall have "d.load_date") "d.load_date")))
         ;; Prefer the built-in finished timestamp; fall back to a custom field.
         (completed (cond ((funcall have "d.timestamp.finished") "d.timestamp.finished")
                          ((car completed-customs)
                           (concat "d.custom=" (caar completed-customs)))))
         (exec (seq-find have '("execute.throw" "execute2" "execute"))))
    (when added (setq rtorred-added-time-method added))
    (when completed (setq rtorred-completed-time-method completed))
    (rtorred--report-time-methods version methods added completed exec customs)
    (message "rtorred: added=%s completed=%s%s"
             (or added "none") (or completed "none")
             (if exec "" " (no execute: delete-data off)"))))

;;;; Column model
;;
;; Every column is declared once in `rtorred--all-columns'.  A column knows
;; the rtorrent data it needs (:fields), how to render it (:format), and how
;; to sort it (:sort).  `rtorred-columns' picks which appear, and in what
;; order; `rtorred--fetch' requests exactly the union of fields the visible
;; columns need.  Add a column by adding one entry here plus its key to
;; `rtorred-columns'.

(defun rtorred--field (tr key)
  "Return field KEY of torrent alist TR."
  (cdr (assq key tr)))

(defun rtorred--rate (n)
  "Format N bytes/second, or the empty string when zero/unknown."
  (if (and (numberp n) (> n 0))
      (concat (file-size-human-readable n 'iec) "/s")
    ""))

(defun rtorred--fmt-bytes (key)
  "Return a formatter rendering numeric field KEY as a human size."
  (lambda (tr) (file-size-human-readable (or (rtorred--field tr key) 0) 'iec)))

(defun rtorred--fmt-rate (key)
  "Return a formatter rendering numeric field KEY as a transfer rate."
  (lambda (tr) (rtorred--rate (rtorred--field tr key))))

(defun rtorred--relative-time (epoch)
  "Format EPOCH as a compact age relative to now, e.g. \"3d\" or \"5h\"."
  (let ((diff (- (float-time) epoch)))
    (cond ((< diff 0) "—")
          ((< diff 60) "now")
          ((< diff 3600) (format "%dm" (truncate diff 60)))
          ((< diff 86400) (format "%dh" (truncate diff 3600)))
          ((< diff 604800) (format "%dd" (truncate diff 86400)))
          ((< diff 31536000) (format "%dw" (truncate diff 604800)))
          (t (format "%dy" (truncate diff 31536000))))))

(defun rtorred--fmt-time (key)
  "Return a formatter rendering epoch field KEY.
Uses a relative age when `rtorred-time-relative' is set, else
`rtorred-time-format'."
  (lambda (tr)
    (let* ((v (rtorred--field tr key))
           (n (cond ((numberp v) v) ((stringp v) (string-to-number v)) (t 0))))
      (cond ((<= n 0) "")
            (rtorred-time-relative (rtorred--relative-time n))
            (t (format-time-string rtorred-time-format n))))))

(defun rtorred--fmt-count (key)
  "Return a formatter rendering integer field KEY, blank when zero."
  (lambda (tr)
    (let ((n (rtorred--field tr key)))
      (if (and (numberp n) (> n 0)) (number-to-string n) ""))))

(defun rtorred--fmt-name (tr)
  "Render the name of torrent TR."
  (or (rtorred--field tr 'name) ""))

(defun rtorred--fmt-directory (tr)
  "Render the directory of torrent TR."
  (or (rtorred--field tr 'directory) ""))

(defvar rtorred--gradient-cache (make-hash-table :test 'equal)
  "Memoizes `rtorred--gradient-color' results, keyed by (PCT . BG-MODE).")

(defun rtorred--gradient-color (frac)
  "Return a hex foreground colour for FRAC in 0..1.
Interpolates red (0) through yellow to green (1) in HSL, with lightness
adapted to the frame's light/dark background for legibility.  Results
are memoized (only ~100 distinct values), since this is called for every
visible row on every refresh."
  (let* ((pct (max 0 (min 100 (round (* frac 100)))))
         (bg (frame-parameter nil 'background-mode))
         (key (cons pct bg)))
    (or (gethash key rtorred--gradient-cache)
        (puthash key
                 (let* ((hue (/ (* (/ pct 100.0) 120.0) 360.0))
                        (light (if (eq bg 'light) 0.40 0.62))
                        (rgb (color-hsl-to-rgb hue 0.6 light)))
                   (apply #'color-rgb-to-hex (append rgb '(2))))
                 rtorred--gradient-cache))))

(defun rtorred--fmt-percent (tr)
  "Render the completion percentage of torrent TR."
  (let ((size (rtorred--field tr 'size))
        (done (rtorred--field tr 'done)))
    (if (and (numberp size) (> size 0) (numberp done))
        (let* ((pct (/ (* 100 done) size))
               (str (format "%d%%" pct)))
          (if rtorred-percent-gradient
              (propertize str 'face
                          (list :foreground (rtorred--gradient-color (/ pct 100.0))))
            str))
      "")))

(defun rtorred--fmt-ratio (tr)
  "Render the share ratio of torrent TR (rtorrent stores it per-mille)."
  (let* ((ratio (/ (or (rtorred--field tr 'ratio) 0) 1000.0))
         (str (format "%.2f" ratio)))
    (if (and rtorred-ratio-gradient (> rtorred-ratio-good 0))
        (propertize str 'face
                    (list :foreground
                          (rtorred--gradient-color (/ ratio rtorred-ratio-good))))
      str)))

(defun rtorred--fmt-priority (tr)
  "Render the priority of torrent TR."
  (pcase (rtorred--field tr 'priority)
    (0 "off") (1 "low") (2 "norm") (3 "high") (_ "")))

(defun rtorred--status-of (tr)
  "Return the plain status string for torrent TR (no text properties).
One of: error, hashing, stopped, paused, seeding, leeching."
  (let ((state (rtorred--field tr 'state))
        (active (rtorred--field tr 'active))
        (complete (rtorred--field tr 'complete))
        (hashing (rtorred--field tr 'hashing))
        (msg (rtorred--field tr 'message)))
    (cond
     ((and (stringp msg) (> (length msg) 0)) "error")
     ((and (numberp hashing) (> hashing 0)) "hashing")
     ((eq state 0) "stopped")
     ((eq active 0) "paused")
     ((eq complete 1) "seeding")
     (t "leeching"))))

(defconst rtorred--statuses
  '("seeding" "leeching" "stopped" "paused" "hashing" "error")
  "All status strings `rtorred--status-of' can return.")

(defun rtorred--fmt-status (tr)
  "Return a short, faced status string for torrent TR."
  (let ((s (rtorred--status-of tr)))
    (propertize s 'face (pcase s
                          ("seeding" 'rtorred-seeding)
                          ("leeching" 'rtorred-leeching)
                          ("hashing" 'rtorred-hashing)
                          ("error" 'rtorred-errored)
                          ((or "stopped" "paused") 'rtorred-stopped)
                          (_ 'default)))))

(defun rtorred--all-columns ()
  "Return the master alist of column definitions, (KEY . PLIST).

Each PLIST has :label :width [:align right] :fields :format :sort.
:fields is an alist (FIELDKEY . COMMAND), COMMAND being an rtorrent
method (a trailing \"=\" is added when calling) optionally carrying an
argument, e.g. \"d.custom=tm_loaded\".  :format is a function of the
torrent's field alist returning the cell string.  :sort is nil (not
sortable), t (sort by the displayed text), or a FIELDKEY symbol (sort
numerically by that field)."
  `((name      . (:label "Name"      :width 40
                  :fields ((name . "d.name"))
                  :format ,#'rtorred--fmt-name :sort t))
    (size      . (:label "Size"      :width 10 :align right
                  :fields ((size . "d.size_bytes"))
                  :format ,(rtorred--fmt-bytes 'size) :sort size))
    (done      . (:label "Done"      :width 5 :align right
                  :fields ((size . "d.size_bytes") (done . "d.bytes_done"))
                  :format ,#'rtorred--fmt-percent :sort done))
    (down      . (:label "Down"      :width 11 :align right
                  :fields ((down . "d.down.rate"))
                  :format ,(rtorred--fmt-rate 'down) :sort down))
    (up        . (:label "Up"        :width 11 :align right
                  :fields ((up . "d.up.rate"))
                  :format ,(rtorred--fmt-rate 'up) :sort up))
    (uploaded  . (:label "Uploaded"  :width 10 :align right
                  :fields ((uptotal . "d.up.total"))
                  :format ,(rtorred--fmt-bytes 'uptotal) :sort uptotal))
    (ratio     . (:label "Ratio"     :width 7 :align right
                  :fields ((ratio . "d.ratio"))
                  :format ,#'rtorred--fmt-ratio :sort ratio))
    (peers     . (:label "Peers"     :width 6 :align right
                  :fields ((peers . "d.peers_connected"))
                  :format ,(rtorred--fmt-count 'peers) :sort peers))
    (seeds     . (:label "Seeds"     :width 6 :align right
                  :fields ((seeds . "d.peers_complete"))
                  :format ,(rtorred--fmt-count 'seeds) :sort seeds))
    (status    . (:label "Status"    :width 9
                  :fields ((state . "d.state") (active . "d.is_active")
                           (complete . "d.complete") (hashing . "d.hashing")
                           (message . "d.message"))
                  :format ,#'rtorred--fmt-status :sort t))
    (added     . (:label "Added"     :width 16
                  :fields ((added . ,rtorred-added-time-method))
                  :format ,(rtorred--fmt-time 'added) :sort added))
    (completed . (:label "Done At"   :width 16
                  :fields ((completed . ,rtorred-completed-time-method))
                  :format ,(rtorred--fmt-time 'completed) :sort completed))
    (directory . (:label "Directory" :width 30
                  :fields ((directory . "d.directory"))
                  :format ,#'rtorred--fmt-directory :sort t))
    (priority  . (:label "Prio"      :width 5
                  :fields ((priority . "d.priority"))
                  :format ,#'rtorred--fmt-priority :sort priority))))

(defun rtorred--active-columns ()
  "Return the active column definitions, ordered per `rtorred-columns'."
  (let ((all (rtorred--all-columns)))
    (delq nil (mapcar (lambda (k) (assq k all)) rtorred-columns))))

(defun rtorred--field-methods (cols)
  "Return an alist (FIELDKEY . COMMAND) of data to fetch for COLS.
Always includes the hash (the row id), then the de-duplicated union of
every visible column's :fields."
  (let ((acc (list (cons 'hash "d.hash"))))
    (dolist (col cols)
      (dolist (fm (plist-get (cdr col) :fields))
        (unless (assq (car fm) acc)
          (setq acc (cons fm acc)))))
    ;; Also fetch whatever the active filters need, even if no visible
    ;; column requires it.
    (dolist (filter rtorred--filters)
      (dolist (fm (plist-get filter :fields))
        (unless (assq (car fm) acc)
          (setq acc (cons fm acc)))))
    (nreverse acc)))

(defun rtorred--multicall-command (command)
  "Normalise COMMAND for use as a `d.multicall2' argument.
A bare accessor like \"d.name\" gets a trailing \"=\"; a command that
already carries an argument like \"d.custom=tm_loaded\" is left as is."
  (if (string-search "=" command) command (concat command "=")))

(defun rtorred--fetch-plan (cols)
  "Return (KEYS . MULTICALL-ARGS) to fetch the available fields of COLS.
KEYS are the field symbols, in order; MULTICALL-ARGS are the matching
`d.multicall2' command strings, with server-unavailable methods dropped
so the call never faults."
  (let* ((fields (rtorred--field-methods cols))
         (available (cl-remove-if-not
                     (lambda (fm)
                       (rtorred--method-available-p
                        (car (split-string (cdr fm) "="))))
                     fields)))
    (cons (mapcar #'car available)
          (mapcar (lambda (fm) (rtorred--multicall-command (cdr fm))) available))))

(defun rtorred--rows->torrents (keys rows)
  "Pair each row in ROWS with KEYS to form a list of torrent alists."
  (mapcar (lambda (row) (cl-mapcar #'cons keys row)) rows))

(defun rtorred--fetch (cols)
  "Fetch the current view synchronously as torrent alists for columns COLS."
  (rtorred--ensure-methods)
  (let* ((plan (rtorred--fetch-plan cols))
         (rows (apply #'rtorred-rpc "d.multicall2" "" rtorred-view (cdr plan))))
    (rtorred--rows->torrents (car plan) rows)))

(defun rtorred--fetch-async (cols callback errback)
  "Fetch the current view asynchronously for columns COLS.
CALLBACK is called with the list of torrent alists; ERRBACK with a
message string."
  (rtorred--ensure-methods-async
   (lambda (_methods)
     (let ((plan (rtorred--fetch-plan cols)))
       (rtorred-rpc-async
        "d.multicall2" (append (list "" rtorred-view) (cdr plan))
        (lambda (rows)
          (funcall callback (rtorred--rows->torrents (car plan) rows)))
        errback)))
   errback))

;;;; Data model

(defvar-local rtorred--torrents nil
  "Alist mapping a torrent hash to its field alist, for the current buffer.
Holds only the torrents currently visible (after filtering).")

(defvar-local rtorred--total-count 0
  "Number of torrents fetched in the last refresh, before filtering.")

(defvar-local rtorred--marks nil
  "List of hashes with an action mark (shown as `*'), for this buffer.")

(defvar-local rtorred--flags nil
  "List of hashes flagged for erase (shown as `D'), for this buffer.")

(defvar-local rtorred--filters nil
  "Active filters for this buffer: a list of plists.
Each has :desc (string), :fields (alist of (KEY . COMMAND) the filter
needs), and :pred (a function of a torrent alist).  A torrent is shown
only when it satisfies every filter (AND).")

(defun rtorred--visible-torrents (torrents)
  "Return the subset of TORRENTS satisfying every active filter."
  (if (null rtorred--filters)
      torrents
    (seq-filter
     (lambda (tr)
       (cl-every (lambda (f) (funcall (plist-get f :pred) tr)) rtorred--filters))
     torrents)))

(defun rtorred--apply-tags ()
  "Set the mark/flag tag in the padding column of every visible row.
Always does a full pass, so it clears stale tags too (e.g. after
`rtorred-unmark-all').  Callers on the hot refresh path should skip it
when nothing is marked, since a fresh print already leaves padding blank."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((id (tabulated-list-get-id)))
        (tabulated-list-put-tag
         (cond ((and id (member id rtorred--flags)) "D")
               ((and id (member id rtorred--marks)) "*")
               (t " "))
         t)))))

(defun rtorred--torrent-num (hash field)
  "Return numeric FIELD of the torrent with HASH, defaulting to 0.
Coerces string epoch/values (e.g. from custom fields) to numbers."
  (let ((v (cdr (assq field (cdr (assoc hash rtorred--torrents))))))
    (cond ((numberp v) v)
          ((stringp v) (string-to-number v))
          (t 0))))

(defun rtorred--num-sorter (field)
  "Return a `tabulated-list' sort predicate comparing torrents by FIELD."
  (lambda (a b)
    (< (rtorred--torrent-num (car a) field)
       (rtorred--torrent-num (car b) field))))

(defun rtorred--sort-spec (col)
  "Translate column COL's :sort into a `tabulated-list-format' sort value."
  (let ((s (plist-get (cdr col) :sort)))
    (cond ((null s) nil)
          ((eq s t) t)
          ((symbolp s) (rtorred--num-sorter s))
          (t s))))

(defun rtorred--column-width (col)
  "Return the display width for column def COL, honouring `rtorred-column-widths'."
  (or (cdr (assq (car col) rtorred-column-widths))
      (plist-get (cdr col) :width)))

(defun rtorred--list-format (cols)
  "Build a `tabulated-list-format' vector for column defs COLS."
  (vconcat
   (mapcar (lambda (col)
             (let ((p (cdr col)))
               (append (list (plist-get p :label)
                             (rtorred--column-width col)
                             (rtorred--sort-spec col))
                       (and (eq (plist-get p :align) 'right) '(:right-align t)))))
           cols)))

(defun rtorred--name-width (cols)
  "Compute a Name-column width for COLS that fills the selected window.
Returns at least `rtorred-name-min-width'."
  (let* ((others (cl-loop for col in cols
                          unless (eq (car col) 'name)
                          sum (rtorred--column-width col)))
         ;; Each column adds 1 (its `pad-right'); plus the leading padding;
         ;; minus a small margin so the line never exceeds the window.
         (avail (- (window-body-width) tabulated-list-padding
                   (length cols) others 1)))
    (max rtorred-name-min-width avail)))

(defun rtorred--adjust-name-width ()
  "Resize the Name column to fill the window, reprinting if it changed.
Used from `window-configuration-change-hook' and on open."
  (when (and (derived-mode-p 'rtorred-mode)
             (vectorp tabulated-list-format))
    (let* ((cols (rtorred--active-columns))
           (idx (cl-position 'name cols :key #'car)))
      (when (and idx (< idx (length tabulated-list-format)))
        (let ((new (rtorred--name-width cols))
              (entry (aref tabulated-list-format idx)))
          (unless (= new (nth 1 entry))
            (setf (nth 1 entry) new)
            (tabulated-list-init-header)
            (tabulated-list-print t)))))))

(defun rtorred--default-sort-key (cols)
  "Return an initial `tabulated-list-sort-key' for column defs COLS.
Honours `rtorred-default-sort', falling back to the first sortable
column when the requested one is absent or unsortable."
  (cl-flet ((first-sortable ()
              (let ((col (seq-find #'rtorred--sort-spec cols)))
                (and col (cons (plist-get (cdr col) :label) nil)))))
    (pcase rtorred-default-sort
      ('nil nil)
      (`(,key . ,dir)
       (let ((col (assq key cols)))
         (if (and col (rtorred--sort-spec col))
             (cons (plist-get (cdr col) :label) (eq dir 'descending))
           (first-sortable))))
      (_ (first-sortable)))))

(defun rtorred--entry (tr cols)
  "Build a `tabulated-list-entries' element for torrent TR over COLS."
  (list (cdr (assq 'hash tr))
        (vconcat (mapcar (lambda (col)
                           (funcall (plist-get (cdr col) :format) tr))
                         cols))))

(defun rtorred--row-position (id)
  "Return the buffer position of the start of the row for ID, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (if (equal (tabulated-list-get-id) id)
            (setq found (point))
          (forward-line 1)))
      found)))

(defun rtorred--render (torrents cols)
  "Populate the current buffer from TORRENTS using column defs COLS.
Re-prints the list, preserving point (by torrent), the sort order, and
the marks/flags (pruned to torrents that still exist)."
  (let* ((gc-cons-threshold (max gc-cons-threshold (* 256 1024 1024)))
         (visible (rtorred--visible-torrents torrents))
         ;; Remember which torrent sits at the top of the window so we can
         ;; pin it back there after the reprint -- otherwise erasing the
         ;; buffer resets the scroll and redisplay recenters on point.
         (win (get-buffer-window (current-buffer)))
         (top-id (and win (save-excursion
                            (goto-char (window-start win))
                            (tabulated-list-get-id)))))
    ;; Only visible torrents are stored, so marks, sorting, actions and the
    ;; detail view all operate on the filtered set -- hidden rows cannot be
    ;; acted on.
    (setq rtorred--torrents
          (mapcar (lambda (tr) (cons (cdr (assq 'hash tr)) tr)) visible))
    (setq rtorred--total-count (length torrents))
    (let ((present (mapcar #'car rtorred--torrents)))
      (setq rtorred--marks (cl-intersection rtorred--marks present :test #'equal)
            rtorred--flags (cl-intersection rtorred--flags present :test #'equal)))
    (setq tabulated-list-entries
          (mapcar (lambda (tr) (rtorred--entry tr cols)) visible))
    (tabulated-list-print t)
    ;; A fresh print blanks the padding, so only re-tag when something is
    ;; marked (saves an O(n) pass on the common no-marks refresh).
    (when (or rtorred--marks rtorred--flags)
      (rtorred--apply-tags))
    (when (and win (window-live-p win) top-id)
      (let ((pos (rtorred--row-position top-id)))
        (when pos (set-window-start win pos t))))
    ;; Reprinting moves the hl-line overlay off point; put it back.
    (when (bound-and-true-p hl-line-mode)
      (hl-line-highlight))))

(defun rtorred--refresh ()
  "Refetch synchronously and re-render the current buffer."
  (let ((cols (rtorred--active-columns)))
    (rtorred--render (rtorred--fetch cols) cols)))

;;;; Asynchronous refresh and auto-update

(defvar-local rtorred--refresh-timer nil
  "Per-buffer repeating timer driving auto-refresh, or nil.")

(defvar-local rtorred--refreshing nil
  "Non-nil while an async refresh is in flight for this buffer.")

(defvar-local rtorred--render-timer nil
  "Idle timer for a deferred re-render, or nil.")

(defvar-local rtorred--pending-render nil
  "Latest (TORRENTS . COLS) awaiting a deferred render, or nil.")

(defun rtorred--mode-line ()
  "Update the rtorred mode-line indicator (count, refresh/auto state, filters)."
  (let* ((shown (length rtorred--torrents))
         (count (if rtorred--filters
                    (format "%d/%d" shown rtorred--total-count)
                  (number-to-string rtorred--total-count))))
    (setq mode-line-process
          (concat
           ;; Show the icon only while auto-refresh is on; its colour changes
           ;; while actually refreshing.  Present throughout an auto-refresh
           ;; session (only the colour toggles), so the line doesn't shift.
           (and rtorred--refresh-timer
                (concat " " (propertize "↻" 'face (if rtorred--refreshing
                                                       'rtorred-refreshing
                                                     'shadow))))
           " " count
           (and rtorred--refresh-timer
                (format " [auto:%ss]" rtorred-auto-refresh-interval))
           (and rtorred--filters
                (format " {%s}"
                        (string-join
                         (mapcar (lambda (f) (plist-get f :desc))
                                 (reverse rtorred--filters))
                         ","))))))
  (force-mode-line-update))

(defun rtorred--refresh-async ()
  "Refetch asynchronously and re-render when the data arrives.
Skips out if a refresh is already in flight for this buffer."
  (unless rtorred--refreshing
    (setq rtorred--refreshing t)
    (rtorred--mode-line)
    (let ((buf (current-buffer))
          (cols (rtorred--active-columns)))
      (rtorred--fetch-async
       cols
       (lambda (torrents)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq rtorred--refreshing nil)
             (rtorred--schedule-render torrents cols)
             (rtorred--mode-line))))
       (lambda (msg)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq rtorred--refreshing nil)
             (rtorred--mode-line)))
         (message "rtorred: refresh failed: %s" msg))))))

(defun rtorred-revert (&optional _arg _noconfirm)
  "Refresh the rtorred buffer (the `revert-buffer-function')."
  (rtorred--refresh-async))

(defun rtorred--render-pending (buf)
  "Render the data most recently queued for BUF (see `rtorred--schedule-render').
While a minibuffer is active (e.g. a `consult-line' search reading from
this buffer), the redraw is postponed -- reprinting underneath the
search would scramble its positions and jump the view."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq rtorred--render-timer nil)
      (cond
       ((null rtorred--pending-render))
       ((active-minibuffer-window)
        (setq rtorred--render-timer
              (run-with-idle-timer rtorred-render-idle-delay nil
                                   #'rtorred--render-pending buf)))
       (t (let ((data rtorred--pending-render))
            (setq rtorred--pending-render nil)
            (rtorred--render (car data) (cdr data))))))))

(defun rtorred--schedule-render (torrents cols)
  "Render TORRENTS for COLS, deferred to a brief idle.
The redraw of a large list is the costliest synchronous step; deferring
it via `rtorred-render-idle-delay' lets it land in a pause rather than
interrupting typing.  Only the most recent data is rendered.  With a nil
delay it renders immediately."
  (if (null rtorred-render-idle-delay)
      (rtorred--render torrents cols)
    (setq rtorred--pending-render (cons torrents cols))
    (unless (timerp rtorred--render-timer)
      (setq rtorred--render-timer
            (run-with-idle-timer rtorred-render-idle-delay nil
                                 #'rtorred--render-pending (current-buffer))))))

(defun rtorred--timer-tick (buf)
  "Fire an async refresh in BUF if it is alive, visible, and idle.
Skips refreshing a buffer that is not displayed (no point fetching and
re-rendering ~1000 rows nobody is looking at)."
  (when (and (buffer-live-p buf)
             (get-buffer-window buf 'visible)
             ;; Don't refresh while a minibuffer command (e.g. consult) is
             ;; reading -- it would reprint the buffer out from under it.
             (not (active-minibuffer-window)))
    (with-current-buffer buf
      (unless rtorred--refreshing
        (rtorred--refresh-async)))))

(defun rtorred--stop-timer ()
  "Cancel this buffer's auto-refresh and deferred-render timers, if any."
  (when rtorred--refresh-timer
    (cancel-timer rtorred--refresh-timer)
    (setq rtorred--refresh-timer nil))
  (when rtorred--render-timer
    (cancel-timer rtorred--render-timer)
    (setq rtorred--render-timer nil)))

(defun rtorred--start-timer ()
  "Start this buffer's auto-refresh timer per `rtorred-auto-refresh-interval'."
  (rtorred--stop-timer)
  (when (and (numberp rtorred-auto-refresh-interval)
             (> rtorred-auto-refresh-interval 0))
    (setq rtorred--refresh-timer
          (run-at-time rtorred-auto-refresh-interval
                       rtorred-auto-refresh-interval
                       #'rtorred--timer-tick (current-buffer)))))

(defun rtorred-toggle-auto-refresh ()
  "Toggle automatic refreshing in the current rtorred buffer."
  (interactive)
  (if rtorred--refresh-timer
      (progn (rtorred--stop-timer)
             (message "rtorred: auto-refresh off"))
    (unless (and (numberp rtorred-auto-refresh-interval)
                 (> rtorred-auto-refresh-interval 0))
      (setq-local rtorred-auto-refresh-interval 3))
    (rtorred--start-timer)
    (message "rtorred: auto-refresh on (%ss)" rtorred-auto-refresh-interval))
  (rtorred--mode-line))

;;;; Marking

(defun rtorred--put-mark (kind)
  "Set KIND (`mark', `flag', or `unmark') on the current line, no movement."
  (let ((id (tabulated-list-get-id)))
    (when id
      (setq rtorred--marks (delete id rtorred--marks)
            rtorred--flags (delete id rtorred--flags))
      (pcase kind
        ('mark (push id rtorred--marks))
        ('flag (push id rtorred--flags)))
      (tabulated-list-put-tag (pcase kind ('mark "*") ('flag "D") (_ " "))))))

(defun rtorred-mark ()
  "Mark the torrent at point for actions, and move to the next line."
  (interactive)
  (rtorred--put-mark 'mark)
  (forward-line 1))

(defun rtorred-unmark ()
  "Unmark the torrent at point, and move to the next line."
  (interactive)
  (rtorred--put-mark 'unmark)
  (forward-line 1))

(defun rtorred-unmark-backward ()
  "Move to the previous line and unmark the torrent there."
  (interactive)
  (forward-line -1)
  (rtorred--put-mark 'unmark))

(defun rtorred-unmark-all ()
  "Remove all marks and erase flags in this buffer."
  (interactive)
  (setq rtorred--marks nil rtorred--flags nil)
  (rtorred--apply-tags))

(defun rtorred-toggle-marks ()
  "Toggle action marks: marked rows become unmarked and vice versa.
Rows flagged for erase are left untouched."
  (interactive)
  (let (toggled)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((id (tabulated-list-get-id)))
          (when (and id
                     (not (member id rtorred--flags))
                     (not (member id rtorred--marks)))
            (push id toggled)))
        (forward-line 1)))
    (setq rtorred--marks toggled)
    (rtorred--apply-tags)))

(defun rtorred--marked-or-current ()
  "Return the hashes to act on: the marked set, else the torrent at point."
  (or (reverse rtorred--marks)
      (let ((id (tabulated-list-get-id))) (and id (list id)))))

(defun rtorred--hash-name (hash)
  "Return the display name of HASH, falling back to the hash itself."
  (or (cdr (assq 'name (cdr (assoc hash rtorred--torrents)))) hash))

;;;; Actions

(defun rtorred--run-batch (thunks done)
  "Run async THUNKS, then call DONE with the list of failures once all finish.
Each thunk gets a continuation to call with no argument on success, or
with the item's identifier on failure.  DONE receives the collected
failure identifiers (nil if everything succeeded)."
  (if (null thunks)
      (funcall done nil)
    (let ((remaining (length thunks))
          (failures nil))
      (dolist (thunk thunks)
        (funcall thunk
                 (lambda (&optional failure)
                   (when failure (push failure failures))
                   (setq remaining (1- remaining))
                   (when (zerop remaining) (funcall done failures))))))))

(defun rtorred--after-action (buf &optional failures)
  "Refresh BUF after an action; note FAILURES if any."
  (when failures
    (message "rtorred: %d of the operations failed" (length failures)))
  (when (buffer-live-p buf)
    (with-current-buffer buf (rtorred--refresh-async))))

(defun rtorred--act (method)
  "Call METHOD with each marked-or-current hash, then refresh once.
METHOD is a single-argument rtorrent command such as \"d.start\"."
  (let ((hashes (rtorred--marked-or-current))
        (buf (current-buffer)))
    (if (null hashes)
        (message "rtorred: no torrent here")
      (rtorred--run-batch
       (mapcar (lambda (h)
                 (lambda (k)
                   (rtorred-rpc-async
                    method (list h)
                    (lambda (_) (funcall k))
                    (lambda (msg) (message "rtorred: %s" msg) (funcall k h)))))
               hashes)
       (lambda (failures) (rtorred--after-action buf failures))))))

(defun rtorred-start ()
  "Start the marked-or-current torrent(s)."
  (interactive)
  (rtorred--act "d.start"))

(defun rtorred-stop ()
  "Stop the marked-or-current torrent(s)."
  (interactive)
  (rtorred--act "d.stop"))

(defun rtorred-check-hash ()
  "Trigger a hash check of the marked-or-current torrent(s)."
  (interactive)
  (rtorred--act "d.check_hash"))

(defun rtorred--priority-adjust (delta)
  "Adjust priority of the marked-or-current torrent(s) by DELTA, clamped 0..3."
  (let ((hashes (rtorred--marked-or-current))
        (buf (current-buffer)))
    (if (null hashes)
        (message "rtorred: no torrent here")
      (rtorred--run-batch
       (mapcar
        (lambda (h)
          (lambda (k)
            (rtorred-rpc-async
             "d.priority" (list h)
             (lambda (cur)
               (rtorred-rpc-async
                "d.priority.set"
                (list h (max 0 (min 3 (+ (if (numberp cur) cur 2) delta))))
                (lambda (_) (funcall k))
                (lambda (msg) (message "rtorred: %s" msg) (funcall k h))))
             (lambda (msg) (message "rtorred: %s" msg) (funcall k h)))))
        hashes)
       (lambda (failures) (rtorred--after-action buf failures))))))

(defun rtorred-priority-up ()
  "Raise the priority of the marked-or-current torrent(s)."
  (interactive)
  (rtorred--priority-adjust 1))

(defun rtorred-priority-down ()
  "Lower the priority of the marked-or-current torrent(s)."
  (interactive)
  (rtorred--priority-adjust -1))

(defun rtorred--hash-error-p (msg)
  "Non-nil if error MSG looks like a hash/data problem (vs a tracker one)."
  (and (stringp msg)
       (let ((case-fold-search t))
         (string-match-p "hash\\|chunk\\|unfinished\\|\\bfile\\b" msg))))

(defun rtorred--retry-clear-then (h action k)
  "Clear torrent H's message, then call one-arg method ACTION; continue with K.
Passes H to K on failure."
  (rtorred-rpc-async
   "d.message.set" (list h "")
   (lambda (_)
     (rtorred-rpc-async
      action (list h)
      (lambda (_) (funcall k))
      (lambda (msg) (message "rtorred: %s" msg) (funcall k h))))
   (lambda (msg) (message "rtorred: %s" msg) (funcall k h))))

(defun rtorred--retry-one (h smart k)
  "Retry torrent H, continuing with K.
When SMART, read H's `d.message' and re-check the hash for a hash/data
error or re-announce for anything else; otherwise just re-announce."
  (if (not smart)
      (rtorred--retry-clear-then h "d.tracker_announce" k)
    (rtorred-rpc-async
     "d.message" (list h)
     (lambda (msg)
       (rtorred--retry-clear-then
        h (if (rtorred--hash-error-p msg) "d.check_hash" "d.tracker_announce") k))
     (lambda (_) (rtorred--retry-clear-then h "d.tracker_announce" k)))))

(defun rtorred-retry (&optional plain)
  "Retry the marked-or-current torrent(s) after an error.
Clears the stale `d.message' and applies a remedy.  With `rtorred-retry-smart'
\(the default) the remedy is chosen per torrent from its error: re-check
the hash for a hash/data error, re-announce for a tracker error.  With a
prefix arg PLAIN -- or when `rtorred-retry-smart' is nil -- it always
just re-announces.  For an unconditional hash re-check, use \\[rtorred-check-hash]."
  (interactive "P")
  (let ((hashes (rtorred--marked-or-current))
        (buf (current-buffer))
        (smart (and rtorred-retry-smart (not plain))))
    (if (null hashes)
        (message "rtorred: no torrent here")
      (rtorred--run-batch
       (mapcar (lambda (h) (lambda (k) (rtorred--retry-one h smart k))) hashes)
       (lambda (failures) (rtorred--after-action buf failures))))))

(defun rtorred-toggle-pause ()
  "Pause active torrents and resume paused ones (marked-or-current).
Each torrent is toggled based on its own current state."
  (interactive)
  (let ((hashes (rtorred--marked-or-current))
        (buf (current-buffer)))
    (if (null hashes)
        (message "rtorred: no torrent here")
      (rtorred--run-batch
       (mapcar
        (lambda (h)
          (lambda (k)
            (rtorred-rpc-async
             "d.is_active" (list h)
             (lambda (active)
               (rtorred-rpc-async
                (if (eq active 1) "d.pause" "d.resume") (list h)
                (lambda (_) (funcall k))
                (lambda (msg) (message "rtorred: %s" msg) (funcall k h))))
             (lambda (msg) (message "rtorred: %s" msg) (funcall k h)))))
        hashes)
       (lambda (failures) (rtorred--after-action buf failures))))))

;;;; Erase (optionally with server-side data deletion)

(defun rtorred--execute-method ()
  "Return the best available rtorrent execute method name, or nil.
Used to delete data server-side.  Returns nil -- disabling all data
deletion -- when `rtorred-never-delete-data' is set, or when the server
has no `execute' command (locked down)."
  (and (not rtorred-never-delete-data)
       (seq-find #'rtorred--method-available-p '("execute.throw" "execute2" "execute"))))

(defun rtorred--safe-rm-path-p (path)
  "Return non-nil if PATH passes the basic safety checks for `rm -rf'.
Guards against the empty string, the root directory, and relative paths.
This is the first of several layers -- see `rtorred--rm-unsafe-reason'."
  (and (stringp path)
       (string-prefix-p "/" path)
       (> (length path) 1)
       (not (string-match-p "\\`/+\\'" path))))

(defun rtorred--path-ancestor-p (a b)
  "Non-nil if path A is an ancestor of, or equal to, path B.
Compares whole path components (so /a/b is not an ancestor of /a/bc)."
  (string-prefix-p (file-name-as-directory a) (file-name-as-directory b)))

(defun rtorred--rm-unsafe-reason (path root all-paths)
  "Return a human reason PATH is unsafe to `rm -rf', or nil if it is safe.
ROOT is the shared download directory (or nil); ALL-PATHS is every target
path in the batch.  These layers ensure a delete can never reach beyond a
single torrent's own data, even if path resolution misbehaves."
  (cond
   ((not (rtorred--safe-rm-path-p path)) "no usable path")
   ((and root (rtorred--path-ancestor-p path root)) "the shared download root")
   ((> (seq-count (lambda (p) (string= p path)) all-paths) 1)
    "shared by multiple torrents")
   ((seq-some (lambda (p) (and (not (string= p path))
                               (rtorred--path-ancestor-p path p)))
              all-paths)
    "contains another torrent's data")))

(defvar rtorred--download-root-cache nil
  "Cons (URL . ROOT) caching rtorrent's default download directory.")

(defun rtorred--download-root-async (callback)
  "Call CALLBACK with rtorrent's default download directory, or nil.
Cached per connection; used to refuse deleting the shared root."
  (if (equal (car rtorred--download-root-cache) rtorred-rpc-url)
      (funcall callback (cdr rtorred--download-root-cache))
    (rtorred-rpc-async
     "directory.default" nil
     (lambda (root)
       (setq rtorred--download-root-cache
             (cons rtorred-rpc-url (and (stringp root) (> (length root) 0) root)))
       (funcall callback (cdr rtorred--download-root-cache)))
     (lambda (_)
       (setq rtorred--download-root-cache (cons rtorred-rpc-url nil))
       (funcall callback nil)))))

(defun rtorred--resolve-data-path (hash callback)
  "Pass HASH's on-disk data path (`d.base_path') to CALLBACK, or \"\".
`d.base_path' is the file for single-file torrents and the torrent's own
directory for multi-file ones -- always torrent-specific.

It deliberately does NOT fall back to `d.directory': for a torrent that
has never been opened, base_path is empty and `d.directory' is typically
the *shared* download root, so deleting it would wipe every download.  An
empty result means \"no usable path\", and the torrent is erased without
touching the disk."
  (rtorred-rpc-async
   "d.base_path" (list hash)
   (lambda (path) (funcall callback (if (stringp path) path "")))
   (lambda (_) (funcall callback ""))))

(defun rtorred--erase-one (hash k)
  "Erase HASH from rtorrent (leaving data); call K, passing HASH on failure."
  (rtorred-rpc-async
   "d.erase" (list hash)
   (lambda (_) (funcall k))
   (lambda (msg) (message "rtorred: erase failed: %s" msg) (funcall k hash))))

(defun rtorred--after-erase (buf failures)
  "Refresh BUF after an erase batch, leaving FAILURES marked for retry.
FAILURES is the list of hashes whose rm or erase failed.  Erased
torrents are gone (their marks vanish with them); the failures are
re-marked so you can simply retry.  Flags are cleared regardless."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq rtorred--marks (copy-sequence failures)
            rtorred--flags nil)
      (when failures
        (message "rtorred: %d torrent(s) failed; left marked for retry"
                 (length failures)))
      (rtorred--refresh-async))))

(defun rtorred--maybe-delete-data (hashes buf)
  "Resolve the data paths for HASHES, then confirm deleting them.
Gathers each torrent's on-disk path and the download root first, so the
confirmation can show exactly what will be removed and the safety guards
have everything they need."
  (let ((results nil))
    (rtorred--run-batch
     (mapcar (lambda (h)
               (lambda (k)
                 (rtorred--resolve-data-path
                  h (lambda (path) (push (cons h path) results) (funcall k)))))
             hashes)
     (lambda (_failures)
       (rtorred--download-root-async
        (lambda (root)
          (rtorred--confirm-delete-data (nreverse results) root buf)))))))

(defun rtorred--confirm-delete-data (results root buf)
  "Show the exact `rm' commands for RESULTS, ask, then erase.
RESULTS is a list of (HASH . PATH); ROOT is the download root.  Each path
is screened by `rtorred--rm-unsafe-reason'; only paths that clear every
guard are ever sent to the server.  Torrents with an unsafe/missing path
are still erased, but their data is left on disk."
  (let* ((all-paths (mapcar #'cdr results))
         (to-rm nil) (unsafe nil))
    (dolist (r results)
      (let ((reason (rtorred--rm-unsafe-reason (cdr r) root all-paths)))
        (if reason (push (cons r reason) unsafe) (push r to-rm))))
    (setq to-rm (nreverse to-rm) unsafe (nreverse unsafe))
    (if (null to-rm)
        (progn
          (message "rtorred: no safely deletable data; erasing torrent%s only"
                   (if (= (length results) 1) "" "s"))
          (rtorred--erase-execute nil (mapcar #'car results) buf))
      (with-output-to-temp-buffer "*rtorred-erase*"
        (princ (format "Will run these %d command(s) on the rtorrent host \
(via %s):\n\n" (length to-rm) (rtorred--execute-method)))
        (dolist (r to-rm)
          (princ (format "  rm -rf -- %s\n" (cdr r))))
        (when unsafe
          (princ (format "\nErased WITHOUT deleting data (%d):\n" (length unsafe)))
          (dolist (u unsafe)
            (princ (format "  %-40s  (%s)\n"
                           (rtorred--hash-name (car (car u))) (cdr u))))))
      (let ((delete (yes-or-no-p
                     (format "Send the %d command(s) shown above to delete data? "
                             (length to-rm)))))
        (quit-windows-on "*rtorred-erase*")
        (if delete
            (rtorred--erase-execute to-rm (mapcar (lambda (u) (car (car u))) unsafe) buf)
          (rtorred--erase-execute nil (mapcar #'car results) buf))))))

(defun rtorred--erase-execute (to-rm erase-only buf)
  "Delete data for TO-RM then erase, and erase ERASE-ONLY without deleting data.
TO-RM is a list of (HASH . PATH) whose paths have already passed every
safety guard; ERASE-ONLY is a list of hashes.  A failed `rm' does not
proceed to erase, so the torrent stays put for a retry."
  (let ((exec (rtorred--execute-method)))
    (rtorred--run-batch
     (append
      (mapcar
       (lambda (r)
         (let ((h (car r)) (path (cdr r)))
           (lambda (k)
             (rtorred-rpc-async
              exec (list "" "rm" "-rf" "--" path)
              (lambda (_) (rtorred--erase-one h k))
              (lambda (msg)
                (message "rtorred: rm failed for %s: %s" path msg)
                (funcall k h))))))
       to-rm)
      (mapcar (lambda (h) (lambda (k) (rtorred--erase-one h k))) erase-only))
     (lambda (failures) (rtorred--after-erase buf failures)))))

(defun rtorred--erase-only (hashes buf)
  "Erase HASHES from rtorrent, leaving their data on disk."
  (rtorred--run-batch
   (mapcar (lambda (h) (lambda (k) (rtorred--erase-one h k))) hashes)
   (lambda (failures) (rtorred--after-erase buf failures))))

(defun rtorred--format-name-list (hashes)
  "Format HASHES as a short, human-readable list of torrent names."
  (let* ((names (mapcar #'rtorred--hash-name hashes))
         (max 4))
    (if (<= (length names) max)
        (string-join names ", ")
      (concat (string-join (seq-take names max) ", ")
              (format ", and %d more" (- (length names) max))))))

(defun rtorred--do-erase (hashes)
  "Confirm and erase HASHES, optionally deleting their data server-side."
  (if (null hashes)
      (message "rtorred: nothing to erase")
    (let ((buf (current-buffer))
          (n (length hashes)))
      (when (yes-or-no-p
             (format "Erase %d torrent%s (%s)? "
                     n (if (= n 1) "" "s") (rtorred--format-name-list hashes)))
        ;; If the server can delete data, gather the paths and show exactly
        ;; what would run before asking; otherwise just erase.
        (if (rtorred--execute-method)
            (rtorred--maybe-delete-data hashes buf)
          (rtorred--erase-only hashes buf))))))

(defun rtorred-flag-for-erase ()
  "Flag the torrent at point for erase (executed with \\[rtorred-execute-flags])."
  (interactive)
  (rtorred--put-mark 'flag)
  (forward-line 1))

(defun rtorred-execute-flags ()
  "Erase all torrents flagged with \\[rtorred-flag-for-erase]."
  (interactive)
  (if rtorred--flags
      (rtorred--do-erase (reverse rtorred--flags))
    (message "rtorred: no torrents flagged for erase")))

(defun rtorred-erase ()
  "Erase the marked-or-current torrent(s) immediately (with confirmation)."
  (interactive)
  (rtorred--do-erase (rtorred--marked-or-current)))

;;;; Filtering
;;
;; Filters narrow the visible list (and thus what can be marked/operated on).
;; They compose with AND.  Each filter records the fields it needs so the
;; fetch pulls them even when the matching column is hidden.

(defun rtorred--add-filter (filter)
  "Add FILTER (a plist) and re-render."
  (push filter rtorred--filters)
  (rtorred--refresh-async))

(defun rtorred-filter-done ()
  "Show only torrents that are 100% complete."
  (interactive)
  (rtorred--add-filter
   (list :desc "done"
         :fields '((complete . "d.complete"))
         :pred (lambda (tr) (eq (cdr (assq 'complete tr)) 1)))))

(defun rtorred-filter-ratio (n)
  "Show only torrents whose share ratio is greater than N."
  (interactive (list (read-number "Ratio greater than: " 1.0)))
  (rtorred--add-filter
   (list :desc (format "ratio>%s" n)
         :fields '((ratio . "d.ratio"))
         :pred (lambda (tr) (> (/ (or (cdr (assq 'ratio tr)) 0) 1000.0) n)))))

(defun rtorred-filter-status (status)
  "Show only torrents whose status is STATUS."
  (interactive (list (completing-read "Status: " rtorred--statuses nil t)))
  (rtorred--add-filter
   (list :desc (format "status=%s" status)
         :fields '((state . "d.state") (active . "d.is_active")
                   (complete . "d.complete") (hashing . "d.hashing")
                   (message . "d.message"))
         :pred (lambda (tr) (equal (rtorred--status-of tr) status)))))

(defun rtorred-filter-active ()
  "Show only active (started, not paused) torrents."
  (interactive)
  (rtorred--add-filter
   (list :desc "active"
         :fields '((active . "d.is_active"))
         :pred (lambda (tr) (eq (cdr (assq 'active tr)) 1)))))

(defun rtorred-filter-downloading ()
  "Show only torrents with a live download rate (down rate > 0)."
  (interactive)
  (rtorred--add-filter
   (list :desc "downloading"
         :fields '((down . "d.down.rate"))
         :pred (lambda (tr) (> (or (cdr (assq 'down tr)) 0) 0)))))

(defun rtorred-filter-name (regexp)
  "Show only torrents whose name matches REGEXP (case-insensitive)."
  (interactive (list (read-string "Filter name (regexp): ")))
  (rtorred--add-filter
   (list :desc (format "/%s/" regexp)
         :fields '((name . "d.name"))
         :pred (lambda (tr)
                 (let ((case-fold-search t))
                   (string-match-p regexp (or (cdr (assq 'name tr)) "")))))))

(defun rtorred-filter-pop ()
  "Remove the most recently added filter."
  (interactive)
  (if rtorred--filters
      (progn (setq rtorred--filters (cdr rtorred--filters))
             (rtorred--refresh-async)
             (message "rtorred: removed last filter"))
    (message "rtorred: no filters")))

(defun rtorred-filter-clear ()
  "Remove all filters."
  (interactive)
  (if rtorred--filters
      (progn (setq rtorred--filters nil)
             (rtorred--refresh-async)
             (message "rtorred: filters cleared"))
    (message "rtorred: no filters")))

(defvar rtorred-filter-map (make-sparse-keymap)
  "Keymap for rtorred filtering commands, bound to the `/' prefix.")

;; Re-applied on every load (see the `rtorred-mode-map' note).
(keymap-set rtorred-filter-map "d" #'rtorred-filter-done)
(keymap-set rtorred-filter-map "r" #'rtorred-filter-ratio)
(keymap-set rtorred-filter-map "s" #'rtorred-filter-status)
(keymap-set rtorred-filter-map "a" #'rtorred-filter-active)
(keymap-set rtorred-filter-map "D" #'rtorred-filter-downloading)
(keymap-set rtorred-filter-map "f" #'rtorred-filter-name)
(keymap-set rtorred-filter-map "p" #'rtorred-filter-pop)
(keymap-set rtorred-filter-map "x" #'rtorred-filter-clear)
(keymap-set rtorred-filter-map "/" #'rtorred-filter-clear)

;;;; Adding torrents

(defun rtorred--load-method (kind start)
  "Return the best available load method for KIND (`raw' or `normal').
START non-nil chooses the start-on-load variant.  Prefers the dotted
0.9.x names, falling back to verbose and then underscore aliases."
  (let ((candidates
         (pcase (list kind start)
           ('(raw t)      '("load.raw_start" "load.raw_start_verbose" "load_raw_start"))
           ('(raw nil)    '("load.raw" "load.raw_verbose" "load_raw"))
           ('(normal t)   '("load.start" "load.start_verbose" "load_start"))
           ('(normal nil) '("load.normal" "load.verbose" "load")))))
    (or (seq-find #'rtorred--method-available-p candidates)
        (car candidates))))

(defun rtorred--add (method arg label)
  "Call load METHOD with ARG, report LABEL, and refresh on success."
  (let ((buf (current-buffer)))
    (rtorred-rpc-async
     method (list "" arg)
     (lambda (_)
       (message "rtorred: added %s" label)
       (rtorred--after-action buf))
     (lambda (msg) (message "rtorred: add failed: %s" msg)))))

(defun rtorred-add-torrent-file (file &optional no-start)
  "Add the torrent in FILE to rtorrent, sending its contents.
With a prefix argument (NO-START), add it without starting it.
FILE is read on the local machine and uploaded as base64, so this works
even when rtorrent is remote."
  (interactive
   (list (read-file-name "Add torrent file: " nil nil t nil
                         (lambda (n) (or (file-directory-p n)
                                         (string-suffix-p ".torrent" n))))
         current-prefix-arg))
  (let ((data (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally file)
                (buffer-string))))
    (rtorred--add (rtorred--load-method 'raw (not no-start))
                  (cons :base64 data)
                  (file-name-nondirectory file))))

(defun rtorred-add-magnet (uri &optional no-start)
  "Add a magnet link or torrent URL URI to rtorrent.
With a prefix argument (NO-START), add it without starting it.  URI may
be a magnet: link or an http(s)/ftp URL to a .torrent (rtorrent fetches
and resolves it server-side)."
  (interactive (list (read-string "Add magnet or URL: ") current-prefix-arg))
  (let ((uri (string-trim uri)))
    (when (string-empty-p uri)
      (user-error "rtorred: nothing to add"))
    (rtorred--add (rtorred--load-method 'normal (not no-start)) uri uri)))

;;;; Detail view
;;
;; A read-only buffer showing one download's overview, files, trackers and
;; peers.  Files/trackers/peers each come from one multicall (`f.multicall',
;; `t.multicall', `p.multicall'); the overview reuses the data already in the
;; list buffer, so opening the view is cheap.

(defconst rtorred--file-fields
  '((path         . "f.path")
    (size         . "f.size_bytes")
    (done-chunks  . "f.completed_chunks")
    (total-chunks . "f.size_chunks")
    (priority     . "f.priority"))
  "Per-file fields fetched via `f.multicall'.")

(defconst rtorred--tracker-fields
  '((url        . "t.url")
    (enabled    . "t.is_enabled")
    (type       . "t.type")
    (complete   . "t.scrape_complete")
    (incomplete . "t.scrape_incomplete"))
  "Per-tracker fields fetched via `t.multicall'.")

(defconst rtorred--peer-fields
  '((address . "p.address")
    (client  . "p.client_version")
    (down    . "p.down_rate")
    (up      . "p.up_rate")
    (percent . "p.completed_percent"))
  "Per-peer fields fetched via `p.multicall'.")

(defun rtorred--multicall-async (rpc-method leading specs callback errback)
  "Run RPC-METHOD (e.g. \"f.multicall\") and decode its rows.
LEADING is the list of leading args (e.g. (HASH \"\")); SPECS is an
alist (KEY . COMMAND).  Server-unavailable commands are dropped.
CALLBACK receives a list of alists keyed by the SPEC keys."
  (let* ((available (cl-remove-if-not
                     (lambda (s)
                       (rtorred--method-available-p
                        (car (split-string (cdr s) "="))))
                     specs))
         (keys (mapcar #'car available))
         (cmds (mapcar (lambda (s) (rtorred--multicall-command (cdr s))) available)))
    (rtorred-rpc-async
     rpc-method (append leading cmds)
     (lambda (rows) (funcall callback (rtorred--rows->torrents keys rows)))
     errback)))

(defun rtorred--detail-fetch (hash callback)
  "Fetch files, trackers and peers for HASH, then call CALLBACK with a plist.
The plist has :files, :trackers and :peers (each a list of alists); an
aspect whose multicall fails is left nil."
  (rtorred--ensure-methods-async
   (lambda (_methods)
     (let ((data (list :files nil :trackers nil :peers nil))
           (lead (list hash "")))
       (rtorred--run-batch
        (list
         (lambda (k)
           (rtorred--multicall-async
            "f.multicall" lead rtorred--file-fields
            (lambda (rows) (plist-put data :files rows) (funcall k))
            (lambda (_) (funcall k))))
         (lambda (k)
           (rtorred--multicall-async
            "t.multicall" lead rtorred--tracker-fields
            (lambda (rows) (plist-put data :trackers rows) (funcall k))
            (lambda (_) (funcall k))))
         (lambda (k)
           (rtorred--multicall-async
            "p.multicall" lead rtorred--peer-fields
            (lambda (rows) (plist-put data :peers rows) (funcall k))
            (lambda (_) (funcall k)))))
        (lambda (_failures) (funcall callback data)))))))

(defun rtorred--file-priority-label (p)
  "Label rtorrent file priority P (0 off, 1 normal, 2 high)."
  (pcase p (0 "off") (1 "norm") (2 "high") (_ "")))

(defun rtorred--detail-rate (n)
  "Format N bytes/second for the detail view, showing 0 explicitly."
  (if (and (numberp n) (> n 0))
      (concat (file-size-human-readable n 'iec) "/s")
    "0/s"))

(defun rtorred-detail--row (label value)
  "Insert an overview LABEL/VALUE line."
  (insert (format "  %-11s %s\n" label (or value "—"))))

(defun rtorred-detail--overview (tr)
  "Insert the overview block for torrent alist TR."
  (let ((size (cdr (assq 'size tr))))
    (rtorred-detail--row "Size" (and size (file-size-human-readable size 'iec)))
    (rtorred-detail--row "Done" (rtorred--fmt-percent tr))
    (rtorred-detail--row "Status" (rtorred--fmt-status tr))
    (rtorred-detail--row "Ratio" (rtorred--fmt-ratio tr))
    (rtorred-detail--row "Down" (rtorred--detail-rate (cdr (assq 'down tr))))
    (rtorred-detail--row "Up" (rtorred--detail-rate (cdr (assq 'up tr))))
    (when (assq 'uptotal tr)
      (rtorred-detail--row "Uploaded" (file-size-human-readable
                                       (or (cdr (assq 'uptotal tr)) 0) 'iec)))
    (when (assq 'directory tr)
      (rtorred-detail--row "Directory" (cdr (assq 'directory tr))))
    (when (assq 'added tr)
      (rtorred-detail--row "Added" (funcall (rtorred--fmt-time 'added) tr)))
    (when (assq 'completed tr)
      (rtorred-detail--row "Completed" (funcall (rtorred--fmt-time 'completed) tr)))
    (let ((msg (cdr (assq 'message tr))))
      (when (and (stringp msg) (> (length msg) 0))
        (rtorred-detail--row "Message" msg)))
    (insert "\n")))

(defun rtorred-detail--section (title)
  "Insert a bold section TITLE."
  (insert (propertize title 'face 'bold) "\n"))

(defun rtorred-detail--files (files)
  "Insert the Files section for FILES (a list of alists).
Each line carries its file index in the `rtorred-file-index' property."
  (rtorred-detail--section (format "Files (%d)" (length files)))
  (if (null files)
      (insert "  —\n\n")
    (let ((i 0))
      (dolist (f files)
        (let* ((size (or (cdr (assq 'size f)) 0))
               (dc (cdr (assq 'done-chunks f)))
               (tc (cdr (assq 'total-chunks f)))
               (pct (if (and (numberp dc) (numberp tc) (> tc 0))
                        (/ (* 100 dc) tc) 0))
               (start (point)))
          (insert (format "  %3d%%  %9s  %-4s  %s\n"
                          pct
                          (file-size-human-readable size 'iec)
                          (rtorred--file-priority-label (cdr (assq 'priority f)))
                          (or (cdr (assq 'path f)) "")))
          (put-text-property start (point) 'rtorred-file-index i))
        (setq i (1+ i))))
    (insert "\n")))

(defun rtorred-detail--trackers (trackers)
  "Insert the Trackers section for TRACKERS (a list of alists).
Each line carries its tracker index in the `rtorred-tracker-index' property."
  (rtorred-detail--section (format "Trackers (%d)" (length trackers)))
  (if (null trackers)
      (insert "  —\n\n")
    (let ((i 0))
      (dolist (tk trackers)
        (let ((c (cdr (assq 'complete tk)))
              (in (cdr (assq 'incomplete tk)))
              (start (point)))
          (insert (format "  %s  %-52s %s\n"
                          (if (eq (cdr (assq 'enabled tk)) 1) "on " "off")
                          (or (cdr (assq 'url tk)) "")
                          (if (and (numberp c) (numberp in))
                              (format "(seeds %d / peers %d)" c in)
                            "")))
          (put-text-property start (point) 'rtorred-tracker-index i))
        (setq i (1+ i))))
    (insert "\n")))

(defun rtorred-detail--peers (peers)
  "Insert the Peers section for PEERS (a list of alists)."
  (rtorred-detail--section (format "Peers (%d)" (length peers)))
  (if (null peers)
      (insert "  —\n")
    (dolist (p peers)
      (insert (format "  %-21s %-16s  ↓%-10s ↑%-10s %3d%%\n"
                      (or (cdr (assq 'address p)) "")
                      (truncate-string-to-width (or (cdr (assq 'client p)) "") 16)
                      (rtorred--detail-rate (cdr (assq 'down p)))
                      (rtorred--detail-rate (cdr (assq 'up p)))
                      (or (cdr (assq 'percent p)) 0))))))

(defvar-local rtorred-detail--hash nil
  "Info-hash of the download shown in this detail buffer.")

(defvar-local rtorred-detail--torrent nil
  "Snapshot of the download's field alist, for the overview fallback.")

(defvar-local rtorred-detail--source nil
  "The rtorred list buffer this detail view was opened from.")

(defun rtorred-detail--current-torrent ()
  "Return the freshest field alist for this detail buffer's download.
Prefers live data from the source list buffer, falling back to the
snapshot taken when the view was opened."
  (or (and (buffer-live-p rtorred-detail--source)
           (with-current-buffer rtorred-detail--source
             (cdr (assoc rtorred-detail--hash rtorred--torrents))))
      rtorred-detail--torrent))

(defun rtorred-detail--render (torrent data)
  "Render the detail buffer for TORRENT (a field alist) and DATA (a plist)."
  (let ((inhibit-read-only t)
        (name (or (cdr (assq 'name torrent)) "(unknown)")))
    (erase-buffer)
    (insert (propertize name 'face 'bold) "\n"
            (make-string 60 ?─) "\n\n")
    (rtorred-detail--overview torrent)
    (rtorred-detail--files (plist-get data :files))
    (rtorred-detail--trackers (plist-get data :trackers))
    (rtorred-detail--peers (plist-get data :peers))
    (goto-char (point-min))))

(defun rtorred-detail--revert (&optional _arg _noconfirm)
  "Re-fetch and re-render this detail buffer."
  (let ((buf (current-buffer)))
    (rtorred--detail-fetch
     rtorred-detail--hash
     (lambda (data)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (rtorred-detail--render (rtorred-detail--current-torrent) data)))))))

(defun rtorred-detail--refresh-buf (buf)
  "Re-render detail buffer BUF if it is still live."
  (when (buffer-live-p buf)
    (with-current-buffer buf (rtorred-detail--revert))))

(defun rtorred-detail--file-priority (delta)
  "Adjust the priority of the file at point by DELTA (clamped 0..2)."
  (let ((idx (get-text-property (point) 'rtorred-file-index)))
    (if (null idx)
        (message "rtorred: point is not on a file")
      (let ((target (format "%s:f%d" rtorred-detail--hash idx))
            (hash rtorred-detail--hash)
            (buf (current-buffer)))
        (rtorred-rpc-async
         "f.priority" (list target)
         (lambda (cur)
           (let ((new (max 0 (min 2 (+ (if (numberp cur) cur 1) delta)))))
             (rtorred-rpc-async
              "f.priority.set" (list target new)
              (lambda (_)
                ;; Apply the new file priorities to the download.
                (rtorred-rpc-async
                 "d.update_priorities" (list hash)
                 (lambda (_) (rtorred-detail--refresh-buf buf))
                 (lambda (m) (message "rtorred: %s" m))))
              (lambda (m) (message "rtorred: %s" m)))))
         (lambda (m) (message "rtorred: %s" m)))))))

(defun rtorred-detail-file-priority-up ()
  "Raise the priority of the file at point."
  (interactive)
  (rtorred-detail--file-priority 1))

(defun rtorred-detail-file-priority-down ()
  "Lower the priority of the file at point."
  (interactive)
  (rtorred-detail--file-priority -1))

(defun rtorred-detail-toggle-tracker ()
  "Enable or disable the tracker at point."
  (interactive)
  (let ((idx (get-text-property (point) 'rtorred-tracker-index)))
    (if (null idx)
        (message "rtorred: point is not on a tracker")
      (let ((target (format "%s:t%d" rtorred-detail--hash idx))
            (buf (current-buffer)))
        (rtorred-rpc-async
         "t.is_enabled" (list target)
         (lambda (enabled)
           (rtorred-rpc-async
            (if (eq enabled 1) "t.disable" "t.enable") (list target)
            (lambda (_) (rtorred-detail--refresh-buf buf))
            (lambda (m) (message "rtorred: %s" m))))
         (lambda (m) (message "rtorred: %s" m)))))))

(define-derived-mode rtorred-detail-mode special-mode "rtorred-detail"
  "Major mode for an rtorrent download's detail view.

\\<rtorred-detail-mode-map>On a file line, \\[rtorred-detail-file-priority-up] / \
\\[rtorred-detail-file-priority-down] raise/lower its priority; on a tracker line, \
\\[rtorred-detail-toggle-tracker] toggles it.  Refresh with \\[revert-buffer], \
quit with \\[quit-window]."
  (setq-local revert-buffer-function #'rtorred-detail--revert))

(keymap-set rtorred-detail-mode-map "+" #'rtorred-detail-file-priority-up)
(keymap-set rtorred-detail-mode-map "-" #'rtorred-detail-file-priority-down)
(keymap-set rtorred-detail-mode-map "t" #'rtorred-detail-toggle-tracker)

(defun rtorred-detail ()
  "Open a detail view for the torrent at point."
  (interactive)
  (let* ((hash (tabulated-list-get-id))
         (torrent (and hash (cdr (assoc hash rtorred--torrents))))
         (source (current-buffer)))
    (if (null hash)
        (message "rtorred: no torrent here")
      (let ((buf (get-buffer-create
                  (format "*rtorred-detail: %s*" (or (cdr (assq 'name torrent)) hash)))))
        (with-current-buffer buf
          (rtorred-detail-mode)
          (setq rtorred-detail--hash hash
                rtorred-detail--torrent torrent
                rtorred-detail--source source)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "Loading…"))
          (rtorred-detail--revert))
        (pop-to-buffer buf)))))

;;;; Major mode

(defun rtorred-sort ()
  "Sort the download list by column.

With point on a column, sort by that column, reversing on a repeat
\(the parent `tabulated-list-sort' behaviour).  Otherwise, read a
column name with completion and sort by it -- so sorting works even
when point is on the leading padding or between columns."
  (interactive)
  (if (get-text-property (point) 'tabulated-list-column-name)
      (tabulated-list-sort)
    (let* ((sortable (cl-loop for col across tabulated-list-format
                              when (nth 2 col) collect (car col)))
           (default (car tabulated-list-sort-key))
           (name (completing-read
                  (format-prompt "Sort by column" default)
                  sortable nil t nil nil default))
           (index (cl-position name tabulated-list-format
                               :key #'car :test #'equal)))
      (tabulated-list-sort index))))

(defvar rtorred-mode-map (make-sparse-keymap)
  "Keymap for `rtorred-mode'.")

;; Bind keys with `keymap-set' rather than in the `defvar' so that
;; re-evaluating this file (e.g. `eval-buffer' during development)
;; updates the existing keymap object in place -- a plain `defvar' is a
;; no-op once the variable is bound, which would silently keep stale
;; bindings.  `g' (revert) and `q' (quit-window) come from the parent
;; modes.  Action keys (start/stop/erase/add) land here in a later pass.
(keymap-set rtorred-mode-map "S" #'rtorred-sort)
(keymap-set rtorred-mode-map "G" #'rtorred-toggle-auto-refresh)
;; Movement (dired-style).
(keymap-set rtorred-mode-map "n" #'next-line)
(keymap-set rtorred-mode-map "p" #'previous-line)
;; Marking.
(keymap-set rtorred-mode-map "m" #'rtorred-mark)
(keymap-set rtorred-mode-map "u" #'rtorred-unmark)
(keymap-set rtorred-mode-map "DEL" #'rtorred-unmark-backward)
(keymap-set rtorred-mode-map "U" #'rtorred-unmark-all)
(keymap-set rtorred-mode-map "t" #'rtorred-toggle-marks)
;; Actions (marked-or-current).
(keymap-set rtorred-mode-map "s" #'rtorred-start)
(keymap-set rtorred-mode-map "k" #'rtorred-stop)
(keymap-set rtorred-mode-map "c" #'rtorred-check-hash)
(keymap-set rtorred-mode-map "r" #'rtorred-retry)
(keymap-set rtorred-mode-map "P" #'rtorred-toggle-pause)
(keymap-set rtorred-mode-map "+" #'rtorred-priority-up)
(keymap-set rtorred-mode-map "-" #'rtorred-priority-down)
;; Erase: dired flag/execute, plus immediate erase.
(keymap-set rtorred-mode-map "d" #'rtorred-flag-for-erase)
(keymap-set rtorred-mode-map "x" #'rtorred-execute-flags)
(keymap-set rtorred-mode-map "D" #'rtorred-erase)
;; Detail view.
(keymap-set rtorred-mode-map "RET" #'rtorred-detail)
(keymap-set rtorred-mode-map "i" #'rtorred-detail)
;; Adding torrents.
(keymap-set rtorred-mode-map "a" #'rtorred-add-torrent-file)
(keymap-set rtorred-mode-map "A" #'rtorred-add-magnet)
;; Filtering (a prefix map).
(keymap-set rtorred-mode-map "/" rtorred-filter-map)

(define-derived-mode rtorred-mode tabulated-list-mode "rtorred"
  "Major mode for managing rtorrent downloads.

Refreshing is asynchronous: \\[revert-buffer] requests an update without
blocking Emacs, and the buffer auto-refreshes on a timer (see
`rtorred-auto-refresh-interval'; toggle with \\[rtorred-toggle-auto-refresh]).

\\{rtorred-mode-map}"
  (let ((cols (rtorred--active-columns)))
    (setq tabulated-list-format (rtorred--list-format cols))
    (setq tabulated-list-sort-key (rtorred--default-sort-key cols)))
  ;; Two-wide padding: one column for the mark/flag tag plus a separating
  ;; space before the first column (the `dired'/`package-menu' convention).
  (setq tabulated-list-padding 2)
  (setq-local truncate-lines t)
  (when rtorred-hl-line (hl-line-mode 1))
  (setq-local revert-buffer-function #'rtorred-revert)
  (add-hook 'kill-buffer-hook #'rtorred--stop-timer nil t)
  ;; Flex the Name column to the window width, and keep it sized on resize.
  (add-hook 'window-configuration-change-hook #'rtorred--adjust-name-width nil t)
  (tabulated-list-init-header)
  (rtorred--start-timer)
  (rtorred--mode-line))

;;;###autoload
(defun rtorred ()
  "Show and manage rtorrent downloads in the *rtorred* buffer."
  (interactive)
  (let ((buf (get-buffer-create "*rtorred*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'rtorred-mode)
        (rtorred-mode))
      (tabulated-list-print)
      (rtorred--refresh-async))
    (pop-to-buffer-same-window buf)
    ;; Size the Name column now that the buffer is in a window.
    (with-current-buffer buf (rtorred--adjust-name-width))))

(provide 'rtorred)
;;; rtorred.el ends here
