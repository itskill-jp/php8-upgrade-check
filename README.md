# php8-upgrade-check

[日本語](README.ja.md)

A **checklist** and a **read-only scan script** for moving a site from PHP 7.x to 8.x.

Written for WordPress on shared hosting and for hand-written PHP sites.

## Why now

PHP 7.4, 8.0 and 8.1 no longer get security fixes. PHP 8.2 gets them **until 31 December 2026**. If you are upgrading, aim for 8.3 or later (source: [php.net Supported Versions](https://www.php.net/supported-versions.php)).

| Version | Security fixes until |
|---|---|
| 7.4 / 8.0 / 8.1 | Ended |
| 8.2 | 2026-12-31 |
| 8.3 | 2027-12-31 |
| 8.4 | 2028-12-31 |
| 8.5 | 2029-12-31 |

## Using the script

```bash
bash php8-scan.sh /path/to/site
```

- **It never writes, deletes or goes online.** It uses `grep` and `find` only
- `vendor/` is skipped by default (`--include-vendor` to scan it)
- On WordPress it lists the core version and each plugin's `Requires PHP` / `Tested up to` / `Stable tag`
- Exits 1 if anything "may stop on 8.0" (usable in CI)
- Output is English, or Japanese when `LANG` starts with `ja`. Force either with `--lang en` / `--lang ja`

Example output:

```
## [may stop on 8.0] each() (removed in 8.0) (1)
  wp-content/plugins/old-form/inc/util.php:42:while (list($k, $v) = each($arr)) {

## [deprecated] utf8_encode() / utf8_decode() (deprecated in 8.2) (2)
  ...

Total 3 (1 may stop PHP 8.0)
```

Every hit means "check this". Code wrapped in `function_exists()` or a PHP version check keeps working as it is. Whether it really breaks is confirmed by running the site on the new version in staging.

## Checklist

### 1. Environment

- [ ] Decided the current and target PHP versions (8.3 or later)
- [ ] Every extension in use exists on the target version (mysqli / PDO, mbstring, gd, curl, intl, zip, opcache, ...)
- [ ] Checked what a PHP version switch applies to (one domain, or the whole account). **Sites sharing the same setting switch together**
- [ ] Checked that settings in `.htaccess`, `php.ini` and `.user.ini` still apply on the target version
- [ ] Listed cron jobs and the way the site sends mail
- [ ] Found where the error log goes and **what errors already appear there** (keep a record of the state before the upgrade)

### 2. Code (what `php8-scan.sh` looks for)

Removed in 8.0 — execution stops when the line runs:

- [ ] `each()`, `create_function()`, `money_format()`, `__autoload()`
- [ ] `get_magic_quotes_gpc()` / `get_magic_quotes_runtime()`, `fgetss()` and others
- [ ] Curly-brace string offsets (`$str{0}` → `$str[0]`)
- [ ] `(real)` / `(unset)` casts
- [ ] `parse_str()` without a second argument
- [ ] `mysql_*`, `ereg*`, `split()` (removed in 7.0 — if they are still there, that code is already broken)

Behaviour changes:

- [ ] `is_resource()` checks (curl, GD, XML, OpenSSL etc. return objects since 8.0; file handles are still resources)
- [ ] `define()` with `true` as the third argument (ignored since 8.0; referencing the constant in a different case stops execution)
- [ ] `assert()` with a string (no longer evaluated since 8.0, so the check silently passes)

Deprecated (still runs, fills the error log, stops in a later version):

- [ ] `FILTER_SANITIZE_STRING`, `strftime()` (8.1)
- [ ] `utf8_encode()` / `utf8_decode()`, `${var}` inside strings (8.2)
- [ ] Typed parameters with `= null` (implicit nullable, 8.4)

### 3. Code (what a script cannot find)

A text search cannot catch these. **Run the site in staging and read the error log.**

- [ ] Number-to-string comparison changes (`0 == "abc"` is `false` since 8.0)
- [ ] Stricter built-in functions (`count()` on a non-array throws TypeError since 8.0)
- [ ] `null` passed to built-in functions (deprecated since 8.1, e.g. `strlen(null)`)
- [ ] Assigning undeclared properties (dynamic properties, deprecated since 8.2)
- [ ] Reading undefined variables or array keys (promoted to Warning in 8.0)
- [ ] Nested ternaries without parentheses (syntax error since 8.0)

### 4. WordPress

- [ ] The core version supports the target PHP version
- [ ] Checked `Requires PHP` / `Tested up to` / last update of every plugin and theme
- [ ] Listed plugins that are no longer updated or distributed, and **chose replacements**
- [ ] Ran this script on custom code (`functions.php`, child themes, in-house plugins)
- [ ] **Did not update or delete** custom, abandoned or unknown components without a decision. List the risk and the options first

### 5. Backup, staging and rollback (before any change)

- [ ] Copied the files right before the work (not relying only on the host's automatic backups)
- [ ] Dumped each site's database (`mysqldump --single-transaction` or similar)
- [ ] **Restored from that backup once, to prove it works**
- [ ] Cloned the site to staging (a subdomain, for example) and ran it on the new version first. Kept staging out of search engines (noindex, Basic auth)
- [ ] Wrote a three-step rollback, with the point at which each step is used
  1. Switch the PHP version back (minutes)
  2. Roll plugins and themes back to the previous version
  3. Restore files and the database
- [ ] Upgrading production one site at a time, lowest impact first (never all at once)

### 6. After the upgrade

- [ ] The home page and main paths render
- [ ] The contact form submits and **the mail arrives**
- [ ] Admin login, editing and image upload
- [ ] cron runs
- [ ] No new errors in the PHP error log (`WP_DEBUG_LOG` on WordPress)
- [ ] Page speed compared with before the upgrade

## Need a hand?

This checklist is a generalised version of the steps I use for real upgrade work. If you would rather have someone else do it, write to [IT.Skill](https://it-skill.jp/en/?utm_source=github&utm_medium=referral&utm_campaign=php8-upgrade-check), a solo developer in Japan.

## License

MIT License
