# M-FIREWALL v2.0

Firewall de terminal para **Kali Linux** que bloquea acceso a Facebook, YouTube y Hotmail usando múltiples capas de protección a nivel de kernel, sistema de archivos y proxy DNS.

```
  ╔══════════════════════════════════════════════════════════════╗
  ║    M ─ F I R E W A L L    v 2 . 0                          ║
  ║    ──────────────────────────────────                        ║
  ║    Kali Linux  ·  iptables + ipset + Firefox policy          ║
  ╚══════════════════════════════════════════════════════════════╝
```

---

## Requisitos del proyecto (todos cumplidos)

| # | Requisito | Implementación |
|---|-----------|----------------|
| 1 | Bloquear Facebook, YouTube y Hotmail | 6 capas de bloqueo combinadas |
| 2 | Bloquear paquetes cliente→servidor, permitir servidor→cliente | `ESTABLISHED,RELATED -j ACCEPT` en FORWARD antes de las reglas de bloqueo |
| 3 | Bloqueo por dirección MAC | `iptables -m mac --mac-source` en cadena PM_MACBLOCK |
| 4 | Límite de conexiones simultáneas | `iptables -m connlimit` en cadena PM_CONNLIMIT |
| 5 | Log de paquetes rechazados | `iptables -j LOG --log-prefix "PM-DROP:"` en cadena PM_REJECT |
| 6 | Archivo de reglas personalizable | `/opt/mfirewall/config.conf` persistente entre sesiones |
| 7 | Mínimo 10 comandos iptables | Más de 40 comandos ejecutados por activación |

---

## Tecnologías utilizadas

- **iptables / ip6tables** — reglas de firewall a nivel kernel (IPv4 + IPv6)
- **ipset** — conjuntos de IPs para bloqueo eficiente por dirección
- **Python 3** — proxy DNS local que retorna NXDOMAIN para dominios bloqueados
- **/etc/hosts** — entradas `0.0.0.0` y `::` para bloqueo a nivel sistema de nombres
- **Firefox enterprise policy** — JSON que deshabilita DNS-over-HTTPS
- **iptables xt_string** — módulo de matching sobre payload para bloqueo SNI
- **conntrack** — limpieza de conexiones existentes al activar reglas
- **chattr** — atributo inmutable en `/etc/resolv.conf` para evitar sobreescritura
- **NetworkManager conf.d** — deshabilitar gestión DNS de NM durante el bloqueo
- **Bash** — script principal con menú interactivo, animaciones y dashboard

---

## Cómo se elaboró — paso a paso

### Paso 1 — Estructura base y menú interactivo

Se creó el esqueleto del script con:
- Sistema de colores ANSI de 256 colores con función `gradient_print()` para el banner
- Menú principal navegable con opciones numeradas
- Sistema de configuración persistente en `/opt/mfirewall/config.conf`
- Función `run_step()` con spinner animado para mostrar progreso en tiempo real
- Segundo terminal (`xterm`) que muestra cada comando ejecutado mientras el firewall activa

### Paso 2 — Cadenas iptables personalizadas

Se definieron 4 cadenas iptables propias para mantener las reglas organizadas y fáciles de limpiar:

```bash
iptables -N PM_REJECT      # LOG → REJECT con tcp-reset o icmp-unreachable
iptables -N PM_WEBBLOCK    # reglas de bloqueo por sitio (SNI, IP, DNS)
iptables -N PM_MACBLOCK    # bloqueo por dirección MAC
iptables -N PM_CONNLIMIT   # límite de conexiones simultáneas por IP
```

Las cadenas se enganchan en **OUTPUT** (tráfico local) y **FORWARD** (tráfico que pasa por el servidor como gateway). Se agrega `ESTABLISHED,RELATED -j ACCEPT` antes del bloqueo para que las respuestas de servidor ya no se vean afectadas (cumple requisito cliente→servidor únicamente).

### Paso 3 — Bloqueo por IP con ipset

Se resuelven los dominios de cada sitio al momento de activar el firewall y se almacenan en conjuntos `ipset` de tipo `hash:ip`:

