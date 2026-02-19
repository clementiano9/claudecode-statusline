#!/bin/bash
#
# PAI Statusline - Customizable status display for Claude Code
#
# CUSTOMIZATION:
#   - This script sources ${PAI_DIR}/.env for API keys and configuration
#   - Set PAI_SIMPLE_COLORS=1 in settings.json env for basic ANSI colors
#     (fixes display issues on some terminals)
#   - To add features requiring API keys (e.g., quotes), add keys to .env
#   - Comment out any printf lines you don't want displayed
#
# LINES DISPLAYED:
#   1. Greeting: DA name, model, directory, capabilities count
#   2. MCPs: Active MCP servers with names
#   3. Tokens: Daily usage and cost (requires ccusage)
#
# ENVIRONMENT VARIABLES (set in settings.json env section):
#   DA            - Your assistant's name (default: "Assistant")
#   DA_COLOR      - Name color: purple|blue|green|cyan|yellow|red|orange
#   PAI_SIMPLE_COLORS - Set to "1" to use basic terminal colors
#

# Source .env for API keys and custom configuration
claude_env="${PAI_DIR:-$HOME/.claude}/.env"
[ -f "$claude_env" ] && source "$claude_env"

# Read JSON input from stdin
input=$(cat)

# Get Digital Assistant configuration from environment
DA_NAME="${DA:-Assistant}"  # Assistant name
DA_COLOR="${DA_COLOR:-purple}"  # Color for the assistant name

# Extract data from JSON input
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
model_name=$(echo "$input" | jq -r '.model.display_name')
cc_version=$(echo "$input" | jq -r '.version // "unknown"')

# Get directory name
dir_name=$(basename "$current_dir")

# Extract session-specific token and cost data
session_input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
session_output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
session_cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# Extract current context window usage
context_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
current_usage=$(echo "$input" | jq '.context_window.current_usage')

# Calculate session totals
session_total_tokens=$((session_input_tokens + session_output_tokens))
# Format with k notation (e.g., 48k instead of 48,000)
if [ $session_total_tokens -ge 1000 ]; then
    session_tokens_display=$(awk "BEGIN {printf \"%.0fk\", $session_total_tokens/1000}")
else
    session_tokens_display="$session_total_tokens"
fi
session_cost_display=$(printf "\$%.2f" "$session_cost_usd" 2>/dev/null || echo "\$$session_cost_usd")

# Calculate context usage with system overhead estimate
current_usage=$(echo "$input" | jq '.context_window.current_usage')

if [ "$current_usage" != "null" ]; then
    # Get current context from last API call
    context_input=$(echo "$current_usage" | jq -r '.input_tokens // 0')
    cache_creation=$(echo "$current_usage" | jq -r '.cache_creation_input_tokens // 0')
    cache_read=$(echo "$current_usage" | jq -r '.cache_read_input_tokens // 0')

    # Base context from API call (includes cached system components)
    base_context=$((context_input + cache_creation + cache_read))

    # Calculate autocompact buffer based on CLAUDE_CODE_MAX_OUTPUT_TOKENS
    # Formula: buffer = max_output + 10000 + max(0, (max_output - 32000) * 3/32)
    # Default max_output is 32000 if not set
    max_output_tokens=${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-32000}
    if [ $max_output_tokens -gt 32000 ]; then
        # Extra buffer for higher max output: (max_output - 32000) * 3/32
        extra_buffer=$(( (max_output_tokens - 32000) * 3 / 32 ))
        autocompact_buffer=$((max_output_tokens + 10000 + extra_buffer))
    else
        # Base buffer for 32k or less
        autocompact_buffer=$((max_output_tokens + 10000))
    fi

    # Add autocompact buffer (reserved space counted in /context)
    # The base_context already includes system/tools/MCP/agents/memory via cache
    estimated_context=$((base_context + autocompact_buffer))

    # Cap at context window size
    if [ $estimated_context -gt $context_window_size ]; then
        estimated_context=$context_window_size
    fi

    context_percent=$((estimated_context * 100 / context_window_size))

    # Format: "138k/200k tokens (69%)"
    context_total_k=$(awk "BEGIN {printf \"%.0fk\", $estimated_context/1000}")
    context_size_k=$(awk "BEGIN {printf \"%.0fk\", $context_window_size/1000}")
    context_display="${context_total_k}/${context_size_k} tokens (${context_percent}%%)"
else
    context_display="N/A"
fi

