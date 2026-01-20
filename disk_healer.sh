#!/bin/bash

# ==============================================================================
#  ? DISK HEALER v4.2 - BULLETPROOF EDITION
#  Fix: State update during repair phase to prevent skipping sectors on interrupt
# ==============================================================================

# --- CONFIG / CONFIGURACIÓN ---
CHUNK_PERCENT=2
TIEMPO_MAX=1.0       
STATE_FILE=".disk_healer_state"
LOG_FILE="disk_healer_report.log"
TEMP_LIST="/tmp/badblocks_chunk.txt"
BIN_TEMP="/tmp/sector_rescued.bin"
REALTIME_POS_FILE="/tmp/disk_healer_pos.tmp"
BACKUP_INTERVAL=10
# ---------------------

# UI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# --- LANGUAGE DETECTION ---
detect_language() {
    if [[ "$LANG" == *"es_"* ]]; then
        TXT_ROOT="? Se requieren privilegios de Root (sudo)."
        TXT_USAGE="Uso: $0 <dispositivo>"
        TXT_MISSING="? Falta herramienta:"
        TXT_INTERRUPT="??  INTERRUPCIÓN DETECTADA."
        TXT_RESUME_POS="? Posición guardada:"
        TXT_BACKUP_POS="? Usando último backup:"
        TXT_EXIT="Salida limpia."
        TXT_PROG_GLOBAL="Progreso Global:"
        TXT_SECTOR="Sector:"
        TXT_STATUS="Estado:"
        TXT_SCANNING="Escaneando..."
        TXT_REPAIRING="Reparando..."
        TXT_DETECTED="? SECTOR DEFECTUOSO DETECTADO:"
        TXT_UNREADABLE="   ? Ilegible. Iniciando destrucción."
        TXT_SLOW="   ??  Lento (%ss). Intentando rescate."  
        TXT_FALSE_ALARM="   ? Falsa alarma (Lectura OK)."
        TXT_RESTORED="   ? DATO RESTAURADO."
        TXT_REPLACED="   ? SECTOR REEMPLAZADO (Ceros)."
        TXT_PERM_FAIL="   ? FALLO FÍSICO PERMANENTE."
        TXT_RESUME_SESSION="? REANUDANDO SESIÓN"
        TXT_LAST_SECTOR="   Último sector:"
        TXT_OLD_STATE="??  Archivo de estado antiguo borrado."
        TXT_HEADER=" ??  DISK HEALER v4.2 - MONITOR"
        TXT_TARGET=" ? Objetivo:"
        TXT_SIZE=" ? Total:"
        TXT_FINISHED="? OPERACIÓN FINALIZADA"
        TXT_SAVED=" ? Salvados :"
        TXT_ZEROS=" ? Ceros    :"
    else
        TXT_ROOT="? Root privileges required (sudo)."
        TXT_USAGE="Usage: $0 <device>"
        TXT_MISSING="? Missing tool:"
        TXT_INTERRUPT="??  INTERRUPTION DETECTED."
        TXT_RESUME_POS="? Position saved:"
        TXT_BACKUP_POS="? Using last backup:"
        TXT_EXIT="Clean exit."
        TXT_PROG_GLOBAL="Global Progress:"
        TXT_SECTOR="Sector:"
        TXT_STATUS="Status:"
        TXT_SCANNING="Scanning..."
        TXT_REPAIRING="Repairing..."
        TXT_DETECTED="? BAD SECTOR DETECTED:"
        TXT_UNREADABLE="   ? Unreadable. Starting destruction."
        TXT_SLOW="   ??  Slow (%ss). Attempting rescue."
        TXT_FALSE_ALARM="   ? False alarm (Read OK)."
        TXT_RESTORED="   ? DATA RESTORED."
        TXT_REPLACED="   ? SECTOR REPLACED (Zeros)."
        TXT_PERM_FAIL="   ? PERMANENT PHYSICAL FAILURE."
        TXT_RESUME_SESSION="? RESUMING SESSION"
        TXT_LAST_SECTOR="   Last sector:"
        TXT_OLD_STATE="??  Old state file removed."
        TXT_HEADER=" ??  DISK HEALER v4.2 - MONITOR"
        TXT_TARGET=" ? Target:"
        TXT_SIZE=" ? Total:"
        TXT_FINISHED="? OPERATION FINISHED"
        TXT_SAVED=" ? Saved    :"
        TXT_ZEROS=" ? Zeros    :"
    fi
}
detect_language

tput civis

