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
    tput civis
    printf '\n'
    local offset=0
    for line in "${B[@]}"; do
        gradient_print "$line" GRAD[@] $offset
        printf '\n'
        (( offset += 2 ))
        sleep 0.055
    done
    tput cnorm
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
    local cols rows
    cols=$(tput cols 2>/dev/null || echo 80)
    rows=$(tput lines 2>/dev/null || echo 24)
    tput civis
    local i
    for ((i=0; i<rows; i+=2)); do
        tput cup $i 0
        printf '\e[48;5;17m%*s\e[0m' "$cols" ""
        sleep 0.006
    done
    sleep 0.04
    clear
    tput cnorm
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
        local F=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local f=0
        while true; do
            printf "\r  \e[38;5;39m[%d/%d]\e[0m \e[38;5;51m%s\e[0m %s  " \
                "$step_n" "$total" "${F[$f]}" "$msg"
            f=$(( (f + 1) % ${#F[@]} ))
            sleep 0.075
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
    "DNSOverHTTPS": { "Enabled": false, "Locked": true }
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
# IPTABLES BASE
# =============================================================================
setup_base_chains() {
    logsec "Cadenas iptables + ip6tables"
    # Módulo de string matching (SNI)
    modprobe xt_string 2>/dev/null || true

    # ── IPv4 ────────────────────────────────────────────────────────────────────
    for chain in PM_REJECT PM_WEBBLOCK PM_MACBLOCK PM_CONNLIMIT; do
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    done
    cmd iptables -t nat -F PREROUTING 2>/dev/null || true
    cmd iptables -t nat -F OUTPUT     2>/dev/null || true
    iptables -D FORWARD -j PM_MACBLOCK  2>/dev/null || true
    iptables -D FORWARD -j PM_CONNLIMIT 2>/dev/null || true
    iptables -D FORWARD -j PM_WEBBLOCK  2>/dev/null || true
    iptables -D OUTPUT  -j PM_WEBBLOCK  2>/dev/null || true
    # Permitir respuestas de conexiones establecidas en FORWARD (server→client)
    iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    cmd iptables -N PM_REJECT
    cmd iptables -N PM_WEBBLOCK
    cmd iptables -N PM_MACBLOCK
    cmd iptables -N PM_CONNLIMIT
    cmd iptables -A PM_REJECT -j LOG --log-prefix "PM-DROP: " --log-level 4
    cmd iptables -A PM_REJECT -p tcp -j REJECT --reject-with tcp-reset
    cmd iptables -A PM_REJECT -j REJECT --reject-with icmp-port-unreachable
    # ESTABLISHED/RELATED primero — tráfico servidor→cliente (respuestas) siempre pasa
    cmd iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    cmd iptables -A FORWARD -j PM_MACBLOCK
    cmd iptables -A FORWARD -j PM_CONNLIMIT
    cmd iptables -A FORWARD -j PM_WEBBLOCK
    cmd iptables -A OUTPUT  -j PM_WEBBLOCK

    # ── IPv6 — misma estructura para bloquear bypass por AAAA records ───────────
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
    # Limpiar conexiones activas para que las reglas apliquen inmediatamente
    conntrack -F 2>/dev/null || true
    logc "Cadenas IPv4+IPv6 configuradas — ESTABLISHED/RELATED permitido (server->client)"
}

# =============================================================================
# DNS WIRE-PROTOCOL BLOCKING — bloquea queries DNS antes de que el browser
# reciba la IP. Hex-string coincide con la codificación DNS del dominio:
# "youtube.com" → \x07youtube\x03com (longitud + etiqueta + longitud + etiqueta)
# Esto atrapa browsers que bypassean /etc/hosts pero no pueden bypassear el kernel.
# =============================================================================
apply_dns_block() {
    logsec "DNS hex-string blocking (port 53)"
    # Patrones hex para cada sitio (longitud en hex + label ASCII)
    local _dns_rules=()

    if [[ "$BLOCK_FACEBOOK" == "true" ]]; then
        _dns_rules+=("|08|facebook|03|com")
        _dns_rules+=("|05|fbcdn|03|net")
        _dns_rules+=("|09|messenger|03|com")
        _dns_rules+=("|09|instagram|03|com")
    fi
    if [[ "$BLOCK_YOUTUBE" == "true" ]]; then
        _dns_rules+=("|07|youtube|03|com")
        _dns_rules+=("|0b|googlevideo|03|com")
        _dns_rules+=("|05|ytimg|03|com")
        _dns_rules+=("|06|youtu|02|be")
    fi
    if [[ "$BLOCK_HOTMAIL" == "true" ]]; then
        _dns_rules+=("|07|hotmail|03|com")
        _dns_rules+=("|07|outlook|03|com")
        _dns_rules+=("|0f|microsoftonline|03|com")
        _dns_rules+=("|04|live|03|com")
    fi

    local _hex
    for _hex in "${_dns_rules[@]}"; do
        # OUTPUT: DNS del propio servidor/máquina
        cmd iptables -A PM_WEBBLOCK -p udp --dport 53 \
            -m string --hex-string "$_hex" --algo bm -j PM_REJECT
        cmd iptables -A PM_WEBBLOCK -p tcp --dport 53 \
            -m string --hex-string "$_hex" --algo bm -j PM_REJECT
    done
    logc "DNS blocking: ${#_dns_rules[@]} patrones en port 53"
}

# =============================================================================
# SNI BLOCKING — coincide con nombre de dominio en TLS ClientHello (texto plano)
# Funciona aunque las IPs de YouTube roten en Anycast de Google
# =============================================================================
apply_sni_rules() {
    logsec "SNI string-match blocking"
    local sni_fb=("facebook.com" "fbcdn.net" "fbsbx.com" "messenger.com")
    local sni_yt=("youtube.com" "googlevideo.com" "ytimg.com" "youtu.be" "youtube-nocookie.com")
    local sni_hm=("hotmail.com" "outlook.com" "microsoftonline.com" "live.com")

    local domain
    if [[ "$BLOCK_FACEBOOK" == "true" ]]; then
        for domain in "${sni_fb[@]}"; do
            cmd iptables  -A PM_WEBBLOCK -p tcp --dport 443 \
                -m string --string "$domain" --algo bm -j PM_REJECT
            cmd iptables  -A PM_WEBBLOCK -p tcp --dport 80  \
                -m string --string "$domain" --algo bm -j PM_REJECT
            ip6tables -A PM_WEBBLOCK -p tcp --dport 443 \
                -m string --string "$domain" --algo bm -j REJECT 2>/dev/null || true
            ip6tables -A PM_WEBBLOCK -p tcp --dport 80  \
                -m string --string "$domain" --algo bm -j REJECT 2>/dev/null || true
        done
        logc "Facebook SNI: ${#sni_fb[@]} dominios (IPv4+IPv6)"
    fi
    if [[ "$BLOCK_YOUTUBE" == "true" ]]; then
        for domain in "${sni_yt[@]}"; do
            cmd iptables  -A PM_WEBBLOCK -p tcp --dport 443 \
                -m string --string "$domain" --algo bm -j PM_REJECT
            cmd iptables  -A PM_WEBBLOCK -p tcp --dport 80  \
                -m string --string "$domain" --algo bm -j PM_REJECT
            ip6tables -A PM_WEBBLOCK -p tcp --dport 443 \
                -m string --string "$domain" --algo bm -j REJECT 2>/dev/null || true
            ip6tables -A PM_WEBBLOCK -p tcp --dport 80  \
                -m string --string "$domain" --algo bm -j REJECT 2>/dev/null || true
        done
        # Bloqueo global QUIC/HTTP3 IPv4 + IPv6 — YouTube lo usa agresivamente
        cmd iptables -A PM_WEBBLOCK -p udp --dport 443 -j PM_REJECT
        ip6tables -A PM_WEBBLOCK -p udp --dport 443 -j REJECT 2>/dev/null || true
        logc "YouTube SNI: ${#sni_yt[@]} dominios + QUIC UDP 443 (IPv4+IPv6)"
    fi
    if [[ "$BLOCK_HOTMAIL" == "true" ]]; then
        for domain in "${sni_hm[@]}"; do
            cmd iptables  -A PM_WEBBLOCK -p tcp --dport 443 \
                -m string --string "$domain" --algo bm -j PM_REJECT
            cmd iptables  -A PM_WEBBLOCK -p tcp --dport 80  \
                -m string --string "$domain" --algo bm -j PM_REJECT
            ip6tables -A PM_WEBBLOCK -p tcp --dport 443 \
                -m string --string "$domain" --algo bm -j REJECT 2>/dev/null || true
            ip6tables -A PM_WEBBLOCK -p tcp --dport 80  \
                -m string --string "$domain" --algo bm -j REJECT 2>/dev/null || true
        done
        logc "Hotmail SNI: ${#sni_hm[@]} dominios (IPv4+IPv6)"
    fi
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

apply_mac_blocks() {
    [[ -z "$MAC_BLOCKS_STR" ]] && return
    logsec "MAC Blocking"
    IFS=',' read -ra _macs <<< "$MAC_BLOCKS_STR"
    local mac; for mac in "${_macs[@]}"; do
        [[ -z "$mac" ]] && continue
        cmd iptables -A PM_MACBLOCK -m mac --mac-source "$mac" -j PM_REJECT
        logc "MAC bloqueada: $mac"
    done
}

apply_conn_limits() {
    [[ -z "$CONN_LIMITS_STR" ]] && return
    logsec "Connection Limits"
    IFS=',' read -ra _limits <<< "$CONN_LIMITS_STR"
    local entry proto port max
    for entry in "${_limits[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r proto port max <<< "$entry"
        cmd iptables -A PM_CONNLIMIT -p "$proto" --dport "$port" \
            -m connlimit --connlimit-above "$max" --connlimit-mask 32 \
            -j PM_REJECT
        logc "Límite: $proto/$port max=$max"
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
"""M-FIREWALL DNS proxy — retorna NXDOMAIN para dominios bloqueados."""
import sys, socket, threading, signal

upstream  = sys.argv[1]
port      = int(sys.argv[2])
blocked   = [k.lower() for k in sys.argv[3].split(',') if k.strip()]

def nxdomain(data):
    """Construye respuesta DNS NXDOMAIN (RCODE=3) a partir del query original."""
    if len(data) < 12:
        return data
    return (data[:2]            # Transaction ID (2 bytes)
            + b'\x81\x83'       # Flags: QR=1 AA=0 TC=0 RD=1 RA=1 RCODE=3(NXDOMAIN)
            + data[4:6]         # QDCOUNT del query original
            + b'\x00\x00'       # ANCOUNT = 0
            + b'\x00\x00'       # NSCOUNT = 0
            + b'\x00\x00'       # ARCOUNT = 0
            + data[12:])        # Question section original

def handle(data, addr, sock):
    payload = data.lower()
    if any(kw.encode() in payload for kw in blocked):
        try:
            sock.sendto(nxdomain(data), addr)
        except Exception:
            pass
        return
    # Reenviar al upstream real
    up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
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
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('127.0.0.1', port))
    signal.signal(signal.SIGTERM, lambda *_: (sock.close(), sys.exit(0)))
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

setup_dns_proxy() {
    logsec "DNS proxy en port 53 (reemplaza systemd-resolved)"

    # ── 1. Upstream DNS real ANTES de tocar nada ────────────────────────────────
    local _up
    _up=$(awk '/^nameserver/ && $2 !~ /^127\./{print $2; exit}' \
          /run/systemd/resolve/resolv.conf 2>/dev/null)
    [[ -z "$_up" ]] && \
        _up=$(awk '/^nameserver/ && $2 !~ /^127\./{print $2; exit}' \
              /etc/resolv.conf 2>/dev/null)
    [[ -z "$_up" ]] && _up="8.8.8.8"

    # ── 2. Detener todo lo que pueda ocupar port 53 ─────────────────────────────
    # dnsmasq compite con systemd-resolved en algunas instalaciones de Kali
    cmd systemctl stop dnsmasq        2>/dev/null || true
    cmd systemctl stop systemd-resolved 2>/dev/null || true
    pkill -f "dnsmasq"               2>/dev/null || true
    pkill -f "systemd-resolved"      2>/dev/null || true
    sleep 0.5

    # ── 3. Evitar que NetworkManager sobreescriba resolv.conf ───────────────────
    # NM detecta que systemd-resolved murió y lo reinicia o reescribe resolv.conf.
    # Con dns=none le decimos que no toque DNS en absoluto.
    local _nm_conf="/etc/NetworkManager/conf.d/99-mfirewall-dns.conf"
    if command -v nmcli &>/dev/null; then
        mkdir -p /etc/NetworkManager/conf.d
        printf '[main]\ndns=none\n' > "$_nm_conf"
        cmd systemctl reload NetworkManager 2>/dev/null || \
            cmd systemctl restart NetworkManager 2>/dev/null || true
        sleep 0.4
        logc "NetworkManager: dns=none aplicado"
    fi

    # ── 4. Reemplazar /etc/resolv.conf ──────────────────────────────────────────
    # Guardar estado original para restaurar en teardown
    chattr -i /etc/resolv.conf 2>/dev/null || true   # quitar inmutable si ya estaba
    if [[ -L /etc/resolv.conf ]]; then
        readlink /etc/resolv.conf > /var/run/mfirewall-resolv-symlink 2>/dev/null || true
        rm -f /etc/resolv.conf
    else
        cp /etc/resolv.conf /etc/resolv.conf.mfirewall_bak 2>/dev/null || true
        rm -f /etc/resolv.conf
    fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    # Hacer inmutable — ningún proceso puede modificarlo mientras el firewall esté activo
    chattr +i /etc/resolv.conf 2>/dev/null || true
    logc "/etc/resolv.conf fijado en 127.0.0.1 (inmutable)"

    # ── 5. Keywords a bloquear ──────────────────────────────────────────────────
    local -a _kws=()
    [[ "$BLOCK_YOUTUBE"  == "true" ]] && \
        _kws+=(youtube googlevideo ytimg youtu youtube-nocookie youtubei)
    [[ "$BLOCK_FACEBOOK" == "true" ]] && \
        _kws+=(facebook fbcdn messenger instagram fbsbx)
    [[ "$BLOCK_HOTMAIL"  == "true" ]] && \
        _kws+=(hotmail outlook microsoftonline live.com office365)
    # Bloquear resolución de servidores DoH para impedir bypass HTTPS
    _kws+=(dns.google cloudflare-dns dns.quad9 use-application-dns mozilla.cloudflare)
    local _csv
    _csv=$(IFS=','; echo "${_kws[*]}")

    # ── 6. Kill instancia previa del proxy ──────────────────────────────────────
    if [[ -f "$DNS_PROXY_PID_FILE" ]]; then
        kill "$(cat "$DNS_PROXY_PID_FILE")" 2>/dev/null || true
        rm -f "$DNS_PROXY_PID_FILE"
    fi
    pkill -f "$DNS_PROXY_SCRIPT" 2>/dev/null || true
    sleep 0.3

    # ── 7. Proxy en port 53 directo ─────────────────────────────────────────────
    _write_dns_proxy_script
    [[ -n "$CMD_LOG" ]] && printf '[%s] [CMD] python3 %s %s 53 %s &\n' \
        "$(date +%H:%M:%S)" "$DNS_PROXY_SCRIPT" "$_up" "$_csv" >> "$CMD_LOG"
    python3 "$DNS_PROXY_SCRIPT" "$_up" 53 "$_csv" &
    local _pid=$!
    disown "$_pid"
    echo "$_pid" > "$DNS_PROXY_PID_FILE"
    sleep 1.0  # esperar que Python bindee el socket

    # ── 8. Verificar que el proxy realmente está escuchando en :53 ──────────────
    # CRÍTICO: verificar con ss, NO con dig. dig retorna vacío tanto si hay NXDOMAIN
    # como si no hay nada en port 53 → falso positivo. ss es la fuente de verdad.
    local _proxy_ok=false
    if ss -ulnp 2>/dev/null | grep -q ':53 '; then
        _proxy_ok=true
        logc "✓ Proxy confirmado activo en UDP :53"
    elif ss -ulnp 2>/dev/null | grep -q ':53$'; then
        _proxy_ok=true
        logc "✓ Proxy confirmado activo en UDP :53"
    else
        logc "AVISO: No se detectó proceso en UDP :53 — verificar manualmente"
        logc "  Comando: ss -ulnp | grep ':53'"
    fi

    # Verificación adicional con dig (informativa, no concluyente)
    local _test
    _test=$(dig +short +time=2 youtube.com @127.0.0.1 2>/dev/null | head -1 || true)
    if [[ -z "$_test" && "$_proxy_ok" == "true" ]]; then
        logc "✓ DNS: youtube.com → NXDOMAIN (upstream: $_up)"
    elif [[ -n "$_test" ]]; then
        logc "AVISO: youtube.com resolvio a '$_test'"
    fi

    # ── 9. Bloquear IPs de servidores DoH — Firefox los tiene hardcodeados ──────
    # IPv4 DoH IPs (Cloudflare, Google, Quad9)
    for _doh in 1.1.1.1 1.0.0.1 104.16.248.249 104.16.249.249 \
                8.8.8.8 8.8.4.4 9.9.9.9 9.9.9.10; do
        cmd iptables -A PM_WEBBLOCK -p tcp --dport 443 -d "$_doh" -j PM_REJECT
        cmd iptables -A PM_WEBBLOCK -p udp --dport 443 -d "$_doh" -j PM_REJECT
    done
    # IPv6 DoH IPs
    for _doh6 in 2606:4700:4700::1111 2606:4700:4700::1001 \
                 2001:4860:4860::8888 2001:4860:4860::8844; do
        ip6tables -A PM_WEBBLOCK -p tcp --dport 443 -d "$_doh6" -j REJECT 2>/dev/null || true
        ip6tables -A PM_WEBBLOCK -p udp --dport 443 -d "$_doh6" -j REJECT 2>/dev/null || true
    done

    # ── 10. Matar Firefox + limpiar TODO el caché ────────────────────────────────
    pkill -9 -f "firefox" 2>/dev/null || true
    local _ff_tries=0
    while (( _ff_tries++ < 20 )) && pgrep -f "firefox" >/dev/null 2>&1; do
        kill -9 $(pgrep -f "firefox" 2>/dev/null) 2>/dev/null || true
        sleep 0.3
    done

    # HTTP cache en disco — borrado directo, más confiable que find -exec
    rm -rf /root/.cache/mozilla/firefox/*/cache2           2>/dev/null || true
    rm -rf /home/*/.cache/mozilla/firefox/*/cache2         2>/dev/null || true

    # Sessionstore — evita que Firefox reabra pestaña bloqueada
    local _prof
    for _prof in /root/.mozilla/firefox/*.default* \
                 /root/.mozilla/firefox/*.default-esr* \
                 /home/*/.mozilla/firefox/*.default* \
                 /home/*/.mozilla/firefox/*.default-esr*; do
        [[ -d "$_prof" ]] || continue
        rm -f  "$_prof/sessionstore.jsonlz4" 2>/dev/null || true
        rm -rf "$_prof/sessionstore-backups" 2>/dev/null || true
    done

    logc "DNS proxy PID=$_pid | port=53 | upstream=$_up | NM dns=none"
}

teardown_dns_proxy() {
    logsec "Deteniendo DNS proxy y restaurando DNS"

    # Matar proxy
    if [[ -f "$DNS_PROXY_PID_FILE" ]]; then
        local _pid
        _pid=$(cat "$DNS_PROXY_PID_FILE")
        cmd kill "$_pid" 2>/dev/null || true
        rm -f "$DNS_PROXY_PID_FILE"
    fi
    pkill -f "$DNS_PROXY_SCRIPT" 2>/dev/null || true
    rm -f "$DNS_PROXY_SCRIPT" 2>/dev/null || true

    # Quitar inmutable antes de tocar resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # Restaurar /etc/resolv.conf
    rm -f /etc/resolv.conf 2>/dev/null || true
    if [[ -f /var/run/mfirewall-resolv-symlink ]]; then
        local _tgt
        _tgt=$(cat /var/run/mfirewall-resolv-symlink)
        ln -sf "$_tgt" /etc/resolv.conf 2>/dev/null || true
        rm -f /var/run/mfirewall-resolv-symlink
        logc "resolv.conf: symlink restaurado → $_tgt"
    elif [[ -f /etc/resolv.conf.mfirewall_bak ]]; then
        mv /etc/resolv.conf.mfirewall_bak /etc/resolv.conf
        logc "resolv.conf: backup restaurado"
    else
        # Fallback mínimo
        printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > /etc/resolv.conf
        logc "resolv.conf: fallback a 8.8.8.8"
    fi

    # Restaurar NetworkManager DNS management y systemd-resolved
    local _nm_conf="/etc/NetworkManager/conf.d/99-mfirewall-dns.conf"
    if [[ -f "$_nm_conf" ]]; then
        rm -f "$_nm_conf"
        cmd systemctl reload NetworkManager 2>/dev/null || \
            cmd systemctl restart NetworkManager 2>/dev/null || true
        sleep 0.3
        logc "NetworkManager: dns=none eliminado, DNS management restaurado"
    fi
    cmd systemctl start systemd-resolved 2>/dev/null || true

    logc "DNS proxy detenido, DNS restaurado"
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
        printf '\n  \e[33m[!]\e[0m Sin sitios habilitados. Ve a \e[1mOpción 3\e[0m primero.\n'
        return 1
    fi

    open_cmd_terminal
    screen_wipe

    printf '\n'
    gradient_print "  Activando M-FIREWALL..." GRAD[@] 0
    printf '\n\n'

    # Calcular total de pasos
    local total=7  # base + ipsets + SNI + DNS-hex + DNS-proxy + hosts + firefox
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
        draw_progress_bar $step $total
    fi
    if [[ "$BLOCK_YOUTUBE" == "true" ]]; then
        (( step++ ))
        _animated_block_site $step $total "YouTube" "PM_YOUTUBE" YT_IPSET_DOMAINS \
            "tcp:80" "tcp:443" "udp:443" "tcp:853:any" "udp:853:any"
        draw_progress_bar $step $total
    fi
    if [[ "$BLOCK_HOTMAIL" == "true" ]]; then
        (( step++ ))
        _animated_block_site $step $total "Hotmail" "PM_HOTMAIL" DOMAINS_HOTMAIL \
            "tcp:80" "tcp:443"
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

    (( step++ )); run_step $step $total "Aplicando bloqueo SNI (TLS)" apply_sni_rules
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Bloqueando DNS por dominio (port 53)" apply_dns_block
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "DNS proxy local (bloqueo garantizado)" setup_dns_proxy
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Inyectando /etc/hosts" apply_all_hosts
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Deshabilitando Firefox DoH" apply_firefox_doh_block
    draw_progress_bar $step $total

    (( step++ )); run_step $step $total "Limpiando caché DNS" flush_dns
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

show_logs() {
    printf '\n  \e[1m\e[38;5;51mLogs M-FIREWALL\e[0m\n'
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
        gradient_print "  ╭── ACTIVAR FIREWALL  ·  Elige qué bloquear ───────────────────╮" GRAD[@] 0
        printf '\n'
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
menu_interfaces() {
    clear
    printf '\n'
    printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[1mInterfaces de Red  (WAN / LAN)\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mWAN = tarjeta conectada a internet\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mLAN = tarjeta conectada a la red local de clientes\e[0m\n'
    printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
    printf '  \e[38;5;27m│\e[0m  \e[2mInterfaces detectadas en este sistema:\e[0m\n'
    ip -o link show 2>/dev/null \
        | awk -F': ' '{printf "  \033[38;5;27m│\033[0m     \033[38;5;51m%-14s\033[0m\n", $2}' \
        | grep -v "lo$"
    printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
    printf "  \e[38;5;27m│\e[0m  WAN actual:  \e[38;5;46m%s\e[0m\n" "${WAN_IFACE:-no configurada}"
    printf "  \e[38;5;27m│\e[0m  LAN actual:  \e[38;5;46m%s\e[0m\n" "${LAN_IFACE:-no configurada}"
    printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'
    read -rp "  Nueva WAN (Enter = mantener '${WAN_IFACE:-vacío}'): " w
    read -rp "  Nueva LAN (Enter = mantener '${LAN_IFACE:-vacío}'): " l
    [[ -n "$w" ]] && WAN_IFACE="$w"
    [[ -n "$l" ]] && LAN_IFACE="$l"
    save_config
    printf '\n  \e[38;5;46m✓ Guardado  →  WAN: %s  |  LAN: %s\e[0m\n' \
        "${WAN_IFACE:-—}" "${LAN_IFACE:-—}"
}

menu_mac() {
    while true; do
        clear
        printf '\n'
        printf '  \e[38;5;27m╭─────────────────────────────────────────────────────────────╮\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[1mBloqueo por Dirección MAC\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mLos equipos con estas MACs no pueden enviar paquetes\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2ma través de este servidor (cadena FORWARD).\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'

        if [[ -n "$MAC_BLOCKS_STR" ]]; then
            IFS=',' read -ra _macs <<< "$MAC_BLOCKS_STR"
            local i=1
            for mac in "${_macs[@]}"; do
                [[ -z "$mac" ]] && continue
                printf "  \e[38;5;27m│\e[0m  \e[38;5;196m✗\e[0m  \e[38;5;51m%s\e[0m\n" "$mac"
                printf "  \e[38;5;27m│\e[0m      \e[38;5;240m→ iptables FORWARD -m mac --mac-source %s -j REJECT\e[0m\n" "$mac"
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
                printf '\n  \e[1mAgregar dirección MAC al bloqueo\e[0m\n\n'
                printf '  \e[2mFormato requerido:\e[0m  \e[38;5;51mAA:BB:CC:DD:EE:FF\e[0m\n'
                printf '  \e[2mEjemplo:\e[0m           \e[38;5;51m00:1A:2B:3C:4D:5E\e[0m\n\n'
                printf '  \e[2mPara obtener la MAC de un equipo cliente:\e[0m\n'
                printf '  \e[38;5;240m  ip neigh show   (tabla ARP de esta máquina)\e[0m\n'
                printf '  \e[38;5;240m  arp -a          (alternativa)\e[0m\n\n'
                read -rp "  MAC address: " mac
                if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                    MAC_BLOCKS_STR="${MAC_BLOCKS_STR:+${MAC_BLOCKS_STR},}${mac}"
                    save_config
                    printf '\n  \e[38;5;46m✓ Guardada. Se aplicará al activar el firewall.\e[0m\n'
                    sleep 1.2
                else
                    printf '\n  \e[31m✗ Formato inválido. Debe ser: XX:XX:XX:XX:XX:XX\e[0m\n'
                    sleep 1.5
                fi
                ;;
            d|D)
                if [[ -z "$MAC_BLOCKS_STR" ]]; then
                    printf '\n  \e[33mNo hay MACs para eliminar.\e[0m\n'; sleep 1; continue
                fi
                printf '\n  Copia la MAC exactamente como aparece arriba:\n\n'
                read -rp "  MAC a eliminar: " mac
                MAC_BLOCKS_STR=$(tr ',' '\n' <<< "$MAC_BLOCKS_STR" \
                    | grep -vi "^${mac}$" | tr '\n' ',' | sed 's/,$//')
                save_config; printf '  \e[38;5;46m✓ Eliminada.\e[0m\n'; sleep 0.8
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
        printf '  \e[38;5;27m│\e[0m  \e[1mLímite de Conexiones Simultáneas\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mCada IP cliente no puede tener más de N conexiones abiertas\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[2mal mismo tiempo hacia un puerto específico.\e[0m\n'
        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'

        if [[ -n "$CONN_LIMITS_STR" ]]; then
            IFS=',' read -ra _limits <<< "$CONN_LIMITS_STR"
            for entry in "${_limits[@]}"; do
                [[ -z "$entry" ]] && continue
                IFS=':' read -r _p _port _max <<< "$entry"
                printf "  \e[38;5;27m│\e[0m  \e[38;5;214m●\e[0m  \e[38;5;51m%-4s\e[0m  puerto \e[38;5;51m%-6s\e[0m  máx \e[1m%s\e[0m conexiones por IP\n" \
                    "$_p" "$_port" "$_max"
                printf "  \e[38;5;27m│\e[0m      \e[38;5;240m→ --connlimit-above %s --connlimit-mask 32 -j REJECT\e[0m\n" "$_max"
            done
        else
            printf '  \e[38;5;27m│\e[0m  \e[38;5;240m  Sin límites configurados. Agrega uno con [a].\e[0m\n'
        fi

        printf '  \e[38;5;27m├─────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46ma)\e[0m  Agregar   \e[38;5;196md)\e[0m  Eliminar   \e[38;5;240m0)\e[0m  Volver\n'
        printf '  \e[38;5;27m╰─────────────────────────────────────────────────────────────╯\e[0m\n\n'

        read -rp "  Opción: " opt
        case "$opt" in
            a|A)
                printf '\n  \e[1mAgregar límite de conexiones\e[0m\n\n'
                printf '  \e[38;5;27m──\e[0m  \e[1mPaso 1 de 3\e[0m  Protocolo\n'
                printf '  \e[38;5;240m     tcp = HTTP, HTTPS, SSH\e[0m\n'
                printf '  \e[38;5;240m     udp = DNS, streaming, juegos\e[0m\n'
                read -rp "  Protocolo [tcp/udp]: " proto

                printf '\n  \e[38;5;27m──\e[0m  \e[1mPaso 2 de 3\e[0m  Puerto de destino\n'
                printf '  \e[38;5;240m     Comunes: 80 (HTTP)  443 (HTTPS)  22 (SSH)\e[0m\n'
                read -rp "  Puerto: " port

                printf '\n  \e[38;5;27m──\e[0m  \e[1mPaso 3 de 3\e[0m  Máximo de conexiones simultáneas\n'
                printf '  \e[38;5;240m     Sugerido: 50 para HTTP/HTTPS · 10 para SSH\e[0m\n'
                read -rp "  Máximo: " max

                if [[ "$proto" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
                    CONN_LIMITS_STR="${CONN_LIMITS_STR:+${CONN_LIMITS_STR},}${proto}:${port}:${max}"
                    save_config
                    printf '\n  \e[38;5;46m✓ Límite guardado:\e[0m  %s puerto %s  máx %s conexiones\n' \
                        "$proto" "$port" "$max"
                    sleep 1.5
                else
                    printf '\n  \e[31m✗ Datos inválidos.\e[0m  Protocolo: tcp o udp · Puerto y máximo: solo números.\n'
                    sleep 2
                fi
                ;;
            d|D)
                if [[ -z "$CONN_LIMITS_STR" ]]; then
                    printf '\n  \e[33mNo hay límites para eliminar.\e[0m\n'; sleep 1; continue
                fi
                printf '\n  Ingresa la entrada a eliminar (proto:puerto:max):\n'
                printf '  \e[38;5;240m  Ejemplo: tcp:443:50\e[0m\n\n'
                read -rp "  Entrada: " entry
                CONN_LIMITS_STR=$(tr ',' '\n' <<< "$CONN_LIMITS_STR" \
                    | grep -v "^${entry}$" | tr '\n' ',' | sed 's/,$//')
                save_config; printf '  \e[38;5;46m✓ Eliminado.\e[0m\n'; sleep 0.8
                ;;
            0) break ;;
        esac
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
        printf '  \e[38;5;27m│\e[0m  \e[38;5;46m1)\e[0m  \e[1mActivar Firewall\e[0m  \e[2m— elegir sitios y aplicar reglas\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;196m2)\e[0m  Desactivar Firewall  \e[2m— restaurar páginas web al estado normal\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m3)\e[0m  Bloqueo por MAC address  \e[2m— denegar equipos por hardware\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m4)\e[0m  Límite de conexiones  \e[2m— máx simultáneas por IP\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m5)\e[0m  Interfaces WAN / LAN  \e[2m— configurar tarjetas de red\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;39m6)\e[0m  Dashboard en vivo  \e[2m— monitoreo en tiempo real [q] salir\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;39m7)\e[0m  Registro de paquetes  \e[2m— logs PM-DROP del kernel\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;196m8)\e[0m  Reset total de red  \e[2m— eliminar todo, restaurar internet\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m0)\e[0m  Salir\n'
        printf '  \e[38;5;27m╰──────────────────────────────────────────────────────────────╯\e[0m\n'
        printf '\n'

        read -rp "  Opción: " choice

        case "$choice" in
            1) wizard_activate;  read -rp $'\n  Presiona Enter para volver al menú...' ;;
            2) disable_firewall; read -rp $'\n  Presiona Enter para volver al menú...' ;;
            3) menu_mac ;;
            4) menu_connlimit ;;
            5) menu_interfaces; read -rp $'\n  Presiona Enter...' ;;
            6) show_dashboard ;;
            7) show_logs;    read -rp $'\n  Presiona Enter...' ;;
            8) deep_reset;   read -rp $'\n  Presiona Enter...' ;;
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
