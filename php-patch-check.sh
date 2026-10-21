#!/usr/bin/env bash
# php-patch-check.sh — is the PHP on this server patched? (read-only, offline)
#                      このサーバーの PHP に、セキュリティ修正が入っているかを確かめる（読み取りのみ・通信なし）
#
# Usage / 使い方:
#   bash php-patch-check.sh [--fixed 8.5.12,8.4.27,...] [--lang en|ja]
#
# - Finds every PHP on the server (CLI, PHP-FPM, CGI, cPanel / Plesk / Remi / LiteSpeed builds)
#   and runs only "<php> -v" to read the version. Site code is never executed.
# - Compares each version with the fixed versions of the advisory below
#   (or with --fixed, so you can check right after php.net publishes the release).
# - Distro packages (Ubuntu / Debian / RHEL ...) often keep the old upstream number after a fix.
#   For those, the installed package's changelog is searched for the CVE IDs.
# - Warns when PHP-FPM / Apache (mod_php) is still running from before PHP was updated.
# - Never writes, deletes or goes online.
# - Exit: 0 = all patched, 1 = action needed, 3 = cannot decide yet.
#
# Requires: bash, GNU coreutils (sort -V, date -d), ps
# MIT License / https://github.com/itskill-jp/php8-upgrade-check

set -u

# ---- Advisory ---------------------------------------------------------------
# PHP security release announced on php.net for 2026-10-21 14:00 UTC (two critical issues, CVSS v4.0 9.2).
ADVISORY_LABEL="PHP security release 2026-10-21"
# CVE IDs used to search distro changelogs (as reported; php.net's notice did not list them).
ADVISORY_CVES="CVE-2026-109618 CVE-2026-109619"
# Fixed version per branch, from php.net. Empty until the release is published.
FIXED_VERSIONS=""
# Oldest branch that receives official fixes. Older branches are end-of-life upstream.
OLDEST_SUPPORTED="8.2"
# -----------------------------------------------------------------------------

case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in ja*) OUT=ja ;; *) OUT=en ;; esac
LC_ALL=C
export LC_ALL

while [ $# -gt 0 ]; do
  case "$1" in
    --fixed) FIXED_VERSIONS="${2:-}"; shift ;;
    --fixed=*) FIXED_VERSIONS="${1#--fixed=}" ;;
    --lang) OUT="${2:-en}"; shift ;;
    --lang=*) OUT="${1#--lang=}" ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$OUT" = ja ] || OUT=en
FIXED_VERSIONS=$(printf '%s' "$FIXED_VERSIONS" | tr ',' ' ')

t() { if [ "$OUT" = ja ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

for v in $FIXED_VERSIONS; do
  if ! printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$(t "--fixed の版の形が正しくありません" "Invalid version in --fixed"): $v" >&2
    exit 2
  fi
done

# ver_ge A B — true when version A >= version B
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }

# fixed_for 8.3 — the fixed version for a branch, or empty
fixed_for() {
  local v
  for v in $FIXED_VERSIONS; do
    [ "${v%.*}" = "$1" ] && { printf '%s' "$v"; return; }
  done
}

# Every PHP binary on the server (real paths, no duplicates). PPC_SEARCH overrides (tests).
candidates() {
  if [ -n "${PPC_SEARCH:-}" ]; then
    printf '%s\n' $PPC_SEARCH
    return
  fi
  {
    command -v php 2>/dev/null
    ls -1d /usr/bin/php[0-9]* /usr/bin/php-cgi* /usr/sbin/php-fpm* \
           /usr/local/bin/php /usr/local/bin/php-cgi /usr/local/sbin/php-fpm \
           /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm \
           /opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/sbin/php-fpm \
           /opt/plesk/php/*/bin/php /opt/plesk/php/*/sbin/php-fpm \
           /usr/local/lsws/lsphp*/bin/php /usr/local/lsws/lsphp*/bin/lsphp \
           /opt/php*/bin/php /usr/local/php*/bin/php 2>/dev/null
  } | while IFS= read -r b; do
        [ -f "$b" ] && [ -x "$b" ] && readlink -f "$b"
      done | sort -u
}

# pkg_of <binary> — "deb <package> <version>" / "rpm <package>" / empty. PPC_PKG overrides (tests).
pkg_of() {
  if [ -n "${PPC_PKG+x}" ]; then printf '%s' "$PPC_PKG"; return; fi
  local p
  if command -v dpkg-query >/dev/null 2>&1; then
    p=$(dpkg -S "$1" 2>/dev/null | head -n 1 | cut -d: -f1)
    if [ -n "$p" ]; then
      printf 'deb %s %s' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
      return
    fi
  fi
  if command -v rpm >/dev/null 2>&1; then
    p=$(rpm -qf "$1" 2>/dev/null | head -n 1)
    case "$p" in ""|*"not owned"*) ;; *) printf 'rpm %s' "$p"; return ;; esac
  fi
}

