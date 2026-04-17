# agentbox 2.0 — Performance-Architektur

> **Status: in 2.0.0 implementiert.** Der tar.gz-/DrvFs-Pfad bleibt als
> transparenter Fallback erhalten — bei aelteren WSL-Versionen oder
> fehlgeschlagenem vhdx-Import laeuft alles wie in 1.x.

## Problem (1.x)

Alle Projektdateien, Caches und Auth-State liegen auf **DrvFs** (Windows
NTFS via 9P-Protokoll). Das ist 3-10x langsamer als natives ext4 im
WSL2-VM. Jeder `git status`, jeder `npm install`, jedes Datei-Read/Write
geht durch:

```text
App -> Linux VFS -> 9P Client -> Hyper-V VMBus -> 9P Server
    -> Windows I/O -> NTFS -> Disk
```

Das 1.x-Tuning (noatime, iptables-Reorder, DNS, chown-Eliminierung) hat
die schlimmsten Bremsen rausgenommen, kann aber den fundamentalen
9P-Overhead nicht beseitigen.

### Gemessene Zahlen (User-Benchmark 1.0.28)

| Filesystem           | Write    | Read (cached) | Files/s |
|----------------------|----------|---------------|---------|
| ext4 (`/tmp`)        | 495 MB/s | 6.2 GB/s      | 500     |
| DrvFs (`/workspace`) | 44 MB/s  | 161 MB/s      | 125     |

**Faktor: 4-11x langsamer auf DrvFs.**

### Wettbewerbs-Vorteil

ALLE Konkurrenten (Docker-basiert wie vibekit, textcortex, rivet;
WSL-basiert wie claudecode-wsl2, sandvault) leiden unter demselben
DrvFs/9P-Overhead wenn sie Windows-Dateien anfassen. Docker Desktop auf
Windows nutzt intern denselben 9P-Kanal für Bind-Mounts. Wenn agentbox
diesen Flaschenhals eliminiert, ist das ein Performance-Alleinstellungs-
merkmal das kein Konkurrent hat.

## Lösung (2.0): Hybrid-Architektur — vhdx-Template + ext4-Workspace

### Kernideen

1. **Template als vhdx statt tar.gz** — `wsl --export --vhd` speichert
   das fertige Template als vhdx-Datei. Session-Start = File-Copy der
   vhdx (~3-5s auf SSD) + `wsl --import-in-place` (<1s) statt tar.gz-
   Extraktion (30-120s). **Kein Admin nötig** — `wsl --import-in-place`
   ist eine User-Level-Operation.

2. **Hybrid-Workspace: Quellcode auf DrvFs (sicher), Heavy-I/O auf
   ext4 (schnell)** — Quellcode-Dateien (`src/`) bleiben per Bind-Mount
   auf DrvFs/OneDrive (crash-safe, cloud-synced, kein Datenverlust).
   Alles was Heavy-I/O erzeugt (`node_modules`, `.git/objects`, `dist/`,
   `__pycache__`, Build-Artefakte) lebt auf dem ext4-Filesystem der
   Sandbox-vhdx. **Kein Sync nötig, kein Crash-Risiko für Quellcode.**

   ```text
   /workspace/
     src/           <- Bind-Mount von DrvFs (sicher, OneDrive-synced)
     node_modules/  <- ext4 im vhdx (schnell, ephemer, recreatable)
     .git/          <- ext4 im vhdx (schneller git status/log/diff)
     dist/          <- ext4 im vhdx (schnelle Builds)
     __pycache__/   <- ext4 im vhdx
   ```

   Agent schreibt Quellcode -> geht sofort auf DrvFs/OneDrive (safe).
   Agent macht `npm install` -> 10.000 Dateien auf ext4 (500 files/s).
   **Best of both worlds.**

### Architektur-Entwurf

