#!/usr/bin/env bash
# 検査の正規表現が、当たるべきものに当たり、当たってはいけないものに当たらないかを確かめる
set -u
cd "$(dirname "$0")/.."
fail=0
hit=$(bash php8-scan.sh tests/fixtures/should-hit); code=$?
[ "$code" -eq 1 ] || { echo "NG: should-hit で終了コード 1 にならない（$code）"; fail=1; }
# should-hit の各行（2 行目以降）が、どれかの規則に当たっているか
lines=$(grep -c '' tests/fixtures/should-hit/removed.php)
for n in $(seq 2 "$lines"); do
  printf '%s\n' "$hit" | grep -q "removed.php:$n:" || { echo "NG: 見落とし removed.php:$n: $(sed -n "${n}p" tests/fixtures/should-hit/removed.php)"; fail=1; }
done
pass=$(bash php8-scan.sh tests/fixtures/should-pass); code=$?
[ "$code" -eq 0 ] || { echo "NG: should-pass で終了コード 0 にならない（$code）"; fail=1; }
if printf '%s\n' "$pass" | grep -q 'modern.php:'; then
  echo "NG: 誤検知"; printf '%s\n' "$pass" | grep 'modern.php:'; fail=1
fi
wp=$(bash php8-scan.sh tests/fixtures/wp)
printf '%s\n' "$wp" | grep -q "old-form .*Requires PHP: 5.6" || { echo "NG: WordPress のプラグイン一覧"; fail=1; }
printf '%s\n' "$wp" | grep -q "wp_version = '6.8.2'" || { echo "NG: WordPress の版"; fail=1; }
[ "$fail" -eq 0 ] && echo "OK: すべての確認を通過"
exit "$fail"
