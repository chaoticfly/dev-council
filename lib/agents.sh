#!/usr/bin/env bash
# Kannan — Agent Discovery and Management

# Agent registry (populated by agents_discover)
declare -A AGENTS_AVAILABLE=()
declare -A AGENT_CAPABILITIES=()

# Static capability map
_init_capabilities() {
    AGENT_CAPABILITIES=(
        [claude]="code,review,plan,test,debug,general"
        [codex]="code,test,debug"
        [gemini]="code,review,plan,general"
        [ollama]="review,plan,general"
    )
}

# Discover which agent CLIs are installed
agents_discover() {
    _init_capabilities
    AGENTS_AVAILABLE=()

    if has_cmd claude; then
        AGENTS_AVAILABLE[claude]="$(claude --version 2>/dev/null | head -1 || echo "available")"
    fi
    if has_cmd codex; then
        AGENTS_AVAILABLE[codex]="$(codex --version 2>/dev/null | head -1 || echo "available")"
    fi
    if has_cmd gemini; then
        AGENTS_AVAILABLE[gemini]="$(gemini --version 2>/dev/null | head -1 || echo "available")"
    fi
    if has_cmd ollama; then
        AGENTS_AVAILABLE[ollama]="$(ollama --version 2>/dev/null | head -1 || echo "available")"
    fi
}

agents_available_count() {
    echo "${#AGENTS_AVAILABLE[@]}"
}

agents_available_names() {
    local names=""
    for name in "${!AGENTS_AVAILABLE[@]}"; do
        names+="$name "
    done
    echo "${names% }"
}

agents_is_available() {
    [[ -n "${AGENTS_AVAILABLE[$1]+x}" ]]
}

agents_list_pretty() {
    local found=0
    echo ""
    echo -e "${_BOLD}Available Agents${_RESET}"
    ui_separator

    for name in claude codex gemini ollama; do
        if agents_is_available "$name"; then
            local ver="${AGENTS_AVAILABLE[$name]}"
            local caps="${AGENT_CAPABILITIES[$name]}"
            echo -e "  ${_GREEN}●${_RESET} ${_BOLD}$name${_RESET}  ${_DIM}$ver${_RESET}"
            echo -e "    capabilities: ${_CYAN}$caps${_RESET}"
            found=$((found + 1))
        else
            echo -e "  ${_DIM}○ $name (not installed)${_RESET}"
        fi
    done

    echo ""
    echo -e "  ${_DIM}$found agent(s) available${_RESET}"
    echo ""
}

# Check if agent has a specific capability
agent_has_capability() {
    local agent="$1" cap="$2"
    local caps="${AGENT_CAPABILITIES[$agent]:-}"
    [[ ",$caps," == *",$cap,"* ]]
}

# Get the best agent for a given capability
agent_best_for() {
    local cap="$1"
    # Priority order: claude > codex > gemini > ollama
    for name in claude codex gemini ollama; do
        if agents_is_available "$name" && agent_has_capability "$name" "$cap"; then
            echo "$name"
            return
        fi
    done
    # Fallback: any available agent
    for name in "${!AGENTS_AVAILABLE[@]}"; do
        echo "$name"
        return
    done
    echo ""
}

# --- Pane execution: run agents in separate tmux panes or terminal windows ---

# Check if we can open a separate pane/window for an agent
_can_open_pane() {
    [[ -n "${TMUX:-}" ]] && return 0
    [[ "$(uname -s)" == "Darwin" ]] && return 0
    return 1
}

