#!/bin/bash

# ==============================================================================
#  ? DISK HEALER v6.1 - STABLE UI (ASCII & STATIC REFRESH)
#  Corregido: Caracteres compatibles, contador real y tabla estática.
# ==============================================================================

# --- CONFIG ---
CHUNK_PERCENT=2
TIEMPO_MAX=1.0       
STATE_FILE=".disk_healer_state"
PENDING_FILE=".disk_healer_pending"
LOG_FILE="disk_healer_report.log"
TEMP_LIST="/tmp/badblocks_chunk.txt"
BIN_TEMP="/tmp/sector_rescued.bin"
REALTIME_POS_FILE="/tmp/disk_healer_pos.tmp"
BACKUP_INTERVAL=10
# --------------

# Colores
R='\033[0;31m'   # Rojo
G='\033[0;32m'   # Verde
Y='\033[1;33m'   # Amarillo
B='\033[0;34m'   # Azul
C='\033[0;36m'   # Cyan
P='\033[0;35m'   # Purpura
W='\033[1;37m'   # Blanco
GR='\033[0;90m'  # Gris
NC='\033[0m'     # Reset

# Variables de Sesión
SESSION_START_TIME=$(date +%s)
SESSION_START_SECTOR=0
TOTAL_PENDING_COUNT=0 

# --- IDIOMA ---
detect_language() {
    if [[ "$LANG" == *"es_"* ]]; then
        L_STATS="ESTADISTICAS"
        L_SAVED="Salvados"
        L_ZEROS="Ceros"
        L_FAIL="Fallidos"
        L_PEND="Pendientes"
        L_SPEED="Velocidad"
        L_ETA="T. Restante"
        L_FINISH="Fin Estimado"
        L_SCAN="ESCANEANDO"
        L_REPAIR="REPARANDO"
        L_PLUS_REPAIR="(+ Reparacion)"
        L_PH_READ="Lectura"
        L_PH_RESC="Rescate"
        L_PH_ZERO="Ceros"
    else
        L_STATS="STATISTICS"
        L_SAVED="Saved"
        L_ZEROS="Zeros"
        L_FAIL="Failed"
        L_PEND="Pending"
        L_SPEED="Speed"
        L_ETA="ETA"
        L_FINISH="Est. Finish"
        L_SCAN="SCANNING"
        L_REPAIR="REPAIRING"
        L_PLUS_REPAIR="(+ Repair)"
        L_PH_READ="Read"
        L_PH_RESC="Rescue"
        L_PH_ZERO="Zeros"
    fi
}
detect_language
tput civis # Ocultar cursor

# --- UTILS ---
format_seconds() {
    local T=$1
    local H=$((T/3600))
    local M=$(( (T%3600)/60 ))
    local S=$((T%60))
    printf "%02d:%02d:%02d" $H $M $S
}

get_pending_count() {
    # Cuenta líneas en el archivo temporal actual y en el archivo de pendientes global
    local c1=0
    local c2=0
    if [ -f "$TEMP_LIST" ]; then c1=$(grep -cve '^\s*$' "$TEMP_LIST" || echo 0); fi
    if [ -f "$PENDING_FILE" ]; then c2=$(grep -cve '^\s*$' "$PENDING_FILE" || echo 0); fi
    # Si estamos dentro del loop de reparación, restamos 1 (el actual que ya no está en la lista pero se está procesando)
    # Pero para simplificar visualmente, la suma directa suele ser suficiente referencia
    echo $((c1 + c2))
}

cleanup_exit() {
    tput cnorm
    if [ -s "$TEMP_LIST" ]; then
        cat "$TEMP_LIST" >> "$PENDING_FILE"
        sort -u "$PENDING_FILE" -o "$PENDING_FILE"
    fi
    jobs -p | xargs -r kill > /dev/null 2>&1
    rm -f $TEMP_LIST $BIN_TEMP $REALTIME_POS_FILE
    echo -e "\n${NC}"
    exit
}
trap cleanup_exit SIGINT SIGTERM EXIT

# CHECKS
if [ "$EUID" -ne 0 ]; then echo "Root required"; exit 1; fi
DISCO=$1
if [ -z "$DISCO" ]; then echo "Uso: $0 <device>"; exit 1; fi

