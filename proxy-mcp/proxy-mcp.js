#!/usr/bin/env node
// proxy-mcp.js — agentbox sandbox-side MCP proxy
//
// Spricht das MCP-Stdio-Protokoll (JSON-RPC) mit dem Agent (Claude Code,
// Codex, Gemini, Goose). Forwarded jeden `tools/call` als File-Queue-
// Request an den Host-side MCP-Handler-Daemon unter
// ~/.mcp-runtime/<id>/requests/ und pollt ~/.mcp-runtime/<id>/responses/
// auf die passende Antwort.
//
// Keine Netzwerk-Bridge — die Sandbox-Firewall bleibt unangetastet.
// Keine npm-Deps — nur node-builtins (fs, path, crypto, readline).
//
// Aufruf: proxy-mcp.js --id <mcp-id> [--runtime <dir>] [--timeout <sec>]
//
// --id        MCP-Server-ID aus config.json mcp_servers[].id (Queue-Pfad
//             und tools.json-Lookup). Pflicht.
// --runtime   Runtime-Root (Default: $HOME/.mcp-runtime). Darin liegt
//             <id>/{requests,responses,daemon.pid,daemon.heartbeat,
//             tools.json}.
// --timeout   Request-Timeout in Sekunden (Default: 30).
//
// Der Host-side Handler muss `daemon.heartbeat` regelmaessig touchen
// und seine Tools in `tools.json` deklarieren. Fehlt die Heartbeat-
// Datei oder ist sie aelter als 2x timeout, liefert der Proxy einen
// 'MCP daemon not running' Fehler.

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const readline = require('readline');

// --- Argparse ---
function parseArgs(argv) {
    const args = { id: '', runtime: '', timeout: 30 };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--id') { args.id = argv[++i] || ''; }
        else if (a === '--runtime') { args.runtime = argv[++i] || ''; }
        else if (a === '--timeout') { args.timeout = parseInt(argv[++i] || '30', 10) || 30; }
    }
    if (!args.id) {
        process.stderr.write('proxy-mcp: --id is required\n');
        process.exit(2);
    }
    if (!args.runtime) {
        args.runtime = path.join(process.env.HOME || '/tmp', '.mcp-runtime');
    }
    return args;
}

const ARGS = parseArgs(process.argv.slice(2));
const RUNTIME_BASE = path.join(ARGS.runtime, ARGS.id);
const REQUESTS_DIR = path.join(RUNTIME_BASE, 'requests');
const RESPONSES_DIR = path.join(RUNTIME_BASE, 'responses');
const TOOLS_JSON = path.join(RUNTIME_BASE, 'tools.json');
const HEARTBEAT_FILE = path.join(RUNTIME_BASE, 'daemon.heartbeat');
const HEARTBEAT_STALE_MS = Math.max(ARGS.timeout * 2, 60) * 1000;

// --- Logging (stderr only — stdout ist fuer MCP-Protokoll reserviert) ---
function log(msg) {
    process.stderr.write('[proxy-mcp ' + ARGS.id + '] ' + msg + '\n');
}

// --- JSON-RPC writer ---
function sendResponse(id, result) {
    const msg = { jsonrpc: '2.0', id: id, result: result };
    process.stdout.write(JSON.stringify(msg) + '\n');
}
function sendError(id, code, message, data) {
    const err = { code: code, message: message };
    if (data !== undefined) err.data = data;
    const msg = { jsonrpc: '2.0', id: id, error: err };
    process.stdout.write(JSON.stringify(msg) + '\n');
}

// --- Tools-Cache (wird bei jeder tools/list neu geladen, nicht cached
//     — Handler kann seine Tools zur Laufzeit aendern) ---
function loadTools() {
    try {
        const raw = fs.readFileSync(TOOLS_JSON, 'utf8');
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) return parsed;
        if (parsed && Array.isArray(parsed.tools)) return parsed.tools;
        return [];
    } catch (e) {
        return [];
    }
}

function daemonAlive() {
    try {
        const st = fs.statSync(HEARTBEAT_FILE);
        return (Date.now() - st.mtimeMs) < HEARTBEAT_STALE_MS;
    } catch (e) {
        return false;
    }
}

