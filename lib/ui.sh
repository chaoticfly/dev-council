#!/usr/bin/env bash
# Kannan — UI / Display functions
# Uses gum if available, falls back to plain terminal output

# Colors (ANSI)
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_BLUE='\033[0;34m'
_MAGENTA='\033[0;35m'
_CYAN='\033[0;36m'
_BOLD='\033[1m'
_DIM='\033[2m'
_RESET='\033[0m'

# Agent colors
declare -A AGENT_COLORS=(
    [claude]="$_MAGENTA"
    [codex]="$_GREEN"
    [gemini]="$_BLUE"
    [ollama]="$_CYAN"
)

# Role colors
declare -A ROLE_COLORS=(
    [planner]="$_CYAN"
    [architect]="$_BLUE"
    [implementer]="$_GREEN"
    [critic]="$_YELLOW"
    [debugger]="$_RED"
    [tester]="$_MAGENTA"
    [verifier]="$_BOLD"
)

_use_gum() { has_cmd gum; }

ui_banner() {
    echo ""
    if _use_gum; then
        gum style --border rounded --padding "0 2" --border-foreground 141 \
            "KANNAN v${KANNAN_VERSION}" "Adaptive Multi-Agent Development"
    else
        echo -e "${_BOLD}=== KANNAN v${KANNAN_VERSION} ===${_RESET}"
        echo -e "${_DIM}Adaptive Multi-Agent Development${_RESET}"
    fi
    echo ""
}

ui_info() { echo -e "${_BLUE}[info]${_RESET} $*"; }
ui_success() { echo -e "${_GREEN}[ok]${_RESET} $*"; }
ui_warn() { echo -e "${_YELLOW}[warn]${_RESET} $*"; }
ui_error() { echo -e "${_RED}[error]${_RESET} $*" >&2; }
ui_debug() { [[ "${KANNAN_DEBUG:-}" == "1" ]] && echo -e "${_DIM}[debug] $*${_RESET}" >&2; }

# Show agent → role assignment (writes to stderr so it's visible inside subshells)
ui_assign() {
    local agent="$1" role="$2"
    local ac="${AGENT_COLORS[$agent]:-$_RESET}"
    local rc="${ROLE_COLORS[$role]:-$_DIM}"
    echo -e "  ${ac}${_BOLD}${agent}${_RESET} ${_DIM}→${_RESET} ${rc}${role}${_RESET}" >&2
}

# Display a table of all role → agent assignments
ui_assignment_table() {
    echo ""
    echo -e "${_BOLD}Agent Assignments${_RESET}"
    echo -e "${_DIM}──────────────────────────────────${_RESET}"
    for role in planner implementer critic; do
        local agent
        agent="$(role_assign "$role")"
        if [[ -n "$agent" ]]; then
            local ac="${AGENT_COLORS[$agent]:-$_RESET}"
            local rc="${ROLE_COLORS[$role]:-$_DIM}"
            printf "  ${rc}%-14s${_RESET} ${ac}${_BOLD}%s${_RESET}\n" "$role" "$agent"
        else
            printf "  ${_DIM}%-14s (none)${_RESET}\n" "$role"
        fi
    done
    echo ""
}

ui_phase() {
    echo ""
    echo -e "${_BOLD}>> $*${_RESET}"
}

# Print agent output with colored prefix
ui_agent_output() {
    local agent="$1" role="$2" text="$3"
    local ac="${AGENT_COLORS[$agent]:-$_RESET}"
    local rc="${ROLE_COLORS[$role]:-$_DIM}"
    echo -e "${ac}[${agent}${_RESET}${_DIM}:${rc}${role}${_RESET}${ac}]${_RESET} ${text}"
}

# Stream agent output line by line with prefix
ui_stream_agent() {
    local agent="$1" role="$2"
    while IFS= read -r line; do
        ui_agent_output "$agent" "$role" "$line"
    done
}

# Prompt user for input
ui_prompt() {
    local prompt_text="${1:-Enter your intent}"
    if _use_gum; then
        gum input --placeholder "$prompt_text" --width 80
    else
        echo -en "${_BOLD}> ${_RESET}"
        read -r REPLY
        echo "$REPLY"
    fi
}

# Confirm yes/no
ui_confirm() {
    local question="$1"
    if _use_gum; then
        gum confirm "$question"
    else
        echo -en "${_YELLOW}$question [y/N]${_RESET} "
        read -r answer
        [[ "$answer" =~ ^[Yy] ]]
    fi
}

# Show a spinner while a command runs
ui_spin() {
    local msg="$1"
    shift
    if _use_gum; then
        gum spin --spinner dot --title "$msg" -- "$@"
    else
        echo -en "${_DIM}$msg...${_RESET} "
        "$@" &>/dev/null
        echo -e "${_GREEN}done${_RESET}"
    fi
}