```text
Installer (install.ps1, einmalig):
  1. Template bauen:     wsl --import template-build <tmpdir> <ubuntu.tar.xz>
                         [Node, Python, Agent-CLIs installieren - wie bisher]
  2. Als vhdx sichern:   wsl --export --vhd template-build template.vhdx
                         wsl --unregister template-build
     -> template.vhdx in %LOCALAPPDATA%\agentbox\sandbox\

Sandbox-Start (wsl-ai-start.sh, jede Session):
  3. vhdx kopieren:      Copy-Item template.vhdx -> session.vhdx   (~3-5s SSD)
  4. Distro registrieren: wsl --import-in-place agentbox-<sess> session.vhdx  (<1s)
  5. wsl-sandbox-init.sh:
     - Quellcode bind-mounten: DrvFs -> /workspace/src  (wie 1.x, sicher)
     - Heavy-I/O-Dirs auf ext4: node_modules, .git, dist, Cache
       bleiben im vhdx-Filesystem (schnell)

Agent-Session:
  6. Quellcode-Writes -> DrvFs (safe, sofort auf OneDrive)
     Heavy-I/O (npm, git, build) -> ext4 (500 files/s, 495 MB/s)

Sandbox-Ende:
  7. wsl --unregister agentbox-<sess>
  8. session.vhdx löschen
  -> Kein rsync nötig! Quellcode war die ganze Zeit auf DrvFs.
  -> node_modules etc. sind ephemer (werden bei nächstem npm install
     neu erzeugt, oder per Cache beschleunigt)
```

## Netzwerk-Tuning 2.0 — Ziel: Host-Level-Performance

### Status nach 1.x-Tuning

- DNS: 28ms ✓ (Google/Cloudflare, schnelle Resolver)
- TCP Handshake: 63ms ✓
- HTTPS HEAD: 250-450ms ✓ (TLS-Overhead, kaum reduzierbar)
- iptables: ESTABLISHED an Pos. 2, fast-path für 99% des Traffics ✓

### Was in 2.0 noch geht

1. **TCP BBR Congestion Control** — Googles Algorithmus, besser als
   cubic bei Paketverlust und hoher Latenz. Besonders relevant weil
   WSL2-NAT einen extra Hop einführt:

   ```bash
   modprobe tcp_bbr 2>/dev/null || true
   sysctl -w net.ipv4.tcp_congestion_control=bbr
   ```

2. **TCP Fast Open (TFO)** — spart einen Roundtrip beim TCP-
   Verbindungsaufbau. Jede neue HTTPS-Connection (npm registry,
   AI API, git push) profitiert:

   ```bash
   sysctl -w net.ipv4.tcp_fastopen=3
   ```

3. **Socket-Buffer-Tuning** — WSL2-Defaults sind konservativ. Grössere
   Buffer = weniger Syscalls pro Transfer, besserer Durchsatz bei
   grossen Downloads:

   ```bash
   sysctl -w net.core.rmem_max=16777216
   sysctl -w net.core.wmem_max=16777216
   sysctl -w net.ipv4.tcp_rmem="4096 131072 16777216"
   sysctl -w net.ipv4.tcp_wmem="4096 131072 16777216"
   ```

4. **Lokaler DNS-Cache** — aktuell geht jede DNS-Query direkt an
   8.8.8.8/1.1.1.1. npm/pip machen 50-200 DNS-Queries pro Install
   (registry.npmjs.org, cdn.npmjs.org, ...). Ein lokaler dnsmasq-Cache
   hält aufgelöste Adressen im Speicher:

   ```bash
   apt-get install -y dnsmasq
   # /etc/dnsmasq.conf: server=8.8.8.8, cache-size=1000
   # /etc/resolv.conf: nameserver 127.0.0.1
   ```

   Erwarteter Gewinn: DNS-Latenz von 28ms auf <1ms für wiederholte
   Lookups (99% der Fälle bei npm/pip install).

