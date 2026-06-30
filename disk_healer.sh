#!/bin/bash

# ==============================================================================
#  DISK HEALER v7.2.2 - SAFE REPAIR EDITION
#  Reescritura centrada en evitar pérdida de datos:
#   - Lectura cruzada (dd + hdparm) con decisión por status y desempate por voto
#   - Restauración directa de la copia en sectores lentos (sin ceros intermedios)
#   - Ceros SOLO en sectores ilegibles (forzar remapeo del firmware)
#   - Verificación post-escritura (relectura + comparación)
#   - Copias persistentes fuera de /tmp; se conservan si hubo discrepancia
#   - Arranque blindado: montaje, utilidades, SMART, tamaño de sector real
#   - Estado atómico y validado al reanudar (sin 'source')
# ==============================================================================

set -uo pipefail
# NOTA: -e queda fuera a propósito. badblocks/hdparm/dd devuelven códigos !=0
# esperados (encontrar bloque malo, leer sector dañado) que NO son errores fatales.

# --- CONFIG ---
CHUNK_PERCENT=2                      # % del disco por chunk de escaneo (def. 2). -e lo cambia.
TIEMPO_MAX=1.0                       # umbral (s) para considerar un sector "lento"
BACKUP_INTERVAL=10                   # cada cuántos seg se persiste el estado en escaneo

# Modo "reparar nada más encontrarlos" (-r). Usa un motor de escaneo híbrido
# propio (scan_hybrid), NO badblocks: lee en bloques grandes en zona sana y, al
# detectar un fallo, baja a granularidad de sector reparando cada uno al instante.
# Ignora CHUNK_PERCENT.
REPAIR_NOW=0
HYBRID_BLOCK_BYTES=$((8 * 1024 * 1024))   # tamaño del bloque de lectura rápida en -r (def. 8 MB). -b lo cambia.
REPAIR_NEIGHBORS=8                   # tras reparar, reintentar ±N sectores por si se destrabaron

# Timeout configurable (-t <seg>). Es el tope DURO del kernel para el disco.
# El timeout de cada operación del script se deriva como (IO_TIMEOUT - 2),
# manteniendo la relación 8/10 que se pidió: kernel=10 -> script=8.
IO_TIMEOUT=10                        # por defecto 10s; se puede cambiar con -t
OP_TIMEOUT=8                         # se recalcula tras parsear -t

# Detección de dispositivo (rellenadas en runtime)
SMART_DOPT=""                        # opción -d para smartctl (sat/auto/"")
DISK_SERIAL=""                       # serial/WWN para verificar identidad
KERNEL_TIMEOUT_PATH=""               # /sys/block/<dev>/device/timeout
KERNEL_TIMEOUT_ORIG=""               # valor original para restaurar al salir

STATE_FILE=".disk_healer_state"
PENDING_FILE=".disk_healer_pending"
LOG_FILE="disk_healer_report.log"

# Directorio persistente para copias de sectores rescatados (NO /tmp / NO tmpfs).
RESCUE_DIR="./disk_healer_rescued"

# Temporales de trabajo (sí pueden ir en /tmp; son volátiles por diseño)
TEMP_LIST="/tmp/badblocks_chunk.txt"
BIN_DD="/tmp/sector_dd.bin"
BIN_HDP="/tmp/sector_hdp.bin"
BIN_VOTE="/tmp/sector_vote.bin"
BIN_VERIFY="/tmp/sector_verify.bin"
# --------------

# Colores
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'
C='\033[0;36m'; P='\033[0;35m'; W='\033[1;37m'; GR='\033[0;90m'; NC='\033[0m'

# Variables globales (inicialización explícita)
SESSION_START_TIME=$(date +%s)
SESSION_START_SECTOR=0
TOTAL_SALVADOS=0
TOTAL_CEROS=0
TOTAL_FALLIDOS=0
TOTAL_DUDOSOS=0
SECTOR_ACTUAL=0
SECTOR_SIZE=512
TOTAL_SECTORS=0
LAST_REPAIR_DONE=0

# --- IDIOMA ---
detect_language() {
    if [[ "${LANG:-}" == *"es_"* ]]; then
        L_SAVED="Salvados"; L_ZEROS="Ceros"; L_FAIL="Fallidos"; L_PEND="Pendientes"
        L_DUB="Dudosos"; L_SPEED="Velocidad"; L_ETA="T. Restante"; L_FINISH="Fin Est."
        L_SCAN="ESCANEANDO"; L_REPAIR="REPARANDO"; L_PLUS_REPAIR="(+ Reparacion)"
        L_PH_READ="Lectura"; L_PH_RESC="Rescate"; L_PH_ZERO="Ceros"
        L_ELAPSED="Transcurr."; L_MODE="Modo"; L_TOUT="Timeout"
    else
        L_SAVED="Saved"; L_ZEROS="Zeros"; L_FAIL="Failed"; L_PEND="Pending"
        L_DUB="Dubious"; L_SPEED="Speed"; L_ETA="ETA"; L_FINISH="Est.End"
        L_SCAN="SCANNING"; L_REPAIR="REPAIRING"; L_PLUS_REPAIR="(+ Repair)"
        L_PH_READ="Read"; L_PH_RESC="Rescue"; L_PH_ZERO="Zeros"
        L_ELAPSED="Elapsed"; L_MODE="Mode"; L_TOUT="Timeout"
    fi
}
detect_language

# --- AUTODETECCIÓN DE CARACTERES DE CAJA (Unicode si el terminal lo soporta) ---
# Si el locale efectivo es UTF-8, usamos caja Unicode; si no, ASCII.
# Esto evita los '?' cuando se ejecuta como root con locale C/POSIX.
detect_box_charset() {
    local cmap
    cmap=$(locale charmap 2>/dev/null)
    if [ "$cmap" = "UTF-8" ] || [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"UTF-8"* ]] || [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"utf8"* ]]; then
        USE_UNICODE=1
        BX_TL='?'; BX_TR='?'; BX_BL='?'; BX_BR='?'; BX_HZ='?'; BX_VL='?'; BX_ML='?'; BX_MR='?'; BX_SEP='?'
        BX_FILL='?'; BX_EMPTY='?'; BX_ARROW='»'; BX_FAIL='?'
        # caja secundaria (tarjeta de reparación)
        BX_TL2='?'; BX_TR2='?'; BX_BL2='?'; BX_BR2='?'; BX_HZ2='?'; BX_VL2='?'
    else
        USE_UNICODE=0
        BX_TL='+'; BX_TR='+'; BX_BL='+'; BX_BR='+'; BX_HZ='='; BX_VL='|'; BX_ML='+'; BX_MR='+'; BX_SEP='|'
        BX_FILL='#'; BX_EMPTY='.'; BX_ARROW='>>'; BX_FAIL='X'
        BX_TL2='+'; BX_TR2='+'; BX_BL2='+'; BX_BR2='+'; BX_HZ2='-'; BX_VL2='|'
    fi
}
detect_box_charset

