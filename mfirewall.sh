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
        for d in "${all[@]}"; do printf '0.0.0.0 %s\n' "$d"; done
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
    logsec "Cadenas iptables"
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
    cmd iptables -N PM_REJECT
    cmd iptables -N PM_WEBBLOCK
    cmd iptables -N PM_MACBLOCK
    cmd iptables -N PM_CONNLIMIT
    cmd iptables -A PM_REJECT -j LOG --log-prefix "PM-DROP: " --log-level 4
    cmd iptables -A PM_REJECT -p tcp -j REJECT --reject-with tcp-reset
    cmd iptables -A PM_REJECT -j REJECT --reject-with icmp-port-unreachable
    cmd iptables -A FORWARD -j PM_MACBLOCK
    cmd iptables -A FORWARD -j PM_CONNLIMIT
    cmd iptables -A FORWARD -j PM_WEBBLOCK
    cmd iptables -A OUTPUT  -j PM_WEBBLOCK
    cmd sysctl -w net.ipv4.ip_forward=1
    logc "IP Forwarding activado"
}

# =============================================================================
# BLOQUEADORES
# =============================================================================
block_facebook() {
    logsec "FACEBOOK"
    mapfile -t _fb_ips < <(resolve_site_ips DOMAINS_FACEBOOK)
    logc "${#_fb_ips[@]} IPs resueltas"
    cmd ipset create PM_FACEBOOK hash:ip family inet hashsize 1024 maxelem 65536 -exist
    cmd ipset flush PM_FACEBOOK
    local ip; for ip in "${_fb_ips[@]}"; do cmd ipset add PM_FACEBOOK "$ip" -exist; done
    cmd iptables -A PM_WEBBLOCK -p tcp --dport 80  \
        -m set --match-set PM_FACEBOOK dst -j PM_REJECT
    cmd iptables -A PM_WEBBLOCK -p tcp --dport 443 \
        -m set --match-set PM_FACEBOOK dst -j PM_REJECT
    logc "Facebook bloqueado: ${#_fb_ips[@]} IPs"
}

block_hotmail() {
    logsec "HOTMAIL / OUTLOOK"
    mapfile -t _hm_ips < <(resolve_site_ips DOMAINS_HOTMAIL)
    logc "${#_hm_ips[@]} IPs resueltas"
    cmd ipset create PM_HOTMAIL hash:ip family inet hashsize 1024 maxelem 65536 -exist
    cmd ipset flush PM_HOTMAIL
    local ip; for ip in "${_hm_ips[@]}"; do cmd ipset add PM_HOTMAIL "$ip" -exist; done
    cmd iptables -A PM_WEBBLOCK -p tcp --dport 80  \
        -m set --match-set PM_HOTMAIL dst -j PM_REJECT
    cmd iptables -A PM_WEBBLOCK -p tcp --dport 443 \
        -m set --match-set PM_HOTMAIL dst -j PM_REJECT
    logc "Hotmail bloqueado: ${#_hm_ips[@]} IPs"
}

