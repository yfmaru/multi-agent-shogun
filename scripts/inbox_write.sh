#!/usr/bin/env bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from>
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5
#
# 記号（バッククォート・$(...)・$VAR・${...}）を含む本文はファイル経由で渡せ:
#   bash scripts/inbox_write.sh --to karo --content-file <path> --type report_received --from gunshi
#
# 過去の既読メッセージ（overflow時に退避されたもの）を参照したい場合は
# `grep` で `queue/inbox/archive/<agent>-*.yaml` を検索せよ。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 第1引数が -- で始まらなければ従来経路（位置引数）。始まればフラグ形式。
if [ "${1:-}" = "${1#--}" ]; then
    TARGET="$1"
    CONTENT="$2"
    TYPE="$3"
    FROM="$4"
else
    CONTENT_FILE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --to)
                [ $# -ge 2 ] || { echo "[inbox_write] --to には値が必要である" >&2; exit 1; }
                TARGET="$2"; shift 2 ;;
            --content-file)
                [ $# -ge 2 ] || { echo "[inbox_write] --content-file には値が必要である" >&2; exit 1; }
                CONTENT_FILE="$2"; shift 2 ;;
            --type)
                [ $# -ge 2 ] || { echo "[inbox_write] --type には値が必要である" >&2; exit 1; }
                TYPE="$2"; shift 2 ;;
            --from)
                [ $# -ge 2 ] || { echo "[inbox_write] --from には値が必要である" >&2; exit 1; }
                FROM="$2"; shift 2 ;;
            *) echo "[inbox_write] 未知の引数: $1" >&2; exit 1 ;;
        esac
    done
    [ -n "$CONTENT_FILE" ] || {
        echo "[inbox_write] フラグ形式では --content-file が必須である。inline本文は従来の位置引数で渡せ" >&2; exit 1; }
    [ -r "$CONTENT_FILE" ] || {
        echo "[inbox_write] --content-file が読めぬ: $CONTENT_FILE" >&2; exit 1; }
    CONTENT=$(cat -- "$CONTENT_FILE") || {
        echo "[inbox_write] --content-file の読み取りに失敗した" >&2; exit 1; }
    [ -n "$CONTENT" ] || {
        echo "[inbox_write] --content-file が空である: $CONTENT_FILE" >&2; exit 1; }
fi

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ] || [ -z "$TYPE" ] || [ -z "$FROM" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from>" >&2
    exit 1
fi

# Self-send guard: reject messages where sender == target
if [ "$FROM" = "$TARGET" ]; then
    echo "[inbox_write] REJECTED: self-send detected (from=$FROM, target=$TARGET)" >&2
    exit 1
fi

# Initialize inbox if not exists
# dangling symlink recovery: queue/inbox が壊れたシンボリックリンクならリンク先を再生成
_inbox_parent="$(dirname "$INBOX")"
if [ -L "$_inbox_parent" ] && [ ! -d "$_inbox_parent" ]; then
    mkdir -p "$(readlink "$_inbox_parent")"
fi
if [ ! -f "$INBOX" ]; then
    mkdir -p "$_inbox_parent"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp + 4 random bytes).
# Use `od` instead of `xxd` because `od` is available on both GNU/Linux and macOS runners by default.
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Cross-process lock: mkdir coordinates with OpenCode tools; flock is added when available.
LOCK_DIR="${LOCKFILE}.d"

_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Atomic write with lock (3 retries)
attempt=0
max_attempts=3

while [ $attempt -lt $max_attempts ]; do
    if _acquire_lock; then
        trap _release_lock EXIT
        if INBOX="$INBOX" MSG_ID="$MSG_ID" FROM="$FROM" TIMESTAMP="$TIMESTAMP" \
           TYPE="$TYPE" CONTENT="$CONTENT" TARGET="$TARGET" \
           "$SCRIPT_DIR/.venv/bin/python3" - <<'PYSRC'
import yaml, sys
import tempfile, os

try:
    # Load existing inbox
    with open(os.environ["INBOX"]) as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get('messages'):
        data['messages'] = []

    # Add new message
    new_msg = {
        'id': os.environ["MSG_ID"],
        'from': os.environ["FROM"],
        'timestamp': os.environ["TIMESTAMP"],
        'type': os.environ["TYPE"],
        'content': os.environ["CONTENT"],
        'read': False
    }
    data['messages'].append(new_msg)

    # Overflow protection: keep max 50 messages.
    # Older read messages are archived (not discarded) to queue/inbox/archive/.
    if len(data['messages']) > 50:
        msgs = data['messages']
        unread = [m for m in msgs if not m.get('read', False)]
        read = [m for m in msgs if m.get('read', False)]
        # Keep all unread + newest 30 read messages; archive the rest.
        to_archive = read[:-30] if len(read) > 30 else []
        data['messages'] = unread + read[-30:]

        # Invariant: unread (read: false) messages must NEVER be archived/discarded.
        if to_archive:
            archive_dir = os.path.join(os.path.dirname(os.environ["INBOX"]), 'archive')
            os.makedirs(archive_dir, exist_ok=True)
            archive_date = os.environ["TIMESTAMP"].split('T')[0]
            archive_path = os.path.join(archive_dir, os.environ["TARGET"] + '-' + archive_date + '.yaml')

            if os.path.exists(archive_path):
                with open(archive_path) as af:
                    archive_data = yaml.safe_load(af)
            else:
                archive_data = None
            if not archive_data:
                archive_data = {}
            if not archive_data.get('messages'):
                archive_data['messages'] = []
            archive_data['messages'].extend(to_archive)

            archive_tmp_fd, archive_tmp_path = tempfile.mkstemp(dir=archive_dir, suffix='.tmp')
            try:
                with os.fdopen(archive_tmp_fd, 'w') as af:
                    yaml.dump(archive_data, af, default_flow_style=False, allow_unicode=True, indent=2)
                os.replace(archive_tmp_path, archive_path)
            except:
                os.unlink(archive_tmp_path)
                raise

    # Atomic write: tmp file + rename (prevents partial reads)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(os.environ["INBOX"]), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, os.environ["INBOX"])
    except:
        os.unlink(tmp_path)
        raise

except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
PYSRC
        then
            STATUS=0
        else
            STATUS=$?
        fi
        _release_lock
        trap - EXIT
        [ $STATUS -eq 0 ] && exit 0
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep 1
    else
        # Lock timeout
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