# Display a task list
ui_task_status() {
    local status="$1" task="$2"
    case "$status" in
        pending)   echo -e "  ${_DIM}○${_RESET} $task" ;;
        running)   echo -e "  ${_YELLOW}◉${_RESET} $task" ;;
        done)      echo -e "  ${_GREEN}✓${_RESET} $task" ;;
        failed)    echo -e "  ${_RED}✗${_RESET} $task" ;;
        review)    echo -e "  ${_CYAN}◎${_RESET} $task" ;;
    esac
}

# Separator line
ui_separator() {
    local cols="${COLUMNS:-80}"
    printf '%*s\n' "$cols" '' | tr ' ' '─'
}

# Greenfield bootstrap — ask user what they're building
ui_greenfield_bootstrap() {
    echo ""
    if _use_gum; then
        gum style --foreground 212 --bold "New project detected — let's set things up."
    else
        echo -e "${_BOLD}${_MAGENTA}New project detected — let's set things up.${_RESET}"
    fi
    echo ""

    # Language
    local language
    if _use_gum; then
        language="$(gum choose --header "Primary language?" \
            "Go" "TypeScript" "Python" "Rust" "JavaScript" "Java" "Ruby" "C/C++" "Other")"
        if [[ "$language" == "Other" ]]; then
            language="$(gum input --placeholder "Enter language...")"
        fi
    else
        echo -e "${_BOLD}Primary language?${_RESET}"
        echo "  1) Go  2) TypeScript  3) Python  4) Rust  5) JavaScript  6) Java  7) Ruby  8) Other"
        echo -en "${_BOLD}> ${_RESET}"
        read -r choice
        case "$choice" in
            1) language="Go" ;; 2) language="TypeScript" ;; 3) language="Python" ;;
            4) language="Rust" ;; 5) language="JavaScript" ;; 6) language="Java" ;;
            7) language="Ruby" ;; *) language="$choice" ;;
        esac
    fi

    # Framework
    local framework
    if _use_gum; then
        framework="$(gum input --placeholder "Framework? (e.g., React, FastAPI, Gin — or leave blank for none)" --width 80)"
    else
        echo -en "${_BOLD}Framework?${_RESET} ${_DIM}(e.g., React, FastAPI, Gin — or blank for none)${_RESET} "
        read -r framework
    fi
    framework="${framework:-none}"

    # Description
    local description
    if _use_gum; then
        description="$(gum input --placeholder "What are you building? (brief description)" --width 80)"
    else
        echo -en "${_BOLD}What are you building?${_RESET} "
        read -r description
    fi

    echo ""
    ui_success "Got it: $language / $framework — $description"
    echo ""

    # Return values via global vars (bash has no multi-return)
    _GREENFIELD_LANGUAGE="$language"
    _GREENFIELD_FRAMEWORK="$framework"
    _GREENFIELD_DESCRIPTION="$description"
}

# Display token usage summary
ui_token_summary() {
    local has_data=0
    for agent in "${!TOKEN_CALLS[@]}"; do
        [[ ${TOKEN_CALLS[$agent]:-0} -gt 0 ]] && has_data=1 && break
    done
    [[ $has_data -eq 0 ]] && return

    echo ""
    echo -e "${_BOLD}Token Usage${_RESET}"
    ui_separator

    local grand_input=0 grand_output=0 grand_calls=0

    for agent in claude codex gemini ollama; do
        local calls="${TOKEN_CALLS[$agent]:-0}"
        [[ $calls -eq 0 ]] && continue

        local input="${TOKEN_INPUT[$agent]:-0}"
        local output="${TOKEN_OUTPUT[$agent]:-0}"
        local total=$((input + output))
        local ac="${AGENT_COLORS[$agent]:-$_RESET}"

        printf "  ${ac}%-10s${_RESET} %d call(s)  ${_DIM}in:${_RESET}%-8s ${_DIM}out:${_RESET}%-8s ${_DIM}total:${_RESET}%s\n" \
            "$agent" "$calls" "$input" "$output" "$total"

        grand_input=$((grand_input + input))
        grand_output=$((grand_output + output))
        grand_calls=$((grand_calls + calls))
    done

    echo -e "  ${_DIM}──────────────────────────────────────────────────${_RESET}"
    printf "  ${_BOLD}%-10s${_RESET} %d call(s)  ${_DIM}in:${_RESET}%-8s ${_DIM}out:${_RESET}%-8s ${_DIM}total:${_RESET}%s\n" \
        "total" "$grand_calls" "$grand_input" "$grand_output" "$((grand_input + grand_output))"
    echo ""
}
