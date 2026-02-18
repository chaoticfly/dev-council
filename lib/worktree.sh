#!/usr/bin/env bash
# Kannan — Git Worktree Management
# Provides isolated branches for unsupervised agent edits

KANNAN_WORK_DIR=""      # Current worktree path (or project_dir if no git)
KANNAN_WORK_BRANCH=""   # Branch name for the worktree

# Create an isolated worktree for a task
# Sets KANNAN_WORK_DIR and KANNAN_WORK_BRANCH globals
worktree_create() {
    local project_dir="$1"
    local intent="$2"

    KANNAN_WORK_DIR=""
    KANNAN_WORK_BRANCH=""

    if [[ ! -d "$project_dir/.git" ]]; then
        ui_warn "Not a git repo — running directly in project directory"
        KANNAN_WORK_DIR="$project_dir"
        return 0
    fi

    local branch_name="kannan/$(slugify "$intent")-$(date +%s)"
    local worktree_base
    worktree_base="$(mktemp -d)"
    local worktree_path="$worktree_base/work"

    if ! git -C "$project_dir" worktree add "$worktree_path" -b "$branch_name" 2>/dev/null; then
        ui_warn "Could not create worktree — running directly in project directory"
        KANNAN_WORK_DIR="$project_dir"
        return 0
    fi

    KANNAN_WORK_DIR="$worktree_path"
    KANNAN_WORK_BRANCH="$branch_name"
    ui_info "Branch: $branch_name"
}

# Check if the worktree has uncommitted changes
worktree_has_changes() {
    [[ -z "$KANNAN_WORK_DIR" ]] && return 1
    local status
    status="$(git -C "$KANNAN_WORK_DIR" status --porcelain 2>/dev/null)"
    [[ -n "$status" ]]
}

# Commit all changes in the worktree
worktree_commit() {
    local intent="$1"
    [[ -z "$KANNAN_WORK_DIR" ]] && return 1

    git -C "$KANNAN_WORK_DIR" add -A 2>/dev/null
    git -C "$KANNAN_WORK_DIR" commit -m "kannan: $intent" 2>/dev/null
}

# Show diff between main branch and worktree branch
worktree_diff() {
    local project_dir="$1"
    [[ -z "$KANNAN_WORK_BRANCH" ]] && return 0

    # Get the base branch (what the worktree was created from)
    local base_branch
    base_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ -z "$base_branch" ]] && base_branch="main"

    git -C "$project_dir" diff "${base_branch}...${KANNAN_WORK_BRANCH}" 2>/dev/null
}

# Show summary of changed files
worktree_stat() {
    local project_dir="$1"
    [[ -z "$KANNAN_WORK_BRANCH" ]] && return 0

    local base_branch
    base_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ -z "$base_branch" ]] && base_branch="main"

    git -C "$project_dir" diff --stat "${base_branch}...${KANNAN_WORK_BRANCH}" 2>/dev/null
}

# Merge the worktree branch into the current branch
worktree_merge() {
    local project_dir="$1"
    [[ -z "$KANNAN_WORK_BRANCH" ]] && return 1

    git -C "$project_dir" merge "$KANNAN_WORK_BRANCH" 2>/dev/null
}

# Remove the worktree (branch persists for later review/merge)
worktree_cleanup() {
    local project_dir="$1"

    [[ -z "$KANNAN_WORK_DIR" || "$KANNAN_WORK_DIR" == "$project_dir" ]] && return 0

    git -C "$project_dir" worktree remove "$KANNAN_WORK_DIR" --force 2>/dev/null
    # Clean up the temp directory parent
    local parent
    parent="$(dirname "$KANNAN_WORK_DIR")"
    rmdir "$parent" 2>/dev/null

    KANNAN_WORK_DIR=""
}
