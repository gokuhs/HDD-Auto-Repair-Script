# ? Disk Healer - Automated HDD Repair Tool
![Version](https://img.shields.io/badge/version-4.0-blue.svg) ![Platform](https://img.shields.io/badge/platform-Linux-green.svg) ![License](https://img.shields.io/badge/license-MIT-orange.svg)

**Disk Healer** is a powerful bash script designed to detect, analyze, and repair physical sectors on failing hard drives. Unlike standard tools, it uses a **hybrid strategy** to attempt data recovery before marking sectors as bad.

**Disk Healer** es un potente script de bash diseñado para detectar, analizar y reparar sectores físicos en discos duros defectuosos. A diferencia de las herramientas estándar, utiliza una **estrategia híbrida** para intentar recuperar datos antes de marcar los sectores como dañados.

---

## DISCLAIMER / DESCARGO DE RESPONSABILIDAD

> **ENGLISH:**
> THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND. USE IT AT YOUR OWN RISK.
> This tool performs **low-level write operations** (zero-filling) on your disk. While it attempts to save data before repairing, **data loss in the affected sectors is possible** if the physical damage is severe. The author is not responsible for any data loss, hardware damage, or thermonuclear war caused by the use of this script. **ALWAYS BACKUP YOUR DATA BEFORE PROCEEDING.**

> **ESPAÑOL:**
> ESTE SOFTWARE SE PROPORCIONA "TAL CUAL", SIN GARANTÍA DE NINGÚN TIPO. ÚSELO BAJO SU PROPIA RESPONSABILIDAD.
> Esta herramienta realiza **operaciones de escritura a bajo nivel** (llenado de ceros) en su disco. Aunque intenta salvar los datos antes de reparar, **la pérdida de datos en los sectores afectados es posible** si el daño físico es grave. El autor no se hace responsable de ninguna pérdida de datos, daño al hardware o guerra termonuclear causada por el uso de este script. **SIEMPRE HAGA UNA COPIA DE SEGURIDAD ANTES DE CONTINUAR.**

---

## Features / Características

| Feature | Description (EN) | Descripción (ES) |
| :--- | :--- | :--- |
| **Hybrid Repair** | Tries to read & restore data. If it fails, it zero-fills the sector to fix the drive lag. | Intenta leer y restaurar datos. Si falla, llena de ceros para arreglar el "lag" del disco. |
| **Real-Time Monitor** | Reads directly from the Kernel to show exact sector progress. | Lee directamente del Kernel para mostrar el progreso exacto del sector. |
| **Precision Resume** | Stopped by Ctrl+C? Resume exactly where you left off. | ¿Parado por Ctrl+C? Reanuda exactamente donde lo dejaste. |
| **Multilingual** | Auto-detects system language (English / Spanish). | Autodetecta el idioma del sistema (Inglés / Español). |
| **IO Optimized** | Minimal disk writing to avoid stressing the damaged drive. | Escritura mínima en disco para evitar estresar la unidad dañada. |

---

## Usage / Uso

### 1. Requirements / Requisitos
This script requires standard Linux tools. It will auto-detect missing ones.
Este script requiere herramientas estándar de Linux. Detectará automáticamente si falta alguna.

* `hdparm`
* `dd`
* `badblocks`
* `xxd`
* `bc`

### 2. Installation / Instalación
Clone the repository and give execution permissions:
Clone el repositorio y dé permisos de ejecución:

```bash
git clone ssh://git@gitlab.gokuhs.eu:443/gokuhs-software/hdd-auto-repair-script.git
cd hdd-auto-repair-script
chmod +x disk_healer.sh
```

### 3. Execution / Ejecución

Run as root indicating the target drive: Ejecute como root indicando el disco objetivo:
```Bash
  sudo ./disk_healer.sh /dev/sdX
```

  (Replace /dev/sdX with your actual drive, e.g., /dev/sdb).

## How it works / Cómo funciona

  **Scanning**: It runs badblocks in 2% chunks to find damaged areas.

  **Detection**: If bad sectors are found, it switches to "Surgical Mode".

  **Analysis**: It checks if the sector is unreadable or just slow.

  **Rescue Attempt**:

1. It tries to read the raw data using hdparm
1. It converts hex dump to binary.
1. It forces a sector re-map by writing zeros (cauterization).
1. It restores the original data using dd.

Fallback: If data cannot be saved, it leaves the sector zeroed out to prevent OS freezes.

Author: Gokuhs License: MIT


