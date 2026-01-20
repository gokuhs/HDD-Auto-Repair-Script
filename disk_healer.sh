#!/bin/bash

# ==============================================================================
#  ? DISK HEALER v2.0 - VISUAL UPGRADE
#  Reparación automática con Feedback Visual en tiempo real
# ==============================================================================

# --- CONFIGURACIÓN ---
CHUNK_PERCENT=2      # Porcentaje por bloque (mantener bajo para más actualizaciones visuales)
TIEMPO_MAX=1.0       
STATE_FILE=".disk_healer_state"
LOG_FILE="disk_healer_report.log"
TEMP_LIST="/tmp/badblocks_chunk.txt"
BIN_TEMP="/tmp/sector_rescued.bin"
# ---------------------

# Colores y Cursores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Ocultar cursor para limpieza visual
tput civis

# Restaurar cursor al salir
cleanup_exit() {
    tput cnorm
    rm -f $TEMP_LIST $BIN_TEMP
    exit
}
trap cleanup_exit SIGINT SIGTERM EXIT

# 1. VERIFICACIONES (Igual que antes)
if [ "$EUID" -ne 0 ]; then echo -e "${RED}? Ejecuta como root.${NC}"; exit 1; fi
if [ -z "$1" ]; then echo -e "${YELLOW}Uso: $0 <dispositivo>${NC}"; exit 1; fi
DISCO=$1

DEPENDENCIAS=("hdparm" "dd" "xxd" "bc" "badblocks")
for dep in "${DEPENDENCIAS[@]}"; do
    if ! command -v $dep &> /dev/null; then
        echo -e "${RED}? Falta: $dep${NC}"; exit 1
    fi
done

# --- FUNCIONES VISUALES ---

# Dibuja una barra de progreso: [####....] 45%
draw_progress_bar() {
    local width=40
    local progress=$1 # 0-100
    local num_filled=$(echo "scale=0; $width * $progress / 100" | bc)
    local num_empty=$((width - num_filled))
    
    # Crear cadenas de # y .
    local filled=$(printf "%0.s#" $(seq 1 $num_filled))
    local empty=$(printf "%0.s." $(seq 1 $num_empty))

    # Imprimir barra sobrescribiendo la línea (\r)
    printf "\r${BLUE}[${filled}${empty}] ${progress}%%${NC}"
}

# Spinner animado mientras espera un proceso PID
wait_with_spinner() {
    local pid=$1
    local info_text=$2
    local spin='-\|/'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        # Imprime: [Spinner] Texto de estado (Sectores actuales)
        printf "\r${CYAN}[${spin:$i:1}]${NC} %s" "$info_text"
        sleep 0.1
    done
    # Limpiar línea al terminar
    printf "\r\033[K"
}

# --- ESTADÍSTICAS ---
TOTAL_SALVADOS=0
TOTAL_CEROS=0
TOTAL_FALLIDOS=0
SECTOR_ACTUAL=0

# --- FUNCIÓN DE REPARACIÓN (Lógica v5.1) ---
reparar_sector() {
    local sector=$1
    local modo_rescate=0
    
    # Nueva línea para el log de reparación
    echo -e "\n? Analizando sector $sector..." 

    start_t=$(date +%s.%N)
    raw_output=$(hdparm --read-sector "$sector" "$DISCO" 2>&1)
    status_read=$?
    end_t=$(date +%s.%N)
    duracion=$(echo "$end_t - $start_t" | bc)

    procesar=0
    if [ $status_read -ne 0 ]; then
        echo -e "${RED}   ? ILEGIBLE. Iniciando protocolo destructivo.${NC}" | tee -a $LOG_FILE
        procesar=1; modo_rescate=0
    else
        es_lento=$(echo "$duracion > $TIEMPO_MAX" | bc -l)
        if [ "$es_lento" -eq 1 ]; then
            echo -e "${YELLOW}   ??  LENTO (${duracion}s). Intentando rescate.${NC}" | tee -a $LOG_FILE
            procesar=1; modo_rescate=1
        else
            echo -e "${GREEN}   ? OK (${duracion}s). Falsa alarma.${NC}"
            procesar=0
        fi
    fi

    if [ $procesar -eq 0 ]; then return; fi

    if [ $modo_rescate -eq 1 ]; then
        hex_dump=$(echo "$raw_output" | grep -E "^[0-9a-fA-F]{4}" | tr -d ' \r\n')
        echo "$hex_dump" | xxd -r -p > "$BIN_TEMP"
        size=$(stat -c%s "$BIN_TEMP")
        if [ "$size" -ne 512 ]; then modo_rescate=0; fi
    fi

    # Cauterizar
    hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
    sleep 0.5

    # Restaurar
    if [ $modo_rescate -eq 1 ]; then
        dd if="$BIN_TEMP" of="$DISCO" bs=512 count=1 seek="$sector" conv=fdatasync status=none
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}   ? DATO SALVADO Y RESTAURADO${NC}" | tee -a $LOG_FILE
            ((TOTAL_SALVADOS++))
        else
             hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
             echo -e "${YELLOW}   ? SECTOR LIMPIADO (Ceros)${NC}" | tee -a $LOG_FILE
             ((TOTAL_CEROS++))
        fi
    else
        hdparm --read-sector "$sector" "$DISCO" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${YELLOW}   ? SECTOR LIMPIADO (Ceros)${NC}" | tee -a $LOG_FILE
            ((TOTAL_CEROS++))
        else
            echo -e "${RED}   ? FALLO FÍSICO PERMANENTE${NC}" | tee -a $LOG_FILE
            ((TOTAL_FALLIDOS++))
        fi
    fi
    echo "---------------------------------------------------"
}

