#!/bin/bash

# ==============================================================================
#  ? DISK HEALER v6.0 - UI OVERHAUL (MODERN DASHBOARD)
#  Lógica v5.0 (Zero Loss) + Interfaz gráfica en terminal con ETA y Tablas
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

# Colores y Estilos
R='\033[0;31m'   # Rojo
G='\033[0;32m'   # Verde
Y='\033[1;33m'   # Amarillo
B='\033[0;34m'   # Azul
C='\033[0;36m'   # Cyan
P='\033[0;35m'   # Purpura
W='\033[1;37m'   # Blanco Brillante
GR='\033[0;90m'  # Gris
NC='\033[0m'     # Reset

# Variables de Sesión para ETA
SESSION_START_TIME=$(date +%s)
SESSION_START_SECTOR=0

# --- IDIOMA ---
detect_language() {
    if [[ "$LANG" == *"es_"* ]]; then
        L_ROOT="? Se requiere Root."
        L_USAGE="Uso: $0 <dispositivo>"
        L_MISSING="? Falta:"
        L_INTERRUPT="??  INTERRUPCIÓN"
        L_SAVING="? Guardando estado..."
        L_RESUME="? REANUDANDO"
        L_PENDING="??  Procesando cola pendiente..."
        L_FINISHED="? FINALIZADO"
        
        # Dashboard
        L_STATS="ESTADÍSTICAS"
        L_SAVED="Salvados"
        L_ZEROS="Ceros"
        L_FAIL="Fallidos"
        L_PEND="Pendientes"
        L_SPEED="Velocidad"
        L_ETA="Tiempo Restante"
        L_FINISH="Finalización"
        L_SCAN="ESCANEANDO"
        L_REPAIR="REPARANDO"
        L_WAIT="Espere..."
        L_PLUS_REPAIR="(+ Reparación)"
        
        # Repair Stages
        L_PH_READ="Lectura"
        L_PH_RESC="Rescate"
        L_PH_ZERO="Ceros"
        L_PH_CHECK="Verif."
    else
        L_ROOT="? Root required."
        L_USAGE="Usage: $0 <device>"
        L_MISSING="? Missing:"
        L_INTERRUPT="??  INTERRUPT"
        L_SAVING="? Saving state..."
        L_RESUME="? RESUMING"
        L_PENDING="??  Processing pending queue..."
        L_FINISHED="? FINISHED"
        
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
        L_WAIT="Wait..."
        L_PLUS_REPAIR="(+ Repair)"
        
        L_PH_READ="Read"
        L_PH_RESC="Rescue"
        L_PH_ZERO="Zeros"
        L_PH_CHECK="Check"
    fi
}
detect_language
tput civis

# --- UTILS ---
format_seconds() {
    local T=$1
    local H=$((T/3600))
    local M=$(( (T%3600)/60 ))
    local S=$((T%60))
    printf "%02d:%02d:%02d" $H $M $S
}

cleanup_exit() {
    tput cnorm
    if [ -f "$STATE_FILE" ]; then
         LAST_POS=$(grep "LAST_SECTOR" $STATE_FILE | cut -d= -f2)
         echo -e "\n${Y}${L_INTERRUPT}: ${C}Sector $LAST_POS${NC}"
    fi
    # Salvar pendientes
    if [ -s "$TEMP_LIST" ]; then
        cat "$TEMP_LIST" >> "$PENDING_FILE"
        sort -u "$PENDING_FILE" -o "$PENDING_FILE"
    fi
    jobs -p | xargs -r kill > /dev/null 2>&1
    rm -f $TEMP_LIST $BIN_TEMP $REALTIME_POS_FILE
    exit
}
trap cleanup_exit SIGINT SIGTERM EXIT

# CHECKS
if [ "$EUID" -ne 0 ]; then echo -e "${R}${L_ROOT}${NC}"; exit 1; fi
if [ -z "$1" ]; then echo -e "${Y}${L_USAGE}${NC}"; exit 1; fi
DISCO=$1
DEPENDENCIAS=("hdparm" "dd" "xxd" "bc" "badblocks")
for dep in "${DEPENDENCIAS[@]}"; do
    if ! command -v $dep &> /dev/null; then echo -e "${R}${L_MISSING} $dep${NC}"; exit 1; fi