```bash
ipset create PM_YOUTUBE hash:ip family inet hashsize 1024 maxelem 65536
ipset add PM_YOUTUBE <IP>
iptables -A PM_WEBBLOCK -m set --match-set PM_YOUTUBE dst -j PM_REJECT
```

**Problema encontrado:** Google usa infraestructura Anycast con miles de IPs rotativas. Las IPs resueltas hoy no son las mismas mañana, y un bloqueo solo por IP es ineficiente.

### Paso 4 — SNI blocking (string matching en TLS)

Se implementó matching sobre el campo SNI del TLS ClientHello, que contiene el nombre del dominio en texto plano:

```bash
iptables -A PM_WEBBLOCK -p tcp --dport 443 \
    -m string --string "youtube.com" --algo bm -j PM_REJECT
```

**Problema encontrado:** Firefox 118+ implementa **ECH (Encrypted Client Hello)**, que cifra el SNI. El campo ya no es visible en el payload TCP, haciendo que el string matching no funcione.

### Paso 5 — DNS hex-string blocking

Se descubrió que las queries DNS en puerto 53 contienen el nombre del dominio en formato wire-protocol (longitud de etiqueta + texto). Se bloquearon a nivel iptables antes de que el resolver responda:

```bash
# "youtube.com" en DNS wire-protocol = \x07youtube\x03com
iptables -A PM_WEBBLOCK -p udp --dport 53 \
    -m string --hex-string "|07|youtube|03|com" --algo bm -j PM_REJECT
```

### Paso 6 — /etc/hosts

Se inyectan entradas que mapean todos los dominios bloqueados a `0.0.0.0` (IPv4) y `::` (IPv6):

```
0.0.0.0 youtube.com
0.0.0.0 www.youtube.com
:: youtube.com
:: www.youtube.com
```

Las entradas se delimitan con marcadores `# BEGIN M-FIREWALL` / `# END M-FIREWALL` para poder limpiarlas limpiamente al desactivar.

### Paso 7 — Firefox DoH policy

Firefox puede usar **DNS-over-HTTPS** (DoH) para resolver nombres sin pasar por el resolver del sistema, bypasseando `/etc/hosts` y el proxy DNS. Se deshabilita mediante política enterprise de Firefox:

```json
{
  "policies": {
    "DNSOverHTTPS": { "Enabled": false, "Locked": true }
  }
}
```

Este JSON se escribe en `/usr/lib/firefox-esr/distribution/policies.json` y aplica globalmente a todas las sesiones.

### Paso 8 — Proxy DNS Python3 (capa definitiva)

**Problema:** A pesar de todas las capas anteriores, YouTube seguía cargando. Análisis del root cause:

1. Firefox tiene caché DNS **en memoria** que sobrevive cambios en `/etc/resolv.conf`
2. Firefox tiene caché HTTP en disco (`cache2/`) que sirve páginas sin consultar la red
3. Firefox con ECH cifra el SNI, haciendo inefectivo el string matching

**Solución:** Proxy DNS local en Python 3 que intercepta todas las queries DNS antes de que lleguen a cualquier resolver externo:

```python
def handle(data, addr, sock):
    payload = data.lower()
    if any(kw.encode() in payload for kw in blocked):
        sock.sendto(nxdomain(data), addr)   # NXDOMAIN inmediato
        return
    # reenviar al upstream real para todo lo demás
    forward_to_upstream(data, addr, sock)
```

El proxy escucha en `127.0.0.1:53` directamente (no por NAT REDIRECT), se detiene `systemd-resolved` para liberar el puerto, y `/etc/resolv.conf` se configura con `nameserver 127.0.0.1`.

Al activar se mata Firefox, se borra la caché HTTP en disco y el sessionstore para que no restaure pestañas bloqueadas.

### Paso 9 — Root cause final: NetworkManager reescribía resolv.conf

**Problema persistente:** YouTube continuaba cargando incluso con el proxy DNS activo.

