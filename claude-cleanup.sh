#!/usr/bin/env bash
set -euo pipefail

CLAUDE_JSON="$HOME/.claude.json"
CLAUDE_PROJECTS="$HOME/.claude/projects"

# --- Dependency check ---
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed." >&2
    echo "  brew install jq  (macOS)" >&2
    echo "  apt install jq   (Debian/Ubuntu)" >&2
    exit 1
fi

# --- Collect orphaned JSON entries ---
orphaned_paths=()
all_encoded=()
if [[ -f "$CLAUDE_JSON" ]] && jq -e '.projects' "$CLAUDE_JSON" &>/dev/null; then
    while IFS= read -r path; do
        encoded="${path//\//-}"
        all_encoded+=("$encoded")
        if [[ ! -d "$path" ]]; then
            orphaned_paths+=("$path")
        fi
    done < <(jq -r '.projects | keys[]' "$CLAUDE_JSON")
fi

# Helper: check if a value exists in an array
contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# --- Collect orphaned project directories ---
# A dir is orphaned if:
#   - it doesn't match ANY known path from claude.json, OR
#   - it matches an orphaned path (path no longer exists on disk)
orphaned_dirs=()
if [[ -d "$CLAUDE_PROJECTS" ]]; then
    for dir in "$CLAUDE_PROJECTS"/*/; do
        [[ -d "$dir" ]] || continue
        dname="$(basename "$dir")"
        if ! contains "$dname" "${all_encoded[@]+"${all_encoded[@]}"}"; then
            # Dir doesn't match any known JSON path — extra orphan
            orphaned_dirs+=("$dname")
        else
            # Dir matches a known path — check if that path is orphaned
            for path in "${orphaned_paths[@]+"${orphaned_paths[@]}"}"; do
                if [[ "${path//\//-}" == "$dname" ]]; then
                    orphaned_dirs+=("$dname")
                    break
                fi
            done
        fi
    done
fi

# --- Display ---
total_count=$(( ${#orphaned_paths[@]} + ${#orphaned_dirs[@]} ))

if (( total_count == 0 )); then
    echo "No orphaned Claude Code project data found."
    exit 0
fi

echo "Scanning for orphaned Claude Code project data..."
echo

if (( ${#orphaned_paths[@]} > 0 )); then
    echo "Orphaned ~/.claude.json entries (path no longer exists):"
    for path in "${orphaned_paths[@]}"; do
        json_size=$(jq --arg p "$path" '.projects[$p] | tostring | length' "$CLAUDE_JSON")
        if (( json_size >= 1024 )); then
            size_str="~$(( json_size / 1024 ))K in JSON"
        else
            size_str="~${json_size}B in JSON"
        fi
        printf "  %-60s (%s)\n" "$path" "$size_str"
    done
    echo
fi

total_bytes=0
if (( ${#orphaned_dirs[@]} > 0 )); then
    echo "Orphaned ~/.claude/projects/ directories:"
    for dname in "${orphaned_dirs[@]}"; do
        dir_size=$(du -sh "$CLAUDE_PROJECTS/$dname" 2>/dev/null | cut -f1)
        dir_bytes=$(du -sk "$CLAUDE_PROJECTS/$dname" 2>/dev/null | cut -f1)
        total_bytes=$(( total_bytes + dir_bytes ))
        printf "  %-60s %s\n" "$dname" "$dir_size"
    done
    echo
fi

# Format total reclaimable
if (( total_bytes >= 1048576 )); then
    total_human="~$(( total_bytes / 1048576 ))G"
elif (( total_bytes >= 1024 )); then
    total_human="~$(( total_bytes / 1024 ))M"
else
    total_human="~${total_bytes}K"
fi

echo "Found $total_count orphaned entries. Total reclaimable: $total_human"

# --- Prune mode ---
if [[ "${1:-}" != "--prune" ]]; then
    echo
    echo "Run with --prune to clean up."
    exit 0
fi

echo
read -rp "Remove $total_count orphaned entries? (y/N) " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
fi

# Back up claude.json
if [[ -f "$CLAUDE_JSON" ]]; then
    cp "$CLAUDE_JSON" "$CLAUDE_JSON.bak"
    echo "Backed up ~/.claude.json to ~/.claude.json.bak"
fi

# Remove orphaned directories
removed_dirs=0
for dname in "${orphaned_dirs[@]}"; do
    target="$CLAUDE_PROJECTS/$dname"
    if [[ -d "$target" ]]; then
        rm -rf "$target"
        echo "Removed ~/.claude/projects/$dname"
        removed_dirs=$(( removed_dirs + 1 ))
    fi
done

# Remove orphaned JSON entries
if (( ${#orphaned_paths[@]} > 0 )); then
    filter='.'
    for path in "${orphaned_paths[@]}"; do
        filter="$filter | del(.projects[$(jq -n --arg p "$path" '$p')])"
    done
    jq "$filter" "$CLAUDE_JSON.bak" > "$CLAUDE_JSON"
    echo "Removed ${#orphaned_paths[@]} entries from ~/.claude.json"
fi

echo "Done. Cleaned up $total_human."
