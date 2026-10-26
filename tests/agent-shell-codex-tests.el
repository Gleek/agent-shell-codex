;;; agent-shell-codex-tests.el --- Codex extension tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agent-shell)
(require 'agent-shell-codex)

(defmacro agent-shell-codex-test--with-retry (&rest body)
  "Run BODY in a Codex shell with a captured retry timer."
  (declare (indent 0))
  `(with-temp-buffer
     (setq major-mode 'agent-shell-mode)
     (setq-local agent-shell--state
                 (list (cons :event-subscriptions nil)
                       (cons :agent-config '((:identifier . codex)))
                       (cons :session '((:id . "test-session")))))
     (let (callback delay sent cancelled
           (status 'ready))
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (seconds _repeat function &rest _args)
                    (setq delay seconds callback function)
                    'retry-timer))
                 ((symbol-function 'timerp) (lambda (value) (eq value 'retry-timer)))
                 ((symbol-function 'cancel-timer) (lambda (_) (setq cancelled t)))
                 ((symbol-function 'agent-shell-status) (lambda (&rest _) status))
                 ((symbol-function 'agent-shell--prompt-input-start) #'point-min)
                 ((symbol-function 'agent-shell-insert)
                  (lambda (&rest args) (setq sent args))))
         ,@body))))

(ert-deftest agent-shell-codex-capacity-error-retries ()
  (agent-shell-codex-test--with-retry
    (agent-shell-codex--capacity-event
     '((:event . error)
       (:data . ((:message . "Selected model is at capacity. Please try a different model.")))))
    (should (= delay 10))
    (should-not sent)
    (funcall callback)
    (should (equal (plist-get sent :text) "continue"))
    (should (plist-get sent :submit))
    (should (plist-get sent :no-focus))
    (should (eq (plist-get sent :shell-buffer) (current-buffer)))))

(ert-deftest agent-shell-codex-capacity-stream-waits-for-turn-end ()
  (agent-shell-codex-test--with-retry
    (dolist (chunk '("Selected model is at " "capacity. Please try a different model."))
      (agent-shell-codex--capacity-event
       `((:event . agent-message-chunk) (:data . ((:text-chunk . ,chunk))))))
    (should-not callback)
    (agent-shell-codex--capacity-event
     '((:event . turn-complete) (:data . ((:stop-reason . "end_turn")))))
    (should (= delay 10))))