**Investigación:** Se analizó que **NetworkManager** monitorea el estado de `systemd-resolved`. Cuando lo detenemos, NM detecta que su gestor DNS cayó y sobrescribe `/etc/resolv.conf` en cuestión de segundos, restaurando el DNS normal.

**Además:** La verificación del proxy usaba `dig` para comprobar NXDOMAIN, pero si nada escuchaba en puerto 53, `dig` también retornaba vacío — **falso positivo** que reportaba éxito cuando el proxy había fallado.

**Solución implementada:**

```bash
# 1. Decirle a NetworkManager que NO gestione DNS
printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/99-mfirewall-dns.conf
systemctl reload NetworkManager

# 2. Hacer resolv.conf inmutable — ningún proceso puede sobreescribirlo
chattr +i /etc/resolv.conf

# 3. Verificar con ss que el proxy realmente está escuchando
ss -ulnp | grep ':53'   # fuente de verdad real
```

Al desactivar el firewall: `chattr -i` → restaurar resolv.conf → eliminar conf NM → reiniciar NM y systemd-resolved.

### Paso 10 — IPv6 (bypass ignorado hasta ahora)

**Problema:** Todo el stack de bloqueo operaba solo en IPv4. Firefox puede usar **registros AAAA** (IPv6) para conectarse a YouTube/Facebook directamente, evitando todas las reglas `iptables`.

**Solución:** Se duplicaron las reglas en `ip6tables` con la misma cadena `PM_WEBBLOCK` para IPv6, y se agregaron entradas `::` en `/etc/hosts`:

```bash
# Mismas reglas SNI en ip6tables
ip6tables -N PM_WEBBLOCK
ip6tables -A OUTPUT  -j PM_WEBBLOCK
ip6tables -A FORWARD -j PM_WEBBLOCK
ip6tables -A PM_WEBBLOCK -p tcp --dport 443 \
    -m string --string "youtube.com" --algo bm -j REJECT

# IPs de DoH en IPv6 también bloqueadas
ip6tables -A PM_WEBBLOCK -p tcp --dport 443 \
    -d 2606:4700:4700::1111 -j REJECT   # Cloudflare IPv6
```

---

## Arquitectura de capas de bloqueo

```
Usuario abre youtube.com en Firefox
         │
         ▼
[Capa 1] /etc/hosts — 0.0.0.0 y :: para todos los dominios
         │ (si Firefox tiene IP cacheada, salta esta capa)
         ▼
[Capa 2] DNS Proxy Python3 en 127.0.0.1:53
         │ retorna NXDOMAIN para dominios bloqueados
         │ (chattr +i en resolv.conf impide que NM lo sobreescriba)
         ▼
[Capa 3] DNS hex-string blocking — iptables bloquea queries en port 53
         │ por si algún proceso bypasea el proxy
         ▼
[Capa 4] SNI string matching — iptables detecta "youtube.com" en TLS
         │ (efectivo solo si Firefox no usa ECH)
         ▼
[Capa 5] ipset IP blocking — IPs de YouTube resueltas al activar
         │
         ▼
[Capa 6] Firefox DoH deshabilitado — policy.json enterprise
         │ IPs de servidores DoH (Cloudflare, Google) bloqueadas en iptables
         ▼
[BLOQUEADO] PM_REJECT → LOG (PM-DROP en kernel) → REJECT tcp-reset
```

---

## Comandos iptables ejecutados (cumple requisito mínimo 10)

