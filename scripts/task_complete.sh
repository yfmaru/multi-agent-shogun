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
# --message と --message-file <path> は排他。引き継ぎ本文に
# バッククォート・$(...)・$VAR を含める場合、--message（二重引用符）
# では呼び手のシェルがそれらを展開し本文が黙って壊れる（単一引用符で
# 守るか、シェルを経路から外す --message-file を用いよ。cmd_190）。
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

# --- pending_followups表示（cmd_203 案C・軍師設計） ---
# 「戻ってきて思い出す」の代わりに、条件成就させた当人の完了出力へ
# 強制的に割り込ませ、目に入れる。$TASK_FILE の parent_cmd を鍵に
# queue/shogun_to_karo.yaml の該当cmdブロックを引き、status: pending の
# followupだけを表示する（status: doneは表示しない＝案A側のデータを
# 読むだけで、本スクリプトは一切書き込まない）。
# 範囲抽出は厳密なYAML解析ではなく実用上十分な文字列処理でよい
# （cur_id等task_id抽出と同じ流儀）。他cmdのpending_followupsを拾わぬ
# ことが唯一の厳格な要件のため、cmdブロック境界は`  - id:`行で区切る。
_print_pending_followups() {
    local task_file="$1" karo_file="$2"
    local parent_cmd followups
    # parent_cmdは大半のtask YAMLに存在せぬ（本来任意のフィールド）。
    # grepが無一致=exit 1となり、pipefail下ではパイプライン全体の
    # 終了ステータスとなる。set -eの元でこれをそのまま代入させると
    # 「completion echo後・exit 0前」で関数自体が失敗しスクリプトが
    # 中断してしまう（status/inbox更新は済んでいるのに異常終了する
    # 重大な回帰）。`|| true`で無一致を正常系として吸収する。
    parent_cmd=$(grep -m1 '^  parent_cmd:' "$task_file" | sed -E 's/^  parent_cmd:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//' || true)
    [ -n "$parent_cmd" ] || return 0
    [ -f "$karo_file" ] || return 0
    followups="$(awk -v cmd="$parent_cmd" '
      function flush_item() {
        if (pf_status == "pending") {
          printf("  - %s: %s → %s\n", pf_id, pf_when, pf_then)
        }
        pf_in_item = 0
      }
      /^  - id: / {
        if (pf_in_item) flush_item()
        pf_in_item = 0; pf_in_pf = 0
        pf_blockid = $0
        sub(/^  - id: /, "", pf_blockid)
        gsub(/[[:space:]]+$/, "", pf_blockid)
        pf_in_block = (pf_blockid == cmd)
        next
      }
      !pf_in_block { next }
      /^    pending_followups:/ { pf_in_pf = 1; next }
      pf_in_pf && /^    [A-Za-z_]/ {
        if (pf_in_item) flush_item()
        pf_in_pf = 0
      }
      !pf_in_pf { next }
      /^      - id: / {
        if (pf_in_item) flush_item()
        pf_id = $0
        sub(/^      - id: /, "", pf_id)
        gsub(/[[:space:]]+$/, "", pf_id)
        pf_when = ""; pf_then = ""; pf_status = ""
        pf_in_item = 1
        next
      }
      pf_in_item && /^        when: / {
        pf_when = $0
        sub(/^        when: /, "", pf_when)
        sub(/^"/, "", pf_when)
        sub(/"$/, "", pf_when)
        next
      }
      pf_in_item && /^        then: / {
        pf_then = $0
        sub(/^        then: /, "", pf_then)
        sub(/^"/, "", pf_then)
        sub(/"$/, "", pf_then)
        next
      }
      pf_in_item && /^        status:/ {
        pf_status = $0
        sub(/^        status:[[:space:]]*/, "", pf_status)
        gsub(/[[:space:]]/, "", pf_status)
        next
      }
      END { if (pf_in_item) flush_item() }
    ' "$karo_file")"
    [ -n "$followups" ] || return 0
    echo "[task_complete] ⚠ この完了で条件成就し得るpending_followupsあり:"
    echo "$followups"
}

# --- 引数解析 ---
AGENT=""
TASK_ID=""
TO=""
MESSAGE=""
MESSAGE_FILE=""
TYPE="report_received"
STATUS="done"
REQUIRE_REPORT=1
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --task-id) TASK_ID="$2"; shift 2 ;;
        --to) TO="$2"; shift 2 ;;
        --message) MESSAGE="$2"; shift 2 ;;
        --message-file) MESSAGE_FILE="$2"; shift 2 ;;
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
# --message と --message-file は排他（cmd_190: シェルを経路から外すための
# ファイル渡し経路。両方あれば意図不明、どちらも無ければ本文が無い）
if [ -n "$MESSAGE" ] && [ -n "$MESSAGE_FILE" ]; then
    die 2 "--messageと--message-fileは同時指定できぬ"
