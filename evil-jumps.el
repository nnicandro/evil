;;; evil-jumps.el --- Jump list implementation -*- lexical-binding: t -*-

;; Author: Nathaniel Nicandro <nathanielnicandro at gmail.com>
;; Original Author: Bailey Ling <bling at live.ca>
;;

;; Version: 1.14.0

;;
;; This file is NOT part of GNU Emacs.

;;; License:

;; This file is part of Evil.
;;
;; Evil is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Evil is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Evil.  If not, see <http://www.gnu.org/licenses/>.

(require 'subr-x)
(require 'cl-lib)
(require 'evil-core)
(require 'evil-states)

;;; Commentary:

;; A jumplist is a list of buffer positions. Your current position within a
;; file will be saved to the jumplist before executing certain motion commands
;; (more specifically, motion commands with a non-nil `:jump' property). For
;; example, pressing gg will save your current location to the jumplist and
;; move `point' to the beginning of the buffer. You can jump backward to the
;; saved position by pressing C-o (`evil-jump-backward'). On the first backward
;; jump, the position you jumped from will also be saved to the jumplist so
;; that you can return back to the location where you first pressed C-o, i.e.
;; jump forward through the jumplist, by pressing C-i (`evil-jump-forward').
;; You navigate the jumplist by additional presses of C-o and C-i.
;;
;; Your position on the jumplist will be maintained until a new jump point is
;; set, so that if you jump backward a few times and edit the buffer you may
;; jump forward to your original location as long as no new jump point was set
;; while modifying the buffer. To view the the current history of jumps, run
;; the Ex command :ju[mps] or bind `evil-show-jumps' to an appropriate key.
;;
;; In addition to setting a jump point before executing some motion commands,
;; jump points are set before every buffer switch and before every window
;; split. To prevent setting a jump point for commands that switch buffers or
;; split windows you may add the command to `evil-jumps-ignored-commands'. As
;; an example, since `evil-show-jumps' splits the window a new jump point would
;; be added every time you view the jumplist if it were not in
;; `evil-jumps-ignored-commands'. There is also
;; `evil-jumps-ignored-file-patterns' which prevents setting jump points
;; in files matching any of the patterns, and
;; `evil-jumps-allowed-buffer-patterns' which allows setting jump points in
;; buffers with names that match any of the patterns when the buffer is not
;; associated with a file.
;;
;; The jumplist only contains unique jump points. Jumps that exist on the same
;; line of a file are considered the same and only the most recently set jump
;; point on the line will be present in the jumplist.

;; Implementation details
;;
;; Jumplists are stored in frame/window parameters as the `evil-jumplist'
;; parameter. The frame's jumplist acts as the default jumplist. When a window
;; is deleted, its jumplist is merged into the frame's jumplist. When a new
;; window is split from an existing window the new window's jumplist is
;; obtained first by trying to copy over the existing window's jumplist and if
;; that fails, by copying the jumplist of the frame. To avoid unnecessary
;; copying, only shallow copies of a jumplist are made when copying over
;; jumplists to new windows. Fully independent copies are made only when the
;; jumplist of a window is first modified. This behavior differs from Vim which
;; creates an independent copy whenever the new window is created. In Emacs,
;; windows pop in and out of existence very frequently and there are many cases
;; in which a jump point will never be set in a window so this design decision
;; seems justified. As an example, there does not seem to be a point in copying
;; a jumplist to the *Completions* window whenever it pops up.
;;
;; The object stored in the `evil-jumplist' parameter is a cons cell,
;; (COPY-FLAG . RING), where COPY-FLAG is t if RING must be copied before
;; setting a new jump point in the window or attempting to modify RING in any
;; way. RING stores the jumplist in the form of a ring data structure.
;;
;; Navigating through jumps in RING is implemented through ring rotations, i.e.
;; deletion of the oldest (newest) element of RING and subsequent insertion as
;; the newest (oldest) element. Rotating RING forward (oldest -> newest) jumps
;; to newly set jump points and rotating RING backward (newest -> oldest) jumps
;; to older ones.
;;
;; Instead of keeping track of an index which determines the most recently
;; visited jump point, a sentinel value is placed in RING, as the first element
;; before any jumps are added, and acts to orient the jumps in RING. All jumps
;; with indices less than the index of the sentinel are backward jumps, indices
;; larger than the sentinel are forward jumps. The sentinel value is simply the
;; symbol, `evil'.
;;
;; The sentinel also determines the two states that RING can be in: if a
;; backward jump has been made between calls to `evil-set-jump' or not. If no
;; backward jumps have been made, the oldest element in RING is the sentinel
;; value. Otherwise the oldest element is the most recent backward jump.
;;
;; So for example if RING is
;;
;;     (A B C ... evil)
;;
;; then no backward jumps have been made and A is the most recently set jump.
;; Then after a backward jump to A, RING would look like
;;
;;     (B C ... evil A)
;;
;; After one more backward jump, RING would look like
;;
;;     (C ... evil A B)
;;
;; with `point' at the location specified by B. Making a forward jump to A,
;; RING would become
;;
;;     (B C ... evil A)
;;
;; Since A is the most recently set jump, there are no more forward jumps that
;; can be made and additional attempts to jump forward will leave RING in the
;; same state. Notice that after each forward/backward jump, `point' is left at
;; the location specified by the oldest element of RING. It looks like we have
;; found something pretty close to being an invariant in this representation of
;; a jumplist. After every jumplist operation, the oldest element of RING will
;; be the most recently jumped to location.
;;
;; When a new jump point is set, regardles of which jump point is the most
;; recently visited, RING is reset to the state where the sentinel is the
;; oldest element, so if we set a new jump point at D, RING would be
;;
;;    (D A B C ... evil)

;;; Code:

(defgroup evil-jumps nil
  "Evil jump list configuration options."
  :group 'evil)

(defcustom evil-jumps-ignored-commands '(helm-buffers-list
                                         magit-status
                                         evil-show-jumps)
  "A list of commands that prevent setting the jump point while active.
Normally a jump point will be set before an `evil' command is
executed if it has a non-nil `:jump' property when defined
through `evil-define-command'. But if the command opens a new
window or switches the current buffer during its execution, a
jump point will be set regardless of the value of the `:jump'
property. To disable setting a jump point even in these cases,
add the command to this list.

Note, for commands that are not defined through
`evil-define-command' you can specify that a jump point should be
set when the command is called by setting the `:jump' property of
the commmand to t using `evil-set-command-property'."
  :type '(repeat symbol)
  :group 'evil-jumps)

(defcustom evil-jumps-cross-buffers t
  "When non-nil, jumping can visit locations in other buffers.
Otherwise jumping is restricted to jump points available for the
current buffer."
  :type 'boolean
  :group 'evil-jumps)

(defcustom evil-jumps-max-length 100
  "The maximum number of jumps to keep track of."
  :type 'integer
  :group 'evil-jumps)

(defcustom evil-jumps-pre-jump-hook nil
  "Hook to run just before jumping to a location in the jump list."
  :type 'hook
  :group 'evil-jumps)

(defcustom evil-jumps-post-jump-hook nil
  "Hook to run just after jumping to a location in the jump list."
  :type 'hook
  :group 'evil-jumps)

(defcustom evil-jumps-ignored-file-patterns '("COMMIT_EDITMSG$" "TAGS$")
  "When `buffer-file-name' matches one of these patterns, jump are inhibited."
  :type '(repeat string)
  :group 'evil-jumps)

(defcustom evil-jumps-allowed-buffer-patterns '("\\*new\\*" "\\*scratch\\*")
  "When `buffer-name' matches one of these patterns, jumps are allowed.
These patterns are only checked when the `current-buffer' has no
`buffer-file-name'."
  :type '(repeat string)
  :group 'evil-jumps)

(defvar savehist-additional-variables)

(defvar evil-jump-history nil
  "History of `evil-mode' jumps that are persisted with `savehist'.")

(defvar evil-jumping-p nil
  "Dynamically bound to a non-nil value during a jump.")

(defvar evil-global-jump-id 0
  "The number of jump markers created so far.")

;; Save the jumplist when saving the window configuration.
(add-to-list 'window-persistent-parameters '(evil-jumplist . t))

;;; Iterating over jumps

(defmacro evil-loop-over-jumps (spec &rest body)
  "Loop over the JUMP's of JUMPLIST.
For each iteration: bind a jump marker to JUMP, set FORWARDP to t
if JUMP is a forward jump otherwise set it to nil, evaluate BODY.
If BODY evaluates to a non-nil value keep JUMP in JUMPLIST,
otherwise remove JUMP from JUMPLIST.

If FILTER is non-nil it is a function that takes a single
argument, a jump marker. Only iterate over the jumps that cause
FILTER to return non-nil. The jumps that do not pass FILTER are
skipped over and are left in the jumplist unchanged.

\(fn (JUMPLIST JUMP &optional FORWARDP FILTER) BODY...)"
  (declare (indent defun)
           (debug (([&or form symbolp] symbolp &optional symbolp form) body)))
  (let* ((jumplist (pop spec))
         (jump (pop spec))
         (ring (make-symbol "ringvar"))
         (head (make-symbol "headvar"))
         (fun (make-symbol "funvar"))
         (forwardp (or (pop spec) (make-symbol "forwardpvar")))
         (filter-fun (make-symbol "filter-funvar"))
         (pred `(or (not (funcall ,filter-fun ,jump))
                    (funcall ,fun))))
    `(unless (or (null (cdr ,jumplist)) (ring-empty-p (cdr ,jumplist)))
       (let* ((,ring (cdr ,jumplist))
              (,head (ring-remove ,ring 0))
              (,jump ,head)
              (,forwardp nil)
              (,filter-fun #',(or (pop spec) 'identity))
              (,fun (lambda ()
                      (with-demoted-errors "Error in `evil-loop-over-jumps': %S"
                        ,@body))))
         ;; Find the first jump that is used to determine when to stop
         ;; iterating
         (while (not (or (eq ,jump 'evil) ,pred))
           (setq ,head (ring-remove ,ring 0)
                 ,jump ,head))
         (ring-insert-at-beginning ,ring ,head)
         (setq ,forwardp (eq ,head 'evil))
         (while (not (eq (ring-ref ,ring 0) ,head))
           (setq ,jump (ring-remove ,ring 0))
           (if (not (eq ,jump 'evil))
               (when ,pred
                 (ring-insert-at-beginning ,ring ,jump))
             (setq ,forwardp t)
             (ring-insert-at-beginning ,ring ,jump)))))))

;;; Jump markers

;; NOTE: The optional parameter is only used when loading the jump history from
;; file, it shouldn't be used otherwise.
(defun evil-jump-marker (&optional jump)
  "Return a new jump marker.
A jump marker is a cons cell

     (ID . MARKER) or (ID POS . PATH)

depending on if there is a buffer visiting the jump or not. ID is
the jump ID, MARKER is the marker pointing to the jump if there
is a buffer visiting the jump, POS is an integer and PATH is the
file name or buffer name for buffer targets.

If JUMP is nil, make a new jump marker using `point-marker'.
Otherwise use JUMP."
  (setq jump (pcase jump
               ('nil (point-marker))
               ((pred markerp) jump)
               (`(,(pred integerp) . ,(pred stringp)) jump)
               (_ (error "Invalid jump marker (%s)" jump))))
  (cons (cl-incf evil-global-jump-id) jump))

(defun evil-jump-marker-id (marker)
  "Return the ID of a jump MARKER.
The jump ID serves as a way to order the jumps when merging
jumplists of two windows."
  (car-safe marker))

(defun evil-jump-marker-position (marker)
  "Return the position of a jump MARKER."
  (if (markerp (cdr-safe marker))
      (marker-position (cdr marker))
    (car-safe (cdr-safe marker))))

(defun evil-jump-marker-target (marker)
  "Return the file or buffer name of a jump MARKER."
  (if (markerp (cdr-safe marker))
      (let ((buffer (marker-buffer (cdr marker))))
        (or (buffer-file-name buffer)
            (buffer-name buffer)))
    (cdr-safe (cdr-safe marker))))

(defun evil-jump-target-p (item)
  "Return non-nil if ITEM is a valid jump target.
If ITEM is a buffer with no file name then its `buffer-name' must
match `evil-jumps-allowed-buffer-patterns' to be a valid jump
target. If ITEM does have a file name, then the file name must
not match one of `evil-jumps-ignored-file-patterns' and must
point to an existing file. In the case that the file points to a
remote file, the file existence check is not performed."
  (let* ((buffer (or (and (stringp item) (get-buffer item))
                     (and (bufferp item) item)))
         (path (or (and buffer (buffer-file-name
                                (or (buffer-base-buffer buffer) buffer)))
                   (and (stringp item) item))))
    (if path (and (not (cl-loop
                        for pattern in evil-jumps-ignored-file-patterns
                        thereis (string-match-p pattern path)))
                  (or (file-remote-p path)
                      (file-exists-p path)))
      (when buffer
        (cl-loop
         for pattern in evil-jumps-allowed-buffer-patterns
         thereis (string-match-p pattern (buffer-name buffer)))))))

(defun evil-jump-marker-p (marker)
  "Return non-nil if MARKER is a jump marker.
A jump marker is a cons cell

     (ID . MARKER) or (ID POS . PATH)

depending on if there is a buffer visiting the jump or not."
  (pcase marker
    (`(,(pred integerp) . ,(and (pred markerp) jump))
     (evil-jump-target-p (marker-buffer jump)))
    (`(,(pred integerp) ,(pred integerp) . ,(and (pred stringp) path))
     (evil-jump-target-p path))))

(defun evil-swap-out-jump-markers (&optional make-markers frame-or-window)
  "Convert jump markers to (POS . PATH) pairs.
Markers are converted only if the `current-buffer' is visiting a
file and the current jump list has jumps in the `current-buffer'.
If MAKE-MARKERS is non-nil, then convert

    (POS . PATH)

pairs to markers instead. If FRAME-OR-WINDOW is non-nil, then
swap out markers for FRAME-OR-WINDOW's jumplist, default to the
`selected-window' if FRAME-OR-WINDOW is nil"
  (or frame-or-window (setq frame-or-window (selected-window)))
  ;; Can't swap out markers of buffer targets, i.e. buffers with a nil
  ;; `buffer-file-name' so ignore them.
  (when (and buffer-file-name (evil-jump-target-p (current-buffer)))
    (evil-maybe-copy-jumplist (evil-get-jumplist frame-or-window))
    (evil-loop-over-jumps ((evil-get-jumplist frame-or-window) jump nil
                           (lambda (jump)
                             (string= (evil-jump-marker-target jump)
                                      buffer-file-name)))
      (let ((position (evil-jump-marker-position jump)))
        (if make-markers
            (or (markerp (cdr jump))
                (setcdr jump (set-marker (make-marker) position)))
          (or (not (markerp (cdr jump)))
              (progn
                (set-marker (cdr jump) nil)
                (setcdr jump (cons position buffer-file-name)))))))))

(defun evil-swap-out-all-jump-markers (&optional make-markers)
  "Swap out jump markers of the `current-buffer' for all windows in all frames.
Call `evil-swap-out-jump-markers' on every window in every frame
for the `current-buffer'. MAKE-MARKERS has the same meaning as in
`evil-swap-out-jump-markers'."
  (dolist (frame (frame-list))
    (evil-swap-out-jump-markers make-markers frame)
    (dolist (window (window-list frame))
      (evil-swap-out-jump-markers make-markers window))))

(put 'evil-swap-out-all-jump-markers 'permanent-local-hook t)

;;; Rotating the jumplist

(defun evil--rotate-jumps-forward (ring)
  "Make the oldest element of RING the newest.
Only rotate when the first or second oldest element is not the
sentinel value."
  ;; Note that we use the second oldest element to distinguish between a ring
  ;; in which at least one backward rotation has been performed and one in
  ;; which no backward rotations have been performed.
  (unless (or (eq (ring-ref ring -2) 'evil)
              (eq (ring-ref ring -1) 'evil))
    (ring-insert ring (ring-remove ring -1))))

(defun evil--rotate-jumps-backward (ring)
  "Make the newest element of RING the oldest.
Only rotate when the newest element is not the sentinel value."
  (unless (eq (ring-ref ring 0) 'evil)
    (ring-insert-at-beginning ring (ring-remove ring 0))))

(defun evil-rotate-jumplist (pred jumplist dir)
  "Call PRED on jumps in JUMPLIST while rotating in DIR.
JUMPLIST is rotated in DIR and PRED is called on the oldest
element of JUMPLIST. If PRED returns a non-nil value, stop
rotating and return the element that caused PRED to return
non-nil. If all possible rotations in DIR were made without PRED
ever returning a non-nil value, rotate JUMPLIST back to the state
it was in before the call to this function and return nil.

DIR is either `forward' or `backward' indicating that rotations
should be in the forward or backward direction."
  (unless (memq dir '(forward backward))
    (error "Rotation direction can only be `forward' or `backward'"))
  (evil-maybe-copy-jumplist jumplist)
  (catch 'done
    (let* ((ring (cdr jumplist))
           (oldest (ring-ref ring -1)))
      (while (if (eq dir 'backward)
                 (evil--rotate-jumps-backward ring)
               (evil--rotate-jumps-forward ring))
        ;; Regardless of the rotating direction, the oldest element is always
        ;; the jump that should be performed.
        (let ((jump (ring-ref ring -1)))
          (when (funcall pred jump)
            (throw 'done jump))))
      ;; Restore the jumplist when PRED does not return a non-nil value and we
      ;; have rotated as far as we can
      (while (not (eq (ring-ref ring -1) oldest))
        (if (eq dir 'backward)
            (evil--rotate-jumps-forward ring)
          (evil--rotate-jumps-backward ring))))))

(defun evil-revert-backward-jumps (jumplist)
  "Restore JUMPLIST to a state as if no backward jumps had been performed."
  (when (evil-forward-jumps-p jumplist)
    (evil-maybe-copy-jumplist jumplist)
    (let ((ring (cdr jumplist)))
      (while (evil--rotate-jumps-forward ring))
      (ring-insert ring (ring-remove ring -1)))))

;;; Accessing the jumplist

(defun evil-jumplist-p (thing)
  "Return non-nil if THING is a jumplist."
  (and (consp thing)
       (booleanp (car thing))
       (ring-p (cdr thing))
       (ring-member (cdr thing) 'evil)))

(defun evil-forward-jumps-p (jumplist)
  "Return non-nil if JUMPLIST has forward jumps."
  (not (eq (ring-ref (cdr jumplist) -1) 'evil)))

(defun evil-current-jumps (&optional frame-or-window)
  "Return a list of all jumps on FRAME-OR-WINDOW's jumplist.
WINDOW defaults to the `selected-window'.

The returned list has the following form

    (FORWARD-JUMPS BACKWARD-JUMPS)

where FORWARD-JUMPS and BACKWARD-JUMPS are each a list of jumps
containing the jumps that can be navigated to in the forward or
backward direction, respectively.

The elements in each list are ordered so that

    (append FORWARD-JUMPS BACKWARD-JUMPS)

gives the jumps in order from newest to oldest. Note,
FORWARD-JUMPS is nil if no backward jumps have been made yet,
i.e. if no forward jumps can be performed.

As a special case, if FRAME-OR-WINDOW is a jumplist return its
jumps."
  (let ((jumplist (if (evil-jumplist-p frame-or-window)
                      frame-or-window
                    (evil-get-jumplist frame-or-window))))
    (let (forward-jumps backward-jumps)
      (evil-loop-over-jumps (jumplist jump forwardp)
        (push jump (if forwardp forward-jumps backward-jumps)))
      (list (nreverse forward-jumps) (nreverse backward-jumps)))))

(defun evil-get-jumplist (&optional frame-or-window)
  "Get the jumplist for FRAME-OR-WINDOW.
Return the jumplist stored in the `evil-jumplist' frame/window
parameter of FRAME-OR-WINDOW.

The returned jumplist is a cons cell (COPY-FLAG . RING) where
COPY-FLAG is a flag variable determining if RING should be copied
before attempting to modify RING. RING is the ring data structure
holding the jump points for FRAME-OR-WINDOW.

If FRAME-OR-WINDOW is a frame that does not have a jumplist,
return nil. Note that a frame's jumplist is updated only through
a call to `evil-merge-jumps-into-frame'.

If FRAME-OR-WINDOW is a window that does not have a jumplist and
if the `selected-frame's jumplist is non-nil, set the window's
jumplist as a copy of the `selected-frame's jumplist and return
the copied jumplist. Otherwise make a new empty jumplist for the
window and return it."
  (or frame-or-window (setq frame-or-window (selected-window)))
  (let ((jumplist (cond
                   ((framep frame-or-window)
                    (frame-parameter frame-or-window 'evil-jumplist))
                   ((windowp frame-or-window)
                    (window-parameter frame-or-window 'evil-jumplist)))))
    (or jumplist
        (cond
         ((windowp frame-or-window)
          (setq jumplist (cdr-safe (evil-get-jumplist
                                    (window-frame frame-or-window))))
          (set-window-parameter
           frame-or-window 'evil-jumplist
           (if jumplist (cons t jumplist)
             (cons nil (let ((ring (make-ring (1+ evil-jumps-max-length))))
                         (prog1 ring
                           (ring-insert ring 'evil)))))))
         ;; See `evil-merge-jumps-into-frame'
         ((framep frame-or-window) nil)
         (t (signal 'wrong-type-argument '(or framep windowp)))))))

;;; Removing jumps from the jumplist

(defun evil-remove-jump (jumplist jump)
  "In JUMPLIST, remove all occurances of JUMP.
Disregard the ID of jump markers when comparing. Two jump markers
are considered equivalent if they are `equal' or, in the case
they are both markers, are jump points on the same line in the
same buffer."
  (evil-maybe-copy-jumplist jumplist)
  (setq jump (cdr jump))
  (let (beg end)
    (when (markerp jump)
      (with-current-buffer (marker-buffer jump)
        (save-excursion
          (goto-char jump)
          (setq beg (line-beginning-position)
                end (line-end-position)))))
    (evil-loop-over-jumps (jumplist rjump)
      (let ((rjump (cdr rjump)))
        (not (or (equal jump rjump)
                 ;; VIM considers jumps on the same line as equivalent
                 (and (markerp jump) (markerp rjump)
                      (eq (marker-buffer jump) (marker-buffer rjump))
                      (<= beg rjump end))))))))

(defun evil-remove-invalid-jumps (jumplist)
  "Remove any invalid jumps from the JUMPLIST.
A jump is invalid if it doesn't pass `evil-jump-marker-p'. Also
remove jumps that are considered equivalent, see
`evil-remove-jump'."
  (evil-maybe-copy-jumplist jumplist)
  (evil-loop-over-jumps (jumplist jump)
    (and (evil-jump-marker-p jump)
         (prog1 t (evil-remove-jump jumplist jump)))))

;;; Pushing jumps

;; NOTE: The jump markers removed from one jumplist may be present on another
;; jump list so we cannot nil out the marker here.
(defun evil-push-jump (jumplist jump)
  "In JUMPLIST, remove occurences of JUMP and then insert it."
  (evil-remove-jump jumplist jump)
  (let ((ring (cdr jumplist)))
    (when (= (ring-length ring) (ring-size ring))
      ;; Always remove the oldest jump
      (ring-remove ring (1- (ring-member ring 'evil))))
    (ring-insert ring jump)))

;;; Copying the jumplist

(defun evil-maybe-copy-jumplist (jumplist)
  "Copy the ring of JUMPLIST, if necessary.
A copy is necessary when the copy flag of JUMPLIST is t."
  (when (car jumplist)
    (setcar jumplist nil)
    (setcdr jumplist (ring-copy (cdr jumplist)))))

;;; Jumping

(defun evil--do-jump (jump)
  "Set the `current-buffer' and `point' depending on JUMP."
  (let ((evil-jumping-p t)
        (do-jump
         (lambda (set-buf target position)
           (run-hooks 'evil-jumps-pre-jump-hook)
           (funcall set-buf target)
           (goto-char position)
           (run-hooks 'evil-jumps-post-jump-hook))))
    (pcase jump
      (`(,_ . ,(and (pred markerp) marker))
       (funcall do-jump #'switch-to-buffer (marker-buffer marker)
                (marker-position marker)))
      (`(,_ ,(and (pred integerp) position) . ,(and (pred stringp) target))
       (funcall do-jump #'find-file target position)
       (evil-swap-out-all-jump-markers 'make-markers))
      (`,elem (error "Invalid jump in jumplist (%s)" elem)))))

(defun evil--jump (dir count)
  "Jump in DIR COUNT times."
  (or count (setq count 1))
  (let ((jumplist (evil-get-jumplist)))
    (evil-remove-invalid-jumps jumplist)
    (evil-motion-loop (nil count)
      (let* ((pred (if evil-jumps-cross-buffers #'evil-jump-marker-p
                     (apply-partially
                      (lambda (target jump)
                        (and (evil-jump-marker-p jump)
                             (string= (evil-jump-marker-target jump) target)))
                      (or (buffer-file-name) (buffer-name)))))
             (jump (evil-rotate-jumplist pred jumplist dir)))
        (when jump
          (evil--do-jump jump))))))

;;; Setting a jump point

(defun evil-set-jump (&optional pos)
  "Set a new jump point at POS.
If POS is nil, it defaults to `point'."
  (unless (or evil-jumping-p
              (memq this-command evil-jumps-ignored-commands)
              (not (evil-jump-target-p (current-buffer))))
    (let ((jumplist (evil-get-jumplist))
          (jump (save-excursion
                  (when pos (goto-char pos))
                  (evil-jump-marker))))
      (unless (or (region-active-p) (evil-visual-state-p))
        (push-mark pos t))
      (evil-revert-backward-jumps jumplist)
      (evil-push-jump jumplist jump))))

(put 'evil-set-jump 'permanent-local-hook t)

(defun evil-set-jump-pre-command (&optional command)
  "Set jump point if COMMAND has a non-nil :jump property."
  (setq command (or command this-command))
  (when (evil-get-command-property command :jump)
    (evil-set-jump)))

(put 'evil-set-jump-pre-command 'permanent-local-hook t)

;;; Showing jumps

(evil-define-command evil-show-jumps ()
  "Display the jump list."
  :repeat nil
  (evil-remove-invalid-jumps (evil-get-jumplist))
  (let* ((index 1)
         (jumps (cl-destructuring-bind (forward-jumps backward-jumps)
                    (evil-current-jumps)
                  (when forward-jumps
                    (setq index (1+ (- (length forward-jumps)))))
                  (nconc forward-jumps backward-jumps)))
         entries)
    ;; Special case which makes the jump list look like:
    ;;
    ;; Jump  Marker  File/text
    ;;  ...    ...     ...
    ;;    1   2345    foo bar
    ;; >
    ;;
    ;; The last line has the '>' character and the next line up
    ;; corresponds to the first backward jump that can be made.
    ;;
    ;; When some backward jumps have been made, the jump list
    ;; will look like
    ;;
    ;; Jump  Marker  File/text
    ;;  ...    ...     ...
    ;;    1   2345    foo bar
    ;; >  0   2982    baz bar
    ;;    1   2102    qux bar
    ;;  ...    ...     ...
    ;;
    ;; See http://vimdoc.sourceforge.net/htmldoc/motion.html#jumplist
    (when (= index 1)
      (let* ((jump (evil-jump-marker))
             (file-text (propertize " " 'evil-jump jump)))
        (push `(nil [">   " "" ,file-text ""]) entries)))
    (while (car jumps)
      (push (evil--show-jumps-display-value index (pop jumps)) entries)
      (cl-incf index))
    (when (get-buffer "*evil-jumps*")
      (quit-windows-on "*evil-jumps*"))
    (evil-with-view-list
      :name "evil-jumps"
      :mode "Evil Jump List"
      :format `[("Jump" 5 nil :right-align t)
                ("Marker" 8 nil :right-align t)
                ("File/text" ,(- fill-column (+ 5 8 1)) t)
                ;; Add an empty column to be able to truncate File/text
                ("" 1 t)]
      :entries entries
      :select-action #'evil--show-jumps-select-action)
    (with-current-buffer "*evil-jumps*"
      ;; The File/text column uses the button face which normally is
      ;; underlined, remove the underline since we handle underlining using
      ;; text properties for the column.
      (face-remap-add-relative 'button :underline nil)
      (goto-char (point-max))
      (while (not (search-forward ">" (+ (point) 5) 'noerror))
        (forward-line -1))
      (beginning-of-line))))

(defun evil--show-jumps-select-action (row)
  "Jump to the location corresponding ROW."
  (quit-window 'kill)
  (let* ((jump (get-text-property 0 'evil-jump (elt row 2))))
    (evil--do-jump jump)))

(defun evil--show-jumps-display-value (index jump)
  "Return the row at INDEX using JUMP.
INDEX is negative if JUMP is a forward jump and positive if JUMP
is a backward jump. The most recently jumped to location has
INDEX equal to 0."
  (let* ((current-target (or (buffer-file-name) (buffer-name)))
         (pos (evil-jump-marker-position jump))
         (target (evil-jump-marker-target jump))
         value)
    (setq value
          (cond
           ((string= current-target target)
            (save-excursion
              (goto-char pos)
              (font-lock-ensure (point) (line-end-position))
              (setq value
                    (string-trim-left
                     (buffer-substring (point) (line-end-position)))))
            (if (string-empty-p value) " " value))
           (t (propertize (abbreviate-file-name target) 'face 'underline))))
    (put-text-property 0 1 'evil-jump jump value)
    `(nil [,(concat (if (= index 0) ">  " "")
                    (number-to-string (abs index)))
           ,(number-to-string pos)
           ,value
           ""])))

;;; Saving jumps persistently

(defun evil-load-jump-history ()
  "Load the jump list from `evil-jump-history'."
  (add-to-list 'savehist-additional-variables 'evil-jump-history)
  ;; If loading from history, reset the frame's jumplist as well
  (set-frame-parameter nil 'evil-jumplist nil)
  (set-window-parameter nil 'evil-jumplist nil)
  (let ((jumplist (evil-get-jumplist)))
    (cl-loop
     for jump in (reverse evil-jump-history)
     do (evil-push-jump jumplist (evil-jump-marker jump)))
    (dolist (buf (buffer-list))
      (when (evil-jump-target-p buf)
        (with-current-buffer buf
          (evil-swap-out-all-jump-markers 'make-markers))))
    (add-hook 'savehist-save-hook #'evil-sync-jump-history)
    (remove-hook 'savehist-mode-hook #'evil-load-jump-history)))

(defun evil-sync-jump-history ()
  "Synchronize `evil-jump-history' with the jump list."
  (walk-windows
   (lambda (window)
     (evil-merge-jumps-into-frame window (selected-frame))))
  (evil-remove-invalid-jumps (evil-get-jumplist (selected-frame)))
  (setq evil-jump-history
        (let ((jumps (cl-destructuring-bind (forward-jumps backward-jumps)
                         (evil-current-jumps (selected-frame))
                       (nconc forward-jumps backward-jumps))))
          (delq nil (mapcar (lambda (marker)
                              (let ((position (evil-jump-marker-position marker))
                                    (target (evil-jump-marker-target marker)))
                                (unless (or (not target)
                                            (file-remote-p target)
                                            (not (file-exists-p target)))
                                  (cons position target))))
                            jumps)))))

(if (bound-and-true-p savehist-loaded)
    (evil-load-jump-history)
  (add-hook 'savehist-mode-hook #'evil-load-jump-history))

;;; Integration

(defadvice switch-to-buffer (before evil-jumps activate)
  "Set a new jump point before switching to a new buffer."
  (evil-set-jump))

(defadvice split-window-internal (around evil-jumps activate)
  "Split the window and set the jumplist for the new window.
Set a new jump point in the window being split. The jumplist of
the new window is a shallow copy of the jumplist in the window
being split. Return the newly splitted window."
  (evil-set-jump)
  (let* ((window (ad-get-arg 0))
        (jumplist (when (evil-get-jumplist window)
                    (cons t (cdr (evil-get-jumplist window)))))
        (new-window ad-do-it))
    (prog1 new-window
      (set-window-parameter new-window 'evil-jumplist jumplist))))

(defun evil-merge-jumplists (jl1 jl2)
  "Return a new jumplist consisting of the unique jumps in JL1 and JL2.
The jumps are sorted by their `evil-jump-marker-id', larger IDs
corresponding to newer jump points. The returned jumplist
consists of `evil-jumps-max-length' newest jumps between the
merged jumplists."
  (let ((jumps1 (apply #'nconc (evil-current-jumps jl1)))
        (jumps2 (apply #'nconc (evil-current-jumps jl2)))
        (ring (make-ring (1+ evil-jumps-max-length)))
        (min-id most-positive-fixnum)
        jumps)
    (while (or jumps1 jumps2)
      (let ((id1 (evil-jump-marker-id (car jumps1)))
            (id2 (evil-jump-marker-id (car jumps2)))
            id sym)
        (cond
         ((null id1) (setq id id2 sym 'jumps2))
         ((null id2) (setq id id1 sym 'jumps1))
         (t (if (>= id1 id2) (setq id id1 sym 'jumps1)
              (setq id id2 sym 'jumps2))))
        ;; If the id of a jump is larger or equal to the smallest id in jumps,
        ;; then the jump is already in jumps since for each previous iteration
        ;; the jump with the largest id was added to jumps. So only add a jump
        ;; that has an id smaller than min-id.
        (when (< id min-id)
          (setq min-id id)
          (push (car (symbol-value sym)) jumps))
        (set sym (cdr (symbol-value sym)))))
    (while jumps
      (ring-insert ring (pop jumps)))
    ;; Insert the sentinel value
    (ring-insert-at-beginning ring 'evil)
    (cons t ring)))

(defun evil-merge-jumps-into-frame (window frame)
  "Merge WINDOW's jumplist into FRAME's jumplist.
Perform the merge only when WINDOW's jumplist is not a copy of
another window's jumplist."
  (unless (car (evil-get-jumplist window))
    (set-frame-parameter
     frame 'evil-jumplist
     (if (null (evil-get-jumplist frame))
         (cons t (ring-copy (cdr (evil-get-jumplist window))))
       (evil-merge-jumplists
        (evil-get-jumplist frame) (evil-get-jumplist window))))))

(defadvice delete-window-internal (before evil-jumps activate)
  "Merge jumplists."
  (let ((window (ad-get-arg 0)))
    (evil-merge-jumps-into-frame window (selected-frame))))

(defadvice delete-other-windows (before evil-jumps activate)
  "Merge jumplists."
  (let ((this-window (selected-window)))
    (walk-windows
     (lambda (window)
       (unless (eq window this-window)
         (evil-merge-jumps-into-frame window (selected-frame)))))))

(defun evil-enable-jumps-in-buffer ()
  "Enable jumps if `evil-local-mode' is non-nil.
Otherwise disable jumps."
  (cond
   (evil-local-mode
    (add-hook 'kill-buffer-hook #'evil-swap-out-all-jump-markers nil t)
    (add-hook 'pre-command-hook #'evil-set-jump-pre-command nil t)
    (add-hook 'next-error-hook #'evil-set-jump nil t))
   ((not evil-local-mode)
    (remove-hook 'kill-buffer-hook #'evil-swap-out-all-jump-markers t)
    (remove-hook 'pre-command-hook #'evil-set-jump-pre-command t)
    (remove-hook 'next-error-hook #'evil-set-jump t))))

(defun evil-copy-jumps-to-frame (frame)
  "Copy a previous jumplist to a new FRAME's root window.
The previous jumplist copied is from the most recently selected
window on the previous frame."
  (set-frame-parameter
   frame 'evil-jumplist (evil-get-jumplist
                         (frame-selected-window (previous-frame frame)))))

(add-hook 'evil-local-mode-hook #'evil-enable-jumps-in-buffer)
(add-hook 'after-make-frame-functions #'evil-copy-jumps-to-frame)

(provide 'evil-jumps)

;;; evil-jumps.el ends here
