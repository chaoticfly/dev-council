#!/usr/bin/env bash
# Kannan — Gemini CLI Adapter

gemini_execute() {
    local system_prompt="$1"
    local user_prompt="$2"
    local model="${3:-}"
    local report_file="${4:-}"

    local prompt="$user_prompt"
    if [[ -n "$system_prompt" ]]; then
        prompt="[System: $system_prompt]

$user_prompt"
    fi

    local cmd_args=()
    [[ -n "$model" ]] && cmd_args+=("--model" "$model")

    if [[ -n "$report_file" ]]; then
        echo "$prompt" | gemini "${cmd_args[@]}" | tee "$report_file"
    else
        echo "$prompt" | gemini "${cmd_args[@]}"
    fi
}
