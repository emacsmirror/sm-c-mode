;;; sm-c-mode.el --- Experimental C major mode based on SMIE  -*- lexical-binding: t; -*-

;; Copyright (C) 2015  Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Version: 0
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; ¡¡Don't use this!!
;;
;; This is an experiment to see concretely where&how SMIE falls down when
;; trying to handle a language like C.
;; So, strictly speaking, this does provide "SMIE-based indentation for C" and
;; might even do it OK for simple cases, but it really doesn't benefit much
;; from SMIE:
;; - it does a lot of its own parsing by hand.
;; - its smie-ruled-function also does a lot of indentation by hand.
;; Hopefully at some point, someone will find a way to extend SMIE such that
;; it can handle C without having to constantly work around SMIE, e.g.
;; it'd be nice to hook the sm-c--while-to-do, sm-c--else-to-if, and sm-c--boi
;; functions into SMIE at some level.

;; FIXME:
;; - M-; mistakes # for a comment in CPP directives!
;; Ha!  As if this was the only/main problem!

;;; Code:

(require 'cl-lib)
(require 'smie)

(defgroup sm-c-mode nil
  "Major mode to edit C code, based on SMIE."
  :group 'programming)

(defcustom sm-c-indent-basic 2
  "Basic step of indentation.
Typically 2 for GNU style and `tab-width' for Linux style."
  :type 'integer)

(defcustom sm-c-indent-braces t
  "If non-nil, braces in if/while/... are indented."
  :type 'boolean)

;;; Handling CPP directives.

(defsubst sm-c--cpp-inside-p (ppss)
  (eq 2 (nth 7 ppss)))

(eval-and-compile
  (defconst sm-c--cpp-regexp "^[ \t]*\\(\\(#\\)[ \t]*\\([a-z]+\\)\\)"))

(defconst sm-c--cpp-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124" st)
    (modify-syntax-entry ?* ". 23b" st)
    (modify-syntax-entry ?\n ">" st)
    st))

(defun sm-c--cpp-goto-end (ppss &optional limit)
  (cl-assert (sm-c--cpp-inside-p ppss))
  (let (found)
    (while
        (and (setq found (re-search-forward "\\(?:\\\\\\\\\\)*\n" limit 'move))
             ;; We could also check (nth 5 ppss) to figure out if we're
             ;; after a backslash, but this is a very common case, so it's good
             ;; to avoid calling parse-partial-sexp for that.
             (or (eq ?\\ (char-before (match-beginning 0)))
                 (with-syntax-table sm-c--cpp-syntax-table
                   (nth 4 (parse-partial-sexp (1+ (nth 8 ppss)) (point)))))))
    found))

(defun sm-c--cpp-fontify-syntactically (ppss)
  ;; FIXME: ¡¡BIG UGLY HACK!!
  ;; Copied from font-lock.el's font-lock-fontify-syntactically-region.
  (cl-assert (> (point) (nth 8 ppss)))
  (save-excursion
    (save-restriction
      (sm-c--cpp-goto-end ppss)
      (narrow-to-region (1+ (nth 8 ppss)) (point))
      ;; FIXME: We should add some "with-local-syntax-ppss" macro to
      ;; encapsulate this.
      (let ((syntax-propertize-function nil)
            (syntax-ppss-cache nil)
            (syntax-ppss-last nil))
        (font-lock-fontify-syntactically-region (point-min) (point-max))))))

(defun sm-c--cpp-syntax-propertize (end)
  (let ((ppss (syntax-ppss))
        found)
    (when (sm-c--cpp-inside-p ppss)
      (while
          (and (setq found (re-search-forward "\\(\\\\\\\\\\)*\n" end 'move))
               (or (eq ?\\ (char-before (match-beginning 0)))
                   (with-syntax-table sm-c--cpp-syntax-table
                     (nth 4 (parse-partial-sexp (1+ (nth 8 ppss)) (point)))))))
      (when found
        (put-text-property (1- (point)) (point)
                           'syntax-table (string-to-syntax "> c"))))))

;;;; Indenting CPP directives.

(defcustom sm-c-indent-cpp-basic 1
  "Indent step for CPP directives."
  :type 'integer)

(defun sm-c--cpp-prev (tok)
  (let ((offset nil))
    (while
        (when (re-search-backward sm-c--cpp-regexp nil t)
          (pcase (cons tok (match-string 3))
            (`(,_ . "endif") (sm-c--cpp-prev "endif"))
            ((or `(,(or "endif" "else" "elif") . ,(or "if" "ifdef" "ifndef"))
                 `(,(or "else" "elif") . "elif"))
             (setq offset 0))
            (`(,(or "endif" "else" "elif") . ,_) nil)
            (`(,_ . ,(or "if" "ifdef" "ifndef" "elif" "else"))
             (setq offset sm-c-indent-cpp-basic))
            (_ (setq offset 0)))
          (not offset)))
    (when offset
      (goto-char (match-beginning 3))
      (+ offset (current-column)))))


