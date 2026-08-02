---
name: inbox-write
description: 別エージェントのinboxにメッセージを送信する。agent-to-agent通信の唯一の手段。
---

他のエージェントにメッセージを送るには、必ずこのスキルを使うこと。
tmux send-keys で直接メッセージを送ることは禁止。

## 使い方

**本文の渡し方は2つある。「本文に記号を含むか」で選べ。**

**(1) 記号（バッククォート・`$(...)`・`$VAR`・`${...}`）を含む本文
→ ファイルで渡す（フラグ形式）。** 本文がシェルを通らぬゆえ、展開は
原理的に起こり得ない:

```bash
# 本文は Write ツールで書く（シェルを経由せぬ）。その上で:
bash scripts/inbox_write.sh --to karo --content-file <path> \
     --type report_received --from gunshi
```

**(2) 記号を含まぬ平文 → 従来の位置引数。単一引用符で囲め。**

```bash
bash scripts/inbox_write.sh <target_agent> '<message>' <type> <from>
```

**バッククォート・`$(...)`・`$VAR` を含む本文を二重引用符で囲むな。**
呼び手のシェルがスクリプト起動**前に**展開する。本文が黙って書き換わる
だけでなく、**置換された中身が実行される**——2026-08-02、本文中の
バッククォートが `watcher_supervisor.sh` を起動させ、呼び出しが2分半
ハングし、そのメッセージは一度も届かなかった。

補足: 単一引用符の中にアポストロフィは書けぬ。本文にアポストロフィが
要るなら (1) のファイル形式を使え。

### type 一覧

| type | 用途 |
|------|------|
| `cmd_new` | 新規コマンド（shogun→karo） |
| `task_assigned` | タスク割り当て（karo→ashigaru） |
| `report_received` | 作業完了報告（ashigaru→karo/gunshi） |
| `clear_command` | セッションリセット指示 |
| `model_switch` | モデル切り替え指示 |

### 例

```bash
bash scripts/inbox_write.sh karo 'cmd_048を書いた。実行せよ。' cmd_new shogun
bash scripts/inbox_write.sh ashigaru3 'タスクYAMLを読んで作業開始せよ。' task_assigned karo
bash scripts/inbox_write.sh gunshi '足軽5号、任務完了。品質チェックを仰ぎたし。' report_received ashigaru5
```
