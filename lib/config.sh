#!/bin/bash
# config.sh — agentbox Konfigurations-Loader
# Einbinden: . "$CONTROL_DIR/lib/config.sh"

AGENTBOX_CONFIG="${CONTROL_DIR:-$(dirname "$(dirname "$0")")}/config.json"

# cfg_get "key" [default]
# Liest einen einzelnen Wert aus config.json
cfg_get() {
    local key="$1"
    local default="${2:-}"

    if [ ! -f "$AGENTBOX_CONFIG" ]; then
        echo "$default"
        return
    fi

    if command -v python3 &> /dev/null; then
        local val
        val=$(python3 -c "
import json, sys
try:
    with open('$AGENTBOX_CONFIG') as f:
        data = json.load(f)
    v = data.get('$key')
    if v is None:
        print('$default')
    elif isinstance(v, bool):
        print('true' if v else 'false')
    elif isinstance(v, list):
        print('\n'.join(str(x) for x in v))
    else:
        print(v)
except:
    print('$default')
" 2>/dev/null)
        echo "$val"
        return
    fi

    # Fallback: grep/sed fuer einfache String/Number-Werte
    local val
    val=$(grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$AGENTBOX_CONFIG" \
        | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [ -z "$val" ]; then
        # Unquoted (Zahlen, Booleans)
        val=$(grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[a-z0-9][a-z0-9]*" "$AGENTBOX_CONFIG" \
            | head -1 | sed 's/.*:[[:space:]]*//')
    fi

    echo "${val:-$default}"
}

# cfg_get_array "key"
# Gibt Array-Eintraege zeilenweise aus
cfg_get_array() {
    local key="$1"

    if [ ! -f "$AGENTBOX_CONFIG" ]; then
        return
    fi

    if command -v python3 &> /dev/null; then
        python3 -c "
import json
try:
    with open('$AGENTBOX_CONFIG') as f:
        data = json.load(f)
    v = data.get('$key', [])
    if isinstance(v, list):
        for x in v:
            print(x)
except:
    pass
" 2>/dev/null
        return
    fi

    # Fallback: Zeilenweiser Parser
    local in_array=false
    while IFS= read -r line; do
        if [[ "$line" =~ \"${key}\" ]]; then
            in_array=true
            continue
        fi
        if [ "$in_array" = true ]; then
            if [[ "$line" =~ \] ]]; then
                break
            fi
            local val
            val=$(echo "$line" | sed -n 's/.*"\([^"]*\)".*/\1/p')
            if [ -n "$val" ]; then
                echo "$val"
            fi
        fi
    done < "$AGENTBOX_CONFIG"
}

# cfg_get_agents
# Gibt aktivierte Agenten als "id:name:command" pro Zeile aus
cfg_get_agents() {
    if [ ! -f "$AGENTBOX_CONFIG" ]; then
        return
    fi

    if command -v python3 &> /dev/null; then
        python3 -c "
import json, re
try:
    with open('$AGENTBOX_CONFIG') as f:
        data = json.load(f)
    ids = set()
    for k in data:
        m = re.match(r'agent_(.+)_name', k)
        if m:
            ids.add(m.group(1))
    for aid in sorted(ids):
        enabled = data.get(f'agent_{aid}_enabled', False)
        if enabled:
            name = data.get(f'agent_{aid}_name', aid)
            cmd = data.get(f'agent_{aid}_command', aid)
            print(f'{aid}:{name}:{cmd}')
except:
    pass
" 2>/dev/null
        return
    fi

    # Fallback: Standard-Agents (alle, die standardmaessig aktiviert sind)
    echo "claude:Claude Code:claude"
    echo "codex:OpenAI Codex:codex"
    echo "gemini:Gemini CLI:gemini"
    # Aider und Goose nur wenn installiert (standardmaessig deaktiviert)
    # Im Fallback-Modus nicht ausgeben — config.json ist die Wahrheitsquelle
}