# ============================== LOGGING =======================================
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ========================= UTILIDADES DE FORMATO ==============================
format_seconds() {
    local T=${1:-0}
    printf "%02d:%02d:%02d" $((T/3600)) $(((T%3600)/60)) $((T%60))
}

fmt_int() {
    local n=${1:-0}
    echo "$n" | sed -r ':a;s/([0-9])([0-9]{3})($|[^0-9])/\1.\2\3/;ta'
}

# Formatea la hora de fin estimada indicando el día sin ambigüedad:
#   hoy       -> "14:30"
#   mañana    -> "Mañana 14:30"
#   +2 o más  -> "Jue 03/07 14:30"
format_finish() {
    local eta_seconds=${1:-0}
    local finish_epoch today_epoch finish_day today_day diff
    finish_epoch=$(date -d "+$eta_seconds seconds" +%s 2>/dev/null) || { echo "--:--"; return; }
    today_epoch=$(date +%s)
    # día (a medianoche) para comparar saltos de fecha, no de 24h
    finish_day=$(date -d "@$finish_epoch" +%Y%m%d 2>/dev/null)
    today_day=$(date +%Y%m%d)
    # diferencia en días naturales
    local fd td
    fd=$(date -d "$finish_day" +%s 2>/dev/null)
    td=$(date -d "$today_day" +%s 2>/dev/null)
    diff=$(( (fd - td) / 86400 ))
    local hhmm; hhmm=$(date -d "@$finish_epoch" +%H:%M 2>/dev/null)
    if [ "$diff" -le 0 ]; then
        echo "$hhmm"
    elif [ "$diff" -eq 1 ]; then
        if [[ "${LANG:-}" == *"es_"* ]]; then echo "Manana $hhmm"; else echo "Tomorrow $hhmm"; fi
    else
        # fecha completa con día de semana abreviado (LC_TIME forzado a C para ancho fijo ASCII)
        echo "$(LC_TIME=C date -d "@$finish_epoch" '+%a %d/%m %H:%M' 2>/dev/null)"
    fi
}

get_pending_count() {
    local c1=0 c2=0
    if [ -f "$TEMP_LIST" ]; then
        c1=$(grep -cve '^\s*$' "$TEMP_LIST" 2>/dev/null)
    fi
    if [ -f "$PENDING_FILE" ]; then
        c2=$(grep -cve '^\s*$' "$PENDING_FILE" 2>/dev/null)
    fi
    echo $(( ${c1:-0} + ${c2:-0} ))
}

# ========================== ESTADO ATÓMICO ====================================
write_state() {
    local last_sector=$1
    local tmp="${STATE_FILE}.tmp.$$"
    {
        echo "DEVICE=$DISCO"
        echo "SECTOR_SIZE=$SECTOR_SIZE"
        echo "LAST_SECTOR=$last_sector"
        echo "STATS_SALVADOS=$TOTAL_SALVADOS"
        echo "STATS_CEROS=$TOTAL_CEROS"
        echo "STATS_FALLIDOS=$TOTAL_FALLIDOS"
        echo "STATS_DUDOSOS=$TOTAL_DUDOSOS"
    } > "$tmp"
    sync "$tmp" 2>/dev/null
    mv -f "$tmp" "$STATE_FILE"
}

