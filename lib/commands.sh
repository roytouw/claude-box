# claude-box subcommands: init, set, secret, trust, doctor, list, profiles, status, logs, stop, update.
# Their usage lines live in the header of bin/claude-box (shown by `claude-box <command> -h`).
# Sourced by bin/claude-box (bash 3.2 compatible: macOS /bin/bash). Secret values are never printed.

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; DOCTOR_PROBLEMS=$((DOCTOR_PROBLEMS + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
hint() { printf '      %s\n' "$*"; }
DOCTOR_PROBLEMS=0
export GIT_TERMINAL_PROMPT=0   # no git command here may ever wait for input on the terminal

valid_ws()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
need_ws()   { valid_ws "${1:-}" || { echo "workspace must be a plain name, got: ${1:-<none>}" >&2; exit 2; }; }
ws_cfg()    { echo "$WS_ROOT/$1/.claude-box"; }
cfg_value() { local f; f="$(ws_cfg "$1")/$2"; [[ -f "$f" ]] && head -1 "$f" | tr -d '[:space:]' || true; }
cfg_line()  { local f; f="$(ws_cfg "$1")/$2"; [[ -f "$f" ]] && sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$f" || true; }   # keeps inner spaces
env_value() { local f; f="$(ws_cfg "$1")/env"; [[ -f "$f" ]] && sed -n "s/^$2=//p" "$f" | head -1 || true; }
keychain()  { security find-generic-password -s "claude-box/$1/$2" -w 2>/dev/null || true; }
secret_names() {
  local f; f="$(ws_cfg "$1")/secrets.txt"; [[ -f "$f" ]] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -E '^[A-Z_][A-Z0-9_]*$' || true
}

# git@host:path, ssh://git@host/path or https://host/path  ->  https://host/path(.git)
https_url() {
  local u="$1"
  case "$u" in
    git@*:*)   u="${u#git@}"; u="https://${u/://}" ;;
    ssh://*)   u="${u#ssh://}"; u="https://${u#*@}" ;;
    *)         echo "$u"; return ;;
  esac
  # SSH host aliases (e.g. github-personal) -> the real hostname from ~/.ssh/config
  local h real; h="$(url_host "$u")"
  real="$(ssh -G "$h" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
  [[ -n "$real" && "$real" != "$h" ]] && u="https://$real/${u#https://"$h"/}"
  echo "$u"
}
url_host() { local u="${1#*://}"; echo "${u%%/*}"; }
url_path() { local u="${1#*://}"; u="${u#*/}"; echo "${u%.git}"; }
urlencode() { local s="$1" o="" c i; for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"; case "$c" in [A-Za-z0-9._~-]) o+="$c" ;; *) o+="$(printf '%%%02X' "'$c")" ;; esac; done; echo "$o"; }

# Repos in a workspace: the workspace itself, or its direct subfolders.
ws_repos() {
  local d="$WS_ROOT/$1"
  if [[ -d "$d/.git" ]]; then echo "$d"; return; fi
  for r in "$d"/*/; do [[ -d "$r.git" ]] && echo "${r%/}"; done
  return 0
}

gitlab_host_for() { local h; h="$(env_value "$1" GITLAB_HOST)"; h="${h#*://}"; h="${h%%/*}"; echo "${h:-gitlab.com}"; }

# --- secret validation (value comes from the Keychain or clipboard, is never echoed) ----------
check_shape() {  # $1 var, $2 value -> prints problem or nothing
  local var="$1" v="$2"
  [[ -z "$v" ]] && { echo "is empty"; return; }
  [[ "$v" == security\ * || "$v" == *add-generic-password* ]] && { echo "contains a command, not the secret (copy the token itself)"; return; }
  [[ "$v" =~ [[:space:]] ]] && { echo "contains whitespace (copied too much?)"; return; }
  case "$var" in
    GH_TOKEN) [[ "$v" =~ ^(github_pat_|ghp_|gho_) ]] || echo "doesn't look like a GitHub token (github_pat_…)" ;;
    GITLAB_TOKEN) [[ "$v" =~ ^glpat- || ${#v} -ge 20 ]] || echo "doesn't look like a GitLab token (glpat-…)" ;;
    JIRA_API_TOKEN) [[ "$v" == ATATT* && ${#v} -lt 180 ]] && echo "is ${#v} characters; Atlassian tokens are ~192 (truncated?)" ;;
  esac
  return 0
}

check_secret() {  # $1 ws, $2 var, $3 value -> ok/bad lines
  local ws="$1" var="$2" v="$3" problem code body
  problem="$(check_shape "$var" "$v")"
  [[ -n "$problem" ]] && { bad "$var $problem"; return; }
  body="$(mktemp)"
  case "$var" in
    GH_TOKEN)
      code=$(curl -s -o "$body" -w '%{http_code}' -H "Authorization: Bearer $v" https://api.github.com/user)
      if [[ "$code" != 200 ]]; then bad "GH_TOKEN rejected by GitHub (HTTP $code): expired, revoked or wrong value"
      else
        ok "GH_TOKEN valid for GitHub user $(jq -r .login "$body")"
        for r in $(ws_repos "$ws"); do
          local u; u="$(git -C "$r" remote get-url origin 2>/dev/null || true)"; u="$(https_url "$u")"
          [[ "$(url_host "$u")" == github.com ]] || continue
          code=$(curl -s -o "$body" -w '%{http_code}' -H "Authorization: Bearer $v" "https://api.github.com/repos/$(url_path "$u")")
          if [[ "$code" == 200 ]]; then
            [[ "$(jq -r '.permissions.push // false' "$body")" == true ]] && ok "  can push to $(url_path "$u")" || warn "  read-only on $(url_path "$u") (needs Contents: read/write)"
          else bad "  no access to $(url_path "$u") (HTTP $code): add the repo to the token"; fi
        done
      fi ;;
    GITLAB_TOKEN)
      local host; host="$(gitlab_host_for "$ws")"
      code=$(curl -s -o "$body" -w '%{http_code}' -H "PRIVATE-TOKEN: $v" "https://$host/api/v4/user")
      if [[ "$code" != 200 ]]; then bad "GITLAB_TOKEN rejected by $host (HTTP $code): expired, revoked, wrong host or value"
      else
        ok "GITLAB_TOKEN valid on $host for user $(jq -r .username "$body")"
        for r in $(ws_repos "$ws"); do
          local u; u="$(git -C "$r" remote get-url origin 2>/dev/null || true)"; u="$(https_url "$u")"
          [[ "$(url_host "$u")" == "$host" ]] || continue
          code=$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $v" "https://$host/api/v4/projects/$(urlencode "$(url_path "$u")")")
          [[ "$code" == 200 ]] && ok "  can access $(url_path "$u")" || bad "  no access to $(url_path "$u") (HTTP $code)"
        done
      fi ;;
    JIRA_API_TOKEN)
      local user url; user="$(keychain "$ws" JIRA_USERNAME)"
      url="$(jq -r '[.. | .JIRA_URL? // empty | select(startswith("http"))][0] // empty' "$(ws_cfg "$ws")/mcp.json" 2>/dev/null || true)"
      if [[ -z "$user" || -z "$url" ]]; then ok "JIRA_API_TOKEN stored (can't test: needs JIRA_USERNAME and JIRA_URL in mcp.json)"
      else
        code=$(curl -s -o "$body" -w '%{http_code}' -u "$user:$v" "$url/rest/api/3/myself")
        [[ "$code" == 200 ]] && ok "JIRA_API_TOKEN valid on $url for $(jq -r .displayName "$body")" \
          || bad "JIRA_API_TOKEN rejected by $url (HTTP $code): token must belong to the JIRA_USERNAME account"
      fi ;;
    *) ok "$var stored" ;;
  esac
  rm -f "$body"
}

# --- doctor ---------------------------------------------------------------------------------------
doctor_system() {
  echo "System"
  if docker info >/dev/null 2>&1; then ok "Docker running"; else bad "Docker isn't running"; hint "install/start Docker Desktop: https://www.docker.com/products/docker-desktop/"; fi
  command -v security >/dev/null && ok "macOS Keychain available" || bad "macOS 'security' tool not found (claude-box needs macOS)"
  for t in jq curl git; do command -v "$t" >/dev/null && ok "$t" || { bad "$t not found"; hint "brew install $t"; }; done
  local on_path installed=0; on_path="$(command -v claude-box 2>/dev/null || true)"
  [[ "$BOX_DIR" == */claude_box/data ]] && installed=1   # running from `uv tool install`, not a clone
  if [[ -n "$on_path" ]]; then ok "claude-box on your PATH ($on_path)"
  elif [[ $installed -eq 1 ]]; then warn "claude-box isn't on your PATH; add uv's tool folder with:"; hint "uv tool update-shell"
  else warn "claude-box isn't on your PATH (optional); to add it, run:"; hint "ln -s $BOX_DIR/bin/claude-box ~/.local/bin/claude-box"; fi
  if command -v uv >/dev/null; then ok "uv $(uv --version | awk '{print $2}')"
  else warn "uv not found (needed only for the MCP server)"; hint "brew install uv"; fi
  if [[ -n "${CLAUDE_BOX_VIA_MCP:-}" ]]; then ok "running through the claude-box MCP server"
  elif command -v claude >/dev/null; then
    if claude mcp get claude-box >/dev/null 2>&1; then ok "claude-box MCP server registered in Claude Code"
    else
      warn "claude-box MCP server not registered (optional: lets Claude set up boxes for you)"
      hint "It can clone repos into $WS_ROOT, write .claude-box/ config, store secrets from your"
      hint "clipboard in the Keychain (claude-box/* items only) and run these checks. It never sees"
      hint "or returns secret values. To add it, run yourself:"
      if command -v claude-box-mcp >/dev/null; then hint "claude mcp add claude-box -- claude-box-mcp"
      else hint "claude mcp add claude-box -- uv run --script $BOX_DIR/mcp/server.py"; fi
    fi
  fi
  local hn he; hn="$(git config --global user.name 2>/dev/null || true)"; he="$(git config --global user.email 2>/dev/null || true)"
  [[ -n "$he" ]] && ok "git identity on this Mac: ${hn:-<no name>} <$he> (boxes don't use it; each workspace sets its own)"
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 && ok "base image present" || warn "base image not pulled yet (happens on first start)"
}