# --- TRAP ---
cleanup_exit() {
    tput cnorm
    # Prioridad: 1. Estado actual (si existe). 2. Archivo realtime. 3. Archivo backup
    if [ -f "$STATE_FILE" ]; then
         # Leemos el último estado guardado (que ahora se actualiza al reparar)
         LAST_POS=$(grep "LAST_SECTOR" $STATE_FILE | cut -d= -f2)
         echo -e "\n\n${YELLOW}${TXT_INTERRUPT}${NC}"
         echo -e "${TXT_RESUME_POS} ${CYAN}$LAST_POS${NC}"
    fi

    jobs -p | xargs -r kill > /dev/null 2>&1
    rm -f $TEMP_LIST $BIN_TEMP $REALTIME_POS_FILE
    echo -e "${YELLOW}${TXT_EXIT}${NC}"
    exit
}
trap cleanup_exit SIGINT SIGTERM EXIT

# CHECKS
if [ "$EUID" -ne 0 ]; then echo -e "${RED}${TXT_ROOT}${NC}"; exit 1; fi
if [ -z "$1" ]; then echo -e "${YELLOW}${TXT_USAGE}${NC}"; exit 1; fi
DISCO=$1

DEPENDENCIAS=("hdparm" "dd" "xxd" "bc" "badblocks")
for dep in "${DEPENDENCIAS[@]}"; do
    if ! command -v $dep &> /dev/null; then echo -e "${RED}${TXT_MISSING} $dep${NC}"; exit 1; fi
done

# --- UI FUNCTIONS ---
draw_dashboard() {
    local sector_actual=$1
    local total=$2
    local percent=$3
    local status_msg=$4
    local spinner=$5

    local width=50
    local num_filled=$(echo "scale=0; $width * $percent / 100" | bc)
    local num_empty=$((width - num_filled))
    local filled=$(printf "%0.s?" $(seq 1 $num_filled))
    local empty=$(printf "%0.s?" $(seq 1 $num_empty))

    printf "\r${BLUE}${TXT_PROG_GLOBAL}${NC} [${filled}${empty}] ${CYAN}${percent}%%${NC}"
    printf "\n\033[K${PURPLE}[${spinner}]${NC} ${TXT_SECTOR} ${YELLOW}%'d${NC} / %'d" "$sector_actual" "$total"
    printf "\n\033[K${NC}${TXT_STATUS} $status_msg"
    printf "\033[2A" 
}

monitor_badblocks() {
    local pid=$1
    local total_sectors=$2
    local spin='-\|/'
    local i=0
    local last_write_time=0

    sleep 0.5 
    local fd_path=$(ls -l /proc/$pid/fd 2>/dev/null | grep "$DISCO" | awk '{print $9}')
    local fd_num=${fd_path:+$(basename $fd_path)}
    [ -z "$fd_num" ] && fd_num=3

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        if [ -f "/proc/$pid/fdinfo/$fd_num" ]; then
            local pos_bytes=$(grep "pos:" /proc/$pid/fdinfo/$fd_num | awk '{print $2}')
            if [[ "$pos_bytes" =~ ^[0-9]+$ ]]; then
                local current_sector_lba=$((pos_bytes / 512))
                local current_time=$(date +%s)
                if (( current_time - last_write_time >= BACKUP_INTERVAL )); then
                    # Guardamos estado también durante el escaneo
                    echo "DEVICE=$DISCO" > $STATE_FILE
                    echo "LAST_SECTOR=$current_sector_lba" >> $STATE_FILE
                    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
                    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
                    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
                    last_write_time=$current_time
                fi
                local percent=$(echo "scale=2; $current_sector_lba * 100 / $total_sectors" | bc)
                draw_dashboard "$current_sector_lba" "$total_sectors" "$percent" "$TXT_SCANNING" "${spin:$i:1}"
            fi
        fi
        sleep 0.2
    done
}