read_state_value() {
    local key=$1
    grep -m1 "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2-
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# ========================= LIMPIEZA / SALIDA ==================================
cleanup_exit() {
    tput cnorm 2>/dev/null
    # matar procesos hijos (badblocks, dd, hdparm en background)
    jobs -p | xargs -r kill -TERM > /dev/null 2>&1
    sleep 0.2
    jobs -p | xargs -r kill -KILL > /dev/null 2>&1
    if [ -s "$TEMP_LIST" ]; then
        cat "$TEMP_LIST" >> "$PENDING_FILE" 2>/dev/null
        sort -un "$PENDING_FILE" -o "$PENDING_FILE" 2>/dev/null
    fi
    rm -f "$BIN_DD" "$BIN_HDP" "$BIN_VOTE" "$BIN_VERIFY" "$TEMP_LIST" 2>/dev/null
    restore_kernel_timeout
    echo -e "\n${NC}"
}

# SIGINT (Ctrl+C): avisar, limpiar y salir con código estándar 130.
on_sigint() {
    ABORT_REQUESTED=1
    echo -e "\n${Y}Interrupción solicitada (Ctrl+C). Cerrando de forma segura...${NC}" >&2
    cleanup_exit
    trap - EXIT
    exit 130
}
ABORT_REQUESTED=0
trap on_sigint SIGINT
trap cleanup_exit SIGTERM EXIT

abort() {
    tput cnorm 2>/dev/null
    echo -e "\n${R}ERROR:${NC} $*" >&2
    exit 1
}

# ===================== COMPROBACIONES DE ARRANQUE =============================
check_root() {
    [ "$EUID" -eq 0 ] || abort "Se requieren privilegios de root."
}

check_utils() {
    declare -A pkg=(
        [hdparm]=hdparm
        [badblocks]=e2fsprogs
        [dd]=coreutils
        [blockdev]=util-linux
        [lsblk]=util-linux
        [findmnt]=util-linux
        [bc]=bc
        [xxd]=xxd
        [smartctl]=smartmontools
        [cmp]=diffutils
    )
    local missing=()
    for util in "${!pkg[@]}"; do
        command -v "$util" >/dev/null 2>&1 || missing+=("$util (apt install ${pkg[$util]})")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${R}Faltan utilidades necesarias:${NC}" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        abort "Instala los paquetes indicados y reintenta."
    fi
}

show_help() {
    cat <<EOF
DISK HEALER v7.2.2 - Reparación segura de sectores defectuosos

Uso: $0 [opciones] <device>

  <device>                 Dispositivo de bloque a procesar (ej. /dev/sdb).
                           ¡Debe estar DESMONTADO!

Opciones:
  -t, --timeout <seg>      Timeout de I/O en segundos (def. 10). Fija el tope
                           del kernel; el timeout de cada operación del script
                           se deriva como (valor - 2). Mín. 3.

  -r, --repair-now         Repara los sectores defectuosos NADA MÁS encontrarlos.
                           Usa un motor híbrido propio (no badblocks): lee en
                           bloques grandes en zona sana y, al detectar un fallo,
                           baja a granularidad de sector y repara cada uno al
                           instante. Ignora --repair-every.

  -b, --block <MB>         Tamaño del bloque de lectura rápida en modo -r (def. 8).
                           Mayor = más rápido en zona sana; menor = re-escanea
                           menos al encontrar un fallo. Sin efecto sin -r.

  -e, --repair-every <pct> Porcentaje del disco que se escanea antes de cada
                           pasada de reparación (def. ${CHUNK_PERCENT}). Acepta decimales
                           (ej. 0.5). Sin efecto si se usa --repair-now.

  -h, --help               Muestra esta ayuda y sale.

Comportamiento por defecto (sin -r ni -e): escanea en chunks del ${CHUNK_PERCENT}% y
repara al terminar cada chunk.

Notas de seguridad:
  - Aborta si el dispositivo o sus particiones están montadas.
  - Verifica la identidad del disco (serial/WWN) antes de cada escritura
    (protección anti-reset USB).
  - Conserva copias de sectores con dato dudoso en ./disk_healer_rescued.
  - Reanuda automáticamente si existe estado previo (.disk_healer_state).
EOF
}

parse_args() {
    DISCO=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--timeout)
                shift
                is_uint "${1:-}" || abort "El valor de -t debe ser un entero en segundos."
                [ "${1:-0}" -lt 3 ] && abort "El timeout mínimo razonable es 3 segundos."
                IO_TIMEOUT=$1
                ;;
            -r|--repair-now)
                REPAIR_NOW=1
                ;;
            -b|--block)
                shift
                is_uint "${1:-}" || abort "El valor de -b debe ser un entero en MB."
                [ "${1:-0}" -lt 1 ] && abort "El bloque mínimo es 1 MB."
                HYBRID_BLOCK_BYTES=$(( $1 * 1024 * 1024 ))
                ;;
            -e|--repair-every)
                shift
                # acepta entero o decimal positivo (ej. 2, 0.5)
                [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || abort "El valor de -e debe ser un porcentaje positivo (ej. 2 o 0.5)."
                # rechazar 0 o valores >100
                if [ "$(echo "${1} <= 0 || ${1} > 100" | bc -l 2>/dev/null)" = "1" ]; then
                    abort "El porcentaje de -e debe estar entre 0 (excl.) y 100."
                fi
                CHUNK_PERCENT=$1
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                abort "Opción desconocida: $1  (usa --help para ver las opciones)"
                ;;
            *)
                DISCO=$1
                ;;
        esac
        shift
    done
    [ -n "$DISCO" ] || abort "Falta el dispositivo. Usa: $0 [opciones] <device>  (--help para ayuda)"
    [ -b "$DISCO" ] || abort "$DISCO no es un dispositivo de bloque válido."
    # Derivar timeout de operación del script (kernel = IO_TIMEOUT)
    OP_TIMEOUT=$(( IO_TIMEOUT - 2 ))
    [ "$OP_TIMEOUT" -lt 1 ] && OP_TIMEOUT=1
    # MB del bloque híbrido (para mostrar en la UI sin recalcular cada refresco)
    HYBRID_BLOCK_BYTES_MB=$(( HYBRID_BLOCK_BYTES / 1024 / 1024 ))
}

check_not_mounted() {
    local mounted
    mounted=$(lsblk -nro NAME,MOUNTPOINT "$DISCO" 2>/dev/null | awk '$2!="" {print $1" -> "$2}')
    if [ -n "$mounted" ]; then
        echo -e "${R}El dispositivo tiene puntos de montaje activos:${NC}" >&2
        echo "$mounted" >&2
        abort "Desmonta todo antes de continuar (umount). Operación abortada por seguridad."
    fi
}

detect_sector_size() {
    SECTOR_SIZE=$(blockdev --getss "$DISCO" 2>/dev/null)
    local phys
    phys=$(blockdev --getpbsz "$DISCO" 2>/dev/null)
    is_uint "$SECTOR_SIZE" || abort "No se pudo determinar el tamaño de sector lógico."
    TOTAL_SECTORS=$(blockdev --getsz "$DISCO" 2>/dev/null)
    is_uint "$TOTAL_SECTORS" || abort "No se pudo determinar el total de sectores."
    if [ "$SECTOR_SIZE" -ne 512 ]; then
        TOTAL_SECTORS=$(( TOTAL_SECTORS * 512 / SECTOR_SIZE ))
    fi
    echo -e "${C}Tamaño de sector:${NC} lógico=${SECTOR_SIZE}  físico=${phys:-?}  | total=${TOTAL_SECTORS} sectores"
    if [ "$SECTOR_SIZE" -ne 512 ]; then
        echo -e "${Y}AVISO:${NC} disco no-512. Validando coherencia de unidades antes de cualquier escritura..."
    fi
}

# Detecta qué opción -d necesita smartctl. Recorre desde "sin opción" (SATA
# directo a placa) hasta los modos de las cajas USB más comunes. Usa también
# la pista de `smartctl --scan` si está disponible.
detect_smart_mode() {
    local opt scan_hint
    # Pista de --scan: puede sugerir directamente el -d adecuado para este disco
    scan_hint=$(smartctl --scan 2>/dev/null | awk -v d="$DISCO" '$1==d {for(i=1;i<=NF;i++) if($i=="-d"){print $(i+1); exit}}')

    # Lista de candidatos en orden razonable. El primero que devuelva atributos gana.
    local candidates=(
        ""                       # SATA/NVMe directo en placa
        "sat"                    # caja USB->SATA estándar (SCSI/ATA Translation)
        "sat,12"                 # variante con comandos de 12 bytes
        "sat,16"                 # variante con comandos de 16 bytes
        "usbjmicron"             # cajas JMicron
        "usbjmicron,x"           # JMicron variante
        "usbsunplus"             # cajas Sunplus
        "usbcypress"             # cajas Cypress
        "usbprolific"            # cajas Prolific
        "scsi"                   # acceso SCSI puro
        "auto"                   # último recurso: autodetección de smartctl
    )
    # Si --scan sugirió algo, probarlo primero
    [ -n "$scan_hint" ] && candidates=("$scan_hint" "${candidates[@]}")

    for opt in "${candidates[@]}"; do
        local dflag=()
        [ -n "$opt" ] && dflag=(-d "$opt")
        if smartctl -A "${dflag[@]}" "$DISCO" 2>/dev/null | grep -qiE 'Reallocated_Sector|Current_Pending'; then
            SMART_DOPT="${dflag[*]}"
            echo -e "${C}SMART accesible${NC} con: ${SMART_DOPT:-(sin -d / acceso directo)}"
            return 0
        fi
    done
    SMART_DOPT=""
    echo -e "${Y}AVISO:${NC} no se pudo leer SMART con ningún modo conocido. Se continúa sin métricas SMART."
    return 1
}

