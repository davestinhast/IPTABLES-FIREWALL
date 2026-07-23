#!/usr/bin/env bash
# M-FIREWALL diagnostico — pega todo el output a ENI
echo "====== DNS PROXY ======"
if [[ -f /var/run/mfirewall-dnsproxy.pid ]]; then
    PID=$(cat /var/run/mfirewall-dnsproxy.pid)
    echo "PID file: $PID"
    kill -0 "$PID" 2>/dev/null && echo "proceso VIVO" || echo "proceso MUERTO"
else
    echo "pid file NO existe — proxy no corre"
fi
ss -ulnp | grep ':53' || echo "nada escuchando en UDP :53"
ss -tlnp | grep ':53' || echo "nada escuchando en TCP :53"

echo ""
echo "====== resolv.conf ======"
cat /etc/resolv.conf
lsattr /etc/resolv.conf 2>/dev/null

echo ""
echo "====== DNS TEST ======"
echo "--- dig youtube.com ---"
dig +short +time=3 youtube.com 2>&1 | head -10
echo "--- dig youtube.com @127.0.0.1 ---"
dig +short +time=3 youtube.com @127.0.0.1 2>&1 | head -10
echo "--- dig google.com ---"
dig +short +time=3 google.com 2>&1 | head -5

echo ""
echo "====== CURL TEST ======"
curl -s --max-time 5 -o /dev/null -w "youtube.com HTTP: %{http_code}\n" https://www.youtube.com 2>&1
curl -s --max-time 5 -o /dev/null -w "google.com  HTTP: %{http_code}\n" https://www.google.com  2>&1

echo ""
echo "====== PM_WEBBLOCK REGLAS ======"
iptables -L PM_WEBBLOCK -n --line-numbers 2>/dev/null || echo "cadena PM_WEBBLOCK no existe"

echo ""
echo "====== NAT TABLE ======"
iptables -t nat -L OUTPUT -n 2>/dev/null | head -20

echo ""
echo "====== /etc/hosts (bloque mfirewall) ======"
sed -n '/BEGIN M-FIREWALL/,/END M-FIREWALL/p' /etc/hosts 2>/dev/null | head -20

echo ""
echo "====== ULTIMOS PM-DROP ======"
journalctl -k --no-pager -n 5 2>/dev/null | grep "PM-DROP" || dmesg | grep "PM-DROP" | tail -5 || echo "sin drops"

echo ""
echo "====== FIN DIAGNOSTICO ======"
