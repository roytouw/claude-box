# claude-box subcommands: doctor, init, set, secret, list.
# Sourced by bin/claude-box (bash 3.2 compatible: macOS /bin/bash). Secret values are never printed.

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; DOCTOR_PROBLEMS=$((DOCTOR_PROBLEMS + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
hint() { printf '      %s\n' "$*"; }
DOCTOR_PROBLEMS=0

valid_ws()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
need_ws()   { valid_ws "${1:-}" || { echo "workspace must be a plain name, got: ${1:-<none>}" >&2; exit 2; }; }
ws_cfg()    { echo "$WS_ROOT/$1/.claude-box"; }
cfg_value() { local f; f="$(ws_cfg "$1")/$2"; [[ -f "$f" ]] && head -1 "$f" | tr -d '[:space:]' || true; }
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
  local on_path; on_path="$(command -v claude-box 2>/dev/null || true)"
  if [[ -n "$on_path" && "$(readlink -f "$on_path")" == "$BOX_DIR/bin/claude-box" ]]; then ok "claude-box on your PATH"
  else warn "claude-box isn't on your PATH (optional); to add it, run:"; hint "ln -s $BOX_DIR/bin/claude-box ~/.local/bin/claude-box"; fi
  if command -v uv >/dev/null; then ok "uv $(uv --version | awk '{print $2}')"
  else warn "uv not found (needed only for the MCP server)"; hint "brew install uv"; fi
  if command -v claude >/dev/null; then
    if claude mcp get claude-box >/dev/null 2>&1; then ok "claude-box MCP server registered in Claude Code"
    else
      warn "claude-box MCP server not registered (optional: lets Claude set up boxes for you)"
      hint "It can clone repos into $WS_ROOT, write .claude-box/ config, store secrets from your"
      hint "clipboard in the Keychain (claude-box/* items only) and run these checks. It never sees"
      hint "or returns secret values. To add it, run yourself:"
      hint "claude mcp add claude-box -- uv run --script $BOX_DIR/mcp/server.py"
    fi
  fi
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 && ok "base image present" || warn "base image not pulled yet (happens on first start)"
}

doctor_workspace() {
  local ws="$1" d="$WS_ROOT/$1" cfg; cfg="$(ws_cfg "$1")"
  echo; echo "Workspace $ws"
  [[ -d "$d" ]] || { bad "$d doesn't exist"; hint "create it: claude-box init <repo-url> $ws"; return; }
  [[ -d "$cfg" ]] && ok ".claude-box/ present" || warn "no .claude-box/: runs on the plain base image without secrets"
  local p c k; p="$(cfg_value "$ws" profile)"; c="$(cfg_value "$ws" connectors)"; k="$(cfg_value "$ws" docker)"
  ok "profile ${p:-private} · connectors ${c:-off} · docker ${k:-off}"

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
  if [[ -n "${1:-}" ]]; then need_ws "$1"; doctor_workspace "$1"; fi
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

# --- set: one setting per file in .claude-box/ ----------------------------------------------------
cmd_set() {
  local ws="${1:-}" key="${2:-}" val="${3:-}"; need_ws "$ws"
  [[ -d "$WS_ROOT/$ws" ]] || { echo "workspace $ws doesn't exist" >&2; exit 2; }
  local cfg; cfg="$(ws_cfg "$ws")"; mkdir -p "$cfg"
  case "$key" in
    profile) [[ "$val" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "profile must be a plain name" >&2; exit 2; }
             if [[ "$val" == private ]]; then rm -f "$cfg/profile"; else echo "$val" > "$cfg/profile"; fi ;;
    connectors|docker)
             case "$val" in on) echo on > "$cfg/$key" ;; off) rm -f "$cfg/$key" ;; *) echo "$key must be on or off" >&2; exit 2 ;; esac ;;
    color)   [[ "$val" =~ ^#[0-9A-Fa-f]{6}$ ]] || { echo "color must be #RRGGBB" >&2; exit 2; }
             echo "$val" > "$cfg/color" ;;
    env)     [[ "$val" =~ ^[A-Z_][A-Z0-9_]*=.*$ ]] || { echo "env must be KEY=value" >&2; exit 2; }
             local k="${val%%=*}"; touch "$cfg/env"
             grep -v "^$k=" "$cfg/env" > "$cfg/env.tmp" || true; echo "$val" >> "$cfg/env.tmp"; mv "$cfg/env.tmp" "$cfg/env" ;;
    *) echo "usage: claude-box set <workspace> profile|connectors|docker|color|env <value>" >&2; exit 2 ;;
  esac
  echo "$ws: $key = $val"
}