# Captura el serial/WWN del disco para verificar su identidad antes de escribir.
detect_disk_identity() {
    DISK_SERIAL=$(lsblk -dno SERIAL "$DISCO" 2>/dev/null | head -1)
    [ -z "$DISK_SERIAL" ] && DISK_SERIAL=$(lsblk -dno WWN "$DISCO" 2>/dev/null | head -1)
    if [ -z "$DISK_SERIAL" ]; then
        echo -e "${Y}AVISO:${NC} no se pudo obtener serial/WWN. La verificación anti-reset USB quedará deshabilitada."
    else
        echo -e "${C}Identidad del disco:${NC} serial/WWN = $DISK_SERIAL"
    fi
}

# Comprueba que $DISCO sigue siendo EL MISMO disco (USB puede resetear y cambiar
# de letra). Devuelve 0 si coincide o si no hay serial de referencia.
verify_disk_identity() {
    [ -z "$DISK_SERIAL" ] && return 0
    [ -b "$DISCO" ] || return 1
    local now
    now=$(lsblk -dno SERIAL "$DISCO" 2>/dev/null | head -1)
    [ -z "$now" ] && now=$(lsblk -dno WWN "$DISCO" 2>/dev/null | head -1)
    [ "$now" == "$DISK_SERIAL" ]
}

# Baja el timeout del kernel para el disco y guarda el valor original.
set_kernel_timeout() {
    local base
    base=$(basename "$DISCO")
    # resolver a disco base si nos pasaron una partición (sdl1 -> sdl)
    base=$(lsblk -dno PKNAME "$DISCO" 2>/dev/null || echo "$base")
    [ -z "$base" ] && base=$(basename "$DISCO")
    KERNEL_TIMEOUT_PATH="/sys/block/$base/device/timeout"
    if [ -w "$KERNEL_TIMEOUT_PATH" ]; then
        KERNEL_TIMEOUT_ORIG=$(cat "$KERNEL_TIMEOUT_PATH" 2>/dev/null)
        echo "$IO_TIMEOUT" > "$KERNEL_TIMEOUT_PATH" 2>/dev/null \
            && echo -e "${C}Timeout kernel:${NC} $KERNEL_TIMEOUT_PATH = ${IO_TIMEOUT}s (original: ${KERNEL_TIMEOUT_ORIG}s)" \
            || echo -e "${Y}AVISO:${NC} no se pudo escribir el timeout del kernel."
    else
        echo -e "${Y}AVISO:${NC} $KERNEL_TIMEOUT_PATH no escribible. Solo se aplicarán timeouts del script."
        KERNEL_TIMEOUT_PATH=""
    fi
}

restore_kernel_timeout() {
    if [ -n "$KERNEL_TIMEOUT_PATH" ] && [ -n "$KERNEL_TIMEOUT_ORIG" ] && [ -w "$KERNEL_TIMEOUT_PATH" ]; then
        echo "$KERNEL_TIMEOUT_ORIG" > "$KERNEL_TIMEOUT_PATH" 2>/dev/null
    fi
}

read_sector_dd() {
    local sector=$1 out=$2
    timeout "$OP_TIMEOUT" dd if="$DISCO" of="$out" bs="$SECTOR_SIZE" skip="$sector" count=1 \
       iflag=direct status=none 2>/dev/null
}

read_sector_hdparm() {
    local sector=$1 out=$2
    local raw st
    raw=$(timeout "$OP_TIMEOUT" hdparm --read-sector "$sector" "$DISCO" 2>&1)
    st=$?
    if [ $st -ne 0 ]; then
        : > "$out"
        return $st
    fi
    # hdparm imprime el dump como líneas de words hex de 4 dígitos.
    # 1) seleccionar SOLO las líneas que son puro dump (descarta cabecera "reading...").
    # 2) extraer CADA word de 4 hex (incluido el último de la línea, que no lleva
    #    espacio detrás -> la regex antigua lo perdía y devolvía <512 bytes).
    echo "$raw" \
        | grep -iE '^([[:space:]]*[0-9a-f]{4})+[[:space:]]*$' \
        | grep -oiE '[0-9a-f]{4}' \
        | tr -d '\n' \
        | xxd -r -p > "$out"
    return 0
}

validate_unit_coherence() {
    echo -e "${C}Validando coherencia de unidades hdparm/dd...${NC}"
    local test_sector=$(( TOTAL_SECTORS / 2 ))
    local ok=0 tries=0
    while [ $tries -lt 5 ]; do
        if read_sector_dd "$test_sector" "$BIN_DD" \
           && read_sector_hdparm "$test_sector" "$BIN_HDP" \
           && [ -s "$BIN_DD" ] && [ -s "$BIN_HDP" ]; then
            if cmp -s "$BIN_DD" "$BIN_HDP"; then
                ok=1; break
            fi
        fi
        test_sector=$(( test_sector + 1000 ))
        [ "$test_sector" -ge "$TOTAL_SECTORS" ] && break
        tries=$((tries+1))
    done
    if [ $ok -ne 1 ]; then
        abort "hdparm y dd NO coinciden en la unidad de sector. Abortado para no corromper datos. Revisa manualmente."
    fi
    echo -e "${G}OK:${NC} hdparm y dd interpretan el sector de forma idéntica."
    rm -f "$BIN_DD" "$BIN_HDP"
}

# ================================ SMART =======================================
smart_attr() {
    local name=$1
    smartctl -A $SMART_DOPT "$DISCO" 2>/dev/null | awk -v n="$name" '$2==n {print $NF; exit}'
}

show_smart() {
    local title=$1
    echo -e "\n${B}===== SMART ($title) =====${NC}"
    local realloc pending offline
    realloc=$(smart_attr "Reallocated_Sector_Ct")
    pending=$(smart_attr "Current_Pending_Sector")
    offline=$(smart_attr "Offline_Uncorrectable")
    echo -e "  Reallocated_Sector_Ct : ${realloc:-N/A}"
    echo -e "  Current_Pending_Sector: ${pending:-N/A}"
    echo -e "  Offline_Uncorrectable : ${offline:-N/A}"
    eval "SMART_${title}_REALLOC=\${realloc:-0}"
    eval "SMART_${title}_PENDING=\${pending:-0}"
    eval "SMART_${title}_OFFLINE=\${offline:-0}"
}