# Get git branch + status for current directory
git_branch=""
git_marker=""
if git -C "$current_dir" rev-parse --git-dir > /dev/null 2>&1; then
    git_branch=$(git -C "$current_dir" symbolic-ref --short HEAD 2>/dev/null || echo "detached")
    if git -C "$current_dir" diff --quiet 2>/dev/null && git -C "$current_dir" diff --cached --quiet 2>/dev/null; then
        git_marker="✓"
    else
        modified_count=$(git -C "$current_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        [ "$modified_count" -gt 99 ] 2>/dev/null && modified_count="99+"
        git_marker="●${modified_count}"
    fi
fi

# Count items from specified directories
claude_dir="${PAI_DIR:-$HOME/.claude}"
commands_count=0
mcps_count=0
fobs_count=0
fabric_count=0

# Count commands (optimized - direct ls instead of find)
if [ -d "$claude_dir/commands" ]; then
    commands_count=$(ls -1 "$claude_dir/commands/"*.md 2>/dev/null | wc -l | tr -d ' ')
fi

# Count MCPs from settings.json (single parse)
mcp_names_raw=""
if [ -f "$claude_dir/settings.json" ]; then
    mcp_data=$(jq -r '.mcpServers | keys | join(" "), length' "$claude_dir/settings.json" 2>/dev/null)
    mcp_names_raw=$(echo "$mcp_data" | head -1)
    mcps_count=$(echo "$mcp_data" | tail -1)
else
    mcps_count="0"
fi

# Count Services (optimized - count .md files directly)
services_dir="${HOME}/Projects/FoundryServices/Services"
if [ -d "$services_dir" ]; then
    fobs_count=$(ls -1 "$services_dir/"*.md 2>/dev/null | wc -l | tr -d ' ')
fi

# Count Fabric patterns (optimized - count subdirectories)
fabric_patterns_dir="${HOME}/.config/fabric/patterns"
if [ -d "$fabric_patterns_dir" ]; then
    # Count immediate subdirectories only
    fabric_count=$(find "$fabric_patterns_dir" -maxdepth 1 -type d -not -path "$fabric_patterns_dir" 2>/dev/null | wc -l | tr -d ' ')
fi

# Get cached ccusage data - SAFE VERSION without background processes
CACHE_FILE="${PAI_DIR:-$HOME/.claude}/.ccusage-cache"
LOCK_FILE="${PAI_DIR:-$HOME/.claude}/.ccusage-lock"
CACHE_AGE=300  # 5 minutes

daily_tokens=""
daily_cost=""

# Check if cache exists and load it
if [ -f "$CACHE_FILE" ]; then
    # Always load cache data first (if it exists)
    source "$CACHE_FILE"
fi

# If cache is stale, missing, or we have no data, update it SYNCHRONOUSLY with timeout
cache_needs_update=false
if [ ! -f "$CACHE_FILE" ] || [ -z "$daily_tokens" ]; then
    cache_needs_update=true
elif [ -f "$CACHE_FILE" ]; then
    cache_age=$(($(date +%s) - $(stat -f%m "$CACHE_FILE" 2>/dev/null || echo 0)))
    if [ $cache_age -ge $CACHE_AGE ]; then
        cache_needs_update=true
    fi
fi

if [ "$cache_needs_update" = true ]; then
    # Try to acquire lock (non-blocking)
    if mkdir "$LOCK_FILE" 2>/dev/null; then
        # We got the lock - update cache with timeout
        if command -v bunx >/dev/null 2>&1; then
            # Get current month in YYYY-MM format (e.g., "2025-12")
            current_month=$(date +"%Y-%m")

            # Run ccusage monthly with a timeout (5 seconds for faster updates)
            # Check if gtimeout is available (macOS), otherwise try timeout (Linux)
            if command -v gtimeout >/dev/null 2>&1; then
                ccusage_output=$(gtimeout 5 bunx ccusage monthly 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep "│ $current_month" | head -1)
            elif command -v timeout >/dev/null 2>&1; then
                ccusage_output=$(timeout 5 bunx ccusage monthly 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep "│ $current_month" | head -1)
            else
                # Fallback without timeout (but faster than before)
                ccusage_output=$(bunx ccusage monthly 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep "│ $current_month" | head -1)
            fi

            # If no output for current month, set defaults
            if [ -z "$ccusage_output" ]; then
                daily_input="0"
                daily_output="0"
                daily_cost="\$0.00"
            elif [ -n "$ccusage_output" ]; then
                # Extract input/output tokens, removing commas and ellipsis
                daily_input=$(echo "$ccusage_output" | awk -F'│' '{print $4}' | sed 's/[^0-9]//g' | head -c 10)
                daily_output=$(echo "$ccusage_output" | awk -F'│' '{print $5}' | sed 's/[^0-9]//g' | head -c 10)
                # Extract cost, keep the dollar sign
                daily_cost=$(echo "$ccusage_output" | awk -F'│' '{print $9}' | sed 's/^ *//;s/ *$//')

                if [ -n "$daily_input" ] && [ -n "$daily_output" ]; then
                    daily_total=$((daily_input + daily_output))
                    daily_tokens=$(printf "%'d" "$daily_total" 2>/dev/null || echo "$daily_total")

                    # Write to cache file (properly escape dollar sign)
                    echo "daily_tokens=\"$daily_tokens\"" > "$CACHE_FILE"
                    # Use printf to properly escape the dollar sign in the cost
                    printf "daily_cost=\"%s\"\n" "${daily_cost//$/\\$}" >> "$CACHE_FILE"
                    # Add timestamp for debugging
                    echo "cache_updated=\"$(date)\"" >> "$CACHE_FILE"
                fi
            fi
        fi

        # Always remove lock when done
        rmdir "$LOCK_FILE" 2>/dev/null
    else
        # Someone else is updating - check if lock is stale (older than 30 seconds)
        if [ -d "$LOCK_FILE" ]; then
            lock_age=$(($(date +%s) - $(stat -f%m "$LOCK_FILE" 2>/dev/null || echo 0)))
            if [ $lock_age -gt 30 ]; then
                # Stale lock - remove it and try again
                rmdir "$LOCK_FILE" 2>/dev/null
            fi
        fi

        # Just use cached data if available
        if [ -f "$CACHE_FILE" ]; then
            source "$CACHE_FILE"
        fi
    fi
fi

# ─── Color Palette (Tokyo Night Storm) ───────────────────────────────────────
RESET='\033[0m'
BORDER_C='\033[38;2;88;91;112m'         # Muted overlay  — borders ╭ ─ │ ╰
CC_C='\033[38;2;122;162;247m'           # Blue           — CC version
MODEL_C='\033[38;2;187;154;247m'        # Mauve          — model name
GIT_BRANCH_C='\033[38;2;125;207;255m'   # Sky            — branch name
GIT_CLEAN_C='\033[38;2;158;206;106m'    # Green          — ✓ clean
GIT_DIRTY_C='\033[38;2;255;158;100m'    # Orange         — ● dirty
DIR_C='\033[38;2;169;177;214m'          # Subtext1       — directory
SEP_C='\033[38;2;88;91;112m'            # Muted          — · separators
LABEL_C='\033[38;2;101;108;131m'        # Comment        — labels
CTX_NORMAL_C='\033[38;2;158;206;106m'   # Green          — ctx normal
CTX_WARN_C='\033[38;2;224;175;104m'     # Yellow         — ctx 80%+
CTX_CRIT_C='\033[38;2;247;118;142m'     # Red            — ctx 90%+
COST_C='\033[38;2;224;175;104m'         # Yellow         — costs

# Simple colors fallback (PAI_SIMPLE_COLORS=1)
if [ "${PAI_SIMPLE_COLORS:-0}" = "1" ]; then
    BORDER_C='\033[90m'
    CC_C='\033[34m'
    MODEL_C='\033[35m'
    GIT_BRANCH_C='\033[36m'
    GIT_CLEAN_C='\033[32m'
    GIT_DIRTY_C='\033[33m'
    DIR_C='\033[37m'
    SEP_C='\033[90m'
    LABEL_C='\033[90m'
    CTX_NORMAL_C='\033[32m'
    CTX_WARN_C='\033[33m'
    CTX_CRIT_C='\033[31m'
    COST_C='\033[33m'
fi

# ─── Context progress bar ─────────────────────────────────────────────────────
context_total_k="${context_total_k:-N/A}"
context_size_k="${context_size_k:-N/A}"
context_percent="${context_percent:-0}"

bar_width=10
if [[ "$context_percent" =~ ^[0-9]+$ ]]; then
    filled=$(( context_percent * bar_width / 100 ))
    [ $filled -gt $bar_width ] && filled=$bar_width
    bar=""
    i=0
    while [ $i -lt $filled ]; do bar="${bar}■"; i=$((i+1)); done
    while [ $i -lt $bar_width ]; do bar="${bar}□"; i=$((i+1)); done
    if [ "$context_percent" -ge 90 ]; then
        CTX_C="$CTX_CRIT_C"
        ctx_alert=" ▲"
    elif [ "$context_percent" -ge 80 ]; then
        CTX_C="$CTX_WARN_C"
        ctx_alert=" ▲"
    else
        CTX_C="$CTX_NORMAL_C"
        ctx_alert=""
    fi
else
    bar="□□□□□□□□□□"
    CTX_C="$CTX_NORMAL_C"
    ctx_alert=""
fi

# ─── Monthly cost (from ccusage cache) ───────────────────────────────────────
if [ -n "$daily_tokens" ] && [ "$daily_tokens" != "N/A" ]; then
    daily_tokens_num=$(echo "$daily_tokens" | tr -d ',')
    if [ "$daily_tokens_num" -ge 1000 ] 2>/dev/null; then
        tokens_display=$(awk "BEGIN {printf \"%.0fk\", $daily_tokens_num/1000}")
    else
        tokens_display="$daily_tokens_num"
    fi
else
    tokens_display="N/A"
fi
cost_display="${daily_cost:-N/A}"

# ─── Dynamic width ────────────────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 88)
BOX_WIDTH=$(( TERM_WIDTH - 6 ))  # 3-char margin each side (cram-resistant)

# Field truncation — use … when over limit so disambiguating parts aren't silently clipped
_trunc() { local s="$1" max="$2"; [ "${#s}" -gt "$max" ] && echo "${s:0:$(( max - 1 ))}…" || echo "$s"; }
git_branch=$(_trunc "$git_branch" 22)
dir_name=$(_trunc "$dir_name" 18)

# Line 1 visible lengths for fill calculation
line1_left_vis="╭─ CC ${cc_version} · ${model_name} "
if [ -n "$git_branch" ]; then
    line1_right_vis=" ⎇ ${git_branch} ${git_marker} · ${dir_name} ─╮"
else
    line1_right_vis=" ${dir_name} ─╮"
fi
line1_left_len=${#line1_left_vis}
line1_right_len=${#line1_right_vis}
fill_len=$(( BOX_WIDTH - line1_left_len - line1_right_len ))
[ $fill_len -lt 1 ] && fill_len=1
header_fill=$(printf '─%.0s' $(seq 1 $fill_len))

# Bottom border (box width minus 2 for ╰╯)
bottom_fill=$(printf '─%.0s' $(seq 1 $(( BOX_WIDTH - 2 )) ))

# Line 2 padding between ctx and cost (1-space inner padding each side)
ctx_vis=" ctx ${bar} ${context_total_k}/${context_size_k} (${context_percent}%)${ctx_alert}"
cost_vis="session ${session_cost_display} · mo ${cost_display} "
ctx_vis_len=${#ctx_vis}
cost_vis_len=${#cost_vis}
inner_width=$(( BOX_WIDTH - 2 ))  # minus 2 for │ borders
line2_pad_len=$(( inner_width - ctx_vis_len - cost_vis_len ))
[ $line2_pad_len -lt 1 ] && line2_pad_len=1
line2_pad=$(printf ' %.0s' $(seq 1 $line2_pad_len))

# ─── Output (atomic write — single printf closes interleaving windows) ─────────
if [ -n "$git_branch" ]; then
    if [[ "$git_marker" == "✓" ]]; then
        git_marker_color="$GIT_CLEAN_C"
    else
        git_marker_color="$GIT_DIRTY_C"
    fi
    _line1=" ${BORDER_C}╭─${RESET} ${CC_C}CC ${cc_version}${RESET} ${SEP_C}·${RESET} ${MODEL_C}${model_name}${RESET} ${BORDER_C}${header_fill} ⎇${RESET} ${GIT_BRANCH_C}${git_branch}${RESET} ${git_marker_color}${git_marker}${RESET} ${SEP_C}·${RESET} ${DIR_C}${dir_name}${RESET} ${BORDER_C}─╮${RESET}"
else
    _line1=" ${BORDER_C}╭─${RESET} ${CC_C}CC ${cc_version}${RESET} ${SEP_C}·${RESET} ${MODEL_C}${model_name}${RESET} ${BORDER_C}${header_fill}${RESET} ${DIR_C}${dir_name}${RESET} ${BORDER_C}─╮${RESET}"
fi
_line2=" ${BORDER_C}│${RESET} ${LABEL_C}ctx${RESET} ${CTX_C}${bar}${RESET} ${DIR_C}${context_total_k}/${context_size_k}${RESET} ${SEP_C}(${RESET}${CTX_C}${context_percent}%%${RESET}${SEP_C})${RESET}${CTX_C}${ctx_alert}${RESET}${line2_pad}${LABEL_C}session${RESET} ${COST_C}${session_cost_display}${RESET} ${SEP_C}·${RESET} ${LABEL_C}mo${RESET} ${COST_C}${cost_display}${RESET} ${BORDER_C}│${RESET}"
_line3=" ${BORDER_C}╰${bottom_fill}╯${RESET}"
# \033[2K\r before each line erases any injected garbage that landed before this write
printf "\033[2K\r${_line1}\n\033[2K\r${_line2}\n\033[2K\r${_line3}\n"