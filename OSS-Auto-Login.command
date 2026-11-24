#!/bin/bash
# OSS Auto-Login for Safari on macOS.
#
# Double-click to set up or update the background service.
# Terminal usage (from this folder):  ./OSS-Auto-Login.command COMMAND
#
# Design:
#  - The saved password is encrypted with a Secure Enclave key that never leaves the chip.
#  - Decrypting it requires Touch ID (can be switched off with: touchid off).
#  - The encrypted storage is always kept after a confirmed login (as long as Touch ID is set up).
#  - store on|off controls the memory cache: with store on, the plaintext also stays in memory
#    between logins, while the service runs. store off (default) keeps nothing in memory.
#  - A deliberate logout clears the password and the remembered pages.
#  - Only addresses of the OSS domain are remembered (last 10, memory only).

umask 077

# ============================================================
# Settings
# ============================================================
DEFAULT_DOMAIN="online-schule.saarland"
LOGIN_PAT="login|anmeld|signin|sign-in|idp|saml"
LOGOUT_PAT="logout|abmeld|signout|sign-out|logoff|saml2/redirect/slo|saml2/post/slo"
CHECK_INTERVAL=2        # seconds between checks while an OSS tab is open
IDLE_INTERVAL=3         # seconds between checks while Safari is closed or no OSS tab is open
MAX_ATTEMPTS=2          # automatic login attempts before the password is requested again
FILL_COOLDOWN=8         # seconds to wait after filling a login form
MAX_URLS=10             # recently visited OSS pages kept in memory
LOG_KEEP_LINES=200      # the log is trimmed to this many lines
RETURN_TIMEOUT=90       # seconds allowed for returning to the last page after a re-login

# ============================================================
# Paths and configuration
# ============================================================
LABEL="local.oss-autologin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.oss-autologin"
CONFIG_FILE="$STATE_DIR/config"
LOG_FILE="$STATE_DIR/log.txt"
VAULT="$STATE_DIR/ossvault"
VAULT_SRC="$STATE_DIR/ossvault.swift"
PAUSE_FILE="$STATE_DIR/paused"
FORGET_FILE="$STATE_DIR/forget"
LOGOUT_FLAG="$STATE_DIR/logout_event"
LEGACY_KC_SERVICES="oss-autologin-saved oss-autologin-pass oss-autologin-user"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

HOST_MATCH=""
OSS_USER=""
MEMORY_CACHE=0          # 1 = keep the plaintext in memory between logins (command: store on)
TOUCHID_REQUIRED=1      # 1 = decrypting needs Touch ID, 0 = no fingerprint needed
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# ============================================================
# Runtime state (memory only)
# ============================================================
SESSION_PASS=""         # plaintext password while the service runs
PENDING_STORE=0         # 1 = typed password waits for a confirmed login before it is stored
PASS_FROM_VAULT=0       # 1 = SESSION_PASS was loaded from the vault and is cleared after filling
REQUIRE_CONFIRM=0       # 1 = after a deliberate logout the next login must be confirmed (Touch ID or typed)
ATTEMPTS=0
LAST_LOGIN_TAB=""
LAST_FILL_TS=0
DECLINED=""
PREV_LOGOUT_COUNT=0
LAST_LOGOUT_EVENT=0
IGNORE_LOGOUT_UNTIL=0
SAFARI_DOWN=1
SUPPRESS_UNTIL=0
HAVE_OSS_TAB=0
WATCHER_PID=""
WARNED=""
NOW=0
NEXT_WAIT=$CHECK_INTERVAL
LAST_URLS=""            # "tab<TAB>address" lines, newest last
RETURN_TAB=""
RETURN_URL=""
RETURN_AFTER=0
RETURN_DEADLINE=0

# JavaScript run inside a tab: returns LOGOUT, LOGIN, WAIT or OK
CHECK_JS="(function(){var u=location.href.toLowerCase();var pw=Array.prototype.find.call(document.querySelectorAll('input[type=password]'),function(e){return e.offsetParent!==null;});if(new RegExp('$LOGOUT_PAT').test(u))return 'LOGOUT';if(pw&&new RegExp('$LOGIN_PAT').test(u))return 'LOGIN';if(location.hostname.indexOf('idp.')===0)return 'WAIT';return 'OK';})()"

set_urls() {
  START_URL="https://$HOST_MATCH/"
  PORTAL_LOGOUT_URL="https://psc.$HOST_MATCH/saml2/logout"
  IDP_LOGOUT_URL="https://idp.$HOST_MATCH/idp/profile/Logout"
}
set_urls

# ============================================================
# Small helpers
# ============================================================
now_ts() { date +%s; }

say() { echo "$(date '+%H:%M:%S') $1"; }

notify() {
  osascript -e "display notification \"$1\" with title \"OSS Auto-Login\"" >/dev/null 2>&1
  say "$1"
}

# Escape a string for use inside an AppleScript string literal
as_escape() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Keep the log short (called from the service loop)
trim_log() {
  [ -f "$LOG_FILE" ] || return 0
  if [ "$(wc -l < "$LOG_FILE")" -gt $((LOG_KEEP_LINES * 2)) ]; then
    tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
  chmod 600 "$LOG_FILE" 2>/dev/null
}

