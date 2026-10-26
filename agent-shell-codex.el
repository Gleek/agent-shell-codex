;;; agent-shell-codex.el --- Codex specific extensions for agent-shell  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar Ahmad
;; Author: Umar Ahmad
;; URL: https://github.com/Gleek/agent-shell-codex
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.87.10"))
;; Keywords: convenience, tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Provides Codex specific functionality for agent-shell using the
;; local Codex app-server protocol.
;;
;; The Codex app-server API used here is experimental.
;; Method names and payloads may change across Codex releases.

;;; Code:

(require 'agent-shell)
(require 'cl-lib)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)

(declare-function term-mode "term")
(declare-function term-char-mode "term")

(defgroup agent-shell-codex nil
  "Codex specific extensions for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-codex-")

(defcustom agent-shell-codex-show-usage-indicator nil
  "Whether to show the current CLI account's subscription quota in the header.
Independent of `agent-shell-show-cost-indicator'; both can be enabled."
  :type 'boolean
  :group 'agent-shell-codex)

(defcustom agent-shell-codex-app-server-command
  '("codex" "app-server" "--listen" "stdio://")
  "Command used to start a local Codex app-server over stdio."
  :type '(repeat string)
  :group 'agent-shell-codex)

(defcustom agent-shell-codex-app-server-timeout 10
  "Seconds to wait for a Codex app-server JSON-RPC response."
  :type 'number
  :group 'agent-shell-codex)

(defvar agent-shell-codex--request-id 0)

(defvar agent-shell-codex--quota nil
  "Cached quota for the current CLI login, shared across Codex buffers.")
(defvar agent-shell-codex--quota-process nil)
(defvar agent-shell-codex--quota-timer nil)

(defvar-local agent-shell-codex--capacity-timer nil)
(defvar-local agent-shell-codex--capacity-text "")
(defvar-local agent-shell-codex--capacity-subscription nil)

(defun agent-shell-codex--cancel-capacity-retry ()
  "Cancel any pending capacity retry in this buffer."
  (when (timerp agent-shell-codex--capacity-timer)
    (cancel-timer agent-shell-codex--capacity-timer))
  (setq agent-shell-codex--capacity-timer nil
        agent-shell-codex--capacity-text ""))

(defun agent-shell-codex--schedule-capacity-retry ()
  "Send `continue' in ten seconds if this Codex session remains idle.
Leave any unsubmitted input alone.  A repeated capacity error retries again."
  (agent-shell-codex--cancel-capacity-retry)
  (let ((buffer (current-buffer))
        (session-id (map-nested-elt (agent-shell--state) '(:session :id))))
    (setq agent-shell-codex--capacity-timer
          (run-at-time
           10 nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq agent-shell-codex--capacity-timer nil)
                 (when-let* (((equal session-id
                                     (map-nested-elt (agent-shell--state)
                                                     '(:session :id))))
                             (session-id)
                             ((eq (agent-shell-status) 'ready))
                             (start (agent-shell--prompt-input-start))
                             ((string-blank-p
                               (buffer-substring-no-properties start (point-max)))))
                   (agent-shell-insert :text "continue" :submit t
                                       :no-focus t :shell-buffer buffer))))))))
  (message "Codex at capacity; retrying in 10 seconds"))

(defun agent-shell-codex--capacity-event (event)
  "Retry a capacity failure reported by agent-shell EVENT.
For example, an `error' containing \"Selected model is at capacity\"
starts a ten-second timer.  Streamed messages wait for `turn-complete'."
  (when (eq (map-nested-elt (agent-shell--state)
                            '(:agent-config :identifier)) 'codex)
    (pcase (map-elt event :event)
      ((or 'input-submitted 'clean-up)
       (agent-shell-codex--cancel-capacity-retry))
      ('agent-message-chunk
       (setq agent-shell-codex--capacity-text
             (concat agent-shell-codex--capacity-text
                     (map-nested-elt event '(:data :text-chunk)))))
      ((or 'error 'turn-complete)
       (let ((capacity
              (string-match-p
               (regexp-quote "Selected model is at capacity")
               (or (map-nested-elt event '(:data :message))
                   agent-shell-codex--capacity-text))))
         (setq agent-shell-codex--capacity-text "")
         (when (and capacity
                    (not (equal (map-nested-elt event '(:data :stop-reason))
                                "cancelled")))
           (agent-shell-codex--schedule-capacity-retry)))))))

(defun agent-shell-codex--listen-for-capacity ()
  "Install the capacity listener once in the current shell buffer."
  (unless (seq-some
           (lambda (subscription)
             (equal (map-elt subscription :token)
                    agent-shell-codex--capacity-subscription))
           (map-elt (agent-shell--state) :event-subscriptions))
    (setq agent-shell-codex--capacity-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :on-event #'agent-shell-codex--capacity-event))
    (add-hook 'kill-buffer-hook #'agent-shell-codex--cancel-capacity-retry nil t)))

(add-hook 'agent-shell-mode-hook #'agent-shell-codex--listen-for-capacity)
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'agent-shell-mode)
      (agent-shell-codex--listen-for-capacity))))

(defun agent-shell-codex--auth (&rest args)
  "Run codex-auth with ARGS and return its JSON response."
  (with-temp-buffer
    (let* ((status (apply #'call-process "codex-auth" nil (list t nil) nil
                          (append args '("--json"))))
           (result (progn (goto-char (point-min))
                          (json-parse-buffer :object-type 'alist :array-type 'list
                                             :null-object nil :false-object nil))))
      (unless (equal status 0)
        (user-error "%s" (or (alist-get 'message (alist-get 'error result))
                             "codex-auth failed")))
      result)))

;;;###autoload
(defun agent-shell-codex-login ()
  "Add a Codex account through codex-auth's browser login."
  (interactive)
  (require 'term)
  (pop-to-buffer
   (make-term "codex-auth-login"
              (or (executable-find "codex-auth")
                  (user-error "Install @loongphy/codex-auth first"))
              nil "login"))
  (term-mode)
  (term-char-mode))

;;;###autoload
(defun agent-shell-codex-switch-account (account)
  "Switch the shared CLI ACCOUNT using codex-auth, then start a new shell.
Running clients need restarting to pick up the changed login."
  (interactive
   (let* ((accounts (alist-get 'accounts
                              (agent-shell-codex--auth "list" "--skip-api")))
          (choices
           (mapcar (lambda (account)
                     (cons (format "%s: %s <%s> (%s)%s"
                                   (alist-get 'number account)
                                   (or (alist-get 'alias account) "")
                                   (or (alist-get 'email account) "")
                                   (or (alist-get 'plan account) "unknown")
                                   (if (alist-get 'active account) " [active]" ""))
                           (alist-get 'account_key account)))
                   accounts)))
     (unless choices
       (user-error "No accounts saved; run agent-shell-codex-login first"))
     (list (cdr (assoc (completing-read "Codex account: " choices nil t)
                       choices)))))
  (agent-shell-codex--auth "switch" account)
  (setq agent-shell-codex--quota nil)
  (agent-shell-codex-refresh-usage)
  (agent-shell-openai-start-codex))

(defun agent-shell-codex--current-shell ()
  "Return the current Codex shell, or signal a user error."
  (let ((buffer (or (agent-shell--current-shell)
                    (user-error "Not in a shell"))))
    (unless (eq (map-nested-elt (buffer-local-value 'agent-shell--state buffer)
                               '(:agent-config :identifier)) 'codex)
      (user-error "Not in a Codex shell"))
    buffer))

(defun agent-shell-codex--session-id (&optional shell-buffer)
  "Return the Codex session id for SHELL-BUFFER."
  (let* ((buf (or shell-buffer (agent-shell-codex--current-shell)))
         (session-id (map-nested-elt (buffer-local-value 'agent-shell--state buf)
                                     '(:session :id))))
    (unless session-id
      (user-error "No active session"))
    session-id))

(defun agent-shell-codex--ensure-ready (shell-buffer)
  "Signal an error unless SHELL-BUFFER is ready for history mutation."
  (unless (eq (agent-shell-status :shell-buffer shell-buffer) 'ready)
    (user-error "Codex session is busy; try again when the turn finishes")))

(defun agent-shell-codex--json-rpc-request (method &optional params)
  "Return a JSON-RPC request object for METHOD and PARAMS."
  `((id . ,(cl-incf agent-shell-codex--request-id))
    (method . ,method)
    ,@(when params `((params . ,params)))))

(defun agent-shell-codex--send-json-rpc (process request)
  "Send REQUEST to PROCESS as newline-delimited JSON."
  (process-send-string process (concat (json-encode request) "\n")))

(defun agent-shell-codex--parse-json-line (line)
  "Parse LINE as JSON, returning nil on parse failure."
  (condition-case nil
      (json-parse-string line :object-type 'alist :array-type 'list)
    (json-parse-error nil)))

(defun agent-shell-codex--wait-response (process buffer request-id)
  "Wait for REQUEST-ID response from PROCESS using BUFFER."
  (let ((deadline (+ (float-time) agent-shell-codex-app-server-timeout))
        (read-pos (point-min))
        response)
    (with-current-buffer buffer
      (while (and (not response)
                  (< (float-time) deadline))
        (accept-process-output process 0.05)
        (goto-char read-pos)
        (while (and (not response)
                    (not (eobp))
                    (search-forward "\n" nil t))
          (let* ((line (string-trim
                        (buffer-substring-no-properties read-pos (1- (point)))))
                 (obj (and (not (string-empty-p line))
                           (agent-shell-codex--parse-json-line line))))
            (setq read-pos (point))
            (when (and obj (equal (alist-get 'id obj) request-id))
              (setq response obj))))
        (when (and (not response)
                   (not (process-live-p process))
                   (>= read-pos (point-max)))
          (error "Codex app-server exited before response %s" request-id)))
      (unless response
        (error "Timed out waiting for Codex app-server response %s" request-id))
      (when-let ((err (alist-get 'error response)))
        (user-error "Codex app-server error: %s"
                    (or (alist-get 'message err)
                        (format "%S" err))))
      (alist-get 'result response))))

(defmacro agent-shell-codex--with-app-server (&rest body)
  "Start a short-lived Codex app-server and evaluate BODY.
Inside BODY, `process' and `buffer' are bound to the server process and
its output buffer."
  (declare (indent 0) (debug t))
  `(let* ((buffer (generate-new-buffer " *agent-shell-codex-app-server*"))
          (process (make-process
                    :name "agent-shell-codex-app-server"
                    :buffer buffer
                    :command agent-shell-codex-app-server-command
                    :connection-type 'pipe
                    :noquery t)))
     (unwind-protect
         (progn
           (agent-shell-codex--request-using
            process buffer "initialize"
            '((clientInfo (name . "agent-shell-codex") (version . "0.1"))
              (capabilities (experimentalApi . t))))
           (agent-shell-codex--send-json-rpc process '((method . "initialized")))
           ,@body)
       (when (process-live-p process)
         (delete-process process))
       (when (buffer-live-p buffer)
         (kill-buffer buffer)))))

(defun agent-shell-codex--request (method params)
  "Synchronously call Codex app-server METHOD with PARAMS."
  (agent-shell-codex--with-app-server
    (agent-shell-codex--request-using process buffer method params)))

(defun agent-shell-codex--request-using (process buffer method params)
  "Synchronously call Codex app-server METHOD with PARAMS.
Use existing app-server PROCESS and BUFFER."
  (let* ((request (agent-shell-codex--json-rpc-request method params))
         (request-id (alist-get 'id request)))
    (agent-shell-codex--send-json-rpc process request)
    (agent-shell-codex--wait-response process buffer request-id)))

(defun agent-shell-codex--quota-window (window)
  "Format a quota WINDOW with its actual duration and remaining percentage."
  (when (and (listp window) (numberp (alist-get 'usedPercent window)))
    (let* ((minutes (alist-get 'windowDurationMins window))
           (label (cond ((not (numberp minutes)) "quota")
                        ((= minutes 10080) "weekly")
                        ((zerop (% minutes 60)) (format "%gh" (/ minutes 60.0)))
                        (t (format "%gm" minutes)))))
      (format "%s %.0f%% left" label
              (max 0 (min 100 (- 100 (alist-get 'usedPercent window))))))))

(defun agent-shell-codex--quota-indicator ()
  "Return the CLI account quota for a Codex header when enabled."
  (when (and agent-shell-codex-show-usage-indicator
             (eq (map-nested-elt (agent-shell--state)
                                 '(:agent-config :identifier)) 'codex)
             (listp agent-shell-codex--quota))
    (let* ((windows (seq-filter (lambda (window)
                                  (and (listp window)
                                       (numberp (alist-get 'usedPercent window))))
                                (mapcar (lambda (key)
                                          (alist-get key agent-shell-codex--quota))
                                        '(primary secondary))))
           (parts (delq nil (mapcar #'agent-shell-codex--quota-window windows))))
      (when parts
        (propertize
         (let* ((email (alist-get 'email agent-shell-codex--quota))
                (text (concat (if (stringp email) email "Codex")
                              " · " (string-join parts " · "))))
           (if (eq agent-shell-header-style 'text)
               (replace-regexp-in-string "%" "%%" text t t)
             text))
         'face 'agent-shell-secondary
         'help-echo
         (concat "Quota for the current Codex CLI login (shared across shells)."
                 "\nOlder shells may use a different login."
                 (mapconcat
                  (lambda (window)
                    (if (numberp (alist-get 'resetsAt window))
                        (concat "\n" (agent-shell-codex--quota-window window)
                                "; resets "
                                (format-time-string
                                 "%a %d %b %H:%M %Z"
                                 (seconds-to-time (alist-get 'resetsAt window))))
                      ""))
                  windows "")))))))

(defun agent-shell-codex--add-quota-to-header (model)
  "Append subscription quota beside any session cost in header MODEL."
  (when-let* ((quota (agent-shell-codex--quota-indicator)))
    (map-put! model :cost-indicator
              (string-join (delq nil (list (map-elt model :cost-indicator) quota))
                           " ➤ ")))
  model)

(defun agent-shell-codex--update-quota-headers ()
  "Rebuild Codex headers after the cached account quota changes."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'agent-shell-mode)
                 (eq (map-nested-elt (agent-shell--state)
                                     '(:agent-config :identifier)) 'codex))
        (agent-shell--update-header-and-mode-line)))))

;;;###autoload
(defun agent-shell-codex-refresh-usage ()
  "Fetch the current CLI login's subscription quota without blocking Emacs.
Refresh automatically once a minute while a Codex shell is visible.
Uses `agent-shell-codex-show-usage-indicator' to control header visibility."
  (interactive)
  (when (process-live-p agent-shell-codex--quota-process)
    (delete-process agent-shell-codex--quota-process))
  (let* ((initialize (agent-shell-codex--json-rpc-request
                      "initialize"
                      '((clientInfo (name . "agent-shell-codex") (version . "0.1")))))
         (account (agent-shell-codex--json-rpc-request "account/read" (make-hash-table)))
         (request (agent-shell-codex--json-rpc-request "account/rateLimits/read"))
         (pending "")
         timeout)
    (setq agent-shell-codex--quota-process
          (make-process
           :name "agent-shell-codex-quota" :noquery t
           :command agent-shell-codex-app-server-command
           :connection-type 'pipe :buffer nil
           :stderr (get-buffer-create " *agent-shell-codex-quota-errors*")
           :filter
           (lambda (process chunk)
             (setq pending (concat pending chunk))
             (while (string-match "\n" pending)
               (let* ((end (match-end 0))
                      (response (agent-shell-codex--parse-json-line
                                 (substring pending 0 end))))
                 (setq pending (substring pending end))
                 (cond
                  ((equal (alist-get 'id response) (alist-get 'id initialize))
                   (if (alist-get 'error response)
                       (delete-process process)
                     (agent-shell-codex--send-json-rpc
                      process '((method . "initialized")))
                     (agent-shell-codex--send-json-rpc process account)))
                  ((equal (alist-get 'id response) (alist-get 'id account))
                   (if (alist-get 'error response)
                       (delete-process process)
                     (process-put process 'email
                                  (map-nested-elt response '(result account email)))
                     (agent-shell-codex--send-json-rpc process request)))
                  ((equal (alist-get 'id response) (alist-get 'id request))
                   (let ((result (alist-get 'result response)))
                     (setq agent-shell-codex--quota
                           (or (map-nested-elt result '(rateLimitsByLimitId codex))
                               (alist-get 'rateLimits result)))
                     (when (listp agent-shell-codex--quota)
                       (push (cons 'email (process-get process 'email))
                             agent-shell-codex--quota))
                     (process-put process 'quota-received t)
                     (delete-process process)))))))
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (when timeout (cancel-timer timeout))
               (unless (process-get process 'quota-received)
                 (setq agent-shell-codex--quota nil))
               (agent-shell-codex--update-quota-headers)))))
    (setq timeout (run-at-time agent-shell-codex-app-server-timeout nil
                               (lambda (process)
                                 (when (process-live-p process)
                                   (delete-process process)))
                               agent-shell-codex--quota-process))
    (agent-shell-codex--send-json-rpc agent-shell-codex--quota-process initialize)))

(defun agent-shell-codex--poll-quota ()
  "Refresh quota when enabled and a Codex buffer is visible."
  (when (and agent-shell-codex-show-usage-indicator
             (not (process-live-p agent-shell-codex--quota-process))
             (seq-some (lambda (buffer)
                         (with-current-buffer buffer
                           (and (get-buffer-window buffer t)
                                (derived-mode-p 'agent-shell-mode)
                                (eq (map-nested-elt (agent-shell--state)
                                                    '(:agent-config :identifier))
                                    'codex))))
                       (buffer-list)))
    (agent-shell-codex-refresh-usage)))

(advice-add 'agent-shell--make-header-model :filter-return
            #'agent-shell-codex--add-quota-to-header)
(when (timerp agent-shell-codex--quota-timer)
  (cancel-timer agent-shell-codex--quota-timer))
(setq agent-shell-codex--quota-timer
      (run-at-time 0 60 #'agent-shell-codex--poll-quota))

(defun agent-shell-codex--turn-text (turn)
  "Return a displayable user message preview for TURN."
  (let* ((items (alist-get 'items turn))
         (user-item (seq-find (lambda (item)
                                (equal (alist-get 'type item) "userMessage"))
                              items))
         (content (alist-get 'content user-item))
         (text-items (seq-filter (lambda (item)
                                   (equal (alist-get 'type item) "text"))
                                 content))
         (text (mapconcat (lambda (item)
                            (or (alist-get 'text item) ""))
                          text-items
                          "\n")))
    (truncate-string-to-width
     (string-trim (replace-regexp-in-string "[\n\r]+" " " text))
     80 nil nil "...")))

(defun agent-shell-codex--list-turns (session-id)
  "Return turns for SESSION-ID ordered oldest first."
  (let* ((result (agent-shell-codex--request
                  "thread/turns/list"
                  `((threadId . ,session-id)
                    (limit . 100)
                    (sortDirection . "desc")
                    (itemsView . "summary"))))
         (turns (alist-get 'data result)))
    (nreverse turns)))

;;;###autoload
(defun agent-shell-codex-rewind ()
  "Rewind the current Codex session to before a selected turn.
Use `thread/revert' to update paginated history, then reload the shell.
Project files are unchanged.  Legacy history must be migrated first."
  (interactive)
  (let* ((shell-buffer (agent-shell-codex--current-shell))
         (session-id (agent-shell-codex--session-id shell-buffer)))
    (agent-shell-codex--ensure-ready shell-buffer)
    (let* ((turns (agent-shell-codex--list-turns session-id))
           (candidates (cl-loop for turn in (cdr turns)
                                for index from 2
                                collect (cons (format "Turn %d: %s" index
                                                      (agent-shell-codex--turn-text turn))
                                              (alist-get 'id turn)))))
      (unless candidates
        (user-error "Not enough turns to rewind (need at least 2)"))
      (let* ((selection (completing-read
                         "Rewind to before: "
                         (lambda (string pred action)
                           (if (eq action 'metadata)
                               '(metadata (display-sort-function . identity))
                             (complete-with-action action (reverse candidates) string pred)))
                         nil t))
             (turn-id (cdr (assoc selection candidates))))
        (when (yes-or-no-p (format "Rewind to before %s? " selection))
          (with-current-buffer shell-buffer
            (agent-shell--shutdown)
            (unwind-protect
                (agent-shell-codex--with-app-server
                  (unless (equal
                           (map-nested-elt
                            (agent-shell-codex--request-using
                             process buffer "thread/resume"
                             `((threadId . ,session-id) (excludeTurns . t)))
                            '(thread historyMode))
                           "paginated")
                    (user-error "Migrate legacy history first: codex migrate-rollouts --thread %s --apply"
                                session-id))
                  (agent-shell-codex--request-using
                   process buffer "thread/revert"
                   `((threadId . ,session-id) (beforeTurnId . ,turn-id))))
              (agent-shell-reload)))
          (message "Codex session rewound"))))))

;;;###autoload
(defun agent-shell-codex-archive-this-session ()
  "Archive the current Codex session and kill its agent-shell buffer.
This is Codex's official-ish delete equivalent; it hides the session
from normal session lists without directly deleting JSONL or SQLite
state."
  (interactive)
  (let* ((shell-buffer (agent-shell-codex--current-shell))
         (session-id (agent-shell-codex--session-id shell-buffer)))
    (agent-shell-codex--ensure-ready shell-buffer)
    (when (yes-or-no-p "Archive current Codex session? ")
      (with-current-buffer shell-buffer
        (agent-shell--shutdown)
        (condition-case err
            (agent-shell-codex--request "thread/archive"
                                        `((threadId . ,session-id)))
          (error
           (agent-shell-reload)
           (signal (car err) (cdr err)))))
      (kill-buffer shell-buffer)
      (message "Archived Codex session %s" session-id))))

(provide 'agent-shell-codex)
;;; agent-shell-codex.el ends here