smart_compare() {
    echo -e "\n${B}===== Comparativa SMART (inicio -> fin) =====${NC}"
    local ri=${SMART_INICIO_REALLOC:-0} rf=${SMART_FIN_REALLOC:-0}
    local pi=${SMART_INICIO_PENDING:-0} pf=${SMART_FIN_PENDING:-0}
    is_uint "$ri" || ri=0; is_uint "$rf" || rf=0
    is_uint "$pi" || pi=0; is_uint "$pf" || pf=0
    echo -e "  Pendientes  : $pi -> $pf"
    echo -e "  Reasignados : $ri -> $rf"
    if [ "$pf" -lt "$pi" ]; then
        echo -e "  ${G}El firmware procesó $((pi - pf)) sector(es) pendiente(s).${NC}"
    fi
    if [ "$rf" -gt "$ri" ]; then
        echo -e "  ${Y}$((rf - ri)) sector(es) fueron remapeados a la zona de reserva.${NC}"
    fi
}

# ============================ MOTOR GRÁFICO ===================================
draw_screen() {
    local mode=$1 sector=$2 total=$3 spinner=$4 status_msg=$5
    local r_sector=${6:-0} st_read=${7:-0} st_resc=${8:-0} st_patch=${9:-0} r_msg=${10:-}

    local percent
    percent=$(echo "scale=2; ${sector:-0} * 100 / ${total:-1}" | bc 2>/dev/null)
    [ -z "$percent" ] && percent="0.00"
    local pending; pending=$(get_pending_count)

    local current_time elapsed sectors_done speed=0 eta_str="--:--:--"
    current_time=$(date +%s)
    elapsed=$((current_time - SESSION_START_TIME))
    sectors_done=$((sector - SESSION_START_SECTOR))
    if [ $elapsed -gt 5 ] && [ $sectors_done -gt 0 ]; then
        speed=$((sectors_done / elapsed))
        if [ $speed -gt 0 ]; then
            local remaining=$((total - sector))
            local eta_seconds=$((remaining / speed))
            eta_str=$(format_seconds $eta_seconds)
        fi
        # un '*' discreto indica que aún quedan reparaciones por hacer (no descuadra)
        [ "$pending" -gt 0 ] && eta_str="${eta_str}*"
    fi

    printf "\033[H"

    # Normalizar percent para que SIEMPRE lleve cero inicial (.93 -> 0.93)
    [[ "$percent" == .* ]] && percent="0$percent"

    # --- Cálculo de elapsed y fin estimado con día ---
    local elapsed_str finish_str="--:--"
    elapsed_str=$(format_seconds "$elapsed")
    if [ $elapsed -gt 5 ] && [ $sectors_done -gt 0 ] && [ "$speed" -gt 0 ]; then
        local remaining2=$((total - sector))
        local eta_seconds2=$((remaining2 / speed))
        finish_str=$(format_finish "$eta_seconds2")
    fi

    # --- Texto de modo activo (sin acentos; cabe en %-11s) ---
    local mode_txt
    if [ "${REPAIR_NOW:-0}" -eq 1 ]; then
        mode_txt="hib ${HYBRID_BLOCK_BYTES_MB:-8}MB"
    else
        mode_txt="blk ${CHUNK_PERCENT}%"
    fi

    local IW=72   # ancho interior entre las barras verticales
    local HBAR; HBAR=$(printf "%0.s${BX_HZ}" $(seq 1 $IW))

    # Encabezado
    echo -e "${B}${BX_TL}${HBAR}${BX_TR}${NC}\033[K"
    printf "${B}${BX_VL}${NC} ${W}%-22s${NC} ${GR}${BX_SEP}${NC} ${C}%-47s${NC} ${B}${BX_VL}${NC}\033[K\n" \
           "DISK HEALER v7.2.2" "$DISCO"
    echo -e "${B}${BX_ML}${HBAR}${BX_MR}${NC}\033[K"

    # Fila de estadísticas (5 contadores)
    printf "${B}${BX_VL}${NC} ${G}%-8s${NC}:%-5d ${GR}${BX_SEP}${NC} ${Y}%-6s${NC}:%-5d ${GR}${BX_SEP}${NC} ${R}%-8s${NC}:%-4d ${GR}${BX_SEP}${NC} ${C}%-7s${NC}:%-4d ${GR}${BX_SEP}${NC} ${P}%-7s${NC}:%-4d ${B}${BX_VL}${NC}\033[K\n" \
           "$L_SAVED" "${TOTAL_SALVADOS:-0}" \
           "$L_ZEROS" "${TOTAL_CEROS:-0}" \
           "$L_FAIL"  "${TOTAL_FALLIDOS:-0}" \
           "$L_DUB"   "${TOTAL_DUDOSOS:-0}" \
           "$L_PEND"  "${pending:-0}"
    echo -e "${B}${BX_ML}${HBAR}${BX_MR}${NC}\033[K"

    # Fila de velocidad / ETA / fin estimado
    printf "${B}${BX_VL}${NC} %-11s:%-9s ${GR}${BX_SEP}${NC} %-11s:%-11s ${GR}${BX_SEP}${NC} %-9s:%-14s ${B}${BX_VL}${NC}\033[K\n" \
           "$L_SPEED" "${speed} s/s" "$L_ETA" "$eta_str" "$L_FINISH" "$finish_str"
    # Fila de elapsed / modo / timeout
    printf "${B}${BX_VL}${NC} %-11s:%-9s ${GR}${BX_SEP}${NC} %-11s:%-11s ${GR}${BX_SEP}${NC} %-9s:%-14s ${B}${BX_VL}${NC}\033[K\n" \
           "$L_ELAPSED" "$elapsed_str" "$L_MODE" "$mode_txt" "$L_TOUT" "${IO_TIMEOUT:-?}s"
    echo -e "${B}${BX_BL}${HBAR}${BX_BR}${NC}\033[K"

    # --- Barra de progreso con color según avance ---
    local width=58 num_filled num_empty filled="" empty=""
    num_filled=$(echo "scale=0; $width * $percent / 100" | bc 2>/dev/null)
    is_uint "$num_filled" || num_filled=0
    [ "$num_filled" -gt "$width" ] && num_filled=$width
    num_empty=$((width - num_filled))
    [ "$num_filled" -gt 0 ] && filled=$(printf "%0.s${BX_FILL}" $(seq 1 "$num_filled"))
    [ "$num_empty" -gt 0 ]  && empty=$(printf "%0.s${BX_EMPTY}" $(seq 1 "$num_empty"))
    local bar_col=$R
    local pint=${percent%.*}; is_uint "$pint" || pint=0
    [ "$pint" -ge 33 ] && bar_col=$Y
    [ "$pint" -ge 66 ] && bar_col=$G

    echo ""
    echo -e "${bar_col}${filled}${GR}${empty}${NC} ${W}${percent}%${NC}\033[K"
    echo -e "${P}[${spinner}]${NC} ${Y}$(fmt_int "$sector")${NC} / $(fmt_int "$total") ${GR}sectores${NC}\033[K"

    if [ "$mode" == "SCAN" ]; then
        echo -e "${G}${L_SCAN}${NC} ${GR}${BX_ARROW}${NC} $status_msg\033[K"
        echo -e "\033[J"
    else
        echo -e "${R}${L_REPAIR}${NC} ${GR}${BX_ARROW}${NC} SECTOR: ${W}$r_sector${NC}\033[K"
        local i_pend="${GR}[ ]${NC}" i_ok="${G}[OK]${NC}" i_fail="${R}[${BX_FAIL}]${NC}" i_try="${Y}[?]${NC}"
        local v_read=$i_pend; [ "$st_read" -eq 1 ] && v_read=$i_ok; [ "$st_read" -eq 2 ] && v_read=$i_fail
        local v_resc=$i_pend; [ "$st_resc" -eq 1 ] && v_resc=$i_try; [ "$st_resc" -eq 2 ] && v_resc=$i_ok; [ "$st_resc" -eq 3 ] && v_resc=$i_fail
        local v_patch=$i_pend; [ "$st_patch" -eq 1 ] && v_patch=$i_ok; [ "$st_patch" -eq 2 ] && v_patch=$i_fail
        local RHBAR; RHBAR=$(printf "%0.s${BX_HZ2}" $(seq 1 56))
        echo -e "${B}${BX_TL2}${RHBAR}${BX_TR2}${NC}\033[K"
        printf "${B}${BX_VL2}${NC} %-19b %-19b %-19b ${B}${BX_VL2}${NC}\033[K\n" "$v_read $L_PH_READ" "$v_resc $L_PH_RESC" "$v_patch $L_PH_ZERO"
        echo -e "${B}${BX_BL2}${RHBAR}${BX_BR2}${NC}\033[K"
        echo -e "${W}Status:${NC} $r_msg\033[K"
        echo -e "\033[J"
    fi
}

