#!/usr/bin/env bash
# scripts/secret_scan.sh
#
# 公開リポジトリで秘密（ntfyトピック・APIキー等）を追跡ツリーへ書き込んで
# いないことを機械的に確かめる検査器（cmd_242）。gunshi_design_242_secret_scan
# 設計に基づく。
#
# 形式はbashラッパ＋python3ヒアドキュメント（lib/stall_policy.shの
# baton_watchdog_queryと同じ家中の作法）。理由: このセッションのgrepは
# ugrepを呼ぶシェル関数、macOS runnerのgrepはBSDであり、正規表現をgrepに
# 委ねると環境ごとの挙動が読めない（CLAUDE.md「常駐デーモンの再起動」節
# C-5相乗り参照）。python3標準の`re`モジュールに一本化することでこの
# 方言問題を原理的に回避する。
#
# Usage:
#   secret_scan.sh --staged                    # pre-commit用: git indexの内容を走査
#   secret_scan.sh --range <old-sha>..<new-sha> # pre-push用: 変更ファイルの新版を走査
#   secret_scan.sh --all                        # CI用: 追跡ツリー全体を走査
#   [--ignore-file PATH]                        # 既定: <repo_root>/.secretscanignore
#
# 終了コード:
#   0 = block重大度の検出なし（warnのみ、または検出なし）
#   1 = block重大度の検出が1件以上（allowlistで抑止された分を除く）
#   2 = 使用法エラー、または .secretscanignore の行フォーマット不正
#
# 出力規律: 検出した値そのものは一切出力しない。path:line・rule・
# severity・valuelen のみで指す（本スクリプト自身の出力が二次露出に
# ならぬため）。

set -euo pipefail

MODE=""
RANGE_SPEC=""
IGNORE_FILE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged)
            MODE="staged"
            shift
            ;;
        --all)
            MODE="all"
            shift
            ;;
        --range)
            MODE="range"
            RANGE_SPEC="${2:-}"
            [[ -n "$RANGE_SPEC" ]] || { echo "ERROR: --range には <old>..<new> を指定せよ" >&2; exit 2; }
            shift 2
            ;;
        --ignore-file)
            IGNORE_FILE_OVERRIDE="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: 不明な引数: $1" >&2
            echo "Usage: secret_scan.sh --staged | --all | --range <old>..<new> [--ignore-file PATH]" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "Usage: secret_scan.sh --staged | --all | --range <old>..<new> [--ignore-file PATH]" >&2
    exit 2
fi

python_bin=""
for candidate in "python3" "python"; do
    if command -v "$candidate" >/dev/null 2>&1; then
        python_bin="$candidate"
        break
    fi
done
[[ -n "$python_bin" ]] || { echo "ERROR: python3 が見つからない" >&2; exit 2; }

exec "$python_bin" - "$MODE" "$RANGE_SPEC" "$IGNORE_FILE_OVERRIDE" <<'PY'
import math
import os
import re
import subprocess
import sys
from collections import Counter

EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
Z40 = "0" * 40


def run_git(args, cwd):
    result = subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=False
    )
    return result.returncode, result.stdout, result.stderr


def run_git_bytes(args, cwd):
    """バイナリ安全な取得（`git show`のblob内容取得専用）。text=Trueだと
    バイナリblobでUnicodeDecodeErrorが起き得るため、生bytesで受ける。"""
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, check=False)
    return result.returncode, result.stdout, result.stderr


def git_or_die(args, cwd):
    rc, out, err = run_git(args, cwd)
    if rc != 0:
        sys.stderr.write(f"ERROR: git {' '.join(args)} 失敗: {err.strip()}\n")
        sys.exit(2)
    return out


# ============================================================
# ルール定義
# ============================================================