# Only https addresses of the OSS domain (or a subdomain) that are not login, logout or start pages
url_allowed() {
  local u="$1" host
  case "$u" in https://*) ;; *) return 1 ;; esac
  [ "${#u}" -le 1500 ] || return 1
  host=${u#https://}; host=${host%%[/?#]*}; host=${host%%:*}
  case "$host" in "$HOST_MATCH"|*".$HOST_MATCH") ;; *) return 1 ;; esac
  [ "$u" = "$START_URL" ] && return 1
  printf '%s' "$u" | grep -qiE "$LOGIN_PAT|$LOGOUT_PAT|shibboleth" && return 1
  return 0
}

# ============================================================
# Safari access (AppleScript + JavaScript)
# ============================================================

# One line per tab with a matching address: "window.tab<TAB>STATE[*]<TAB>address".
# "*" marks the visible tab. Prints NOSAFARI, NONE, or nothing on error.
safari_check() {
  pgrep -x Safari >/dev/null 2>&1 || { echo NOSAFARI; return; }
  local js host
  js=$(as_escape "$CHECK_JS")
  host=$(as_escape "$HOST_MATCH")
  osascript 2>/dev/null <<OSA
on run
  if application "Safari" is not running then return "NOSAFARI"
  set out to ""
  set tabChar to (ASCII character 9)
  set nlChar to (ASCII character 10)
  tell application "Safari"
    set isFront to frontmost
    repeat with wi from 1 to (count of windows)
      set curIdx to 0
      try
        set curIdx to index of current tab of window wi
      end try
      repeat with ti from 1 to (count of tabs of window wi)
        try
          set t to tab ti of window wi
          if (URL of t) contains "$host" then
            set r to do JavaScript "$js" in t
            set vis to ""
            if isFront and wi is 1 and ti is curIdx then set vis to "*"
            set out to out & wi & "." & ti & tabChar & r & vis & tabChar & (URL of t) & nlChar
          end if
        end try
      end repeat
    end repeat
  end tell
  if out is "" then return "NONE"
  return out
end run
OSA
}

# Run JavaScript in one tab. $1 = "window.tab", $2 = JavaScript
safari_exec() {
  local w t js
  w=${1%%.*}; t=${1#*.}
  js=$(as_escape "$2")
  osascript 2>/dev/null <<OSA
tell application "Safari"
  return (do JavaScript "$js" in tab $t of window $w)
end tell
OSA
}

# Point one tab at another address. $1 = "window.tab", $2 = address
safari_nav() {
  local w t url
  w=${1%%.*}; t=${1#*.}
  url=$(as_escape "$2")
  osascript >/dev/null 2>&1 <<OSA
tell application "Safari"
  set URL of tab $t of window $w to "$url"
end tell
OSA
}

# Open an address in a background tab, wait, read the final address, then close that tab again.
# The tab is found by a unique marker in its address, never by its position.
# $1 = address, $2 = seconds to wait
safari_bg_visit() {
  local url marker
  url=$(as_escape "$1")
  marker="oss-al-$RANDOM$RANDOM"
  osascript 2>/dev/null <<OSA
tell application "Safari"
  if (count of windows) is 0 then return "NOWINDOW"
  set w to window 1
  set oldTab to current tab of w
  set newTab to make new tab at end of tabs of w with properties {URL:"$url#$marker"}
  set current tab of w to oldTab
  delay $2
  set u to ""
  repeat with wi from (count of windows) to 1 by -1
    repeat with ti from (count of tabs of window wi) to 1 by -1
      try
        if (URL of tab ti of window wi) contains "$marker" then
          set u to URL of tab ti of window wi
          close tab ti of window wi
        end if
      end try
    end repeat
  end repeat
  return u
end tell
OSA
}

# ============================================================
# Remembered pages (last MAX_URLS, memory only)
# ============================================================
url_remember() {   # $1 = tab, $2 = address
  url_allowed "$2" || return 0
  [ "$(url_get "$1")" = "$2" ] && return 0
  LAST_URLS=$({ printf '%s\n' "$LAST_URLS" | awk 'NF'; printf '%s\t%s\n' "$1" "$2"; } | tail -n "$MAX_URLS")
}

url_get() {        # $1 = tab: newest remembered address of this tab
  printf '%s\n' "$LAST_URLS" | awk -F'\t' -v id="$1" '$1 == id { u = $2 } END { print u }'
}

# ============================================================
# Vault: the password is encrypted by a Secure Enclave key (Swift helper)
# ============================================================

# Writes the Swift helper source, compiles it and removes the source again.
vault_build() {
  [ -x "$VAULT" ] && return 0
  mkdir -p "$STATE_DIR"
  cat > "$VAULT_SRC" <<'SWIFT'
import Foundation
import CryptoKit
import LocalAuthentication

// Protects one password with a Secure Enclave key.
// Usage: ossvault <state-dir> setup bio|nobio | store | load | check | destroy
//   setup    create the key (bio = key usable only with Touch ID, nobio = usable while the Mac is unlocked)
//   store    read the plaintext password from stdin, write it encrypted to secret.bin
//   load     decrypt secret.bin and print the password to stdout (Touch ID prompt if the key needs it)
//   check    print "bio" if Touch ID is usable, otherwise "nobio"
//   destroy  delete key and encrypted password

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count < 3 { fail("usage: ossvault <state-dir> setup|store|load|check|destroy [bio|nobio]") }
let directory = arguments[1]
let command = arguments[2]
let keyURL = URL(fileURLWithPath: directory + "/se.key")
let pubURL = URL(fileURLWithPath: directory + "/se.pub")
let secretURL = URL(fileURLWithPath: directory + "/secret.bin")
let kdfInfo = Data("oss-autologin-v1".utf8)

func biometryAvailable() -> Bool {
    return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
}

func symmetricKey(_ secret: SharedSecret) -> SymmetricKey {
    return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: kdfInfo, outputByteCount: 32)
}

func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func run() throws {
    switch command {
    case "setup":
        let useBiometry = arguments.count > 3 && arguments[3] == "bio"
        guard SecureEnclave.isAvailable else { fail("no-secure-enclave") }
        if useBiometry && !biometryAvailable() { fail("no-biometry") }
        var error: Unmanaged<CFError>?
        let flags: SecAccessControlCreateFlags = useBiometry ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage]
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            fail("access-control")
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        try writePrivate(key.dataRepresentation, to: keyURL)
        try writePrivate(key.publicKey.x963Representation, to: pubURL)
        print("ok")

    case "store":
        // Encrypt with the public key only: no fingerprint needed for saving.
        let plain = FileHandle.standardInput.readDataToEndOfFile()
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: Data(contentsOf: pubURL))
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let sealed = try AES.GCM.seal(plain, using: symmetricKey(shared))
        var blob = ephemeral.publicKey.x963Representation
        blob.append(sealed.combined!)
        try writePrivate(blob, to: secretURL)
        print("ok")

    case "load":
        // Decrypting uses the Secure Enclave key, which asks for Touch ID if the key was created with biometry.
        let context = LAContext()
        context.localizedReason = "OSS-Passwort fuer die Anmeldung freigeben"
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: Data(contentsOf: keyURL), authenticationContext: context)
        let blob = try Data(contentsOf: secretURL)
        let ephemeralPublic = try P256.KeyAgreement.PublicKey(x963Representation: Data(blob.prefix(65)))
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let box = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(65)))
        FileHandle.standardOutput.write(try AES.GCM.open(box, using: symmetricKey(shared)))

    case "check":
        print(biometryAvailable() ? "bio" : "nobio")

    case "destroy":
        for url in [keyURL, pubURL, secretURL] {
            try? FileManager.default.removeItem(at: url)
        }
        print("ok")

    default:
        fail("unknown command")
    }
}