# A detached box (if any) that keeps exiting is a problem; none at all is fine.
doctor_detached() {
  local status restarts code _
  read -r status restarts code _ <<< "$(detached_state "$1")"
  [[ -z "$status" ]] && return 0
  if [[ "$status" == running && "$restarts" == 0 ]]; then
    ok "detached box running"
  else
    bad "detached box keeps exiting ($status, restarted $restarts time(s), last status $code)"
    hint "its script must stay in the foreground; see: claude-box status $1"
  fi
}

doctor_workspace() {
  local ws="$1" d="$WS_ROOT/$1" cfg; cfg="$(ws_cfg "$1")"
  echo; echo "Workspace $ws"
  [[ -d "$d" ]] || { bad "$d doesn't exist"; hint "create it: claude-box init $ws <repo-url>"; return; }
  [[ -d "$cfg" ]] && ok ".claude-box/ present" || warn "no .claude-box/: runs on the plain base image without secrets"
  local p c k g; p="$(cfg_value "$ws" profile)"; c="$(cfg_value "$ws" connectors)"; k="$(cfg_value "$ws" docker)"; g="$(cfg_value "$ws" gcloud)"
  ok "profile ${p:-private} · connectors ${c:-off} · docker ${k:-off} · gcloud ${g:-off}"
  if [[ "$g" == on ]]; then
    # The login lives in the workspace's gcloud volume; read the account without starting gcloud.
    local acct=""
    if docker volume inspect "claude-box-gcloud-$ws" >/dev/null 2>&1; then
      acct="$(docker run --rm -v "claude-box-gcloud-$ws:/gcloud:ro" alpine:3.20 sh -c \
        'f=/gcloud/configurations/config_default; [ -f "$f" ] && sed -n "s/^account *= *//p" "$f" | head -1' 2>/dev/null || true)"
    fi
    if [[ -n "$acct" ]]; then ok "gcloud logged in as $acct"
    else warn "gcloud isn't logged in for this workspace yet"; hint "claude-box gcloud-login $ws"; fi
  fi

  local repos; repos="$(ws_repos "$ws")"
  [[ -z "$repos" ]] && warn "no git repo found in the workspace"
  for r in $repos; do
    local u name; u="$(git -C "$r" remote get-url origin 2>/dev/null || true)"; name="${r#"$WS_ROOT/"}"
    if [[ -z "$u" ]]; then warn "$name: no origin remote"
    elif [[ "$u" == https://* ]]; then ok "$name: HTTPS remote"
    else bad "$name: remote isn't HTTPS (the box has no SSH keys)"; hint "git -C $r remote set-url origin $(https_url "$u")"; fi
    if [[ "$r" == "$d" && -d "$cfg" ]]; then
      if git -C "$r" ls-files --error-unmatch .claude-box >/dev/null 2>&1 || git -C "$r" ls-files .claude-box | grep -q .; then ok "$name: .claude-box/ committed in the repo"
      elif git -C "$r" check-ignore -q .claude-box/; then ok "$name: .claude-box/ kept out of git"
      else warn "$name: .claude-box/ is untracked; commit it, or keep it local with:"; hint "echo .claude-box/ >> $r/.git/info/exclude"; fi
    fi
  done
  if [[ ! -d "$d/.git" && -n "$repos" ]]; then   # multi-repo: CLAUDE.md should name every repo folder
    local missing folders="" origins=""; missing="$(claude_md_missing "$ws")"
    for r in $missing; do folders="$folders${folders:+, }$(basename "$r")/"; origins="$origins $(repo_origin "$r")"; done
    if [[ ! -f "$d/CLAUDE.md" ]]; then warn "no CLAUDE.md telling Claude which folder holds which repo"
    elif [[ -n "$missing" ]]; then warn "CLAUDE.md doesn't list $folders"
    else ok "CLAUDE.md lists every repo"; fi
    [[ -n "$missing" ]] && hint "add them (keeps what's written there): claude-box init $ws$origins"
  fi

  doctor_git_identity "$ws"

  local names; names="$(secret_names "$ws")"
  for var in $names; do
    local v; v="$(keychain "$ws" "$var")"
    if [[ -z "$v" ]]; then bad "$var missing"; hint "copy it, then: claude-box secret $ws $var"
    else check_secret "$ws" "$var" "$v"; fi
    v=""
  done
  if [[ -f "$cfg/mcp.json" ]]; then jq -e . "$cfg/mcp.json" >/dev/null 2>&1 && ok "mcp.json valid" || bad "mcp.json isn't valid JSON"; fi
  if [[ -f "$cfg/Dockerfile" ]]; then
    if docker build -q -t "claude-box-project-$(echo "$ws" | tr '[:upper:]' '[:lower:]')" "$cfg" >/dev/null 2>&1; then ok "project image builds"
    else bad "project image doesn't build"; hint "docker build $cfg"; fi
  fi
}

cmd_doctor() {
  doctor_system
  if [[ -n "${1:-}" ]]; then need_ws "$1"; doctor_workspace "$1"; doctor_detached "$1"; fi
  echo
  if [[ $DOCTOR_PROBLEMS -eq 0 ]]; then echo "No problems found."; else echo "$DOCTOR_PROBLEMS problem(s) found; see the hints above."; fi
  [[ $DOCTOR_PROBLEMS -eq 0 ]]
}

# --- secret: clipboard -> Keychain, validated, clipboard cleared ----------------------------------
cmd_secret() {
  local ws="${1:-}" var="${2:-}"; need_ws "$ws"
  [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "usage: claude-box secret <workspace> <VAR>  (reads the value from the clipboard)" >&2; exit 2; }
  [[ -d "$WS_ROOT/$ws" ]] || { echo "workspace $ws doesn't exist" >&2; exit 2; }
  local v problem; v="$(pbpaste)"
  problem="$(check_shape "$var" "$v")"
  if [[ -n "$problem" ]]; then v=""; echo "Not stored: the clipboard $problem." >&2; exit 1; fi
  security add-generic-password -U -s "claude-box/$ws/$var" -a "$USER" -w "$v"
  pbcopy < /dev/null
  mkdir -p "$(ws_cfg "$ws")"
  secret_names "$ws" | grep -qx "$var" || echo "$var" >> "$(ws_cfg "$ws")/secrets.txt"
  echo "Stored $var for $ws (${#v} characters) and cleared the clipboard."
  check_secret "$ws" "$var" "$v"
  v=""
}

# --- commit signing: a dedicated SSH key per workspace --------------------------------------------
# The private key is stored base64 (one line) in the Keychain item claude-box/<ws>/GIT_SIGNING_KEY;
# the public key is kept next to the settings as .claude-box/signing-key.pub (not secret).
ensure_signing_key() {  # $1 ws, $2 email
  local ws="$1" email="$2" cfg tmp; cfg="$(ws_cfg "$ws")"
  [[ -n "$(keychain "$ws" GIT_SIGNING_KEY)" && -f "$cfg/signing-key.pub" ]] && return 0
  tmp="$(mktemp -d)"
  # The private key only touches disk in this temp folder, which is removed whatever happens.
  if ssh-keygen -q -t ed25519 -N "" -C "$email" -f "$tmp/key" </dev/null \
     && security add-generic-password -U -s "claude-box/$ws/GIT_SIGNING_KEY" -a "${USER:-claude-box}" \
          -w "$(base64 < "$tmp/key" | tr -d '\n')" \
     && cp "$tmp/key.pub" "$cfg/signing-key.pub"; then
    rm -rf "$tmp"
  else
    rm -rf "$tmp"; echo "Couldn't make or store the signing key." >&2; exit 1
  fi
  echo "Made a new SSH signing key for $ws (private key in the Keychain, only used inside this box)."
}

# Where to register the public key, per host of the workspace's repos.
signing_key_instructions() {
  local ws="$1" pub hosts="" r u h; pub="$(ws_cfg "$ws")/signing-key.pub"
  for r in $(ws_repos "$ws"); do
    u="$(https_url "$(git -C "$r" remote get-url origin 2>/dev/null || true)")"; h="$(url_host "$u")"
    [[ -n "$h" && " $hosts " != *" $h "* ]] && hosts="$hosts $h"
  done
  [[ -z "$hosts" ]] && hosts=" github.com $(gitlab_host_for "$ws")"
  pbcopy < "$pub" 2>/dev/null && echo "Public key (copied to the clipboard):" || echo "Public key:"
  echo "  $(cat "$pub")"
  echo "Add it to your account as a signing key:"
  for h in $hosts; do
    case "$h" in
      github.com) echo "  GitHub: https://github.com/settings/ssh/new  (Key type: Signing Key)" ;;
      *)          echo "  GitLab: https://$h/-/user_settings/ssh_keys  (Usage type: Signing)" ;;
    esac
  done
  echo "Commits then show as Verified when git-email ($(cfg_line "$ws" git-email)) is a verified email there."
}