fi
if [ -z "$MESSAGE" ] && [ -z "$MESSAGE_FILE" ]; then
    die 2 "--messageまたは--message-fileのいずれかが必須である"
fi
if [ -n "$MESSAGE_FILE" ]; then
    [ -r "$MESSAGE_FILE" ] || die 2 "--message-fileが読めぬ: $MESSAGE_FILE"
    MESSAGE=$(cat -- "$MESSAGE_FILE") || die 2 "--message-fileの読み取りに失敗した"
fi

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
# 三重引用符の禁止は、もはやPythonソース保護のためではない
#（cmd_196 S1でinbox_write.shの本文Pythonソース補間そのものを解体済み。
# 現在はos.environ経由で渡り、yaml.dumpが引用符を自前で処理する）。
# 撤去してよい状態だが、正当な本文が''' を含むことは稀であり無害ゆえ、
# 二重の守りとして意図的に残す。撤回されたバッククォート die 案(a)とは
# 別物ゆえ、--message-file経路でも等しく適用する（巻き添えで外さぬこと）。
case "$MESSAGE" in *"'''"*) die 2 "messageに三重引用符を含めてはならぬ";; esac
case "$MESSAGE" in *\\*) echo "[task_complete] 警告: messageにバックスラッシュを含む。\\n等は改行へ化ける" >&2;; esac

# cmd_190: 呼び手のシェルが message を展開した痕跡を探す。
# 展開後の文字列からは検知できぬため、親プロセスのcmdlineに残る
# 「展開前の生テキスト」と突き合わせる（設計: gunshi_190_design.yaml）。
# 誤検知の類型が実在するため **die にはせず警告に留める**。
# --message-file経路は原理的に展開が起こり得ぬため検査しない
# （ファイル内容はコマンド行に現れず、行えば必ず誤検知になる）。
if [ -z "$MESSAGE_FILE" ] && [ -r "/proc/$PPID/cmdline" ]; then
    raw=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null || true)
    if [ -n "$raw" ]; then
        case "$raw" in
            *"$MESSAGE"*) : ;;   # 逐語で在る＝展開されておらぬ
            *) echo "[task_complete] 警告: messageが呼び手のシェルで展開された可能性がある（受け取った本文が元のコマンド行に逐語で現れぬ）。バッククォート・\$(...)・\$VAR を含む本文は単一引用符で囲むか、--message-file を用いよ" >&2 ;;
        esac
    fi
fi || true

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
# BACKUPも書き込み先と同じディレクトリに置く（mvの原子性理由は下記tmp参照）
BACKUP="$(mktemp "${TASK_FILE}.bak.XXXXXX")"
cp "$TASK_FILE" "$BACKUP"
# BACKUP代入の後にtrapを設定（先だとBACKUPが空文字列になる）。
# この時点ではロックを保持しておらぬゆえ、後始末はBACKUPのみに限る。
# _release_lockをここで呼ぶと、(a)ロック取得に失敗した側が
# 「保持者のロック」をrmdirして排他が壊れ、(b)未定義のまま呼ばれると
# set -eでtrapが中断し rm -f 自体が実行されぬ。
trap 'rm -f "$BACKUP"' EXIT

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
# ロックを実際に取得した者だけが解放を担う（取得成功後に差し替える）
trap '_release_lock; rm -f "$BACKUP"' EXIT

# 書き込み先と同じディレクトリに置く: mktempの既定(/tmp)は別デバイスの
# ことがあり、その場合mvがrename(2)にならずcopy+unlinkとなって
# 書き換え中にファイルが一瞬消える窓が生じる（inbox_write.shと同じ様式）
tmp="$(mktemp "${TASK_FILE}.XXXXXX")"
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
    _print_pending_followups "$TASK_FILE" "$ROOT/queue/shogun_to_karo.yaml"
    exit 0
fi

if cp "$BACKUP" "$TASK_FILE"; then
    die 4 "inbox_writeに失敗。statusを${cur_status}へ巻き戻した。バトンは貴殿が保持しておる。原因を除いて同じ命令を再実行せよ"
fi
die 5 "inbox_write失敗・巻き戻しも失敗。手で直せ: ${TASK_FILE}のstatusを${cur_status}へ戻し、${TO}へinbox_writeせよ"
