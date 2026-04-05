;; guix-manifest.scm
;; CI/CD パイプライン用の再現可能な開発環境
;;
;; Usage:
;;   guix shell -m guix-manifest.scm
;;   guix shell -m guix-manifest.scm -- ./scripts/ci-pipeline.sh dev

(specifications->manifest
  '(
    ;; Java
    "openjdk@21"

    ;; Build tools
    "maven@3.8"
    "git@2"

    ;; Container
    "docker@24"

    ;; Utilities
    "jq@1"          ; JSON parsing/manipulation
    "curl@8"        ; HTTP client
    "which@2"       ; Command locator
    "coreutils@9"   ; Basic utilities (for scripts)

    ;; Azure CLI（optional but recommended）
    "azure-cli@2"
  ))