# ======================== MONITOR DE BADBLOCKS ================================
monitor_badblocks() {
    local pid=$1 total_sectors=$2
    local spin='-\|/' i=0 last_write_time=0
    sleep 0.5
    local fd_path fd_num
    fd_path=$(ls -l /proc/$pid/fd 2>/dev/null | grep "$DISCO" | awk '{print $9}')
    fd_num=${fd_path:+$(basename "$fd_path")}
    [ -z "$fd_num" ] && fd_num=3

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        if [ -f "/proc/$pid/fdinfo/$fd_num" ]; then
            local pos_bytes
            pos_bytes=$(grep "pos:" "/proc/$pid/fdinfo/$fd_num" 2>/dev/null | awk '{print $2}')
            if [[ "$pos_bytes" =~ ^[0-9]+$ ]]; then
                local current_lba=$(( pos_bytes / SECTOR_SIZE ))
                SECTOR_ACTUAL=$current_lba
                local now; now=$(date +%s)
                if (( now - last_write_time >= BACKUP_INTERVAL )); then
                    write_state "$current_lba"
                    last_write_time=$now
                fi
                draw_screen "SCAN" "$current_lba" "$total_sectors" "${spin:$i:1}" "Monitorizando..."
            fi
        fi
        sleep 0.2
    done
}

# =================== REPARACIÓN DE SECTOR (núcleo seguro) =====================
write_and_verify() {
    local sector=$1 src=$2
    # Salvaguarda anti-reset USB: nunca escribir si el disco cambió de identidad.
    if ! verify_disk_identity; then
        log_msg "ABORTO ESCRITURA sector $sector: el disco no coincide con la identidad inicial ($DISK_SERIAL). Posible reset USB."
        return 4
    fi
    timeout "$OP_TIMEOUT" dd if="$src" of="$DISCO" bs="$SECTOR_SIZE" seek="$sector" count=1 \
       conv=fdatasync,notrunc oflag=direct status=none 2>/dev/null
    local wst=$?
    [ $wst -ne 0 ] && return 2
    read_sector_dd "$sector" "$BIN_VERIFY" || return 3
    cmp -s "$src" "$BIN_VERIFY" && return 0
    return 1
}

zero_sector() {
    local sector=$1
    if ! verify_disk_identity; then
        log_msg "ABORTO ESCRITURA (ceros) sector $sector: el disco no coincide con la identidad inicial. Posible reset USB."
        return 4
    fi
    timeout "$OP_TIMEOUT" dd if=/dev/zero of="$DISCO" bs="$SECTOR_SIZE" seek="$sector" count=1 \
       conv=fdatasync,notrunc oflag=direct status=none 2>/dev/null
    read_sector_dd "$sector" "$BIN_VERIFY"
}

