;; guix-manifest.scm
;; CI/CD パイプライン用の再現可能な開発環境
;;
;; Usage:
;;   guix shell -m guix-manifest.scm
;;   guix shell -m guix-manifest.scm -- ./scripts/ci-pipeline.sh dev

(specifications->manifest
  '(
    ;; Java (21 = latest LTS)
    "openjdk@21"

    ;; Build tools
    "maven@3.8"
    "git@2"

    ;; Container
    "docker@20"

    ;; Utilities
    "jq"          ; JSON parsing/manipulation
    "curl"        ; HTTP client
    "which"       ; Command locator
    "coreutils"   ; Basic utilities (for scripts)
  ))