block_youtube() {
    logsec "YOUTUBE"
    local -A _seen; local _yt_ips=(); local ip domain
    for domain in "${YT_IPSET_DOMAINS[@]}"; do
        while IFS= read -r ip; do
            if [[ -n "$ip" && -z "${_seen[$ip]+x}" ]]; then
                _seen[$ip]=1; _yt_ips+=("$ip")
            fi
        done < <(resolve_domain_ips "$domain")
    done
    logc "${#_yt_ips[@]} IPs resueltas"
    cmd ipset create PM_YOUTUBE hash:ip family inet hashsize 1024 maxelem 65536 -exist
    cmd ipset flush PM_YOUTUBE
    for ip in "${_yt_ips[@]}"; do cmd ipset add PM_YOUTUBE "$ip" -exist; done
    cmd iptables -A PM_WEBBLOCK -p tcp --dport 80  \
        -m set --match-set PM_YOUTUBE dst -j PM_REJECT
    cmd iptables -A PM_WEBBLOCK -p tcp --dport 443 \
        -m set --match-set PM_YOUTUBE dst -j PM_REJECT
    cmd iptables -A PM_WEBBLOCK -p udp --dport 443 \
        -m set --match-set PM_YOUTUBE dst -j PM_REJECT
    cmd iptables -A PM_WEBBLOCK -p tcp --dport 853 -j PM_REJECT
    cmd iptables -A PM_WEBBLOCK -p udp --dport 853 -j PM_REJECT
    logc "YouTube bloqueado: ipset + QUIC + DoT"
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
    cmd systemctl restart systemd-resolved 2>/dev/null || true
    cmd resolvectl flush-caches 2>/dev/null || true
    logc "Caché DNS limpiada"
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
    local total=4  # base + hosts + firefox + dns
    [[ "$BLOCK_FACEBOOK" == "true" ]] && (( total++ ))
    [[ "$BLOCK_YOUTUBE"  == "true" ]] && (( total++ ))
    [[ "$BLOCK_HOTMAIL"  == "true" ]] && (( total++ ))
    [[ -n "$MAC_BLOCKS_STR" ]]  && (( total++ ))
    [[ -n "$CONN_LIMITS_STR" ]] && (( total++ ))

    local step=0

    (( step++ )); run_step $step $total "Configurando cadenas iptables" setup_base_chains
    draw_progress_bar $step $total

    if [[ "$BLOCK_FACEBOOK" == "true" ]]; then
        (( step++ )); run_step $step $total "Bloqueando Facebook" block_facebook
        draw_progress_bar $step $total
    fi
    if [[ "$BLOCK_YOUTUBE" == "true" ]]; then
        (( step++ )); run_step $step $total "Bloqueando YouTube" block_youtube
        draw_progress_bar $step $total
    fi
    if [[ "$BLOCK_HOTMAIL" == "true" ]]; then
        (( step++ )); run_step $step $total "Bloqueando Hotmail/Outlook" block_hotmail
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
        logc "Cadenas eliminadas"
    }

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
            iptables -t "$t" -F 2>/dev/null || true
            iptables -t "$t" -X 2>/dev/null || true
        done
        iptables -P INPUT   ACCEPT 2>/dev/null
        iptables -P FORWARD ACCEPT 2>/dev/null
        iptables -P OUTPUT  ACCEPT 2>/dev/null
        for t in filter nat mangle raw; do
            ip6tables -t "$t" -F 2>/dev/null || true
            ip6tables -t "$t" -X 2>/dev/null || true
        done
        logc "Todas las tablas iptables vaciadas"
    }
    _destroy_ipsets() { cmd ipset destroy 2>/dev/null || true; logc "ipsets destruidos"; }
    _restore_resolv() {
        if [[ ! -s "/etc/resolv.conf" ]] || ! grep -q "nameserver" /etc/resolv.conf; then
            cmd bash -c 'printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf'
        fi
        logc "/etc/resolv.conf verificado"
    }

    (( step++ )); run_step $step $total "Vaciando todas las tablas iptables" _flush_all_tables
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Destruyendo ipsets" _destroy_ipsets
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Limpiando /etc/hosts" remove_hosts_block
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Quitando políticas Firefox" remove_firefox_doh_block
    draw_progress_bar $step $total
    (( step++ )); run_step $step $total "Restaurando /etc/resolv.conf" _restore_resolv
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
    printf '  \e[38;5;27m┌──────────────────────────────────────────┐\e[0m\n'
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

    printf '  \e[38;5;27m├──────────────────────────────────────────┤\e[0m\n'
    printf "  \e[38;5;27m│\e[0m  WAN: \e[38;5;51m%-10s\e[0m  LAN: \e[38;5;51m%s\e[0m\n" \
        "${WAN_IFACE:-—}" "${LAN_IFACE:-—}"
    [[ -n "$MAC_BLOCKS_STR" ]] && \
        printf "  \e[38;5;27m│\e[0m  MACs: \e[38;5;214m%s\e[0m\n" "$MAC_BLOCKS_STR"
    [[ -n "$CONN_LIMITS_STR" ]] && \
        printf "  \e[38;5;27m│\e[0m  Limites: \e[38;5;214m%s\e[0m\n" "$CONN_LIMITS_STR"
    printf '  \e[38;5;27m└──────────────────────────────────────────┘\e[0m\n\n'

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