# --- MOTOR GRÁFICO (Dibuja toda la pantalla de una vez) ---

draw_screen() {
    local mode=$1        # "SCAN" o "REPAIR"
    local sector=$2
    local total=$3
    local spinner=$4
    local status_msg=$5
    
    # Datos específicos de reparación
    local r_sector=$6
    local st_read=$7
    local st_resc=$8
    local st_patch=$9
    local r_msg=${10}

    # Cálculos Generales
    local percent=$(echo "scale=2; $sector * 100 / $total" | bc)
    local pending=$(get_pending_count)
    
    # Cálculo ETA
    local current_time=$(date +%s)
    local elapsed=$((current_time - SESSION_START_TIME))
    local sectors_done=$((sector - SESSION_START_SECTOR))
    local speed=0
    local eta_str="--:--:--"
    local finish_str="--:--"
    
    if [ $elapsed -gt 5 ] && [ $sectors_done -gt 0 ]; then
        speed=$((sectors_done / elapsed))
        local remaining=$((total - sector))
        local eta_seconds=$((remaining / speed))
        eta_str=$(format_seconds $eta_seconds)
        finish_str=$(date -d "+$eta_seconds seconds" +"%H:%M")
        if [ "$pending" -gt 0 ]; then eta_str="$eta_str $L_PLUS_REPAIR"; fi
    fi

    # --- INICIO PINTADO ---
    # Mover cursor a HOME (0,0) para sobrescribir todo sin scroll
    printf "\033[H"

    # 1. HEADER (ASCII Box)
    echo -e "${B}+------------------------------------------------------------------------+${NC}"
    printf "${B}|${NC} %-25s ${GR}|${NC} %-41s ${B}|${NC}\n" "${W}DISK HEALER v6.1${NC}" "${C}$DISCO${NC}"
    echo -e "${B}+------------------------------------------------------------------------+${NC}"
    printf "${B}|${NC} ${G}%-10s${NC} : %-4d ${GR}|${NC} ${Y}%-10s${NC} : %-4d ${GR}|${NC} ${R}%-10s${NC} : %-4d ${GR}|${NC} ${P}%-10s${NC} : %-4d ${B}|${NC}\n" \
           "$L_SAVED" "$TOTAL_SALVADOS" "$L_ZEROS" "$TOTAL_CEROS" "$L_FAIL" "$TOTAL_FALLIDOS" "$L_PEND" "$pending"
    echo -e "${B}+------------------------------------------------------------------------+${NC}"
    printf "${B}|${NC} %-10s : %-7s ${GR}|${NC} %-10s : %-19s ${GR}|${NC} %-10s : %-5s ${B}|${NC}\n" \
           "$L_SPEED" "${speed} s/s" "$L_ETA" "$eta_str" "$L_FINISH" "$finish_str"
    echo -e "${B}+------------------------------------------------------------------------+${NC}"

    # 2. PROGRESO GLOBAL
    local width=50
    local num_filled=$(echo "scale=0; $width * $percent / 100" | bc)
    local num_empty=$((width - num_filled))
    local filled=$(printf "%0.s#" $(seq 1 $num_filled))
    local empty=$(printf "%0.s." $(seq 1 $num_empty))
    
    echo ""
    echo -e "${B}[${filled}${empty}]${NC} ${C}${percent}%${NC}"
    echo -e "${P}[${spinner}]${NC} ${Y}$(printf "%'d" $sector)${NC} / $(printf "%'d" $total)"
    
    if [ "$mode" == "SCAN" ]; then
        echo -e "${G}$L_SCAN${NC} - $status_msg\033[K"
        # Limpiar líneas de abajo por si había una tarjeta de reparación antes
        echo -e "\033[J" 
    else
        # 3. TARJETA DE REPARACIÓN (Solo visible en modo REPAIR)
        echo -e "${R}$L_REPAIR${NC} >>> SECTOR: ${W}$r_sector${NC}\033[K"
        
        # Iconos estado
        local i_pend="${GR}[ ]${NC}"
        local i_ok="${G}[OK]${NC}"
        local i_fail="${R}[FAIL]${NC}"
        local i_try="${Y}[?]${NC}"

        local v_read=$i_pend; [ $st_read -eq 1 ] && v_read=$i_ok; [ $st_read -eq 2 ] && v_read=$i_fail
        local v_resc=$i_pend; [ $st_resc -eq 1 ] && v_resc=$i_try; [ $st_resc -eq 2 ] && v_resc=$i_ok; [ $st_resc -eq 3 ] && v_resc=$i_fail
        local v_patch=$i_pend; [ $st_patch -eq 1 ] && v_patch=$i_ok; [ $st_patch -eq 2 ] && v_patch=$i_fail

        echo -e "${B}+--------------------------------------------------------+${NC}"
        printf "${B}|${NC} %-18b %-18b %-18b ${B}|${NC}\n" "$v_read $L_PH_READ" "$v_resc $L_PH_RESC" "$v_patch $L_PH_ZERO"
        echo -e "${B}+--------------------------------------------------------+${NC}"
        echo -e "${W}Status:${NC} $r_msg\033[K"
        echo -e "\033[J" # Limpiar resto de pantalla
    fi
}

