#!/usr/bin/env bash
# php8-scan.sh — PHP 7.x のコードを 8.x へ上げる前に、壊れそうな箇所を探す（読み取りのみ）
#
# 使い方:
#   bash php8-scan.sh [対象ディレクトリ] [--include-vendor]
#
# - ファイルを書き換えない・消さない・ネットワークに出ない。grep と find だけを使う
# - 見つかったものは「要確認」。本当に壊れるかは、検証環境で動かして確かめる
# - 「8.0で停止のおそれ」が 1 件でもあれば、終了コード 1 を返す（CI で使える）
#
# 必要なもの: bash、GNU grep（Linux のレンタルサーバー・VPS なら通常入っている）
# MIT License / https://github.com/itskill-jp/php8-upgrade-check

set -u
LC_ALL=C
export LC_ALL

TARGET="."
INCLUDE_VENDOR=0
for arg in "$@"; do
  case "$arg" in
    --include-vendor) INCLUDE_VENDOR=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) TARGET="$arg" ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "ディレクトリが見つかりません: $TARGET" >&2
  exit 2
fi

EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules)
[ "$INCLUDE_VENDOR" -eq 0 ] && EXCLUDES+=(--exclude-dir=vendor)

FATAL=0
TOTAL=0

# rule <区分> <見出し> <探す正規表現> [除外する正規表現]
rule() {
  local level="$1" title="$2" pattern="$3" exclude="${4:-}"
  local hits
  hits=$(grep -rnEI "${EXCLUDES[@]}" --include='*.php' --include='*.inc' --include='*.phtml' \
           -e "$pattern" "$TARGET" 2>/dev/null)
  # コメント行（// ・ # ・ * で始まる行）は数えない
  if [ -n "$hits" ]; then
    hits=$(printf '%s\n' "$hits" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|#|\*|/\*)')
  fi
  if [ -n "$exclude" ] && [ -n "$hits" ]; then
    hits=$(printf '%s\n' "$hits" | grep -vE -e "$exclude")
  fi
  [ -z "$hits" ] && return
  local n
  n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
  TOTAL=$((TOTAL + n))
  [ "$level" = "8.0で停止のおそれ" ] && FATAL=$((FATAL + n))
  echo
  echo "## [$level] $title（$n 件）"
  printf '%s\n' "$hits" | head -n 20 | sed 's/^/  /'
  [ "$n" -gt 20 ] && echo "  …ほか $((n - 20)) 件"
}

echo "# PHP 8.x へ上げる前の確認（読み取りのみ）"
echo "対象: $(cd "$TARGET" && pwd)"
[ "$INCLUDE_VENDOR" -eq 0 ] && echo "vendor/ は除外しています（含めるには --include-vendor）"

# ---- PHP 8.0 で削除され、その行が実行された時点で停止するもの ----
# function_exists() や PHP のバージョン判定で囲まれていれば、そのままで動く（目で確かめる）
rule "8.0で停止のおそれ" "each()（8.0 で削除）" \
  '(^|[^A-Za-z0-9_$>:.])each[[:space:]]*\(' \
  '(->|::|function[[:space:]]+)each[[:space:]]*\('
rule "8.0で停止のおそれ" "create_function()（8.0 で削除。無名関数に置き換える）" \
  '(^|[^A-Za-z0-9_$>:.])create_function[[:space:]]*\('
rule "8.0で停止のおそれ" "money_format()（8.0 で削除）" \
  '(^|[^A-Za-z0-9_$>:.])money_format[[:space:]]*\('
rule "8.0で停止のおそれ" "__autoload() の定義（8.0 で削除。spl_autoload_register に置き換える）" \
  'function[[:space:]]+__autoload[[:space:]]*\('
rule "8.0で停止のおそれ" "get_magic_quotes_gpc() / get_magic_quotes_runtime()（8.0 で削除）" \
  '(^|[^A-Za-z0-9_$>:.])get_magic_quotes_(gpc|runtime)[[:space:]]*\('
rule "8.0で停止のおそれ" "そのほか 8.0 で削除された関数" \
  '(^|[^A-Za-z0-9_$>:.])(fgetss|hebrevc|convert_cyr_string|restore_include_path|ezmlm_hash|image2wbmp|gmp_random|read_exif_data|ldap_sort)[[:space:]]*\('
rule "8.0で停止のおそれ" "文字列の {} での添字（\$str{0}。8.0 で構文エラー。\$str[0] に直す）" \
  '\$[A-Za-z_][A-Za-z0-9_]*\{[[:space:]]*([0-9]+|\$[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}' \
  '"'
rule "8.0で停止のおそれ" "(real) / (unset) キャスト（8.0 で削除）" \
  '\([[:space:]]*(real|unset)[[:space:]]*\)[[:space:]]*\$'
rule "8.0で停止のおそれ" "parse_str() の第 2 引数なし（8.0 で必須）" \
  'parse_str[[:space:]]*\([^,()]+\)[[:space:]]*;'
rule "8.0で停止のおそれ" "mysql_* / ereg* / split()（7.0 で削除済み。まだ残っていれば今も動いていない）" \
  '(^|[^A-Za-z0-9_$>:.])(mysql_[a-z_]+|eregi?(_replace)?|spliti?)[[:space:]]*\(' \
  '(->|::|function[[:space:]]+)(split|spliti)[[:space:]]*\('

# ---- 動きが変わるもの（目で確かめる） ----
rule "要確認" "is_resource() の判定（curl・GD・XML・OpenSSL などは 8.0 からオブジェクトになった。fopen などのファイルは今もリソースなのでそのままでよい）" \
  '(^|[^A-Za-z0-9_$>:.])is_resource[[:space:]]*\('

rule "要確認" "define(…, …, true)（8.0 から第 3 引数は無視され警告。定義と違う大文字小文字で参照していると、その行で止まる）" \
  'define[[:space:]]*\([^,()]+,[^,()]+,[[:space:]]*true[[:space:]]*\)'
rule "要確認" "assert() に文字列を渡している（8.0 から文字列は評価されず、確認が素通りになる）" \
  "(^|[^A-Za-z0-9_\$>:.])assert[[:space:]]*\([[:space:]]*['\"]"

# ---- 非推奨（動くが、エラーログが埋まる。次の版で止まる） ----
rule "非推奨" "FILTER_SANITIZE_STRING / FILTER_SANITIZE_STRIPPED（8.1 で非推奨）" \
  'FILTER_SANITIZE_(STRING|STRIPPED)'
rule "非推奨" "strftime() / gmstrftime()（8.1 で非推奨）" \
  '(^|[^A-Za-z0-9_$>:.])g?m?strftime[[:space:]]*\('
rule "非推奨" "utf8_encode() / utf8_decode()（8.2 で非推奨）" \
  '(^|[^A-Za-z0-9_$>:.])utf8_(encode|decode)[[:space:]]*\('
rule "非推奨" "文字列中の \${変数}（8.2 で非推奨。{\$変数} に直す。JavaScript のテンプレート文字列なら無視してよい）" \
  '"[^"]*\$\{[A-Za-z_]'
rule "非推奨" "型付き引数の = null（暗黙の null 許容。8.4 で非推奨。?型 に直す）" \
  'function[^(]*\(([^)]*,)?[[:space:]]*[A-Za-z_\\][A-Za-z0-9_\\]*[[:space:]]+&?\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*null'

# ---- WordPress：本体とプラグインの対応状況 ----
if [ -f "$TARGET/wp-includes/version.php" ]; then
  echo
  echo "## WordPress"
  grep -E '^\$(wp_version|required_php_version)' "$TARGET/wp-includes/version.php" | sed 's/^/  /'
  if [ -d "$TARGET/wp-content/plugins" ]; then
    echo
    echo "  プラグイン（readme.txt の Requires PHP / Tested up to / Stable tag）"
    for readme in "$TARGET"/wp-content/plugins/*/readme.txt; do
      [ -f "$readme" ] || continue
      name=$(basename "$(dirname "$readme")")
      rp=$(grep -iE '^Requires PHP:' "$readme" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
      tu=$(grep -iE '^Tested up to:' "$readme" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
      st=$(grep -iE '^Stable tag:' "$readme" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
      printf '  - %-40s Requires PHP: %-6s Tested up to: %-6s Stable tag: %s\n' "$name" "${rp:--}" "${tu:--}" "${st:--}"
    done
    echo "  ※ readme.txt が無いプラグインは、配布元で PHP の対応状況を確かめてください"
  fi
fi

echo
echo "---"
echo "合計 $TOTAL 件（うち PHP 8.0 で停止のおそれ $FATAL 件）"
echo "静的には見つけられないもの（型の比較の変化・null の受け渡し・動的プロパティなど）は、"
echo "検証環境で実際に動かし、エラーログで確かめてください。チェックリスト: README.md"
[ "$FATAL" -gt 0 ] && exit 1
exit 0