# cves_in_changelog <kind> <package> — the advisory CVE IDs found in the installed package's changelog
cves_in_changelog() {
  local kind="$1" pkg="$2" text="" f c found=""
  if [ -n "${PPC_CHANGELOG:-}" ]; then
    text=$(zcat -f "$PPC_CHANGELOG" 2>/dev/null)
  elif [ "$kind" = deb ]; then
    for f in "/usr/share/doc/$pkg/changelog.Debian.gz" "/usr/share/doc/$pkg/changelog.gz"; do
      if [ -r "$f" ]; then text=$(zcat "$f" 2>/dev/null); break; fi
    done
  elif [ "$kind" = rpm ]; then
    text=$(rpm -q --changelog "$pkg" 2>/dev/null)
  fi
  for c in $ADVISORY_CVES; do
    printf '%s\n' "$text" | grep -q -- "$c" && found="$found $c"
  done
  printf '%s' "${found# }"
}

ACTION=0
PENDING=0
PATCHED=0
FOUND=0

say_status() {  # <ok|action|pending> <message>
  local label
  case "$1" in
    ok)      label=$(t "修正済み" "patched"); PATCHED=$((PATCHED + 1)) ;;
    action)  label=$(t "要対応" "action needed"); ACTION=$((ACTION + 1)) ;;
    pending) label=$(t "判定待ち" "cannot decide yet"); PENDING=$((PENDING + 1)) ;;
  esac
  echo "    -> [$label] $2"
}

echo "# $(t "PHP のセキュリティ修正の確認（読み取りのみ・通信なし）" "PHP security patch check (read-only, offline)")"
echo "$(t "対象の告知" "Advisory"): $ADVISORY_LABEL  ($ADVISORY_CVES)"
if [ -n "$FIXED_VERSIONS" ]; then
  echo "$(t "修正版" "Fixed versions"): $FIXED_VERSIONS"
else
  echo "$(t "修正版：まだ入っていません（php.net の公開後に --fixed で指定するか、新しい版のスクリプトで）" "Fixed versions: not set yet (pass --fixed after php.net publishes the release, or use a newer copy of this script)")"
fi
echo
echo "## $(t "見つかった PHP" "PHP found on this server")"

while IFS= read -r bin; do
  [ -n "$bin" ] || continue
  line=$("$bin" -v 2>/dev/null | head -n 1)
  ver=$(printf '%s' "$line" | sed -nE 's/^PHP ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  [ -n "$ver" ] || continue
  FOUND=$((FOUND + 1))
  sapi=$(printf '%s' "$line" | sed -nE 's/^PHP [^ ]+ \(([^)]+)\).*/\1/p')
  branch="${ver%.*}"
  pkg=$(pkg_of "$bin")
  echo
  echo "- $bin"
  echo "    PHP $ver${sapi:+ ($sapi)}${pkg:+  /  $(t "パッケージ" "package"): ${pkg#* }}"

  cves=""
  case "$pkg" in deb\ *|rpm\ *) set -- $pkg; cves=$(cves_in_changelog "$1" "$2") ;; esac
  fixed=$(fixed_for "$branch")

  if [ -n "$cves" ]; then
    say_status ok "$(t "パッケージの変更履歴に $cves の修正が記録されています" "the package changelog records the fix for $cves")"
  elif ! ver_ge "$branch" "$OLDEST_SUPPORTED"; then
    if [ -n "$pkg" ]; then
      say_status action "$(t "PHP $branch は公式のサポートが終わっています（公式の修正は出ません）。ディストリビューションの更新で修正が入るか確かめ、無ければ $OLDEST_SUPPORTED 以上へ" "PHP $branch is end-of-life upstream (no official fix). Check whether your distro ships a fix; otherwise move to $OLDEST_SUPPORTED or later")"
    else
      say_status action "$(t "PHP $branch は公式のサポートが終わっています（公式の修正は出ません）。$OLDEST_SUPPORTED 以上へ" "PHP $branch is end-of-life (no official fix). Move to $OLDEST_SUPPORTED or later")"
    fi
  elif [ -z "$FIXED_VERSIONS" ]; then
    say_status pending "$(t "修正版がまだ公開されていません。公開後にもう一度" "fixed versions not published yet; run again after the release")"
  elif [ -z "$fixed" ]; then
    say_status pending "$(t "PHP $branch の修正版が一覧にありません。php.net で確かめてください" "no fixed version listed for PHP $branch; check php.net")"
  elif ver_ge "$ver" "$fixed"; then
    say_status ok "$(t "$fixed 以上です" "$ver is $fixed or later")"
  else
    case "$pkg" in
      deb\ *|rpm\ *)
        say_status action "$(t "$fixed 未満で、パッケージの変更履歴にも修正の記録がありません。ディストリビューションの更新を当ててください（版の番号は変わらないことがあります）" "older than $fixed and the package changelog has no record of the fix. Apply your distro's update (the version number may not change)")" ;;
      *)
        say_status action "$(t "$fixed 未満です。$fixed 以上へ更新してください" "older than $fixed; update to $fixed or later")" ;;
    esac
  fi
