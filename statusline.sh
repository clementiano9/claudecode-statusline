#!/bin/bash
#
# claudecode-statusline — Customizable status display for Claude Code
#
# CUSTOMIZATION:
#   - Set STATUSLINE_SIMPLE_COLORS=1 in settings.json env for basic ANSI colors
#     (fixes display issues on some terminals without truecolor support)
#   - Comment out any printf lines you don't want displayed
#
# LINES DISPLAYED (responsive tiers based on terminal width):
#   XL (>=80): 3-line bordered box with ctx bar, costs, lines changed, badges
#   L  (60-79): Compact box, no directory
#   M  (40-59): Borderless 2-line with vim badge
#   S  (<40):   Single micro line
#
# ENVIRONMENT VARIABLES (set in settings.json env section):
#   CLAUDE_CONFIG_DIR       — path to Claude config dir (default: ~/.claude)
#   STATUSLINE_SIMPLE_COLORS — Set to "1" to use basic terminal colors
#   STATUSLINE_PLAIN_STATUS  — Set to "1" to disable all ANSI colors
#   NO_COLOR                 — Set to "1" to disable all ANSI colors (standard)
#

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Source .env for optional API keys / overrides
claude_env="${CLAUDE_CONFIG_DIR}/.env"
[ -f "$claude_env" ] && source "$claude_env" < /dev/null

# Read JSON input from stdin
input=$(cat)

# Extract data from JSON input
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
model_name=$(echo "$input" | jq -r '.model.display_name')
cc_version=$(echo "$input" | jq -r '.version // "unknown"')

# Get directory name
dir_name=$(basename "$current_dir")

# Extract session cost data
session_cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
session_cost_display=$(printf "\$%.2f" "$session_cost_usd" 2>/dev/null || echo "\$$session_cost_usd")

# Extract context window data — use CC's authoritative used_percentage
context_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
used_percentage=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
current_usage=$(echo "$input" | jq '.context_window.current_usage')

# Extract new CC fields (conditionally present)
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
session_duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Calculate context percentage and display values
if [ -n "$used_percentage" ]; then
    # CC provides authoritative used_percentage — use it directly
    context_percent=$(printf "%.0f" "$used_percentage" 2>/dev/null || echo "0")

    # Derive token count for Xk/200k display from current_usage
    if [ "$current_usage" != "null" ]; then
        context_input=$(echo "$current_usage" | jq -r '.input_tokens // 0')
        cache_creation=$(echo "$current_usage" | jq -r '.cache_creation_input_tokens // 0')
        cache_read=$(echo "$current_usage" | jq -r '.cache_read_input_tokens // 0')
        base_context=$((context_input + cache_creation + cache_read))
    else
        base_context=$((context_percent * context_window_size / 100))
    fi

    context_total_k=$(awk "BEGIN {printf \"%.0fk\", $base_context/1000}")
    context_size_k=$(awk "BEGIN {printf \"%.0fk\", $context_window_size/1000}")
elif [ "$current_usage" != "null" ]; then
    # Fallback: calculate from current_usage tokens (no autocompact buffer guess)
    context_input=$(echo "$current_usage" | jq -r '.input_tokens // 0')
    cache_creation=$(echo "$current_usage" | jq -r '.cache_creation_input_tokens // 0')
    cache_read=$(echo "$current_usage" | jq -r '.cache_read_input_tokens // 0')
    base_context=$((context_input + cache_creation + cache_read))

    context_percent=$((base_context * 100 / context_window_size))
    context_total_k=$(awk "BEGIN {printf \"%.0fk\", $base_context/1000}")
    context_size_k=$(awk "BEGIN {printf \"%.0fk\", $context_window_size/1000}")
else
    context_percent=0
    context_total_k="N/A"
    context_size_k=$(awk "BEGIN {printf \"%.0fk\", $context_window_size/1000}")
fi

