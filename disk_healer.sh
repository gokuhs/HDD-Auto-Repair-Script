#!/bin/bash

# ==============================================================================
#  ? DISK HEALER v3.2 - IO OPTIMIZED
#  Escritura en disco reducida al mínimo + Captura de señal en tiempo real
# ==============================================================================

# --- CONFIGURACIÓN ---
CHUNK_PERCENT=2
TIEMPO_MAX=1.0       
STATE_FILE=".disk_healer_state"
LOG_FILE="disk_healer_report.log"
TEMP_LIST="/tmp/badblocks_chunk.txt"
BIN_TEMP="/tmp/sector_rescued.bin"
REALTIME_POS_FILE="/tmp/disk_healer_pos.tmp"
BACKUP_INTERVAL=10   # Segundos entre escrituras de seguridad
# ---------------------

# Colores y UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

tput civis # Ocultar cursor

# --- TRAP INTELIGENTE: LECTURA DIRECTA DEL KERNEL ---
cleanup_exit() {
    tput cnorm
    
    # Si tenemos un PID de badblocks activo, leemos su posición AHORA MISMO
    # Esto evita tener que escribir en disco constantemente durante la ejecución.
    if [ -n "$PID_BB" ] && kill -0 "$PID_BB" 2>/dev/null; then
        
        # Lógica de extracción directa de /proc (sin archivos intermedios)
        fd_path=$(ls -l /proc/$PID_BB/fd 2>/dev/null | grep "$DISCO" | awk '{print $9}')
        fd_num=${fd_path:+$(basename $fd_path)}
        [ -z "$fd_num" ] && fd_num=3
        
        if [ -f "/proc/$PID_BB/fdinfo/$fd_num" ]; then
            pos_bytes=$(grep "pos:" /proc/$PID_BB/fdinfo/$fd_num | awk '{print $2}')
            if [[ "$pos_bytes" =~ ^[0-9]+$ ]]; then
                LAST_POS=$((pos_bytes / 512))
                
                # Guardamos estado
                echo "DEVICE=$DISCO" > $STATE_FILE
                echo "LAST_SECTOR=$LAST_POS" >> $STATE_FILE
                echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
                echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
                echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
                
                echo -e "\n\n${YELLOW}??  INTERRUPCIÓN (Ctrl+C).${NC}"
                echo -e "? Posición capturada del Kernel: ${CYAN}$LAST_POS${NC}"
            fi
        fi
    elif [ -f "$REALTIME_POS_FILE" ]; then
        # Fallback: Si el proceso ya murió, usamos el último backup de 10s
        LAST_POS=$(cat $REALTIME_POS_FILE)
        echo "DEVICE=$DISCO" > $STATE_FILE
        echo "LAST_SECTOR=$LAST_POS" >> $STATE_FILE
        # ... (resto de stats)
        echo -e "\n\n${YELLOW}??  INTERRUPCIÓN.${NC}"
        echo -e "? Usando último backup de seguridad: ${CYAN}$LAST_POS${NC}"
    fi

    jobs -p | xargs -r kill > /dev/null 2>&1
    rm -f $TEMP_LIST $BIN_TEMP $REALTIME_POS_FILE
    echo -e "${YELLOW}Salida limpia.${NC}"
    exit
}
trap cleanup_exit SIGINT SIGTERM EXIT

# 1. VERIFICACIONES
if [ "$EUID" -ne 0 ]; then echo -e "${RED}? Root requerido.${NC}"; exit 1; fi
if [ -z "$1" ]; then echo -e "${YELLOW}Uso: $0 <dispositivo>${NC}"; exit 1; fi
DISCO=$1

DEPENDENCIAS=("hdparm" "dd" "xxd" "bc" "badblocks")
for dep in "${DEPENDENCIAS[@]}"; do
    if ! command -v $dep &> /dev/null; then echo -e "${RED}? Falta: $dep${NC}"; exit 1; fi
done

# --- DASHBOARD ---
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

    printf "\r${BLUE}Progreso Global:${NC} [${filled}${empty}] ${CYAN}${percent}%%${NC}"
    printf "\n\033[K${PURPLE}[${spinner}]${NC} Sector: ${YELLOW}%'d${NC} / %'d" "$sector_actual" "$total"
    printf "\n\033[K${NC}Estado: $status_msg"
    printf "\033[2A" 
}

# --- MONITOR OPTIMIZADO (Solo escribe cada 10s) ---
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
                
                # --- OPTIMIZACIÓN AQUÍ ---
                # Solo escribimos en disco si han pasado 10 segundos
                local current_time=$(date +%s)
                if (( current_time - last_write_time >= BACKUP_INTERVAL )); then
                    echo "$current_sector_lba" > $REALTIME_POS_FILE
                    last_write_time=$current_time
                fi
                # -------------------------

                local percent=$(echo "scale=2; $current_sector_lba * 100 / $total_sectors" | bc)
                draw_dashboard "$current_sector_lba" "$total_sectors" "$percent" "Escaneando..." "${spin:$i:1}"
            fi
        fi
        sleep 0.2
    done
}