# --- INICIO ---
TOTAL_SECTORS=$(blockdev --getsz $DISCO)
START_SECTOR=0

# Recuperar estado
if [ -f "$STATE_FILE" ]; then
    source $STATE_FILE
    if [ "$DEVICE" == "$DISCO" ]; then
        echo -e "${YELLOW}? Reanudando desde el sector $LAST_SECTOR${NC}"
        START_SECTOR=$LAST_SECTOR
        TOTAL_SALVADOS=${STATS_SALVADOS:-0}
        TOTAL_CEROS=${STATS_CEROS:-0}
        TOTAL_FALLIDOS=${STATS_FALLIDOS:-0}
        sleep 2
    else
        rm $STATE_FILE
    fi
fi

CHUNK_SIZE=$(echo "$TOTAL_SECTORS * $CHUNK_PERCENT / 100" | bc)
if [ "$CHUNK_SIZE" -lt 2048 ]; then CHUNK_SIZE=2048; fi 

clear
echo "==================================================="
echo -e "${CYAN} ? DISK HEALER v2.0 - LIVE MONITOR${NC}"
echo " ? Disco: $DISCO"
echo " ? Total Sectores: $TOTAL_SECTORS"
echo "==================================================="

CURRENT=$START_SECTOR

while [ $CURRENT -lt $TOTAL_SECTORS ]; do
    END=$((CURRENT + CHUNK_SIZE))
    if [ $END -gt $TOTAL_SECTORS ]; then END=$TOTAL_SECTORS; fi
    
    # Calcular porcentaje
    PERCENT=$(echo "scale=2; $CURRENT * 100 / $TOTAL_SECTORS" | bc)
    
    # 1. Dibujar Barra de Progreso estática arriba
    draw_progress_bar "$PERCENT"
    
    # 2. Ejecutar Badblocks en BACKGROUND (&)
    #    y capturar su PID para mostrar el spinner
    badblocks -b 512 -s $DISCO $END $CURRENT > $TEMP_LIST 2> /dev/null &
    PID_BB=$!
    
    # 3. Mostrar Spinner con info de rango mientras badblocks trabaja
    wait_with_spinner $PID_BB "Escaneando sectores: $CURRENT - $END"

    # Actualizar para trap
    SECTOR_ACTUAL=$CURRENT

    # 4. Procesar errores si los hay
    if [ -s $TEMP_LIST ]; then
        # Limpiar línea visual
        printf "\r\033[K"
        NUM_ERRORS=$(wc -l < $TEMP_LIST)
        echo -e "${RED}??  Detectados $NUM_ERRORS sectores malos en este bloque.${NC}"
        
        while IFS= read -r bad_sector; do
            reparar_sector "$bad_sector"
        done < $TEMP_LIST
        
        # Pausa breve para leer lo que pasó antes de seguir
        sleep 2
    fi

    CURRENT=$END
    
    # Guardar Estado
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$CURRENT" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
done

draw_progress_bar "100"
echo -e "\n\n==================================================="
echo -e "${GREEN}? PROCESO COMPLETADO${NC}"
echo " ? Datos Salvados : $TOTAL_SALVADOS"
echo " ? Sectores Ceros : $TOTAL_CEROS"
echo "==================================================="