```bash
# Cadena de log y rechazo
iptables -N PM_REJECT
iptables -A PM_REJECT -j LOG --log-prefix "PM-DROP: " --log-level 4
iptables -A PM_REJECT -p tcp -j REJECT --reject-with tcp-reset
iptables -A PM_REJECT -j REJECT --reject-with icmp-port-unreachable

# Bloqueo web (OUTPUT = tráfico local, FORWARD = gateway)
iptables -N PM_WEBBLOCK
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -j PM_WEBBLOCK
iptables -A OUTPUT  -j PM_WEBBLOCK

# Bloqueo MAC
iptables -N PM_MACBLOCK
iptables -A PM_MACBLOCK -m mac --mac-source AA:BB:CC:DD:EE:FF -j PM_REJECT

# Límite conexiones simultáneas
iptables -N PM_CONNLIMIT
iptables -A PM_CONNLIMIT -p tcp --dport 443 \
    -m connlimit --connlimit-above 50 --connlimit-mask 32 -j PM_REJECT

# SNI blocking
iptables -A PM_WEBBLOCK -p tcp --dport 443 \
    -m string --string "youtube.com" --algo bm -j PM_REJECT

# DNS hex-string
iptables -A PM_WEBBLOCK -p udp --dport 53 \
    -m string --hex-string "|07|youtube|03|com" --algo bm -j PM_REJECT

# QUIC/HTTP3 (YouTube usa UDP 443)
iptables -A PM_WEBBLOCK -p udp --dport 443 -j PM_REJECT

# ipset matching
iptables -A PM_WEBBLOCK -p tcp --dport 443 \
    -m set --match-set PM_YOUTUBE dst -j PM_REJECT

# DoH servers
iptables -A PM_WEBBLOCK -p tcp --dport 443 -d 1.1.1.1 -j PM_REJECT
```

> Total real al activar los 3 sitios: **más de 60 comandos iptables + ip6tables**

---

## Instalación

```bash
# Clonar repositorio
git clone https://github.com/davestinhast/IPTABLES-FIREWALL.git
cd IPTABLES-FIREWALL

# Dar permisos de ejecución
chmod +x mfirewall.sh

# Ejecutar como root
sudo bash mfirewall.sh
```

### Dependencias

```bash
apt install iptables ipset dnsutils iproute2 python3 conntrack
```

---

## Uso

```
  ╭──────────────────────────────────────────────────────────────╮
  │  1)  Activar Firewall   — elegir sitios y aplicar reglas     │
  │  2)  Desactivar Firewall — restaurar páginas web             │
  ├──────────────────────────────────────────────────────────────┤
  │  3)  Bloqueo por MAC address — denegar equipos por hardware  │
  │  4)  Límite de conexiones  — máx simultáneas por IP          │
  │  5)  Interfaces WAN / LAN  — configurar tarjetas de red      │
  ├──────────────────────────────────────────────────────────────┤
  │  6)  Dashboard en vivo  — monitoreo en tiempo real           │
  │  7)  Registro de paquetes — logs PM-DROP del kernel          │
  ├──────────────────────────────────────────────────────────────┤
  │  8)  Reset total de red — eliminar todo, restaurar internet  │
  │  0)  Salir                                                   │
  ╰──────────────────────────────────────────────────────────────╯
```

### Activar bloqueo

1. Ejecutar `sudo bash mfirewall.sh`
2. Opción **1** → elegir sitios a bloquear con `1`, `2`, `3`
3. Presionar **A** para activar
4. El firewall aplica las 6 capas de bloqueo en secuencia animada

### Verificar que funciona

```bash
# DNS debe retornar vacío para sitios bloqueados
dig +short youtube.com

# Kernel debe mostrar paquetes rechazados
journalctl -k | grep PM-DROP | tail -10

# Proxy DNS debe estar activo
ss -ulnp | grep ':53'
```

### Desactivar

Opción **2** en el menú. Restaura: DNS proxy → iptables → /etc/hosts → Firefox DoH → NetworkManager → systemd-resolved.

---

## Archivos generados en el sistema

| Archivo | Propósito |
|---------|-----------|
| `/opt/mfirewall/config.conf` | Configuración persistente |
| `/var/log/mfirewall.log` | Log de activaciones/desactivaciones |
| `/var/run/mfirewall-dnsproxy.pid` | PID del proxy DNS |
| `/tmp/mfirewall_dnsproxy.py` | Script Python del proxy (temporal) |
| `/etc/NetworkManager/conf.d/99-mfirewall-dns.conf` | Deshabilita gestión DNS de NM (se elimina al desactivar) |

---

## Autores

Quezada · Espinola · Sanchez
