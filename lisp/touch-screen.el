;;; touch-screen.el --- touch screen support for X and Android  -*- lexical-binding: t; -*-

;; Copyright (C) 2023 Free Software Foundation, Inc.

;; Maintainer: emacs-devel@gnu.org
;; Package: emacs

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file provides code to recognize simple touch screen gestures.
;; It is used on X and Android, where the platform cannot recognize
;; them for us.

;;; Code:

(defvar touch-screen-current-tool nil
  "The touch point currently being tracked, or nil.
If non-nil, this is a list of nine elements: the ID of the touch
point being tracked, the window where the touch began, a cons
containing the last known position of the touch point, relative
to that window, a field used to store data while tracking the
touch point, the initial position of the touchpoint, and another
four fields to used store data while tracking the touch point.
See `touch-screen-handle-point-update' for the meanings of the
fourth element.")

(defvar touch-screen-set-point-commands '(mouse-set-point)
  "List of commands known to set the point.
This is used to determine whether or not to display the on-screen
keyboard after a mouse command is executed in response to a
`touchscreen-end' event.")

(defvar touch-screen-current-timer nil
  "Timer used to track long-presses.
This is always cleared upon any significant state change.")

(defvar touch-screen-translate-prompt nil
  "Prompt given to the touch screen translation function.
If non-nil, the touch screen key event translation machinery
is being called from `read-sequence' or some similar function.")

(defcustom touch-screen-display-keyboard nil
  "If non-nil, always display the on screen keyboard.
A buffer local value means to always display the on screen
keyboard when the buffer is selected."
  :type 'boolean
  :group 'mouse
  :version "30.1")

(defcustom touch-screen-delay 0.7
  "Delay in seconds before Emacs considers a touch to be a long-press."
  :type 'number
  :group 'mouse
  :version "30.1")

(defcustom touch-screen-precision-scroll nil
  "Whether or not to use precision scrolling for touch screens.
See `pixel-scroll-precision-mode' for more details."
  :type 'boolean
  :group 'mouse
  :version "30.1")



;; Touch screen event translation.  The code here translates raw touch
;; screen events into `touchscreen-scroll' events and mouse events in
;; a ``DWIM'' fashion, consulting the keymaps at the position of the
;; mouse event to determine the best course of action, while also
;; recognizing drag-to-select and other gestures.

(defun touch-screen-relative-xy (posn window)
  "Return the coordinates of POSN, a mouse position list.
However, return the coordinates relative to WINDOW.

If (posn-window posn) is the same as window, simply return the
coordinates in POSN.  Otherwise, convert them to the frame, and
then back again.

If WINDOW is the symbol `frame', simply convert the coordinates
to the frame that they belong in."
  (if (or (eq (posn-window posn) window)
          (and (eq window 'frame)
               (framep (posn-window posn))))
      (posn-x-y posn)
    (let ((xy (posn-x-y posn))
          (edges (and (windowp window)
                      (window-inside-pixel-edges window))))
      ;; Make the X and Y positions frame relative.
      (when (windowp (posn-window posn))
        (let ((edges (window-inside-pixel-edges
                      (posn-window posn))))
          (setq xy (cons (+ (car xy) (car edges))
                         (+ (cdr xy) (cadr edges))))))
      (if (eq window 'frame)
          xy
        ;; Make the X and Y positions window relative again.
        (cons (- (car xy) (car edges))
              (- (cdr xy) (cadr edges)))))))

(defun touch-screen-handle-scroll (dx dy)
  "Scroll the display assuming that a touch point has moved by DX and DY.
Perform vertical scrolling by DY, using `pixel-scroll-precision'
if `touch-screen-precision-scroll' is enabled.  Next, perform
horizontal scrolling according to the movement in DX."
  ;; Perform vertical scrolling first.  Do not ding at buffer limits.
  ;; Show a message instead.
  (condition-case nil
      (if touch-screen-precision-scroll
          (progn
            (if (> dy 0)
                (pixel-scroll-precision-scroll-down-page dy)
              (pixel-scroll-precision-scroll-up-page (- dy)))
            ;; Now set `lines-vscrolled' to an value that will result
            ;; in hscroll being disabled if dy looks as if a
            ;; significant amount of scrolling is about to take
            ;; Otherwise, horizontal scrolling may then interfere with
            ;; precision scrolling.
            (when (> (abs dy) 10)
              (setcar (nthcdr 7 touch-screen-current-tool) 10)))
        ;; Start conventional scrolling.  First, determine the
        ;; direction in which the scrolling is taking place.  Load the
        ;; accumulator value.
        (let ((accumulator (or (nth 5 touch-screen-current-tool) 0))
              (window (cadr touch-screen-current-tool))
              (lines-vscrolled (or (nth 7 touch-screen-current-tool) 0)))
          (setq accumulator (+ accumulator dy)) ; Add dy.
          ;; Figure out how much it has scrolled and how much remains
          ;; on the top or bottom of the window.
          (while (catch 'again
                   (let* ((line-height (window-default-line-height window)))
                     (if (and (< accumulator 0)
                              (>= (- accumulator) line-height))
                         (progn
                           (setq accumulator (+ accumulator line-height))
                           (scroll-down 1)
                           (setq lines-vscrolled (1+ lines-vscrolled))
                           (when (not (zerop accumulator))
                             ;; If there is still an outstanding
                             ;; amount to scroll, do this again.
                             (throw 'again t)))
                       (when (and (> accumulator 0)
                                  (>= accumulator line-height))
                         (setq accumulator (- accumulator line-height))
                         (scroll-up 1)
                         (setq lines-vscrolled (1+ lines-vscrolled))
                         (when (not (zerop accumulator))
                           ;; If there is still an outstanding amount
                           ;; to scroll, do this again.
                           (throw 'again t)))))
                   ;; Scrolling is done.  Move the accumulator back to
                   ;; touch-screen-current-tool and break out of the
                   ;; loop.
                   (setcar (nthcdr 5 touch-screen-current-tool) accumulator)
                   (setcar (nthcdr 7 touch-screen-current-tool)
                           lines-vscrolled)
                   nil))))
    (beginning-of-buffer
     (message (error-message-string '(beginning-of-buffer))))
    (end-of-buffer
     (message (error-message-string '(end-of-buffer)))))

  ;; Perform horizontal scrolling by DX, as this does not signal at
  ;; the beginning of the buffer.
  (let ((accumulator (or (nth 6 touch-screen-current-tool) 0))
        (window (cadr touch-screen-current-tool))
        (lines-vscrolled (or (nth 7 touch-screen-current-tool) 0))
        (lines-hscrolled (or (nth 8 touch-screen-current-tool) 0)))
    (setq accumulator (+ accumulator dx)) ; Add dx;
    ;; Figure out how much it has scrolled and how much remains on the
    ;; left or right of the window.  If a line has already been
    ;; vscrolled but no hscrolling has happened, don't hscroll, as
    ;; otherwise it is too easy to hscroll by accident.
    (if (or (> lines-hscrolled 0)
            (< lines-vscrolled 1))
        (while (catch 'again
                 (let* ((column-width (frame-char-width (window-frame window))))
                   (if (and (< accumulator 0)
                            (>= (- accumulator) column-width))
                       (progn
                         (setq accumulator (+ accumulator column-width))
                         (scroll-right 1)
                         (setq lines-hscrolled (1+ lines-hscrolled))
                         (when (not (zerop accumulator))
                           ;; If there is still an outstanding amount to
                           ;; scroll, do this again.
                           (throw 'again t)))
                     (when (and (> accumulator 0)
                                (>= accumulator column-width))
                       (setq accumulator (- accumulator column-width))
                       (scroll-left 1)
                       (setq lines-hscrolled (1+ lines-hscrolled))
                       (when (not (zerop accumulator))
                         ;; If there is still an outstanding amount to
                         ;; scroll, do this again.
                         (throw 'again t)))))
                 ;; Scrolling is done.  Move the accumulator back to
                 ;; touch-screen-current-tool and break out of the loop.
                 (setcar (nthcdr 6 touch-screen-current-tool) accumulator)
                 (setcar (nthcdr 8 touch-screen-current-tool) lines-hscrolled)
                 nil)))))

(defun touch-screen-scroll (event)
  "Scroll the window within EVENT, a `touchscreen-scroll' event.
If `touch-screen-precision-scroll', scroll the window vertically
by the number of pixels specified within that event.  Else,
scroll the window by one line for every
`window-default-line-height' pixels worth of movement.

If EVENT also specifies horizontal motion and no significant
amount of vertical scrolling has taken place, also scroll the
window horizontally in conjunction with the number of pixels in
the event."
  (interactive "e")
  (let ((window (nth 1 event))
        (dx (nth 2 event))
        (dy (nth 3 event)))
    (with-selected-window window
      (touch-screen-handle-scroll dx dy))))

(global-set-key [touchscreen-scroll] #'touch-screen-scroll)

(defun touch-screen-handle-timeout (arg)
  "Start the touch screen timeout or handle it depending on ARG.
When ARG is nil, start the `touch-screen-current-timer' to go off
in `touch-screen-delay' seconds, and call this function with ARG
t.

When ARG is t, beep.  Then, set the fourth element of
touch-screen-current-tool to `held', and the mark to the last
known position of the tool."
  (if (not arg)
      ;; Cancel the touch screen long-press timer, if it is still
      ;; there by any chance.
      (progn
        (when touch-screen-current-timer
          (cancel-timer touch-screen-current-timer))
        (setq touch-screen-current-timer
              (run-at-time touch-screen-delay nil
                           #'touch-screen-handle-timeout
                           t)))
    ;; Beep.
    (beep)
    ;; Set touch-screen-current-timer to nil.
    (setq touch-screen-current-timer nil)
    (when touch-screen-current-tool
      ;; Set the state to `held'.
      (setcar (nthcdr 3 touch-screen-current-tool) 'held)
      ;; Go to the initial position of the touchpoint and activate the
      ;; mark.
      (select-window (cadr touch-screen-current-tool))
      (set-mark (posn-point (nth 4 touch-screen-current-tool)))
      (goto-char (mark))
      (activate-mark))))

(defun touch-screen-handle-point-update (point)
  "Notice that the touch point POINT has changed position.
Perform the editing operations or throw to the input translation
function with an input event tied to any gesture that is
recognized.

POINT must be the touch point currently being tracked as
`touch-screen-current-tool'.

If the fourth element of `touch-screen-current-tool' is nil, then
the touch has just begun.  Determine how much POINT has moved.
If POINT has moved upwards or downwards by a significant amount,
then set the fourth element to `scroll'.  Then, generate a
`touchscreen-scroll' event with the window that POINT was
initially placed upon, and pixel deltas describing how much point
has moved relative to its previous position in the X and Y axes.

If the fourth element of `touchscreen-current-tool' is `scroll',
then generate a `touchscreen-scroll' event with the window that
qPOINT was initially placed upon, and pixel deltas describing how
much point has moved relative to its previous position in the X
and Y axes.

If the fourth element of `touch-screen-current-tool' is
`mouse-drag' and `track-mouse' is non-nil, then generate a
`mouse-movement' event with the position of POINT.

If the fourth element of `touch-screen-current-tool' is `held',
then the touch has been held down for some time.  If motion
happens, cancel `touch-screen-current-timer', and set the field
to `drag'.  Then, activate the mark and start dragging.

If the fourth element of `touch-screen-current-tool' is `drag',
then move point to the position of POINT."
  (let ((window (nth 1 touch-screen-current-tool))
        (what (nth 3 touch-screen-current-tool)))
    (cond ((null what)
           (let* ((posn (cdr point))
                  (last-posn (nth 2 touch-screen-current-tool))
                  ;; Now get the position of X and Y relative to
                  ;; WINDOW.
                  (relative-xy
                   (touch-screen-relative-xy posn window))
                  (diff-x (- (car last-posn) (car relative-xy)))
                  (diff-y (- (cdr last-posn) (cdr relative-xy))))
             ;; Decide whether or not to start scrolling.
             (when (or (> diff-y 10) (> diff-x 10)
                       (< diff-y -10) (< diff-x -10))
               (setcar (nthcdr 3 touch-screen-current-tool)
                       'scroll)
               (setcar (nthcdr 2 touch-screen-current-tool)
                       relative-xy)
               ;; Generate a `touchscreen-scroll' event with `diff-x'
               ;; and `diff-y'.
               (throw 'input-event
                      (list 'touchscreen-scroll
                            window diff-x diff-y))
               ;; Cancel the touch screen long-press timer, if it is
               ;; still there by any chance.
               (when touch-screen-current-timer
                 (cancel-timer touch-screen-current-timer)
                 (setq touch-screen-current-timer nil)))))
          ((eq what 'scroll)
           ;; Cancel the touch screen long-press timer, if it is still
           ;; there by any chance.
           (when touch-screen-current-timer
             (cancel-timer touch-screen-current-timer)
             (setq touch-screen-current-timer nil))
           (let* ((posn (cdr point))
                  (last-posn (nth 2 touch-screen-current-tool))
                  ;; Now get the position of X and Y relative to
                  ;; WINDOW.
                  (relative-xy
                   (touch-screen-relative-xy posn window))
                  (diff-x (- (car last-posn) (car relative-xy)))
                  (diff-y (- (cdr last-posn) (cdr relative-xy))))
             (setcar (nthcdr 3 touch-screen-current-tool)
                     'scroll)
             (setcar (nthcdr 2 touch-screen-current-tool)
                     relative-xy)
             (unless (and (zerop diff-x) (zerop diff-y))
               (throw 'input-event
                      ;; Generate a `touchscreen-scroll' event with
                      ;; `diff-x' and `diff-y'.
                      (list 'touchscreen-scroll
                            window diff-x diff-y)))))
          ((eq what 'mouse-drag)
           ;; There was a `down-mouse-1' event bound at the starting
           ;; point of the event.  Generate a mouse-motion event if
           ;; mouse movement is being tracked.
           (when track-mouse
             (throw 'input-event (list 'mouse-movement
                                       (cdr point)))))
          ((eq what 'held)
           (let* ((posn (cdr point))
                  (relative-xy
                   (touch-screen-relative-xy posn window)))
             (when touch-screen-current-timer
               (cancel-timer touch-screen-current-timer)
               (setq touch-screen-current-timer nil))
             ;; Now start dragging.
             (setcar (nthcdr 3 touch-screen-current-tool)
                     'drag)
             (setcar (nthcdr 2 touch-screen-current-tool)
                     relative-xy)
             (with-selected-window window
               ;; Activate the mark.  It should have been set by the
               ;; time `touch-screen-timeout' was called.
               (activate-mark)
               ;; Figure out what character to go to.  If this posn is
               ;; in the window, go to (posn-point posn).  If not,
               ;; then go to the line before either window start or
               ;; window end.
               (if (and (eq (posn-window posn) window)
                        (posn-point posn))
                   (goto-char (posn-point posn))
                 (let ((relative-xy
                        (touch-screen-relative-xy posn window)))
                   (let ((scroll-conservatively 101))
                     (cond
                      ((< (cdr relative-xy) 0)
                       (ignore-errors
                         (goto-char (1- (window-start))))
                       (redisplay))
                      ((> (cdr relative-xy)
                          (let ((edges (window-inside-pixel-edges)))
                            (- (nth 3 edges) (cadr edges))))
                       (ignore-errors
                         (goto-char (1+ (window-end nil t))))
                       (redisplay)))))))))
          ((eq what 'drag)
           (let* ((posn (cdr point)))
             ;; Keep dragging.
             (with-selected-window window
               ;; Figure out what character to go to.  If this posn is
               ;; in the window, go to (posn-point posn).  If not,
               ;; then go to the line before either window start or
               ;; window end.
               (if (and (eq (posn-window posn) window)
                        (posn-point posn))
                   (goto-char (posn-point posn))
                 (let ((relative-xy
                        (touch-screen-relative-xy posn window)))
                   (let ((scroll-conservatively 101))
                     (cond
                      ((< (cdr relative-xy) 0)
                       (ignore-errors
                         (goto-char (1- (window-start))))
                       (redisplay))
                      ((> (cdr relative-xy)
                          (let ((edges (window-inside-pixel-edges)))
                            (- (nth 3 edges) (cadr edges))))
                       (ignore-errors
                         (goto-char (1+ (window-end nil t))))
                       (redisplay))))))))))))

(defun touch-screen-window-selection-changed (frame)
  "Notice that FRAME's selected window has changed.
If point is now on read only text, hide the on screen keyboard.
Otherwise, cancel any timer that is supposed to hide the keyboard
in response to the minibuffer being closed."
  (with-selected-frame frame
    (if (and (or buffer-read-only
                 (get-text-property (point) 'read-only))
             ;; Don't hide the on-screen keyboard if it's always
             ;; supposed to be displayed.
             (not touch-screen-display-keyboard))
        (frame-toggle-on-screen-keyboard (selected-frame) t)
      ;; Prevent hiding the minibuffer from hiding the on screen
      ;; keyboard.
      (when minibuffer-on-screen-keyboard-timer
        (cancel-timer minibuffer-on-screen-keyboard-timer)
        (setq minibuffer-on-screen-keyboard-timer nil)))))

(defun touch-screen-handle-point-up (point prefix)
  "Notice that POINT has been removed from the screen.
POINT should be the point currently tracked as
`touch-screen-current-tool'.
PREFIX should be a virtual function key used to look up key
bindings.

If the fourth element of `touch-screen-current-tool' is nil, move
point to the position of POINT, selecting the window under POINT
as well, and deactivate the mark; if there is a button or link at
POINT, call the command bound to `mouse-2' there.  Otherwise,
call the command bound to `mouse-1'.

If the fourth element of `touch-screen-current-tool' is
`mouse-drag', then generate either a `mouse-1' or a
`drag-mouse-1' event depending on how far the position of POINT
is from the starting point of the touch.

If the command being executed is listed in
`touch-screen-set-point-commands' also display the on-screen
keyboard if the current buffer and the character at the new point
is not read-only."
  (let ((what (nth 3 touch-screen-current-tool))
        (posn (cdr point)) window point)
    (cond ((null what)
           (when (windowp (posn-window posn))
             (setq point (posn-point point)
                   window (posn-window posn))
             ;; Select the window that was tapped.
             (select-window window)
             ;; Now simulate a mouse click there.  If there is a link
             ;; or a button, use mouse-2 to push it.
             (let* ((event (list (if (or (mouse-on-link-p posn)
                                         (and point (button-at point)))
                                     'mouse-2
                                   'mouse-1)
                                 posn))
                    ;; Look for the command bound to this event.
                    (command (key-binding (if prefix
                                                 (vector prefix
                                                         (car event))
                                            (vector (car event)))
                                          t nil posn)))
               (deactivate-mark)
               (when point
                 ;; This is necessary for following links.
                 (goto-char point))
               ;; Figure out if the on screen keyboard needs to be
               ;; displayed.
               (when command
                 (if (memq command touch-screen-set-point-commands)
                     (if touch-screen-translate-prompt
                         ;; When a `mouse-set-point' command is
                         ;; encountered and
                         ;; `touch-screen-handle-touch' is being
                         ;; called from the keyboard command loop,
                         ;; call it immediately so that point is set
                         ;; prior to the on screen keyboard being
                         ;; displayed.
                         (call-interactively command nil
                                             (vector event))
                       (if (and (or (not buffer-read-only)
                                    touch-screen-display-keyboard)
                                ;; Detect the splash screen and avoid
                                ;; displaying the on screen keyboard
                                ;; there.
                                (not (equal (buffer-name) "*GNU Emacs*")))
                           ;; Once the on-screen keyboard has been
                           ;; opened, add
                           ;; `touch-screen-window-selection-changed'
                           ;; as a window selection change function
                           ;; This allows the on screen keyboard to be
                           ;; hidden if the selected window's point
                           ;; becomes read only at some point in the
                           ;; future.
                           (progn
                             (add-hook 'window-selection-change-functions
                                       #'touch-screen-window-selection-changed)
                             (frame-toggle-on-screen-keyboard (selected-frame)
                                                              nil))
                         ;; Otherwise, hide the on screen keyboard
                         ;; now.
                         (frame-toggle-on-screen-keyboard (selected-frame) t))
                       ;; But if it's being called from `describe-key'
                       ;; or some such, return it as a key sequence.
                       (throw 'input-event event)))
                 ;; If not, return the event.
                 (throw 'input-event event)))))
          ((eq what 'mouse-drag)
           ;; Generate a corresponding `mouse-1' event.
           (let* ((new-window (posn-window posn))
                  (new-point (posn-point posn))
                  (old-posn (nth 4 touch-screen-current-tool))
                  (old-window (posn-window posn))
                  (old-point (posn-point posn)))
             (throw 'input-event
                    ;; If the position of the touch point hasn't
                    ;; changed, or it doesn't start or end on a
                    ;; window...
                    (if (and (eq new-window old-window)
                             (eq new-point old-point)
                             (windowp new-window)
                             (windowp old-window))
                        ;; ... generate a mouse-1 event...
                        (list 'mouse-1 posn)
                      ;; ... otherwise, generate a drag-mouse-1 event.
                      (list 'drag-mouse-1 (cons old-window
                                                old-posn)
                            (cons new-window posn)))))))))

(defun touch-screen-handle-touch (event prefix &optional interactive)
  "Handle a single touch EVENT, and perform associated actions.
EVENT can either be a `touchscreen-begin', `touchscreen-update' or
`touchscreen-end' event.
PREFIX is either nil, or a symbol specifying a virtual function
key to apply to EVENT.

If INTERACTIVE, execute the command associated with any event
generated instead of throwing `input-event'.  Otherwise, throw
`input-event' with a single input event if that event should take
the place of EVENT within the key sequence being translated, or
`nil' if all tools have been released."
  (interactive "e\ni\np")
  (if interactive
      ;; Called interactively (probably from wid-edit.el.)
      ;; Add any event generated to `unread-command-events'.
      (let ((event (catch 'input-event
                     (touch-screen-handle-touch event prefix) nil)))
        (when event
          (setq unread-command-events
                (nconc unread-command-events
                       (list event)))))
    (cond
     ((eq (car event) 'touchscreen-begin)
      ;; A tool was just pressed against the screen.  Figure out the
      ;; window where it is and make it the tool being tracked on the
      ;; window.
      (let* ((touchpoint (caadr event))
             (position (cdadr event))
             (window (posn-window position))
             (point (posn-point position)))
        ;; Cancel the touch screen timer, if it is still there by any
        ;; chance.
        (when touch-screen-current-timer
          (cancel-timer touch-screen-current-timer)
          (setq touch-screen-current-timer nil))
        ;; Replace any previously ongoing gesture.  If POSITION has no
        ;; window or position, make it nil instead.
        (setq touch-screen-current-tool (and (windowp window)
                                             (list touchpoint window
                                                   (posn-x-y position)
                                                   nil position
                                                   nil nil nil nil)))
        ;; Determine if there is a command bound to `down-mouse-1' at
        ;; the position of the tap and that command is not a command
        ;; whose functionality is replaced by the long-press mechanism.
        ;; If so, set the fourth element of `touch-screen-current-tool'
        ;; to `mouse-drag' and generate an emulated `mouse-1' event.
        (if (and touch-screen-current-tool
                 (with-selected-window window
                   (let ((binding (key-binding (if prefix
                                                   (vector prefix
                                                           'down-mouse-1)
                                                 [down-mouse-1])
                                               t nil position)))
                     (and binding
                          (not (and (symbolp binding)
                                    (get binding 'ignored-mouse-command)))))))
            (progn (setcar (nthcdr 3 touch-screen-current-tool)
                           'mouse-drag)
                   (throw 'input-event (list 'down-mouse-1 position)))
          (and point
               ;; Start the long-press timer.
               (touch-screen-handle-timeout nil)))))
     ((eq (car event) 'touchscreen-update)
      ;; The positions of tools currently pressed against the screen
      ;; have changed.  If there is a tool being tracked as part of a
      ;; gesture, look it up in the list of tools.
      (let ((new-point (assq (car touch-screen-current-tool)
                             (cadr event))))
        (when new-point
          (touch-screen-handle-point-update new-point))))
     ((eq (car event) 'touchscreen-end)
      ;; A tool has been removed from the screen.  If it is the tool
      ;; currently being tracked, clear `touch-screen-current-tool'.
      (when (eq (caadr event) (car touch-screen-current-tool))
        ;; Cancel the touch screen long-press timer, if it is still there
        ;; by any chance.
        (when touch-screen-current-timer
          (cancel-timer touch-screen-current-timer)
          (setq touch-screen-current-timer nil))
        (unwind-protect
            (touch-screen-handle-point-up (cadr event) prefix)
          ;; Make sure the tool list is cleared even if
          ;; `touch-screen-handle-point-up' throws.
          (setq touch-screen-current-tool nil)))
      ;; Throw to the key translation function.
      (throw 'input-event nil)))))

;; Mark `mouse-drag-region' as ignored for the purposes of mouse click
;; emulation.

(put 'mouse-drag-region 'ignored-mouse-command t)

(defun touch-screen-translate-touch (prompt)
  "Translate touch screen events into a sequence of mouse events.
PROMPT is the prompt string given to `read-key-sequence', or nil
if this function is being called from the keyboard command loop.
Value is a new key sequence.

Read the touch screen event within `current-key-remap-sequence'
and give it to `touch-screen-handle-touch'.  Return any key
sequence signaled.

If `touch-screen-handle-touch' does not signal for an event to be
returned after the last element of the key sequence is read,
continue reading touch screen events until
`touch-screen-handle-touch' signals.  Return a sequence
consisting of the first event encountered that is not a touch
screen event.

In addition to non-touchscreen events read, key sequences
returned may contain any one of the following events:

  (touchscreen-scroll WINDOW DX DY)

where WINDOW specifies a window to scroll, and DX and DY are
integers describing how many pixels to be scrolled horizontally
and vertically.

  (down-mouse-1 POSN)
  (drag-mouse-1 POSN)

where POSN is the position of the mouse button press or click.

  (mouse-1 POSN)
  (mouse-2 POSN)

where POSN is the position of the mouse click, either `mouse-2'
if POSN is on a link or a button, or `mouse-1' otherwise."
  (if (> (length current-key-remap-sequence) 0)
      ;; Save the virtual function key if this is a mode line event.
      (let* ((prefix (and (> (length current-key-remap-sequence) 1)
                          (aref current-key-remap-sequence 0)))
             (touch-screen-translate-prompt prompt)
             (event (catch 'input-event
                      ;; First, process the one event already within
                      ;; `current-key-remap-sequence'.
                      (touch-screen-handle-touch
                       (aref current-key-remap-sequence
                             (if prefix 1 0))
                       prefix)
                      ;; Next, continue reading input events.
                      (while t
                        (let ((event1 (read-event)))
                          ;; If event1 is a virtual function key, make
                          ;; it the new prefix.
                          (if (memq event1 '(mode-line tab-line
                                             header-line tool-bar tab-bar
                                             left-fringe right-fringe
                                             left-margin right-margin
                                             right-divider bottom-divider))
                              (setq prefix event1)
                            ;; If event1 is not a touch screen event, return
                            ;; it.
                            (if (not (memq (car-safe event1)
                                           '(touchscreen-begin
                                             touchscreen-end
                                             touchscreen-update)))
                                (throw 'input-event event1)
                              ;; Process this event as well.
                              (touch-screen-handle-touch event1 prefix))))))))
        ;; Return a key sequence consisting of event
        ;; or an empty vector if it is nil, meaning that
        ;; no key events have been translated.
        (if event (or (and prefix (consp event)
                           ;; If this is a mode line event, then generate
                           ;; the appropriate function key.
                           (vector prefix event))
                      (vector event))
          ""))))

(define-key function-key-map [touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [mode-line touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [mode-line touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [mode-line touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [header-line touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [header-line touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [header-line touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [bottom-divider touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [bottom-divider touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [bottom-divider touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [right-divider touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-divider touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-divider touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [right-divider touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-divider touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-divider touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [left-fringe touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [left-fringe touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [left-fringe touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [right-fringe touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-fringe touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-fringe touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [left-margin touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [left-margin touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [left-margin touchscreen-end]
            #'touch-screen-translate-touch)

(define-key function-key-map [right-margin touchscreen-begin]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-margin touchscreen-update]
            #'touch-screen-translate-touch)
(define-key function-key-map [right-margin touchscreen-end]
            #'touch-screen-translate-touch)


;; Exports.  These functions are intended for use externally.

(defun touch-screen-track-tap (event &optional update data)
  "Track a single tap starting from EVENT.
EVENT should be a `touchscreen-begin' event.

Read touch screen events until a `touchscreen-end' event is
received with the same ID as in EVENT.  If UPDATE is non-nil and
a `touchscreen-update' event is received in the mean time and
contains a touch point with the same ID as in EVENT, call UPDATE
with that event and DATA.

Return nil immediately if any other kind of event is received;
otherwise, return t once the `touchscreen-end' event arrives."
  (let ((disable-inhibit-text-conversion t))
    (catch 'finish
      (while t
        (let ((new-event (read-event nil)))
          (cond
           ((eq (car-safe new-event) 'touchscreen-update)
            (when (and update (assq (caadr event) (cadr new-event)))
              (funcall update new-event data)))
           ((eq (car-safe new-event) 'touchscreen-end)
            (throw 'finish
                   ;; Now determine whether or not the `touchscreen-end'
                   ;; event has the same ID as EVENT.  If it doesn't,
                   ;; then this is another touch, so return nil.
                   (eq (caadr event) (caadr new-event))))
           (t (throw 'finish nil))))))))

(defun touch-screen-track-drag (event update &optional data)
  "Track a single drag starting from EVENT.
EVENT should be a `touchscreen-begin' event.

Read touch screen events until a `touchscreen-end' event is
received with the same ID as in EVENT.  For each
`touchscreen-update' event received in the mean time containing a
touch point with the same ID as in EVENT, call UPDATE with the
touch point in event and DATA, once the touch point has moved
significantly by at least 5 pixels from where it was in EVENT.

Return nil immediately if any other kind of event is received;
otherwise, return either t or `no-drag' once the
`touchscreen-end' event arrives; return `no-drag' returned if the
touch point in EVENT did not move significantly, and t otherwise."
  (let ((return-value 'no-drag)
        (start-xy (touch-screen-relative-xy (cdadr event)
                                            'frame))
        (disable-inhibit-text-conversion t))
    (catch 'finish
      (while t
        (let ((new-event (read-event nil)))
          (cond
           ((eq (car-safe new-event) 'touchscreen-update)
            (when-let* ((tool (assq (caadr event) (nth 1 new-event)))
                        (xy (touch-screen-relative-xy (cdr tool) 'frame)))
              (when (or (> (- (car xy) (car start-xy)) 5)
                        (< (- (car xy) (car start-xy)) -5)
                        (> (- (cdr xy) (cdr start-xy)) 5)
                        (< (- (cdr xy) (cdr start-xy)) -5))
                (setq return-value t))
              (when (and update tool (eq return-value t))
                (funcall update new-event data))))
           ((eq (car-safe new-event) 'touchscreen-end)
            (throw 'finish
                   ;; Now determine whether or not the `touchscreen-end'
                   ;; event has the same ID as EVENT.  If it doesn't,
                   ;; then this is another touch, so return nil.
                   (and (eq (caadr event) (caadr new-event))
                        return-value)))
           (t (throw 'finish nil))))))))



(provide 'touch-screen)

;;; touch-screen ends here
