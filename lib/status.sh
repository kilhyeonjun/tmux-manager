#!/bin/zsh
# tmux-manager — status bar segment refresh
# Called as standalone script via tmux #() or run-shell hooks.
# Usage: status.sh <segment> [args]

TMUX_MANAGER_DIR="${0:A:h:h}"
source "$TMUX_MANAGER_DIR/conf/defaults.conf"
source "$TMUX_MANAGER_DIR/lib/utils.sh"

segment="$1"
shift

case "$segment" in
  refresh_tabs)
    # Debounce: prevent re-execution within TMUX_MANAGER_DEBOUNCE_SEC
    local _tmux_uid="${UID:-$(id -u 2>/dev/null || echo 0)}"
    local _tmux_socket_key="${TMUX%%,*}"
    [ -z "$_tmux_socket_key" ] && _tmux_socket_key='nosocket'
    _tmux_socket_key=$(printf '%s' "$_tmux_socket_key" | tr -c '[:alnum:]_.-' '_')
    local lockfile="/tmp/.tmux-status-lock-${_tmux_uid}-${_tmux_socket_key}"
    if [ -f "$lockfile" ]; then
      local lock_age=$(( $(date +%s) - $(stat -f%m "$lockfile" 2>/dev/null || echo 0) ))
      [ "$lock_age" -lt "${TMUX_MANAGER_DEBOUNCE_SEC:-2}" ] && exit 0
    fi
    touch "$lockfile"

    local all_ps=$(ps -axo pid=,ppid=,%cpu=,rss= 2>/dev/null)
    local now=$(date +%s)

    # 1) Collect all pane data in one call (tab-separated)
    local pane_data=$(tmux list-panes -a -F "#{pane_id}$(printf '\t')#{session_id}$(printf '\t')#{window_index}$(printf '\t')#{pane_current_path}$(printf '\t')#{pane_title}$(printf '\t')#{pane_pid}" 2>/dev/null)
    [ -z "$pane_data" ] && exit 0

    # 2) BFS process tree metrics per pane_pid
    local all_pids=$(echo "$pane_data" | awk -F'\t' '{print $6}')
    local pid_metrics=$(awk '
      NR==FNR {
        pid=$1+0; ppid=$2+0; cpu=$3+0; rss=$4+0
        pcpu[pid]=cpu; prss[pid]=rss
        children[ppid]=children[ppid] " " pid
        next
      }
      {
        root=$1+0
        if (root==0) next
        tc=0; tr=0
        queue[1]=root; head=1; tail=1
        while (head<=tail) {
          p=queue[head++]
          if (p in pcpu) { tc+=pcpu[p]; tr+=prss[p] }
          if (p in children) {
            n=split(children[p], ch, " ")
            for (i=1;i<=n;i++) { if (ch[i]+0>0) queue[++tail]=ch[i]+0 }
          }
        }
        delete queue
        printf "%d\t%.0f\t%d\n", root, tc, int(tr/1024)
      }
    ' <(echo "$all_ps") <(echo "$all_pids"))

    # Load pid_metrics into associative arrays
    typeset -A pm_cpu pm_mem
    while IFS=$'\t' read -r _pid _cpu _mem; do
      [ -z "$_pid" ] && continue
      pm_cpu[$_pid]="$_cpu"
      pm_mem[$_pid]="$_mem"
    done <<< "$pid_metrics"

    # 3) Git branch cache (deduplicate per directory)
    typeset -A git_cache

    # 4) Window/session aggregation
    typeset -A win_cpu win_mem win_branch win_oc
    typeset -A sess_cpu sess_mem

    # 5) Pane loop — set pane options + aggregate
    while IFS=$'\t' read -r pid sid widx ppath ptitle ppid; do
      [ -z "$pid" ] && continue
      local wkey="${sid}:${widx}"

      # Git branch (cached)
      local branch=''
      if [ -n "$ppath" ] && [ -d "$ppath" ]; then
        if [[ -v git_cache[$ppath] ]]; then
          branch="${git_cache[$ppath]}"
        else
          branch=$(git -C "$ppath" rev-parse --abbrev-ref HEAD 2>/dev/null)
          git_cache[$ppath]="$branch"
        fi
      fi

      # Pane border: @pbranch
      if [ -n "$branch" ]; then
        tmux set-option -p -t "$pid" -q @pbranch " ⎇ $branch" 2>/dev/null
      else
        tmux set-option -u -p -t "$pid" -q @pbranch 2>/dev/null
      fi

      # Pane border: @poc (OC title detection — simple string check)
      if [[ "$ptitle" == "OC |"* ]]; then
        local poc_title="${ptitle#OC | }"
        [ ${#poc_title} -gt 20 ] && poc_title="${poc_title:0:18}.."
        tmux set-option -p -t "$pid" -q @poc " ● $poc_title" 2>/dev/null
      else
        tmux set-option -u -p -t "$pid" -q @poc 2>/dev/null
      fi

      # Pane border: @pmetrics
      local pcpu="${pm_cpu[$ppid]:-0}"
      local pmem="${pm_mem[$ppid]:-0}"
      if [ "$pcpu" != "0" ] || [ "$pmem" != "0" ]; then
        tmux set-option -p -t "$pid" -q @pmetrics " C${pcpu}%M${pmem}M" 2>/dev/null
      else
        tmux set-option -u -p -t "$pid" -q @pmetrics 2>/dev/null
      fi

      # Window aggregation (first pane's branch/oc as window representative)
      win_cpu[$wkey]=$(( ${win_cpu[$wkey]:-0} + pcpu ))
      win_mem[$wkey]=$(( ${win_mem[$wkey]:-0} + pmem ))
      [ -z "${win_branch[$wkey]}" ] && [ -n "$branch" ] && win_branch[$wkey]="$branch"
      if [ -z "${win_oc[$wkey]}" ] && [[ "$ptitle" == "OC |"* ]]; then
        local oc_t="${ptitle#OC | }"
        [ ${#oc_t} -gt 20 ] && oc_t="${oc_t:0:18}.."
        win_oc[$wkey]="$oc_t"
      fi

      # Session aggregation
      sess_cpu[$sid]=$(( ${sess_cpu[$sid]:-0} + pcpu ))
      sess_mem[$sid]=$(( ${sess_mem[$sid]:-0} + pmem ))
    done <<< "$pane_data"

    # 6) Set window options
    for wkey in ${(k)win_cpu}; do
      local b="${win_branch[$wkey]}"
      local o="${win_oc[$wkey]}"
      [ -n "$b" ] && tmux set-option -w -t "$wkey" -q @branch " ⎇ $b" 2>/dev/null || tmux set-option -u -w -t "$wkey" -q @branch 2>/dev/null
      [ -n "$o" ] && tmux set-option -w -t "$wkey" -q @oc " ● $o" 2>/dev/null || tmux set-option -u -w -t "$wkey" -q @oc 2>/dev/null
    done

    # 7) Set session options (metrics + archive timestamp)
    for sid in ${(k)sess_cpu}; do
      local sc="${sess_cpu[$sid]:-0}"
      local sm="${sess_mem[$sid]:-0}"
      tmux set-option -t "$sid" -q @metrics "C${sc}% M${sm}M" 2>/dev/null

      # Archive age
      local sess_name=$(tmux display-message -t "$sid" -p '#{session_name}' 2>/dev/null)
      local safe_name=$(_tmux_archive_safe_name "$sess_name")
      local latest=$(ls -1t "$TMUX_ARCHIVE_DIR/${safe_name}_"*.archive 2>/dev/null | head -1)
      if [ -n "$latest" ]; then
        local fdate=$(grep '^ARCHIVED_AT=' "$latest" | cut -d= -f2-)
        if [ -n "$fdate" ]; then
          local fsecs=$(date -j -f '%Y-%m-%d %H:%M:%S' "$fdate" +%s 2>/dev/null)
          if [ -n "$fsecs" ]; then
            local diff=$((now - fsecs))
            local label=''
            if [ $diff -lt 60 ]; then label="📦${diff}초"
            elif [ $diff -lt 3600 ]; then label="📦$((diff/60))분"
            elif [ $diff -lt 86400 ]; then label="📦$((diff/3600))h"
            else label="📦$((diff/86400))d"
            fi
            tmux set-option -t "$sid" -q @archive_ago "$label" 2>/dev/null
          fi
        fi
      else
        tmux set-option -u -t "$sid" -q @archive_ago 2>/dev/null
      fi
    done
    ;;
esac