# Session-aware Guard Mode — DEFAULT ON.
#   Cost-based signal: cost stays at exactly $0.00 until first AI response.
#   Safe cost: normalize null/empty from jq (happens when CC provides minimal JSON at startup).
#   We only EXIT guard mode when cost is CONFIRMED > 0 — on unknown/error, stay in guard mode.
_gc="${session_cost_usd:-0}"
[ "$_gc" = "null" ] && _gc="0"
if [ "$context_percent" -ge 75 ] 2>/dev/null; then
    FORCE_GUARD_MODE=1   # 75%+ context: autocompact imminent
elif awk "BEGIN { exit ($_gc > 0 ? 0 : 1) }" 2>/dev/null; then
    FORCE_GUARD_MODE=0   # confirmed cost > 0: first message answered, exit guard mode
else
    FORCE_GUARD_MODE=1   # cost == 0 or indeterminate: stay in guard mode (default)
fi

# Format lines changed display (compact: +42/-7)
lines_display=""
if [ "$lines_added" -gt 0 ] 2>/dev/null || [ "$lines_removed" -gt 0 ] 2>/dev/null; then
    lines_display="+${lines_added}/-${lines_removed}"
fi

# Format session duration (compact: 2m, 1h23m)
duration_display=""
if [ "$session_duration_ms" -gt 0 ] 2>/dev/null; then
    duration_s=$((session_duration_ms / 1000))
    if [ $duration_s -ge 3600 ]; then
        duration_h=$((duration_s / 3600))
        duration_m=$(( (duration_s % 3600) / 60 ))
        duration_display="${duration_h}h${duration_m}m"
    elif [ $duration_s -ge 60 ]; then
        duration_m=$((duration_s / 60))
        duration_display="${duration_m}m"
    else
        duration_display="${duration_s}s"
    fi
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

# Count MCPs from settings.json (single parse)
mcp_names_raw=""
mcps_count=0
if [ -f "${CLAUDE_CONFIG_DIR}/settings.json" ]; then
    mcp_data=$(jq -r '.mcpServers | keys | join(" "), length' "${CLAUDE_CONFIG_DIR}/settings.json" 2>/dev/null)
    mcp_names_raw=$(echo "$mcp_data" | head -1)
    mcps_count=$(echo "$mcp_data" | tail -1)
fi

# Get cached ccusage data - SAFE VERSION without background processes
CACHE_FILE="${CLAUDE_CONFIG_DIR}/.ccusage-cache"
LOCK_FILE="${CLAUDE_CONFIG_DIR}/.ccusage-lock"
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

# ─── ANSI Plain Mode ─────────────────────────────────────────────────────────
# CC bug #24514: ANSI escape bytes counted as visible chars. However, this only
# triggers during Ink flex reflow — which only fires when a notification competes
# on row 1. Lines 2+ never share space with notifications, so colors are ALWAYS
# safe on box body lines. Only the guard line (row 1 in guard mode) needs plain.
#
# Colors are ON by default. Opt out with STATUSLINE_PLAIN_STATUS=1 or NO_COLOR=1.
PLAIN_MODE=0
if [ "${STATUSLINE_PLAIN_STATUS:-0}" = "1" ] || [ "${NO_COLOR:-}" = "1" ]; then
    PLAIN_MODE=1
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
LINES_ADD_C='\033[38;2;158;206;106m'    # Green          — +lines
LINES_DEL_C='\033[38;2;247;118;142m'    # Red            — -lines
BADGE_C='\033[38;2;122;162;247m'        # Blue           — vim/agent badges
DUR_C='\033[38;2;169;177;214m'          # Subtext1       — duration

# Simple colors fallback (STATUSLINE_SIMPLE_COLORS=1)
if [ "${STATUSLINE_SIMPLE_COLORS:-0}" = "1" ]; then
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
    LINES_ADD_C='\033[32m'
    LINES_DEL_C='\033[31m'
    BADGE_C='\033[34m'
    DUR_C='\033[37m'