# =============================================================================
# SUBMENÚS
# =============================================================================
menu_sites() {
    while true; do
        clear
        printf '\n'
        printf '  \e[38;5;27m┌──────────────────────────────────────┐\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[1mSitios Bloqueados\e[0m\n'
        printf '  \e[38;5;27m├──────────────────────────────────────┤\e[0m\n'
        echo -e "  \e[38;5;27m│\e[0m  \e[1m1)\e[0m  Facebook   [$(toggle_label "$BLOCK_FACEBOOK")]"
        echo -e "  \e[38;5;27m│\e[0m  \e[1m2)\e[0m  YouTube    [$(toggle_label "$BLOCK_YOUTUBE")]"
        echo -e "  \e[38;5;27m│\e[0m  \e[1m3)\e[0m  Hotmail    [$(toggle_label "$BLOCK_HOTMAIL")]"
        printf '  \e[38;5;27m├──────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m0)\e[0m  Volver\n'
        printf '  \e[38;5;27m└──────────────────────────────────────┘\e[0m\n\n'
        read -rp "  Opción: " opt
        case "$opt" in
            1) toggle_var BLOCK_FACEBOOK; save_config ;;
            2) toggle_var BLOCK_YOUTUBE;  save_config ;;
            3) toggle_var BLOCK_HOTMAIL;  save_config ;;
            0) break ;;
        esac
    done
}

menu_interfaces() {
    printf '\n  \e[1mInterfaces disponibles:\e[0m\n'
    ip -o link show | awk -F': ' '{print "    " $2}' | grep -v "^    lo"
    printf '\n  WAN actual: \e[38;5;51m%s\e[0m\n' "${WAN_IFACE:-no configurada}"
    printf '  LAN actual: \e[38;5;51m%s\e[0m\n\n' "${LAN_IFACE:-no configurada}"
    read -rp "  WAN [Enter para mantener]: " w
    read -rp "  LAN [Enter para mantener]: " l
    [[ -n "$w" ]] && WAN_IFACE="$w"
    [[ -n "$l" ]] && LAN_IFACE="$l"
    save_config
    printf '  \e[38;5;46m✓ Guardado.\e[0m\n'
}

menu_mac() {
    while true; do
        printf '\n  \e[1mBloqueo por MAC\e[0m\n'
        if [[ -n "$MAC_BLOCKS_STR" ]]; then
            printf '  MACs bloqueadas:\n'
            IFS=',' read -ra _macs <<< "$MAC_BLOCKS_STR"
            local i=1
            for mac in "${_macs[@]}"; do
                [[ -n "$mac" ]] && printf '    \e[38;5;46m%d) %s\e[0m\n' $i "$mac" && ((i++))
            done
        else
            printf '  \e[2mSin MACs configuradas.\e[0m\n'
        fi
        printf '\n  a) Agregar  d) Eliminar  0) Volver\n\n'
        read -rp "  Opción: " opt
        case "$opt" in
            a)
                read -rp "  MAC (AA:BB:CC:DD:EE:FF): " mac
                if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                    MAC_BLOCKS_STR="${MAC_BLOCKS_STR:+${MAC_BLOCKS_STR},}${mac}"
                    save_config
                    printf '  \e[38;5;46m✓ MAC agregada.\e[0m\n'
                else
                    printf '  \e[31mFormato inválido.\e[0m\n'
                fi
                ;;
            d)
                read -rp "  MAC a eliminar: " mac
                MAC_BLOCKS_STR=$(
                    tr ',' '\n' <<< "$MAC_BLOCKS_STR" \
                    | grep -vi "^${mac}$" | tr '\n' ',' | sed 's/,$//')
                save_config; printf '  \e[38;5;46m✓ Eliminada.\e[0m\n' ;;
            0) break ;;
        esac
    done
}

