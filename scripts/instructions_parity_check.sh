#!/usr/bin/env bash
# instructions_parity_check.sh — 手書き版 instructions/<role>.md と
# 生成元 instructions/roles/<role>_role.md + instructions/common/*.md の
# 見出し食い違いを機械的に検出する（cmd_203 T1）。
#
# 出力する3種:
#   (a) 手書き版にのみ存在する見出し
#   (b) 生成元にのみ存在する見出し（common/・cli_specific/ 由来の
#       当然の差は除外し、roles/<role>_role.md 固有の差分のみを残す）
#   (c) 両者に共通する見出しについて、本文を行単位でdiffした差分行数
#
# 見出し抽出の規則（両者に同一に適用）:
#   - YAML front matter（先頭の --- ... --- ブロック）は対象外
#   - フェンスコードブロック（``` ... ```）内の `#` コメント行は対象外
#   - レベル1見出し（`^# `）は対象外——各ファイルの文書タイトル行であり、
#     ファイルごとに異なることが設計上自明なため（例:
#     「# Shogun Instructions」 対 「# Shogun Role Definition」）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTRUCTIONS_DIR="$ROOT_DIR/instructions"

ALL_ROLES=(shogun karo gunshi ashigaru)
ROLES=()

usage() {
    cat <<'EOF'
Usage: instructions_parity_check.sh [--role <shogun|karo|gunshi|ashigaru>]

役職ごとに、手書き版 instructions/<role>.md と生成元
instructions/roles/<role>_role.md + instructions/common/*.md の
見出し食い違いを出力する。--role 省略時は4役職すべてを対象とする。

終了コード:
  0 = 差分（a/b/cいずれも）なし
  1 = 差分あり
  2 = 引数エラー・対象ファイル欠落
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            [[ -n "${2:-}" ]] || { echo "ERROR: --role には値が要る" >&2; usage >&2; exit 2; }
            ROLES+=("$2")
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ${#ROLES[@]} -eq 0 ]]; then
    ROLES=("${ALL_ROLES[@]}")
fi

for role in "${ROLES[@]}"; do
    valid=0
    for r in "${ALL_ROLES[@]}"; do
        [[ "$role" == "$r" ]] && valid=1
    done
    if [[ "$valid" -ne 1 ]]; then
        echo "ERROR: unknown role: $role (expected one of: ${ALL_ROLES[*]})" >&2
        exit 2
    fi
done

# 見出し抽出: front matter とフェンスコードブロックを除外し、
# レベル2以上（## 以上）の見出し行のみを出力する。
extract_headings() {
    local file="$1"
    awk '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---" { infm=0; next }
        infm { next }
        /^```/ { infence = !infence; next }
        infence { next }
        /^#{2,6}[[:space:]]/ { print }
    ' "$file"
}

# 見出し配下の本文を切り出す（見出し行から次の見出し行の手前まで、
# front matter・フェンスコードブロックは extract_headings と同じ扱い）。
extract_section_body() {
    local file="$1"
    local heading="$2"
    awk -v target="$heading" '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---" { infm=0; next }
        infm { next }
        /^```/ { infence = !infence; if (found) print; next }
        infence { if (found) print; next }
        /^#{2,6}[[:space:]]/ {
            if (found) { exit }
            if ($0 == target) { found=1 }
            next
        }
        found { print }
    ' "$file"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# common/・cli_specific/ 由来の見出し集合（(b)の除外リスト）
COMMON_HEADINGS="$TMP_DIR/common_headings.txt"
: > "$COMMON_HEADINGS"
for f in "$INSTRUCTIONS_DIR"/common/*.md "$INSTRUCTIONS_DIR"/cli_specific/*.md; do
    [[ -f "$f" ]] || continue
    extract_headings "$f" >> "$COMMON_HEADINGS"
done
sort -u -o "$COMMON_HEADINGS" "$COMMON_HEADINGS"

EXIT_CODE=0
TOTAL_A=0
TOTAL_B=0
TOTAL_C=0

for role in "${ROLES[@]}"; do
    hw_file="$INSTRUCTIONS_DIR/${role}.md"
    role_file="$INSTRUCTIONS_DIR/roles/${role}_role.md"

    if [[ ! -f "$hw_file" ]]; then
        echo "ERROR: not found: $hw_file" >&2
        exit 2
    fi
    if [[ ! -f "$role_file" ]]; then
        echo "ERROR: not found: $role_file" >&2
        exit 2
    fi

    echo "[INFO] === role: $role ==="

    hw_headings="$TMP_DIR/hw_${role}.txt"
    gen_headings="$TMP_DIR/gen_${role}.txt"

    extract_headings "$hw_file" | sort -u > "$hw_headings"
    {
        extract_headings "$role_file"
        for f in "$INSTRUCTIONS_DIR"/common/*.md; do
            [[ -f "$f" ]] || continue
            extract_headings "$f"
        done
    } | sort -u > "$gen_headings"

    # (a) 手書き版にのみ存在する見出し
    a_diff="$TMP_DIR/a_${role}.txt"
    comm -23 "$hw_headings" "$gen_headings" > "$a_diff"
    a_count=$(wc -l < "$a_diff" | tr -d ' ')
    TOTAL_A=$((TOTAL_A + a_count))

    echo "[INFO] (a) 手書き版のみに存在する見出し: ${a_count}件"
    if [[ "$a_count" -gt 0 ]]; then
        EXIT_CODE=1
        while IFS= read -r line; do
            echo "[DIFF] (a) hw-only: $line"
        done < "$a_diff"
    fi

    # (b) 生成元にのみ存在する見出し（common/・cli_specific/ 由来を除外）
    b_diff="$TMP_DIR/b_${role}.txt"
    comm -13 "$hw_headings" "$gen_headings" | grep -vFxf "$COMMON_HEADINGS" > "$b_diff" || true
    b_count=$(wc -l < "$b_diff" | tr -d ' ')
    TOTAL_B=$((TOTAL_B + b_count))

    echo "[INFO] (b) 生成元のみに存在する見出し(common/cli_specific由来除く): ${b_count}件"
    if [[ "$b_count" -gt 0 ]]; then
        EXIT_CODE=1
        while IFS= read -r line; do
            echo "[DIFF] (b) gen-only: $line"
        done < "$b_diff"
    fi

    # (c) 両者に共通する見出しの本文diff
    common_headings_role="$TMP_DIR/common_role_${role}.txt"
    comm -12 "$hw_headings" "$gen_headings" > "$common_headings_role"
    c_count=0

    while IFS= read -r heading; do
        [[ -z "$heading" ]] && continue

        # 生成元側の本文取得元を決める: roles/<role>_role.md にあれば
        # そちらを優先し、無ければ common/*.md を探す。
        gen_body_file="$TMP_DIR/gen_body_${role}.txt"
        if extract_headings "$role_file" | grep -qFx "$heading"; then
            extract_section_body "$role_file" "$heading" > "$gen_body_file"
        else
            : > "$gen_body_file"
            for f in "$INSTRUCTIONS_DIR"/common/*.md; do
                [[ -f "$f" ]] || continue
                if extract_headings "$f" | grep -qFx "$heading"; then
                    extract_section_body "$f" "$heading" > "$gen_body_file"
                    break
                fi
            done
        fi

        hw_body_file="$TMP_DIR/hw_body_${role}.txt"
        extract_section_body "$hw_file" "$heading" > "$hw_body_file"

        if ! diff -q "$hw_body_file" "$gen_body_file" > /dev/null 2>&1; then
            diff_lines=$(diff -u "$hw_body_file" "$gen_body_file" | grep -c '^[+-]' || true)
            # diff -u のヘッダ2行（---/+++）分を差し引く
            diff_lines=$((diff_lines - 2))
            [[ "$diff_lines" -lt 0 ]] && diff_lines=0
            if [[ "$diff_lines" -gt 0 ]]; then
                echo "[DIFF] (c) content-mismatch: $heading (${diff_lines} lines)"
                c_count=$((c_count + 1))
                EXIT_CODE=1
            fi
        fi
    done < "$common_headings_role"

    TOTAL_C=$((TOTAL_C + c_count))
    echo "[INFO] (c) 内容が食い違う共通見出し: ${c_count}件"
done

echo "[INFO] === TOTAL === hw-only(a)=${TOTAL_A} gen-only(b)=${TOTAL_B} content-mismatch(c)=${TOTAL_C}"

exit "$EXIT_CODE"