do {
    try run()
} catch {
    fail("\(error)")
}
SWIFT
  swiftc -O -o "$VAULT" "$VAULT_SRC" >/dev/null 2>&1
  local rc=$?
  rm -f "$VAULT_SRC"
  return $rc
}

# Creates the key if needed. Mode follows TOUCHID_REQUIRED.
ensure_vault_key() {
  local mode=nobio
  [ "$TOUCHID_REQUIRED" = 1 ] && mode=bio
  vault_build || return 1
  [ -f "$STATE_DIR/se.key" ] && return 0
  "$VAULT" "$STATE_DIR" setup "$mode" >/dev/null 2>&1
}

vault_has_secret() {
  [ -x "$VAULT" ] && [ -f "$STATE_DIR/se.key" ] && [ -f "$STATE_DIR/secret.bin" ]
}

# Prints the password (Touch ID if required). Fails if nothing is stored or the user cancels.
load_secret() {
  vault_has_secret || return 1
  "$VAULT" "$STATE_DIR" load 2>/dev/null
}

store_secret() {   # reads $SESSION_PASS
  ensure_vault_key || return 1
  printf '%s' "$SESSION_PASS" | "$VAULT" "$STATE_DIR" store >/dev/null 2>&1
}

destroy_vault() {
  [ -x "$VAULT" ] && "$VAULT" "$STATE_DIR" destroy >/dev/null 2>&1
  rm -f "$STATE_DIR/se.key" "$STATE_DIR/se.pub" "$STATE_DIR/secret.bin"
}

# Old versions stored the password in the login keychain. Remove those entries.
purge_legacy_keychain() {
  local svc i
  for svc in $LEGACY_KC_SERVICES; do
    i=0
    while [ "$i" -lt 20 ] && security delete-generic-password -s "$svc" >/dev/null 2>&1; do
      i=$((i + 1))
    done
  done
}

# Obtain the password for a login.
# Stored password and Touch ID required (or no deliberate logout since the last login):
# Touch ID is asked first. If it is cancelled or fails, the password can be typed.
# Otherwise (Touch ID off after a deliberate logout) the password must be typed.
obtain_password() {
  local pw
  TOUCHID_TRIED=0
  # Memory cache (store on): the password is still in memory and no deliberate logout happened
  if [ "$MEMORY_CACHE" = 1 ] && [ -n "$SESSION_PASS" ]; then
    return 0
  fi
  if vault_has_secret; then
    if [ "$TOUCHID_REQUIRED" = 1 ] || [ "$REQUIRE_CONFIRM" = 0 ]; then
      TOUCHID_TRIED=1
      pw=$(load_secret) && [ -n "$pw" ] && { SESSION_PASS="$pw"; PASS_FROM_VAULT=1; return 0; }
    fi
  fi
  if [ "$TOUCHID_TRIED" = 1 ]; then
    ask_password "Touch ID wurde abgebrochen oder ist fehlgeschlagen. OSS-Passwort eingeben:" || return 1
  else
    ask_password || return 1
  fi
  REQUIRE_CONFIRM=0
  PENDING_STORE=1
  return 0
}

