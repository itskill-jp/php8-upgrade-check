#!/usr/bin/env bash
# php8-scan.sh — find code that may break when a site moves from PHP 7.x to 8.x (read-only)
#                PHP 7.x のコードを 8.x へ上げる前に、壊れそうな箇所を探す（読み取りのみ）
#
# Usage / 使い方:
#   bash php8-scan.sh [directory] [--include-vendor] [--lang en|ja]
#
# - Never writes, deletes or goes online. Uses grep and find only.
# - Every hit means "check this". Run the site on the new version in staging to confirm.
# - Exits 1 if anything may stop PHP 8.0 (usable in CI).
# - Output is Japanese when LANG starts with "ja", English otherwise (override with --lang).
#
# Requires: bash, GNU grep (standard on Linux shared hosting and VPS)
# MIT License / https://github.com/itskill-jp/php8-upgrade-check

set -u

case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in ja*) OUT=ja ;; *) OUT=en ;; esac
LC_ALL=C
export LC_ALL

TARGET="."
INCLUDE_VENDOR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --include-vendor) INCLUDE_VENDOR=1 ;;
    --lang) OUT="${2:-en}"; shift ;;
    --lang=*) OUT="${1#--lang=}" ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) TARGET="$1" ;;
  esac
  shift
done
[ "$OUT" = ja ] || OUT=en

# t "<Japanese>" "<English>" — print the text for the chosen language
t() { if [ "$OUT" = ja ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

if [ ! -d "$TARGET" ]; then
  echo "$(t "ディレクトリが見つかりません" "Directory not found"): $TARGET" >&2
  exit 2
fi

EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules)
[ "$INCLUDE_VENDOR" -eq 0 ] && EXCLUDES+=(--exclude-dir=vendor)

FATAL=0
TOTAL=0

# rule <fatal|review|deprecated> <title (ja)> <title (en)> <pattern> [exclude pattern]
rule() {
  local level="$1" title_ja="$2" title_en="$3" pattern="$4" exclude="${5:-}"
  local hits label
  hits=$(grep -rnEI "${EXCLUDES[@]}" --include='*.php' --include='*.inc' --include='*.phtml' \
           -e "$pattern" "$TARGET" 2>/dev/null)
  # Skip comment lines (starting with // # * /*)
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
  case "$level" in
    fatal)      FATAL=$((FATAL + n)); label=$(t "8.0で停止のおそれ" "may stop on 8.0") ;;
    review)     label=$(t "要確認" "behaviour changes") ;;
    deprecated) label=$(t "非推奨" "deprecated") ;;
  esac
  echo
  if [ "$OUT" = ja ]; then echo "## [$label] $title_ja（$n 件）"; else echo "## [$label] $title_en ($n)"; fi
  printf '%s\n' "$hits" | head -n 20 | sed 's/^/  /'
  [ "$n" -gt 20 ] && echo "  $(t "…ほか $((n - 20)) 件" "... and $((n - 20)) more")"
}

echo "# $(t "PHP 8.x へ上げる前の確認（読み取りのみ）" "Before moving to PHP 8.x (read-only)")"
echo "$(t "対象" "Target"): $(cd "$TARGET" && pwd)"
[ "$INCLUDE_VENDOR" -eq 0 ] && t "vendor/ は除外しています（含めるには --include-vendor）" "vendor/ is skipped (add --include-vendor to scan it)" && echo

# ---- Removed in PHP 8.0: execution stops when the line runs ----
# Code wrapped in function_exists() or a PHP version check still works — check by eye.
rule fatal "each()（8.0 で削除）" "each() (removed in 8.0)" \
  '(^|[^A-Za-z0-9_$>:.])each[[:space:]]*\(' \
  '(->|::|function[[:space:]]+)each[[:space:]]*\('
rule fatal "create_function()（8.0 で削除。無名関数に置き換える）" \
  "create_function() (removed in 8.0; use an anonymous function)" \
  '(^|[^A-Za-z0-9_$>:.])create_function[[:space:]]*\('
rule fatal "money_format()（8.0 で削除）" "money_format() (removed in 8.0)" \
  '(^|[^A-Za-z0-9_$>:.])money_format[[:space:]]*\('
rule fatal "__autoload() の定義（8.0 で削除。spl_autoload_register に置き換える）" \
  "__autoload() definition (removed in 8.0; use spl_autoload_register)" \
  'function[[:space:]]+__autoload[[:space:]]*\('
rule fatal "get_magic_quotes_gpc() / get_magic_quotes_runtime()（8.0 で削除）" \
  "get_magic_quotes_gpc() / get_magic_quotes_runtime() (removed in 8.0)" \
  '(^|[^A-Za-z0-9_$>:.])get_magic_quotes_(gpc|runtime)[[:space:]]*\('
rule fatal "そのほか 8.0 で削除された関数" "Other functions removed in 8.0" \
  '(^|[^A-Za-z0-9_$>:.])(fgetss|hebrevc|convert_cyr_string|restore_include_path|ezmlm_hash|image2wbmp|gmp_random|read_exif_data|ldap_sort)[[:space:]]*\('
rule fatal "文字列の {} での添字（\$str{0}。8.0 で構文エラー。\$str[0] に直す）" \
  "Curly-brace string offsets (\$str{0} is a syntax error in 8.0; use \$str[0])" \
  '\$[A-Za-z_][A-Za-z0-9_]*\{[[:space:]]*([0-9]+|\$[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}' \
  '"'
rule fatal "(real) / (unset) キャスト（8.0 で削除）" "(real) / (unset) casts (removed in 8.0)" \
  '\([[:space:]]*(real|unset)[[:space:]]*\)[[:space:]]*\$'
