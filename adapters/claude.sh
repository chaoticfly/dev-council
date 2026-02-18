#!/usr/bin/env bash
# Kannan — Claude CLI Adapter

claude_execute() {
    local system_prompt="$1"
    local user_prompt="$2"
    local model="${3:-}"
    local report_file="${4:-}"

    local args=("-p" "--output-format" "text" "--permission-mode" "acceptEdits")

    [[ -n "$model" ]] && args+=("--model" "$model")
    [[ -n "$system_prompt" ]] && args+=("--system-prompt" "$system_prompt")
    args+=("$user_prompt")

    if [[ -n "$report_file" ]]; then
        claude "${args[@]}" | tee "$report_file"
    else
        claude "${args[@]}"
    fi
}