reparar_sector() {
    local sector=$1
    local modo_rescate=0
    
    # >>> FIX v4.2: ACTUALIZAR ESTADO AL ENTRAR EN REPARACIÓN <<<
    # Esto asegura que si cortas aquí, reanudas AQUÍ, no al final del bloque.
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$sector" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
    # >>> FIN FIX <<<

    printf "\r\033[K\n\033[K\n\033[K" 
    printf "\033[2A" 
    
    # Actualizar Dashboard visualmente para indicar reparación
    local percent=$(echo "scale=2; $sector * 100 / $TOTAL_SECTORS" | bc)
    draw_dashboard "$sector" "$TOTAL_SECTORS" "$percent" "${RED}${TXT_REPAIRING}${NC}" "!"

    printf "\n\n${RED}${TXT_DETECTED} $sector${NC}"

    start_t=$(date +%s.%N)
    raw_output=$(hdparm --read-sector "$sector" "$DISCO" 2>&1)
    status_read=$?
    end_t=$(date +%s.%N)
    duracion=$(echo "$end_t - $start_t" | bc)

    procesar=0
    if [ $status_read -ne 0 ]; then
        echo -e "${TXT_UNREADABLE}" | tee -a $LOG_FILE
        procesar=1; modo_rescate=0
    else
        es_lento=$(echo "$duracion > $TIEMPO_MAX" | bc -l)
        if [ "$es_lento" -eq 1 ]; then
            printf "${TXT_SLOW}\n" "$duracion" | tee -a $LOG_FILE
            procesar=1; modo_rescate=1
        else
            echo -e "${TXT_FALSE_ALARM}"
            procesar=0
        fi
    fi

    if [ $procesar -eq 1 ]; then
        if [ $modo_rescate -eq 1 ]; then
            hex_dump=$(echo "$raw_output" | grep -E "^[0-9a-fA-F]{4}" | tr -d ' \r\n')
            echo "$hex_dump" | xxd -r -p > "$BIN_TEMP"
            [ $(stat -c%s "$BIN_TEMP") -ne 512 ] && modo_rescate=0
        fi

        hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
        sleep 0.5

        if [ $modo_rescate -eq 1 ]; then
            dd if="$BIN_TEMP" of="$DISCO" bs=512 count=1 seek="$sector" conv=fdatasync status=none
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${TXT_RESTORED}${NC}" | tee -a $LOG_FILE
                ((TOTAL_SALVADOS++))
            else
                 hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
                 echo -e "${YELLOW}${TXT_REPLACED}${NC}" | tee -a $LOG_FILE
                 ((TOTAL_CEROS++))
            fi
        else
            hdparm --read-sector "$sector" "$DISCO" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo -e "${YELLOW}${TXT_REPLACED}${NC}" | tee -a $LOG_FILE
                ((TOTAL_CEROS++))
            else
                echo -e "${RED}${TXT_PERM_FAIL}${NC}" | tee -a $LOG_FILE
                ((TOTAL_FALLIDOS++))
            fi
        fi
    fi
    sleep 1
    printf "\033[2A" # Volver a subir para mantener dashboard limpio
}

# --- MAIN ---
TOTAL_SECTORS=$(blockdev --getsz $DISCO)
START_SECTOR=0

if [ -f "$STATE_FILE" ]; then
    source $STATE_FILE
    if [ "$DEVICE" == "$DISCO" ]; then
        echo -e "${YELLOW}${TXT_RESUME_SESSION}${NC}"
        echo -e "${TXT_LAST_SECTOR} ${CYAN}$LAST_SECTOR${NC}"
        START_SECTOR=$LAST_SECTOR
        TOTAL_SALVADOS=${STATS_SALVADOS:-0}
        TOTAL_CEROS=${STATS_CEROS:-0}
        TOTAL_FALLIDOS=${STATS_FALLIDOS:-0}
        sleep 2
    else
        echo -e "${RED}${TXT_OLD_STATE}${NC}"
        rm $STATE_FILE
    fi
fi

CHUNK_SIZE=$(echo "$TOTAL_SECTORS * $CHUNK_PERCENT / 100" | bc)
if [ "$CHUNK_SIZE" -lt 2048 ]; then CHUNK_SIZE=2048; fi 

clear
echo "==================================================="
echo -e "${CYAN}${TXT_HEADER}${NC}"
echo "${TXT_TARGET} $DISCO"
echo "${TXT_SIZE} $(echo "$TOTAL_SECTORS / 2 / 1024" | bc) MB"
echo "==================================================="
echo "" 

CURRENT=$START_SECTOR

while [ $CURRENT -lt $TOTAL_SECTORS ]; do
    END=$((CURRENT + CHUNK_SIZE))
    if [ $END -gt $TOTAL_SECTORS ]; then END=$TOTAL_SECTORS; fi
    
    # IMPORTANTE: Al reanudar, badblocks empezará exactamente donde lo dejamos
    badblocks -b 512 -s $DISCO $END $CURRENT > $TEMP_LIST 2> /dev/null &
    PID_BB=$!
    
    monitor_badblocks $PID_BB $TOTAL_SECTORS

    if [ -s $TEMP_LIST ]; then
        printf "\n\n"
        while IFS= read -r bad_sector; do
            reparar_sector "$bad_sector"
        done < $TEMP_LIST
        # Limpiar salida visual tras reparar bloque
        printf "\n"
    fi

    CURRENT=$END
    
    # Guardado de fin de bloque
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$CURRENT" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
done

printf "\n\n"
echo "==================================================="
echo -e "${GREEN}${TXT_FINISHED}${NC}"
echo "${TXT_SAVED} $TOTAL_SALVADOS"
echo "${TXT_ZEROS} $TOTAL_CEROS"
echo "==================================================="
rm -f $STATE_FILE