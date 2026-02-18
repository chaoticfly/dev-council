#!/usr/bin/env bash
# Kannan — Role Engine
# Dynamic role assignment based on task type and agent capabilities

# Role definitions: name -> required capability
declare -A ROLE_CAPABILITY=(
    [planner]="plan"
    [architect]="plan"
    [implementer]="code"
    [critic]="review"
    [debugger]="debug"
    [tester]="test"
    [verifier]="code"
)

# Role system prompts
declare -A ROLE_PROMPTS=(
    [planner]="You are a senior software architect acting as a Planner. Your job is to analyze the user's intent and break it into specific, actionable implementation tasks. For each task, describe:
1. What needs to be done (specific files, functions, or modules to change)
2. Why it needs to be done
3. Dependencies between tasks (what must happen first)

If the project context says GREENFIELD, your first tasks must be:
- Initialize the project (dependency manifest, directory structure, entry point)
- Set up build/test tooling
Then proceed with the user's actual feature request.

Output your plan as a numbered list of tasks. Be specific about file paths and function names based on the project context provided. Keep tasks small and incremental."

    [architect]="You are a senior software architect acting as an Architect. Review the proposed changes and evaluate:
1. Does this fit the existing architecture?
2. Are there better patterns to use?
3. What are the risks?
4. What edge cases should be handled?

Be specific and reference the actual codebase structure."

    [implementer]="You are a senior developer acting as an Implementer. Write the actual code changes needed. Rules:
1. Make minimal, focused changes
2. Follow existing code conventions and patterns
3. Include only the changed files
4. Output changes as unified diff format when possible
5. Do not change unrelated code
6. Write tests if the project has a test suite

For GREENFIELD projects: create complete, runnable files with proper project structure.
Include dependency manifests (go.mod, package.json, etc.), entry points, and a README.
Follow idiomatic conventions for the chosen language and framework."

    [critic]="You are a senior code reviewer acting as a Critic. Review the implementation and evaluate:
1. Correctness — does it do what was intended?
2. Safety — are there bugs, edge cases, or security issues?
3. Style — does it match the project's conventions?
4. Completeness — is anything missing?

At the end of your review, output a JSON block:
\`\`\`json
{\"verdict\": \"accept|revise|reject\", \"issues\": [{\"severity\": \"critical|major|minor\", \"description\": \"...\"}], \"summary\": \"...\"}
\`\`\`"

    [debugger]="You are a senior developer acting as a Debugger. Analyze the error or unexpected behavior. Identify:
1. Root cause
2. Why it happened
3. The fix
4. How to prevent it in the future"

    [tester]="You are a QA engineer acting as a Tester. Based on the changes made:
1. Identify what should be tested
2. Write test cases
3. Run existing tests if possible
4. Report results"

    [verifier]="You are a senior developer acting as a Verifier. Do a final check:
1. Are all changes consistent?
2. Do the changes compile/parse correctly?
3. Do tests pass?
4. Is anything missing from the implementation?"
)

# Classify roles into "doer" (writes code) vs "thinker" (plans/reviews)
declare -A ROLE_CLASS=(
    [planner]="thinker"
    [architect]="thinker"
    [implementer]="doer"
    [critic]="thinker"
    [debugger]="doer"
    [tester]="doer"
    [verifier]="thinker"
)

# Cached agent split for 2-agent mode (populated by _compute_agent_split)
_SPLIT_DOER=""
_SPLIT_THINKER=""
_SPLIT_COMPUTED=0

# Compute the doer/thinker split for 2-agent scenarios
_compute_agent_split() {
    [[ $_SPLIT_COMPUTED -eq 1 ]] && return
    _SPLIT_COMPUTED=1

    local available=()
    for name in claude codex gemini ollama; do
        agents_is_available "$name" && available+=("$name")
    done

    [[ ${#available[@]} -ne 2 ]] && return

    # Pick the best code-capable agent as doer, the other as thinker
    # Priority for doer: claude > codex > gemini > ollama (need "code" capability)
    for name in "${available[@]}"; do
        if agent_has_capability "$name" "code"; then
            _SPLIT_DOER="$name"
            break
        fi
    done

    # The other agent becomes the thinker
    for name in "${available[@]}"; do
        if [[ "$name" != "$_SPLIT_DOER" ]]; then
            _SPLIT_THINKER="$name"
            break
        fi
    done

    # Edge case: if no code-capable agent, first does everything
    if [[ -z "$_SPLIT_DOER" ]]; then
        _SPLIT_DOER="${available[0]}"
        _SPLIT_THINKER="${available[1]}"
    fi

    ui_debug "Agent split: doer=$_SPLIT_DOER thinker=$_SPLIT_THINKER"
}

# Cached role distribution for 3+ agents (populated by _compute_multi_agent_roles)
declare -A _MULTI_AGENT_ROLES=()
_MULTI_COMPUTED=0

# Distribute primary roles across different agents when 3+ are available.
# Assigns implementer first (most constrained — needs code), then critic (review),
# then planner (plan), each time preferring an agent not yet assigned.
_compute_multi_agent_roles() {
    [[ $_MULTI_COMPUTED -eq 1 ]] && return
    _MULTI_COMPUTED=1

    local -A used=()

    # 1. Implementer — needs "code", prefer best coders
    for name in claude codex gemini ollama; do
        if agents_is_available "$name" && agent_has_capability "$name" "code" && [[ -z "${used[$name]:-}" ]]; then
            _MULTI_AGENT_ROLES[implementer]="$name"
            used[$name]=1
            break
        fi
    done

    # 2. Critic — needs "review", prefer agents not already assigned
    for name in ollama gemini codex claude; do
        if agents_is_available "$name" && agent_has_capability "$name" "review" && [[ -z "${used[$name]:-}" ]]; then
            _MULTI_AGENT_ROLES[critic]="$name"
            used[$name]=1
            break
        fi
    done

    # 3. Planner — needs "plan", prefer agents not already assigned
    for name in gemini ollama codex claude; do
        if agents_is_available "$name" && agent_has_capability "$name" "plan" && [[ -z "${used[$name]:-}" ]]; then
            _MULTI_AGENT_ROLES[planner]="$name"
            used[$name]=1
            break
        fi
    done

    # Fallback: if any primary role still unassigned, use best available (may double up)
    # NOTE: must NOT use variable name "role" here — bash dynamic scoping would
    # clobber the caller's $role in role_assign().
    local _r
    for _r in implementer critic planner; do
        if [[ -z "${_MULTI_AGENT_ROLES[$_r]:-}" ]]; then
            local _cap="${ROLE_CAPABILITY[$_r]:-general}"
            _MULTI_AGENT_ROLES[$_r]="$(agent_best_for "$_cap")"
        fi
    done

    ui_debug "Multi-agent roles: impl=${_MULTI_AGENT_ROLES[implementer]} critic=${_MULTI_AGENT_ROLES[critic]} planner=${_MULTI_AGENT_ROLES[planner]}"
}

# Assign the best agent for a role
# Checks config for pinned assignment first, then agent-count-aware logic
role_assign() {
    local role="$1"

    # Check if role is pinned in config
    local pinned
    pinned="$(config_get_role_agent "$role")"
    if [[ -n "$pinned" ]]; then
        if agents_is_available "$pinned"; then
            echo "$pinned"
            return
        else
            ui_warn "Config pins $role to '$pinned' but it's not available — falling back to dynamic"
        fi
    fi

    local agent_count
    agent_count="$(agents_available_count)"

    # 1 agent: it does everything
    if [[ "$agent_count" -eq 1 ]]; then
        agent_best_for "general"
        return
    fi

    # 2 agents: split into doer (code) and thinker (plan/review)
    if [[ "$agent_count" -eq 2 ]]; then
        _compute_agent_split
        local role_class="${ROLE_CLASS[$role]:-doer}"
        if [[ "$role_class" == "doer" ]]; then
            echo "$_SPLIT_DOER"
        else
            echo "$_SPLIT_THINKER"
        fi
        return
    fi

    # 3+ agents: distribute primary roles across different agents
    _compute_multi_agent_roles
    if [[ -n "${_MULTI_AGENT_ROLES[$role]:-}" ]]; then
        echo "${_MULTI_AGENT_ROLES[$role]}"
        return
    fi

    # Other roles (debugger, tester, etc.): fall back to capability match
    local required_cap="${ROLE_CAPABILITY[$role]:-general}"
    agent_best_for "$required_cap"
}

# Get system prompt for a role
role_prompt() {
    local role="$1"
    echo "${ROLE_PROMPTS[$role]:-You are a helpful AI assistant.}"
}

# Infer which role a task needs based on keywords
role_infer() {
    local task_description="$1"
    local desc_lower
    desc_lower="$(echo "$task_description" | tr '[:upper:]' '[:lower:]')"

    case "$desc_lower" in
        *plan*|*break*down*|*decompose*|*analyze*what*) echo "planner" ;;
        *architect*|*design*|*structure*)                echo "architect" ;;
        *implement*|*write*|*create*|*add*|*modify*|*change*|*update*|*remove*|*delete*) echo "implementer" ;;
        *review*|*critique*|*check*|*evaluate*)         echo "critic" ;;
        *debug*|*fix*|*error*|*bug*|*crash*)            echo "debugger" ;;
        *test*|*coverage*|*spec*)                        echo "tester" ;;
        *verify*|*validate*|*confirm*)                   echo "verifier" ;;
        *)                                               echo "implementer" ;;
    esac
}

# Build context-enriched prompt for an agent given a role and project
role_build_prompt() {
    local role="$1" project_dir="$2" task="$3"
    local project_summary
    project_summary="$(repo_summary "$project_dir")"

    # Load memory context if available
    local memory_context
    memory_context="$(memory_load_context "$project_dir")"

    if [[ -n "$memory_context" ]]; then
        cat <<EOF
## Project Context
$project_summary

## Memory (past sessions)
$memory_context

## Task
$task
EOF
    else
        cat <<EOF
## Project Context
$project_summary

## Task
$task
EOF
    fi
}
