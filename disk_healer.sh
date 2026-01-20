#!/bin/bash

# ==============================================================================
#  ? DISK HEALER v1.0 - REPARACIÓN INTELIGENTE Y AUTOMATIZADA
#  Combina badblocks + hdparm + dd para revivir discos duros
# ==============================================================================

# --- CONFIGURACIÓN ---
CHUNK_PERCENT=2      # Porcentaje del disco a escanear en cada pasada
TIEMPO_MAX=1.0       # Umbral de latencia para considerar un sector "Lento"
STATE_FILE=".disk_healer_state"
LOG_FILE="disk_healer_report.log"
TEMP_LIST="/tmp/badblocks_chunk.txt"
BIN_TEMP="/tmp/sector_rescued.bin"
# ---------------------

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 1. VERIFICACIÓN DE PARÁMETROS
if [ "$EUID" -ne 0 ]; then echo -e "${RED}? Ejecuta como root (sudo).${NC}"; exit 1; fi

if [ -z "$1" ]; then
    echo -e "${YELLOW}Uso: $0 <dispositivo>${NC}"
    echo "Ejemplo: $0 /dev/sdd"
    exit 1
fi
DISCO=$1

# 2. VERIFICACIÓN DE DEPENDENCIAS
DEPENDENCIAS=("hdparm" "dd" "xxd" "bc" "badblocks")
FALTAN=()

for dep in "${DEPENDENCIAS[@]}"; do
    if ! command -v $dep &> /dev/null; then
        FALTAN+=($dep)
    fi
done

