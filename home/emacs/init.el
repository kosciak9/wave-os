(load "~/.emacs.d/sanemacs.el" nil t)
(setq package-enable-at-startup nil)

(defvar bootstrap-version)

;; for emacs 29.1
(setq straight-repository-branch "develop")

(let ((bootstrap-file
       (expand-file-name "straight/repos/straight.el/bootstrap.el" user-emacs-directory))
      (bootstrap-version 6))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
      (url-retrieve-synchronously
       "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
       'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

(straight-use-package 'use-package)
(setq straight-use-package-by-default t)

(use-package evil
  :ensure t
  :config
  (evil-mode 1))

(use-package org
  :after geiser-guile
  :config
  (require 'org-tempo)
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((scheme . t)))
  )

(use-package doom-modeline
  :config
  (setq doom-modeline-buffer-encoding nil)
  (setq doom-modeline-modal-icon nil)
  :init
  (doom-modeline-mode 1))

(defvar k9/default-font-size 140)
(defvar k9/default-variable-font-size 140)

(set-face-attribute 'default nil :font "Iosevka Nerd Font Mono" :height k9/default-font-size)
;; Set the fixed pitch face
(set-face-attribute 'fixed-pitch nil :font "Iosevka Nerd Font Mono" :height k9/default-font-size)
;; ;; Set the variable pitch face
;; (set-face-attribute 'variable-pitch nil :font "Noto Sans" :height k9/default-font-size :weight 'regular)

(use-package autothemer
  :config
  (load "~/.emacs.d/kanagawa-theme.el" nil t)
  (load-theme 'kanagawa t))

(use-package geiser-guile)
(use-package paredit
  :init
  (add-hook 'clojure-mode-hook #'enable-paredit-mode)
  (add-hook 'cider-repl-mode-hook #'enable-paredit-mode)
  (add-hook 'emacs-lisp-mode-hook #'enable-paredit-mode)
  (add-hook 'eval-expression-minibuffer-setup-hook #'enable-paredit-mode)
  (add-hook 'ielm-mode-hook #'enable-paredit-mode)
  (add-hook 'lisp-mode-hook #'enable-paredit-mode)
  (add-hook 'lisp-interaction-mode-hook #'enable-paredit-mode)
  (add-hook 'scheme-mode-hook #'enable-paredit-mode)
  :config
  (show-paren-mode t)
  :bind (("M-[" . paredit-wrap-square)
	 ("M-{" . paredit-wrap-curly))
  :diminish nil)
(use-package parinfer-rust-mode
  :init
  (setq parinfer-rust-auto-download t)
  :hook (scheme-mode emacs-lisp-mode))
