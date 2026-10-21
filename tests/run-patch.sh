#!/usr/bin/env bash
# php-patch-check.sh の判定が正しいかを、偽の php（版を表示するだけ）で確かめる
set -u
cd "$(dirname "$0")/.."
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fake <name> <version line> — "-v" で版を表示するだけの偽の php を作る
fake() { printf '#!/bin/sh\necho "%s"\n' "$2" > "$tmp/$1"; chmod +x "$tmp/$1"; printf '%s' "$tmp/$1"; }
FIXED="8.5.12,8.4.27,8.3.36,8.2.35"

# check <名前> <期待する終了コード> <出力に含まれるべき文字列> -- <コマンド…>
check() {
  local name="$1" want="$2" grep_for="$3"; shift 4
  local out code
  out=$("$@" 2>&1); code=$?
  if [ "$code" -ne "$want" ]; then echo "NG: $name（終了コード $code、期待 $want）"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1; return; fi
  if ! printf '%s\n' "$out" | grep -q -- "$grep_for"; then echo "NG: $name（「$grep_for」が出ない）"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1; fi
}

export PPC_NO_PROC=1 PPC_PKG=""
run() { LANG=ja_JP.UTF-8 bash php-patch-check.sh "$@"; }

p8335=$(fake php8335 "PHP 8.3.35 (cli) (built: Sep 24 2026)")
p8336=$(fake php8336 "PHP 8.3.36 (fpm-fcgi) (built: Oct 21 2026)")
p8340=$(fake php8340 "PHP 8.3.40 (cli)")
p839=$(fake php839 "PHP 8.3.9 (cli)")
p8131=$(fake php8131 "PHP 8.1.31 (cli)")
p8360=$(fake php836u "PHP 8.3.6 (cli) (built: Jul 14 2026)")
p860=$(fake php860 "PHP 8.6.0 (cli)")

check "修正版の一覧が空なら判定待ち（--fixed ""）" 3 "判定待ち" -- env PPC_SEARCH="$p8335" bash -c 'LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed ""'
check "修正版未満は要対応" 1 "8.3.36 未満" -- env PPC_SEARCH="$p8335" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "修正版ちょうどは修正済み" 0 "\[修正済み\]" -- env PPC_SEARCH="$p8336" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "修正版より新しいのも修正済み" 0 "\[修正済み\]" -- env PPC_SEARCH="$p8340" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed=$FIXED"
check "8.3.9 は 8.3.36 より古い（文字の並びで読み違えない）" 1 "8.3.36 未満" -- env PPC_SEARCH="$p839" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "サポート終了の系列は要対応" 1 "公式のサポートが終わっています" -- env PPC_SEARCH="$p8131" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "サポート終了は修正版の公開前でも要対応" 1 "公式のサポートが終わっています" -- env PPC_SEARCH="$p8131" bash -c 'LANG=ja_JP.UTF-8 bash php-patch-check.sh'
check "一覧にない系列は判定待ち" 3 "一覧にありません" -- env PPC_SEARCH="$p860" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "1 つでも要対応なら終了コード 1" 1 "要対応 1" -- env PPC_SEARCH="$p8336 $p8335" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"

# ディストリビューションのパッケージ：版の番号は 8.3.6 のままでも、変更履歴に CVE があれば修正済み
printf 'php8.3 (8.3.6-0ubuntu0.24.04.6) noble-security; urgency=medium\n\n  * SECURITY UPDATE: remote code execution\n    - CVE-2026-109618\n    - CVE-2026-109619\n' > "$tmp/changelog.fixed"
printf 'php8.3 (8.3.6-0ubuntu0.24.04.5) noble-security; urgency=medium\n\n  * SECURITY UPDATE: other\n    - CVE-2026-17543\n' > "$tmp/changelog.old"
gzip -k "$tmp/changelog.fixed"
check "パッケージの変更履歴に CVE があれば修正済み" 0 "変更履歴に CVE-2026-109618 CVE-2026-109619" -- env PPC_SEARCH="$p8360" PPC_PKG="deb php8.3-cli 8.3.6-0ubuntu0.24.04.6" PPC_CHANGELOG="$tmp/changelog.fixed" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "変更履歴は gzip でも読める" 0 "\[修正済み\]" -- env PPC_SEARCH="$p8360" PPC_PKG="deb php8.3-cli 8.3.6-0ubuntu0.24.04.6" PPC_CHANGELOG="$tmp/changelog.fixed.gz" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "変更履歴に CVE が無いパッケージは要対応（ディストリの更新を当てる）" 1 "ディストリビューションの更新を当ててください" -- env PPC_SEARCH="$p8360" PPC_PKG="deb php8.3-cli 8.3.6-0ubuntu0.24.04.5" PPC_CHANGELOG="$tmp/changelog.old" bash -c "LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "パッケージの修正は修正版の公開前でも分かる" 0 "\[修正済み\]" -- env PPC_SEARCH="$p8360" PPC_PKG="deb php8.3-cli 8.3.6-0ubuntu0.24.04.6" PPC_CHANGELOG="$tmp/changelog.fixed" bash -c 'LANG=ja_JP.UTF-8 bash php-patch-check.sh'

# 入力と言語
check "修正版の番号は組み込み（--fixed なしでも判定する）" 1 "8.3.36 未満" -- env PPC_SEARCH="$p8335" bash -c 'LANG=ja_JP.UTF-8 bash php-patch-check.sh'
check "組み込みでも修正版ちょうどは修正済み" 0 "\[修正済み\]" -- env PPC_SEARCH="$p8336" bash -c 'LANG=ja_JP.UTF-8 bash php-patch-check.sh'
check "--fixed の形が違えば止める" 2 "形が正しくありません" -- env PPC_SEARCH="$p8335" bash -c 'LANG=ja_JP.UTF-8 bash php-patch-check.sh --fixed 8.3'
check "PHP が無ければ判定待ち" 3 "見つかりませんでした" -- env PPC_SEARCH="$tmp/none" bash -c 'LANG=ja_JP.UTF-8 bash php-patch-check.sh'
check "LANG=en なら英語" 1 "action needed" -- env PPC_SEARCH="$p8335" bash -c "LANG=en_US.UTF-8 bash php-patch-check.sh --fixed $FIXED"
check "--lang ja で日本語" 1 "要対応" -- env PPC_SEARCH="$p8335" bash -c "LANG=en_US.UTF-8 bash php-patch-check.sh --lang ja --fixed $FIXED"

# 書き込み・通信をしないこと（スクリプトの中に、書き込みや通信の命令が無い）
bad=$(grep -nE '\b(curl|wget|rm|mv|cp|tee|dd|truncate)\b|sed -i|>>' php-patch-check.sh | grep -vE '^[0-9]+:[[:space:]]*#')
if [ -n "$bad" ]; then echo "NG: 書き込み・通信の命令がある"; printf '%s\n' "$bad"; fail=1; fi
# リダイレクトは標準エラーと /dev/null だけ
bad=$(grep -nE '[^-2&]>[[:space:]]*[^&[:space:]]' php-patch-check.sh | grep -vE '^[0-9]+:[[:space:]]*#|-> \[|>/dev/null|>&2|\$\(\(|-gt|"\$|# <')
if [ -n "$bad" ]; then echo "NG: ファイルへの書き込みがある"; printf '%s\n' "$bad"; fail=1; fi

[ "$fail" -eq 0 ] && echo "OK: php-patch-check のすべての確認を通過"
exit "$fail"