// --- Request-Submit + Response-Poll ---
// Wir nutzen kein fs.watch(), weil das auf DrvFs-Bind-Mounts unzuverlaessig
// ist (9P file change notifications sind best-effort). Ein 50ms-Polling-
// Loop hat eine vorhersagbare Latenz und kommt ohne FileSystemWatcher-
// Edge-Cases aus.
function submitRequest(toolName, args) {
    return new Promise((resolve, reject) => {
        if (!daemonAlive()) {
            return reject(new Error(
                'MCP daemon not running (stale/missing heartbeat at ' +
                HEARTBEAT_FILE + '). Logoff/Logon triggert Scheduled Task ' +
                '"agentbox-mcp-dispatcher" neu.'
            ));
        }

        try {
            fs.mkdirSync(REQUESTS_DIR, { recursive: true });
            fs.mkdirSync(RESPONSES_DIR, { recursive: true });
        } catch (e) {
            return reject(new Error('cannot create queue dirs: ' + e.message));
        }

        const reqId = crypto.randomBytes(8).toString('hex') + '-' + Date.now();
        const reqPath = path.join(REQUESTS_DIR, reqId + '.req.json');
        const resPath = path.join(RESPONSES_DIR, reqId + '.res.json');
        const tmpPath = reqPath + '.tmp';

        const payload = {
            id: reqId,
            tool: toolName,
            arguments: args || {},
            ts: Date.now()
        };

        try {
            // Atomic write: tmp -> rename. Verhindert, dass der
            // FileSystemWatcher auf der Host-Seite eine halb-geschriebene
            // Datei liest.
            fs.writeFileSync(tmpPath, JSON.stringify(payload), 'utf8');
            fs.renameSync(tmpPath, reqPath);
        } catch (e) {
            return reject(new Error('cannot submit request: ' + e.message));
        }

        const startedAt = Date.now();
        const deadline = startedAt + ARGS.timeout * 1000;

        const poll = () => {
            let content = null;
            try {
                content = fs.readFileSync(resPath, 'utf8');
            } catch (e) {
                // ENOENT → noch nicht da
            }

            if (content !== null) {
                try { fs.unlinkSync(resPath); } catch (e) { /* best-effort */ }
                // Request-File kann der Handler selbst schon geloescht
                // haben; wenn nicht, cleanup.
                try { fs.unlinkSync(reqPath); } catch (e) { /* best-effort */ }
                try {
                    const parsed = JSON.parse(content);
                    return resolve(parsed);
                } catch (e) {
                    return reject(new Error('invalid response JSON: ' + e.message));
                }
            }

            if (Date.now() > deadline) {
                // Request aufraeumen, damit der Handler ihn nicht nach
                // Timeout noch verarbeitet und Orphan-Responses produziert.
                try { fs.unlinkSync(reqPath); } catch (e) { /* best-effort */ }
                return reject(new Error(
                    'MCP request timeout after ' + ARGS.timeout + 's (tool=' + toolName + ')'
                ));
            }

            setTimeout(poll, 50);
        };

        // Start slightly delayed to give the handler one cycle of FSWatcher headroom.
        setTimeout(poll, 20);
    });
}

// --- MCP-Protokoll-Handler ---
async function handleRequest(req) {
    const id = req.id;
    const method = req.method;
    const params = req.params || {};

    switch (method) {
        case 'initialize': {
            // Vereinfachte capabilities-Response. Das reicht fuer Claude
            // Code/Codex/Gemini/Goose — niemand von denen braucht hier
            // experimentelle Server-Side-Features.
            sendResponse(id, {
                protocolVersion: params.protocolVersion || '2024-11-05',
                capabilities: { tools: {} },
                serverInfo: {
                    name: 'agentbox-proxy-mcp',
                    version: '1.0.0'
                }
            });
            break;
        }

        case 'notifications/initialized':
        case 'initialized': {
            // Notification, keine Antwort noetig.
            break;
        }

        case 'tools/list': {
            const tools = loadTools();
            sendResponse(id, { tools: tools });
            break;
        }

        case 'tools/call': {
            const name = params.name;
            const args = params.arguments || {};
            if (!name) {
                sendError(id, -32602, 'tools/call: missing "name"');
                return;
            }
            try {
                const result = await submitRequest(name, args);
                // Handler-Response-Schema ist:
                //   { content: [...], isError?: bool }
                // oder vereinfacht nur { content: [...] }.
                // Fehlermeldungen aus dem Handler koennen auch als
                //   { error: "msg" }
                // kommen — wir wandeln die in ein MCP-kompatibles Error-Tool-
                // Result um, damit der Agent sie sieht.
                if (result && result.error && !result.content) {
                    sendResponse(id, {
                        content: [{ type: 'text', text: String(result.error) }],
                        isError: true
                    });
                } else if (result && result.content) {
                    sendResponse(id, result);
                } else {
                    // Letzter Fallback: raw payload als text zurueckgeben.
                    sendResponse(id, {
                        content: [{ type: 'text', text: JSON.stringify(result) }]
                    });
                }
            } catch (e) {
                sendResponse(id, {
                    content: [{ type: 'text', text: 'MCP error: ' + e.message }],
                    isError: true
                });
            }
            break;
        }

        case 'ping': {
            sendResponse(id, {});
            break;
        }

        default: {
            // Unbekannte Methode → method-not-found. Agents probieren teils
            // resources/list, prompts/list usw. — die kann der Proxy nicht
            // verdolmetschen, weil die Tools.json-Layer nur Tools kennt.
            sendError(id, -32601, 'method not found: ' + method);
        }
    }
}

// --- Stdio-Reader ---
const rl = readline.createInterface({ input: process.stdin, terminal: false });

rl.on('line', (line) => {
    line = line.trim();
    if (!line) return;
    let req = null;
    try {
        req = JSON.parse(line);
    } catch (e) {
        sendError(null, -32700, 'parse error: ' + e.message);
        return;
    }
    handleRequest(req).catch((e) => {
        log('unhandled: ' + e.message);
        try { sendError(req && req.id, -32603, 'internal error: ' + e.message); }
        catch (ee) { /* ignore */ }
    });
});

rl.on('close', () => {
    process.exit(0);
});

log('started (runtime=' + RUNTIME_BASE + ', timeout=' + ARGS.timeout + 's)');
