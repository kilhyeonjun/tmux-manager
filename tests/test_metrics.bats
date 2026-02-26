#!/usr/bin/env bats
# Tests for lib/metrics.sh — BFS process tree metrics
# Note: _tmux_session_metrics requires a running tmux server,
# so we test the underlying awk logic with synthetic data.

load helpers/setup

@test "metrics awk logic computes BFS tree CPU/MEM" {
  # Simulate: session "test" has pane_pid=100
  # Process tree: 100 -> 200 -> 300
  # ps data: pid,ppid,cpu,rss
  local ps_data="100 1 2.0 10240
200 100 3.0 20480
300 200 1.5 5120
400 1 10.0 51200"

  local pane_data="test|100"

  result=$(awk '
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
  ' <(echo "$ps_data") <(echo "$pane_data"))

  echo "result: $result"
  # CPU: 2.0 + 3.0 + 1.5 = 6.5
  # MEM: (10240 + 20480 + 5120) / 1024 = 35
  [[ "$result" == "test|6.5|35" ]]
}

@test "metrics handles multiple sessions" {
  local ps_data="100 1 2.0 10240
200 1 5.0 20480"

  local pane_data="sess-a|100
sess-b|200"

  result=$(awk '
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
  ' <(echo "$ps_data") <(echo "$pane_data") | sort)

  echo "result: $result"
  [[ "$result" == *"sess-a|2.0|10"* ]]
  [[ "$result" == *"sess-b|5.0|20"* ]]
}

@test "metrics handles zero-pid gracefully" {
  local ps_data="100 1 2.0 10240"
  local pane_data="test|0"

  result=$(awk '
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
  ' <(echo "$ps_data") <(echo "$pane_data"))

  echo "result: $result"
  # Should produce no output for pid=0
  [ -z "$result" ]
}

@test "metrics handles deep process tree (4 levels)" {
  # Tree: 100 -> 200 -> 300 -> 400 -> 500
  local ps_data="100 1 1.0 1024
200 100 2.0 2048
300 200 3.0 3072
400 300 4.0 4096
500 400 5.0 5120"

  local pane_data="deep|100"

  result=$(awk '
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
  ' <(echo "$ps_data") <(echo "$pane_data"))

  echo "result: $result"
  # CPU: 1+2+3+4+5 = 15.0
  # MEM: (1024+2048+3072+4096+5120) / 1024 = 15
  [[ "$result" == "deep|15.0|15" ]]
}

@test "metrics handles forking process tree (multiple children)" {
  # Tree: 100 -> {200, 300, 400}
  local ps_data="100 1 1.0 1024
200 100 2.0 2048
300 100 3.0 3072
400 100 4.0 4096"

  local pane_data="fork|100"

  result=$(awk '
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
  ' <(echo "$ps_data") <(echo "$pane_data"))

  echo "result: $result"
  # CPU: 1+2+3+4 = 10.0
  # MEM: (1024+2048+3072+4096) / 1024 = 10
  [[ "$result" == "fork|10.0|10" ]]
}

@test "metrics handles orphan pane_pid not in ps" {
  local ps_data="200 1 5.0 10240"
  local pane_data="orphan|999"

  result=$(awk '
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
  ' <(echo "$ps_data") <(echo "$pane_data"))

  echo "result: $result"
  # pid 999 not found in ps — should produce no output
  [ -z "$result" ]
}