# Store a typed password once the login is confirmed (only if encrypted storage is on)
store_if_pending() {
  [ "$PENDING_STORE" = 1 ] && [ -n "$SESSION_PASS" ] || return 0
  PENDING_STORE=0
  if store_secret; then
    notify "Passwort verschluesselt im Langzeitspeicher abgelegt"
  else
    notify "Passwort nicht verschluesselt gespeichert (Touch ID nicht eingerichtet oder Werkzeuge fehlen)"
  fi
  # Without the memory cache the plaintext is dropped right after it is stored
  [ "$MEMORY_CACHE" = 0 ] && SESSION_PASS=""
  return 0
}

# Password dialog. Sets SESSION_PASS only on success; a cancelled dialog keeps the old value.
ask_password() {
  local pw user msg
  user=$(as_escape "$OSS_USER")
  msg=$(as_escape "${1:-OSS-Passwort fuer $OSS_USER eingeben:}")
  pw=$(osascript 2>/dev/null <<OSA
tell application "System Events"
  activate
  set r to display dialog "$msg" default answer "" with hidden answer with title "OSS Auto-Login" buttons {"Abbrechen", "OK"} default button "OK" giving up after 300
  if gave up of r then error number -128
  return text returned of r
end tell
OSA
) || return 1
  [ -n "$pw" ] || return 1
  SESSION_PASS="$pw"
  return 0
}

