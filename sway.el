;;; sway.el --- Emacs 🖤 Sway  -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (c) 2020-2021 Thibault Polge <thibault@thb.lt>

;; Author: Thibault Polge <thibault@thb.lt>
;; Maintainer: Thibault Polge <thibault@thb.lt>
;;
;; Keywords: convenience
;; Homepage: https://github.com/thblt/sway.el
;; Version: 0.1

;; This program is free software; you can redistribute it and/or modify
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
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a very rudimentary library to talk to Sway from Emacs.  Its
;; main use case is in combination with Shackle or some other popup
;; managers, to 1) use frames instead of windows while still 2) giving
;; focus to existing frames instead of duplicating them.

;; It is highly likely that this will also work with i3, but it's
;; completely untested.

;; * General notes
;;
;; In this package, Emacs frames can be designated in three different
;; ways:
;;
;;  1. As regular Emacs frame objects, that verifies (framep)
;;  3. As Sway container IDs, integers.
;;  3. Or as combinations of both, as cons list (FRAME . WINDOW-ID)
;;
;; In a single case, Sway tree nodes or X-window IDs are used.

;;; Code:

(require 'dash)
(require 'json)

;;;; Low-level Sway interaction

(defcustom sway-swaymsg-binary (executable-find "swaymsg")
  "Path to `swaymsg' or a compatible program.")

(defun sway-find-socket ()
  "A non-subtle attempt to find the path to the Sway socket.
Having `sway-socket-tracker-mode' will help a lot.

This isn't easy, because:
 - The same daemon can survive multiple Sway/X instances, so the
   daemon's $SWAYSOCK can be obsolete.
 - But, lucky for us, client frames get a copy on the client's
   environment as a frame parameter!
 - But, stupid Emacs don't copy  parameter copy on new frames created
   from existing client frames, eg with C-x 5 2 (this is bug
   #47806).  This is why we have `sway-socket-tracker-mode'."
  (or (frame-parameter nil 'sway-socket)
      (getenv "SWAYSOCK" (selected-frame))
      (getenv "SWAYSOCK")))

(defun sway-json-parse-buffer ()
  "Parse current buffer as JSON, from point.

This function is just to save a few lambdas and make sure we're
reasonably consistent."
  (json-parse-buffer :null-object nil :false-object nil))

(defun sway-msg (handler message)
  "Send MESSAGE to swaymsg, writing output to HANDLER.

If HANDLER is a buffer, output is added to it.

If HANDLER is a function, output is written to a temporary
  buffer, then function is run on that buffer with point at the
  beginning and its result is returned.

Otherwise, output is dropped."
  (let ((buffer (or
                 (when (bufferp handler) handler)
                 (generate-new-buffer "*swaymsg*")))
        (process-environment (list (format "SWAYSOCK=%s" (sway-find-socket)))))
    (with-current-buffer buffer
      (call-process sway-swaymsg-binary nil buffer nil message)
      (when (functionp handler)
        (prog2
            (goto-char (point-min))
            (funcall handler)
          (kill-buffer buffer))))))

(defun sway-do (message &optional noerror)
  "Run a sway command that returns only success or error.

This function always returns t or raises an error, unless NOERROR
is non-nil.  If NOERROR is a function."
  (let ((err
         (sway--process-response
          message
          (sway-msg 'sway-json-parse-buffer message)
          (if noerror (if (functionp noerror) noerror 'ignore) 'error))))
    err))

(defun sway--process-response (message response &optional handler)
  "Read RESPONSE, a parsed Sway response.

Sway responses are always a vector of statuses, because `swaymsg'
can accept multiple messages.

If none of them is an error, return nil.  Otherwise, return
output suitable for an error message, optionally passing it to
HANDLER.

MESSAGE is the message that was sent to Sway.  It is used to
annotate the error output."
  (unless handler (setq handler 'identity))

  (when (cl-some (lambda (rsp) (not (gethash "success" rsp))) response)
    ;; We have an error.
    (funcall handler
             (concat
              (format "Sway error on `%s'" message)
              (mapconcat
               (lambda (rsp)
                 (format " -%s %s"
                         (if (gethash "parse_error" rsp) " [Parse error]" "")
                         (gethash "error" rsp (format "No message: %s" rsp))))
               response
               "\n")))))

;;;; Sway interaction

(defun sway-tree (&optional frame)
  "Get the Sway tree as an elisp object, using environment of FRAME.

If FRAME is nil, use the value of (selected-frame)."
  (with-temp-buffer
    (sway-msg 'sway-json-parse-buffer "-tget_tree")))

(defun sway-list-windows (&optional tree visible-only focused-only)
  "Walk TREE and return windows."
  ;; @TODO What this actually does is list terminal containers that
  ;; aren't workspaces.  The latter criterion is to eliminate
  ;; __i3_scratch, which is a potentially empty workspace.  It works,
  ;; but could maybe be improved.
  (unless tree
    (setq tree (sway-tree)))
  (let ((next-tree (gethash "nodes" tree)))
    (if (and
         (zerop (length next-tree))
         (not (string= "workspace" (gethash "type" tree)))
         (if visible-only (gethash "visible" tree) t)
         (if focused-only (gethash "focused" tree) t))
        tree ; Collect
      (-flatten ; Or recurse
       (mapcar
        (lambda (t2) (sway-list-windows t2 visible-only focused-only))
        next-tree)))))

;;;; Focus control

(defun sway-focus-container (id &optional noerror)
  "Focus Sway container ID.

ID is a Sway ID.  NOERROR is as in `sway-do', which see."
  (sway-do (format "[con_id=%s] focus;" id) noerror))

;;;; Windows and frames manipulation

(defun sway-find-x-window-frame (window)
  "Return the Emacs frame corresponding to Window, an X-Window ID.

Notice WINDOW is NOT a Sway ID, but a X id or a Sway tree objet.
If the latter, it most be the window node of a a tree

This is more of an internal-ish function.  It is used when
walking the tree to bridge Sway windows to frame objects, since
the X id is the only value available from both."
  (when (hash-table-p window)
    (setq window (gethash "window" window)))
  (cl-some (lambda (frame)
             (let ((owi (frame-parameter frame 'outer-window-id)))
               (and owi
                    (eq window (string-to-number owi))
                    frame)))
           (frame-list)))

(defun sway-find-frame-window (frame &optional tree)
  "Return the sway window id corresponding to FRAME.

FRAME is an Emacs frame object.

Use TREE if non-nil, otherwise call (sway-tree)."
  (unless tree (setq tree (sway-tree)))
  (cl-some
   (lambda (f)
     (when (eq frame (car f))
       (cdr f)))
   (sway-list-frames tree)))

(defun sway-get-id (tree)
  (gethash "id" tree))

(defun sway-list-frames (&optional tree visible-only focused-only)
  "List all Emacs frames in TREE.

VISIBLE-ONLY and FOCUSED-ONLY select only frames that are,
respectively, visible and focused.

Return value is a list of (FRAME-OBJECT . SWAY-ID)"
  (unless tree (setq tree (sway-tree)))
  (let* ((wins (sway-list-windows tree visible-only focused-only)))
    (seq-filter (lambda (x) (car x))
                (-zip
                 (mapcar 'sway-find-x-window-frame wins)
                 (mapcar 'sway-get-id wins)))))

(defun sway-frame-displays-buffer-p (frame buffer)
  "Determine if FRAME displays BUFFER."
  (cl-some
   (lambda (w) (eq (window-buffer w) buffer))
   (window-list frame nil)))

(defun sway-find-frame-for-buffer (buffer &optional tree visible-only focused-only)
  "Find which frame displays BUFFER.

TREE, VISIBLE-ONLY, FOCUSED-ONLY and return value are as in
`sway-list-frames', which see."
  (unless tree (setq tree (sway-tree)))
  (cl-some (lambda (f)
             (when (sway-frame-displays-buffer-p (car f) buffer)
               f))
           (sway-list-frames tree visible-only focused-only)))

;;;; Shackle integration

(defun sway-shackle-display-buffer-frame (buffer alist plist)
  "Show BUFFER in an Emacs frame, creating it if needed.

ALIST and PLIST are as in Shackle."
  (let* ((tree (sway-tree))
         (old-frame (sway-find-frame-window (selected-frame) tree))
         (sway (sway-find-frame-for-buffer buffer tree t))
         (frame (or (car sway)
                    (funcall pop-up-frame-function))))

    ;; Display buffer if frame doesn't already.
    (if (sway-frame-displays-buffer-p frame buffer)
        ;; Select existing window
        (set-frame-selected-window frame (get-buffer-window buffer frame))
      ;; Show buffer in current window
      (set-window-buffer (frame-selected-window frame) buffer))

    ;; (message "buffer=%s\nalist=%s\nplist=%s" buffer alist plist)

    ;; Give focus back to previous window.
    (sway-focus-container old-frame)

    ;; Mark as killable for undertaker mode
    ;; @TODO Make this a configuration option.
    (when (and (plist-get plist :dedicate)
               (not sway))
      (set-frame-parameter frame 'sway-dedicated buffer))

    ;; Return the window displaying buffer.
    (frame-selected-window frame)))
;;(let ((process-environment (frame-parameter frame 'environment)))
;;(call-process sway-swaymsg-binary nil nil nil (format sway-focus-message-format focused))))

;;;; The Undertaker: A stupid mode to make it easier to kill frames on bury-buffer

;; Another little trick, technically independant from sway.  Some
;; frames shouldn't last, but sometimes we reuse them.  sway.el marks
;; frames it creates with the `sway-dedicated' frame parameter, whose
;; value is a buffer.  As long as this frame keeps displaying only
;; this buffer in a single window, we kill the whole frame if this
;; buffer gets buried.

(defvar sway-undertaker-killer-commands
  (list 'bury-buffer
         'cvs-bury-buffer
         'magit-log-bury-buffer
         'magit-mode-bury-buffer
         'quit-window)
  "Commands whose invocation will kill the frame if it's still
dedicated.")

(defun sway--undertaker (&optional frame)
  "Call the undertaker on FRAME.

This should only be called from
`window-configuration-change-hook'.

If the frame is sway-dedicated, and `last-command' is one of
`sway-undertaker-killer-commands', delete the frame.

Otherwise, un-dedicate the frame if it has more than one window
or a window not displaying the buffer it's sway-dedicated to."
  (if (and (frame-parameter frame 'sway-dedicated)
           (member last-command sway-undertaker-killer-commands))
      ;; kill the frame
      (delete-frame frame)
    ;; otherwise, drop the sway-dedicated parameter if its contents have changed.
    (when-let ((buffer (frame-parameter nil 'sway-dedicated))
               (windows (window-list frame 'never)))
      (unless (and (= 1 (length windows))
                   (eq buffer (window-buffer (car windows))))
        ;; (message "Frame %s is now safe from The Undertaker because of %s." (or frame (selected-frame)) windows)
        (set-frame-parameter frame 'sway-dedicated nil)))))

(define-minor-mode sway-undertaker-mode
  "Remove the `sway-killable' parameter of frames on `window-configuration-change-hook'"
  :global t
  (if sway-undertaker-mode
      ;; Install
      (add-hook 'window-configuration-change-hook 'sway--undertaker)
    (remove-hook 'window-configuration-change-hook 'sway-undertaker-protect)))

;;;; Tracking minor mode

(defun sway--socket-tracker (frame)
  "Track path to the Sway socket.

Store the output of `sway-find-socket' as a parameter of FRAME.

This is meant to be run in `after-make-frame-functions', so that
the previous frame is still selected and we have better hope of
getting a value."
  (when-let ((socket (sway-find-socket)))
    (set-frame-parameter frame 'sway-socket socket)))

(define-minor-mode sway-socket-tracker-mode
  "Try not to lose the path to the Sway socket.

A minor mode to track the value of SWAYSOCK on newly created
frames.  This is a best effort approach, and remains probably
very fragile."
  :global t
  (if sway-socket-tracker-mode
      (add-hook 'after-make-frame-functions 'sway--socket-tracker)
    (remove-hook 'after-make-frame-functions 'sway--socket-tracker)))

(provide 'sway)

;;; sway.el ends here