fi

# ─── Context progress bar ─────────────────────────────────────────────────────
context_total_k="${context_total_k:-N/A}"
context_size_k="${context_size_k:-N/A}"
context_percent="${context_percent:-0}"

# ─── Dynamic width detection ──────────────────────────────────────────────────
# tput cols is unreliable inside CC subprocess (returns 80 regardless of actual
# pane width). Walk up process tree to find parent TTY and query real dimensions.
TERM_WIDTH=80
_pid=$$
for _i in 1 2 3; do
    _pid=$(ps -o ppid= -p $_pid 2>/dev/null | tr -d ' ')
    [ -z "$_pid" ] || [ "$_pid" = "1" ] && break
    _tty=$(ps -o tty= -p $_pid 2>/dev/null | tr -d ' ')
    if [ -n "$_tty" ] && [ "$_tty" != "??" ]; then
        _pw=$(stty size < "/dev/$_tty" 2>/dev/null | awk '{print $2}')
        if [ -n "$_pw" ] && [ "$_pw" -gt 0 ] 2>/dev/null; then
            TERM_WIDTH=$_pw
            break
        fi
    fi
done
# Allow override for testing: STATUSLINE_WIDTH=50 bash statusline.sh
[ -n "$STATUSLINE_WIDTH" ] && TERM_WIDTH=$STATUSLINE_WIDTH
[ $TERM_WIDTH -lt 20 ] && TERM_WIDTH=20
# Cap at max width so the box never spans a very wide terminal
MAX_WIDTH=${STATUSLINE_MAX_WIDTH:-120}
[ $TERM_WIDTH -gt $MAX_WIDTH ] && TERM_WIDTH=$MAX_WIDTH

# In plain mode, null out all color variables so interpolation produces no bytes
if [ $PLAIN_MODE -eq 1 ]; then
    RESET=''; BORDER_C=''; CC_C=''; MODEL_C=''; GIT_BRANCH_C=''
    GIT_CLEAN_C=''; GIT_DIRTY_C=''; DIR_C=''; SEP_C=''; LABEL_C=''
    CTX_NORMAL_C=''; CTX_WARN_C=''; CTX_CRIT_C=''; COST_C=''
    LINES_ADD_C=''; LINES_DEL_C=''; BADGE_C=''; DUR_C=''
fi

# Field truncation helper
_trunc() { local s="$1" max="$2"; [ "${#s}" -gt "$max" ] && echo "${s:0:$(( max - 1 ))}…" || echo "$s"; }

# Tier selection: XL (full box) → L (compact box) → M (borderless) → S (micro)
if [ $TERM_WIDTH -ge 80 ]; then
    TIER="XL"
    BOX_WIDTH=$(( TERM_WIDTH - 6 ))
    bar_width=10
    git_branch=$(_trunc "$git_branch" 18)
    dir_name=$(_trunc "$dir_name" 18)
elif [ $TERM_WIDTH -ge 60 ]; then
    TIER="L"
    BOX_WIDTH=$(( TERM_WIDTH - 6 ))
    bar_width=5
    git_branch=$(_trunc "$git_branch" 12)
    dir_name=""  # dropped in compact mode
elif [ $TERM_WIDTH -ge 40 ]; then
    TIER="M"
    bar_width=5
    git_branch=$(_trunc "$git_branch" 10)
    model_name=$(_trunc "$model_name" 12)
    dir_name=""
else
    TIER="S"
    bar_width=5
    git_branch=""
    dir_name=""
fi
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
    bar=""; i=0; while [ $i -lt $bar_width ]; do bar="${bar}□"; i=$((i+1)); done
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
cost_display_short=$(echo "$cost_display" | sed 's/\.[0-9]*//')