# --- LÓGICA PRINCIPAL ---

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
                SECTOR_ACTUAL=$current_sector_lba
                
                # Guardado periódico
                local current_time=$(date +%s)
                if (( current_time - last_write_time >= BACKUP_INTERVAL )); then
                    echo "DEVICE=$DISCO" > $STATE_FILE
                    echo "LAST_SECTOR=$current_sector_lba" >> $STATE_FILE
                    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
                    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
                    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
                    last_write_time=$current_time
                fi

                # LLAMADA AL MOTOR GRÁFICO (Modo SCAN)
                draw_screen "SCAN" "$current_sector_lba" "$total_sectors" "${spin:$i:1}" "Monitorizando..." 
            fi
        fi
        sleep 0.2
    done
}

reparar_sector() {
    local sector=$1
    local modo_rescate=0
    
    # Save State
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$sector" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE

    # Función helper para redibujar rápido dentro de esta función
    # Argumentos: (st_read, st_resc, st_patch, mensaje)
    update_card() {
        draw_screen "REPAIR" "$sector" "$TOTAL_SECTORS" "!" "Interviniendo..." "$sector" "$1" "$2" "$3" "$4"
    }

    # --- FASE 1: LECTURA ---
    update_card 0 0 0 "Analizando sector..."

    start_t=$(date +%s.%N)
    raw_output=$(hdparm --read-sector "$sector" "$DISCO" 2>&1)
    status_read=$?
    end_t=$(date +%s.%N)
    duracion=$(echo "$end_t - $start_t" | bc)

    procesar=0
    if [ $status_read -ne 0 ]; then
        echo "LOG: $sector - I/O Error" >> $LOG_FILE
        update_card 2 0 0 "${R}Error I/O.${NC}"
        sleep 0.5
        procesar=1; modo_rescate=0
    else
        es_lento=$(echo "$duracion > $TIEMPO_MAX" | bc -l)
        if [ "$es_lento" -eq 1 ]; then
            echo "LOG: $sector - Slow ($duracion)" >> $LOG_FILE
            update_card 2 1 0 "${Y}Lento (${duracion}s).${NC}"
            sleep 0.5
            procesar=1; modo_rescate=1
        else
             update_card 1 0 0 "${G}Lectura Correcta.${NC}"
             procesar=0
        fi
    fi

    if [ $procesar -eq 1 ]; then
        # --- FASE 2: PREPARAR RESCATE ---
        if [ $modo_rescate -eq 1 ]; then
            hex_dump=$(echo "$raw_output" | grep -E "^[0-9a-fA-F]{4}" | tr -d ' \r\n')
            echo "$hex_dump" | xxd -r -p > "$BIN_TEMP"
            if [ $(stat -c%s "$BIN_TEMP") -ne 512 ]; then
                modo_rescate=0
                update_card 2 3 0 "${R}Error dump size.${NC}"
                sleep 0.5
            fi
        fi

        # --- FASE 3: CAUTERIZAR (Ceros) ---
        update_card 2 $modo_rescate 0 "${Y}Escribiendo ceros (Remapeo)...${NC}"
        hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
        sleep 0.5

        # --- FASE 4: RESTAURAR O FINALIZAR ---
        if [ $modo_rescate -eq 1 ]; then
            update_card 2 1 0 "Restaurando datos (DD)..."
            dd if="$BIN_TEMP" of="$DISCO" bs=512 count=1 seek="$sector" conv=fdatasync status=none
            if [ $? -eq 0 ]; then
                ((TOTAL_SALVADOS++))
                echo "LOG: $sector - Saved" >> $LOG_FILE
                update_card 2 2 1 "${G}¡Dato Salvado!${NC}"
            else
                 hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
                 ((TOTAL_CEROS++))
                 echo "LOG: $sector - Zeroed (Restore fail)" >> $LOG_FILE
                 update_card 2 3 1 "${Y}Fallo Restore. Ceros aplicados.${NC}"
            fi
        else
            # Verificación post-cauterización
            hdparm --read-sector "$sector" "$DISCO" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                ((TOTAL_CEROS++))
                echo "LOG: $sector - Zeroed" >> $LOG_FILE
                update_card 2 0 1 "${Y}Sector recuperado (Ceros).${NC}"
            else
                ((TOTAL_FALLIDOS++))
                 echo "LOG: $sector - FAILED" >> $LOG_FILE
                 update_card 2 0 2 "${R}FALLO FÍSICO PERMANENTE.${NC}"
            fi
        fi
    fi
    sleep 0.5
}