5. **MTU-Optimierung** — WSL2-NAT kann MTU-Mismatches verursachen die
   zu TCP-Fragmentierung führen. Korrekter MTU = weniger Overhead:

   ```bash
   # In wsl-sandbox-init.sh: auto-detect und setzen
   ip link set dev eth0 mtu $(cat /sys/class/net/eth0/mtu) 2>/dev/null
   ```

### Wettbewerbs-Pitch

> "agentbox: die einzige AI-Agent-Sandbox mit TCP BBR, DNS-Caching,
> Buffer-Tuning und iptables-Fastpath. Alle anderen nutzen die
> WSL2/Docker-Defaults — wir nicht."

## Offene Fragen / Risiken

- **`wsl --export --vhd` und `wsl --import-in-place`** — verfügbar seit
  WSL 2.0.x (ca. 2023). Ältere WSL-Versionen unterstützen das nicht ->
  Fallback auf 1.x tar.gz-Pfad nötig.
- **vhdx-Größe:** Template ist ~3 GB (Ubuntu + Node + Python + 5
  Agent-CLIs). Sparse VHDX startet kleiner, wächst auf Disk aber
  während der Session (node_modules etc.). 10 GB Limit sollte reichen,
  Monitoring via `du` sinnvoll.
- **Crash-Recovery:** Quellcode ist sicher (DrvFs/OneDrive). Ephemere
  Daten (node_modules, Build-Artefakte) gehen bei Crash verloren —
  akzeptabel, weil jederzeit regenerierbar.
- **dnsmasq im Template:** vergrössert das Template, muss beim Build
  installiert werden. Alternativ: nur die sysctl-Tunings ohne dnsmasq
  (leichtgewichtiger, 80% des Gewinns).
- **TCP BBR:** WSL2-Kernel muss `tcp_bbr` als Modul haben. Auf
  Standard-WSL2-Kernel (5.15+) vorhanden. `modprobe tcp_bbr` mit
  Fallback wenn fehlend.
- **Fallback:** wenn vhdx-Pfad fehlschlägt (alte WSL-Version, fehlende
  Befehle), muss der 1.x-DrvFs-Pfad als Fallback erhalten bleiben.

## Implementierungs-Reihenfolge

### Phase 1: Netzwerk-Tuning (niedrig-hängend, kein Architektur-Umbau)

1. TCP BBR + TFO + Socket-Buffer sysctls in `wsl-sandbox-init.sh`
2. Lokaler DNS-Cache (dnsmasq oder systemd-resolved)
3. Benchmarks vorher/nachher

### Phase 2: vhdx-Template (der grosse Umbau)

1. PoC: `wsl --export --vhd` + Copy + `wsl --import-in-place` manuell
   testen
2. `win-setup-core.ps1`: Template als vhdx exportieren
3. `wsl-ai-start.sh`: vhdx-Copy + import-in-place statt tar.gz-import
4. Fallback: wenn vhdx-Pfad fehlschlägt, 1.x tar.gz beibehalten

### Phase 3: Hybrid-Workspace

1. `wsl-sandbox-init.sh`: Quellcode per Bind-Mount (wie 1.x), aber
   `node_modules`/`.git`/`dist` auf ext4 im vhdx belassen
2. Session-Ende: kein rsync nötig (Quellcode war immer auf DrvFs)

### Phase 4: Feinschliff

1. `.update_class = major` für das Release
2. Benchmarks: vorher/nachher-Vergleich publizieren (README)
3. Competitive Claim: "5-10x faster I/O than stock WSL2/Docker"

## Nicht in 2.0 (Later)

- npm/pip-Cache auf vhdx statt DrvFs (weiterer I/O-Gewinn)
- Multi-Projekt-VHD-Pool (ein vhdx pro Projekt, parallele Sessions)
- Dev-Drive-Detection (ReFS Copy-on-Write für instant vhdx-Kopie)
- Netzwerk-Profiling pro Session (Latenz/Throughput-Report am Ende)