# ─── Git marker color ─────────────────────────────────────────────────────────
if [ -n "$git_branch" ]; then
    if [[ "$git_marker" == "✓" ]]; then
        git_marker_color="$GIT_CLEAN_C"
    else
        git_marker_color="$GIT_DIRTY_C"
    fi
fi

# ─── Extra indicators (lines changed, duration, vim, agent) ──────────────────
# Build visible (for width calc) and ANSI (for display) versions
extras_vis=""
extras_ansi=""

if [ -n "$lines_display" ]; then
    extras_vis="${extras_vis} · ${lines_display}"
    extras_ansi="${extras_ansi} ${SEP_C}·${RESET} ${LINES_ADD_C}+${lines_added}${RESET}${SEP_C}/${RESET}${LINES_DEL_C}-${lines_removed}${RESET}"
fi
if [ -n "$vim_mode" ]; then
    vim_short=$(echo "$vim_mode" | head -c 1)
    extras_vis="${extras_vis} [${vim_short}]"
    extras_ansi="${extras_ansi} ${BADGE_C}[${vim_short}]${RESET}"
fi
if [ -n "$agent_name" ]; then
    agent_short=$(_trunc "$agent_name" 12)
    extras_vis="${extras_vis} @${agent_short}"
    extras_ansi="${extras_ansi} ${BADGE_C}@${agent_short}${RESET}"
fi

# Compact version for L/M tiers
extras_compact_vis=""
extras_compact_ansi=""
if [ -n "$lines_display" ]; then
    extras_compact_vis=" ${lines_display}"
    extras_compact_ansi=" ${LINES_ADD_C}+${lines_added}${RESET}${SEP_C}/${RESET}${LINES_DEL_C}-${lines_removed}${RESET}"
fi
if [ -n "$vim_mode" ]; then
    vim_short=$(echo "$vim_mode" | head -c 1)
    extras_compact_vis="${extras_compact_vis} [${vim_short}]"
    extras_compact_ansi="${extras_compact_ansi} ${BADGE_C}[${vim_short}]${RESET}"
fi

# ─── Tier-conditional layout + output ─────────────────────────────────────────
# CC notifications share LINE 1's horizontal space (notification: flexShrink:0,
# statusline: flexShrink:1). Lines 2+ get full terminal width always.
#
# Guard mode triggers when box header alone can't fit terminal width. Guard lines
# are plain text (no ANSI), so notification crushing them is harmless. If a
# notification temporarily garbles the colored line 1 in normal mode, lines 2+
# (ctx bar, costs) remain intact — acceptable tradeoff for keeping git in the box.
#
# When context >= 80%, autocompact is imminent and CC will show a notification
# that competes for line 1 space. Preemptively reserve ~30 chars for it.
if [ "$context_percent" -ge 75 ] 2>/dev/null; then
    NOTIFICATION_RESERVE=30
else
    NOTIFICATION_RESERVE=0
fi