# doctor: is the key registered and the email verified on the host? Needs a token that may read
# them (GitLab: read_user or api; GitHub fine-grained: "SSH signing keys" + "Email addresses" read).
check_signing_on_host() {  # $1 ws, $2 host, $3 key "type base64", $4 email
  local ws="$1" host="$2" key="$3" email="$4" tok code body; body="$(mktemp)"
  if [[ "$host" == github.com ]]; then
    tok="$(keychain "$ws" GH_TOKEN)"
    [[ -z "$tok" ]] && { warn "can't check signing on GitHub without GH_TOKEN"; rm -f "$body"; return; }
    code=$(curl -s -o "$body" -w '%{http_code}' -H "Authorization: Bearer $tok" https://api.github.com/user/ssh_signing_keys)
    if [[ "$code" != 200 ]]; then warn "can't check GitHub signing keys (HTTP $code; token lacks \"SSH signing keys\" read)"
    elif jq -e --arg k "$key" 'any(.[]; (.key | split(" ")[0:2] | join(" ")) == $k)' "$body" >/dev/null; then ok "signing key registered on GitHub"
    else bad "signing key not registered on GitHub"; hint "claude-box set $ws signing on  (prints the key and where to add it)"; fi
    code=$(curl -s -o "$body" -w '%{http_code}' -H "Authorization: Bearer $tok" https://api.github.com/user/emails)
    if [[ "$code" != 200 ]]; then warn "can't check GitHub emails (HTTP $code; token lacks \"Email addresses\" read)"
    elif jq -e --arg e "$email" 'any(.[]; (.email | ascii_downcase) == ($e | ascii_downcase) and .verified)' "$body" >/dev/null; then ok "$email verified on GitHub"
    else bad "$email isn't a verified email on your GitHub account (commits won't show as Verified)"; fi
  else
    tok="$(keychain "$ws" GITLAB_TOKEN)"
    [[ -z "$tok" ]] && { warn "can't check signing on $host without GITLAB_TOKEN"; rm -f "$body"; return; }
    code=$(curl -s -o "$body" -w '%{http_code}' -H "PRIVATE-TOKEN: $tok" "https://$host/api/v4/user/keys")
    if [[ "$code" != 200 ]]; then warn "can't check $host SSH keys (HTTP $code; token needs read_user or api)"
    elif jq -e --arg k "$key" 'any(.[]; (.key | split(" ")[0:2] | join(" ")) == $k and ((.usage_type // "auth_and_signing") | test("signing")))' "$body" >/dev/null; then ok "signing key registered on $host"
    else bad "signing key not registered on $host for signing"; hint "claude-box set $ws signing on  (prints the key and where to add it)"; fi
    code=$(curl -s -o "$body" -w '%{http_code}' -H "PRIVATE-TOKEN: $tok" "https://$host/api/v4/user")
    local primary=""; [[ "$code" == 200 ]] && primary="$(jq -r '.email // empty' "$body")"
    code=$(curl -s -o "$body" -w '%{http_code}' -H "PRIVATE-TOKEN: $tok" "https://$host/api/v4/user/emails")
    if [[ "$code" != 200 ]]; then warn "can't check $host emails (HTTP $code; token needs read_user or api)"
    elif [[ "$(echo "$primary" | tr '[:upper:]' '[:lower:]')" == "$(echo "$email" | tr '[:upper:]' '[:lower:]')" ]] \
      || jq -e --arg e "$email" 'any(.[]; (.email | ascii_downcase) == ($e | ascii_downcase) and .confirmed_at != null)' "$body" >/dev/null; then ok "$email verified on $host"
    else bad "$email isn't a verified email on your $host account (commits won't show as Verified)"; fi
  fi
  rm -f "$body"
}

doctor_git_identity() {
  local ws="$1" cfg name email; cfg="$(ws_cfg "$1")"; name="$(cfg_line "$ws" git-name)"; email="$(cfg_line "$ws" git-email)"
  if [[ -n "$email" ]]; then ok "git identity ${name:-<no name>} <$email>"
  else warn "no git identity: commits in the box fail"; hint "claude-box set $ws git-name \"Your Name\"; claude-box set $ws git-email you@example.com"; fi
  [[ "$(cfg_value "$ws" signing)" == on ]] || return 0
  if [[ -z "$(keychain "$ws" GIT_SIGNING_KEY)" || ! -f "$cfg/signing-key.pub" ]]; then
    bad "signing is on, but the signing key is missing"; hint "claude-box set $ws signing on"; return
  fi
  ok "commits and tags are signed (SSH key $(awk '{print $1}' "$cfg/signing-key.pub"))"
  local key hosts="" r u h; key="$(awk '{print $1" "$2}' "$cfg/signing-key.pub")"
  for r in $(ws_repos "$ws"); do
    u="$(https_url "$(git -C "$r" remote get-url origin 2>/dev/null || true)")"; h="$(url_host "$u")"
    [[ -n "$h" && " $hosts " != *" $h "* ]] && hosts="$hosts $h"
  done
  for h in $hosts; do
    case "$h" in github.com|"$(gitlab_host_for "$ws")") check_signing_on_host "$ws" "$h" "$key" "$email" ;; esac
  done
}

# --- set: one setting per file in .claude-box/ ----------------------------------------------------
cmd_set() {
  local ws="${1:-}" key="${2:-}" val="${3:-}"; need_ws "$ws"
  [[ -d "$WS_ROOT/$ws" ]] || { echo "workspace $ws doesn't exist" >&2; exit 2; }
  local cfg; cfg="$(ws_cfg "$ws")"; mkdir -p "$cfg"
  case "$key" in
    profile) [[ "$val" == own ]] && val="$(echo "$ws" | tr -c 'A-Za-z0-9_-\n' '-')"   # its own profile, named after the workspace
             [[ "$val" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "profile must be a plain name (or 'own')" >&2; exit 2; }
             if [[ "$val" == private ]]; then rm -f "$cfg/profile"; else echo "$val" > "$cfg/profile"; fi ;;
    connectors|docker|gcloud)
             case "$val" in on) echo on > "$cfg/$key" ;; off) rm -f "$cfg/$key" ;; *) echo "$key must be on or off" >&2; exit 2 ;; esac ;;
    git-name) val="${*:3}"   # unquoted "Jane Doe" arrives as two arguments
             [[ -n "$val" ]] || { echo "usage: claude-box set <workspace> git-name \"Jane Doe\"" >&2; exit 2; }
             echo "$val" > "$cfg/git-name" ;;
    git-email) [[ "$val" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "git-email must be an email address" >&2; exit 2; }
             echo "$val" > "$cfg/git-email" ;;
    signing) case "$val" in
               on)  local email; email="$(cfg_line "$ws" git-email)"
                    [[ -n "$email" ]] || { echo "set the email first (it must be verified on your account): claude-box set $ws git-email you@example.com" >&2; exit 2; }
                    ensure_signing_key "$ws" "$email"
                    echo on > "$cfg/signing" ;;
               off) rm -f "$cfg/signing" ;;
               *)   echo "signing must be on or off" >&2; exit 2 ;;
             esac ;;
    color)   [[ "$val" =~ ^#[0-9A-Fa-f]{6}$ ]] || { echo "color must be #RRGGBB" >&2; exit 2; }
             echo "$val" > "$cfg/color" ;;
    env)     [[ "$val" =~ ^[A-Z_][A-Z0-9_]*=.*$ ]] || { echo "env must be KEY=value" >&2; exit 2; }
             local k="${val%%=*}"; touch "$cfg/env"
             grep -v "^$k=" "$cfg/env" > "$cfg/env.tmp" || true; echo "$val" >> "$cfg/env.tmp"; mv "$cfg/env.tmp" "$cfg/env" ;;
    *) echo "usage: claude-box set <workspace> profile|connectors|docker|gcloud|git-name|git-email|signing|color|env <value>" >&2; exit 2 ;;
  esac
  echo "$ws: $key = $val"
  [[ "$key" == signing && "$val" == on ]] && signing_key_instructions "$ws"
  [[ "$key" == gcloud && "$val" == on ]] && echo "Log gcloud in for this workspace with: claude-box gcloud-login $ws"
  return 0
}