# ============================================================
# Filling the login form
# ============================================================
fill_js() {
  local u64 p64
  u64=$(printf '%s' "$OSS_USER" | base64 | tr -d '\n')
  p64=$(printf '%s' "$SESSION_PASS" | base64 | tr -d '\n')
  cat <<JS
(function(){if(!new RegExp('$LOGIN_PAT').test(location.href.toLowerCase()))return 'NOLOGINPAGE';var dec=function(s){return new TextDecoder().decode(Uint8Array.from(atob(s),function(c){return c.charCodeAt(0);}));};var U=dec('$u64'),P=dec('$p64');var pw=Array.prototype.find.call(document.querySelectorAll('input[type=password]'),function(e){return e.offsetParent!==null;});if(!pw)return 'NOPW';var form=pw.form;var scope=form||document;var fields=Array.prototype.filter.call(scope.querySelectorAll('input'),function(e){return /^(text|email|tel|)$/.test(e.type)&&e.offsetParent!==null;});var userField=fields.find(function(e){return /user|login|name|mail|kenn|id/i.test((e.name||'')+' '+(e.id||'')+' '+(e.autocomplete||''));})||fields[fields.length-1];var setVal=function(el,v){var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value');d.set.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));};if(userField)setVal(userField,U);setVal(pw,P);setTimeout(function(){var btn=scope.querySelector('button[name=_eventId_proceed]')||scope.querySelector('button[type=submit],input[type=submit]');if(btn)btn.click();else if(form)form.requestSubmit();else pw.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));},500);return 'FILLED';})()
JS
}

# ============================================================
# Deliberate logout: clear the password and the remembered pages
# ============================================================

# End the portal and identity-provider sessions, so the next login really asks for Touch ID or the password
end_sessions() {
  safari_bg_visit "$PORTAL_LOGOUT_URL" 4 >/dev/null
  safari_bg_visit "$IDP_LOGOUT_URL" 4 >/dev/null
}

# Bring leftover logout pages back to the OSS start page
lead_back() {
  local res id st url
  res=$(safari_check)
  case "$res" in ""|NOSAFARI|NONE) return 0 ;; esac
  while IFS=$'\t' read -r id st url; do
    [ -z "$id" ] && continue
    st=${st%\*}
    [ "$st" = LOGOUT ] && safari_nav "$id" "$START_URL"
  done <<< "$res"
  return 0
}

on_logout_event() {   # $1 = address (for the log only)
  NOW=$(now_ts)
  [ -f "$PAUSE_FILE" ] && return 0
  [ "$NOW" -lt "$SUPPRESS_UNTIL" ] && return 0        # Safari just started: restored tabs
  [ "$NOW" -lt "$IGNORE_LOGOUT_UNTIL" ] && return 0   # our own logout visits
  [ $((NOW - LAST_LOGOUT_EVENT)) -le 5 ] && return 0  # duplicate report
  LAST_LOGOUT_EVENT=$NOW
  say "Abmelde-Seite erkannt: ${1%%\?*}"
  # A logout is only possible after a login, so a password typed just before is confirmed
  if [ "$PENDING_STORE" = 1 ] && [ $((NOW - LAST_FILL_TS)) -le 600 ]; then
    store_if_pending
  fi
  SESSION_PASS=""
  PENDING_STORE=0
  REQUIRE_CONFIRM=1
  ATTEMPTS=0
  DECLINED=""
  LAST_URLS=""
  RETURN_TAB=""
  RETURN_URL=""
  notify "Abgemeldet - Passwort aus dem Speicher geloescht"
  IGNORE_LOGOUT_UNTIL=$((NOW + 60))
  end_sessions
  lead_back
  rm -f "$LOGOUT_FLAG"
  IGNORE_LOGOUT_UNTIL=$(( $(now_ts) + 4 ))
  return 0
}

# ============================================================
# Watcher: a separate process that checks Safari about every 0.15 s
# while an OSS tab is open, so very short logout pages are not missed.
# It only writes the logout address (without query) into LOGOUT_FLAG.
# ============================================================
start_watcher() {
  local host p pats="" sep=""
  host=$(as_escape "$HOST_MATCH")
  while IFS= read -r p; do
    pats="$pats$sep\"$(as_escape "$p")\""
    sep=", "
  done <<PATS
$(printf '%s' "$LOGOUT_PAT" | tr '|' '\n')
PATS
  osascript 2>/dev/null <<OSA &
set hostStr to "$host"
set pats to {$pats}
set flagPath to "$LOGOUT_FLAG"
set prevCount to 0
set wasRunning to false
set firstPass to true
set quietUntil to (current date)
repeat
  set pause to 1.0
  try
    if application "Safari" is running then
      if not wasRunning then
        set wasRunning to true
        if not firstPass then set quietUntil to (current date) + 25
      end if
      set n to 0
      set h to 0
      set hit to ""
      tell application "Safari"
        set allURLs to URL of every tab of every window
      end tell
      repeat with wl in allURLs
        repeat with u in wl
          try
            set us to u as text
            if us contains hostStr then
              set h to h + 1
              repeat with p in pats
                if us contains (p as text) then
                  set n to n + 1
                  set hit to us
                  exit repeat
                end if
              end repeat
            end if
          end try
        end repeat
      end repeat
      if firstPass then
        set firstPass to false
      else if n > prevCount and (current date) > quietUntil then
        if hit contains "?" then set hit to text 1 thru ((offset of "?" in hit) - 1) of hit
        do shell script "printf '%s' " & quoted form of hit & " > " & quoted form of flagPath
      end if
      set prevCount to n
      if h > 0 then set pause to 0.15
    else
      set wasRunning to false
      set firstPass to false
      set prevCount to 0
    end if
  end try
  delay pause
end repeat
OSA
  WATCHER_PID=$!
  disown "$WATCHER_PID" 2>/dev/null
}

# The watcher runs only while an OSS tab is open
manage_watcher() {
  if [ "$HAVE_OSS_TAB" = 1 ]; then
    if [ -z "$WATCHER_PID" ] || ! kill -0 "$WATCHER_PID" 2>/dev/null; then
      start_watcher
    fi
  elif [ -n "$WATCHER_PID" ]; then
    kill "$WATCHER_PID" 2>/dev/null
    WATCHER_PID=""
    rm -f "$LOGOUT_FLAG"
  fi
}

check_logout_flag() {
  local hit
  [ -f "$LOGOUT_FLAG" ] || return 0
  hit=$(cat "$LOGOUT_FLAG" 2>/dev/null)
  rm -f "$LOGOUT_FLAG"
  on_logout_event "$hit"
}

# Sleep for $1 seconds; while the watcher runs, its report is checked every 0.5 s
wait_watch() {
  local i=0
  manage_watcher
  if [ -z "$WATCHER_PID" ]; then
    sleep "$1"
    return 0
  fi
  while [ "$i" -lt $(( $1 * 2 )) ]; do
    sleep 0.5
    check_logout_flag
    i=$((i + 1))
  done
}

# ============================================================
# Main check, run every CHECK_INTERVAL seconds
# ============================================================
note_safari_up() {
  if [ "$SAFARI_DOWN" = 1 ]; then
    SAFARI_DOWN=0
    SUPPRESS_UNTIL=$((NOW + 25))
  fi
}

forget_password() {
  rm -f "$FORGET_FILE"
  SESSION_PASS=""
  PENDING_STORE=0
  ATTEMPTS=0
  DECLINED=""
  notify "Passwort vergessen - bei der naechsten Anmeldeseite neu eingeben"
}

# Returns to the remembered page after a successful re-login
handle_return() {
  local ret_ok=$1 ret_cur=$2
  [ -n "$RETURN_TAB" ] || return 0
  if [ "$NOW" -ge "$RETURN_DEADLINE" ]; then
    RETURN_TAB=""; RETURN_URL=""
  elif [ "$ret_ok" = 1 ] && [ "$NOW" -ge "$RETURN_AFTER" ]; then
    if url_allowed "$RETURN_URL" && [ "$ret_cur" != "$RETURN_URL" ]; then
      say "Zurueck zur letzten Seite: ${RETURN_URL%%\?*}"
      safari_nav "$RETURN_TAB" "$RETURN_URL"
    fi
    RETURN_TAB=""; RETURN_URL=""
  fi
}

tick_inner() {
  local res id st url vis logout_count=0 login_tab="" login_vis=0 ret_ok=0 ret_cur=""
  [ -f "$FORGET_FILE" ] && forget_password
  [ -f "$PAUSE_FILE" ] && return 0
  NOW=$(now_ts)
  res=$(safari_check)
  case "$res" in
    "")
      if [ -z "$WARNED" ]; then
        WARNED=1
        say "Keine Antwort von Safari. Ist 'JavaScript aus Apple-Events erlauben' aktiviert?"
      fi
      return 0 ;;
    NOSAFARI)
      SAFARI_DOWN=1; HAVE_OSS_TAB=0; LAST_URLS=""; NEXT_WAIT=$IDLE_INTERVAL
      return 0 ;;
    NONE)
      note_safari_up; HAVE_OSS_TAB=0; LAST_URLS=""; PREV_LOGOUT_COUNT=0; NEXT_WAIT=$IDLE_INTERVAL
      return 0 ;;
  esac
  note_safari_up
  HAVE_OSS_TAB=1

  while IFS=$'\t' read -r id st url; do
    [ -z "$id" ] && continue
    vis=0
    case "$st" in *'*') vis=1; st=${st%?} ;; esac
    case "$st" in
      LOGOUT) logout_count=$((logout_count + 1)) ;;
      LOGIN)
        if [ -z "$login_tab" ] || { [ "$vis" = 1 ] && [ "$login_vis" != 1 ]; }; then
          login_tab=$id; login_vis=$vis
        fi ;;
      OK)
        if [ "$id" = "$LAST_LOGIN_TAB" ]; then
          # The login tab shows a normal page again: the login worked.
          ATTEMPTS=0
          LAST_LOGIN_TAB=""
          REQUIRE_CONFIRM=0
          store_if_pending
          RETURN_URL=$(url_get "$id")
          if [ -n "$RETURN_URL" ]; then
            RETURN_TAB=$id
            RETURN_AFTER=$((NOW + 3))
            RETURN_DEADLINE=$((NOW + RETURN_TIMEOUT))
          fi
        else
          url_remember "$id" "$url"
        fi
        if [ "$id" = "$RETURN_TAB" ]; then ret_ok=1; ret_cur=$url; fi ;;
    esac
  done <<< "$res"

  handle_return "$ret_ok" "$ret_cur"

  # Second check next to the watcher: a new logout page appeared
  local prev=$PREV_LOGOUT_COUNT
  PREV_LOGOUT_COUNT=$logout_count
  if [ "$logout_count" -gt "$prev" ]; then
    on_logout_event "(tab count)"
    return 0
  fi

  if [ -n "$DECLINED" ] && [ "$login_tab" != "$DECLINED" ]; then
    DECLINED=""
  fi

  # ---- Login page ----
  [ -z "$login_tab" ] && return 0
  [ "$login_tab" = "$DECLINED" ] && return 0
  if [ "$login_tab" = "$LAST_LOGIN_TAB" ] && [ "$NOW" -lt $((LAST_FILL_TS + FILL_COOLDOWN)) ]; then
    return 0
  fi

  # Only ask or fill on a visible login page (never on a background tab)
  if [ -z "$SESSION_PASS" ]; then
    [ "$login_vis" = 1 ] || return 0
    if ! obtain_password; then
      DECLINED=$login_tab
      return 0
    fi
  fi

  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    [ "$login_vis" = 1 ] || return 0
    notify "Login fehlgeschlagen - Passwort evtl. falsch"
    ATTEMPTS=0
    if ask_password "Anmeldung fehlgeschlagen. Passwort erneut eingeben (Abbrechen behaelt das bisherige):"; then
      PENDING_STORE=1
    else
      DECLINED=$login_tab
    fi
    return 0
  fi

  ATTEMPTS=$((ATTEMPTS + 1))
  LAST_LOGIN_TAB=$login_tab
  LAST_FILL_TS=$NOW
  say "Login wird ausgefuellt (Versuch $ATTEMPTS)"
  safari_exec "$login_tab" "$(fill_js)" > /dev/null
  if [ "$PASS_FROM_VAULT" = 1 ]; then
    PASS_FROM_VAULT=0
    [ "$MEMORY_CACHE" = 0 ] && SESSION_PASS=""
  fi
  return 0
}

