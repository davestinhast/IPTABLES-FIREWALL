#!/usr/bin/env bash
# =============================================================================
#  M-FIREWALL v2 — Terminal Edition  (Enhanced)
#  Kali Linux | iptables + ipset + /etc/hosts + Firefox DoH policy
#  Uso: sudo ./mfirewall.sh
# =============================================================================

# ─── Colores base ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
DIM='\033[2m'; NC='\033[0m'

# ─── Paleta 256 colores — gradiente azul ▶ cian ▶ verde ───────────────────────
GRAD=(17 18 19 20 27 33 38 45 51 50 49 47 46)
GRAD_RED=(88 124 160 196 203 210 214 220)

# ─── Estado global ────────────────────────────────────────────────────────────
STEP_MODE=false
SPINNER_PID=""
FIRST_DRAW=true
TERM_COLS=$(tput cols 2>/dev/null || echo 80)

# ─── Rutas ────────────────────────────────────────────────────────────────────
CONFIG_DIR="/opt/mfirewall"
CONFIG_FILE="$CONFIG_DIR/config.conf"
LOG_FILE="/var/log/mfirewall.log"
HOSTS_MARKER_START="# BEGIN M-FIREWALL"
HOSTS_MARKER_END="# END M-FIREWALL"

FIREFOX_POLICY_DIRS=(
    "/usr/lib/firefox-esr/distribution"
    "/usr/lib/firefox/distribution"
    "/etc/firefox-esr/policies"
    "/etc/firefox/policies"
)

# ─── Config defaults ──────────────────────────────────────────────────────────
BLOCK_FACEBOOK="false"; BLOCK_YOUTUBE="false"; BLOCK_HOTMAIL="false"
WAN_IFACE=""; LAN_IFACE=""
MAC_BLOCKS_STR=""; CONN_LIMITS_STR=""

# ─── DNS Proxy (Python3, intercepta queries antes del browser) ─────────────────
DNS_PROXY_PID_FILE="/var/run/mfirewall-dnsproxy.pid"
DNS_PROXY_PORT=5353
DNS_PROXY_SCRIPT="/tmp/mfirewall_dnsproxy.py"

# ─── Dominios ─────────────────────────────────────────────────────────────────
DOMAINS_FACEBOOK=(
    "facebook.com" "www.facebook.com" "m.facebook.com"
    "fb.com" "www.fb.com" "fbcdn.net" "www.fbcdn.net"
    "fbsbx.com" "messenger.com" "www.messenger.com"
    "connect.facebook.net" "fb.me" "static.xx.fbcdn.net"
    "instagram.com" "www.instagram.com"
)
DOMAINS_YOUTUBE=(
    "youtube.com" "www.youtube.com" "m.youtube.com"
    "youtu.be" "googlevideo.com" "www.googlevideo.com"
    "ytimg.com" "i.ytimg.com" "s.ytimg.com" "www.ytimg.com"
    "youtube-nocookie.com" "www.youtube-nocookie.com"
    "youtubekids.com" "www.youtubekids.com"
    "youtubei.googleapis.com" "yt3.ggpht.com"
    "use-application-dns.net"
)
DOMAINS_HOTMAIL=(
    "hotmail.com" "www.hotmail.com" "outlook.live.com"
    "login.live.com" "live.com" "www.live.com"
    "outlook.com" "www.outlook.com" "office365.com"
    "microsoftonline.com" "login.microsoftonline.com"
    "microsoft.com" "www.microsoft.com" "msftconnecttest.com"
)
YT_IPSET_DOMAINS=(
    "youtube.com" "www.youtube.com" "m.youtube.com"
    "youtu.be" "ytimg.com" "i.ytimg.com" "s.ytimg.com"
    "googlevideo.com" "youtube-nocookie.com"
)

# ─── Segundo terminal ─────────────────────────────────────────────────────────
CMD_LOG=""

# =============================================================================
# MOTOR DE ANIMACIÓN
# =============================================================================

# Restaurar cursor siempre al salir
_cleanup() {
    [[ -n "$SPINNER_PID" ]] && kill "$SPINNER_PID" 2>/dev/null
    tput cnorm 2>/dev/null
    tput rmcup 2>/dev/null
    stty echo 2>/dev/null
    echo ""
}
trap _cleanup EXIT INT TERM