# Run an agent in a separate tmux pane or terminal window.
# The agent runs with its own TTY — user sees output in the new pane.
# Report file captures the output. Blocks until the agent completes.
_run_agent_in_pane() {
    local agent="$1"
    local system_prompt="$2"
    local user_prompt="$3"
    local model="$4"
    local work_dir="$5"
    local report_file="$6"

    # Write prompts to temp files to avoid quoting issues in the wrapper script
    local sys_file usr_file
    sys_file="$(mktemp)"
    usr_file="$(mktemp)"
    printf '%s' "$system_prompt" > "$sys_file"
    printf '%s' "$user_prompt" > "$usr_file"

    local done_file="${report_file}.done"
    local exit_file="${report_file}.exit"

    # Build wrapper script: set variables with printf %q (safe quoting),
    # then append the logic with a non-expanding heredoc.
    local wrapper
    wrapper="$(mktemp /tmp/kannan-agent-XXXXXX.sh)"

    {
        echo '#!/usr/bin/env bash'
        printf '_ADAPTER=%q\n' "$SCRIPT_DIR/adapters/${agent}.sh"
        printf '_AGENT=%q\n' "$agent"
        printf '_WORK_DIR=%q\n' "$work_dir"
        printf '_MODEL=%q\n' "$model"
        printf '_REPORT=%q\n' "$report_file"
        printf '_SYS=%q\n' "$sys_file"
        printf '_USR=%q\n' "$usr_file"
        printf '_DONE=%q\n' "$done_file"
        printf '_EXIT=%q\n' "$exit_file"
    } > "$wrapper"

    cat >> "$wrapper" <<'PANE_BODY'
source "$_ADAPTER"
cd "$_WORK_DIR"
_s="$(cat "$_SYS")"
_u="$(cat "$_USR")"
"${_AGENT}_execute" "$_s" "$_u" "$_MODEL" "$_REPORT"
echo $? > "$_EXIT"
rm -f "$_SYS" "$_USR"
touch "$_DONE"
echo ""
echo "── agent finished ──"
sleep 2
PANE_BODY

    chmod +x "$wrapper"

    # Launch in a separate pane/window
    if [[ -n "${TMUX:-}" ]]; then
        tmux split-window -v -p 40 "$wrapper"
        ui_phase "Agent $agent opened in tmux pane — waiting for completion..."
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        osascript -e "tell application \"Terminal\" to do script \"'$wrapper'\"" 2>/dev/null \
            || open -a Terminal "$wrapper"
        ui_phase "Agent $agent opened in Terminal window — waiting for completion..."
    fi

    # Wait for agent to complete (poll for .done sentinel)
    while [[ ! -f "$done_file" ]]; do
        sleep 0.5
    done
    ui_success "Agent $agent completed"

    # Get exit code
    local result=0
    if [[ -f "$exit_file" ]]; then
        result="$(cat "$exit_file")"
    fi

    rm -f "$wrapper" "$done_file" "$exit_file"

    return "${result:-0}"
}

# Execute a prompt using a specific agent adapter
# Args: agent, system_prompt, user_prompt, [report_file]
# When report_file is provided and a pane can be opened, the agent runs in its
# own tmux pane / terminal window. Otherwise runs in the current terminal.
# Token recording is done here (outside subshell) so globals are updated.
adapter_execute() {
    local agent="$1" system_prompt="$2" user_prompt="$3" report_file="${4:-}"
    local adapter="$SCRIPT_DIR/adapters/${agent}.sh"

    if [[ ! -f "$adapter" ]]; then
        ui_error "No adapter for agent: $agent"
        return 1
    fi

    # Prepend custom agent prompt from config if set
    local custom_prompt
    custom_prompt="$(config_get_agent_prompt "$agent")"
    if [[ -n "$custom_prompt" ]]; then
        if [[ -n "$system_prompt" ]]; then
            system_prompt="$custom_prompt

$system_prompt"
        else
            system_prompt="$custom_prompt"
        fi
    fi

    # Resolve model override from config
    local model
    model="$(config_get_agent_model "$agent")"

    local work_dir="${KANNAN_WORK_DIR:-$(pwd)}"

    # Run agent in a separate pane if possible, otherwise in current terminal
    if [[ -n "$report_file" ]] && _can_open_pane; then
        _run_agent_in_pane "$agent" "$system_prompt" "$user_prompt" "$model" "$work_dir" "$report_file"
    else
        source "$adapter"
        (cd "$work_dir" && "${agent}_execute" "$system_prompt" "$user_prompt" "$model" "$report_file")
    fi
    local result=$?

    # Record token estimates from report file (outside subshell so globals update)
    if [[ -n "$report_file" && -f "$report_file" ]]; then
        local prompt_chars=$(( ${#system_prompt} + ${#user_prompt} ))
        local output_chars
        output_chars="$(wc -c < "$report_file" | tr -d ' ')"
        tokens_record "$agent" "$(( prompt_chars / 4 ))" "$(( output_chars / 4 ))"
    fi

    return $result
}