tick() {
  NEXT_WAIT=$CHECK_INTERVAL
  tick_inner
  manage_watcher
}

service_main() {
  if [ -z "$HOST_MATCH" ] || [ -z "$OSS_USER" ]; then
    echo "Nicht eingerichtet. Bitte OSS-Auto-Login.command per Doppelklick starten."
    exit 0
  fi
  trim_log
  trap 'exit 0' TERM INT HUP
  trap 'kill "$WATCHER_PID" 2>/dev/null' EXIT
  say "Dienst gestartet (Adresse $HOST_MATCH, store: $MEMORY_CACHE, touchid: $TOUCHID_REQUIRED)"
  local loops=0
  while true; do
    tick
    wait_watch "$NEXT_WAIT"
    loops=$((loops + 1))
    if [ $((loops % 600)) -eq 0 ]; then trim_log; fi
  done
}

# ============================================================
# Setup dialogs and configuration
# ============================================================
dialog_text() {
  osascript 2>/dev/null <<OSA
tell application "System Events"
  activate
  set r to display dialog "$(as_escape "$1")" default answer "$(as_escape "$2")" with title "OSS Auto-Login" buttons {"Abbrechen", "OK"} default button "OK"
  return text returned of r
end tell
OSA
}

write_config() {
  mkdir -p "$STATE_DIR"
  {
    printf 'HOST_MATCH=%q\n' "$HOST_MATCH"
    printf 'OSS_USER=%q\n' "$OSS_USER"
    printf 'MEMORY_CACHE=%q\n' "$MEMORY_CACHE"
    printf 'TOUCHID_REQUIRED=%q\n' "$TOUCHID_REQUIRED"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

first_setup() {
  local domain user
  domain=$(dialog_text "OSS-Adresse (Teil der Adresse aus Safari):" "$DEFAULT_DOMAIN") || return 1
  domain=${domain#http://}; domain=${domain#https://}; domain=${domain%%/*}
  [ -z "$domain" ] && return 1
  user=$(dialog_text "OSS-Benutzername (das Passwort wird erst bei der Anmeldung abgefragt):" "") || return 1
  [ -z "$user" ] && return 1
  HOST_MATCH=$domain
  OSS_USER=$user
  MEMORY_CACHE=0
  TOUCHID_REQUIRED=1
  write_config
  set_urls
  return 0
}

# ============================================================
# Background service (LaunchAgent)
# ============================================================
write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$STATE_DIR/oss-autologin.sh</string><string>start</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict></plist>
PL
}

restart_service() {
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1
}

# Bring the working copy, the LaunchAgent and the running service up to date
ensure_service() {
  local changed=0 loaded=0
  mkdir -p "$STATE_DIR"
  if ! cmp -s "$SELF" "$STATE_DIR/oss-autologin.sh" 2>/dev/null; then
    cp "$SELF" "$STATE_DIR/oss-autologin.sh"
    changed=1
  fi
  chmod 700 "$STATE_DIR/oss-autologin.sh"
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && loaded=1
  if [ "$changed" = 1 ] || [ "$loaded" = 0 ] || [ ! -f "$PLIST" ]; then
    write_plist
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    sleep 1
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  fi
  purge_legacy_keychain
}

close_terminal_window() {
  [ -t 1 ] || return 0
  ( sleep 1; osascript -e 'tell application "Terminal" to close (every window whose name contains "OSS-Auto-Login")' >/dev/null 2>&1 ) &
  disown 2>/dev/null
  return 0
}

auto_launch() {
  if [ -z "$HOST_MATCH" ] || [ -z "$OSS_USER" ]; then
    if first_setup; then
      ensure_service
      notify "Eingerichtet. Das Passwort wird bei der Anmeldung abgefragt."
    fi
  else
    ensure_service
  fi
  close_terminal_window
}

# ============================================================
# Terminal commands
# ============================================================
store_command() {
  case "$1" in
    on)
      MEMORY_CACHE=1; write_config
      echo "store on: Das Passwort bleibt zusaetzlich zwischen den Anmeldungen im Arbeitsspeicher (bis zur bewussten Abmeldung oder einem Neustart)."
      echo "Der verschluesselte Langzeitspeicher bleibt davon unberuehrt."
      echo ""
      warn_memory_password
      restart_service ;;
    off)
      MEMORY_CACHE=0; SESSION_PASS=""; write_config
      echo "store off: Das Passwort wird nicht im Arbeitsspeicher gehalten. Es wird bei Bedarf aus dem Langzeitspeicher geholt (Touch ID)."
      restart_service ;;
    *)
      echo "Benutzung: ./OSS-Auto-Login.command store on|off"
      return 1 ;;
  esac
}

