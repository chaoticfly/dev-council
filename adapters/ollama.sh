#!/usr/bin/env bash
# Kannan — Ollama Adapter

# Default model (can be overridden via KANNAN_OLLAMA_MODEL env var or config.json)
OLLAMA_MODEL="${KANNAN_OLLAMA_MODEL:-llama3.2}"

ollama_execute() {
    local system_prompt="$1"
    local user_prompt="$2"
    local model="${3:-$OLLAMA_MODEL}"
    local report_file="${4:-}"

    local prompt="$user_prompt"
    if [[ -n "$system_prompt" ]]; then
        prompt="[System: $system_prompt]

$user_prompt"
    fi

    if [[ -n "$report_file" ]]; then
        ollama run "$model" "$prompt" | tee "$report_file"
    else
        ollama run "$model" "$prompt"
    fi
}
