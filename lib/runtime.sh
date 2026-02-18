#!/usr/bin/env bash
# Kannan — Runtime Orchestration
# The main execution loop: intent → plan → execute → critique → patch
# Agents run in the foreground — user sees output live via tee.
# Kannan reads report files after each agent completes.

# Record session to memory after pipeline completes
_runtime_record_memory() {
    local project_dir="$1"
    local intent="$2"

    local verdict iterations issues_json tokens
    verdict="$(consensus_meta_get "$project_dir" "verdict")"
    iterations="$(consensus_meta_get "$project_dir" "iterations")"
    issues_json="$(consensus_meta_get "$project_dir" "issues")"
    tokens="$(tokens_total)"

    [[ -z "$verdict" ]] && verdict="accept"
    [[ -z "$iterations" ]] && iterations="1"
    [[ -z "$issues_json" || "$issues_json" == "" ]] && issues_json="[]"

    # Build roles JSON from what we can determine
    local planner_agent impl_agent critic_agent
    planner_agent="$(role_assign planner)"
    impl_agent="$(consensus_meta_get "$project_dir" "impl_agent")"
    critic_agent="$(consensus_meta_get "$project_dir" "critic_agent")"
    [[ -z "$impl_agent" ]] && impl_agent="$(role_assign implementer)"

    local roles_json="{}"
    if has_cmd jq; then
        roles_json="$(jq -n -c \
            --arg planner "$planner_agent" \
            --arg implementer "$impl_agent" \
            --arg critic "$critic_agent" \
            '{planner: $planner, implementer: $implementer, critic: $critic} | with_entries(select(.value != ""))'
        )"
    fi

    # Capture per-agent token breakdown
    local token_usage
    token_usage="$(tokens_snapshot_json)"

    memory_record_session "$project_dir" "$intent" "$roles_json" "$verdict" "$iterations" "$issues_json" "$tokens" "$token_usage"

    # Also record implementer stats on final verdict
    if [[ -n "$impl_agent" && -n "$verdict" ]]; then
        memory_update_stats "$project_dir" "$impl_agent" "implementer" "$verdict"
    fi
    if [[ -n "$planner_agent" ]]; then
        memory_update_stats "$project_dir" "$planner_agent" "planner" "$verdict"
    fi
}

# Decompose user intent into tasks using a planner agent
# Args: project_dir, intent, report_file
runtime_decompose() {
    local project_dir="$1"
    local intent="$2"
    local report_file="$3"

    local planner_agent
    planner_agent="$(role_assign planner)"

    if [[ -z "$planner_agent" ]]; then
        # No planner available — treat entire intent as single task
        echo "1. $intent" | tee "$report_file"
        return
    fi

    ui_assign "$planner_agent" "planner"

    local system_prompt
    system_prompt="$(role_prompt planner)"
    local user_prompt
    user_prompt="$(role_build_prompt planner "$project_dir" "$intent")"

    ui_agent_output "$planner_agent" "planner" "Breaking down task..."
    echo ""

    adapter_execute "$planner_agent" "$system_prompt" "$user_prompt" "$report_file"

    if [[ ! -s "$report_file" ]]; then
        ui_warn "Planner returned empty response — treating as single task"
        echo "1. $intent" > "$report_file"
    fi
}