touchid_command() {
  case "$1" in
    on)  TOUCHID_REQUIRED=1 ;;
    off) TOUCHID_REQUIRED=0 ;;
    *)
      echo "Benutzung: ./OSS-Auto-Login.command touchid on|off"
      return 1 ;;
  esac
  destroy_vault
  write_config
  restart_service
  if [ "$TOUCHID_REQUIRED" = 1 ]; then
    echo "touchid on: Touch ID wird zuerst gefragt. Ein gespeichertes Passwort wurde geloescht und wird nach dem naechsten Login neu gespeichert."
  else
    echo "touchid off: WARNUNG - solange der Mac entsperrt ist, wird das gespeicherte Passwort auf jeder OSS-Anmeldeseite ohne Nachfrage eingesetzt."
    echo "Ein Programm mit deinen Rechten koennte es dann ohne Fingerabdruck nutzen. Nach einer bewussten Abmeldung muss das Passwort weiterhin eingetippt werden."
    echo "Ein gespeichertes Passwort wurde geloescht und wird nach dem naechsten Login neu gespeichert."
  fi
}

# Warning shown when the password can stay in plain memory for a long time
warn_memory_password() {
  echo "WARNUNG: Mit store on bleibt das Passwort unverschluesselt im Arbeitsspeicher des Dienstes, solange er laeuft."
  echo "Das gilt bis zur bewussten Abmeldung, bis zum Neustart des Dienstes oder des Macs. Ein Programm"
  echo "mit deinen Rechten koennte es dort auslesen. Sicherer ist store off (Standard)."
}

# Overview of all commands (shown by "help")
show_help() {
  cat <<'HELP'
OSS Auto-Login - Befehle

Aufruf:  ./OSS-Auto-Login.command BEFEHL
         (aus dem Ordner starten, in dem die Datei liegt)

  status        Zeigt, ob der Dienst aktiv oder pausiert ist, den Stand von store
                und touchid und ob ein Passwort im Langzeitspeicher liegt.
  check         Zeigt, was Safari gerade fuer die OSS-Tabs meldet.
  pause         Stoppt die automatische Anmeldung und die Abmelde-Erkennung.
  resume        Startet beides wieder nach einer Pause.
  password      Vergisst das Passwort im Arbeitsspeicher sofort. Keine Abmeldung noetig.
  store on      Haelt das Passwort zusaetzlich zwischen den Anmeldungen im Arbeitsspeicher.
                Der Langzeitspeicher bleibt unberuehrt.
  store off     Haelt das Passwort nicht im Arbeitsspeicher (Standard). Es wird bei
                Bedarf aus dem Langzeitspeicher geholt.
  touchid on    Touch ID wird beim Einsetzen eines gespeicherten Passworts zuerst gefragt
                (Standard). Bei Abbruch kannst du das Passwort eintippen.
  touchid off   Gespeicherte Passwoerter werden ohne Touch ID eingesetzt, solange der Mac
                entsperrt ist. Nach einer bewussten Abmeldung muss das Passwort trotzdem
                eingetippt werden. Ein gespeichertes Passwort wird dabei geloescht.
  logout        Beendet die Sitzungen von OSS-Portal und Anmeldedienst sofort.
  reset         Entfernt alles und richtet neu ein. Fragt vorher nach; "reset --yes"
                ueberspringt die Frage.
  uninstall     Entfernt alles, auch das gespeicherte Passwort. Fragt vorher nach;
                "uninstall --yes" ueberspringt die Frage.
  help          Zeigt diese Uebersicht.

Ohne Befehl richtet die Datei den Dienst ein bzw. aktualisiert ihn (wie der Doppelklick).
HELP
}