rule fatal "parse_str() の第 2 引数なし（8.0 で必須）" \
  "parse_str() without a second argument (required in 8.0)" \
  'parse_str[[:space:]]*\([^,()]+\)[[:space:]]*;'
rule fatal "mysql_* / ereg* / split()（7.0 で削除済み。まだ残っていれば今も動いていない）" \
  "mysql_* / ereg* / split() (removed in 7.0 — if these still run, that code is already broken)" \
  '(^|[^A-Za-z0-9_$>:.])(mysql_[a-z_]+|eregi?(_replace)?|spliti?)[[:space:]]*\(' \
  '(->|::|function[[:space:]]+)(split|spliti)[[:space:]]*\('

# ---- Behaviour changes (check by eye) ----
rule review "is_resource() の判定（curl・GD・XML・OpenSSL などは 8.0 からオブジェクトになった。fopen などのファイルは今もリソースなのでそのままでよい）" \
  "is_resource() checks (curl, GD, XML, OpenSSL etc. return objects since 8.0; file handles from fopen are still resources and are fine)" \
  '(^|[^A-Za-z0-9_$>:.])is_resource[[:space:]]*\('
rule review "define(…, …, true)（8.0 から第 3 引数は無視され警告。定義と違う大文字小文字で参照していると、その行で止まる）" \
  "define(..., ..., true) (the 3rd argument is ignored with a warning since 8.0; referencing the constant in a different case stops execution)" \
  'define[[:space:]]*\([^,()]+,[^,()]+,[[:space:]]*true[[:space:]]*\)'
rule review "assert() に文字列を渡している（8.0 から文字列は評価されず、確認が素通りになる）" \
  "assert() with a string (strings are no longer evaluated since 8.0, so the check silently passes)" \
  "(^|[^A-Za-z0-9_\$>:.])assert[[:space:]]*\([[:space:]]*['\"]"

# ---- Deprecated (still runs, fills the error log, breaks in a later version) ----
rule deprecated "FILTER_SANITIZE_STRING / FILTER_SANITIZE_STRIPPED（8.1 で非推奨）" \
  "FILTER_SANITIZE_STRING / FILTER_SANITIZE_STRIPPED (deprecated in 8.1)" \
  'FILTER_SANITIZE_(STRING|STRIPPED)'
rule deprecated "strftime() / gmstrftime()（8.1 で非推奨）" "strftime() / gmstrftime() (deprecated in 8.1)" \
  '(^|[^A-Za-z0-9_$>:.])g?m?strftime[[:space:]]*\('
rule deprecated "utf8_encode() / utf8_decode()（8.2 で非推奨）" "utf8_encode() / utf8_decode() (deprecated in 8.2)" \
  '(^|[^A-Za-z0-9_$>:.])utf8_(encode|decode)[[:space:]]*\('
rule deprecated "文字列中の \${変数}（8.2 で非推奨。{\$変数} に直す。JavaScript のテンプレート文字列なら無視してよい）" \
  "\${var} inside strings (deprecated in 8.2; use {\$var}. Ignore JavaScript template literals)" \
  '"[^"]*\$\{[A-Za-z_]'
rule deprecated "型付き引数の = null（暗黙の null 許容。8.4 で非推奨。?型 に直す）" \
  "Typed parameter with = null (implicit nullable, deprecated in 8.4; use ?Type)" \
  'function[^(]*\(([^)]*,)?[[:space:]]*[A-Za-z_\\][A-Za-z0-9_\\]*[[:space:]]+&?\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*null'

# ---- WordPress: core and plugin compatibility ----
if [ -f "$TARGET/wp-includes/version.php" ]; then
  echo
  echo "## WordPress"
  grep -E '^\$(wp_version|required_php_version)' "$TARGET/wp-includes/version.php" | sed 's/^/  /'
  if [ -d "$TARGET/wp-content/plugins" ]; then
    echo
    echo "  $(t "プラグイン（readme.txt の Requires PHP / Tested up to / Stable tag）" "Plugins (Requires PHP / Tested up to / Stable tag from readme.txt)")"
    for readme in "$TARGET"/wp-content/plugins/*/readme.txt; do
      [ -f "$readme" ] || continue
      name=$(basename "$(dirname "$readme")")
      rp=$(grep -iE '^Requires PHP:' "$readme" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
      tu=$(grep -iE '^Tested up to:' "$readme" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
      st=$(grep -iE '^Stable tag:' "$readme" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
      printf '  - %-40s Requires PHP: %-6s Tested up to: %-6s Stable tag: %s\n' "$name" "${rp:--}" "${tu:--}" "${st:--}"
    done
    echo "  $(t "※ readme.txt が無いプラグインは、配布元で PHP の対応状況を確かめてください" "Note: for plugins without a readme.txt, check PHP support with the vendor")"
  fi
fi

echo
echo "---"
if [ "$OUT" = ja ]; then
  echo "合計 $TOTAL 件（うち PHP 8.0 で停止のおそれ $FATAL 件）"
  echo "静的には見つけられないもの（型の比較の変化・null の受け渡し・動的プロパティなど）は、"
  echo "検証環境で実際に動かし、エラーログで確かめてください。チェックリスト: README.ja.md"
else
  echo "Total $TOTAL ($FATAL may stop PHP 8.0)"
  echo "Some changes cannot be found by searching (comparison rules, null passed to built-ins,"
  echo "dynamic properties). Run the site on the new version in staging and read the error log. Checklist: README.md"
fi
[ "$FATAL" -gt 0 ] && exit 1
exit 0