# Imprime texto con gradiente 256 colores, carácter a carácter
gradient_print() {
    local text="$1"
    local palette=("${!2}")
    local offset="${3:-0}"
    [[ ${#palette[@]} -eq 0 ]] && palette=("${GRAD[@]}")
    local i
    for ((i=0; i<${#text}; i++)); do
        local cidx=$(( (i / 3 + offset) % ${#palette[@]} ))
        printf '\e[38;5;%dm%s' "${palette[$cidx]}" "${text:$i:1}"
    done
    printf '\e[0m'
}

# Banner ASCII animado — solo se dibuja una vez al arrancar
draw_banner_animated() {
    local B=(
        "  ╔══════════════════════════════════════════════════════════════╗"
        "  ║                                                              ║"
        "  ║    M ─ F I R E W A L L    v 2 . 0                          ║"
        "  ║    ──────────────────────────────────                        ║"
        "  ║    Kali Linux  ·  iptables + ipset + Firefox policy          ║"
        "  ║    Quezada  /  Espinola  /  Sanchez                          ║"
        "  ║                                                              ║"
        "  ╚══════════════════════════════════════════════════════════════╝"
    )
    printf '\n'
    local offset=0
    for line in "${B[@]}"; do
        gradient_print "$line" GRAD[@] $offset
        printf '\n'
        (( offset += 2 ))
    done
    printf '\n'
}

# Banner pequeño estático — para redraws rápidos del menú
draw_banner_static() {
    printf '\n'
    printf '  \e[38;5;27m╔══════════════════════════════════════════════════════════════╗\e[0m\n'
    printf '  \e[38;5;27m║\e[0m  \e[1m\e[38;5;51mM ─ F I R E W A L L\e[0m  \e[2mv2.0  ·  Kali Linux\e[0m'
    printf '                   \e[38;5;27m║\e[0m\n'
    printf '  \e[38;5;27m╚══════════════════════════════════════════════════════════════╝\e[0m\n'
    printf '\n'
}

# Efecto typewriter
typewrite() {
    local text="$1"
    local delay="${2:-0.028}"
    local color="${3:-}"
    [[ -n "$color" ]] && printf '%b' "$color"
    local i
    for ((i=0; i<${#text}; i++)); do
        printf '%s' "${text:$i:1}"
        sleep "$delay"
    done
    [[ -n "$color" ]] && printf '%b' "$NC"
    printf '\n'
}

# Transición de pantalla — barrido diagonal rápido
screen_wipe() {
    clear
}

# Spinner en background mientras corre la función dada
run_step() {
    local step_n="$1" total="$2" msg="$3" func="$4"
    shift 4

    STEP_MODE=true
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local pad_len=$(( cols - ${#msg} - 18 ))
    [[ $pad_len -lt 0 ]] && pad_len=0

    # Lanzar animación en subproceso
    (
        local F=('·' '·' '·' '·' '·' '·' '·' '·' '·' '·' '·' '·')
        local f=0 dots=""
        while true; do
            dots="${dots}."
            [[ ${#dots} -gt 3 ]] && dots=""
            printf "\r  \e[38;5;39m[%d/%d]\e[0m  %s%-3s  " \
                "$step_n" "$total" "$msg" "$dots"
            sleep 0.18
        done
    ) &
    SPINNER_PID=$!

    # Ejecutar función real
    "$func" "$@"
    local rc=$?

    # Detener spinner y limpiar línea
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
    SPINNER_PID=""
    STEP_MODE=false

    local clear_pad
    printf -v clear_pad '%*s' "$pad_len" ""

    if [[ $rc -eq 0 ]]; then
        printf "\r  \e[38;5;46m[%d/%d] ✓\e[0m  %s%s\n" \
            "$step_n" "$total" "$msg" "$clear_pad"
    else
        printf "\r  \e[38;5;196m[%d/%d] ✗\e[0m  %s \e[31m(rc=%d)\e[0m%s\n" \
            "$step_n" "$total" "$msg" "$rc" "$clear_pad"
    fi
    return $rc
}

# Barra de progreso
draw_progress_bar() {
    local done_n="$1" total_n="$2" label="${3:-}"
    local width=48
    local filled=$(( done_n * width / total_n ))
    local empty=$(( width - filled ))
    local pct=$(( done_n * 100 / total_n ))

    printf '  \e[38;5;239m[\e[0m'
    local i
    for ((i=0; i<filled; i++)); do
        local cidx=$(( i * ${#GRAD[@]} / width ))
        printf '\e[38;5;%dm█\e[0m' "${GRAD[$cidx]}"
    done
    for ((i=0; i<empty; i++)); do
        printf '\e[38;5;236m░\e[0m'
    done
    printf '\e[38;5;239m]\e[0m \e[1m%3d%%\e[0m' "$pct"
    [[ -n "$label" ]] && printf '  \e[2m%s\e[0m' "$label"
    printf '\n'
}

# Pantalla éxito tras activar
success_screen() {
    local S=(
        "  ╔═══════════════════════════════════════════╗"
        "  ║                                           ║"
        "  ║   ✓   FIREWALL ACTIVADO                  ║"
        "  ║       Bloqueos activos en el kernel.      ║"
        "  ║       Reinicia Firefox para aplicar DoH.  ║"
        "  ║                                           ║"
        "  ╚═══════════════════════════════════════════╝"
    )
    printf '\n'
    tput civis
    local off=0
    for line in "${S[@]}"; do
        gradient_print "$line" GRAD[@] $off
        printf '\n'
        (( off += 1 ))
        sleep 0.045
    done
    tput cnorm
    printf '\n'
}

# Pantalla disable
disable_screen() {
    printf '\n'
    printf '  \e[38;5;214m╔═══════════════════════════════════════╗\e[0m\n'
    printf '  \e[38;5;214m║\e[0m  \e[1m\e[38;5;220m✓  Firewall desactivado\e[0m'
    printf '                  \e[38;5;214m║\e[0m\n'
    printf '  \e[38;5;214m║\e[0m     Internet restaurado.                \e[38;5;214m║\e[0m\n'
    printf '  \e[38;5;214m╚═══════════════════════════════════════╝\e[0m\n'
    printf '\n'
}

# Spinner de inicio mientras carga config
boot_spinner() {
    local F=('▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')
    local i=0 cidx=0
    while true; do
        printf "\r  \e[38;5;%dm%s\e[0m  Iniciando M-FIREWALL..." \
            "${GRAD[$cidx]}" "${F[$i]}"
        i=$(( (i + 1) % ${#F[@]} ))
        cidx=$(( (cidx + 1) % ${#GRAD[@]} ))
        sleep 0.06
    done
}

# =============================================================================
# SEGUNDO TERMINAL
# =============================================================================
open_cmd_terminal() {
    CMD_LOG=$(mktemp /tmp/mfirewall-cmds-XXXXX.log)
    cat > "$CMD_LOG" << 'HEADER'
╔═══════════════════════════════════════════════════════════════════╗
║            M-FIREWALL v2 — Comandos Ejecutados                    ║
║      Esta ventana muestra cada comando en tiempo real             ║
╚═══════════════════════════════════════════════════════════════════╝

HEADER

    export DISPLAY="${DISPLAY:-:0}"
    [[ -n "${SUDO_USER:-}" ]] && \
        export XAUTHORITY="${XAUTHORITY:-/home/$SUDO_USER/.Xauthority}"

    local launched=false
    if command -v xterm &>/dev/null; then
        xterm \
            -title "M-FIREWALL — Comandos" \
            -bg "#080d16" -fg "#22c55e" \
            -geometry 105x36+30+30 \
            -fa "Monospace" -fs 10 \
            -e bash -c "tail -n +1 -f '${CMD_LOG}'; \
                        echo ''; echo '  Operación completada.'; read" &
        launched=true
    elif command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="M-FIREWALL Comandos" \
            -- bash -c "tail -n +1 -f '${CMD_LOG}'; read" &
        launched=true
    elif command -v konsole &>/dev/null; then
        konsole --title "M-FIREWALL Comandos" \
            -e bash -c "tail -n +1 -f '${CMD_LOG}'" &
        launched=true
    elif command -v x-terminal-emulator &>/dev/null; then
        x-terminal-emulator -e bash -c "tail -n +1 -f '${CMD_LOG}'" &
        launched=true
    fi

    if [[ "$launched" == false ]]; then
        printf '  \e[33m[AVISO]\e[0m No se encontró emulador. Comandos solo en pantalla.\n'
        CMD_LOG=""
    fi
    sleep 0.5
}

close_cmd_terminal() {
    [[ -z "$CMD_LOG" ]] && return
    {
        printf '\n══════════════════════════════════════════════\n'
        printf '  ✓ Completado — %s\n' "$(date '+%H:%M:%S')"
        printf '  Puedes cerrar esta ventana.\n'
        printf '══════════════════════════════════════════════\n'
    } >> "$CMD_LOG"
    CMD_LOG=""
}

# Ejecuta y loguea en segundo terminal
cmd() {
    [[ -n "$CMD_LOG" ]] && \
        printf '[%s] [CMD] %s\n' "$(date +%H:%M:%S)" "$*" >> "$CMD_LOG"
    if [[ "$STEP_MODE" == true ]]; then
        if [[ -n "$CMD_LOG" ]]; then
            "$@" >> "$CMD_LOG" 2>&1
        else
            "$@" > /dev/null 2>&1
        fi
    else
        "$@"
    fi
    return $?
}

logc() {
    [[ -z "$CMD_LOG" ]] && return
    printf '[%s] [INFO] %s\n' "$(date +%H:%M:%S)" "$*" >> "$CMD_LOG"
}

logsec() {
    [[ -z "$CMD_LOG" ]] && return
    printf '\n══ %s ══\n' "$*" >> "$CMD_LOG"
}

logsub() {
    [[ -z "$CMD_LOG" ]] && return
    printf '\n  ── %s ──\n' "$*" >> "$CMD_LOG"
}

# =============================================================================
# CONFIG
# =============================================================================
load_config() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^# || -z "$key" ]] && continue
        case "$key" in
            BLOCK_FACEBOOK)  BLOCK_FACEBOOK="$val"  ;;
            BLOCK_YOUTUBE)   BLOCK_YOUTUBE="$val"   ;;
            BLOCK_HOTMAIL)   BLOCK_HOTMAIL="$val"   ;;
            WAN_IFACE)       WAN_IFACE="$val"       ;;
            LAN_IFACE)       LAN_IFACE="$val"       ;;
            MAC_BLOCKS_STR)  MAC_BLOCKS_STR="$val"  ;;
            CONN_LIMITS_STR) CONN_LIMITS_STR="$val" ;;
        esac
    done < "$CONFIG_FILE"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
BLOCK_FACEBOOK=$BLOCK_FACEBOOK
BLOCK_YOUTUBE=$BLOCK_YOUTUBE
BLOCK_HOTMAIL=$BLOCK_HOTMAIL
WAN_IFACE=$WAN_IFACE
LAN_IFACE=$LAN_IFACE
MAC_BLOCKS_STR=$MAC_BLOCKS_STR
CONN_LIMITS_STR=$CONN_LIMITS_STR
EOF
}

# =============================================================================
# RESOLUCIÓN DE IPs
# =============================================================================
resolve_domain_ips() {
    dig +short +time=3 +tries=2 "$1" A 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
}

resolve_site_ips() {
    local -n _dom=$1
    local -A _seen
    local ip domain
    for domain in "${_dom[@]}"; do
        while IFS= read -r ip; do
            if [[ -n "$ip" && -z "${_seen[$ip]+x}" ]]; then
                _seen[$ip]=1; echo "$ip"
            fi
        done < <(resolve_domain_ips "$domain")
    done
}

# =============================================================================
# /etc/hosts
# =============================================================================
remove_hosts_block() {
    if grep -q "$HOSTS_MARKER_START" /etc/hosts 2>/dev/null; then
        local tmp; tmp=$(mktemp)
        sed "/$HOSTS_MARKER_START/,/$HOSTS_MARKER_END/d" /etc/hosts > "$tmp"
        cat "$tmp" > /etc/hosts; rm -f "$tmp"
        logc "/etc/hosts limpiado"
    fi
}

# =============================================================================
# PASO 10 — Inyeccion en /etc/hosts (capa de bloqueo a nivel del sistema)
#   /etc/hosts se consulta ANTES que DNS. Si un dominio aparece apuntando a
#   0.0.0.0, el sistema operativo nunca hace la query DNS y nunca obtiene
#   la IP real. Es la capa mas rapida y de menor costo de procesamiento.
#   Se agrega un bloque marcado entre BEGIN/END M-FIREWALL para poder
#   eliminarlo limpiamente al desactivar el firewall.
# =============================================================================
apply_all_hosts() {
    logsec "/etc/hosts"
    remove_hosts_block
    local all=()
    [[ "$BLOCK_FACEBOOK" == "true" ]] && all+=("${DOMAINS_FACEBOOK[@]}")
    [[ "$BLOCK_YOUTUBE"  == "true" ]] && all+=("${DOMAINS_YOUTUBE[@]}")
    [[ "$BLOCK_HOTMAIL"  == "true" ]] && all+=("${DOMAINS_HOTMAIL[@]}")
    [[ ${#all[@]} -eq 0 ]] && return
    {
        printf '\n%s\n' "$HOSTS_MARKER_START"
        for d in "${all[@]}"; do
            printf '0.0.0.0 %s\n' "$d"   # bloqueo IPv4
            printf ':: %s\n'     "$d"    # bloqueo IPv6 — evita bypass por AAAA records
        done
        # Servidores DoH — bloqueados siempre que el firewall esté activo
        # Firefox puede usar DoH como bypass si estos nombres resuelven
        for _doh in \
            dns.google dns64.dns.google \
            cloudflare-dns.com mozilla.cloudflare-dns.com \
            1dot1dot1dot1.cloudflare-dns.com dns.cloudflare.com \
            doh.opendns.com doh.dns.apple.com \
            dns.quad9.net dns10.quad9.net \
            doh.cleanbrowsing.org \
            dns.adguard.com \
            doh.nextdns.io; do
            printf '0.0.0.0 %s\n' "$_doh"
            printf ':: %s\n'     "$_doh"
        done
        printf '%s\n' "$HOSTS_MARKER_END"
    } >> /etc/hosts
    if [[ -n "$CMD_LOG" ]]; then
        printf '[%s] [CMD] # %d entradas inyectadas en /etc/hosts\n' \
            "$(date +%H:%M:%S)" "${#all[@]}" >> "$CMD_LOG"
        for d in "${all[@]}"; do
            printf '[%s] [HOST] 0.0.0.0 %s\n' "$(date +%H:%M:%S)" "$d" >> "$CMD_LOG"
        done
    fi
    logc "${#all[@]} dominios bloqueados en /etc/hosts"
}

# =============================================================================
# FIREFOX DoH POLICY
# =============================================================================
FIREFOX_POLICY='{
  "policies": {
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "Preferences": {
      "network.trr.mode":                      { "Value": 5,    "Status": "locked" },
      "network.trr.uri":                       { "Value": "",   "Status": "locked" },
      "network.trr.bootstrapAddress":          { "Value": "",   "Status": "locked" },
      "network.dns.disablePrefetch":           { "Value": true, "Status": "locked" },
      "network.dns.disablePrefetchFromHTTPS":  { "Value": true, "Status": "locked" },
      "network.dns.echconfig.enabled":         { "Value": false, "Status": "locked" },
      "network.dns.use_https_rr_as_altsvc":    { "Value": false, "Status": "locked" },
      "security.tls.ech.grease_http3":         { "Value": false, "Status": "locked" },
      "network.dns.disableIPv6":               { "Value": true,  "Status": "locked" }
    }
  }
}'

apply_firefox_doh_block() {
    logsec "Firefox — deshabilitando DoH"
    local applied=false
    for dir in "${FIREFOX_POLICY_DIRS[@]}"; do
        if [[ -d "$(dirname "$dir")" ]]; then
            cmd mkdir -p "$dir"
            printf '%s\n' "$FIREFOX_POLICY" > "$dir/policies.json"
            [[ -n "$CMD_LOG" ]] && {
                printf '[%s] [CMD] cat > %s/policies.json\n' \
                    "$(date +%H:%M:%S)" "$dir" >> "$CMD_LOG"
                printf '%s\n' "$FIREFOX_POLICY" >> "$CMD_LOG"
            }
            logc "Escrito: $dir/policies.json"
            applied=true
        fi
    done
    if [[ "$applied" == false ]]; then
        cmd mkdir -p "/usr/lib/firefox-esr/distribution"
        printf '%s\n' "$FIREFOX_POLICY" \
            > "/usr/lib/firefox-esr/distribution/policies.json"
        logc "Forzado: /usr/lib/firefox-esr/distribution/policies.json"
    fi
}

remove_firefox_doh_block() {
    for dir in "${FIREFOX_POLICY_DIRS[@]}"; do
        [[ -f "$dir/policies.json" ]] && cmd rm -f "$dir/policies.json" \
            && logc "Eliminado: $dir/policies.json"
    done
}

# =============================================================================
# IPTABLES BASE — construye todas las cadenas personalizadas del firewall
#
# PASO 1: Crear cadenas personalizadas
#   Las cadenas organizan las reglas por funcion. En vez de meter todo en
#   FORWARD/OUTPUT directamente, cada cadena tiene una responsabilidad clara:
#     PM_REJECT    → registra en kernel y rechaza el paquete
#     PM_WEBBLOCK  → bloqueo por sitio web (IP, SNI, DNS, CIDR)
#     PM_MACBLOCK  → bloqueo por direccion MAC del equipo cliente
#     PM_CONNLIMIT → limite de conexiones simultaneas por IP
#
# PASO 2: Configurar PM_REJECT (registro + rechazo)
#   Todo paquete bloqueado llega a PM_REJECT. Primero escribe una linea en
#   el log del kernel con el prefijo PM-DROP (visible con journalctl -k o
#   dmesg). Luego rechaza el paquete enviando TCP RST al cliente.
#
# PASO 3: Bloquear cliente→servidor, permitir servidor→cliente
#   La regla ESTABLISHED,RELATED se coloca PRIMERA en FORWARD. El kernel
#   rastrea el estado de cada conexion con conntrack. Un paquete nuevo (SYN)
#   tiene estado NEW y cae en las cadenas de bloqueo. Una respuesta del
#   servidor tiene estado ESTABLISHED y pasa directo sin revisarse.
#   Resultado: el cliente no puede abrir nuevas conexiones a sitios bloqueados,
#   pero las respuestas de sesiones ya existentes siguen pasando.
#
# PASO 4: Enganchar las cadenas en el trafico real
#   FORWARD cubre el trafico de clientes que pasa por este servidor Kali.
#   OUTPUT cubre el trafico generado por el propio Kali.
#   El orden importa: ESTABLISHED primero, luego MAC, connlimit, web.
# =============================================================================
setup_base_chains() {
    logsec "Cadenas iptables + ip6tables"
    modprobe xt_string 2>/dev/null || true

    # ── Limpiar estado previo (IPv4) ────────────────────────────────────────────
    for chain in PM_REJECT PM_WEBBLOCK PM_MACBLOCK PM_CONNLIMIT; do
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    done
    cmd iptables -t nat -F PREROUTING 2>/dev/null || true
    cmd iptables -t nat -F OUTPUT     2>/dev/null || true
    iptables -D FORWARD -j PM_MACBLOCK  2>/dev/null || true
    iptables -D FORWARD -j PM_CONNLIMIT 2>/dev/null || true
    iptables -D FORWARD -j PM_WEBBLOCK  2>/dev/null || true
    iptables -D OUTPUT  -j PM_CONNLIMIT 2>/dev/null || true
    iptables -D OUTPUT  -j PM_WEBBLOCK  2>/dev/null || true
    iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # PASO 1 — Crear cadenas personalizadas
    cmd iptables -N PM_REJECT
    cmd iptables -N PM_WEBBLOCK
    cmd iptables -N PM_MACBLOCK
    cmd iptables -N PM_CONNLIMIT

    # PASO 2 — PM_REJECT: guardar registro en kernel y rechazar paquete
    # Cada paquete bloqueado genera una entrada PM-DROP en journalctl/dmesg
    cmd iptables -A PM_REJECT -j LOG --log-prefix "PM-DROP: " --log-level 4
    cmd iptables -A PM_REJECT -p tcp -j REJECT --reject-with tcp-reset
    cmd iptables -A PM_REJECT -j REJECT --reject-with icmp-port-unreachable

    # PASO 3 — Permitir servidor→cliente (respuestas de sesiones existentes)
    # Esta regla va PRIMERA. Estado ESTABLISHED = conexion ya abierta.
    # El SYN inicial del cliente tiene estado NEW, no entra aqui, cae en WEBBLOCK.
    cmd iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    # PASO 4 — Enganchar cadenas: bloqueo por MAC, connlimit y sitios web
    cmd iptables -A FORWARD -j PM_MACBLOCK
    cmd iptables -A FORWARD -j PM_CONNLIMIT
    cmd iptables -A FORWARD -j PM_WEBBLOCK
    cmd iptables -A OUTPUT  -j PM_CONNLIMIT
    cmd iptables -A OUTPUT  -j PM_WEBBLOCK

    # ── IPv6: misma estructura — Firefox usa IPv6 para bypassear reglas IPv4 ─────
    ip6tables -F PM_WEBBLOCK 2>/dev/null || true
    ip6tables -X PM_WEBBLOCK 2>/dev/null || true
    ip6tables -D FORWARD -j PM_WEBBLOCK 2>/dev/null || true
    ip6tables -D OUTPUT  -j PM_WEBBLOCK 2>/dev/null || true
    ip6tables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    ip6tables -N PM_WEBBLOCK 2>/dev/null || true
    ip6tables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    ip6tables -A FORWARD -j PM_WEBBLOCK 2>/dev/null || true
    ip6tables -A OUTPUT  -j PM_WEBBLOCK 2>/dev/null || true

    cmd sysctl -w net.ipv4.ip_forward=1
    conntrack -F 2>/dev/null || true
    logc "Cadenas IPv4+IPv6 listas — ESTABLISHED/RELATED activo (servidor->cliente permitido)"
}


# =============================================================================
# PASO 7 — Bloqueo de sitios web (PM_WEBBLOCK): capas de bloqueo
#
#   Facebook y Hotmail se bloquean con 2 capas:
#     a) ipset: IPs resueltas al activar el firewall  → -m set --match-set
#     b) SNI:   nombre del dominio en TLS ClientHello → -m string --string
#
#   YouTube necesita capas adicionales porque:
#     - Sus IPs rotan (Anycast de Google) → ipset no captura todas
#     - Firefox cifra el SNI con ECH (Firefox 118+) → string match falla
#     - Usa QUIC/HTTP3 sobre UDP 443 → reglas TCP no aplican
#     - Se conecta por IPv6 → reglas IPv4 no aplican
#   Soluciones aplicadas:
#     c) QUIC:  bloqueo UDP 443 para cortar HTTP3
#     d) CIDR:  rangos IPv4 especificos (34.107.0.0/16, 34.98.0.0/16)
#     e) IPv6:  rangos CIDR del AS15169 de Google en ip6tables
#     f) ECH:   desactivado via politica enterprise de Firefox
# =============================================================================
# Per-site SNI caller — llamado inline después de _animated_block_site
_apply_sni_site() {
    local _site="$1"
    local -a _sni_domains
    case "$_site" in
        facebook) _sni_domains=("facebook.com" "fbcdn.net" "fbsbx.com" "messenger.com") ;;
        youtube)  _sni_domains=("youtube.com" "googlevideo.com" "ytimg.com" "youtu.be" "youtube-nocookie.com") ;;
        hotmail)  _sni_domains=("hotmail.com" "outlook.com" "microsoftonline.com" "live.com") ;;
    esac
    logsub "SNI matching (TLS ClientHello) — iptables lee el dominio en texto plano"
    local _d
    for _d in "${_sni_domains[@]}"; do
        cmd iptables  -A PM_WEBBLOCK -p tcp --dport 443 -m string --string "$_d" --algo bm -j PM_REJECT
        cmd iptables  -A PM_WEBBLOCK -p tcp --dport 80  -m string --string "$_d" --algo bm -j PM_REJECT
        ip6tables -A PM_WEBBLOCK -p tcp --dport 443 -m string --string "$_d" --algo bm -j REJECT 2>/dev/null || true
        ip6tables -A PM_WEBBLOCK -p tcp --dport 80  -m string --string "$_d" --algo bm -j REJECT 2>/dev/null || true
    done
    if [[ "$_site" == "youtube" ]]; then
        logsub "QUIC/HTTP3 (UDP 443) + rangos CIDR Google CDN"
        cmd iptables -A PM_WEBBLOCK -p udp --dport 443 -j PM_REJECT
        ip6tables -A PM_WEBBLOCK -p udp --dport 443 -j REJECT 2>/dev/null || true
        cmd iptables -A PM_WEBBLOCK -d 34.107.0.0/16 -j PM_REJECT
        cmd iptables -A PM_WEBBLOCK -d 34.98.0.0/16  -j PM_REJECT
        ip6tables -A PM_WEBBLOCK -d 2800:3f0::/32  -j REJECT 2>/dev/null || true
        ip6tables -A PM_WEBBLOCK -d 2001:4860::/32 -j REJECT 2>/dev/null || true
        ip6tables -A PM_WEBBLOCK -d 2607:f8b0::/32 -j REJECT 2>/dev/null || true
        ip6tables -A PM_WEBBLOCK -d 2404:6800::/32 -j REJECT 2>/dev/null || true
        ip6tables -A PM_WEBBLOCK -d 2a00:1450::/32 -j REJECT 2>/dev/null || true
    fi
    logc "${_site^} SNI: ${#_sni_domains[@]} dominios"
}

# Per-site DNS hex caller — llamado inline después de _apply_sni_site
_apply_dns_site() {
    local _site="$1"
    local -a _hex_rules
    case "$_site" in
        facebook) _hex_rules=("|08|facebook|03|com" "|05|fbcdn|03|net" "|09|messenger|03|com" "|09|instagram|03|com") ;;
        youtube)  _hex_rules=("|07|youtube|03|com" "|0b|googlevideo|03|com" "|05|ytimg|03|com" "|06|youtu|02|be") ;;
        hotmail)  _hex_rules=("|07|hotmail|03|com" "|07|outlook|03|com" "|0f|microsoftonline|03|com" "|04|live|03|com") ;;
    esac
    logsub "DNS wire-protocol (port 53) — bloquea la consulta DNS antes de resolver"
    local _hex
    for _hex in "${_hex_rules[@]}"; do
        cmd iptables -A PM_WEBBLOCK -p udp --dport 53 -m string --hex-string "$_hex" --algo bm -j PM_REJECT
        cmd iptables -A PM_WEBBLOCK -p tcp --dport 53 -m string --hex-string "$_hex" --algo bm -j PM_REJECT
    done
    logc "${_site^} DNS: ${#_hex_rules[@]} patrones hex en port 53"
}


# =============================================================================
# BLOQUEADOR ANIMADO — targeting de IPs en tiempo real
# =============================================================================

# _animated_block_site step total name set_name domain_var_name [proto:port ...]
# Los proto:port con sufijo ":any" no usan match-set (ej: para DoT global)
_animated_block_site() {
    local step_n="$1" total="$2" name="$3" set_name="$4" domain_var="$5"
    shift 5
    local rules=("$@")

    logsec "━━━ $name ━━━"
    logsub "IPs resueltas + ipset"

    printf '\n'

    # ── Spinner durante resolución DNS ────────────────────────────────────
    (
        local F=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local f=0
        while true; do
            printf "\r  \e[38;5;39m[%d/%d]\e[0m \e[38;5;51m%s\e[0m Resolviendo %s..." \
                "$step_n" "$total" "${F[$f]}" "$name"
            f=$(( (f+1) % ${#F[@]} ))
            sleep 0.08
        done
    ) &
    local _spid=$!

    # Resolver IPs
    local -n _adom=$domain_var
    local -A _aseen; local _aips=(); local _aip _adom_entry
    for _adom_entry in "${_adom[@]}"; do
        while IFS= read -r _aip; do
            if [[ -n "$_aip" && -z "${_aseen[$_aip]+x}" ]]; then
                _aseen[$_aip]=1; _aips+=("$_aip")
            fi
        done < <(resolve_domain_ips "$_adom_entry")
    done

    kill "$_spid" 2>/dev/null; wait "$_spid" 2>/dev/null

    printf "\r  \e[38;5;46m[%d/%d] ✓\e[0m  Resolviendo %-10s  \e[38;5;240m%d IPs encontradas\e[0m%*s\n" \
        "$step_n" "$total" "$name" "${#_aips[@]}" 10 ""

    # ── Panel de targeting ────────────────────────────────────────────────
    printf "\n  \e[38;5;27m╭── \e[38;5;51m%s\e[0m \e[38;5;240m(%d IPs)\e[0m \e[38;5;27m" "$set_name" "${#_aips[@]}"
    printf '%.0s─' {1..30}
    printf '╮\e[0m\n'

    local shown=0 max_show=12
    for _aip in "${_aips[@]}"; do
        if [[ $shown -lt $max_show ]]; then
            printf "  \e[38;5;27m│\e[0m  \e[38;5;240m▶\e[0m  \e[38;5;51m%-18s\e[0m \e[38;5;27m→\e[0m \e[38;5;196m%-15s\e[0m  \e[38;5;46m✓\e[0m\n" \
                "$_aip" "$set_name"
            sleep 0.025
        fi
        (( shown++ ))
    done

    local _remaining=$(( ${#_aips[@]} - max_show ))
    [[ $_remaining -gt 0 ]] && \
        printf "  \e[38;5;27m│\e[0m  \e[38;5;240m    ··· y %d IPs más cargadas\e[0m\n" "$_remaining"

    printf "  \e[38;5;27m╰"
    printf '%.0s─' {1..46}
    printf '╯\e[0m\n\n'

    # ── Aplicar ipset ────────────────────────────────────────────────────
    cmd ipset create "$set_name" hash:ip family inet hashsize 1024 maxelem 65536 -exist
    cmd ipset flush "$set_name"
    for _aip in "${_aips[@]}"; do cmd ipset add "$set_name" "$_aip" -exist; done

    # ── Aplicar reglas iptables ───────────────────────────────────────────
    for rule in "${rules[@]}"; do
        IFS=':' read -r _proto _port _mode <<< "$rule"
        if [[ "$_mode" == "any" ]]; then
            cmd iptables -A PM_WEBBLOCK -p "$_proto" --dport "$_port" -j PM_REJECT
        else
            cmd iptables -A PM_WEBBLOCK -p "$_proto" --dport "$_port" \
                -m set --match-set "$set_name" dst -j PM_REJECT
        fi
    done

    logc "$name bloqueado: ${#_aips[@]} IPs en $set_name"
}

# =============================================================================
# DASHBOARD EN VIVO (opción 7)
# =============================================================================
show_dashboard() {
    # Mostrar explicación breve antes de entrar al modo live
    clear
    printf '\n'
    printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[1mPASO 7 — Dashboard en Vivo\e[0m\n'
    printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[38;5;226m¿Para qué sirve?\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mVista en tiempo real del estado del firewall: sitios\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mbloqueados, reglas iptables activas, MACs, conexiones\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2my paquetes PM-DROP registrados. Presiona [q] para salir.\e[0m\n'
    printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'
    sleep 1.5

    tput smcup  2>/dev/null
    tput civis
    stty -echo  2>/dev/null

    local quit=false

    while [[ "$quit" == false ]]; do
        tput home
        printf '\n'

        local now
        now=$(date '+%H:%M:%S')

        # Header con hora
        gradient_print "  ╭── M-FIREWALL  $now ─────────────────────────────────────────╮" GRAD[@] 0
        printf '\n'

        # Sitios
        printf '  \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mSITIOS\e[0m\n'
        for _dinfo in "Facebook:$BLOCK_FACEBOOK:PM_FACEBOOK" \
                      "YouTube:$BLOCK_YOUTUBE:PM_YOUTUBE" \
                      "Hotmail:$BLOCK_HOTMAIL:PM_HOTMAIL"; do
            IFS=':' read -r _dname _dstatus _dset <<< "$_dinfo"
            if [[ "$_dstatus" == "true" ]]; then
                local _dcnt=0
                ipset list "$_dset" &>/dev/null && \
                    _dcnt=$(ipset list "$_dset" 2>/dev/null | grep -cE '^[0-9]+\.' || echo 0)
                printf "  \e[38;5;27m│\e[0m  \e[38;5;46m●\e[0m  %-10s  \e[38;5;46mBLOQUEADO\e[0m   \e[38;5;240m%s  %d IPs\e[0m\n" \
                    "$_dname" "$_dset" "$_dcnt"
            else
                printf "  \e[38;5;27m│\e[0m  \e[38;5;240m○  %-10s  permitido\e[0m\n" "$_dname"
            fi
        done

        # Capas
        printf '  \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mCAPAS DE BLOQUEO\e[0m\n'

        if grep -q "$HOSTS_MARKER_START" /etc/hosts 2>/dev/null; then
            local _hcnt
            _hcnt=$(sed -n "/$HOSTS_MARKER_START/,/$HOSTS_MARKER_END/p" /etc/hosts \
                    | grep -c "^0.0.0.0" 2>/dev/null || echo 0)
            printf "  \e[38;5;27m│\e[0m  \e[38;5;46m●\e[0m  /etc/hosts       %d entradas bloqueadas\n" "$_hcnt"
        else
            printf '  \e[38;5;27m│\e[0m  \e[38;5;240m○  /etc/hosts       inactivo\e[0m\n'
        fi

        local _ff=false
        for _ffd in "${FIREFOX_POLICY_DIRS[@]}"; do
            [[ -f "$_ffd/policies.json" ]] && _ff=true && break
        done
        if [[ "$_ff" == true ]]; then
            printf '  \e[38;5;27m│\e[0m  \e[38;5;46m●\e[0m  Firefox DoH      deshabilitado\n'
        else
            printf '  \e[38;5;27m│\e[0m  \e[38;5;196m●\e[0m  Firefox DoH      \e[38;5;196mACTIVO — bypass posible\e[0m\n'
        fi

        # Actividad reciente
        printf '  \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mACTIVIDAD RECIENTE  (PM-DROP)\e[0m\n'
        printf '  \e[38;5;27m│\e[0m\n'

        local _drops=""
        if command -v journalctl &>/dev/null; then
            _drops=$(journalctl -k --no-pager -n 10 2>/dev/null | grep "PM-DROP" | tail -6)
        else
            _drops=$(dmesg 2>/dev/null | grep "PM-DROP" | tail -6)
        fi

        if [[ -n "$_drops" ]]; then
            while IFS= read -r _dline; do
                local _src _dst _ts
                _src=$(printf '%s' "$_dline" | grep -oP 'SRC=\K[^ ]+' || echo "?")
                _dst=$(printf '%s' "$_dline" | grep -oP 'DST=\K[^ ]+' || echo "?")
                _ts=$(printf '%s' "$_dline" | grep -oP '\d+:\d+:\d+' | head -1 || echo "--:--:--")
                printf "  \e[38;5;27m│\e[0m  \e[38;5;196m✗ DROP\e[0m  \e[38;5;240m%s\e[0m  \e[38;5;51m%-16s\e[0m \e[38;5;27m→\e[0m \e[38;5;214m%s\e[0m\n" \
                    "$_ts" "$_src" "$_dst"
            done <<< "$_drops"
        else
            printf '  \e[38;5;27m│\e[0m  \e[38;5;240m  Sin actividad registrada aún.\e[0m\n'
        fi

        printf '  \e[38;5;27m│\e[0m\n'
        gradient_print "  ╰──────────────────────────────────────────────────────────────╯" GRAD[@] 4
        printf '\n'
        printf '  \e[2mActualiza cada 3s  ·  [q] salir\e[0m\n'

        if read -t 3 -n 1 _key 2>/dev/null; then
            [[ "$_key" == "q" || "$_key" == "Q" ]] && quit=true
        fi
    done

    tput rmcup 2>/dev/null
    tput cnorm
    stty echo 2>/dev/null
}

# =============================================================================
# PASO 5 — Bloqueo por MAC address
#   El modulo xt_mac de iptables lee la direccion MAC del frame Ethernet
#   del paquete que llega a FORWARD. Si coincide con una MAC configurada,
#   el paquete va a PM_REJECT. Esto bloquea todo el trafico de ese equipo
#   sin importar que IP tenga o que protocolo use.
#   Las MACs se configuran desde el menu opcion 3 o desde el scanner opcion 9.
# =============================================================================
apply_mac_blocks() {
    [[ -z "$MAC_BLOCKS_STR" ]] && return
    logsec "MAC Blocking"
    IFS=',' read -ra _macs <<< "$MAC_BLOCKS_STR"
    local mac; for mac in "${_macs[@]}"; do
        [[ -z "$mac" ]] && continue
        # PASO 5: bloquear trafico de este equipo por su MAC de hardware
        cmd iptables -A PM_MACBLOCK -m mac --mac-source "$mac" -j PM_REJECT
        logc "MAC bloqueada: $mac"
    done
}

# =============================================================================
# PASO 6 — Limite de conexiones simultaneas por IP
#   El modulo xt_connlimit cuenta cuantas conexiones TCP activas tiene una
#   IP de origen hacia un puerto especifico. Si supera el maximo configurado,
#   la siguiente conexion va a PM_REJECT.
#   --connlimit-mask 32 = cada IP cuenta por separado (no por subred).
#   Si se configuro una IP especifica desde el scanner, se agrega -s IP
#   para limitar solo ese equipo en lugar de todos.
# =============================================================================
apply_conn_limits() {
    [[ -z "$CONN_LIMITS_STR" ]] && return
    logsec "Connection Limits"
    IFS=',' read -ra _limits <<< "$CONN_LIMITS_STR"
    local entry proto port max ip
    for entry in "${_limits[@]}"; do
        [[ -z "$entry" ]] && continue
        # Formato: proto:port:max   O   proto:port:max:IP
        IFS=':' read -r proto port max ip <<< "$entry"
        if [[ -n "$ip" && "$ip" != "*" ]]; then
            # Limitar solo esa IP especifica (viene del scanner)
            cmd iptables -A PM_CONNLIMIT -s "$ip" -p "$proto" --dport "$port" \
                -m connlimit --connlimit-above "$max" --connlimit-mask 32 \
                -j PM_REJECT
            logc "Límite: $proto/$port max=$max → solo $ip"
        else
            # Sin IP especifica: limita a TODAS las IPs que pasan por FORWARD
            cmd iptables -A PM_CONNLIMIT -p "$proto" --dport "$port" \
                -m connlimit --connlimit-above "$max" --connlimit-mask 32 \
                -j PM_REJECT
            logc "Límite: $proto/$port max=$max → todos los clientes"
        fi
    done
}

flush_dns() {
    logsec "DNS Cache Flush"
    # Si el proxy está activo, no reiniciar systemd-resolved (lo reemplazamos)
    if [[ ! -f "$DNS_PROXY_PID_FILE" ]]; then
        cmd systemctl restart systemd-resolved 2>/dev/null || true
    fi
    cmd resolvectl flush-caches 2>/dev/null || true
    logc "Caché DNS limpiada"
}

# =============================================================================
# DNS PROXY — Python3 intercepta queries DNS antes de que el browser las resuelva
# Retorna NXDOMAIN para dominios bloqueados; reenvía todo lo demás al upstream real.
# Esto mata el problema de Firefox internal DNS cache: eventualmente tiene que
# renovar y ahí nuestro proxy lo bloquea. Combinado con pkill firefox, es inmediato.
# =============================================================================

_write_dns_proxy_script() {
    cat > "$DNS_PROXY_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""M-FIREWALL DNS proxy — NXDOMAIN para dominios bloqueados.

Arquitectura anti-loop con SO_MARK:
  - Upstream queries llevan SO_MARK=7331 en el socket UDP
  - iptables NAT OUTPUT tiene RETURN para paquetes marcados con 0x1CA3
  - Cualquier otro proceso que mande DNS → REDIRECT al proxy → bloqueado/forwarded
  - El proxy mismo → marcado → RETURN → llega al upstream real sin loop
"""
import sys, socket, threading, signal, struct, os

upstream  = sys.argv[1]
port      = int(sys.argv[2])
blocked   = [k.lower() for k in sys.argv[3].split(',') if k.strip()]

# SO_MARK = 36 en Linux — marca paquetes para que iptables los distinga
SO_MARK   = 36
MARK_VAL  = 0x1CA3  # marca arbitraria, coincide con regla iptables

def nxdomain(data):
    if len(data) < 12:
        return data
    return (data[:2]         # Transaction ID
            + b'\x81\x83'    # QR=1 RCODE=3 (NXDOMAIN)
            + data[4:6]      # QDCOUNT original
            + b'\x00\x00'    # ANCOUNT = 0
            + b'\x00\x00'    # NSCOUNT = 0
            + b'\x00\x00'    # ARCOUNT = 0
            + data[12:])     # Question section

def extract_qname(data):
    """Extrae el nombre de dominio del query para log."""
    try:
        pos = 12
        labels = []
        while pos < len(data):
            length = data[pos]
            if length == 0:
                break
            labels.append(data[pos+1:pos+1+length].decode('ascii', errors='replace'))
            pos += 1 + length
        return '.'.join(labels)
    except Exception:
        return '?'

def handle(data, addr, sock):
    payload = data.lower()
    matched = next((kw for kw in blocked if kw.encode() in payload), None)
    if matched:
        try:
            sock.sendto(nxdomain(data), addr)
        except Exception:
            pass
        return
    # Reenviar al upstream — socket marcado con SO_MARK para evitar loop iptables
    up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        up.setsockopt(socket.SOL_SOCKET, SO_MARK, MARK_VAL)
    except (OSError, AttributeError):
        pass  # si el kernel no soporta SO_MARK, funciona igual pero sin anti-loop
    up.settimeout(3.0)
    try:
        up.sendto(data, (upstream, 53))
        resp, _ = up.recvfrom(4096)
        sock.sendto(resp, addr)
    except Exception:
        try:
            sock.sendto(nxdomain(data), addr)
        except Exception:
            pass
    finally:
        up.close()

def main():
    # 0.0.0.0 acepta: loopback (local), REDIRECT de otras IPs (gateway mode)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(('0.0.0.0', port))
    signal.signal(signal.SIGTERM, lambda *_: (sock.close(), sys.exit(0)))
    signal.signal(signal.SIGINT,  lambda *_: (sock.close(), sys.exit(0)))
    while True:
        try:
            data, addr = sock.recvfrom(4096)
            threading.Thread(target=handle, args=(data, addr, sock),
                             daemon=True).start()
        except OSError:
            break

if __name__ == '__main__':
    main()
PYEOF
    chmod +x "$DNS_PROXY_SCRIPT"
}

# =============================================================================
# PASO 9 — Proxy DNS local + NAT REDIRECT (anti-bypass de DNS)
#
#   Problema: Firefox puede usar DNS over HTTPS (DoH) para resolver dominios
#   sin pasar por el sistema operativo, eludiendo /etc/hosts y el DNS local.
#
#   Solucion en 3 partes:
#     a) Proxy DNS Python3 en 127.0.0.1:53 — devuelve NXDOMAIN para dominios
#        bloqueados y reenvía el resto al DNS real upstream.
#     b) NAT REDIRECT — iptables captura CUALQUIER paquete UDP/TCP al puerto
#        53, sin importar a que IP vaya (8.8.8.8, 1.1.1.1, etc.) y lo
#        redirige al proxy local. Asi el firewall controla todo el DNS.
#     c) Anti-loop: el proxy marca sus propias queries con SO_MARK=0x1CA3.
#        Una regla NAT con -m mark --mark 0x1CA3 -j RETURN las deja pasar
#        sin redirigir, evitando un bucle infinito.
#     d) resolv.conf fijado a 127.0.0.1 con chattr +i para que NetworkManager
#        no pueda sobreescribir el DNS del sistema.
# =============================================================================
setup_dns_proxy() {
    logsec "DNS proxy + NAT intercept (anti-bypass total)"

    # 1. Upstream DNS antes de tocar nada
    local _up
    _up=$(awk '/^nameserver/ && $2 !~ /^127\./{print $2; exit}' \
          /run/systemd/resolve/resolv.conf 2>/dev/null)
    [[ -z "$_up" ]] && \
        _up=$(awk '/^nameserver/ && $2 !~ /^127\./{print $2; exit}' \
              /etc/resolv.conf 2>/dev/null)
    [[ -z "$_up" ]] && _up="8.8.8.8"

    # 2. Liberar port 53 — matar TODO lo que pueda estar ocupándolo
    for _svc in systemd-resolved dnsmasq named unbound; do
        cmd systemctl stop "$_svc" 2>/dev/null || true
        pkill -9 -f "$_svc"        2>/dev/null || true
    done
    sleep 0.6
    # Verificar que port 53 esté libre (si no, forzar liberación)
    if ss -ulnp 2>/dev/null | grep -q ':53[[:space:]]'; then
        local _blocker
        _blocker=$(ss -ulnp 2>/dev/null | grep ':53[[:space:]]' | grep -oP 'pid=\K[0-9]+' | head -1)
        [[ -n "$_blocker" ]] && kill -9 "$_blocker" 2>/dev/null || true
        sleep 0.3
    fi

    # 3. NetworkManager: no tocar DNS
    local _nm_conf="/etc/NetworkManager/conf.d/99-mfirewall-dns.conf"
    if command -v nmcli &>/dev/null; then
        mkdir -p /etc/NetworkManager/conf.d
        printf '[main]\ndns=none\n' > "$_nm_conf"
        cmd systemctl reload NetworkManager 2>/dev/null || \
            cmd systemctl restart NetworkManager 2>/dev/null || true
        sleep 0.5
        logc "NetworkManager: dns=none activo"
    fi

    # 4. resolv.conf -> 127.0.0.1 + inmutable
    chattr -i /etc/resolv.conf 2>/dev/null || true
    if [[ -L /etc/resolv.conf ]]; then
        readlink /etc/resolv.conf > /var/run/mfirewall-resolv-symlink 2>/dev/null || true
        rm -f /etc/resolv.conf
    else
        cp /etc/resolv.conf /etc/resolv.conf.mfirewall_bak 2>/dev/null || true
        rm -f /etc/resolv.conf
    fi
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    logc "resolv.conf → 127.0.0.1 (inmutable)"

    # 5. Keywords
    local -a _kws=()
    [[ "$BLOCK_YOUTUBE"  == "true" ]] && \
        _kws+=(youtube googlevideo ytimg youtu youtube-nocookie youtubei ggpht gvt1)
    [[ "$BLOCK_FACEBOOK" == "true" ]] && \
        _kws+=(facebook fbcdn messenger instagram fbsbx)
    [[ "$BLOCK_HOTMAIL"  == "true" ]] && \
        _kws+=(hotmail outlook microsoftonline live.com office365)
    # Bloquear resolución de servidores DoH
    _kws+=(dns.google cloudflare-dns dns.quad9 use-application-dns mozilla.cloudflare)
    local _csv
    _csv=$(IFS=','; echo "${_kws[*]}")

    # 6. Kill proxy anterior
    if [[ -f "$DNS_PROXY_PID_FILE" ]]; then
        kill "$(cat "$DNS_PROXY_PID_FILE")" 2>/dev/null || true
        rm -f "$DNS_PROXY_PID_FILE"
    fi
    pkill -f "$DNS_PROXY_SCRIPT" 2>/dev/null || true
    sleep 0.3

    # 7. Arrancar proxy en 0.0.0.0:53
    _write_dns_proxy_script
    [[ -n "$CMD_LOG" ]] && printf '[%s] [CMD] python3 %s %s 53 %s &\n' \
        "$(date +%H:%M:%S)" "$DNS_PROXY_SCRIPT" "$_up" "$_csv" >> "$CMD_LOG"
    python3 "$DNS_PROXY_SCRIPT" "$_up" 53 "$_csv" &
    local _pid=$!
    disown "$_pid"
    echo "$_pid" > "$DNS_PROXY_PID_FILE"
    sleep 1.2

    # 8. Verificar con ss (fuente de verdad real, no dig)
    local _proxy_ok=false
    if ss -ulnp 2>/dev/null | grep -qE ':[0-9]*53[^0-9]'; then
        _proxy_ok=true
        logc "✓ Proxy UDP :53 activo (PID=$_pid)"
    else
        logc "AVISO: proxy no detectado en UDP :53"
    fi

    # 9. NAT REDIRECT — captura TODO el DNS a nivel kernel
    # Esto hace que resolv.conf sea irrelevante: aunque NM lo cambie a 8.8.8.8,
    # los paquetes UDP/TCP al puerto 53 son capturados antes de salir.
    # Anti-loop: el proxy marca sus upstream queries con 0x1CA3 via SO_MARK.
    # Iptables devuelve esos paquetes marcados sin capturarlos (RETURN).
    cmd iptables -t nat -A OUTPUT -p udp --dport 53 -m mark --mark 0x1CA3 -j RETURN
    cmd iptables -t nat -A OUTPUT -p tcp --dport 53 -m mark --mark 0x1CA3 -j RETURN
    cmd iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53
    cmd iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 53
    # Para clientes LAN que pasan por este Kali como gateway
    cmd iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
    cmd iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53
    logc "NAT REDIRECT :53 activo (mark=0x1CA3 exento de loop)"

    # Verificar con dig que NXDOMAIN funciona
    local _test
    _test=$(dig +short +time=2 youtube.com @127.0.0.1 2>/dev/null | head -1 || true)
    if [[ -z "$_test" ]]; then
        logc "✓ DNS: youtube.com → NXDOMAIN | upstream=$_up"
    else
        logc "AVISO: youtube.com resolvio '$_test'"
    fi

    # 10. Bloquear IPs DoH hardcodeadas en Firefox
    for _doh in 1.1.1.1 1.0.0.1 104.16.248.249 104.16.249.249 \
                8.8.8.8 8.8.4.4 9.9.9.9 9.9.9.10; do
        cmd iptables -A PM_WEBBLOCK -p tcp --dport 443 -d "$_doh" -j PM_REJECT
        cmd iptables -A PM_WEBBLOCK -p udp --dport 443 -d "$_doh" -j PM_REJECT
    done
    for _doh6 in 2606:4700:4700::1111 2606:4700:4700::1001 \
                 2001:4860:4860::8888 2001:4860:4860::8844; do
        ip6tables -A PM_WEBBLOCK -p tcp --dport 443 -d "$_doh6" -j REJECT 2>/dev/null || true
        ip6tables -A PM_WEBBLOCK -p udp --dport 443 -d "$_doh6" -j REJECT 2>/dev/null || true
    done

    # 11. Flush nscd si está corriendo (cache DNS a nivel libc, ignora resolv.conf)
    if command -v nscd &>/dev/null; then
        nscd -i hosts 2>/dev/null || true
        logc "nscd: cache de hosts invalidado"
    fi

    # 12. Matar Firefox + limpiar TODO el caché
    pkill -9 -f "firefox" 2>/dev/null || true
    local _ff_tries=0
    while (( _ff_tries++ < 20 )) && pgrep -f "firefox" >/dev/null 2>&1; do
        kill -9 $(pgrep -f "firefox" 2>/dev/null) 2>/dev/null || true
        sleep 0.3
    done

    # HTTP cache (cache2/) — rutas directas + snap por si Firefox está como snap
    rm -rf /root/.cache/mozilla/firefox/*/cache2                          2>/dev/null || true
    rm -rf /home/*/.cache/mozilla/firefox/*/cache2                        2>/dev/null || true
    rm -rf /root/snap/firefox/common/.cache/mozilla/firefox/*/cache2      2>/dev/null || true
    rm -rf /home/*/snap/firefox/common/.cache/mozilla/firefox/*/cache2    2>/dev/null || true

    # Sessionstore
    local _prof
    for _prof in \
        /root/.mozilla/firefox/*.default* \
        /root/.mozilla/firefox/*.default-esr* \
        /home/*/.mozilla/firefox/*.default* \
        /home/*/.mozilla/firefox/*.default-esr* \
        /root/snap/firefox/common/.mozilla/firefox/*.default* \
        /home/*/snap/firefox/common/.mozilla/firefox/*.default*; do
        [[ -d "$_prof" ]] || continue
        rm -f  "$_prof/sessionstore.jsonlz4" 2>/dev/null || true
        rm -rf "$_prof/sessionstore-backups" 2>/dev/null || true
    done

    logc "Setup completo | proxy PID=$_pid | NAT REDIRECT activo | upstream=$_up"
}

teardown_dns_proxy() {
    logsec "Deteniendo DNS proxy y restaurando DNS"

    # Matar proxy
    if [[ -f "$DNS_PROXY_PID_FILE" ]]; then
        local _pid; _pid=$(cat "$DNS_PROXY_PID_FILE")
        cmd kill "$_pid" 2>/dev/null || true
        rm -f "$DNS_PROXY_PID_FILE"
    fi
    pkill -f "$DNS_PROXY_SCRIPT" 2>/dev/null || true
    rm -f "$DNS_PROXY_SCRIPT"    2>/dev/null || true

    # Limpiar NAT REDIRECT (las limpias también vienen de _flush_chains, pero por si acaso)
    iptables -t nat -D OUTPUT    -p udp --dport 53 -m mark --mark 0x1CA3 -j RETURN  2>/dev/null || true
    iptables -t nat -D OUTPUT    -p tcp --dport 53 -m mark --mark 0x1CA3 -j RETURN  2>/dev/null || true
    iptables -t nat -D OUTPUT    -p udp --dport 53 -j REDIRECT --to-ports 53        2>/dev/null || true
    iptables -t nat -D OUTPUT    -p tcp --dport 53 -j REDIRECT --to-ports 53        2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53      2>/dev/null || true
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53      2>/dev/null || true

    # Quitar inmutable antes de restaurar resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf 2>/dev/null || true

    if [[ -f /var/run/mfirewall-resolv-symlink ]]; then
        local _tgt; _tgt=$(cat /var/run/mfirewall-resolv-symlink)
        ln -sf "$_tgt" /etc/resolv.conf 2>/dev/null || true
        rm -f /var/run/mfirewall-resolv-symlink
        logc "resolv.conf: symlink restaurado → $_tgt"
    elif [[ -f /etc/resolv.conf.mfirewall_bak ]]; then
        mv /etc/resolv.conf.mfirewall_bak /etc/resolv.conf
        logc "resolv.conf: backup restaurado"
    else
        printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > /etc/resolv.conf
        logc "resolv.conf: fallback a 8.8.8.8"
    fi

    # Restaurar NM y systemd-resolved
    local _nm_conf="/etc/NetworkManager/conf.d/99-mfirewall-dns.conf"
    if [[ -f "$_nm_conf" ]]; then
        rm -f "$_nm_conf"
        cmd systemctl reload NetworkManager 2>/dev/null || \
            cmd systemctl restart NetworkManager 2>/dev/null || true
        sleep 0.3
        logc "NetworkManager: dns management restaurado"
    fi
    cmd systemctl start systemd-resolved 2>/dev/null || true

    logc "DNS proxy detenido, DNS restaurado"
}

# =============================================================================
# DEMO: mata Firefox, limpia cache/service-workers, abre sitios bloqueados
# =============================================================================
open_demo_browser() {
    # Matar Firefox completamente para que no haya cache en RAM
    pkill -9 -f "firefox" 2>/dev/null || true
    local _w=0
    while pgrep -f "firefox" >/dev/null 2>&1 && (( _w++ < 20 )); do
        sleep 0.15
    done

    # Borrar cache disco + service worker storage de los 3 dominios bloqueados
    for _prof in \
        /root/.mozilla/firefox/*.default* \
        /root/.mozilla/firefox/*.default-esr* \
        /home/*/.mozilla/firefox/*.default* \
        /home/*/.mozilla/firefox/*.default-esr*; do
        [[ -d "$_prof" ]] || continue
        rm -rf "$_prof/cache2"                                          2>/dev/null || true
        rm -rf "$_prof/storage/default/https+++www.youtube.com"*        2>/dev/null || true
        rm -rf "$_prof/storage/default/https+++youtube.com"*            2>/dev/null || true
        rm -rf "$_prof/storage/default/https+++www.facebook.com"*       2>/dev/null || true
        rm -rf "$_prof/storage/default/https+++www.hotmail.com"*        2>/dev/null || true
        rm -rf "$_prof/storage/default/https+++outlook.live.com"*       2>/dev/null || true
        rm -f  "$_prof/serviceworker.txt"                               2>/dev/null || true
    done
    rm -rf /root/.cache/mozilla/firefox/*/cache2                        2>/dev/null || true

    # Construir lista de URLs según bloqueos activos
    local _urls=()
    [[ "$BLOCK_YOUTUBE"  == "true" ]] && _urls+=("https://www.youtube.com")
    [[ "$BLOCK_FACEBOOK" == "true" ]] && _urls+=("https://www.facebook.com")
    [[ "$BLOCK_HOTMAIL"  == "true" ]] && _urls+=("https://outlook.live.com")

    [[ ${#_urls[@]} -eq 0 ]] && { logc "open_demo_browser: sin URLs activas"; return; }

    # Lanzar Firefox como usuario real (soporta sudo y login directo como root)
    local _user="${SUDO_USER:-root}"
    local _disp="${DISPLAY:-:0}"
    local _ff
    _ff=$(command -v firefox-esr 2>/dev/null \
       || command -v firefox    2>/dev/null \
       || echo "firefox-esr")

    logc "Demo: lanzando $_ff con ${#_urls[@]} sitio(s) → deben fallar"

    if [[ "$_user" != "root" ]]; then
        DISPLAY="$_disp" sudo -u "$_user" nohup "$_ff" "${_urls[@]}" >/dev/null 2>&1 &
    else
        DISPLAY="$_disp" nohup "$_ff" "${_urls[@]}" >/dev/null 2>&1 &
    fi
    sleep 1.2   # dar tiempo al OS para arrancar el proceso antes de que el menú regrese
}

# =============================================================================
# ENABLE
# =============================================================================
enable_firewall() {
    local any=false
    [[ "$BLOCK_FACEBOOK" == "true" || \
       "$BLOCK_YOUTUBE"  == "true" || \
       "$BLOCK_HOTMAIL"  == "true" ]] && any=true

    if [[ "$any" == false ]]; then
        printf '\n  \e[33m[!]\e[0m Sin sitios habilitados. Ve a \e[1mOpción 2\e[0m primero.\n'
        return 1
    fi

    open_cmd_terminal
    screen_wipe

    printf '\n'
    gradient_print "  Activando M-FIREWALL..." GRAD[@] 0
    printf '\n\n'

    # Calcular total de pasos
    local total=6  # base + DNS-proxy + hosts + firefox + flush + demo
    [[ "$BLOCK_FACEBOOK" == "true" ]] && (( total++ ))
    [[ "$BLOCK_YOUTUBE"  == "true" ]] && (( total++ ))
    [[ "$BLOCK_HOTMAIL"  == "true" ]] && (( total++ ))
    [[ -n "$MAC_BLOCKS_STR" ]]  && (( total++ ))
    [[ -n "$CONN_LIMITS_STR" ]] && (( total++ ))

    local step=0

    (( step++ )); run_step $step $total "Configurando cadenas iptables" setup_base_chains
    draw_progress_bar $step $total

    if [[ "$BLOCK_FACEBOOK" == "true" ]]; then
        (( step++ ))
        _animated_block_site $step $total "Facebook" "PM_FACEBOOK" DOMAINS_FACEBOOK \
            "tcp:80" "tcp:443"
        _apply_sni_site  facebook
        _apply_dns_site  facebook
        draw_progress_bar $step $total
    fi
    if [[ "$BLOCK_YOUTUBE" == "true" ]]; then
        (( step++ ))
        _animated_block_site $step $total "YouTube" "PM_YOUTUBE" YT_IPSET_DOMAINS \
            "tcp:80" "tcp:443" "udp:443" "tcp:853:any" "udp:853:any"
        _apply_sni_site  youtube
        _apply_dns_site  youtube
        draw_progress_bar $step $total
    fi
    if [[ "$BLOCK_HOTMAIL" == "true" ]]; then
        (( step++ ))
        _animated_block_site $step $total "Hotmail" "PM_HOTMAIL" DOMAINS_HOTMAIL \
            "tcp:80" "tcp:443"
        _apply_sni_site  hotmail
        _apply_dns_site  hotmail
        draw_progress_bar $step $total
    fi
    if [[ -n "$MAC_BLOCKS_STR" ]]; then
        (( step++ )); run_step $step $total "Aplicando bloqueos MAC" apply_mac_blocks
        draw_progress_bar $step $total
    fi
    if [[ -n "$CONN_LIMITS_STR" ]]; then
        (( step++ )); run_step $step $total "Aplicando límites de conexión" apply_conn_limits
        draw_progress_bar $step $total
    fi

    (( step++ )); run_step $step $total "DNS proxy local (bloqueo garantizado)" setup_dns_proxy
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Inyectando /etc/hosts" apply_all_hosts
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Deshabilitando Firefox DoH" apply_firefox_doh_block
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Limpiando caché DNS" flush_dns
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Abriendo Firefox (sitios bloqueados)" open_demo_browser
    draw_progress_bar $step $total

    printf '[%s] FIREWALL ACTIVADO FB:%s YT:%s HM:%s\n' \
        "$(date)" "$BLOCK_FACEBOOK" "$BLOCK_YOUTUBE" "$BLOCK_HOTMAIL" \
        >> "$LOG_FILE" 2>/dev/null || true

    close_cmd_terminal
    success_screen
}

# =============================================================================
# DISABLE
# =============================================================================
disable_firewall() {
    open_cmd_terminal
    screen_wipe
    printf '\n'
    gradient_print "  Desactivando M-FIREWALL..." GRAD[@] 4
    printf '\n\n'

    local total=5 step=0

    _flush_chains() {
        # IPv4
        iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        for chain in PM_REJECT PM_WEBBLOCK PM_MACBLOCK PM_CONNLIMIT; do
            iptables -F "$chain" 2>/dev/null || true
            iptables -X "$chain" 2>/dev/null || true
        done
        iptables -D FORWARD -j PM_MACBLOCK  2>/dev/null || true
        iptables -D FORWARD -j PM_CONNLIMIT 2>/dev/null || true
        iptables -D FORWARD -j PM_WEBBLOCK  2>/dev/null || true
        iptables -D OUTPUT  -j PM_CONNLIMIT 2>/dev/null || true
        iptables -D OUTPUT  -j PM_WEBBLOCK  2>/dev/null || true
        iptables -t nat -F PREROUTING 2>/dev/null || true
        iptables -t nat -F OUTPUT     2>/dev/null || true
        # IPv6
        ip6tables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        ip6tables -D FORWARD -j PM_WEBBLOCK 2>/dev/null || true
        ip6tables -D OUTPUT  -j PM_WEBBLOCK 2>/dev/null || true
        ip6tables -F PM_WEBBLOCK 2>/dev/null || true
        ip6tables -X PM_WEBBLOCK 2>/dev/null || true
        logc "Cadenas IPv4+IPv6 eliminadas"
    }

    (( step++ )); run_step $step $total "Deteniendo DNS proxy" teardown_dns_proxy
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Eliminando reglas iptables" _flush_chains
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Limpiando /etc/hosts" remove_hosts_block
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Restaurando Firefox DoH" remove_firefox_doh_block
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Limpiando caché DNS" flush_dns
    draw_progress_bar $step $total

    printf '[%s] FIREWALL DESACTIVADO\n' "$(date)" >> "$LOG_FILE" 2>/dev/null || true
    close_cmd_terminal
    disable_screen

    # Resetear config para que dashboard y wizard arranquen limpios
    BLOCK_FACEBOOK="false"
    BLOCK_YOUTUBE="false"
    BLOCK_HOTMAIL="false"
    save_config
}

# =============================================================================
# DEEP RESET
# =============================================================================
deep_reset() {
    printf '\n'
    printf '  \e[38;5;196m╔══════════════════════════════════════════════╗\e[0m\n'
    printf '  \e[38;5;196m║\e[0m  \e[1m\e[38;5;203m⚠  RESET TOTAL DE RED\e[0m'
    printf '                         \e[38;5;196m║\e[0m\n'
    printf '  \e[38;5;196m║\e[0m  Elimina TODAS las reglas, ipsets y bloqueos.  \e[38;5;196m║\e[0m\n'
    printf '  \e[38;5;196m╚══════════════════════════════════════════════╝\e[0m\n\n'
    read -rp "  Escribe 'si' para confirmar: " confirm
    [[ "$confirm" != "si" ]] && printf '  Cancelado.\n' && return

    open_cmd_terminal
    screen_wipe
    printf '\n'
    gradient_print "  Ejecutando reset total..." GRAD_RED[@] 0
    printf '\n\n'

    local total=6 step=0

    _flush_all_tables() {
        for t in filter nat mangle raw; do
            iptables  -t "$t" -F 2>/dev/null || true
            iptables  -t "$t" -X 2>/dev/null || true
            ip6tables -t "$t" -F 2>/dev/null || true
            ip6tables -t "$t" -X 2>/dev/null || true
        done
        iptables -P INPUT   ACCEPT 2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT  ACCEPT 2>/dev/null || true
        ip6tables -P INPUT   ACCEPT 2>/dev/null || true
        ip6tables -P FORWARD ACCEPT 2>/dev/null || true
        ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
        logc "Todas las tablas iptables/ip6tables vaciadas"
    }
    _destroy_ipsets() { cmd ipset destroy 2>/dev/null || true; logc "ipsets destruidos"; }

    (( step++ )); run_step $step $total "Deteniendo DNS proxy" teardown_dns_proxy
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Vaciando todas las tablas iptables" _flush_all_tables
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Destruyendo ipsets" _destroy_ipsets
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Limpiando /etc/hosts" remove_hosts_block
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Quitando políticas Firefox" remove_firefox_doh_block
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Limpiando caché DNS" flush_dns
    draw_progress_bar $step $total

    printf '[%s] DEEP RESET\n' "$(date)" >> "$LOG_FILE" 2>/dev/null || true
    close_cmd_terminal

    printf '\n'
    gradient_print "  ✓ Red completamente restaurada." GRAD[@] 2
    printf '\n\n'
}

# =============================================================================
# STATUS
# =============================================================================
show_status() {
    printf '\n'
    printf '  \e[38;5;27m╭──────────────────────────────────────────╮\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[1mEstado actual\e[0m\n'
    printf '  \e[38;5;27m├──────────────────────────────────────────┤\e[0m\n'

    local sites=("Facebook:$BLOCK_FACEBOOK" "YouTube:$BLOCK_YOUTUBE" "Hotmail:$BLOCK_HOTMAIL")
    for s in "${sites[@]}"; do
        IFS=':' read -r name val <<< "$s"
        if [[ "$val" == "true" ]]; then
            printf "  \e[38;5;27m│\e[0m  %-10s  \e[38;5;46m● BLOQUEADO\e[0m\n" "$name"
        else
            printf "  \e[38;5;27m│\e[0m  %-10s  \e[38;5;240m○ permitido\e[0m\n" "$name"
        fi
    done
    printf '  \e[38;5;27m├──────────────────────────────────────────┤\e[0m\n'

    for set_name in PM_FACEBOOK PM_YOUTUBE PM_HOTMAIL; do
        if ipset list "$set_name" &>/dev/null; then
            local cnt
            cnt=$(ipset list "$set_name" | grep -cE '^[0-9]+\.' 2>/dev/null || echo 0)
            printf "  \e[38;5;27m│\e[0m  \e[38;5;46m%-15s  %3d IPs\e[0m\n" "$set_name" "$cnt"
        else
            printf "  \e[38;5;27m│\e[0m  \e[38;5;240m%-15s  no existe\e[0m\n" "$set_name"
        fi
    done
    printf '  \e[38;5;27m├──────────────────────────────────────────┤\e[0m\n'

    if grep -q "$HOSTS_MARKER_START" /etc/hosts 2>/dev/null; then
        local hcnt
        hcnt=$(sed -n "/$HOSTS_MARKER_START/,/$HOSTS_MARKER_END/p" /etc/hosts \
               | grep -c "^0.0.0.0" 2>/dev/null || echo 0)
        printf "  \e[38;5;27m│\e[0m  \e[38;5;46m/etc/hosts       %3d entradas\e[0m\n" "$hcnt"
    else
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m/etc/hosts       sin bloqueos\e[0m\n'
    fi

    local ff=false
    for dir in "${FIREFOX_POLICY_DIRS[@]}"; do
        [[ -f "$dir/policies.json" ]] && ff=true && break
    done
    if [[ "$ff" == true ]]; then
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46mFirefox DoH      deshabilitado\e[0m\n'
    else
        printf '  \e[38;5;27m│\e[0m  \e[38;5;196mFirefox DoH      ACTIVO — bypass posible\e[0m\n'
    fi

    if [[ -f "$DNS_PROXY_PID_FILE" ]] && kill -0 "$(cat "$DNS_PROXY_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        local _dpid; _dpid=$(cat "$DNS_PROXY_PID_FILE")
        printf "  \e[38;5;27m│\e[0m  \e[38;5;46mDNS proxy        PID=%-6s (127.0.0.1:53)\e[0m\n" "$_dpid"
    else
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240mDNS proxy        inactivo\e[0m\n'
    fi

    printf '  \e[38;5;27m├──────────────────────────────────────────┤\e[0m\n'
    printf "  \e[38;5;27m│\e[0m  WAN: \e[38;5;51m%-10s\e[0m  LAN: \e[38;5;51m%s\e[0m\n" \
        "${WAN_IFACE:-—}" "${LAN_IFACE:-—}"
    [[ -n "$MAC_BLOCKS_STR" ]] && \
        printf "  \e[38;5;27m│\e[0m  MACs: \e[38;5;214m%s\e[0m\n" "$MAC_BLOCKS_STR"
    [[ -n "$CONN_LIMITS_STR" ]] && \
        printf "  \e[38;5;27m│\e[0m  Limites: \e[38;5;214m%s\e[0m\n" "$CONN_LIMITS_STR"
    printf '  \e[38;5;27m╰──────────────────────────────────────────╯\e[0m\n\n'

    if iptables -L PM_WEBBLOCK -n 2>/dev/null | grep -q "target"; then
        printf '  \e[2mPM_WEBBLOCK:\e[0m\n'
        iptables -L PM_WEBBLOCK -n --line-numbers 2>/dev/null | sed 's/^/  /'
        printf '\n'
    fi
}

show_config_file() {
    clear
    printf '\n'
    printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[1mArchivo de Configuración del Firewall\e[0m\n'
    printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[38;5;226mRuta:\e[0m  \e[1m\e[38;5;51m%s\e[0m\n' "$CONFIG_FILE"
    printf '  \e[38;5;27m│\e[0m  \e[2mEste archivo reemplaza /etc/sysconfig/iptables como\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mfuente de verdad de la configuración del firewall.\e[0m\n'
    printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'

    if [[ ! -f "$CONFIG_FILE" ]]; then
        printf '  \e[38;5;196m[!]\e[0m  Archivo no encontrado. Activa el firewall primero.\n\n'
        return
    fi

    printf '  \e[38;5;239m%s\e[0m\n' "$(printf '%0.s─' $(seq 1 62))"
    while IFS='=' read -r _k _v; do
        [[ "$_k" =~ ^# || -z "$_k" ]] && continue
        printf '  \e[38;5;45m%-20s\e[0m\e[38;5;240m=\e[0m\e[38;5;220m%s\e[0m\n' "$_k" "$_v"
    done < "$CONFIG_FILE"
    printf '  \e[38;5;239m%s\e[0m\n\n' "$(printf '%0.s─' $(seq 1 62))"
    printf '  \e[2mVer en terminal: \e[0m\e[1mcat %s\e[0m\n\n' "$CONFIG_FILE"
}

show_logs() {
    printf '\n'
    printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[1mPASO 5 — Registro de Paquetes Bloqueados\e[0m\n'
    printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[38;5;226m¿Para qué sirve?\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mMuestra los paquetes rechazados por el firewall.\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mCada vez que iptables bloquea algo, el kernel escribe\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2muna línea "PM-DROP" en el log del sistema (journalctl).\e[0m\n'
    printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'
    printf '  \e[1m\e[38;5;51mLogs M-FIREWALL\e[0m\n'
    printf '  \e[38;5;239m%s\e[0m\n' "$(printf '%0.s─' $(seq 1 50))"
    if [[ -f "$LOG_FILE" ]]; then
        tail -30 "$LOG_FILE" | sed 's/^/  /'
    else
        printf '  \e[2mSin logs aún.\e[0m\n'
    fi
    printf '\n  \e[1m\e[38;5;51mKernel (PM-DROP últimas entradas)\e[0m\n'
    printf '  \e[38;5;239m%s\e[0m\n' "$(printf '%0.s─' $(seq 1 50))"
    if command -v journalctl &>/dev/null; then
        journalctl -k --no-pager --since "1 hour ago" 2>/dev/null \
            | grep "PM-DROP" | tail -15 | sed 's/^/  /' \
            || printf '  \e[2mSin entradas PM-DROP recientes.\e[0m\n'
    else
        dmesg 2>/dev/null | grep "PM-DROP" | tail -15 | sed 's/^/  /' \
            || printf '  \e[2mSin entradas PM-DROP.\e[0m\n'
    fi
    printf '\n'
}

# =============================================================================
# HELPERS UI
# =============================================================================
toggle_label() {
    [[ "$1" == "true" ]] \
        && printf '\e[38;5;46m✓ ACTIVO\e[0m' \
        || printf '\e[38;5;240m○ inactivo\e[0m'
}

toggle_var() {
    local var="$1"
    if [[ "${!var}" == "true" ]]; then
        printf -v "$var" '%s' "false"
        printf '  \e[38;5;214m→ Deshabilitado\e[0m\n'
    else
        printf -v "$var" '%s' "true"
        printf '  \e[38;5;46m→ Habilitado\e[0m\n'
    fi
}

# Mini-dashboard siempre visible sobre el menú principal
draw_mini_dashboard() {
    # Firewall realmente activo = regla OUTPUT -j PM_WEBBLOCK está enganchada
    local _fw_active=false
    iptables -C OUTPUT -j PM_WEBBLOCK 2>/dev/null && _fw_active=true

    printf '  \e[38;5;27m╭──────────────────────────────────────────────────────────────╮\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mESTADO  DEL  FIREWALL\e[0m'
    [[ "$_fw_active" == true ]] \
        && printf '  \e[38;5;46m● ACTIVO\e[0m\n' \
        || printf '  \e[38;5;240m○ inactivo\e[0m\n'

    local _sites=("Facebook:$BLOCK_FACEBOOK:PM_FACEBOOK"
                  "YouTube:$BLOCK_YOUTUBE:PM_YOUTUBE"
                  "Hotmail:$BLOCK_HOTMAIL:PM_HOTMAIL")
    for _s in "${_sites[@]}"; do
        IFS=':' read -r _sname _sstatus _sset <<< "$_s"
        if [[ "$_sstatus" == "true" && "$_fw_active" == true ]]; then
            local _scnt=0
            ipset list "$_sset" &>/dev/null && \
                _scnt=$(ipset list "$_sset" 2>/dev/null \
                        | grep -cE '^[0-9]+\.' 2>/dev/null || echo 0)
            printf "  \e[38;5;27m│\e[0m  \e[38;5;46m●\e[0m  %-10s  \e[38;5;46mBLOQUEADO\e[0m  \e[38;5;240m%-14s  %d IPs\e[0m\n" \
                "$_sname" "$_sset" "$_scnt"
        elif [[ "$_sstatus" == "true" ]]; then
            printf "  \e[38;5;27m│\e[0m  \e[38;5;214m◌  %-10s  seleccionado  \e[38;5;240m→ presiona 1 para activar\e[0m\n" "$_sname"
        else
            printf "  \e[38;5;27m│\e[0m  \e[38;5;240m○  %-10s  sin bloqueo\e[0m\n" "$_sname"
        fi
    done

    printf '  \e[38;5;27m│\e[0m  '
    if grep -q "$HOSTS_MARKER_START" /etc/hosts 2>/dev/null; then
        local _hc
        _hc=$(sed -n "/$HOSTS_MARKER_START/,/$HOSTS_MARKER_END/p" /etc/hosts \
              | grep -c "^0.0.0.0" 2>/dev/null || echo 0)
        printf '\e[38;5;46m●\e[0m  /etc/hosts %d entradas  ' "$_hc"
    else
        printf '\e[38;5;240m○  /etc/hosts inactivo    '
    fi
    local _ff=false
    for _ffd in "${FIREFOX_POLICY_DIRS[@]}"; do
        [[ -f "$_ffd/policies.json" ]] && _ff=true && break
    done
    [[ "$_ff" == true ]] \
        && printf '·  \e[38;5;46mFirefox DoH OFF\e[0m\n' \
        || printf '·  \e[38;5;196mFirefox DoH ACTIVO\e[0m\n'

    # DNS Proxy status
    printf '  \e[38;5;27m│\e[0m  '
    if [[ -f "$DNS_PROXY_PID_FILE" ]] && kill -0 "$(cat "$DNS_PROXY_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        local _dpid; _dpid=$(cat "$DNS_PROXY_PID_FILE")
        printf '\e[38;5;46m●\e[0m  DNS proxy activo  \e[38;5;240m(PID=%s · /etc/resolv.conf=127.0.0.1)\e[0m\n' "$_dpid"
    else
        printf '\e[38;5;240m○  DNS proxy inactivo\e[0m\n'
    fi

    printf '  \e[38;5;27m╰──────────────────────────────────────────────────────────────╯\e[0m\n'
    printf '\n'
}

# =============================================================================
# WIZARD ACTIVAR — selección de sitios + activación en un flujo
# =============================================================================
wizard_activate() {
    # Si el firewall no está activo, limpiar selección para que el wizard empiece desde cero
    if ! iptables -C OUTPUT -j PM_WEBBLOCK 2>/dev/null; then
        BLOCK_FACEBOOK="false"
        BLOCK_YOUTUBE="false"
        BLOCK_HOTMAIL="false"
    fi

    while true; do
        clear
        printf '\n'
        gradient_print "  ╭── PASO 2 — ACTIVAR FIREWALL  ·  Elige qué bloquear ─────────╮" GRAD[@] 0
        printf '\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;226m¿Para qué sirve?\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mActiva las reglas iptables en el kernel. Elige qué sitios\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mbloquear y el firewall aplica todas las capas automáticamente:\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mDNS, SNI, QUIC, IPv6, /etc/hosts y proxy DNS.\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────╮\e[0m\n'
        printf '  \e[38;5;27m│\e[0m\n'

        echo -e "  \e[38;5;27m│\e[0m  \e[38;5;51m1)\e[0m  Facebook    [$(toggle_label "$BLOCK_FACEBOOK")]"
        printf '  \e[38;5;27m│\e[0m      \e[38;5;240mfacebook.com · messenger.com · instagram.com · fbcdn.net\e[0m\n'
        printf '  \e[38;5;27m│\e[0m\n'

        echo -e "  \e[38;5;27m│\e[0m  \e[38;5;51m2)\e[0m  YouTube     [$(toggle_label "$BLOCK_YOUTUBE")]"
        printf '  \e[38;5;27m│\e[0m      \e[38;5;240myoutube.com · googlevideo.com · ytimg.com · youtu.be\e[0m\n'
        printf '  \e[38;5;27m│\e[0m\n'

        echo -e "  \e[38;5;27m│\e[0m  \e[38;5;51m3)\e[0m  Hotmail     [$(toggle_label "$BLOCK_HOTMAIL")]"
        printf '  \e[38;5;27m│\e[0m      \e[38;5;240moutlook.com · hotmail.com · microsoftonline.com · live.com\e[0m\n'
        printf '  \e[38;5;27m│\e[0m\n'

        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────\e[0m\n'
        printf '  \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46mA)\e[0m  \e[1mActivar con selección actual\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m0)\e[0m  Cancelar\n'
        printf '  \e[38;5;27m│\e[0m\n'
        gradient_print "  ╰──────────────────────────────────────────────────────────────╯" GRAD[@] 4
        printf '\n\n'

        read -rp "  Opción: " opt
        case "$opt" in
            1) toggle_var BLOCK_FACEBOOK; save_config ;;
            2) toggle_var BLOCK_YOUTUBE;  save_config ;;
            3) toggle_var BLOCK_HOTMAIL;  save_config ;;
            [Aa])
                local _any=false
                [[ "$BLOCK_FACEBOOK" == "true" || \
                   "$BLOCK_YOUTUBE"  == "true" || \
                   "$BLOCK_HOTMAIL"  == "true" ]] && _any=true
                if [[ "$_any" == false ]]; then
                    printf '\n  \e[33m[!]\e[0m  Selecciona al menos un sitio primero.\n'
                    sleep 1.2
                else
                    enable_firewall
                    return
                fi
                ;;
            0) return ;;
        esac
    done
}

# =============================================================================
# SUBMENÚS REDISEÑADOS
# =============================================================================
autodetect_interfaces() {
    # WAN = interfaz que tiene la ruta default hacia internet
    local _wan
    _wan=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    # LAN = primera interfaz que no sea lo ni WAN
    local _lan
    _lan=$(ip -o link show 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | grep -v '^lo$' \
        | grep -v "^${_wan}$" \
        | head -1)
    [[ -n "$_wan" ]] && WAN_IFACE="$_wan"
    [[ -n "$_lan" ]] && LAN_IFACE="$_lan"
}

menu_interfaces() {
    # Auto-detectar si están vacías
    if [[ -z "$WAN_IFACE" && -z "$LAN_IFACE" ]]; then
        autodetect_interfaces
        save_config
        local _auto=true
    fi

    while true; do
        clear
        printf '\n'
        printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[1mPASO 1 — Interfaces de Red  (WAN / LAN)\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;226m¿Para qué sirve?\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mEl firewall necesita saber cuál tarjeta de red es\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2minternet (WAN) y cuál conecta a los clientes (LAN).\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mSi tienes una sola tarjeta (eth0), será WAN y LAN.\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mInterfaces detectadas en este sistema:\e[0m\n'
        ip -o link show 2>/dev/null \
            | awk -F': ' '{printf "  \033[38;5;27m│\033[0m     \033[38;5;51m%-14s\033[0m\n", $2}' \
            | grep -v "lo$"
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        if [[ "${_auto}" == "true" ]]; then
            printf '  \e[38;5;27m│\e[0m  \e[38;5;46m✓ Auto-detectado\e[0m\n'
        fi
        printf "  \e[38;5;27m│\e[0m  WAN:  \e[1m\e[38;5;46m%-20s\e[0m  \e[2m(tarjeta hacia internet)\e[0m\n"  "${WAN_IFACE:-—}"
        printf "  \e[38;5;27m│\e[0m  LAN:  \e[1m\e[38;5;46m%-20s\e[0m  \e[2m(tarjeta hacia clientes)\e[0m\n" "${LAN_IFACE:-—}"
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46ma)\e[0m  Re-detectar automáticamente\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45mm)\e[0m  Cambiar manualmente\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;196mc)\e[0m  Limpiar (borrar WAN y LAN guardadas)\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m0)\e[0m  Volver al menú principal\n'
        printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'

        read -rp "  Opción: " _opt
        case "$_opt" in
            a|A)
                autodetect_interfaces
                save_config
                _auto=true
                printf '\n  \e[38;5;46m✓ Re-detectado  →  WAN: %s  |  LAN: %s\e[0m\n' \
                    "${WAN_IFACE:-—}" "${LAN_IFACE:-—}"
                sleep 1
                ;;
            m|M)
                _auto=false
                printf '\n'
                read -rp "  Nueva WAN (Enter = mantener '${WAN_IFACE:-—}'): " w
                read -rp "  Nueva LAN (Enter = mantener '${LAN_IFACE:-—}'): " l
                [[ -n "$w" ]] && WAN_IFACE="$w"
                [[ -n "$l" ]] && LAN_IFACE="$l"
                save_config
                printf '\n  \e[38;5;46m✓ Guardado  →  WAN: %s  |  LAN: %s\e[0m\n' \
                    "${WAN_IFACE:-—}" "${LAN_IFACE:-—}"
                sleep 1
                ;;
            c|C)
                WAN_IFACE=""
                LAN_IFACE=""
                _auto=false
                save_config
                printf '\n  \e[38;5;196m✓ WAN y LAN borradas.\e[0m\n'
                sleep 1
                ;;
            0) return ;;
        esac
    done
}

menu_mac() {
    while true; do
        clear
        printf '\n'
        printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[1mPASO 3 — Bloqueo por Dirección MAC\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;226m¿Para qué sirve?\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mBloquea equipos por su dirección MAC de hardware.\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2miptables lee la MAC del frame Ethernet (módulo xt_mac)\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2my rechaza todos sus paquetes en la cadena FORWARD.\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'

        if [[ -n "$MAC_BLOCKS_STR" ]]; then
            IFS=',' read -ra _macs <<< "$MAC_BLOCKS_STR"
            local i=1
            for mac in "${_macs[@]}"; do
                [[ -z "$mac" ]] && continue
                printf "  \e[38;5;27m│\e[0m  \e[38;5;196m[BLOQUEADA]\e[0m  \e[38;5;51m%s\e[0m\n" "$mac"
                printf "  \e[38;5;27m│\e[0m               \e[38;5;240miptables -m mac --mac-source %s -j REJECT\e[0m\n" "$mac"
                ((i++))
            done
        else
            printf '  \e[38;5;27m│\e[0m  \e[38;5;240m  Sin MACs configuradas. Agrega una con [a].\e[0m\n'
        fi

        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46ma)\e[0m  Agregar MAC   \e[38;5;196md)\e[0m  Eliminar MAC   \e[38;5;240m0)\e[0m  Volver\n'
        printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'

        read -rp "  Opción: " opt
        case "$opt" in
            a|A)
                clear
                printf '\n'
                printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
                printf '  \e[38;5;27m│\e[0m  \e[1mAgregar MAC — Equipos detectados en la red               \e[38;5;27m│\e[0m\n'
                printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
                printf '  \e[38;5;27m│\e[0m  %-4s  %-15s  %-19s  %-13s\e[38;5;27m│\e[0m\n' \
                    "#" "IP" "MAC" "FABRICANTE"

                # Detectar interfaz e IPs
                local _sf
                _sf=$(ip route get 1.1.1.1 2>/dev/null \
                    | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
                [[ -z "$_sf" ]] && _sf=$(ip -o link show | awk -F': ' '!/lo/{print $2}' | head -1)
                local _sown_ip _sown_mac
                _sown_ip=$(ip -4 addr show "$_sf" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
                _sown_mac=$(ip link show "$_sf" 2>/dev/null | awk '/ether/{print $2}')

                declare -a _scan_devs=()
                [[ -n "$_sown_ip" ]] && _scan_devs+=("$_sown_ip|${_sown_mac}|este equipo (Kali)")

                if command -v arp-scan &>/dev/null; then
                    while IFS=$'\t' read -r _sip _smac _sven; do
                        [[ "$_sip" =~ ^[0-9]+\.[0-9]+ ]] || continue
                        [[ "$_sip" == "$_sown_ip" ]] && continue
                        _scan_devs+=("$_sip|$_smac|${_sven:-desconocido}")
                    done < <(arp-scan --interface="$_sf" --localnet 2>/dev/null \
                             | grep -E '^[0-9]+\.[0-9]+')
                fi
                while read -r _sip _ _ _smac _; do
                    [[ "$_sip" =~ ^[0-9]+\.[0-9]+ ]] || continue
                    [[ "$_sip" == "$_sown_ip" ]] && continue
                    local _sd=false
                    for _ex in "${_scan_devs[@]}"; do
                        [[ "${_ex%%|*}" == "$_sip" ]] && _sd=true && break
                    done
                    [[ "$_sd" == false ]] && _scan_devs+=("$_sip|${_smac:-??:??:??:??:??:??}|ARP cache")
                done < <(ip neigh show dev "$_sf" 2>/dev/null \
                         | awk '$4~/lladdr/{print $1,"dev",$3,"lladdr",$5,$6}')

                printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
                if [[ ${#_scan_devs[@]} -eq 0 ]]; then
                    printf '  \e[38;5;27m│\e[0m  \e[38;5;240m  Sin dispositivos detectados.                            \e[38;5;27m│\e[0m\n'
                else
                    local _si=0
                    for _sd in "${_scan_devs[@]}"; do
                        IFS='|' read -r _sdip _sdmac _sdven <<< "$_sd"
                        local _sdven_s="${_sdven:0:13}"
                        if [[ "$_sdip" == "$_sown_ip" ]]; then
                            printf "  \e[38;5;27m│\e[0m  \e[38;5;240m%-4s\e[0m  \e[38;5;51m%-15s\e[0m  \e[38;5;220m%-19s\e[0m  \e[38;5;240m%-13s\e[38;5;27m│\e[0m\n" \
                                "${_si})" "$_sdip" "$_sdmac" "$_sdven_s"
                        else
                            printf "  \e[38;5;27m│\e[0m  \e[38;5;46m%-4s\e[0m  \e[38;5;51m%-15s\e[0m  \e[38;5;214m%-19s\e[0m  \e[38;5;240m%-13s\e[38;5;27m│\e[0m\n" \
                                "${_si})" "$_sdip" "$_sdmac" "$_sdven_s"
                        fi
                        (( _si++ ))
                    done
                fi
                printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'

                read -rp "  Número para bloquear (o escribe MAC manual, 0=cancelar): " _msel
                local mac=""
                if [[ "$_msel" == "0" ]]; then
                    unset _scan_devs; continue
                elif [[ "$_msel" =~ ^[0-9]+$ && "$_msel" -lt "${#_scan_devs[@]}" ]]; then
                    IFS='|' read -r _ mac _ <<< "${_scan_devs[$_msel]}"
                elif [[ "$_msel" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                    mac="$_msel"
                fi
                unset _scan_devs

                if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                    MAC_BLOCKS_STR="${MAC_BLOCKS_STR:+${MAC_BLOCKS_STR},}${mac}"
                    save_config
                    printf '\n  \e[38;5;46m✓\e[0m  MAC \e[1m%s\e[0m agregada. Activa el firewall para aplicar.\n' "$mac"
                    sleep 1.5
                else
                    printf '\n  \e[31m✗\e[0m  Selección inválida.\n'
                    sleep 1.2
                fi
                ;;
            d|D)
                if [[ -z "$MAC_BLOCKS_STR" ]]; then
                    printf '\n  \e[33mNo hay MACs para eliminar.\e[0m\n'; sleep 1; continue
                fi
                clear
                printf '\n  \e[1mEliminar MAC — elige el número:\e[0m\n\n'
                IFS=',' read -ra _del_macs <<< "$MAC_BLOCKS_STR"
                local _di=1
                for _dm in "${_del_macs[@]}"; do
                    [[ -z "$_dm" ]] && continue
                    printf '  \e[38;5;196m%d)\e[0m  %s\n' "$_di" "$_dm"
                    (( _di++ ))
                done
                printf '\n'
                read -rp "  Número (0 para cancelar): " _dsel
                if [[ "$_dsel" =~ ^[0-9]+$ && "$_dsel" -gt 0 && "$_dsel" -lt "$_di" ]]; then
                    local _target_mac="${_del_macs[$(( _dsel - 1 ))]}"
                    MAC_BLOCKS_STR=$(tr ',' '\n' <<< "$MAC_BLOCKS_STR" \
                        | grep -vi "^${_target_mac}$" | tr '\n' ',' | sed 's/,$//')
                    save_config
                    printf '  \e[38;5;46m✓\e[0m  Eliminada: %s\n' "$_target_mac"
                    sleep 0.8
                fi
                ;;
            0) break ;;
        esac
    done
}

menu_connlimit() {
    while true; do
        clear
        printf '\n'
        printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[1mPASO 4 — Límite de Conexiones Simultáneas                \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;226m¿Para qué sirve?\e[0m                                        \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mLimita cuántas conexiones simultáneas puede abrir cada IP\e[0m \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mhacia un puerto. El kernel cuenta con conntrack — si       \e[0m \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2msupera el límite, el paquete nuevo se rechaza.            \e[0m \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  %-6s  %-6s  %-5s  %-16s  %-10s \e[38;5;27m│\e[0m\n' \
            "PROTO" "PUERTO" "MAX" "IP OBJETIVO" "REGLA"
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'

        if [[ -n "$CONN_LIMITS_STR" ]]; then
            IFS=',' read -ra _limits <<< "$CONN_LIMITS_STR"
            for entry in "${_limits[@]}"; do
                [[ -z "$entry" ]] && continue
                IFS=':' read -r _p _port _max _ip <<< "$entry"
                local _target="${_ip:-todos}"
                printf "  \e[38;5;27m│\e[0m  \e[38;5;214m●\e[0m \e[38;5;51m%-5s\e[0m  %-6s  \e[1m%-5s\e[0m  \e[38;5;214m%-16s\e[0m \e[38;5;27m│\e[0m\n" \
                    "$_p" "$_port" "$_max" "$_target"
                printf "  \e[38;5;27m│\e[0m    \e[38;5;240m-m connlimit --connlimit-above %-3s --connlimit-mask 32 \e[38;5;27m│\e[0m\n" "$_max"
            done
        else
            printf '  \e[38;5;27m│\e[0m  \e[38;5;240m  Sin límites. [a] para agregar.                          \e[38;5;27m│\e[0m\n'
        fi

        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46ma)\e[0m Agregar  \e[38;5;196md)\e[0m Eliminar  \e[38;5;240m0)\e[0m Volver              \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'

        read -rp "  Opción: " opt
        case "$opt" in
            a|A)
                clear
                printf '\n'
                printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
                printf '  \e[38;5;27m│\e[0m  \e[1mAgregar límite de conexiones                             \e[38;5;27m│\e[0m\n'
                printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'

                printf '  \e[38;5;51m[1]\e[0m  Protocolo\n'
                printf '  \e[38;5;240m      tcp → HTTP, HTTPS, SSH\e[0m\n'
                printf '  \e[38;5;240m      udp → DNS, streaming\e[0m\n'
                read -rp "  tcp/udp: " proto

                printf '\n  \e[38;5;51m[2]\e[0m  Puerto de destino\n'
                printf '  \e[38;5;240m      80=HTTP  443=HTTPS  22=SSH  53=DNS\e[0m\n'
                read -rp "  Puerto: " port

                printf '\n  \e[38;5;51m[3]\e[0m  Máximo de conexiones simultáneas por IP\n'
                printf '  \e[38;5;240m      Sugerido: 50 HTTPS · 10 SSH · 5 para restringir fuerte\e[0m\n'
                read -rp "  Máximo: " max

                printf '\n  \e[38;5;51m[4]\e[0m  IP objetivo — equipos conectados ahora:\n'
                printf '  \e[38;5;240m      Escaneando red...\e[0m\n'

                # Escaneo inline igual que menu_scan_network
                local _cl_iface
                _cl_iface=$(ip route get 1.1.1.1 2>/dev/null \
                    | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
                [[ -z "$_cl_iface" ]] && _cl_iface=$(ip -o link show \
                    | awk -F': ' '!/lo/{print $2}' | head -1)

                local _cl_own_mac _cl_own_ip
                _cl_own_mac=$(ip link show "$_cl_iface" 2>/dev/null | awk '/ether/{print $2}')
                _cl_own_ip=$(ip -4 addr show "$_cl_iface" 2>/dev/null \
                    | awk '/inet /{print $2}' | cut -d/ -f1)

                declare -a _cl_ips _cl_macs _cl_vens
                # propia máquina
                _cl_ips+=("$_cl_own_ip")
                _cl_macs+=("$_cl_own_mac")
                _cl_vens+=("este equipo (Kali)")

                # arp-scan
                if command -v arp-scan &>/dev/null; then
                    while IFS=$'\t' read -r _cip _cmac _cven; do
                        [[ "$_cmac" == "$_cl_own_mac" ]] && continue
                        _cl_ips+=("$_cip"); _cl_macs+=("$_cmac")
                        _cl_vens+=("${_cven:-desconocido}")
                    done < <(arp-scan --interface="$_cl_iface" --localnet 2>/dev/null \
                        | awk '/^[0-9]/{print $1"\t"$2"\t"$3}')
                fi
                # ip neigh fallback
                while IFS=' ' read -r _nip _ _ _ _nmac _; do
                    [[ -z "$_nmac" || "$_nmac" == "FAILED" ]] && continue
                    local _already=false
                    for _x in "${_cl_macs[@]}"; do [[ "$_x" == "$_nmac" ]] && _already=true; done
                    $_already && continue
                    _cl_ips+=("$_nip"); _cl_macs+=("$_nmac"); _cl_vens+=("vecino ARP")
                done < <(ip neigh show 2>/dev/null | grep -v "^$_cl_own_ip ")

                printf '\n'
                printf '  \e[38;5;27m╭──────┬──────────────────┬───────────────────────╮\e[0m\n'
                printf '  \e[38;5;27m│\e[0m  \e[1m%-3s\e[0m \e[38;5;27m│\e[0m  \e[1m%-16s\e[0m \e[38;5;27m│\e[0m  \e[1m%-21s\e[0m \e[38;5;27m│\e[0m\n' \
                    "#" "IP" "DISPOSITIVO"
                printf '  \e[38;5;27m├──────┼──────────────────┼───────────────────────┤\e[0m\n'
                local _ci
                for (( _ci=0; _ci<${#_cl_ips[@]}; _ci++ )); do
                    local _cven_s="${_cl_vens[$_ci]:0:21}"
                    printf '  \e[38;5;27m│\e[0m  \e[38;5;214m%-3d\e[0m \e[38;5;27m│\e[0m  \e[38;5;51m%-16s\e[0m \e[38;5;27m│\e[0m  %-21s \e[38;5;27m│\e[0m\n' \
                        $(( _ci+1 )) "${_cl_ips[$_ci]}" "$_cven_s"
                done
                printf '  \e[38;5;27m│\e[0m  \e[38;5;46m  0\e[0m \e[38;5;27m│\e[0m  \e[38;5;46m%-16s\e[0m \e[38;5;27m│\e[0m  %-21s \e[38;5;27m│\e[0m\n' \
                    "todos" "limitar a TODOS"
                printf '  \e[38;5;27m╰──────┴──────────────────┴───────────────────────╯\e[0m\n\n'

                local target_ip=""
                read -rp "  Número (0 = todos, o escribe IP manual): " _csel
                if [[ "$_csel" == "0" || -z "$_csel" ]]; then
                    target_ip=""
                elif [[ "$_csel" =~ ^[0-9]+$ ]] && (( _csel >= 1 && _csel <= ${#_cl_ips[@]} )); then
                    target_ip="${_cl_ips[$(( _csel-1 ))]}"
                    printf '  \e[38;5;46m✓ Seleccionado:\e[0m  %s  (%s)\n' \
                        "$target_ip" "${_cl_vens[$(( _csel-1 ))]}"
                else
                    # input manual
                    target_ip="$_csel"
                fi

                if [[ "$proto" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
                    local _entry="${proto}:${port}:${max}"
                    [[ -n "$target_ip" ]] && _entry="${_entry}:${target_ip}"
                    CONN_LIMITS_STR="${CONN_LIMITS_STR:+${CONN_LIMITS_STR},}${_entry}"
                    save_config
                    printf '\n  \e[38;5;46m✓ Guardado:\e[0m  %s puerto %s  máx %s  destino: %s\n' \
                        "$proto" "$port" "$max" "${target_ip:-todos los clientes}"
                    sleep 1.8
                else
                    printf '\n  \e[31m✗ Error:\e[0m protocolo tcp/udp, puerto y máximo deben ser números.\n'
                    sleep 2
                fi
                ;;
            d|D)
                if [[ -z "$CONN_LIMITS_STR" ]]; then
                    printf '\n  \e[33mNo hay límites para eliminar.\e[0m\n'; sleep 1; continue
                fi
                clear
                printf '\n  \e[1mEliminar límite — elige el número:\e[0m\n\n'
                IFS=',' read -ra _del_limits <<< "$CONN_LIMITS_STR"
                local _li=1
                for _dl in "${_del_limits[@]}"; do
                    [[ -z "$_dl" ]] && continue
                    IFS=':' read -r _dlp _dlport _dlmax _dlip <<< "$_dl"
                    printf '  \e[38;5;196m%d)\e[0m  %-4s  puerto %-6s  max %-4s  IP: %s\n' \
                        "$_li" "$_dlp" "$_dlport" "$_dlmax" "${_dlip:-todos}"
                    (( _li++ ))
                done
                printf '\n'
                read -rp "  Número (0 para cancelar): " _lsel
                if [[ "$_lsel" =~ ^[0-9]+$ && "$_lsel" -gt 0 && "$_lsel" -lt "$_li" ]]; then
                    local _target_limit="${_del_limits[$(( _lsel - 1 ))]}"
                    CONN_LIMITS_STR=$(tr ',' '\n' <<< "$CONN_LIMITS_STR" \
                        | grep -v "^${_target_limit}$" | tr '\n' ',' | sed 's/,$//')
                    save_config
                    printf '  \e[38;5;46m✓\e[0m  Eliminado: %s\n' "$_target_limit"
                    sleep 0.8
                fi
                ;;
            0) break ;;
        esac
    done
}

# =============================================================================
# ESCANEO DE RED: detecta equipos con IP + MAC para bloquear
# =============================================================================
menu_scan_network() {
    while true; do
        clear
        printf '\n'
        printf '  \e[38;5;27m╭──────────────────────────────────────────────────────────────╮\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[1mPASO 6 — Escaneo de Red Local\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;226m¿Para qué sirve?\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mDetecta todos los equipos conectados a tu red con su IP\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2my MAC. Desde aquí puedes bloquearlos o limitarlos sin\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mescribir nada manualmente — solo elige del listado.\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mEscaneando...\e[0m\n'

        # Detectar interfaz activa
        local _iface
        _iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        [[ -z "$_iface" ]] && _iface=$(ip -o link show | awk -F': ' '!/lo/{print $2}' | head -1)

        # MAC e IP propias
        local _own_mac _own_ip
        _own_mac=$(ip link show "$_iface" 2>/dev/null | awk '/ether/{print $2}')
        _own_ip=$(ip -4 addr show "$_iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)

        # Red local en CIDR
        local _net
        _net=$(ip -4 addr show "$_iface" 2>/dev/null \
               | awk '/inet /{print $2}' \
               | head -1)

        # Construir tabla de dispositivos: "IP MAC VENDOR"
        declare -a _devs=()

        # Agregar el propio equipo primero
        [[ -n "$_own_ip" && -n "$_own_mac" ]] && \
            _devs+=("$_own_ip|$_own_mac|este equipo (Kali)")

        # Intentar arp-scan si está disponible
        if command -v arp-scan &>/dev/null; then
            while IFS=$'\t' read -r _ip _mac _vendor; do
                [[ "$_ip" =~ ^[0-9]+\.[0-9]+ ]] || continue
                [[ "$_ip" == "$_own_ip" ]]       && continue
                _devs+=("$_ip|$_mac|${_vendor:-desconocido}")
            done < <(arp-scan --interface="$_iface" --localnet 2>/dev/null \
                     | grep -E '^[0-9]+\.[0-9]+')
        fi

        # Siempre agregar tabla ARP del kernel (sin duplicar)
        while read -r _ip _ _ _mac _; do
            [[ "$_ip" =~ ^[0-9]+\.[0-9]+ ]] || continue
            [[ "$_ip" == "$_own_ip" ]]       && continue
            local _dup=false
            for _d in "${_devs[@]}"; do
                [[ "${_d%%|*}" == "$_ip" ]] && _dup=true && break
            done
            [[ "$_dup" == false ]] && _devs+=("$_ip|${_mac:-??:??:??:??:??:??}|ARP cache")
        done < <(ip neigh show dev "$_iface" 2>/dev/null \
                 | awk '$4~/lladdr/{print $1,"dev",$3,"lladdr",$5,$6}')

        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  %-4s  %-15s  %-19s  %-13s\e[38;5;27m│\e[0m\n' \
            "#" "IP" "MAC" "FABRICANTE"
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'

        if [[ ${#_devs[@]} -eq 0 ]]; then
            printf '  \e[38;5;27m│\e[0m  \e[38;5;240m  Sin dispositivos detectados en la red.\e[0m\n'
            printf '  \e[38;5;27m│\e[0m  \e[38;5;240m  Asegurate de estar conectado a una red local.\e[0m\n'
        else
            local _i=0
            for _d in "${_devs[@]}"; do
                IFS='|' read -r _dip _dmac _dven <<< "$_d"
                local _dven_s="${_dven:0:13}"
                if [[ "$_dip" == "$_own_ip" ]]; then
                    printf "  \e[38;5;27m│\e[0m  \e[38;5;240m%-4s\e[0m  \e[38;5;51m%-15s\e[0m  \e[38;5;220m%-19s\e[0m  \e[38;5;240m%-13s\e[38;5;27m│\e[0m\n" \
                        "${_i})" "$_dip" "$_dmac" "$_dven_s"
                else
                    printf "  \e[38;5;27m│\e[0m  \e[38;5;46m%-4s\e[0m  \e[38;5;51m%-15s\e[0m  \e[38;5;214m%-19s\e[0m  \e[38;5;240m%-13s\e[38;5;27m│\e[0m\n" \
                        "${_i})" "$_dip" "$_dmac" "$_dven_s"
                fi
                (( _i++ ))
            done
        fi

        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  Ingresa el numero del equipo para ver opciones de bloqueo   \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45mr)\e[0m Reescanear   \e[38;5;240m0)\e[0m Volver                              \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m╰──────────────────────────────────────────────────────────────╯\e[0m\n'
        printf '\n'

        read -rp "  Selecciona equipo [numero / r / 0]: " _sel

        case "$_sel" in
            r|R) unset _devs; continue ;;
            0)   return ;;
            *[!0-9]*)
                printf '  \e[33m[!]\e[0m Opcion invalida.\n'; sleep 0.8 ;;
            *)
                local _idx="$_sel"
                if (( _idx < ${#_devs[@]} )); then
                    IFS='|' read -r _bip _bmac _bven <<< "${_devs[$_idx]}"

                    # Submenú de accion para el equipo seleccionado
                    clear
                    printf '\n'
                    printf '  \e[38;5;27m╭──────────────────────────────────────────────────────────────╮\e[0m\n'
                    printf '  \e[38;5;27m│\e[0m  Equipo seleccionado                                          \e[38;5;27m│\e[0m\n'
                    printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
                    printf "  \e[38;5;27m│\e[0m  IP:   \e[38;5;51m%-52s\e[38;5;27m│\e[0m\n" "$_bip"
                    printf "  \e[38;5;27m│\e[0m  MAC:  \e[38;5;214m%-52s\e[38;5;27m│\e[0m\n" "$_bmac"
                    printf "  \e[38;5;27m│\e[0m  ID:   \e[38;5;240m%-52s\e[38;5;27m│\e[0m\n" "$_bven"
                    printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
                    printf '  \e[38;5;27m│\e[0m  Que quieres hacer con este equipo?                          \e[38;5;27m│\e[0m\n'
                    printf '  \e[38;5;27m│\e[0m                                                              \e[38;5;27m│\e[0m\n'
                    printf '  \e[38;5;27m│\e[0m  \e[38;5;196m1)\e[0m  Bloquear MAC (corta TODO su trafico)                  \e[38;5;27m│\e[0m\n'
                    printf '  \e[38;5;27m│\e[0m  \e[38;5;214m2)\e[0m  Limitar conexiones (max N por puerto)                  \e[38;5;27m│\e[0m\n'
                    printf '  \e[38;5;27m│\e[0m  \e[38;5;46m3)\e[0m  Ambos (bloquear MAC + limitar conexiones)              \e[38;5;27m│\e[0m\n'
                    printf '  \e[38;5;27m│\e[0m  \e[38;5;240m0)\e[0m  Cancelar                                              \e[38;5;27m│\e[0m\n'
                    printf '  \e[38;5;27m╰──────────────────────────────────────────────────────────────╯\e[0m\n\n'
                    read -rp "  Accion: " _action

                    # — Bloqueo MAC —
                    _do_mac=false
                    _do_limit=false
                    case "$_action" in
                        1) _do_mac=true ;;
                        2) _do_limit=true ;;
                        3) _do_mac=true; _do_limit=true ;;
                        0) unset _devs; continue ;;
                    esac

                    if [[ "$_do_mac" == true ]]; then
                        local _mac_exists=false
                        IFS=',' read -ra _cur <<< "$MAC_BLOCKS_STR"
                        for _m in "${_cur[@]}"; do
                            [[ "${_m,,}" == "${_bmac,,}" ]] && _mac_exists=true && break
                        done
                        if [[ "$_mac_exists" == true ]]; then
                            printf '\n  \e[33m[!]\e[0m  MAC %s ya estaba bloqueada.\n' "$_bmac"
                        else
                            MAC_BLOCKS_STR="${MAC_BLOCKS_STR:+${MAC_BLOCKS_STR},}${_bmac}"
                            save_config
                            printf '\n  \e[38;5;46m[+]\e[0m  MAC \e[1m%s\e[0m bloqueada.\n' "$_bmac"
                        fi
                    fi

                    # — Limite de conexiones para esa IP —
                    if [[ "$_do_limit" == true ]]; then
                        printf '\n  \e[38;5;51m[Limite]\e[0m  Protocolo (tcp/udp): '
                        read -r _lp
                        printf '  \e[38;5;51m[Limite]\e[0m  Puerto de destino:   '
                        read -r _lport
                        printf '  \e[38;5;51m[Limite]\e[0m  Max conexiones:      '
                        read -r _lmax
                        if [[ "$_lp" =~ ^(tcp|udp)$ && "$_lport" =~ ^[0-9]+$ && "$_lmax" =~ ^[0-9]+$ ]]; then
                            CONN_LIMITS_STR="${CONN_LIMITS_STR:+${CONN_LIMITS_STR},}${_lp}:${_lport}:${_lmax}:${_bip}"
                            save_config
                            printf '  \e[38;5;46m[+]\e[0m  Limite %s/%s max=%s aplicado solo a %s\n' \
                                "$_lp" "$_lport" "$_lmax" "$_bip"
                        else
                            printf '  \e[31m✗\e[0m  Datos invalidos.\n'
                        fi
                    fi

                    printf '\n  \e[2mActiva el firewall (opcion 1) para aplicar los cambios.\e[0m\n'
                    sleep 2
                else
                    printf '  \e[33m[!]\e[0m Numero fuera de rango.\n'; sleep 0.8
                fi
                ;;
        esac
        unset _devs
    done
}

# =============================================================================
# MENÚ PRINCIPAL
# =============================================================================
main_menu() {
    if [[ "$FIRST_DRAW" == true ]]; then
        clear
        boot_spinner &
        local _bpid=$!
        load_config
        # Validar que WAN/LAN guardadas sean interfaces reales; si no, limpiar y auto-detectar
        local _ifaces
        _ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}')
        if [[ -n "$WAN_IFACE" ]] && ! grep -qw "$WAN_IFACE" <<< "$_ifaces"; then
            WAN_IFACE=""
        fi
        if [[ -n "$LAN_IFACE" ]] && ! grep -qw "$LAN_IFACE" <<< "$_ifaces"; then
            LAN_IFACE=""
        fi
        if [[ -z "$WAN_IFACE" || -z "$LAN_IFACE" ]]; then
            autodetect_interfaces
            save_config
        fi
        sleep 0.6
        kill "$_bpid" 2>/dev/null; wait "$_bpid" 2>/dev/null
        printf '\r%*s\r' "$(tput cols)" ""
        draw_banner_animated
        FIRST_DRAW=false
    fi

    while true; do
        clear
        draw_banner_static
        draw_mini_dashboard

        printf '  \e[38;5;27m╭──────────────────────────────────────────────────────────────╮\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m Sigue los pasos en orden para completar la demo            \e[38;5;27m│\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m[1]\e[0m  \e[1mPASO 1\e[0m  \e[38;5;240m—\e[0m  Configurar interfaces  \e[38;5;240mWAN / LAN\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46m[2]\e[0m  \e[1mPASO 2\e[0m  \e[38;5;240m—\e[0m  \e[1mActivar Firewall\e[0m  \e[38;5;240m(elegir sitios a bloquear)\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m[3]\e[0m  \e[1mPASO 3\e[0m  \e[38;5;240m—\e[0m  Bloqueo por MAC address\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m[4]\e[0m  \e[1mPASO 4\e[0m  \e[38;5;240m—\e[0m  Límite de conexiones simultáneas\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;39m[5]\e[0m  \e[1mPASO 5\e[0m  \e[38;5;240m—\e[0m  Ver registro de paquetes  \e[38;5;240m(logs PM-DROP)\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m[6]\e[0m  \e[1mPASO 6\e[0m  \e[38;5;240m—\e[0m  Escanear red y bloquear equipos\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;39m[7]\e[0m  \e[1mPASO 7\e[0m  \e[38;5;240m—\e[0m  Dashboard en vivo  \e[38;5;240m[q] para salir\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;220m[c]\e[0m  Ver \e[38;5;51m%s\e[0m\n' "$CONFIG_FILE"
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;196m[8]\e[0m  Desactivar Firewall   \e[38;5;240m│\e[0m  \e[38;5;196m[9]\e[0m  Reset total de red\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m[0]\e[0m  Salir\n'
        printf '  \e[38;5;27m╰──────────────────────────────────────────────────────────────╯\e[0m\n'
        printf '\n'

        read -rp "  Opción: " choice

        case "$choice" in
            1) menu_interfaces ;;
            2) wizard_activate;  read -rp $'\n  Presiona Enter para volver al menú...' ;;
            3) menu_mac ;;
            4) menu_connlimit ;;
            5) show_logs;        read -rp $'\n  Presiona Enter...' ;;
            6) menu_scan_network ;;
            7) show_dashboard ;;
            c|C) show_config_file; read -rp $'\n  Presiona Enter para volver al menú...' ;;
            8) disable_firewall; read -rp $'\n  Presiona Enter para volver al menú...' ;;
            9) deep_reset;       read -rp $'\n  Presiona Enter...' ;;
            0) printf '\n'; gradient_print "  Hasta luego." GRAD[@] 0; printf '\n\n'; exit 0 ;;
            *) printf '  \e[31mOpción inválida.\e[0m\n'; sleep 0.8 ;;
        esac
    done
}

# =============================================================================
# ENTRADA
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    printf '\e[31m[ERROR]\e[0m Requiere root: \e[1msudo %s\e[0m\n' "$0"
    exit 1
fi

missing=()
for dep in iptables ipset dig ip; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    printf '\e[31m[ERROR]\e[0m Dependencias faltantes: %s\n' "${missing[*]}"
    printf '  Instala: \e[1mapt install %s\e[0m\n' "${missing[*]}"
    exit 1
fi

mkdir -p "$CONFIG_DIR"
touch "$LOG_FILE" 2>/dev/null || true

main_menu