# Remove everything this script created
remove_all() {
  local i left=0 svc
  echo "Hintergrunddienst wird beendet ..."
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  launchctl remove "$LABEL" >/dev/null 2>&1
  pkill -f "$STATE_DIR/oss-autologin.sh" >/dev/null 2>&1
  sleep 1

  echo "Dateien werden geloescht ..."
  rm -f "$PLIST"
  if [ -n "$HOME" ] && [ "$HOME" != "/" ] && [ "$STATE_DIR" = "$HOME/.oss-autologin" ]; then
    rm -rf -- "$STATE_DIR"
  fi

  echo "Alte Schluesselbund-Eintraege werden geloescht ..."
  purge_legacy_keychain

  OSS_USER=""; HOST_MATCH=""; SESSION_PASS=""

  echo "Ergebnis wird geprueft:"
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then echo "  [!] service still running"; left=1; else echo "  [ok] service removed"; fi
  if [ -e "$PLIST" ]; then echo "  [!] start file still there: $PLIST"; left=1; else echo "  [ok] start file removed"; fi
  if [ -e "$STATE_DIR" ]; then echo "  [!] folder still there: $STATE_DIR"; left=1; else echo "  [ok] data folder removed"; fi
  for svc in $LEGACY_KC_SERVICES; do
    if security find-generic-password -s "$svc" >/dev/null 2>&1; then echo "  [!] Schluesselbund-Eintrag '$svc' noch da"; left=1; fi
  done
  [ "$left" = 0 ] && echo "  [ok] keine Schluesselbund-Eintraege mehr"
  return "$left"
}

confirm_removal() {
  local answer
  [ "$1" = "--yes" ] && return 0
  if [ -t 0 ]; then
    read -r -p "Really delete EVERYTHING (service, configuration, log, stored password)? [y/N] " answer
    case "$answer" in y|Y|j|J) return 0 ;; esac
    echo "Cancelled. Nothing was deleted."
    return 1
  fi
  return 0
}

main() {
  case "${1:-auto}" in
    auto)  auto_launch ;;
    start) service_main ;;
    status)
      if [ -f "$PAUSE_FILE" ]; then echo "Dienst:     pausiert"; else echo "Dienst:     aktiv"; fi
      if [ -f "$STATE_DIR/secret.bin" ]; then
        echo "Langzeitspeicher: Passwort verschluesselt gespeichert (Touch ID)"
      else
        echo "Langzeitspeicher: noch kein Passwort gespeichert"
      fi
      if [ "$MEMORY_CACHE" = 1 ]; then
        echo "store:       an  (Passwort bleibt zwischen den Anmeldungen im Arbeitsspeicher)"
      else
        echo "store:       aus (Passwort wird nicht im Arbeitsspeicher gehalten)"
      fi
      if [ "$TOUCHID_REQUIRED" = 1 ]; then
        echo "touchid:     an  (Touch ID wird beim Einsetzen zuerst gefragt)"
      else
        echo "touchid:     aus (gespeichertes Passwort wird ohne Touch ID eingesetzt, solange der Mac entsperrt ist)"
      fi
      echo ""
      echo "Letzte Ereignisse:"
      tail -n 8 "$LOG_FILE" 2>/dev/null ;;
    check)
      res=$(safari_check)
      printf '%s\n' "$res" | awk -F'\t' 'NF >= 2 { printf "%s=%s  ", $1, $2 } !NF && $0 { printf "%s", $0 }'; echo ;;
    pause)    touch "$PAUSE_FILE"; echo "Dienst pausiert: keine automatische Anmeldung und keine Abmelde-Erkennung." ;;
    resume)   rm -f "$PAUSE_FILE"; echo "Dienst wieder aktiv." ;;
    password) touch "$FORGET_FILE"; echo "Passwort im Arbeitsspeicher vergessen. Auf der naechsten Anmeldeseite wirst du gefragt." ;;
    store)    store_command "$2" ;;
    touchid)  touchid_command "$2" ;;
    logout)
      echo "OSS-Portal- und Anmeldedienst-Sitzungen werden beendet ..."
      end_sessions
      echo "Fertig. Die naechste Anmeldung braucht Touch ID oder das Passwort." ;;
    help|-h|--help) show_help ;;
    reset)
      case "$SELF" in
        "$STATE_DIR"/*) echo "Bitte 'reset' mit der Datei aus dem Projektordner starten, nicht mit der installierten Kopie."; exit 1 ;;
      esac
      confirm_removal "$2" || exit 1
      remove_all
      mkdir -p "$STATE_DIR"
      auto_launch ;;
    uninstall)
      confirm_removal "$2" || exit 1
      if remove_all; then
        echo "Auto-Login vollstaendig entfernt. Du kannst jetzt die Datei OSS-Auto-Login.command loeschen."
      else
        echo "Einige Teile konnten nicht entfernt werden (siehe oben)."
        exit 1
      fi ;;
    *)
      echo "Unbekannter Befehl. Mit 'help' siehst du alle Befehle."
      exit 1 ;;
  esac
}

[ -n "$OSS_SOURCE_ONLY" ] || main "$@"