VENDOR_RULES = [
    ("secret-key-block", "block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("aws-access-key", "block", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("github-token", "block", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b")),
    ("slack-token", "block", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("google-api-key", "block", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("anthropic-api-key", "block", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{20,}\b")),
    ("openai-api-key", "block", re.compile(r"\bsk-(?!ant-)[A-Za-z0-9]{20,}\b")),
    ("jwt-token", "block", re.compile(
        r"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"
    )),
    ("credential-url", "block", re.compile(
        r"\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s/:@]+:[^\s/@]+@"
    )),
    ("ntfy-topic-url", "block", re.compile(
        r"(?<!docs\.)\bntfy\.sh/[A-Za-z0-9_\-]{3,}\b"
    )),
]

ASSIGNMENT_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*["\']([^"\']{6,})["\']')

# 秘密らしきキーの語（settings.yaml種抽出のような部分一致ではなく、
# 単語単位の完全一致で判定する — でなければ prefKey/authProvider の
# ような無関係な識別子が"key"/"auth"部分文字列に誤爆する（実測で
# 46件のうち大半がこれであった）。
PATTERN_SINGLE_WORD_KEYWORDS = frozenset({
    "password", "passwd", "pwd", "secret", "token", "webhook", "auth",
    "cred", "credential", "topic",
})
# "key"は単独では汎用語すぎる（prefKey等）ため、直前の語との複合形の
# みを秘密キーとみなす。
PATTERN_COMPOUND_KEY_PAIRS = frozenset({
    ("api", "key"), ("access", "key"), ("secret", "key"),
    ("private", "key"), ("auth", "key"), ("signing", "key"),
})


def tokenize_identifier(name):
    words = []
    for part in re.split(r"[_\-]+", name):
        if not part:
            continue
        subs = re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z0-9]+", part)
        words.extend((w.lower() for w in subs) if subs else [part.lower()])
    return words


def is_secret_like_identifier(name):
    words = tokenize_identifier(name)
    if set(words) & PATTERN_SINGLE_WORD_KEYWORDS:
        return True
    for i in range(len(words) - 1):
        if (words[i], words[i + 1]) in PATTERN_COMPOUND_KEY_PAIRS:
            return True
    return False


PLACEHOLDER_RE = re.compile(
    r"(?i)(your|example|sample|changeme|xxx|dummy|placeholder|todo|foo|bar|here)|[<>]|\.\.\."
)
SYNTH_PREFIX_RE = re.compile(r"(?i)^(test|fake|mock|synthetic|dummy|sample)[-_]")


def shannon_entropy(value):
    if not value:
        return 0.0
    counts = Counter(value)
    length = len(value)
    return -sum((n / length) * math.log2(n / length) for n in counts.values())


def check_assignment_line(line):
    """引用符付き秘密代入規則。4フィルタを通過した候補のみ返す（gunshi_report
    engine_decision.two_rule_families.family_B.assignment_filter 準拠）。"""
    hits = []
    for m in ASSIGNMENT_RE.finditer(line):
        key, value = m.group(1), m.group(2)
        key_lower = key.lower()
        if not is_secret_like_identifier(key):
            continue
        if "$" in value:
            # filter1の延長: 引用符で囲まれていても`$VAR`/`$(...)`/`${...}`
            # のような変数参照・コマンド置換はリテラルでない（実測:
            # lib/branch_policy.sh・lib/ntfy_auth.shの変数参照3件相当）
            continue
        if PLACEHOLDER_RE.search(value):
            continue
        if SYNTH_PREFIX_RE.match(value):
            continue
        if value.lower() == key_lower:
            continue
        entropy = shannon_entropy(value)
        threshold = 2.6 if any(ch.isdigit() for ch in value) else 3.2
        if entropy < threshold:
            continue
        hits.append(("secret-assignment", value))
    return hits


# ============================================================
# 種規則（seed rules） — ローカルのみ。存在せぬ環境では静かに飛ばす。
# ============================================================

def load_settings_seeds(repo_root):
    """config/settings.yaml の秘密らしきキー（値が文字列）のみを種とする。
    gitignore対象ゆえCIには存在しない — その場合は空リストを返すのみで
    エラーにしない。"""
    path = os.path.join(repo_root, "config", "settings.yaml")
    if not os.path.isfile(path):
        return []
    try:
        import yaml
    except ImportError:
        sys.stderr.write("WARN: PyYAML が無く config/settings.yaml の種を読めない。パターン規則のみで走行する\n")
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception as exc:
        sys.stderr.write(f"WARN: config/settings.yaml の読み込みに失敗: {exc}\n")
        return []

    # settings.yaml は小さく信頼できるファイルであるため、パターン規則
    # （PATTERN_SINGLE_WORD_KEYWORDS、単語単位一致）より広い部分一致で
    # よい——種として拾いすぎても実害は無く（値が一致する箇所が実際に
    # 存在する場合のみ発火する）、拾い漏らす方が危険である。
    seed_key_hints = ("topic", "key", "secret", "token", "password", "webhook", "auth", "cred")

    seeds = []

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                key_lower = str(k).lower()
                if isinstance(v, str) and len(v) >= 4 and any(
                    kw in key_lower for kw in seed_key_hints
                ):
                    seeds.append(v)
                walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(data)
    return seeds


def load_local_seed_file(repo_root):
    """config/secret_seeds.local（新設・gitignore対象・在れば読む）。
    一行一値、#始まりはコメント、空行は無視。"""
    path = os.path.join(repo_root, "config", "secret_seeds.local")
    if not os.path.isfile(path):
        return []
    seeds = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            seeds.append(line)
    return seeds


def load_user_seed():
    """$USER（OSユーザ名）。CI環境（GitHub ActionsがCI=trueを設定）では
    汎用値（例: runner）を種にすると誤検知の元になるため静かに飛ばす —
    これはCIにconfig/settings.yaml・secret_seeds.localが存在しないのと
    同じ理屈（『いずれも存在せぬ環境では種規則を静かに飛ばす』の帰結）。"""
    if os.environ.get("CI"):
        return []
    user = os.environ.get("USER") or os.environ.get("USERNAME") or ""
    user = user.strip()
    if len(user) < 4:
        return []
    return [user]


# ============================================================
# ファイル収集（モード別）
# ============================================================

def is_probably_text(content_bytes):
    if b"\x00" in content_bytes:
        return False
    try:
        content_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def collect_files_all(repo_root):
    out = git_or_die(["ls-files", "-z"], repo_root)
    files = [f for f in out.split("\x00") if f]
    result = {}
    for rel_path in files:
        abs_path = os.path.join(repo_root, rel_path)
        if not os.path.isfile(abs_path):
            continue
        with open(abs_path, "rb") as fh:
            raw = fh.read()
        if not is_probably_text(raw):
            continue
        result[rel_path] = raw.decode("utf-8")
    return result


def collect_files_staged(repo_root):
    out = git_or_die(
        ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], repo_root
    )
    files = [f for f in out.split("\x00") if f]
    result = {}
    for rel_path in files:
        rc, raw, _err = run_git_bytes(["show", f":{rel_path}"], repo_root)
        if rc != 0:
            continue
        if not is_probably_text(raw):
            continue
        result[rel_path] = raw.decode("utf-8")
    return result