# --- list -----------------------------------------------------------------------------------------
cmd_list() {
  [[ -d "$WS_ROOT" ]] || { echo "no workspaces yet ($WS_ROOT)"; return; }
  printf '%-20s %-10s %-10s %-7s %s\n' WORKSPACE PROFILE CONNECTORS DOCKER SECRETS
  for d in "$WS_ROOT"/*/; do
    local ws total=0 have=0 p c k; ws="$(basename "$d")"
    for var in $(secret_names "$ws"); do total=$((total + 1)); [[ -n "$(keychain "$ws" "$var")" ]] && have=$((have + 1)); done
    p="$(cfg_value "$ws" profile)"; c="$(cfg_value "$ws" connectors)"; k="$(cfg_value "$ws" docker)"
    printf '%-20s %-10s %-10s %-7s %s\n' "$ws" "${p:-private}" "${c:-off}" "${k:-off}" "$have/$total"
  done
}

# --- init: workspace + clone (HTTPS) + generated .claude-box/; safe to run again ------------------
cmd_init() {
  local url="${1:-}" ws="${2:-}"
  [[ -n "$url" ]] || { echo "usage: claude-box init <repo-url> [workspace]" >&2; exit 2; }
  url="$(https_url "$url")"; local host path; host="$(url_host "$url")"; path="$(url_path "$url")"
  [[ "$url" == https://*/* ]] || { echo "can't parse repo url: $1" >&2; exit 2; }
  ws="${ws:-$(basename "$path")}"; need_ws "$ws"
  local d="$WS_ROOT/$ws" cfg; cfg="$(ws_cfg "$ws")"; mkdir -p "$cfg"

  # Token for the host, so private repos can be cloned (and later pushed from the box).
  local var=""
  if [[ "$host" == github.com ]]; then var=GH_TOKEN
  elif [[ "$host" == *gitlab* ]]; then var=GITLAB_TOKEN; [[ "$host" != gitlab.com ]] && cmd_set "$ws" env "GITLAB_HOST=$host" >/dev/null
  fi
  [[ -n "$var" ]] && { secret_names "$ws" | grep -qx "$var" || echo "$var" >> "$cfg/secrets.txt"; }

  if [[ ! -d "$d/.git" ]]; then
    local tok=""; [[ -n "$var" ]] && tok="$(keychain "$ws" "$var")"
    local user=x-access-token; [[ "$var" == GITLAB_TOKEN ]] && user=oauth2
    git -C "$d" init -q
    git -C "$d" remote add origin "$url" 2>/dev/null || git -C "$d" remote set-url origin "$url"
    if CB_USER="$user" CB_TOKEN="$tok" GIT_TERMINAL_PROMPT=0 git -C "$d" \
         -c credential.helper= -c 'credential.helper=!f() { test "$1" = get && [ -n "$CB_TOKEN" ] && printf "username=%s\npassword=%s\n" "$CB_USER" "$CB_TOKEN"; }; f' \
         fetch -q origin 2>/dev/null; then
      git -C "$d" remote set-head origin -a >/dev/null 2>&1 || true
      local head; head="$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
      git -C "$d" checkout -q -B "${head#origin/}" "$head"
      echo "Cloned $path into $d"
    else
      rm -rf "$d/.git"
      echo "Couldn't clone $url yet (private repo?)."
      if [[ -n "$var" ]]; then
        echo "Create a token, copy it, then run:  claude-box secret $ws $var"
        echo "and run this init again:            claude-box init $url $ws"
      fi
      return 1
    fi
  fi
  grep -qx '.claude-box/' "$d/.git/info/exclude" 2>/dev/null || echo '.claude-box/' >> "$d/.git/info/exclude"

  # Generate a Dockerfile from what the repo uses (kept if it already exists).
  local go pnpm notes=""
  go="$(sed -n 's/^go \([0-9][0-9.]*\).*/\1/p' "$d/go.mod" 2>/dev/null | head -1 || true)"
  [[ "$go" =~ ^[0-9]+\.[0-9]+$ ]] && go="$go.0"
  pnpm="$(jq -r '.packageManager // empty' "$d/package.json" 2>/dev/null | sed -n 's/^pnpm@\([0-9.]*\).*/\1/p' || true)"
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
  local compose; compose="$(git -C "$d" ls-files | grep -ciE '(^|/)(docker-)?compose[^/]*\.ya?ml$' || true)"

  echo "Workspace $ws ready at $d${notes:+ ($notes)}."
  [[ "$compose" -gt 0 ]] && echo "Found $compose docker compose file(s); to allow Docker in the box: claude-box set $ws docker on"
  [[ -n "$var" && -z "$(keychain "$ws" "$var")" ]] && echo "To push from the box, store a token: copy it, then: claude-box secret $ws $var"
  echo "Check everything with: claude-box doctor $ws"
}