# Execute a single task with the appropriate role/agent
# Args: project_dir, task_description, task_context, report_file
runtime_execute_task() {
    local project_dir="$1"
    local task_description="$2"
    local task_context="${3:-}"
    local report_file="$4"

    local role
    role="$(role_infer "$task_description")"
    local agent
    agent="$(role_assign "$role")"

    if [[ -z "$agent" ]]; then
        ui_error "No agent available for role: $role"
        return 1
    fi

    ui_assign "$agent" "$role"
    ui_agent_output "$agent" "$role" "Working on: $task_description"
    echo ""

    # Build full prompt: intent + context (plan) for the agent
    local full_task="$task_description"
    if [[ -n "$task_context" ]]; then
        full_task="${task_description}

${task_context}"
    fi

    local system_prompt
    system_prompt="$(role_prompt "$role")"
    local user_prompt
    user_prompt="$(role_build_prompt "$role" "$project_dir" "$full_task")"

    # Add relevant file contents to context
    local model_file="$project_dir/$KANNAN_DIR/project_model.json"
    if [[ -f "$model_file" ]]; then
        local relevant_files
        relevant_files="$(jq -r '.entry_points[]? // empty' "$model_file" 2>/dev/null)"
        if [[ -n "$relevant_files" ]]; then
            user_prompt+="

## Key Files
"
            while IFS= read -r f; do
                if [[ -f "$project_dir/$f" ]]; then
                    local content
                    content="$(head -100 "$project_dir/$f")"
                    user_prompt+="
### $f
\`\`\`
$content
\`\`\`
"
                fi
            done <<< "$relevant_files"
        fi
    fi

    adapter_execute "$agent" "$system_prompt" "$user_prompt" "$report_file"
    local result=$?

    if [[ $result -ne 0 || ! -s "$report_file" ]]; then
        ui_error "Agent returned empty response"
        return 1
    fi

    echo ""
}

# Present worktree results: commit, show diff, print merge instructions
_runtime_present_changes() {
    local project_dir="$1"
    local intent="$2"

    if ! worktree_has_changes; then
        ui_info "No file changes were made"
        return 0
    fi

    # Determine the base branch (what the worktree branched from)
    local base_branch
    base_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ -z "$base_branch" ]] && base_branch="main"

    worktree_commit "$intent"

    echo ""
    echo -e "${_BOLD}Changes${_RESET}"
    echo -e "${_DIM}──────────────────────────────────${_RESET}"
    worktree_stat "$project_dir"

    echo ""
    echo -e "${_BOLD}Branch: ${_GREEN}$KANNAN_WORK_BRANCH${_RESET}"
    echo ""
    echo -e "${_BOLD}Next steps:${_RESET}"
    echo -e "  ${_CYAN}git diff ${base_branch}...${KANNAN_WORK_BRANCH}${_RESET}      # review changes"
    echo -e "  ${_GREEN}git merge ${KANNAN_WORK_BRANCH}${_RESET}   # apply to ${base_branch}"
    echo -e "  ${_RED}git branch -D ${KANNAN_WORK_BRANCH}${_RESET}   # discard"
    echo ""
}

# Run verification (tests) if possible
runtime_verify() {
    local project_dir="$1"
    local model_file="$project_dir/$KANNAN_DIR/project_model.json"

    if [[ ! -f "$model_file" ]]; then
        return 0
    fi

    local test_cmd
    test_cmd="$(jq -r '.test_command // ""' "$model_file" 2>/dev/null)"

    if [[ -z "$test_cmd" ]]; then
        ui_info "No test command detected — skipping verification"
        return 0
    fi

    if ui_confirm "Run tests ($test_cmd)?"; then
        ui_phase "Running verification..."
        if (cd "$project_dir" && eval "$test_cmd"); then
            ui_success "Tests passed"
            return 0
        else
            ui_warn "Tests failed"
            return 1
        fi
    fi
    return 0
}

# Main interactive loop
runtime_loop() {
    local project_dir="$1"

    while true; do
        local intent
        intent="$(ui_prompt "What would you like to do?")"

        # Handle exit commands
        case "$intent" in
            ""|quit|exit|q)
                ui_info "Goodbye!"
                break
                ;;
        esac

        ui_separator
        ui_phase "Processing: $intent"
        ui_assignment_table

        # Create isolated worktree for this task
        worktree_create "$project_dir" "$intent"
        echo ""

        # Step 1: Decompose intent into tasks
        ui_task_status "running" "Planning"
        echo ""
        local plan_file
        plan_file="$(mktemp)"
        runtime_decompose "$project_dir" "$intent" "$plan_file"
        local plan
        plan="$(cat "$plan_file")"
        rm -f "$plan_file"

        if [[ -z "$plan" ]]; then
            ui_error "Could not decompose intent"
            worktree_cleanup "$project_dir"
            continue
        fi

        echo ""
        if ! ui_confirm "Proceed with this plan?"; then
            ui_info "Skipped"
            worktree_cleanup "$project_dir"
            continue
        fi

        ui_task_status "done" "Planning"

        # Step 2: Execute tasks (agent works in worktree)
        ui_task_status "running" "Implementing"
        echo ""
        local impl_file
        impl_file="$(mktemp)"
        runtime_execute_task "$project_dir" "$intent" "Plan:
$plan" "$impl_file"
        local exec_result=$?
        local implementation
        implementation="$(cat "$impl_file")"
        rm -f "$impl_file"

        if [[ $exec_result -ne 0 || -z "$implementation" ]]; then
            ui_task_status "failed" "Implementing"
            ui_error "Implementation failed"
            worktree_cleanup "$project_dir"
            continue
        fi
        ui_task_status "done" "Implementing"

        # Step 3: Critique/consensus loop
        ui_task_status "running" "Reviewing"
        consensus_run "$project_dir" "$implementation" "$intent"
        local consensus_result=$?
        ui_task_status "done" "Reviewing"

        if [[ $consensus_result -ne 0 ]]; then
            ui_warn "Implementation was rejected by critic"
            if ! ui_confirm "Keep changes anyway?"; then
                local discard_branch="$KANNAN_WORK_BRANCH"
                worktree_cleanup "$project_dir"
                [[ -n "$discard_branch" ]] && git -C "$project_dir" branch -D "$discard_branch" 2>/dev/null
                ui_info "Discarded"
                continue
            fi
        fi

        # Step 4: Commit and present changes
        ui_separator
        _runtime_present_changes "$project_dir" "$intent"

        # Save branch name before cleanup clears it
        local result_branch="$KANNAN_WORK_BRANCH"

        # Step 5: Cleanup worktree (branch persists for review/merge)
        worktree_cleanup "$project_dir"

        # Step 6: Optionally merge into current branch
        if [[ -n "$result_branch" ]]; then
            echo ""
            if ui_confirm "Merge into current branch?"; then
                git -C "$project_dir" merge "$result_branch" 2>/dev/null
                ui_success "Merged $result_branch"
                git -C "$project_dir" branch -d "$result_branch" 2>/dev/null
            fi
        fi

        # Step 7: Optionally verify
        runtime_verify "$project_dir"

        # Step 8: Record session to memory
        _runtime_record_memory "$project_dir" "$intent"

        # Step 9: Show token usage
        ui_token_summary

        ui_separator
        echo ""
    done
}

# Single-shot execution (non-interactive, for -p flag)
runtime_once() {
    local project_dir="$1"
    local intent="$2"

    ui_separator
    ui_phase "Processing: $intent"
    ui_assignment_table

    # Create isolated worktree for this task
    worktree_create "$project_dir" "$intent"
    echo ""

    # Step 1: Decompose
    ui_task_status "running" "Planning"
    echo ""
    local plan_file
    plan_file="$(mktemp)"
    runtime_decompose "$project_dir" "$intent" "$plan_file"
    local plan
    plan="$(cat "$plan_file")"
    rm -f "$plan_file"

    if [[ -z "$plan" ]]; then
        ui_error "Could not decompose intent"
        worktree_cleanup "$project_dir"
        return 1
    fi

    echo ""
    ui_task_status "done" "Planning"

    # Step 2: Execute (agent works in worktree)
    ui_task_status "running" "Implementing"
    echo ""
    local impl_file
    impl_file="$(mktemp)"
    runtime_execute_task "$project_dir" "$intent" "Plan:
$plan" "$impl_file"
    local exec_result=$?
    local implementation
    implementation="$(cat "$impl_file")"
    rm -f "$impl_file"

    if [[ $exec_result -ne 0 || -z "$implementation" ]]; then
        ui_task_status "failed" "Implementing"
        ui_error "Implementation failed"
        worktree_cleanup "$project_dir"
        ui_token_summary
        return 1
    fi
    ui_task_status "done" "Implementing"

    # Step 3: Critique
    ui_task_status "running" "Reviewing"
    consensus_run "$project_dir" "$implementation" "$intent"
    local consensus_result=$?
    ui_task_status "done" "Reviewing"

    # Step 4: Commit and present changes
    ui_separator
    _runtime_present_changes "$project_dir" "$intent"

    # Step 5: Cleanup worktree (branch persists for review/merge)
    worktree_cleanup "$project_dir"

    # Step 6: Record session to memory
    _runtime_record_memory "$project_dir" "$intent"

    # Step 7: Token usage
    ui_token_summary

    return $consensus_result
}