# --- list -----------------------------------------------------------------------------------------
cmd_list() {
  [[ -d "$WS_ROOT" ]] || { echo "no workspaces yet ($WS_ROOT)"; return; }
  printf '%-20s %-10s %-10s %-7s %-7s %-8s %s\n' WORKSPACE PROFILE CONNECTORS DOCKER GCLOUD SECRETS DETACHED
  for d in "$WS_ROOT"/*/; do
    local ws total=0 have=0 p c k g s; ws="$(basename "$d")"
    for var in $(secret_names "$ws"); do total=$((total + 1)); [[ -n "$(keychain "$ws" "$var")" ]] && have=$((have + 1)); done
    p="$(cfg_value "$ws" profile)"; c="$(cfg_value "$ws" connectors)"; k="$(cfg_value "$ws" docker)"; g="$(cfg_value "$ws" gcloud)"
    s="$(detached_state "$ws" | cut -d' ' -f1)"
    printf '%-20s %-10s %-10s %-7s %-7s %-8s %s\n' "$ws" "${p:-private}" "${c:-off}" "${k:-off}" "${g:-off}" "$have/$total" "${s:--}"
  done
}

# --- detached boxes: status, logs, stop -----------------------------------------------------------
detached_name()  { echo "claude-box-detached-$1"; }
# "<status> <restarts> <exit code> <started at>", or nothing when there is no detached box.
detached_state() {
  docker inspect -f '{{.State.Status}} {{.RestartCount}} {{.State.ExitCode}} {{.State.StartedAt}}' \
    "$(detached_name "$1")" 2>/dev/null || true
}
need_detached() {
  need_ws "${1:-}"
  [[ -n "$(detached_state "$1")" ]] || {
    echo "$1 has no detached box; start one with: claude-box $1 --detached '<script> [args]'" >&2; exit 1; }
}

cmd_status() {
  local ws="${1:-}"; need_detached "$ws"
  local name status restarts code started cmd exit_cmd
  name="$(detached_name "$ws")"
  read -r status restarts code started <<< "$(detached_state "$ws")"
  cmd="$(docker inspect -f '{{join .Config.Cmd " "}}' "$name" 2>/dev/null)"
  exit_cmd="$(docker inspect -f '{{index .Config.Labels "claude-box.exit"}}' "$name" 2>/dev/null || true)"
  echo "$ws: $status since ${started%.*}, restarted $restarts time(s)"
  echo "  runs:    ${cmd##*"/workspace/$ws/"}"
  [[ -n "$exit_cmd" ]] && echo "  on stop: ${exit_cmd#"/workspace/$ws/"}"
  if [[ "$status" != running || "$restarts" != 0 ]]; then
    echo "  ! the script exited (last status $code). A detached script must stay in the foreground;"
    echo "    when it returns, Docker starts it again. See its output below or with: claude-box logs $ws"
  fi
  echo "--- last output"
  docker logs --tail 20 "$name" 2>&1 | sed 's/^/  /'
  [[ "$status" == running && "$restarts" == 0 ]]
}

cmd_logs() {
  local ws="${1:-}"; need_detached "$ws"
  echo "[claude-box] following $ws (Ctrl+C stops following; the box keeps running)" >&2
  exec docker logs -f --tail 100 "$(detached_name "$ws")"
}

# The --exit script (if any) runs in the box first; its words were checked at start. Then the
# main script gets SIGTERM and 30s to exit, and the box is removed (and its private Docker daemon,
# when nothing else uses it, as when a box exits).
cmd_stop() {
  local ws="${1:-}"; need_detached "$ws"
  local name exit_cmd words; name="$(detached_name "$ws")"
  exit_cmd="$(docker inspect -f '{{index .Config.Labels "claude-box.exit"}}' "$name" 2>/dev/null || true)"
  if [[ -n "$exit_cmd" && "$(docker inspect -f '{{.State.Running}}' "$name")" == "true" ]]; then
    read -ra words <<< "$exit_cmd"
    echo "[claude-box] running ${exit_cmd#"/workspace/$ws/"}" >&2
    docker exec "$name" timeout 120 "${words[@]}" \
      || echo "[claude-box] exit script failed (status $?); stopping anyway" >&2
  fi
  docker stop -t 30 "$name" >/dev/null && docker rm "$name" >/dev/null
  if [[ -z "$(docker ps -q --filter "label=claude-box.uses-dind=claude-box-dind-$ws")" ]]; then
    docker rm -f "claude-box-dind-$ws" >/dev/null 2>&1 || true
  fi
  echo "stopped $ws"
}

# --- trust: accept Claude's folder trust prompt for a workspace and its repos, in its profile ------
# Trust is kept per folder in the profile's ~/.claude.json, so each repo folder (and each profile)
# would otherwise prompt once. This is an explicit command: trusting lets a repo's .claude/
# settings and hooks run inside the box.
cmd_trust() {
  local ws="${1:-}"; need_ws "$ws"
  local d="$WS_ROOT/$ws"; [[ -d "$d" ]] || { echo "workspace $ws doesn't exist" >&2; exit 2; }
  local p; p="$(cfg_value "$ws" profile)"; p="${p:-private}"
  local paths=("/workspace/$ws") r
  for r in $(ws_repos "$ws"); do [[ "$r" != "$d" ]] && paths+=("/workspace/$ws/${r#"$d/"}"); done
  profile_trust "$p" "${paths[@]}" || { echo "Couldn't update the trust settings of profile $p." >&2; exit 1; }
  echo "Trusted in profile $p:"; printf '  %s\n' "${paths[@]}"
}

# Mark box paths as trusted in profile $1's ~/.claude.json. Takes the lock Claude Code itself takes
# for that file (~/.claude.json.lock, a mkdir lock that is stale after 10s) and replaces the file
# atomically. Claude re-reads the file under that lock before every save, so this is safe while
# boxes on the profile are running. With --if-trusted, only when the first path is trusted already;
# returns 3 when it isn't or the profile doesn't exist yet.
profile_trust() {
  local p="$1"; shift
  local cond=0; [[ "${1:-}" == --if-trusted ]] && { cond=1; shift; }
  if [[ $cond -eq 1 ]] && ! docker volume inspect "claude-box-home-$p" >/dev/null 2>&1; then return 3; fi
  local img="$BASE_IMAGE"; docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
  docker run --rm -v "claude-box-home-$p:/home/agent" "$img" bash -c '
    cond=$1; shift
    f=/home/agent/.claude.json; l=$f.lock
    for _ in $(seq 1 150); do
      mkdir "$l" 2>/dev/null && break
      [ $(( $(date +%s) - $(stat -c %Y "$l" 2>/dev/null || date +%s) )) -gt 10 ] && rmdir "$l" 2>/dev/null
      sleep 0.1
    done
    [ -d "$l" ] || exit 4
    trap "rmdir $l" EXIT
    [ -s "$f" ] || echo "{}" > "$f"
    if [ "$cond" = 1 ] && [ "$(jq -r --arg p "$1" ".projects[\$p].hasTrustDialogAccepted // false" "$f")" != true ]; then exit 3; fi
    jq --args "reduce \$ARGS.positional[] as \$p (.; .projects[\$p].hasTrustDialogAccepted = true)" "$@" < "$f" > "$f.claude-box.tmp" \
      && mv "$f.claude-box.tmp" "$f"
  ' _ "$cond" "$@"
}

# --- profiles: which Claude homes exist and who is logged in --------------------------------------
# Shows only the organization and the email domain of a login, never the full address or tokens.
cmd_profiles() {
  local vols; vols="$(docker volume ls --format '{{.Name}}' 2>/dev/null | sed -n 's/^claude-box-home-//p')"
  if [[ -z "$vols" ]]; then
    echo "No profiles yet. A profile is created on the first start of a workspace that uses it;"
    echo "that start asks you to log in with the Claude account you want for it."
    return
  fi
  local img="$BASE_IMAGE"; docker image inspect "$img" >/dev/null 2>&1 || img="alpine:3.20"
  printf '%-14s %-44s %s\n' PROFILE LOGIN WORKSPACES
  for p in $vols; do
    local login used=""
    login="$(docker run --rm -v "claude-box-home-$p:/home/agent:ro" "$img" sh -c \
      'f=/home/agent/.claude.json; [ -f "$f" ] && command -v jq >/dev/null && jq -r ".oauthAccount // empty | \"\(.organizationName // \"?\") (@\(.emailAddress // \"?\" | split(\"@\")[1] // \"?\"))\"" "$f"' 2>/dev/null || true)"
    if [[ -d "$WS_ROOT" ]]; then
      for d in "$WS_ROOT"/*/; do
        local ws wp; ws="$(basename "$d")"; wp="$(cfg_value "$ws" profile)"
        [[ "${wp:-private}" == "$p" ]] && used="$used${used:+, }$ws"
      done
    fi
    printf '%-14s %-44s %s\n' "$p" "${login:-not logged in yet}" "${used:--}"
  done
}