menu_connlimit() {
    while true; do
        printf '\n  \e[1mLímites de Conexión\e[0m\n'
        if [[ -n "$CONN_LIMITS_STR" ]]; then
            IFS=',' read -ra _limits <<< "$CONN_LIMITS_STR"
            local i=1
            for entry in "${_limits[@]}"; do
                [[ -z "$entry" ]] && continue
                IFS=':' read -r _p _port _max <<< "$entry"
                printf '  \e[38;5;46m%d) %s/%s  max=%s conexiones\e[0m\n' \
                    $i "$_p" "$_port" "$_max"
                ((i++))
            done
        else
            printf '  \e[2mSin límites.\e[0m\n'
        fi
        printf '\n  a) Agregar  d) Eliminar  0) Volver\n\n'
        read -rp "  Opción: " opt
        case "$opt" in
            a)
                read -rp "  Protocolo (tcp/udp): " proto
                read -rp "  Puerto: " port
                read -rp "  Máx conexiones: " max
                if [[ "$proto" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
                    CONN_LIMITS_STR="${CONN_LIMITS_STR:+${CONN_LIMITS_STR},}${proto}:${port}:${max}"
                    save_config; printf '  \e[38;5;46m✓ Agregado.\e[0m\n'
                else
                    printf '  \e[31mDatos inválidos.\e[0m\n'
                fi
                ;;
            d)
                read -rp "  Entrada (proto:puerto:max): " entry
                CONN_LIMITS_STR=$(
                    tr ',' '\n' <<< "$CONN_LIMITS_STR" \
                    | grep -v "^${entry}$" | tr '\n' ',' | sed 's/,$//')
                save_config; printf '  \e[38;5;46m✓ Eliminado.\e[0m\n' ;;
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
        # Boot spinner mientras carga
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

        # Estado — evaluado correctamente con double quotes
        echo -e "  \e[2mFB:\e[0m $(toggle_label "$BLOCK_FACEBOOK")   \e[2mYT:\e[0m $(toggle_label "$BLOCK_YOUTUBE")   \e[2mHM:\e[0m $(toggle_label "$BLOCK_HOTMAIL")"
        printf '\n'

        printf '  \e[38;5;27m┌──────────────────────────────────────┐\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;51m1)\e[0m  \e[1mActivar firewall\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;51m2)\e[0m  Desactivar firewall\n'
        printf '  \e[38;5;27m├──────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m3)\e[0m  Configurar sitios bloqueados\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m4)\e[0m  Configurar interfaces (WAN/LAN)\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m5)\e[0m  Bloqueo por MAC\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;45m6)\e[0m  Limites de conexion\n'
        printf '  \e[38;5;27m├──────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;39m7)\e[0m  Ver estado actual\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;39m8)\e[0m  Ver logs\n'
        printf '  \e[38;5;27m├──────────────────────────────────────┤\e[0m\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;196m9)\e[0m  Reset total de red\n'
        printf '  \e[38;5;27m│\e[0m  \e[38;5;240m0)\e[0m  Salir\n'
        printf '  \e[38;5;27m└──────────────────────────────────────┘\e[0m\n'
        printf '\n'

        read -rp "  Opción: " choice

        case "$choice" in
            1) enable_firewall;  read -rp $'\n  Presiona Enter...' ;;
            2) disable_firewall; read -rp $'\n  Presiona Enter...' ;;
            3) menu_sites ;;
            4) menu_interfaces; read -rp $'\n  Presiona Enter...' ;;
            5) menu_mac ;;
            6) menu_connlimit ;;
            7) show_status;  read -rp $'\n  Presiona Enter...' ;;
            8) show_logs;    read -rp $'\n  Presiona Enter...' ;;
            9) deep_reset;   read -rp $'\n  Presiona Enter...' ;;
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