case "$TIER" in
    XL)
        # Calculate box header min content width (without fill dashes)
        _hdr_left="╭─ CC ${cc_version} · ${model_name} "
        if [ -n "$git_branch" ]; then
            _hdr_right=" ⎇ ${git_branch} ${git_marker} · ${dir_name} ─╮"
        else
            _hdr_right=" ${dir_name} ─╮"
        fi
        _hdr_min=$(( ${#_hdr_left} + ${#_hdr_right} ))

        # Width headroom check: can box header + notification fit on line 1?
        if [ "$FORCE_GUARD_MODE" -eq 0 ] && [ $(( _hdr_min + NOTIFICATION_RESERVE )) -le $TERM_WIDTH ]; then
            # ── NORMAL MODE: original 3-line box (top border on line 1) ──
            fill_len=$(( BOX_WIDTH - _hdr_min ))
            [ $fill_len -lt 1 ] && fill_len=1
            header_fill=$(printf '─%.0s' $(seq 1 $fill_len))

            if [ -n "$git_branch" ]; then
                _line1=" ${BORDER_C}╭─${RESET} ${CC_C}CC ${cc_version}${RESET} ${SEP_C}·${RESET} ${MODEL_C}${model_name}${RESET} ${BORDER_C}${header_fill} ⎇${RESET} ${GIT_BRANCH_C}${git_branch}${RESET} ${git_marker_color}${git_marker}${RESET} ${SEP_C}·${RESET} ${DIR_C}${dir_name}${RESET} ${BORDER_C}─╮${RESET}"
            else
                _line1=" ${BORDER_C}╭─${RESET} ${CC_C}CC ${cc_version}${RESET} ${SEP_C}·${RESET} ${MODEL_C}${model_name}${RESET} ${BORDER_C}${header_fill}${RESET} ${DIR_C}${dir_name}${RESET} ${BORDER_C}─╮${RESET}"
            fi

            ctx_vis=" ctx ${bar} ${context_total_k}/${context_size_k} (${context_percent}%)${ctx_alert}"
            inner_width=$(( BOX_WIDTH - 2 ))
            # Try with extras, drop if they overflow
            cost_vis="session ${session_cost_display} · mo ${cost_display}${extras_vis} "
            line2_pad_len=$(( inner_width - ${#ctx_vis} - ${#cost_vis} ))
            if [ $line2_pad_len -lt 1 ]; then
                # Extras don't fit — fall back to base costs only
                cost_vis="session ${session_cost_display} · mo ${cost_display} "
                line2_pad_len=$(( inner_width - ${#ctx_vis} - ${#cost_vis} ))
                [ $line2_pad_len -lt 1 ] && line2_pad_len=1
                _use_extras_ansi=""
            else
                _use_extras_ansi="$extras_ansi"
            fi
            line2_pad=$(printf ' %.0s' $(seq 1 $line2_pad_len))
            bottom_fill=$(printf '─%.0s' $(seq 1 $(( BOX_WIDTH - 2 )) ))

            _line2=" ${BORDER_C}│${RESET} ${LABEL_C}ctx${RESET} ${CTX_C}${bar}${RESET} ${DIR_C}${context_total_k}/${context_size_k}${RESET} ${SEP_C}(${RESET}${CTX_C}${context_percent}%%${RESET}${SEP_C})${RESET}${CTX_C}${ctx_alert}${RESET}${line2_pad}${LABEL_C}session${RESET} ${COST_C}${session_cost_display}${RESET} ${SEP_C}·${RESET} ${LABEL_C}mo${RESET} ${COST_C}${cost_display}${RESET}${_use_extras_ansi} ${BORDER_C}│${RESET}"
            _line3=" ${BORDER_C}╰${bottom_fill}╯${RESET}"
            printf "${_line1}\n${_line2}\n${_line3}\n"
        else
            # ── GUARD MODE: sacrificial guard + box on lines 2-4 ──
            # Guard line sits on row 1 competing with notifications — always plain
            # to avoid CC bug #24514 ANSI byte miscounting during flex reflow
            if [ -n "$git_branch" ]; then
                _guard=" ⎇ ${git_branch} ${git_marker}"
            else
                _guard=" ·"
            fi

            # Box header WITHOUT git (it's on the guard line)
            _hdr_left_g="╭─ CC ${cc_version} · ${model_name} "
            _hdr_right_g=" ${dir_name} ─╮"
            fill_len=$(( BOX_WIDTH - ${#_hdr_left_g} - ${#_hdr_right_g} ))
            [ $fill_len -lt 1 ] && fill_len=1
            header_fill=$(printf '─%.0s' $(seq 1 $fill_len))

            # Plain text box — no ANSI codes — immune to CC bug #24514 byte miscounting.
            # Colored ANSI adds ~300 bytes per line; CC miscounts these as visible chars,
            # causing each line to wrap. Plain text survives any notification length.
            _line1=" ${_hdr_left_g}${header_fill}${_hdr_right_g}"
            ctx_vis=" ctx ${bar} ${context_total_k}/${context_size_k} (${context_percent}%)${ctx_alert}"
            inner_width=$(( BOX_WIDTH - 2 ))
            cost_vis="session ${session_cost_display} · mo ${cost_display} "
            line2_pad_len=$(( inner_width - ${#ctx_vis} - ${#cost_vis} ))
            [ $line2_pad_len -lt 1 ] && line2_pad_len=1
            line2_pad=$(printf ' %.0s' $(seq 1 $line2_pad_len))
            bottom_fill=$(printf '─%.0s' $(seq 1 $(( BOX_WIDTH - 2 )) ))
            _line2=" │${ctx_vis}${line2_pad}${cost_vis}│"
            _line3=" ╰${bottom_fill}╯"
            printf "%s\n%s\n%s\n%s\n" "${_guard}" "${_line1}" "${_line2}" "${_line3}"
        fi
        ;;

    L)
        # Calculate box header min content width (without fill dashes)
        _hdr_left="╭─ CC ${cc_version} · ${model_name} "
        if [ -n "$git_branch" ]; then
            _hdr_right=" ⎇ ${git_branch} ${git_marker} ─╮"
        else
            _hdr_right=" ─╮"
        fi
        _hdr_min=$(( ${#_hdr_left} + ${#_hdr_right} ))

        if [ "$FORCE_GUARD_MODE" -eq 0 ] && [ $(( _hdr_min + NOTIFICATION_RESERVE )) -le $TERM_WIDTH ]; then
            # ── NORMAL MODE: compact 3-line box ──
            fill_len=$(( BOX_WIDTH - _hdr_min ))
            [ $fill_len -lt 1 ] && fill_len=1
            header_fill=$(printf '─%.0s' $(seq 1 $fill_len))

            if [ -n "$git_branch" ]; then
                _line1=" ${BORDER_C}╭─${RESET} ${CC_C}CC ${cc_version}${RESET} ${SEP_C}·${RESET} ${MODEL_C}${model_name}${RESET} ${BORDER_C}${header_fill} ⎇${RESET} ${GIT_BRANCH_C}${git_branch}${RESET} ${git_marker_color}${git_marker}${RESET} ${BORDER_C}─╮${RESET}"
            else
                _line1=" ${BORDER_C}╭─${RESET} ${CC_C}CC ${cc_version}${RESET} ${SEP_C}·${RESET} ${MODEL_C}${model_name}${RESET} ${BORDER_C}${header_fill}─╮${RESET}"
            fi

            ctx_vis=" ctx ${bar} ${context_total_k}/${context_size_k} (${context_percent}%)${ctx_alert}"
            inner_width=$(( BOX_WIDTH - 2 ))
            cost_vis="s:${session_cost_display} m:${cost_display_short}${extras_compact_vis} "
            line2_pad_len=$(( inner_width - ${#ctx_vis} - ${#cost_vis} ))
            if [ $line2_pad_len -lt 1 ]; then
                cost_vis="s:${session_cost_display} m:${cost_display_short} "
                line2_pad_len=$(( inner_width - ${#ctx_vis} - ${#cost_vis} ))
                [ $line2_pad_len -lt 1 ] && line2_pad_len=1
                _use_compact_ansi=""
            else
                _use_compact_ansi="$extras_compact_ansi"
            fi
            line2_pad=$(printf ' %.0s' $(seq 1 $line2_pad_len))
            bottom_fill=$(printf '─%.0s' $(seq 1 $(( BOX_WIDTH - 2 )) ))

            _line2=" ${BORDER_C}│${RESET} ${LABEL_C}ctx${RESET} ${CTX_C}${bar}${RESET} ${DIR_C}${context_total_k}/${context_size_k}${RESET} ${SEP_C}(${RESET}${CTX_C}${context_percent}%%${RESET}${SEP_C})${RESET}${CTX_C}${ctx_alert}${RESET}${line2_pad}${LABEL_C}s:${RESET}${COST_C}${session_cost_display}${RESET} ${LABEL_C}m:${RESET}${COST_C}${cost_display_short}${RESET}${_use_compact_ansi} ${BORDER_C}│${RESET}"
            _line3=" ${BORDER_C}╰${bottom_fill}╯${RESET}"
            printf "${_line1}\n${_line2}\n${_line3}\n"
        else
            # ── GUARD MODE: guard + compact box on lines 2-4 ──
            # Guard line on row 1 — always plain (CC bug #24514)
            if [ -n "$git_branch" ]; then
                _guard=" ⎇ ${git_branch} ${git_marker}"
            else
                _guard=" ·"
            fi

            _hdr_left_g="╭─ CC ${cc_version} · ${model_name} "
            _hdr_right_g=" ─╮"
            fill_len=$(( BOX_WIDTH - ${#_hdr_left_g} - ${#_hdr_right_g} ))
            [ $fill_len -lt 1 ] && fill_len=1
            header_fill=$(printf '─%.0s' $(seq 1 $fill_len))

            # Plain text box — no ANSI (see XL guard mode comment above)
            _line1=" ${_hdr_left_g}${header_fill}${_hdr_right_g}"
            ctx_vis=" ctx ${bar} ${context_total_k}/${context_size_k} (${context_percent}%)${ctx_alert}"
            inner_width=$(( BOX_WIDTH - 2 ))
            cost_vis="s:${session_cost_display} m:${cost_display_short} "
            line2_pad_len=$(( inner_width - ${#ctx_vis} - ${#cost_vis} ))
            [ $line2_pad_len -lt 1 ] && line2_pad_len=1
            line2_pad=$(printf ' %.0s' $(seq 1 $line2_pad_len))
            bottom_fill=$(printf '─%.0s' $(seq 1 $(( BOX_WIDTH - 2 )) ))
            _line2=" │${ctx_vis}${line2_pad}${cost_vis}│"
            _line3=" ╰${bottom_fill}╯"
            printf "%s\n%s\n%s\n%s\n" "${_guard}" "${_line1}" "${_line2}" "${_line3}"
        fi
        ;;

    M)
        # Borderless 2-line — CC uses column layout <80 cols (notification below, not beside)
        _line1=" ${MODEL_C}${model_name}${RESET}"
        [ -n "$git_branch" ] && _line1="${_line1} ${GIT_BRANCH_C}⎇ ${git_branch}${RESET} ${git_marker_color}${git_marker}${RESET}"
        [ -n "$vim_mode" ] && _line1="${_line1} ${BADGE_C}[${vim_short}]${RESET}"
        _m_extras=""
        [ -n "$lines_display" ] && _m_extras=" ${LINES_ADD_C}+${lines_added}${RESET}${SEP_C}/${RESET}${LINES_DEL_C}-${lines_removed}${RESET}"
        _line2=" ${CTX_C}${bar}${RESET} ${CTX_C}${context_percent}%%${RESET}${CTX_C}${ctx_alert}${RESET}  ${LABEL_C}s:${RESET}${COST_C}${session_cost_display}${RESET} ${LABEL_C}m:${RESET}${COST_C}${cost_display_short}${RESET}${_m_extras}"
        printf "${_line1}\n${_line2}\n"
        ;;

    S)
        # Single-line micro — ctx bar + costs only
        _line1=" ${CTX_C}${bar}${RESET} ${CTX_C}${context_percent}%%${RESET} ${LABEL_C}s:${RESET}${COST_C}${session_cost_display}${RESET} ${LABEL_C}m:${RESET}${COST_C}${cost_display_short}${RESET}"
        [ -n "$vim_mode" ] && _line1="${_line1} ${BADGE_C}[${vim_short}]${RESET}"
        printf "${_line1}\n"
        ;;
esac