# --- init: a workspace with one or more repos, cloned over HTTPS, plus .claude-box/ ---------------
# One repo: the workspace is that repo (.claude-box/ kept out of its git). Several repos: the
# workspace is a plain folder with each repo in a subfolder and .claude-box/ + CLAUDE.md on top.
# Safe to run again: existing clones and config are kept, missing repos are cloned or added.
looks_like_url() { [[ "$1" == *://* || "$1" == git@*:* || "$1" =~ ^[A-Za-z0-9.-]+\.[a-z]{2,}/.+ ]]; }
host_var() { case "$1" in github.com) echo GH_TOKEN ;; *gitlab*) echo GITLAB_TOKEN ;; esac; }

# --- the multi-repo CLAUDE.md: tells Claude which folder holds which repo ------------------------
repo_origin() { https_url "$(git -C "$1" remote get-url origin 2>/dev/null || true)"; }
claude_md_row() {  # $1 repo dir
  local u; u="$(repo_origin "$1")"
  echo "| \`$(basename "$1")/\` | ${u:+$(url_host "$u")/$(url_path "$u")} |"
}
# Repo folders of a multi-repo workspace that its CLAUDE.md doesn't mention (all, if it has none).
claude_md_missing() {
  local d="$WS_ROOT/$1" r
  [[ -d "$d/.git" ]] && return 0
  for r in $(ws_repos "$1"); do grep -qF "$(basename "$r")/" "$d/CLAUDE.md" 2>/dev/null || echo "$r"; done
}
# Write the CLAUDE.md, or add a row for each repo it doesn't list yet. What the user wrote is kept.
sync_claude_md() {
  local ws="$1" f="$WS_ROOT/$1/CLAUDE.md" r missing rows=""
  missing="$(claude_md_missing "$ws")"; [[ -n "$missing" ]] || return 0
  for r in $missing; do rows="$rows$(claude_md_row "$r")"$'\n'; done
  if [[ ! -f "$f" ]]; then
    {
      echo "# Workspace: $ws"
      echo
      echo "This workspace holds several repositories. Each folder is its own git repo: branch,"
      echo "commit and open PRs/MRs per repo (gh for GitHub, glab for GitLab)."
      echo
      echo "| Folder | Repository |"
      echo "|---|---|"
      printf '%s' "$rows"
      echo
      echo "Describe here how the repos relate and anything that spans them."
    } > "$f"
    return
  fi
  if grep -q '^| *Folder *| *Repository *|' "$f"; then   # add the rows at the end of the repo table
    CB_ROWS="$rows" awk '
      BEGIN { rows = ENVIRON["CB_ROWS"] }
      intable && !/^\|/ { printf "%s", rows; intable = 0; done = 1 }
      { print }
      !done && /^\| *Folder *\| *Repository *\|/ { intable = 1 }
      END { if (intable) printf "%s", rows }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    printf '\n## Repositories\n\n| Folder | Repository |\n|---|---|\n%s' "$rows" >> "$f"
  fi
  for r in $missing; do echo "Added $(basename "$r")/ to $f"; done
}

# git against a remote: only the workspace token (never the Mac's credential helpers) and never a
# prompt, so a missing token fails fast instead of waiting for input on the user's terminal.
git_remote() {  # $1 dir, $2 user, $3 token, rest: git args
  local dir="$1" user="$2" tok="$3"; shift 3
  CB_USER="$user" CB_TOKEN="$tok" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
    git -C "$dir" -c credential.helper= \
      -c 'credential.helper=!f() { test "$1" = get && [ -n "$CB_TOKEN" ] && printf "username=%s\npassword=%s\n" "$CB_USER" "$CB_TOKEN"; }; f' \
      "$@" </dev/null
}

clone_into() {  # $1 dir, $2 https url, $3 workspace
  local dir="$1" url="$2" ws="$3" var tok="" user=x-access-token head
  var="$(host_var "$(url_host "$url")")"; [[ "$var" == GITLAB_TOKEN ]] && user=oauth2
  [[ -n "$var" ]] && tok="$(keychain "$ws" "$var")"
  mkdir -p "$dir"; git -C "$dir" init -q
  git -C "$dir" remote add origin "$url" 2>/dev/null || git -C "$dir" remote set-url origin "$url"
  if git_remote "$dir" "$user" "$tok" fetch -q origin 2>/dev/null; then
    git_remote "$dir" "$user" "$tok" remote set-head origin -a >/dev/null 2>&1 || true
    head="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ -z "$head" ]]; then  # default branch unknown: main, master, or the first remote branch
      for head in origin/main origin/master $(git -C "$dir" for-each-ref --format='%(refname:short)' refs/remotes/origin | head -1); do
        git -C "$dir" rev-parse -q --verify "$head" >/dev/null && break
      done
    fi
    git -C "$dir" checkout -q -B "${head#origin/}" "$head"
  else
    rm -rf "$dir/.git"; rmdir "$dir" 2>/dev/null || true
    return 1
  fi
}

cmd_init() {
  local ws="" urls=() a named=0 own=0
  for a in "$@"; do
    if [[ "$a" == --own-profile ]]; then own=1
    elif looks_like_url "$a"; then urls+=("$(https_url "$a")")
    elif [[ -z "$ws" ]]; then ws="$a"
    else echo "usage: claude-box init [--own-profile] [workspace] <repo-url>..." >&2; exit 2; fi
  done
  [[ ${#urls[@]} -gt 0 ]] || { echo "usage: claude-box init [workspace] <repo-url>...   (several repos = one workspace)" >&2; exit 2; }
  local repo1; repo1="$(basename "$(url_path "${urls[0]}")")"
  if [[ -z "$ws" ]]; then
    [[ ${#urls[@]} -eq 1 ]] || { echo "name the workspace when it holds several repos: claude-box init <name> <url> <url>..." >&2; exit 2; }
    ws="$repo1"
  else
    named=1
  fi
  need_ws "$ws"
  local d="$WS_ROOT/$ws" cfg; cfg="$(ws_cfg "$ws")"

  # Layout. A repo's folder is always named after the repo. One repo without a custom name: the
  # workspace is that repo. Several repos, a custom name, or an existing multi-repo workspace: a
  # folder per repo inside the workspace.
  local multi=0
  if [[ -d "$d/.git" ]]; then
    local top; top="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
    if [[ ${#urls[@]} -gt 1 || "$(https_url "$top")" != "${urls[0]}" ]]; then
      echo "Workspace $ws holds one repo at its top ($top); to work on several repos together," >&2
      echo "create a new workspace with all of them: claude-box init <name> <url> <url>..." >&2
      exit 2
    fi
  elif [[ ${#urls[@]} -gt 1 || ( $named -eq 1 && "$ws" != "$repo1" ) || -n "$(ws_repos "$ws")" || -f "$d/CLAUDE.md" ]]; then
    multi=1
  fi
  mkdir -p "$cfg"

  # One token per host, so private repos can be cloned and later pushed from the box.
  local url host var gl
  for url in "${urls[@]}"; do
    host="$(url_host "$url")"; var="$(host_var "$host")"
    [[ -n "$var" ]] && { secret_names "$ws" | grep -qx "$var" || echo "$var" >> "$cfg/secrets.txt"; }
    if [[ "$var" == GITLAB_TOKEN && "$host" != gitlab.com ]]; then
      gl="$(env_value "$ws" GITLAB_HOST)"
      if [[ -z "$gl" ]]; then cmd_set "$ws" env "GITLAB_HOST=$host" >/dev/null
      elif [[ "${gl#*://}" != "$host" ]]; then echo "Note: $url is on $host, but this workspace's GitLab is $gl (one GitLab host per workspace)."; fi
    fi
  done

  local failed=() added=() clashes=0 dir have
  for url in "${urls[@]}"; do
    if [[ $multi -eq 1 ]]; then dir="$d/$(basename "$(url_path "$url")")"; else dir="$d"; fi
    if [[ -d "$dir/.git" ]]; then
      have="$(https_url "$(git -C "$dir" remote get-url origin 2>/dev/null || true)")"
      if [[ "${have%.git}" != "${url%.git}" ]]; then
        echo "Not cloning $url: folder $dir already holds $have (two repos with the same name)."
        clashes=$((clashes + 1))
      fi
      continue
    fi
    if clone_into "$dir" "$url" "$ws"; then echo "Cloned $(url_path "$url") into $dir"; added+=("/workspace/$ws/${dir#"$d/"}")
    else failed+=("$url"); echo "Couldn't clone $url yet (private repo?)."; fi
  done
  [[ $multi -eq 0 && -d "$d/.git" ]] && { grep -qx '.claude-box/' "$d/.git/info/exclude" 2>/dev/null || echo '.claude-box/' >> "$d/.git/info/exclude"; }

  # A repo added to a workspace the user already trusted gets that trust too, so agents can be sent
  # to its folder right away (also while the box runs). A workspace that isn't trusted stays so.
  if [[ $multi -eq 1 && ${#added[@]} -gt 0 ]]; then
    local p rc=0; p="$(cfg_value "$ws" profile)"; p="${p:-private}"
    profile_trust "$p" --if-trusted "/workspace/$ws" "${added[@]}" >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then echo "Trusted the new repo folder(s) in profile $p, like the rest of workspace $ws."
    elif [[ $rc -ne 3 ]]; then echo "Couldn't trust the new repo folder(s) automatically; to do it: claude-box trust $ws"; fi
  fi

  # Generate a Dockerfile from what the repos use (highest version wins; kept if it exists).
  local repos r go="" pnpm="" v notes=""
  repos="$(ws_repos "$ws")"
  for r in $repos; do
    v="$(sed -n 's/^go \([0-9][0-9.]*\).*/\1/p' "$r/go.mod" 2>/dev/null | head -1 || true)"
    [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && v="$v.0"
    [[ -n "$v" ]] && go="$(printf '%s\n%s\n' "$go" "$v" | sed '/^$/d' | sort -V | tail -1)"
    v="$(jq -r '.packageManager // empty' "$r/package.json" 2>/dev/null | sed -n 's/^pnpm@\([0-9.]*\).*/\1/p' || true)"
    [[ -n "$v" ]] && pnpm="$(printf '%s\n%s\n' "$pnpm" "$v" | sed '/^$/d' | sort -V | tail -1)"
  done
  if [[ ! -f "$cfg/Dockerfile" && ( -n "$go" || -n "$pnpm" ) ]]; then
    {
      echo "# Generated by claude-box init; add whatever else the project needs."
      echo "FROM $BASE_IMAGE"
      echo "USER root"
      echo "RUN apt-get update && apt-get install -y --no-install-recommends make && rm -rf /var/lib/apt/lists/*"
      [[ -n "$go" ]] && echo "RUN curl -fsSL \"https://go.dev/dl/go$go.linux-\$(dpkg --print-architecture).tar.gz\" | tar -C /usr/local -xz"
      [[ -n "$pnpm" ]] && { echo "ENV COREPACK_HOME=/opt/corepack COREPACK_ENABLE_DOWNLOAD_PROMPT=0"
                            echo "RUN corepack enable && corepack prepare pnpm@$pnpm --activate && chmod -R a+rX /opt/corepack"; }
      echo "USER agent"
      [[ -n "$go" ]] && echo 'ENV PATH="/usr/local/go/bin:/home/agent/go/bin:${PATH}"'
    } > "$cfg/Dockerfile"
    notes="Dockerfile with${go:+ Go $go}${pnpm:+ pnpm $pnpm}"
  fi

  # Multi-repo: a CLAUDE.md on top so Claude knows the layout (each repo's own CLAUDE.md still
  # applies when it works in that repo). Repos added later get a row in its table.
  [[ $multi -eq 1 ]] && sync_claude_md "$ws"

  local compose=0 n
  for r in $repos; do
    n="$(git -C "$r" ls-files | grep -ciE '(^|/)(docker-)?compose[^/]*\.ya?ml$' || true)"; compose=$((compose + n))
  done

  echo "Workspace $ws at $d${notes:+ ($notes)}: $(echo "$repos" | grep -c . || true) repo(s) cloned."
  if [[ $own -eq 1 ]]; then
    cmd_set "$ws" profile own >/dev/null
    echo "Own profile: $(cfg_value "$ws" profile) (separate plugins, memory and history; asks for a Claude login on first start)"
  fi
  [[ "$compose" -gt 0 ]] && echo "Found $compose docker compose file(s); to allow Docker in the box: claude-box set $ws docker on"
  for var in $(secret_names "$ws"); do
    [[ -z "$(keychain "$ws" "$var")" ]] && echo "Missing $var (needed to clone private repos and push): copy a token, then: claude-box secret $ws $var"
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Then run this again to clone the rest: claude-box init $ws ${failed[*]}"
    return 1
  fi
  [[ $clashes -gt 0 ]] && return 1
  echo "Check everything with: claude-box doctor $ws"
}

# --- update: install the newest release (git tag) over the installed one -------------------------
REPO_URL="https://github.com/roytouw/claude-box"
latest_tag() { git ls-remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' | head -1 | sed 's|.*refs/tags/||'; }
cmd_update() {
  if [[ "$BOX_DIR" != */claude_box/data ]]; then
    echo "This claude-box runs from a clone ($BOX_DIR); update it with: git -C $BOX_DIR pull"; return
  fi
  local tag; tag="$(latest_tag)"
  [[ -n "$tag" ]] || { echo "Couldn't read the releases from $REPO_URL" >&2; exit 1; }
  uv tool install --force "git+$REPO_URL@$tag"
  echo "claude-box $tag installed."
}
