#!/usr/bin/env bats
# test_inbox_archive.bats — inbox_write.sh の overflow退避（archive）ユニットテスト
# cmd_172 P1: 既読メッセージのoverflow時「破棄」を「退避」に変更した挙動の検証
#
# テスト構成:
#   TC-ARCHIVE-001（最重要）: 未読メッセージは退避・削除されない不変条件
#   TC-ARCHIVE-002: 51件目書き込みで古い既読メッセージが正しく退避先に追記される
#   TC-ARCHIVE-003: 退避後もinbox本体に未読全件＋既読直近30件が正しく残る
#   TC-ARCHIVE-004: queue/inbox/archive/ が存在しない状態からでも作成・書き込みできる

# --- セットアップ（tests/test_inbox_write.bats と同じ隔離パターン） ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export INBOX_WRITE_SCRIPT="$PROJECT_ROOT/scripts/inbox_write.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    [ -f "$INBOX_WRITE_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/inbox_archive_test.XXXXXX")"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR"

    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$PROJECT_ROOT/scripts/inbox_write.sh" > "$TEST_SCRIPT_DIR/inbox_write.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_write.sh"

    ln -sf "$PROJECT_ROOT/.venv" "$TEST_TMPDIR/.venv"

    export TEST_INBOX_WRITE="$TEST_SCRIPT_DIR/inbox_write.sh"
    export TODAY="$(date +%Y-%m-%d)"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# TC-ARCHIVE-001（最重要）: 未読メッセージは退避・削除されない
# =============================================================================