reparar_sector() {
    local sector=$1
    write_state "$sector"
    LAST_REPAIR_DONE=0   # 1 si hubo cualquier intervención de escritura sobre el sector

    update_card() { draw_screen "REPAIR" "$sector" "$TOTAL_SECTORS" "!" "Interviniendo..." "$sector" "$1" "$2" "$3" "$4"; }
    update_card 0 0 0 "Leyendo (dd + hdparm)..."

    local t0 t1 dur
    t0=$(date +%s.%N)
    read_sector_dd "$sector" "$BIN_DD"; local st_dd=$?
    read_sector_hdparm "$sector" "$BIN_HDP"; local st_hdp=$?
    t1=$(date +%s.%N)
    dur=$(echo "$t1 - $t0" | bc 2>/dev/null); [ -z "$dur" ] && dur=0

    local dd_ok=0 hdp_ok=0
    { [ $st_dd -eq 0 ] && [ -s "$BIN_DD" ]; } && dd_ok=1
    { [ $st_hdp -eq 0 ] && [ -s "$BIN_HDP" ]; } && hdp_ok=1

    local es_lento=0
    es_lento=$(echo "$dur > $TIEMPO_MAX" | bc -l 2>/dev/null); [ -z "$es_lento" ] && es_lento=0

    local good_buf="" dudoso=0

    if [ $dd_ok -eq 1 ] && [ $hdp_ok -eq 1 ]; then
        if cmp -s "$BIN_DD" "$BIN_HDP"; then
            good_buf="$BIN_DD"
        else
            update_card 1 1 0 "${Y}Discrepancia. 3a lectura (voto)...${NC}"
            read_sector_dd "$sector" "$BIN_VOTE"
            if [ -s "$BIN_VOTE" ] && cmp -s "$BIN_VOTE" "$BIN_DD"; then
                good_buf="$BIN_DD"
            elif [ -s "$BIN_VOTE" ] && cmp -s "$BIN_VOTE" "$BIN_HDP"; then
                good_buf="$BIN_HDP"
            else
                local z_dd z_hdp
                z_dd=$(tr -d '\000' < "$BIN_DD" | wc -c)
                z_hdp=$(tr -d '\000' < "$BIN_HDP" | wc -c)
                if [ "$z_hdp" -gt "$z_dd" ]; then good_buf="$BIN_HDP"; else good_buf="$BIN_DD"; fi
            fi
            dudoso=1
            ((TOTAL_DUDOSOS++))
            mkdir -p "$RESCUE_DIR"
            cp -f "$BIN_DD"  "$RESCUE_DIR/sector_${sector}_dd.bin"
            cp -f "$BIN_HDP" "$RESCUE_DIR/sector_${sector}_hdparm.bin"
            log_msg "Sector $sector: DISCREPANCIA dd/hdparm. Copias conservadas en $RESCUE_DIR. Dato DUDOSO."
        fi
    elif [ $dd_ok -eq 1 ]; then
        good_buf="$BIN_DD"
    elif [ $hdp_ok -eq 1 ]; then
        good_buf="$BIN_HDP"
    else
        good_buf=""
    fi

    if [ -n "$good_buf" ]; then
        if [ "$es_lento" -eq 1 ] || [ "$dudoso" -eq 1 ]; then
            update_card 2 1 0 "${Y}Reescribiendo dato (refresco/remapeo)...${NC}"
            write_and_verify "$sector" "$good_buf"; local wrc=$?
            LAST_REPAIR_DONE=1
            if [ $wrc -eq 0 ]; then
                ((TOTAL_SALVADOS++))
                local extra=""; [ "$dudoso" -eq 1 ] && extra=" (DUDOSO)"
                log_msg "Sector $sector: SALVADO por reescritura directa (lento=${dur}s)$extra"
                update_card 2 2 1 "${G}Dato reescrito y verificado.${NC}"
            elif [ $wrc -eq 4 ]; then
                abort "El disco cambió de identidad (posible reset USB). Abortado antes de escribir en el dispositivo equivocado."
            else
                mkdir -p "$RESCUE_DIR"
                cp -f "$good_buf" "$RESCUE_DIR/sector_${sector}_FAILED_VERIFY.bin"
                ((TOTAL_FALLIDOS++))
                log_msg "Sector $sector: FALLO de verificación post-escritura. Copia conservada en $RESCUE_DIR."
                update_card 2 3 2 "${R}Fallo verificación. Copia conservada.${NC}"
            fi
        else
            update_card 1 0 0 "${G}Lectura correcta. Sin intervención.${NC}"
        fi
    else
        update_card 2 0 0 "${Y}Sector ilegible. Escribiendo ceros (remapeo)...${NC}"
        zero_sector "$sector"; local zrc=$?
        LAST_REPAIR_DONE=1
        if [ $zrc -eq 0 ]; then
            ((TOTAL_CEROS++))
            log_msg "Sector $sector: ilegible -> ceros escritos, sector ahora legible (remapeado/curado)."
            update_card 2 0 1 "${Y}Remapeado (ceros). Dato original perdido.${NC}"
        elif [ $zrc -eq 4 ]; then
            abort "El disco cambió de identidad (posible reset USB). Abortado antes de escribir en el dispositivo equivocado."
        else
            ((TOTAL_FALLIDOS++))
            log_msg "Sector $sector: FALLO FÍSICO PERMANENTE (ni tras ceros es legible)."
            update_card 2 0 2 "${R}FALLO FÍSICO PERMANENTE.${NC}"
        fi
    fi

    rm -f "$BIN_DD" "$BIN_HDP" "$BIN_VOTE" "$BIN_VERIFY" 2>/dev/null
    sleep 0.4
}

# Tras reparar un sector, reintenta su entorno (±REPAIR_NEIGHBORS) por si el
# remapeo del firmware "destrabó" sectores vecinos. Repara los que sigan fallando.
declare -A PROCESSED_SECTORS
repair_neighbors() {
    local center=$1
    local lo=$(( center - REPAIR_NEIGHBORS ))
    local hi=$(( center + REPAIR_NEIGHBORS ))
    [ $lo -lt 0 ] && lo=0
    [ $hi -ge "$TOTAL_SECTORS" ] && hi=$(( TOTAL_SECTORS - 1 ))
    local s
    for (( s=lo; s<=hi; s++ )); do
        [ "$s" -eq "$center" ] && continue
        [ -n "${PROCESSED_SECTORS[$s]:-}" ] && continue
        if read_sector_dd "$s" "$BIN_VERIFY"; then
            continue   # vecino se lee bien, no se toca
        fi
        PROCESSED_SECTORS[$s]=1
        reparar_sector "$s"
    done
}

# Motor de escaneo HÍBRIDO para el modo -r:
#  - lee en bloques grandes (HYBRID_BLOCK_BYTES) -> rápido en zona sana
#  - si un bloque falla, baja a granularidad de sector y repara CADA sector malo
#    en el instante en que lo detecta, reintentando el entorno tras cada reparación.
scan_hybrid() {
    local start=$1
    local block_sectors=$(( HYBRID_BLOCK_BYTES / SECTOR_SIZE ))
    [ "$block_sectors" -lt 1 ] && block_sectors=1
    local spin='-\|/' i=0 last_write_time=0
    local cur=$start

    while [ "$cur" -lt "$TOTAL_SECTORS" ]; do
        local remaining=$(( TOTAL_SECTORS - cur ))
        local this_block=$block_sectors
        [ "$this_block" -gt "$remaining" ] && this_block=$remaining

        i=$(( (i+1) % 4 ))
        local now; now=$(date +%s)
        if (( now - last_write_time >= BACKUP_INTERVAL )); then
            write_state "$cur"
            last_write_time=$now
        fi
        draw_screen "SCAN" "$cur" "$TOTAL_SECTORS" "${spin:$i:1}" "Lectura rápida por bloques (-r)..."

        # Lectura rápida del bloque entero (a /dev/null, solo para verificar).
        if timeout "$OP_TIMEOUT" dd if="$DISCO" of=/dev/null bs="$SECTOR_SIZE" \
               skip="$cur" count="$this_block" iflag=direct status=none 2>/dev/null; then
            cur=$(( cur + this_block ))            # bloque sano -> avanzar
        else
            # Bloque con fallo -> descender a sector y reparar al instante
            draw_screen "SCAN" "$cur" "$TOTAL_SECTORS" "!" "${Y}Fallo en bloque: descendiendo a sector...${NC}"
            local s end=$(( cur + this_block ))
            for (( s=cur; s<end; s++ )); do
                [ -n "${PROCESSED_SECTORS[$s]:-}" ] && continue
                if ! read_sector_dd "$s" "$BIN_VERIFY"; then
                    PROCESSED_SECTORS[$s]=1
                    reparar_sector "$s"
                    [ "$LAST_REPAIR_DONE" -eq 1 ] && repair_neighbors "$s"
                fi
            done
            cur=$end
        fi
    done
}