if [ ${#FALTAN[@]} -ne 0 ]; then
    echo -e "${RED}? Faltan herramientas necesarias: ${FALTAN[*]}${NC}"
    echo "Instálalas con uno de estos comandos:"
    echo -e "${BLUE}Debian/Ubuntu/Kali:${NC} sudo apt update && sudo apt install smartmontools gdisk e2fsprogs bc xxd"
    echo -e "${BLUE}Arch Linux:${NC}        sudo pacman -S hdparm bc vi (para xxd) e2fsprogs"
    echo -e "${BLUE}Fedora/RHEL:${NC}       sudo dnf install hdparm bc vim-common e2fsprogs"
    exit 1
fi

# 3. CONTROL DE INTERRUPCIONES (CTRL+C) Y ESTADÍSTICAS
TOTAL_SALVADOS=0
TOTAL_CEROS=0
TOTAL_FALLIDOS=0
SECTOR_ACTUAL=0

cleanup() {
    echo -e "\n\n${YELLOW}??  INTERRUPCIÓN DETECTADA (Ctrl+C)${NC}"
    echo "Guardando estado en $STATE_FILE..."
    # Guardamos dispositivo, sector actual y estadísticas
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$SECTOR_ACTUAL" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
    
    echo -e "? Informe guardado en $LOG_FILE"
    echo -e "${BLUE}??  Para reanudar, ejecuta exactamente el mismo comando.${NC}"
    rm -f $TEMP_LIST $BIN_TEMP
    exit 0
}
trap cleanup SIGINT

# 4. LÓGICA DE REPARACIÓN (La v5.1 optimizada)
reparar_sector() {
    local sector=$1
    local modo_rescate=0
    
    echo -n "[Sector $sector] " | tee -a $LOG_FILE

    # --- DIAGNÓSTICO ---
    start_t=$(date +%s.%N)
    raw_output=$(hdparm --read-sector "$sector" "$DISCO" 2>&1)
    status_read=$?
    end_t=$(date +%s.%N)
    duracion=$(echo "$end_t - $start_t" | bc)

    procesar=0
    if [ $status_read -ne 0 ]; then
        echo -n "? ERROR LECTURA. " | tee -a $LOG_FILE
        procesar=1
        modo_rescate=0
    else
        es_lento=$(echo "$duracion > $TIEMPO_MAX" | bc -l)
        if [ "$es_lento" -eq 1 ]; then
            echo -n "??  LENTO (${duracion}s). " | tee -a $LOG_FILE
            procesar=1
            modo_rescate=1
        else
            echo "? OK (${duracion}s)." | tee -a $LOG_FILE
            procesar=0
        fi
    fi

    if [ $procesar -eq 0 ]; then return; fi

    # --- PREPARACIÓN (Rescue) ---
    if [ $modo_rescate -eq 1 ]; then
        hex_dump=$(echo "$raw_output" | grep -E "^[0-9a-fA-F]{4}" | tr -d ' \r\n')
        echo "$hex_dump" | xxd -r -p > "$BIN_TEMP"
        size=$(stat -c%s "$BIN_TEMP")
        if [ "$size" -ne 512 ]; then modo_rescate=0; fi
    fi

    # --- CAUTERIZACIÓN (Zero Fill) ---
    hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
    sleep 0.5 # Pausa táctica

    # --- RESTAURACIÓN ---
    status_final="FALLIDO"
    
    if [ $modo_rescate -eq 1 ]; then
        dd if="$BIN_TEMP" of="$DISCO" bs=512 count=1 seek="$sector" conv=fdatasync status=none
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}? ¡DATO SALVADO!${NC}" | tee -a $LOG_FILE
            ((TOTAL_SALVADOS++))
            status_final="SALVADO"
        else
             # Fallback a ceros
             hdparm --write-sector "$sector" --yes-i-know-what-i-am-doing "$DISCO" > /dev/null 2>&1
             if [ $? -eq 0 ]; then
                echo -e "${YELLOW}? SECTOR DESBLOQUEADO (Ceros)${NC}" | tee -a $LOG_FILE
                ((TOTAL_CEROS++))
                status_final="CEROS"
             else
                echo -e "${RED}? FALLO TOTAL${NC}" | tee -a $LOG_FILE
                ((TOTAL_FALLIDOS++))
             fi
        fi
    else
        # Verificación simple tras borrar
        hdparm --read-sector "$sector" "$DISCO" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${YELLOW}? SECTOR DESBLOQUEADO (Ceros)${NC}" | tee -a $LOG_FILE
            ((TOTAL_CEROS++))
            status_final="CEROS"
        else
            echo -e "${RED}? FALLO TOTAL${NC}" | tee -a $LOG_FILE
            ((TOTAL_FALLIDOS++))
        fi
    fi
}


# 5. INICIO Y REANUDACIÓN
TOTAL_SECTORS=$(blockdev --getsz $DISCO)
START_SECTOR=0

if [ -f "$STATE_FILE" ]; then
    source $STATE_FILE
    if [ "$DEVICE" == "$DISCO" ]; then
        echo -e "${YELLOW}? Se detectó una sesión previa interrumpida en el sector $LAST_SECTOR.${NC}"
        echo -n "¿Deseas reanudar? [S/n]: "
        read respuesta
        if [[ "$respuesta" =~ ^[Ss]$ ]] || [[ -z "$respuesta" ]]; then
            START_SECTOR=$LAST_SECTOR
            # Recuperar stats previos
            TOTAL_SALVADOS=${STATS_SALVADOS:-0}
            TOTAL_CEROS=${STATS_CEROS:-0}
            TOTAL_FALLIDOS=${STATS_FALLIDOS:-0}
        fi
    else
        echo -e "${RED}??  El archivo de estado pertenece a otro disco ($DEVICE). Se iniciará de cero.${NC}"
        rm $STATE_FILE
    fi
fi

CHUNK_SIZE=$(echo "$TOTAL_SECTORS * $CHUNK_PERCENT / 100" | bc)
# Ajuste mínimo de chunk por si el disco es pequeño
if [ "$CHUNK_SIZE" -lt 2048 ]; then CHUNK_SIZE=2048; fi 

echo "==================================================="
echo " ? DISK HEALER - INICIANDO"
echo " ? Objetivo: $DISCO ($TOTAL_SECTORS sectores)"
echo " ? Bloque de escaneo: $CHUNK_SIZE sectores (~$CHUNK_PERCENT%)"
echo "==================================================="

# 6. BUCLE PRINCIPAL (CHUNK LOOP)
CURRENT=$START_SECTOR

while [ $CURRENT -lt $TOTAL_SECTORS ]; do
    END=$((CURRENT + CHUNK_SIZE))
    if [ $END -gt $TOTAL_SECTORS ]; then END=$TOTAL_SECTORS; fi
    
    PERCENT=$(echo "scale=2; $CURRENT * 100 / $TOTAL_SECTORS" | bc)
    echo -e "${BLUE}? Escaneando rango: $CURRENT - $END ($PERCENT%)${NC}"
    
    # Actualizar puntero global para el trap
    SECTOR_ACTUAL=$CURRENT

    # Ejecutar Badblocks en el rango actual
    # -b 512: Bloque físico real
    # -o: Salida a archivo temporal
    badblocks -b 512 -s $DISCO $END $CURRENT > $TEMP_LIST 2> /dev/null

    # Si hay sectores malos, procesarlos
    if [ -s $TEMP_LIST ]; then
        NUM_ERRORS=$(wc -l < $TEMP_LIST)
        echo -e "${RED}??  Se encontraron $NUM_ERRORS sectores malos. Iniciando reparación...${NC}"
        
        while IFS= read -r bad_sector; do
            reparar_sector "$bad_sector"
        done < $TEMP_LIST
    fi

    # Avanzar
    CURRENT=$END
    
    # Guardar estado intermedio (checkpointing seguro)
    echo "DEVICE=$DISCO" > $STATE_FILE
    echo "LAST_SECTOR=$CURRENT" >> $STATE_FILE
    echo "STATS_SALVADOS=$TOTAL_SALVADOS" >> $STATE_FILE
    echo "STATS_CEROS=$TOTAL_CEROS" >> $STATE_FILE
    echo "STATS_FALLIDOS=$TOTAL_FALLIDOS" >> $STATE_FILE
done

# 7. FINALIZACIÓN
echo "==================================================="
echo -e "${GREEN}? PROCESO COMPLETADO${NC}"
echo "---------------------------------------------------"
echo " ? Datos Salvados  : $TOTAL_SALVADOS"
echo " ? Sectores Ceros  : $TOTAL_CEROS"
echo " ? Irrecuperables  : $TOTAL_FALLIDOS"
echo "==================================================="
rm -f $STATE_FILE $TEMP_LIST $BIN_TEMP