(ert-deftest agent-shell-codex-capacity-ignores-other-errors-and-agents ()
  (agent-shell-codex-test--with-retry
    (agent-shell-codex--capacity-event
     '((:event . error) (:data . ((:message . "Authentication failed")))))
    (should-not callback)
    (setf (alist-get :agent-config agent-shell--state) '((:identifier . claude)))
    (agent-shell-codex--capacity-event
     '((:event . error) (:data . ((:message . "Selected model is at capacity")))))
    (should-not callback)))

(ert-deftest agent-shell-codex-capacity-cancels-on-input-or-cleanup ()
  (dolist (event '(input-submitted clean-up))
    (agent-shell-codex-test--with-retry
      (agent-shell-codex--schedule-capacity-retry)
      (agent-shell-codex--capacity-event `((:event . ,event)))
      (should cancelled)
      (should-not agent-shell-codex--capacity-timer))))

(ert-deftest agent-shell-codex-capacity-preserves-drafts-and-busy-sessions ()
  (agent-shell-codex-test--with-retry
    (agent-shell-codex--schedule-capacity-retry)
    (insert "My draft")
    (funcall callback)
    (should-not sent)
    (erase-buffer)
    (setq status 'busy)
    (funcall callback)
    (should-not sent)))

(ert-deftest agent-shell-codex-capacity-ignores-cancelled-turns ()
  (agent-shell-codex-test--with-retry
    (setq agent-shell-codex--capacity-text "Selected model is at capacity")
    (agent-shell-codex--capacity-event
     '((:event . turn-complete) (:data . ((:stop-reason . "cancelled")))))
    (should-not callback)))

(ert-deftest agent-shell-codex-capacity-listener-is-idempotent ()
  (agent-shell-codex-test--with-retry
    (agent-shell-codex--listen-for-capacity)
    (agent-shell-codex--listen-for-capacity)
    (should (= 1 (length (map-elt agent-shell--state :event-subscriptions))))))

(defmacro agent-shell-codex-test--with-history (&rest body)
  "Run BODY with a Codex shell and recorded app-server operations."
  (declare (indent 0))
  `(agent-shell-codex-test--with-retry
     (let (operations request-failure
           (history-mode "paginated"))
       (cl-letf (((symbol-function 'make-process) (lambda (&rest _) 'test-process))
                 ((symbol-function 'process-live-p) (lambda (_) nil))
                 ((symbol-function 'agent-shell-codex--send-json-rpc) #'ignore)
                 ((symbol-function 'agent-shell-codex--list-turns)
                  (lambda (_)
                    '(((id . "first")) ((id . "second")) ((id . "third")))))
                 ((symbol-function 'completing-read)
                  (lambda (_prompt collection &rest _)
                    (seq-find (lambda (item) (string-prefix-p "Turn 2:" item))
                              (all-completions "" collection))))
                 ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                 ((symbol-function 'agent-shell--shutdown)
                  (lambda () (push "shutdown" operations)))
                 ((symbol-function 'agent-shell-reload)
                  (lambda () (push "reload" operations)))
                 ((symbol-function 'agent-shell-codex--request-using)
                  (lambda (_process _buffer method params)
                    (unless (equal method "initialize")
                      (push (list method params) operations))
                    (when (and request-failure (equal method "thread/revert"))
                      (error "Revert failed"))
                    `((thread . ((historyMode . ,history-mode))))))
                 ((symbol-function 'agent-shell-codex--request)
                  (lambda (method params)
                    (push (list method params) operations)
                    (when request-failure (error "Archive failed")))))
         ,@body))))

(ert-deftest agent-shell-codex-rewind-reverts-selected-turn-after-shutdown ()
  (agent-shell-codex-test--with-history
    (agent-shell-codex-rewind)
    (should (equal
             (reverse operations)
             '("shutdown"
               ("thread/resume" ((threadId . "test-session") (excludeTurns . t)))
               ("thread/revert" ((threadId . "test-session") (beforeTurnId . "second")))
               "reload")))))

(ert-deftest agent-shell-codex-rewind-reloads-on-failure ()
  (agent-shell-codex-test--with-history
    (setq request-failure t)
    (should-error (agent-shell-codex-rewind))
    (should (equal (car operations) "reload"))))

(ert-deftest agent-shell-codex-archive-closes-shell-after-shutdown ()
  (agent-shell-codex-test--with-history
    (let ((buffer (current-buffer)))
      (agent-shell-codex-archive-this-session)
      (should-not (buffer-live-p buffer))
      (should (equal (reverse operations)
                     '("shutdown" ("thread/archive" ((threadId . "test-session")))))))))

(ert-deftest agent-shell-codex-archive-reloads-on-failure ()
  (agent-shell-codex-test--with-history
    (setq request-failure t)
    (let ((buffer (current-buffer)))
      (should-error (agent-shell-codex-archive-this-session))
      (should (equal (car operations) "reload"))
      (should (buffer-live-p buffer)))))

(ert-deftest agent-shell-codex-rewind-leaves-legacy-history-unchanged ()
  (agent-shell-codex-test--with-history
    (setq history-mode "legacy")
    (should-error (agent-shell-codex-rewind) :type 'user-error)
    (should-not (assoc "thread/revert" operations))
    (should (equal (car operations) "reload"))))

(ert-deftest agent-shell-codex-history-rejects-other-agents ()
  (agent-shell-codex-test--with-retry
    (setf (alist-get :agent-config agent-shell--state) '((:identifier . claude)))
    (should-error (agent-shell-codex--current-shell) :type 'user-error)))

(provide 'agent-shell-codex-tests)
;;; agent-shell-codex-tests.el ends here
