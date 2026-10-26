;;; agent-shell-codex-tests.el --- Capacity retry tests -*- lexical-binding: t; -*-

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

(provide 'agent-shell-codex-tests)
;;; agent-shell-codex-tests.el ends here