def collect_files_range(repo_root, range_spec):
    if ".." not in range_spec:
        sys.stderr.write(f"ERROR: --range の形式が不正: {range_spec}\n")
        sys.exit(2)
    old_sha, new_sha = range_spec.split("..", 1)
    if new_sha == Z40 or not new_sha:
        # ブランチ削除等、新側が無い push。走査対象なし。
        return {}
    if old_sha == Z40 or not old_sha:
        # 新規ブランチのpush。差分の基点が無いため空木と比較し、
        # new_sha配下の全ファイルを「追加」として扱う。
        old_sha = EMPTY_TREE_SHA

    out = git_or_die(
        ["diff", "--name-only", "--diff-filter=ACMR", "-z", f"{old_sha}..{new_sha}"],
        repo_root,
    )
    files = [f for f in out.split("\x00") if f]
    result = {}
    for rel_path in files:
        rc, raw, _err = run_git_bytes(["show", f"{new_sha}:{rel_path}"], repo_root)
        if rc != 0:
            continue
        if not is_probably_text(raw):
            continue
        result[rel_path] = raw.decode("utf-8")
    return result


# ============================================================
# allowlist（.secretscanignore）
# ============================================================

def load_ignore_entries(ignore_path):
    """`<path>:<line>:<rule-id>  # <理由> (<cmd_id>)` の1行1件。
    理由・cmd_id欄を欠く行はエラー終了（allowlistが無言で増えるのを防ぐ）。
    パスのglobは禁止（構文上サポートしない = 常にリテラル一致）。
    戻り値: set of (path, line:int, rule_id)"""
    if not os.path.isfile(ignore_path):
        return set()

    entries = set()
    with open(ignore_path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, start=1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue

            if "#" not in line:
                sys.stderr.write(
                    f"ERROR: {ignore_path}:{lineno}: 理由・cmd_id欄(# ...)を欠く行\n"
                )
                sys.exit(2)

            spec, _, comment = line.partition("#")
            comment = comment.strip()
            if not comment or "(" not in comment or not comment.rstrip().endswith(")"):
                sys.stderr.write(
                    f"ERROR: {ignore_path}:{lineno}: 理由・cmd_id欄の書式が不正"
                    f"（'# <理由> (<cmd_id>)' 形式が必要）: {line}\n"
                )
                sys.exit(2)

            parts = spec.strip().split(":")
            if len(parts) != 3:
                sys.stderr.write(
                    f"ERROR: {ignore_path}:{lineno}: '<path>:<line>:<rule-id>' 形式が必要: {line}\n"
                )
                sys.exit(2)
            path_part, line_part, rule_part = parts
            if not line_part.isdigit():
                sys.stderr.write(
                    f"ERROR: {ignore_path}:{lineno}: 行番号が数値でない: {line}\n"
                )
                sys.exit(2)
            entries.add((path_part.strip(), int(line_part), rule_part.strip()))
    return entries


# ============================================================
# 走査本体
# ============================================================

def scan(files, seeds):
    findings = []  # (path, line, rule_id, severity, value)
    for rel_path, content in files.items():
        for lineno, line in enumerate(content.splitlines(), start=1):
            for rule_id, severity, pattern in VENDOR_RULES:
                if pattern.search(line):
                    findings.append((rel_path, lineno, rule_id, severity, ""))

            for rule_id, value in check_assignment_line(line):
                findings.append((rel_path, lineno, rule_id, "block", value))

            for seed in seeds:
                if seed and seed in line:
                    findings.append((rel_path, lineno, "seed-match", "block", seed))

    # 同一 (path, line, rule_id) は1件に畳む
    seen = set()
    deduped = []
    for path, lineno, rule_id, severity, value in findings:
        key = (path, lineno, rule_id)
        if key in seen:
            continue
        seen.add(key)
        deduped.append((path, lineno, rule_id, severity, value))
    deduped.sort(key=lambda f: (f[0], f[1], f[2]))
    return deduped


def main():
    mode, range_spec, ignore_override = sys.argv[1], sys.argv[2], sys.argv[3]
    repo_root = git_or_die(["rev-parse", "--show-toplevel"], os.getcwd()).strip()

    if mode == "all":
        files = collect_files_all(repo_root)
    elif mode == "staged":
        files = collect_files_staged(repo_root)
    elif mode == "range":
        files = collect_files_range(repo_root, range_spec)
    else:
        sys.stderr.write(f"ERROR: 不明なモード: {mode}\n")
        sys.exit(2)

    seeds = []
    seeds.extend(load_settings_seeds(repo_root))
    seeds.extend(load_local_seed_file(repo_root))
    seeds.extend(load_user_seed())

    findings = scan(files, seeds)

    ignore_path = ignore_override or os.path.join(repo_root, ".secretscanignore")
    ignored = load_ignore_entries(ignore_path)

    block_count = 0
    warn_count = 0
    suppressed_count = 0

    for path, lineno, rule_id, severity, value in findings:
        if (path, lineno, rule_id) in ignored:
            suppressed_count += 1
            continue
        print(f"{path}:{lineno} rule={rule_id} severity={severity} valuelen={len(value) if value else 0}")
        if severity == "block":
            block_count += 1
        else:
            warn_count += 1

    print(
        f"SECRET_SCAN: mode={mode} files_scanned={len(files)} "
        f"block={block_count} warn={warn_count} suppressed={suppressed_count}"
    )

    if block_count > 0:
        sys.exit(1)
    sys.exit(0)


main()
PY
