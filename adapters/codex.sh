#!/usr/bin/env bash
# Kannan — Codex CLI Adapter

codex_execute() {
    local system_prompt="$1"
    local user_prompt="$2"
    local model="${3:-}"
    local report_file="${4:-}"

    local prompt="$user_prompt"
    if [[ -n "$system_prompt" ]]; then
        prompt="[System: $system_prompt]

$user_prompt"
    fi

    local args=("-q")
    [[ -n "$model" ]] && args+=("--model" "$model")
    args+=("$prompt")

    if [[ -n "$report_file" ]]; then
        codex "${args[@]}" | tee "$report_file"
    else
        codex "${args[@]}"
    fi
}