done < <(candidates)

if [ "$FOUND" -eq 0 ]; then
  echo
  echo "  $(t "PHP が見つかりませんでした。レンタルサーバーなどで Web 側の PHP が見えない場合は、管理画面の PHP の版とサーバー会社のお知らせを確かめてください" "No PHP found. On shared hosting the web PHP may not be visible here; check the PHP version in your control panel and your host's notices")"
fi

# ---- Restart check: still running from before the update? --------------------
restart_notes=()
if [ "${PPC_NO_PROC:-0}" != 1 ]; then
  newest_ctime() {  # newest change time (= install time) among the given files
    local f m=0 c
    for f in "$@"; do
      [ -e "$f" ] || continue
      c=$(stat -L -c %Z "$f" 2>/dev/null) || continue
      [ "$c" -gt "$m" ] && m=$c
    done
    printf '%s' "$m"
  }
  # PHP-FPM master processes
  while read -r pid rest; do
    [ -n "$pid" ] || continue
    lstart=$(printf '%s' "$rest" | awk '{print $1, $2, $3, $4, $5}')
    # lstart pads single-digit days with two spaces, so split by fields, not by single spaces
    args=$(printf '%s' "$rest" | awk '{ $1 = $2 = $3 = $4 = $5 = ""; sub(/^ +/, ""); print }')
    started=$(date -d "$lstart" +%s 2>/dev/null) || continue
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    hint=$(printf '%s' "$args" | sed -nE 's#.*/php/([0-9]+\.[0-9]+)/.*#\1#p')
    if [ -n "$hint" ]; then
      bins=(/usr/sbin/php-fpm"$hint")
    else
      bins=(/usr/sbin/php-fpm* /usr/local/sbin/php-fpm /opt/remi/php*/root/usr/sbin/php-fpm /opt/cpanel/ea-php*/root/usr/sbin/php-fpm /opt/plesk/php/*/sbin/php-fpm)
    fi
    installed=$(newest_ctime "${bins[@]}")
    if [ "${exe%(deleted)}" != "$exe" ] || [ "$installed" -gt "$started" ]; then
      svc="php${hint}-fpm"; [ -n "$hint" ] || svc="php-fpm"
      restart_notes+=("PHP-FPM${hint:+ $hint} (pid $pid): $(t "PHP の更新より前に起動したままです。再起動してください（例：sudo systemctl restart $svc）" "started before PHP was updated; restart it (e.g. sudo systemctl restart $svc)")")
    fi
  done < <(ps -eo pid=,lstart=,args= 2>/dev/null | grep -E 'php-fpm: master process' | grep -v grep)

  # Apache with mod_php
  mods=(/usr/lib/apache2/modules/libphp*.so /etc/httpd/modules/libphp*.so /usr/lib64/httpd/modules/libphp*.so)
  modtime=$(newest_ctime "${mods[@]}")
  if [ "$modtime" -gt 0 ]; then
    while read -r pid ppid rest; do
      [ "$ppid" = 1 ] || continue
      lstart=$(printf '%s' "$rest" | awk '{print $1, $2, $3, $4, $5}')
      started=$(date -d "$lstart" +%s 2>/dev/null) || continue
      if [ "$modtime" -gt "$started" ]; then
        name=$(printf '%s' "$rest" | awk '{print $6}'); name=${name##*/}
        restart_notes+=("Apache (mod_php, pid $pid): $(t "PHP の更新より前に起動したままです。再起動してください（例：sudo systemctl restart $name）" "started before PHP was updated; restart it (e.g. sudo systemctl restart $name)")")
      fi
    done < <(ps -eo pid=,ppid=,lstart=,comm= 2>/dev/null | awk '$NF ~ /^(apache2|httpd)$/')
  fi
fi

if [ "${#restart_notes[@]}" -gt 0 ]; then
  echo
  echo "## $(t "再起動が必要" "Restart needed")"
  for n in "${restart_notes[@]}"; do
    echo "- $n"
    ACTION=$((ACTION + 1))
  done
fi

echo
echo "---"
if [ "$OUT" = ja ]; then
  echo "修正済み $PATCHED ／ 要対応 $ACTION ／ 判定待ち $PENDING"
  echo "コマンドの php（CLI）と、Web で動いている PHP（PHP-FPM・Apache）の版が違うことがあります。"
  echo "更新したあとは、PHP-FPM か Apache を再起動し、Web 側の版も確かめてください。"
else
  echo "Patched $PATCHED / action needed $ACTION / cannot decide $PENDING"
  echo "The command-line php and the PHP serving your site (PHP-FPM / Apache) can differ."
  echo "After updating, restart PHP-FPM or Apache and check the web-side version too."
fi

[ "$ACTION" -gt 0 ] && exit 1
[ "$PENDING" -gt 0 ] && exit 3
[ "$FOUND" -eq 0 ] && exit 3
exit 0