done

# --- UI DRAWING FUNCTIONS ---

# Dibuja la cabecera y la tabla de estadísticas
draw_header_table() {
    local pending_count=$1
    
    # Calcular ETA
    local current_time=$(date +%s)
    local elapsed=$((current_time - SESSION_START_TIME))
    local sectors_done=$((SECTOR_ACTUAL - SESSION_START_SECTOR))
    
    local speed=0
    local eta_str="--:--:--"
    local finish_str="--:--"
    
    if [ $elapsed -gt 5 ] && [ $sectors_done -gt 0 ]; then
        speed=$((sectors_done / elapsed))
        local remaining=$((TOTAL_SECTORS - SECTOR_ACTUAL))
        local eta_seconds=$((remaining / speed))
        
        eta_str=$(format_seconds $eta_seconds)
        finish_str=$(date -d "+$eta_seconds seconds" +"%H:%M")
        
        # Si hay pendientes, el ETA es mentira
        if [ "$pending_count" -gt 0 ]; then
            eta_str="${Y}$eta_str ${R}${L_PLUS_REPAIR}${NC}"
        fi
    fi

    # Limpiar pantalla (parcialmente)
    # Movemos el cursor arriba 7 líneas (Header + Tabla)
    # printf "\033[7A" 
    # Pero para simplificar en bash puro sin ncurses, redibujamos bloque
    
    # Dibujar Caja
    echo -e "${B}??????????????????????????????????????????????????????????????????????????${NC}"
    printf "${B}?${NC} %-25s ${GR}|${NC} %-41s ${B}?${NC}\n" "${W}DISK HEALER v6.0${NC}" "${C}$DISCO${NC}"
    echo -e "${B}??????????????????????????????????????????????????????????????????????????${NC}"
    
    # Fila 1: Salvados | Ceros | Fallidos | Pendientes
    printf "${B}?${NC} ${G}%-10s${NC} : %-4d ${GR}|${NC} ${Y}%-10s${NC} : %-4d ${GR}|${NC} ${R}%-10s${NC} : %-4d ${GR}|${NC} ${P}%-10s${NC} : %-4d ${B}?${NC}\n" \
           "$L_SAVED" "$TOTAL_SALVADOS" "$L_ZEROS" "$TOTAL_CEROS" "$L_FAIL" "$TOTAL_FALLIDOS" "$L_PEND" "$pending_count"
    
    echo -e "${B}??????????????????????????????????????????????????????????????????????????${NC}"
    
    # Fila 2: Velocidad | ETA | Finalización
    printf "${B}?${NC} %-10s : %-7s ${GR}|${NC} %-10s : %-19b ${GR}|${NC} %-10s : %-5s ${B}?${NC}\n" \
           "$L_SPEED" "${speed} s/sec" "$L_ETA" "$eta_str" "$L_FINISH" "$finish_str"
    
    echo -e "${B}??????????????????????????????????????????????????????????????????????????${NC}"
}

draw_progress() {
    local percent=$1
    local sector=$2
    local total=$3
    local spinner=$4
    local status_txt=$5

    local width=50
    local num_filled=$(echo "scale=0; $width * $percent / 100" | bc)
    local num_empty=$((width - num_filled))
    local filled=$(printf "%0.s?" $(seq 1 $num_filled))
    local empty=$(printf "%0.s?" $(seq 1 $num_empty))

    echo -e "${W}$L_PROG_GLOBAL${NC}"
    echo -e "${B}[${filled}${empty}]${NC} ${C}${percent}%${NC}"
    echo -e "${P}[${spinner}]${NC} ${L_SECTOR} ${Y}$(printf "%'d" $sector)${NC} / $(printf "%'d" $total)"
    echo -e "${NC}$status_txt\033[K" # Limpiar resto de línea
}