(defun sm-c--cpp-indent-line (&optional _arg)
  ;; FIXME: Also align the terminating \, if any.
  (when (> sm-c-indent-cpp-basic 0)
    (let* ((pos (point-marker))
           (beg)
           (indent
            (save-excursion
              (forward-line 0)
              (when (looking-at sm-c--cpp-regexp)
                (setq beg (match-beginning 3))
                (or (sm-c--cpp-prev (match-string 3)) 0)))))
      (when indent
        (let ((before (<= pos beg)))
          (goto-char beg)
          (unless (= (current-column) indent)
            (skip-chars-backward " \t")
            (delete-region (point)
                           (progn (skip-chars-forward " \t") (point)))
            (indent-to indent))
          (unless before (goto-char pos)))))))

;;;; Indenting inside CPP #define.

(defconst sm-c--cpp-smie-indent-functions
  ;; FIXME: Don't just align line after #define with the "d"!
  (mapcar
   (lambda (f)
     (cond
      ((eq f #'smie-indent-comment-inside) #'sm-c--cpp-indent-comment-inside)
      ;; ((eq f #'smie-indent-exps) #'sm-c--cpp-indent-exps)
      (t f)))
   (default-value 'smie-indent-functions)))

(defun sm-c--cpp-indent-comment-inside ()
  (let ((ppss (syntax-ppss)))
    (when (nth 4 ppss)
      ;; Indicate where's the comment start.
      `(noindent . ,(nth 8 ppss)))))

(defun sm-c--cpp-smie-indent ()
  (let ((ppss (syntax-ppss)))
    (cond
     ((sm-c--cpp-inside-p ppss)
      (save-restriction
        (narrow-to-region (nth 8 ppss) (point-max))
        (let ((indent
               (let ((smie-indent-functions sm-c--cpp-smie-indent-functions)
                     (syntax-ppss-cache nil)
                     (syntax-ppss-last nil)
                     (parse-sexp-lookup-properties nil))
                 (smie-indent-calculate))))
          (if (not (eq 'noindent (car-safe indent)))
              (if (integerp indent)
                  (max (funcall smie-rules-function :elem 'basic) indent)
                indent)
            ;; We can't just return `noindent' if we're inside a comment,
            ;; because the indent.el code would then be similarly confused,
            ;; thinking the `noindent' is because we're inside the cpp
            ;; pseudo-comment, and would hence align the code with the content
            ;; of the psuedo-comment rather than the nested real comment!
            ;;
            ;; FIXME: Copy&paste from indent--default-inside-comment.
            ;; FIXME: This will always re-indent inside these comments, even
            ;; during indent-region.
            (save-excursion
              (forward-line -1)
              (skip-chars-forward " \t")
              (when (< (1- (point)) (cdr indent) (line-end-position))
                (goto-char (cdr indent))
                (when (looking-at comment-start-skip)
                  (goto-char (match-end 0))))
              (current-column))))))

     ((equal (syntax-after (point)) (string-to-syntax "< c")) 0)
     )))

;;; Syntax table

(defvar sm-c-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124" st)
    (modify-syntax-entry ?* ". 23b" st)
    (modify-syntax-entry ?\n ">" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\' "\"" st)
    (modify-syntax-entry ?= "." st)
    (modify-syntax-entry ?< "." st)
    (modify-syntax-entry ?> "." st)
    st))

(defun sm-c-syntax-propertize (start end)
  (goto-char start)
  (sm-c--cpp-syntax-propertize end)
  (funcall
   (syntax-propertize-rules
    (sm-c--cpp-regexp (2 (prog1 "< c" (sm-c--cpp-syntax-propertize end)))))
   (point) end))

(defun sm-c-syntactic-face-function (ppss)
  (if (sm-c--cpp-inside-p ppss)
      (prog1 nil (sm-c--cpp-fontify-syntactically ppss))
    (funcall (default-value 'font-lock-syntactic-face-function) ppss)))

;;; SMIE support

(defconst sm-c-paren-block-keywords '("if" "while" "for" "switch"))

(defconst sm-c-smie-precedence-table
  '((assoc ";")
    ;; Compiled from https://en.wikipedia.org/wiki/Operators_in_C_and_C++.
    (assoc ",")                         ;1
    ;; (nonassoc "throw")
    (nonassoc "=" "+=" "-=" "*=" "/=" "%=" "<<=" ">>=" "&=" "^=" "|=") ;2
    ;; (nonassoc "?" ":") ;; Better handle it in the BNF.
    (assoc "||")                        ;3
    (assoc "&&")                        ;4
    (assoc "|")                         ;5
    (assoc "^")                         ;6
    ;; (assoc "&") ;; Binary and.  Confused with address-of.
    (nonassoc "==" "!=")                ;7
    (nonassoc "<" "<=" ">" ">=")        ;8
    (nonassoc "<<" ">>")                ;9
    (assoc "+" "-")                     ;10
    (assoc "/" "* mult" "%")            ;11
    ;; (nonassoc ".*" "->*")            ;12   ;; Only C++
    ;; (nonassoc "++" "--" "+" "-" "!" "~" "(type)" "*" "&"
    ;;          "sizeof" "new" "delete");13  ;; All prefix.
    (left "." "->") ;; "++" "--" suffixes, "()", "[]", "typeid", "*_cast". ;14
    ;; (noassoc "::") ;; Only C++
    ))

(defconst sm-c-smie-grammar
  ;; `((:smie-closer-alist ("{" . "}")) ("{" (39) 0) ("}" 0 (40)) ("else" 27 26) ("," 38 38) ("do" (41) 22) ("while" (42) 23) ("for" (43) 24) (";" 11 11) ("if" (44) 25))
  (let ((grm
         (smie-prec2->grammar
          (smie-merge-prec2s
           (smie-bnf->prec2
            '((decls ("typedef" decl) ("extern" decl)
                     (decls ";" decls))
              (decl)
              (id)
              (insts ("{" insts "}")
                     (insts ";" insts)
                     ("return" exp)
                     ("goto" exp)
                     (":label")
                     ("case" subexp ": case")
                     ("else" exp-if))
              (exp-if ("if" exp) ("do" exp) ("while" exp) ("switch" exp) ("for" exp)
                      (exp))
              (exp ("(" exp ")") (exp "," exp) (subexp "?" exp ":" exp))
              (subexp (subexp "||" subexp))
              ;; Some of the precedence table deals with pre/postfixes, which
              ;; smie-precs->prec2 can't handle, so handle it here instead.
              (exp11 (exp12) (exp11 "/" exp11))
              (exp12 (exp13))           ;C++ only.
              (exp13 (exp14) ("++ prefix" exp13) ("-- prefix" exp13)
                     ("!" exp13) ("~" exp13) ("&" exp13) ("* deref" exp13))
              (exp14 (id) (exp14 "++ postfix") (exp14 "-- postfix")
                     (exp14 "->" id) (exp14 "." id)))
            '((assoc ";") (assoc ",") (nonassoc "?" ":"))
            sm-c-smie-precedence-table)
           (smie-precs->prec2 sm-c-smie-precedence-table)
           (smie-precs->prec2 '((nonassoc ";") (nonassoc ":")))))))
    ;; SMIE gives (":label" 261 262), but really this could just as well be
    ;; (":label" nil nil) because labels don't have any argument to their left
    ;; or right.  They're like both openers and closers at the same time.
    (mapcar (lambda (x)
              (if (equal (car-safe x) ":label")
                  ;; Rather than (":label" (n1) (n2)) we use
                  ;; (":label" (n1) n2) because SMIE otherwise complains:
                  ;; cl--assertion-failed((numberp (funcall op-forw toklevels)))
                  ;; in smie-next-sexp.
                  `(,(nth 0 x) (,(nth 1 x)) ,(nth 2 x)) x))
            grm)))

;; (defun sm-c--:-discriminate ()
;;   (save-excursion
;;     (and (null (smie-backward-sexp))
;;          (let ((prev (smie-indent-backward-token)))
;;            (cond
;;             ((equal prev "case" ) ": case")
;;             ((member prev '(";" "{" "}")) ":-label")
;;             (t ":"))))))

(defconst sm-c-smie-operator-regexp
  (let ((ops '()))
    (pcase-dolist (`(,token . ,_) sm-c-smie-grammar)
      (when (and (stringp token) (string-match "\\`[^ [:alnum:](){}]+" token))
        (push (match-string 0 token) ops)))
    (regexp-opt ops)))

(defun sm-c-smie-forward-token ()
  (forward-comment (point-max))
  (let ((tok (if (looking-at sm-c-smie-operator-regexp)
                 (progn (goto-char (match-end 0)) (match-string 0))
               (smie-default-forward-token))))
    (cond
     ((and (equal tok "") (looking-at "\\\\\n"))
      (goto-char (match-end 0))
      (sm-c-smie-forward-token))
     ((member tok '(":" "*"))
      (save-excursion (sm-c-smie-backward-token)))
     ((looking-at "[ \t]*:")
      (if (not (equal (save-excursion (sm-c-smie-forward-token)) ":label"))
          tok
        (looking-at "[ \t]*:")
        (goto-char (match-end 0)) ":label"))
     (t tok))))


(defun sm-c-smie-backward-token ()
  (forward-comment (- (point)))
  (let ((tok (if (looking-back sm-c-smie-operator-regexp (- (point) 3) t)
                 (progn (goto-char (match-beginning 0)) (match-string 0))
               (smie-default-backward-token))))
    (cond
     ((and (equal tok "") (looking-at "\n"))
      (let ((pos (point)))
        (if (not (= 0 (mod (skip-chars-backward "\\\\") 2)))
            (sm-c-smie-backward-token)
          (goto-char pos)
          tok)))
     ((equal tok "*") (sm-c-smie--*-token))
     ((equal tok ":")
      (let ((pos1 (point))
            (prev (sm-c-smie-backward-token)))
        (if (zerop (length prev))
            (progn (goto-char pos1) tok)
          (let ((pos2 (point)))
            (pcase (car (smie-indent-backward-token))
              ("case" (goto-char pos1) ": case")
              ((or ";" "{" "}") (goto-char pos2) ":label")
              (_ (goto-char pos1) tok))))))
     (t tok))))

(defun sm-c--prev-token ()
  (car (smie-indent-backward-token)))

(defun sm-c--else-to-if ()
  (let ((pos (point)))
    (unless (equal (sm-c--prev-token) ";")
      (goto-char pos))
    (while
        (pcase (smie-backward-sexp)
          (`(,_ ,pos "if") (goto-char pos) nil) ;Found it!
          (`(,_ ,_ ";") nil)                    ;Can't find it!
          (`(,_ ,pos "else") (goto-char pos) (sm-c--else-to-if) t)
          (`(,_ ,pos "while")
           (goto-char pos) (unless (sm-c--while-to-do) (goto-char pos)) t)
          (`(t . ,_) nil)               ;Can't find it!
          (`(,_ ,pos . ,_) (goto-char pos) t)
          (`nil t)))))

(defun sm-c--while-to-do ()
  "Jump to the matching `do' and return non-nil, if any.  Return nil otherwise."
  (pcase (sm-c--prev-token)
    ("}"
     ;; The easy case!
     (forward-char 1) (backward-sexp 1)
     (equal (sm-c--prev-token) "do"))
    (";"
     (let ((found-do nil))
       (while
           (pcase (smie-backward-sexp)
             (`(,_ ,pos "do") (goto-char pos) (setq found-do t) nil)
             (`(,_ ,_ ";") nil)         ;Can't find it!
             (`(,_ ,pos "else") (goto-char pos) (sm-c--else-to-if) t)
             (`(,_ ,pos "while")
              (goto-char pos) (unless (sm-c--while-to-do) (goto-char pos)) t)
             (`(t . ,_) nil)            ;Can't find it!
             (`(,_ ,pos . ,_) (goto-char pos) t)
             (`nil (or (not (looking-at "{"))
                       (smie-rule-prev-p "=")))))
       found-do))))

(defun sm-c--skip-labels (max)
  (while
      (let ((start (point)))
        (pcase (sm-c-smie-forward-token)
          ("case"
           (smie-forward-sexp "case")
           (forward-comment (point-max))
           (if (>= (point) max) (progn (goto-char start) nil)
             t))
          (":label"
           (forward-comment (point-max))
           (if (>= (point) max) (progn (goto-char start) nil)
             t))
          (_ (goto-char start) nil)))))

(defun sm-c--boi (&optional inner)
  "Jump to the beginning-of-instruction.
By default for things like nested ifs, it jumps to the outer if, but
if INNER is non-nil, it stops at the innermost one."
  (while
      (let ((pos (point)))
        (pcase (smie-backward-sexp)
          (`(,_ ,_ ";") nil)            ;Found it!
          (`(,_ ,pos "else") (goto-char pos) (sm-c--else-to-if) t)
          (`(,_ ,pos "while")
           (goto-char pos) (unless (sm-c--while-to-do) (goto-char pos)) t)
          (`(,(pred numberp) ,pos . ,_) (goto-char pos) t)
          ((or `nil `(nil . ,_))
           (if (and (or (not (looking-at "{"))
                        (smie-rule-prev-p "="))
                    (not (bobp)))
               t
             (goto-char pos) nil))
          (`(,_ ,_ ,(or "(" "{" "[")) nil) ;Found it!
          (`(,_ ,pos ,(and tok
                           (guard (when inner
                                    (or (member tok sm-c-paren-block-keywords)
                                        (equal tok "do"))))))
           (goto-char pos) nil) ;Found it!
          (`(t ,(pred (eq (point-min))) . ,_) nil)
          (`(,_ ,pos . ,_) (goto-char pos) t)))))

;; (defun sm-c--if-tail-to-head ()
;;   (pcase (sm-c--prev-token)
;;     (")"
;;      (forward-char 1) (backward-sexp 1)
;;      (pcase (sm-c--prev-token)
;;        ("if" nil)
;;        ((or "while" "for") (sm-c--if-tail-to-head))))
;;     ("do" (sm-c--if-tail-to-head))))

(defun sm-c--boe (tok)
  (let ((start (point))
        (res (smie-backward-sexp tok)))
    (when (member (nth 2 res) '("if" "while" "do" "for" "else"))
      (when (member (nth 2 res) '("if" "for"))
        (let ((forward-sexp-function nil))
          (forward-sexp 1))
        (forward-comment (point-max)))
      (when (looking-at "{")
        (let ((forward-sexp-function nil))
          (forward-sexp 1))
        (forward-comment (point-max)))
      (if (> (point) start) (goto-char start)))))

(defun sm-c-smie--*-token ()
  (save-excursion
    (let ((pos (point)))
      (pcase (car (smie-indent-backward-token))
        (")"
         ;; Can be a multiplication (as in "(a+b)*c"), or a deref
         ;; (as in "if (stop) *a = 0;")
         (if (and (goto-char (nth 1 (syntax-ppss)))
                  (eq ?\( (char-after))
                  (member (smie-default-backward-token) '("if" "for")))
             "* deref"
           "* mult"))
        ("]" "* mult")                         ;Multiplication.
        ((or "(" "[" "{" "}") "* deref")
        (`nil
         (goto-char pos)
         (pcase (smie-backward-sexp "* mult")
           (`(,_ ,_ ,(or ";" "{")) "* deref")
           (_ "* mult")))
        (_ "* mult")))))

(defun sm-c-smie-hanging-eolp ()
  (let ((start (point))
        (prev (smie-indent-backward-token)))
    (if (and (not (numberp (nth 1 prev)))
             (save-excursion (equal (sm-c-smie-backward-token) ";")))
        ;; Treat instructions that start after ";" as always "hanging".
        (end-of-line)
      (goto-char start)))
  (skip-chars-forward " \t")
  (or (eolp)
      (forward-comment (point-max))
      (and (looking-at "\\\\\n")
           (goto-char (match-end 0)))))

(defvar sm-c-smie--inhibit-case/label-rule nil)

(defun sm-c--smie-virtual ()
  (if (and (smie-indent--bolp)
           (not (save-excursion
                  (member (sm-c-smie-forward-token)
                          '("case" ":label")))))
      (current-column)
    (let ((sm-c-smie--inhibit-case/label-rule t))
      (smie-indent-calculate))))

(defun sm-c-smie-rules (kind token)
  (pcase (cons kind token)
    (`(:elem . basic) sm-c-indent-basic)
    (`(:list-intro . ";")
     (save-excursion
       (forward-char 1)
       (if (and (null (smie-forward-sexp))
                ;; FIXME: Handle \\\n as well!
                (progn (forward-comment (point-max))
                       (looking-at "(")))
           nil
         t)))
    (`(:before . "else")
     (save-excursion
       (sm-c--else-to-if)
       `(column . ,(smie-indent-virtual))))
    (`(:before . "while")
     (save-excursion
       (when (sm-c--while-to-do)
         `(column . ,(smie-indent-virtual)))))
    (`(:before . ,(or "=" "+=" "-=" "*=" "/=" "%=" "<<=" ">>=" "&=" "^=" "|="))
     (save-excursion
       (sm-c--boe token)
       `(column . ,(+ (funcall smie-rules-function :elem 'basic)
                      (smie-indent-virtual)))))
    (`(:before . "if")
     (when (and (not (smie-rule-bolp)) (smie-rule-prev-p "else"))
       (save-excursion
         (smie-indent-backward-token)
         `(column . ,(sm-c--smie-virtual)))))
    ;; (`(:after . ,(or "=" "+=" "-=" "*=" "/=" "%=" "<<=" ">>=" "&=" "^=" "|="))
    ;;  (funcall smie-rules-function :elem 'basic))
    (`(:before . "{")
     (cond
      ((smie-rule-prev-p "=") nil)      ;Not a block of instructions!
      ((save-excursion
         (let ((pos (point)))
           (sm-c--boi 'inner) (sm-c--skip-labels (point-max))
           (let ((tok (save-excursion (sm-c-smie-forward-token))))
             (cond
              ((member tok '("typedef")) ; "enum" "struct"
               `(column . ,(+ (funcall smie-rules-function :elem 'basic)
                              (smie-indent-virtual))))
              ((or (member tok sm-c-paren-block-keywords)
                   (equal tok "do"))
               nil)
              ((save-excursion
                 (goto-char pos)
                 (when (and (> (car (syntax-ppss)) 0)
                            (equal ")" (car (smie-indent-backward-token))))
                   (up-list -1)
                   `(column . ,(sm-c--smie-virtual)))))
              (t `(column . ,(smie-indent-virtual))))))))
      ((smie-rule-hanging-p)
       (cond
        ((smie-rule-prev-p "do" "else")
         (smie-indent-backward-token))
        ((smie-rule-prev-p ")")
         (smie-backward-sexp)
         (smie-indent-backward-token))
        (t (sm-c--boi 'inner)))
       `(column . ,(sm-c--smie-virtual)))
      (t
       (let ((pos (point)))
         (pcase (sm-c--prev-token)
           ((or "do" "else")
            (cond
             (sm-c-indent-braces
              `(column . ,(+ (funcall smie-rules-function :elem 'basic)
                             (smie-indent-virtual))))))
           (")" nil)
           (_ (goto-char pos) (sm-c--boi)
              (if (< (point) pos)
                  `(column . ,(sm-c--smie-virtual)))))))))
    (`(:before . "(")
     (save-excursion
       (let ((res (smie-backward-sexp)))
         (pcase res
           (`nil
            (if (looking-at "(")
                ;; (unless (save-excursion
                ;;           (member (sm-c-smie-backward-token)
                ;;                   sm-c-paren-block-keywords))
                ;;   `(column . ,(sm-c--smie-virtual)))
                nil
              `(column . ,(+ (funcall smie-rules-function :elem 'basic)
                             (sm-c--smie-virtual)))))))))
    (`(:after . "else")
     (save-excursion
       (funcall smie-rules-function :elem 'basic)))
    (`(:after . ")")
     (save-excursion
       (let ((_ (progn (forward-char 1) (backward-sexp 1)))
             (pos (point))
             (prev (sm-c-smie-backward-token)))
         (cond
          ((member prev sm-c-paren-block-keywords)
           `(column . ,(+ (funcall smie-rules-function :elem 'basic)
                          (smie-indent-virtual))))
          ((and (looking-at "[[:alnum:]_]+(")
                (save-excursion
                  (forward-line 0)
                  (and (bobp) (looking-at sm-c--cpp-regexp))))
           ;; Will be bumped up presumably by the "max" in
           ;; sm-c--cpp-smie-indent.
           `(column . 0))
          (t (goto-char pos) `(column . ,(sm-c--smie-virtual)))))))
    (`(:after . "}")
     (save-excursion
       (forward-char 1) (backward-sexp 1)
       (sm-c--boi)
       `(column . ,(sm-c--smie-virtual))))
    (`(:after . ";")
     (save-excursion
       (sm-c--boi)
       `(column . ,(sm-c--smie-virtual))))
    (`(:after . ":label")
     ;; Yuck!
     `(column . ,(sm-c--smie-virtual)))
    (`(:after . ": case")
     ;; Yuck!
     (save-excursion
       (smie-backward-sexp ": case")
       `(column . ,(sm-c--smie-virtual))))
    (`(:after . "* deref") `(column . ,(sm-c--smie-virtual)))
    ((and `(:before . ":label") (guard (not sm-c-smie--inhibit-case/label-rule)))
     (let ((ppss (syntax-ppss)))
       (when (nth 1 ppss)
         (save-excursion
           (goto-char (nth 1 ppss))
           `(column . ,(smie-indent-virtual))))))
    ((and `(:before . "case") (guard (not sm-c-smie--inhibit-case/label-rule)))
     (catch 'found
       (dolist (pos (reverse (nth 9 (syntax-ppss))))
         (save-excursion
           (goto-char pos)
           (and (looking-at "{")
                (null (car-safe (smie-backward-sexp)))
                (equal "switch" (sm-c-smie-backward-token))
                (goto-char pos)
                (throw 'found `(column . ,(smie-indent-virtual))))))))))

;;; Backslash alignment

(defvar-local sm-c--bs-changed nil)

(defun sm-c--bs-after-change (beg end _len)
  (unless undo-in-progress
    (if (null sm-c--bs-changed)
        (setq sm-c--bs-changed (cons beg end))
      (cl-callf (lambda (x) (min x beg)) (car sm-c--bs-changed))
      (cl-callf (lambda (x) (max x end)) (cdr sm-c--bs-changed)))))

(defun sm-c--bs-realign ()
  (when sm-c--bs-changed
    (sm-c--bs-realign-1 (car sm-c--bs-changed) (cdr sm-c--bs-changed))
    (setq sm-c--bs-changed nil)))

(defun sm-c--bs-realign-1 (from to)
  (save-excursion
    (goto-char from)
    (end-of-line)
    (unless (zerop (mod (skip-chars-backward "\\\\") 2))
      (skip-chars-backward " \t")
      (let ((col (current-column))
            start end)
        (while
            (progn (setq start (point))
                   (end-of-line 0)
                   (and (< (point) start)
                        (not (zerop (mod (skip-chars-backward "\\\\") 2)))))
          (skip-chars-backward " \t")
          (setq col (max (current-column) col)))
        (goto-char from)
        (while
            (progn (setq end (point))
                   (end-of-line 2)
                   (and (> (point) start)
                        (not (zerop (mod (skip-chars-backward "\\\\") 2)))))
          (skip-chars-backward " \t")
          (setq col (max (current-column) col)))
        (goto-char to)
        (beginning-of-line)
        (unless (or (> (point) end)       ;Don't realign if we changed outside!
                    (< end start))        ;A lone \
          
          (setq col (1+ col))         ;Add a space before the backslashes.
          (goto-char end)
          (end-of-line)
          (while (>= (point) start)
            (cl-assert (eq (char-before) ?\\))
            (forward-char -1)
            (let ((curcol (current-column)))
              (cond
               ((> col curcol) (indent-to col))
               ((< col curcol)
                (move-to-column col t)
                (delete-region (point)
                               (progn (skip-chars-forward " \t") (point))))))
            (end-of-line 0)))))))
            
;;; Font-lock support

(defconst sm-c-font-lock-keywords
  `((,sm-c--cpp-regexp (1 font-lock-preprocessor-face))
    ("\\_<\\(?:true\\|false\\)\\_>" (0 font-lock-constant-face))
    ("\\_<\\(case\\)\\_>[ \t]*\\([^: \t]+\\)"
     (1 font-lock-keyword-face)
     (2 font-lock-constant-face))
    ("\\(?:[{};]\\(\\)\\|^\\)[ \t]*\\([[:alpha:]_][[:alnum:]_]*\\)[ \t]*:"
     (2 (if (or (match-beginning 1)
                (save-excursion (equal ":label" (sm-c-smie-backward-token))))
            font-lock-constant-face)))
    (,(let ((kws (delq nil (mapcar (lambda (x)
                                     (setq x (car x))
                                     (and (stringp x)
                                          (string-match "\\`[a-z]" x)
                                          x))
                                   sm-c-smie-grammar))))
        (concat "\\_<" (regexp-opt
                        (append
                         ;; Elements not in SMIE's grammar.  Either because
                         ;; they're uninteresting from a parsing point of view,
                         ;; or because SMIE's parsing engine can't handle them
                         ;; even poorly.
                         '("break" "continue" "struct" "enum" "union" "static")
                         ;; "case" already handled above.
                         (delete "case" kws)))
                "\\_>"))
     (0 font-lock-keyword-face))
    (,(let* ((spc0 "\\(?:\n?[ \t]\\|/\\*.*?\\*/\\)*")
             (spc1 (concat "\n?[ \t]" spc0))
             (id "\\(?:\\sw\\|\\s_\\)+"))
        (cl-flet ((repeat (repetition &rest res)
                          (concat "\\(?:" (apply #'concat res) "\\)"
                                  (pcase repetition
                                    ((pred symbolp) (symbol-name repetition))
                                    (1 "")))))
          (concat
           "^"
           (repeat '* "\\*" spc0)
           (repeat '* id (repeat 1 spc1 "\\|" spc0 "\\*" spc0))
           "\\(" id "\\)[ \t\n]*(")))
     (1
      (prog1 font-lock-function-name-face
        (if (< (match-beginning 0) (line-beginning-position))
            (put-text-property (match-beginning 0) (match-end 0)
                               'font-lock-multiline t)))))))


;;;###autoload
(define-derived-mode sm-c-mode prog-mode "smC"
  "C editing mode based on SMIE."
  ;; (setq-local font-lock-support-mode nil) ;; To help debugging.
  (setq-local comment-start "/* ")
  (setq-local comment-end " */")
  (setq-local parse-sexp-lookup-properties t)
  (setq-local open-paren-in-column-0-is-defun-start nil)
  (setq-local syntax-propertize-function #'sm-c-syntax-propertize)
  (setq-local font-lock-defaults '(sm-c-font-lock-keywords))
  (setq-local font-lock-syntactic-face-function #'sm-c-syntactic-face-function)
  (smie-setup sm-c-smie-grammar #'sm-c-smie-rules
              :backward-token #'sm-c-smie-backward-token
              :forward-token #'sm-c-smie-forward-token)
  ;; FIXME: The stock SMIE forward-sexp-function is not good enough here, since
  ;; our grammar is much too poor.  We should setup another function instead
  ;; (or ideally teach SMIE to use it).
  (kill-local-variable 'forward-sexp-function)
  (add-hook 'smie-indent-functions #'sm-c--cpp-smie-indent nil t)
  (add-function :after (local 'indent-line-function)
                #'sm-c--cpp-indent-line)
  (setq-local smie--hanging-eolp-function #'sm-c-smie-hanging-eolp)
  ;; Backslash auto-realign.
  (add-hook 'after-change-functions #'sm-c--bs-after-change nil t)
  (add-hook 'post-command-hook #'sm-c--bs-realign nil t))

(provide 'sm-c-mode)
;;; sm-c-mode.el ends here