# --- MAIN ---
TOTAL_SECTORS=$(blockdev --getsz $DISCO)
START_SECTOR=0

# Recuperar Estado
if [ -f "$STATE_FILE" ]; then
    source $STATE_FILE
    if [ "$DEVICE" == "$DISCO" ]; then
        START_SECTOR=$LAST_SECTOR
        SESSION_START_SECTOR=$LAST_SECTOR
        TOTAL_SALVADOS=${STATS_SALVADOS:-0}
        TOTAL_CEROS=${STATS_CEROS:-0}
        TOTAL_FALLIDOS=${STATS_FALLIDOS:-0}
    else
        rm $STATE_FILE
    fi
fi

# Cola Pendiente
if [ -s "$PENDING_FILE" ]; then
    while IFS= read -r pending_sector; do
        reparar_sector "$pending_sector"
        # Eliminar línea procesada para actualizar contador en tiempo real (opcional, pero visualmente correcto)
        sed -i "1d" "$PENDING_FILE"
    done < "$PENDING_FILE"
    rm -f "$PENDING_FILE"
fi

CHUNK_SIZE=$(echo "$TOTAL_SECTORS * $CHUNK_PERCENT / 100" | bc)
if [ "$CHUNK_SIZE" -lt 2048 ]; then CHUNK_SIZE=2048; fi 

clear
CURRENT=$START_SECTOR

while [ $CURRENT -lt $TOTAL_SECTORS ]; do
    END=$((CURRENT + CHUNK_SIZE))
    if [ $END -gt $TOTAL_SECTORS ]; then END=$TOTAL_SECTORS; fi
    
    badblocks -b 512 -s $DISCO $END $CURRENT > $TEMP_LIST 2> /dev/null &
    PID_BB=$!
    
    monitor_badblocks $PID_BB $TOTAL_SECTORS

    if [ -s $TEMP_LIST ]; then
        # Copiar temp list a pending memory para no machacarlo
        cat "$TEMP_LIST" > .current_chunk_list
        while IFS= read -r bad_sector; do
            reparar_sector "$bad_sector"
            # Truco visual: eliminamos la línea de la lista temporal para que el contador de pendientes baje
            sed -i "/^$bad_sector$/d" "$TEMP_LIST"
        done < .current_chunk_list
        rm .current_chunk_list
        > $TEMP_LIST
    fi

    CURRENT=$END
    
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$CURRENT" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
done

clear
draw_screen "SCAN" "$TOTAL_SECTORS" "$TOTAL_SECTORS" "OK" "PROCESO FINALIZADO" 0 0 0 0 ""
echo -e "\n${G}FINALIZADO${NC}"
rm -f $STATE_FILE