# Tarjeta visual para la fase de reparación
draw_repair_card() {
    local sector=$1
    local st_read=$2   # 0=Pending, 1=OK, 2=Fail
    local st_resc=$3   # 0=None, 1=Try, 2=OK, 3=Fail
    local st_check=$4  # 0=Pending, 1=OK, 2=Fail
    local st_patch=$5  # 0=Pending, 1=OK
    local msg=$6

    # Iconos
    local i_pend="${GR}[ ]${NC}"
    local i_ok="${G}[?]${NC}"
    local i_fail="${R}[?]${NC}"
    local i_try="${Y}[?]${NC}"

    # Resolver estado Lectura
    local v_read=$i_pend
    [ $st_read -eq 1 ] && v_read=$i_ok
    [ $st_read -eq 2 ] && v_read=$i_fail

    # Resolver estado Rescate
    local v_resc="${GR}[-]${NC}" # Default desactivado
    [ $st_resc -eq 1 ] && v_resc=$i_try
    [ $st_resc -eq 2 ] && v_resc=$i_ok
    [ $st_resc -eq 3 ] && v_resc=$i_fail

    # Resolver estado Patch
    local v_patch=$i_pend
    [ $st_patch -eq 1 ] && v_patch=$i_ok

    # Dibujar tarjeta
    echo -e "\n${R}>>> ${L_REPAIR} SECTOR: $sector${NC}"
    echo -e "??????????????????????????????????????????????????????????"
    printf "? %-16b %-16b %-16b ?\n" "$v_read $L_PH_READ" "$v_resc $L_PH_RESC" "$v_patch $L_PH_ZERO"
    echo -e "??????????????????????????????????????????????????????????"
    echo -e "${W}Status:${NC} $msg\033[K"
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
                SECTOR_ACTUAL=$current_sector_lba # Actualizar global para ETA
                
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

                # DIBUJAR INTERFAZ
                # Calculamos pendientes (lineas en temp + lineas en archivo pending)
                local p1=$(wc -l < "$TEMP_LIST" 2>/dev/null || echo 0)
                local p2=$(wc -l < "$PENDING_FILE" 2>/dev/null || echo 0)
                local total_pend=$((p1 + p2))

                # Volver al inicio (Home) y redibujar todo
                printf "\033[H"
                draw_header_table "$total_pend"
                
                local percent=$(echo "scale=2; $current_sector_lba * 100 / $total_sectors" | bc)
                draw_progress "$percent" "$current_sector_lba" "$total_sectors" "${spin:$i:1}" "$L_SCAN"
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

    # --- FASE 1: LECTURA ---
    # Pintamos estado inicial
    printf "\033[H"
    draw_header_table "1" # Asumimos 1 pendiente (el actual)
    draw_progress "0.00" "$sector" "$TOTAL_SECTORS" "!" "$L_REPAIR"
    draw_repair_card "$sector" 0 0 0 0 "Analizando..."

    start_t=$(date +%s.%N)
    raw_output=$(hdparm --read-sector "$sector" "$DISCO" 2>&1)
    status_read=$?
    end_t=$(date +%s.%N)
    duracion=$(echo "$end_t - $start_t" | bc)

    procesar=0
    msg=""
    
    if [ $status_read -ne 0 ]; then
        msg="${R}Error I/O.${NC} Destrucción requerida."
        draw_repair_card "$sector" 2 0 0 0 "$msg"
        echo -e "${R}LOG: $sector - I/O Error${NC}" >> $LOG_FILE
        procesar=1; modo_rescate=0
    else
        es_lento=$(echo "$duracion > $TIEMPO_MAX" | bc -l)
        if [ "$es_lento" -eq 1 ]; then
            msg="${Y}Lento (${duracion}s).${NC} Iniciando rescate."
            draw_repair_card "$sector" 2 1 0 0 "$msg" # Marcamos lectura como "Warning/Fail" visual para activar rescate
            echo -e "${Y}LOG: $sector - Slow ($duracion)${NC}" >> $LOG_FILE
            procesar=1; modo_rescate=1
        else
             draw_repair_card "$sector" 1 0 0 0 "${G}Falsa alarma.${NC}"
             procesar=0
        fi
    fi
    sleep 0.5

    if [ $procesar -eq 1 ]; then
        # --- FASE 2: PREPARAR RESCATE ---
        if [ $modo_rescate -eq 1 ]; then
            hex_dump=$(echo "$raw_output" | grep -E "^[0-9a-fA-F]{4}" | tr -d ' \r\n')
            echo "$hex_dump" | xxd -r -p > "$BIN_TEMP"
            if [ $(stat -c%s "$BIN_TEMP") -ne 512 ]; then
                modo_rescate=0
                msg="Error dump size. Cancelando rescate."
                draw_repair_card "$sector" 2 3 0 0 "$msg"
                sleep 1
            fi
        fi

        # --- FASE 3: CAUTERIZAR (Ceros) ---
        draw_repair_card "$sector" 2 $modo_rescate 0 0 "Escribiendo ceros (HDPARM)..."
        hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
        sleep 0.5

        # --- FASE 4: RESTAURAR O FINALIZAR ---
        if [ $modo_rescate -eq 1 ]; then
            draw_repair_card "$sector" 2 1 0 0 "Restaurando datos (DD)..."
            dd if="$BIN_TEMP" of="$DISCO" bs=512 count=1 seek="$sector" conv=fdatasync status=none
            if [ $? -eq 0 ]; then
                ((TOTAL_SALVADOS++))
                draw_repair_card "$sector" 2 2 0 1 "${G}¡Dato Salvado!${NC}"
                echo "LOG: $sector - Saved" >> $LOG_FILE
            else
                 hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
                 ((TOTAL_CEROS++))
                 draw_repair_card "$sector" 2 3 0 1 "${Y}Fallo Restore. Ceros aplicados.${NC}"
                 echo "LOG: $sector - Zeroed (Restore fail)" >> $LOG_FILE
            fi
        else
            # Verificación simple post-cauterización
            hdparm --read-sector "$sector" "$DISCO" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                ((TOTAL_CEROS++))
                draw_repair_card "$sector" 2 0 0 1 "${Y}Sector recuperado (Vacío).${NC}"
                echo "LOG: $sector - Zeroed" >> $LOG_FILE
            else
                ((TOTAL_FALLIDOS++))
                 draw_repair_card "$sector" 2 0 0 0 "${R}FALLO FÍSICO PERMANENTE.${NC}"
                 echo "LOG: $sector - FAILED" >> $LOG_FILE
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
    clear
    echo -e "${Y}${L_PENDING}${NC}"
    sleep 1
    while IFS= read -r pending_sector; do
        reparar_sector "$pending_sector"
    done < "$PENDING_FILE"
    rm "$PENDING_FILE"
fi

CHUNK_SIZE=$(echo "$TOTAL_SECTORS * $CHUNK_PERCENT / 100" | bc)
if [ "$CHUNK_SIZE" -lt 2048 ]; then CHUNK_SIZE=2048; fi 

# Limpiar pantalla una vez al inicio
clear

CURRENT=$START_SECTOR

while [ $CURRENT -lt $TOTAL_SECTORS ]; do
    END=$((CURRENT + CHUNK_SIZE))
    if [ $END -gt $TOTAL_SECTORS ]; then END=$TOTAL_SECTORS; fi
    
    # IMPORTANTE: printf "\033[H" en monitor_badblocks se encarga de volver arriba
    # No usamos clear dentro del loop para evitar parpadeo
    
    badblocks -b 512 -s $DISCO $END $CURRENT > $TEMP_LIST 2> /dev/null &
    PID_BB=$!
    
    monitor_badblocks $PID_BB $TOTAL_SECTORS

    if [ -s $TEMP_LIST ]; then
        while IFS= read -r bad_sector; do
            reparar_sector "$bad_sector"
        done < $TEMP_LIST
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
draw_header_table 0
echo -e "\n${G}${L_FINISHED}${NC}"
rm -f $STATE_FILE