# ================================ MAIN ========================================
# --help / -h se atiende ANTES de cualquier comprobación (no requiere root ni utils)
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help; exit 0 ;;
    esac
done

clear
check_root
check_utils
parse_args "$@"
check_not_mounted
detect_sector_size
validate_unit_coherence
detect_smart_mode
detect_disk_identity
set_kernel_timeout

mkdir -p "$RESCUE_DIR"
log_msg "===== INICIO sesión sobre $DISCO (sector=${SECTOR_SIZE}, total=${TOTAL_SECTORS}, timeout=${IO_TIMEOUT}s) ====="
show_smart "INICIO"

# --- Aviso del modo de reparación configurado ---
if [ "$REPAIR_NOW" -eq 1 ]; then
    echo -e "\n${C}Modo:${NC} reparación INMEDIATA (-r), motor híbrido. Bloque=$(( HYBRID_BLOCK_BYTES / 1024 / 1024 )) MB. Repara cada sector al detectarlo."
else
    echo -e "\n${C}Modo:${NC} reparación por bloques. Pasada de reparación cada ${CHUNK_PERCENT}% del disco."
fi
echo -e "${C}Timeout:${NC} kernel=${IO_TIMEOUT}s / operación=${OP_TIMEOUT}s"
if [ "${USE_UNICODE:-0}" -eq 1 ]; then
    echo -e "${C}Interfaz:${NC} Unicode (caja TUI)"
else
    echo -e "${C}Interfaz:${NC} ASCII (terminal sin soporte Unicode detectado)"
fi

# --- Detección de reanudación (antes del ENTER, para que el aviso sea visible) ---
START_SECTOR=0
if [ -f "$STATE_FILE" ]; then
    st_device=$(read_state_value "DEVICE")
    st_last=$(read_state_value "LAST_SECTOR")
    if [ "$st_device" == "$DISCO" ] && is_uint "$st_last" \
       && [ "$st_last" -ge 0 ] && [ "$st_last" -le "$TOTAL_SECTORS" ]; then
        START_SECTOR=$st_last
        SESSION_START_SECTOR=$st_last
        v=$(read_state_value "STATS_SALVADOS");  is_uint "$v" && TOTAL_SALVADOS=$v
        v=$(read_state_value "STATS_CEROS");     is_uint "$v" && TOTAL_CEROS=$v
        v=$(read_state_value "STATS_FALLIDOS");  is_uint "$v" && TOTAL_FALLIDOS=$v
        v=$(read_state_value "STATS_DUDOSOS");   is_uint "$v" && TOTAL_DUDOSOS=$v
        local_pct=$(echo "scale=1; $START_SECTOR * 100 / $TOTAL_SECTORS" | bc 2>/dev/null)
        echo -e "\n${G}>>> SESIÓN ANTERIOR DETECTADA <<<${NC}"
        echo -e "${G}    Reanudando desde el sector $START_SECTOR (${local_pct}% del disco).${NC}"
        echo -e "${GR}    Para empezar de cero: borra .disk_healer_state y relanza.${NC}"
    else
        echo -e "\n${Y}Estado previo inválido o de otro disco. Empezando de cero.${NC}"
        rm -f "$STATE_FILE"
    fi
fi

echo -e "\n${Y}Pulsa ENTER para comenzar el escaneo (Ctrl+C para abortar).${NC}"
# El '|| exit 130' garantiza que un Ctrl+C durante la espera salga limpio
read -r _ || exit 130

tput civis 2>/dev/null

if [ -s "$PENDING_FILE" ]; then
    while IFS= read -r ps; do
        is_uint "$ps" && reparar_sector "$ps"
        sed -i "1d" "$PENDING_FILE"
    done < "$PENDING_FILE"
    rm -f "$PENDING_FILE"
fi

clear
if [ "$REPAIR_NOW" -eq 1 ]; then
    # --- MODO -r: motor híbrido propio (repara cada sector al detectarlo) ---
    scan_hybrid "$START_SECTOR"
else
    # --- MODO normal: badblocks por chunks ---
    CHUNK_SIZE=$(echo "($TOTAL_SECTORS * $CHUNK_PERCENT / 100) / 1" | bc)
    [ "$CHUNK_SIZE" -lt 2048 ] && CHUNK_SIZE=2048

    CURRENT=$START_SECTOR
    while [ "$CURRENT" -lt "$TOTAL_SECTORS" ]; do
        END=$((CURRENT + CHUNK_SIZE))
        [ "$END" -gt "$TOTAL_SECTORS" ] && END=$TOTAL_SECTORS

        # badblocks SOLO LECTURA (-s). NUNCA usar -w (destructivo).
        badblocks -b "$SECTOR_SIZE" -s "$DISCO" "$END" "$CURRENT" > "$TEMP_LIST" 2>/dev/null &
        PID_BB=$!
        monitor_badblocks "$PID_BB" "$TOTAL_SECTORS"

        if [ -s "$TEMP_LIST" ]; then
            cp "$TEMP_LIST" .current_chunk_list
            while IFS= read -r bad_sector; do
                is_uint "$bad_sector" && reparar_sector "$bad_sector"
                sed -i "/^${bad_sector}$/d" "$TEMP_LIST"
            done < .current_chunk_list
            rm -f .current_chunk_list
            : > "$TEMP_LIST"
        fi

        CURRENT=$END
        write_state "$CURRENT"
    done
fi

clear
draw_screen "SCAN" "$TOTAL_SECTORS" "$TOTAL_SECTORS" "OK" "PROCESO FINALIZADO" 0 0 0 0 ""
show_smart "FIN"
smart_compare
log_msg "===== FIN sesión. Salvados=$TOTAL_SALVADOS Ceros=$TOTAL_CEROS Fallidos=$TOTAL_FALLIDOS Dudosos=$TOTAL_DUDOSOS ====="
echo -e "\n${G}FINALIZADO${NC}  (log: $LOG_FILE | copias dudosas: $RESCUE_DIR)"
rm -f "$STATE_FILE"