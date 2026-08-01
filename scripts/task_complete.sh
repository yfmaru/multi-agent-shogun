#!/usr/bin/env bash
# task_complete.sh — status更新とinbox_writeを1コマンドへ束ねる（cmd_188前半）
#
# 背景: 従来の手順は write_report → update_status(done) → inbox_write の
# 三手に分かれており、一番軽い最後の一手（status更新）が抜け落ちる事故が
# 繰り返し起きた。本スクリプトは両者を1コマンドへ束ね、片方だけ済ませて
# 忘れる余地を構造的に減らす。
#
# 設計: queue/reports/gunshi_report.yaml の design_front_half 節（軍師設計）
# に基づく。再設計はしていない。
#
# Usage:
#   bash scripts/task_complete.sh \
#     --task-id <task_id> \
#     --to      <next_agent> \
#     --message "<引き継ぎ本文>" \
#     [--agent  <agent_id>]           # 省略時 tmux @agent_id から自己解決
#     [--type   <inbox type>]         # 既定 report_received
#     [--status done|failed|blocked]  # 既定 done
#     [--no-report]                   # 報告突き合わせ前提条件を外す
#     [--dry-run]                     # preflightのみ。一切書き換えぬ
#
# exit codes (常に標準エラーへ1行の状態説明を伴う):
#   0 成功
#   2 前提不一致（何も変えていない）
#   3 報告未着（何も変えていない）
#   4 inbox_write失敗・status巻き戻し済み
#   5 巻き戻し失敗・手当て要

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "[task_complete] $2" >&2; exit "$1"; }

# --- 引数解析 ---
AGENT=""
TASK_ID=""
TO=""
MESSAGE=""
TYPE="report_received"
STATUS="done"
REQUIRE_REPORT=1
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --task-id) TASK_ID="$2"; shift 2 ;;
        --to) TO="$2"; shift 2 ;;
        --message) MESSAGE="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        --type) TYPE="$2"; shift 2 ;;
        --status) STATUS="$2"; shift 2 ;;
        --no-report) REQUIRE_REPORT=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) die 2 "未知の引数: $1" ;;
    esac
done

[ -n "$TASK_ID" ] || die 2 "--task-idは必須である"
[ -n "$TO" ]      || die 2 "--toは必須である"
[ -n "$MESSAGE" ] || die 2 "--messageは必須である"

: "${AGENT:=$(tmux display-message -t "${TMUX_PANE:-}" -p '#{@agent_id}' 2>/dev/null || true)}"
TASK_FILE="$ROOT/queue/tasks/${AGENT}.yaml"
REPORT_FILE="$ROOT/queue/reports/${AGENT}_report.yaml"

# --- P1..P7 preflight ---
[ -n "$AGENT" ]      || die 2 "agentを解決できぬ。--agentで明示せよ"
[ -f "$TASK_FILE" ]  || die 2 "task YAMLが無い: $TASK_FILE"
cur_id=$(grep -m1 '^  task_id:' "$TASK_FILE" | sed -E 's/^  task_id:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')
[ "$cur_id" = "$TASK_ID" ] || die 2 "task_id不一致: YAML=$cur_id 指定=$TASK_ID"
cur_status=$(grep -m1 '^  status:' "$TASK_FILE" | sed -E 's/^  status:[[:space:]]*//')
[ "$TO" != "$AGENT" ] || die 2 "自己宛の引き継ぎは成立せぬ"
case "$MESSAGE" in *"'''"*) die 2 "messageに三重引用符を含めてはならぬ";; esac
case "$MESSAGE" in *\\*) echo "[task_complete] 警告: messageにバックスラッシュを含む。\\n等は改行へ化ける" >&2;; esac

if [ "$REQUIRE_REPORT" = 1 ]; then
    [ -f "$REPORT_FILE" ] || die 3 "報告YAMLが無い。報告を書いてから呼べ"
    r_id=$(grep -m1 '^task_id:' "$REPORT_FILE" | sed -E 's/^task_id:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')
    [ "$r_id" = "$TASK_ID" ] || die 3 "報告のtask_idが違う: $r_id"
    grep -qE '^status: (done|failed|blocked)' "$REPORT_FILE" || die 3 "報告のstatusが未確定である"
fi

if [ "$DRY_RUN" = 1 ]; then
    echo "[task_complete] dry-run: preflight 全通過"
    exit 0
fi

# --- M1..M3 可逆側 ---
BACKUP="$(mktemp)"
cp "$TASK_FILE" "$BACKUP"

# flockはmacOS(util-linux非搭載)に無いため、mkdirの原子性を第一の排他機構とする
# （inbox_write.shと同じ様式）。flockが使える環境ではさらに二重に確保する。
LOCK_DIR="${TASK_FILE}.lock.d"
_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done
    if command -v flock &>/dev/null; then
        exec 201>"${TASK_FILE}.lock"
        flock -w 5 201 || { rmdir "$LOCK_DIR" 2>/dev/null; return 1; }
    fi
    return 0
}
_release_lock() {
    if command -v flock &>/dev/null; then
        exec 201>&- 2>/dev/null || true
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
_acquire_lock || die 2 "task YAMLのロックを取れぬ"
trap _release_lock EXIT

tmp="$(mktemp)"
awk -v st="$STATUS" -v ts="$(date -Iseconds)" '
  !done_st && /^  status: / { print "  status: " st; print "  completed_at: \"" ts "\""; done_st=1; next }
  /^  completed_at: / && done_st { next }
  { print }
' "$TASK_FILE" > "$tmp" && mv "$tmp" "$TASK_FILE"

[ "$(grep -cE "^  status: ${STATUS}$" "$TASK_FILE")" -eq 1 ] || {
    cp "$BACKUP" "$TASK_FILE"
    die 2 "status行の書き換えに失敗した（巻き戻し済）"
}

# --- M4..M5 不可逆側 ---
if bash "$ROOT/scripts/inbox_write.sh" "$TO" "$MESSAGE" "$TYPE" "$AGENT"; then
    echo "[task_complete] 完了: status=$STATUS, 引き継ぎ→$TO"
    exit 0
fi

if cp "$BACKUP" "$TASK_FILE"; then
    die 4 "inbox_writeに失敗。statusを$cur_statusへ巻き戻した。バトンは貴殿が保持しておる。原因を除いて同じ命令を再実行せよ"
fi
die 5 "inbox_write失敗・巻き戻しも失敗。手で直せ: ${TASK_FILE}のstatusを${cur_status}へ戻し、${TO}へinbox_writeせよ"