@test "TC-ARCHIVE-001: unread messages are never archived, even when total exceeds 50" {
    # 未読11件 + 既読45件を事前作成（合計56件、overflow発生）
    "$VENV_PYTHON" <<EOF
import yaml

messages = []
for i in range(11):
    messages.append({
        'id': f'msg_unread_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T00:{i:02d}:00',
        'type': 'test_type',
        'content': f'未読メッセージ {i}',
        'read': False
    })
for i in range(45):
    messages.append({
        'id': f'msg_read_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T01:{i:02d}:00',
        'type': 'test_type',
        'content': f'既読メッセージ {i}',
        'read': True
    })

data = {'messages': messages}
with open('$TEST_INBOX_DIR/test_agent.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    run bash "$TEST_INBOX_WRITE" "test_agent" "新規未読" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # 検証: (1) inbox本体の未読は全12件が残っている
    #       (2) 退避先ファイルが存在する場合、その中に read: false のメッセージは1件も無い
    "$VENV_PYTHON" <<EOF
import yaml, glob

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

unread = [m for m in data['messages'] if not m.get('read', False)]
assert len(unread) == 12, f'Expected 12 unread messages preserved, got {len(unread)}'

archive_files = glob.glob('$TEST_INBOX_DIR/archive/test_agent-*.yaml')
for af_path in archive_files:
    with open(af_path) as af:
        archive_data = yaml.safe_load(af)
    for msg in archive_data.get('messages', []):
        assert msg.get('read', False) is True, f'Unread message leaked into archive: {msg}'

print('TC-ARCHIVE-001: PASS')
EOF
}

# =============================================================================
# TC-ARCHIVE-002: 51件目の書き込みで古い既読メッセージが退避先に追記される
# =============================================================================

@test "TC-ARCHIVE-002: 51st message triggers archiving of oldest read messages, content preserved" {
    # 既読60件を事前作成（読了順を維持するためtimestampを連番に）
    "$VENV_PYTHON" <<EOF
import yaml

messages = []
for i in range(60):
    messages.append({
        'id': f'msg_old_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T00:{i:02d}:00',
        'type': 'test_type',
        'content': f'既読メッセージ {i:03d}',
        'read': True
    })

data = {'messages': messages}
with open('$TEST_INBOX_DIR/test_agent.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    run bash "$TEST_INBOX_WRITE" "test_agent" "新規メッセージ" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # 退避先ファイルが本日日付で作成されていること
    [ -f "$TEST_INBOX_DIR/archive/test_agent-$TODAY.yaml" ]

    # 検証: 破棄されていたはずの古い既読30件（msg_old_000〜msg_old_029）が
    #       退避先に内容そのまま残っていること
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/archive/test_agent-$TODAY.yaml') as f:
    archive_data = yaml.safe_load(f)

archived_ids = {m['id'] for m in archive_data['messages']}
expected_archived = {f'msg_old_{i:03d}' for i in range(30)}
assert expected_archived.issubset(archived_ids), f'Missing archived messages: {expected_archived - archived_ids}'

# 内容が失われていないことを確認（1件サンプル検証）
sample = next(m for m in archive_data['messages'] if m['id'] == 'msg_old_000')
assert sample['content'] == '既読メッセージ 000', f'Archived content mismatch: {sample["content"]}'

print('TC-ARCHIVE-002: PASS')
EOF
}

# =============================================================================
# TC-ARCHIVE-003: 退避後もinbox本体に未読全件＋既読直近30件が正しく残る
# =============================================================================

@test "TC-ARCHIVE-003: inbox body retains all unread + newest 30 read after archiving" {
    "$VENV_PYTHON" <<EOF
import yaml

messages = []
for i in range(5):
    messages.append({
        'id': f'msg_unread_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T00:{i:02d}:00',
        'type': 'test_type',
        'content': f'未読 {i}',
        'read': False
    })
for i in range(60):
    messages.append({
        'id': f'msg_old_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T01:{i:02d}:00',
        'type': 'test_type',
        'content': f'既読 {i:03d}',
        'read': True
    })

data = {'messages': messages}
with open('$TEST_INBOX_DIR/test_agent.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    run bash "$TEST_INBOX_WRITE" "test_agent" "新規未読メッセージ" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

unread = [m for m in data['messages'] if not m.get('read', False)]
read = [m for m in data['messages'] if m.get('read', False)]

assert len(unread) == 6, f'Expected 6 unread (5 original + 1 new), got {len(unread)}'
assert len(read) == 30, f'Expected 30 read messages retained, got {len(read)}'

# 直近30件は既読の末尾30件（msg_old_030〜msg_old_059）であること
retained_ids = {m['id'] for m in read}
expected_retained = {f'msg_old_{i:03d}' for i in range(30, 60)}
assert retained_ids == expected_retained, f'Retained read set mismatch: {retained_ids ^ expected_retained}'

print('TC-ARCHIVE-003: PASS')
EOF
}

# =============================================================================
# TC-ARCHIVE-004: queue/inbox/archive/ が存在しない状態からでも作成・書き込みできる
# =============================================================================

@test "TC-ARCHIVE-004: archive/ directory is created from scratch when missing" {
    [ ! -d "$TEST_INBOX_DIR/archive" ]

    "$VENV_PYTHON" <<EOF
import yaml

messages = []
for i in range(60):
    messages.append({
        'id': f'msg_old_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T00:{i:02d}:00',
        'type': 'test_type',
        'content': f'既読メッセージ {i}',
        'read': True
    })

data = {'messages': messages}
with open('$TEST_INBOX_DIR/test_agent.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    [ ! -d "$TEST_INBOX_DIR/archive" ]

    run bash "$TEST_INBOX_WRITE" "test_agent" "新規メッセージ" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    [ -d "$TEST_INBOX_DIR/archive" ]
    [ -f "$TEST_INBOX_DIR/archive/test_agent-$TODAY.yaml" ]

    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/archive/test_agent-$TODAY.yaml') as f:
    archive_data = yaml.safe_load(f)

assert len(archive_data['messages']) == 30, f'Expected 30 archived messages, got {len(archive_data["messages"])}'

print('TC-ARCHIVE-004: PASS')
EOF
}
