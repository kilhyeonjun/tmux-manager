# tmux-manager — session metrics (BFS process tree walk)
# Sourced by init.sh

# Compute CPU% and MEM(MB) per session via BFS walk of pane process trees.
# Output: session_name|cpu|mem  (one line per session)
_tmux_session_metrics() {
  local pane_rows
  pane_rows=$(tmux list-panes -a -F '#{session_name}|#{pane_pid}' 2>/dev/null)
  [ -z "$pane_rows" ] && return

  local all_ps
  all_ps=$(ps -axo pid=,ppid=,%cpu=,rss= 2>/dev/null)
  [ -z "$all_ps" ] && return

  awk '
    NR==FNR {
      pid=$1+0; ppid=$2+0; cpu=$3+0; rss=$4+0
      pcpu[pid]=cpu; prss[pid]=rss
      children[ppid]=children[ppid] " " pid
      next
    }
    {
      split($0, a, "|")
      s=a[1]; root=a[2]+0
      if (root==0) next
      # BFS: walk process tree from root
      queue[1]=root; head=1; tail=1
      while (head<=tail) {
        p=queue[head++]
        if (p in pcpu) { sc[s]+=pcpu[p]; sr[s]+=prss[p] }
        if (p in children) {
          n=split(children[p], ch, " ")
          for (i=1;i<=n;i++) { if (ch[i]+0>0) queue[++tail]=ch[i]+0 }
        }
      }
      delete queue
    }
    END {
      for (s in sc) {
        printf "%s|%.1f|%d\n", s, sc[s], int(sr[s]/1024)
      }
    }
  ' <(echo "$all_ps") <(echo "$pane_rows")
}