# --- LÓGICA DE REPARACIÓN (v5.1) ---
reparar_sector() {
    local sector=$1
    local modo_rescate=0
    
    printf "\r\033[K\n\033[K\n\033[K" 
    printf "\033[2A" 

    echo -e "\n${RED}? DETECTADO SECTOR DEFECTUOSO: $sector${NC}"

    start_t=$(date +%s.%N)
    raw_output=$(hdparm --read-sector "$sector" "$DISCO" 2>&1)
    status_read=$?
    end_t=$(date +%s.%N)
    duracion=$(echo "$end_t - $start_t" | bc)

    procesar=0
    if [ $status_read -ne 0 ]; then
        echo -e "   ? Ilegible. Iniciando destrucción." | tee -a $LOG_FILE
        procesar=1; modo_rescate=0
    else
        es_lento=$(echo "$duracion > $TIEMPO_MAX" | bc -l)
        if [ "$es_lento" -eq 1 ]; then
            echo -e "   ??  Lento (${duracion}s). Intentando rescate." | tee -a $LOG_FILE
            procesar=1; modo_rescate=1
        else
            echo -e "   ? Falsa alarma (Lectura OK)."
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
                echo -e "${GREEN}   ? DATO RESTAURADO.${NC}" | tee -a $LOG_FILE
                ((TOTAL_SALVADOS++))
            else
                 hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
                 echo -e "${YELLOW}   ? SECTOR REEMPLAZADO (Ceros).${NC}" | tee -a $LOG_FILE
                 ((TOTAL_CEROS++))
            fi
        else
            hdparm --read-sector "$sector" "$DISCO" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo -e "${YELLOW}   ? SECTOR REEMPLAZADO (Ceros).${NC}" | tee -a $LOG_FILE
                ((TOTAL_CEROS++))
            else
                echo -e "${RED}   ? FALLO FÍSICO PERMANENTE.${NC}" | tee -a $LOG_FILE
                ((TOTAL_FALLIDOS++))
            fi
        fi
    fi
    sleep 1
    echo "---------------------------------------------------"
}


# --- MAIN ---
TOTAL_SECTORS=$(blockdev --getsz $DISCO)
START_SECTOR=0

if [ -f "$STATE_FILE" ]; then
    source $STATE_FILE
    if [ "$DEVICE" == "$DISCO" ]; then
        echo -e "${YELLOW}? REANUDANDO SESIÓN${NC}"
        echo -e "   Último sector: ${CYAN}$LAST_SECTOR${NC}"
        START_SECTOR=$LAST_SECTOR
        TOTAL_SALVADOS=${STATS_SALVADOS:-0}
        TOTAL_CEROS=${STATS_CEROS:-0}
        TOTAL_FALLIDOS=${STATS_FALLIDOS:-0}
        sleep 2
    else
        echo -e "${RED}??  Archivo de estado antiguo borrado.${NC}"
        rm $STATE_FILE
    fi
fi

CHUNK_SIZE=$(echo "$TOTAL_SECTORS * $CHUNK_PERCENT / 100" | bc)
if [ "$CHUNK_SIZE" -lt 2048 ]; then CHUNK_SIZE=2048; fi 

clear
echo "==================================================="
echo -e "${CYAN} ??  DISK HEALER v3.2 - IO OPTIMIZED${NC}"
echo " ? Objetivo: $DISCO"
echo " ? Total: $(echo "$TOTAL_SECTORS / 2 / 1024" | bc) MB"
echo "==================================================="
echo "" 

CURRENT=$START_SECTOR

while [ $CURRENT -lt $TOTAL_SECTORS ]; do
    END=$((CURRENT + CHUNK_SIZE))
    if [ $END -gt $TOTAL_SECTORS ]; then END=$TOTAL_SECTORS; fi
    
    badblocks -b 512 -s $DISCO $END $CURRENT > $TEMP_LIST 2> /dev/null &
    PID_BB=$!  # HACEMOS GLOBAL EL PID PARA EL TRAP
    
    monitor_badblocks $PID_BB $TOTAL_SECTORS

    if [ -s $TEMP_LIST ]; then
        printf "\n\n"
        while IFS= read -r bad_sector; do
            reparar_sector "$bad_sector"
        done < $TEMP_LIST
    fi

    CURRENT=$END
    
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$CURRENT" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
done

printf "\n\n"
echo "==================================================="
echo -e "${GREEN}? FINALIZADO${NC}"
echo "==================================================="
rm -f $STATE_FILE
