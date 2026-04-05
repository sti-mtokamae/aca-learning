;; guix-manifest.scm
;; CI/CD パイプライン用の再現可能な開発環境
;;
;; Usage:
;;   guix shell -m guix-manifest.scm
;;   guix shell -m guix-manifest.scm -- ./scripts/ci-pipeline.sh dev

(specifications->manifest
  '(
    ;; Java
    "openjdk"

    ;; Build tools
    "maven"
    "git"

    ;; Container
    "docker"

    ;; Utilities
    "jq"          ; JSON parsing/manipulation
    "curl"        ; HTTP client
    "which"       ; Command locator
    "coreutils"   ; Basic utilities (for scripts)
  ))
