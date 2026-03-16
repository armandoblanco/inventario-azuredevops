#!/bin/bash

###############################################################################
# Azure DevOps Server 2022 - Inventory Tool - Examples Runner
# 
# Este script interactivo te permite ejecutar ejemplos comunes de la herramienta
# de inventario sin tener que recordar los comandos completos.
###############################################################################

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Banner
echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   Azure DevOps Server 2022 - Inventory Tool                      ║
║   Examples Runner                                                 ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Verificar que existe el archivo .env
if [ ! -f .env ]; then
    echo -e "${RED}Error: Archivo .env no encontrado${NC}"
    echo -e "${YELLOW}Por favor copia .env.example a .env y configura tus credenciales:${NC}"
    echo -e "   cp .env.example .env"
    echo -e "   nano .env"
    exit 1
fi

# Verificar que Python esta instalado
if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
    echo -e "${RED}Error: Python no esta instalado${NC}"
    exit 1
fi

# Determinar comando Python
PYTHON_CMD="python3"
if ! command -v python3 &> /dev/null; then
    PYTHON_CMD="python"
fi

# Verificar que las dependencias están instaladas
echo -e "${BLUE}Verificando dependencias...${NC}"
$PYTHON_CMD -c "import requests, dotenv" 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Instalando dependencias...${NC}"
    pip install -r requirements.txt
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error instalando dependencias${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Dependencias verificadas${NC}\n"

# Menú de ejemplos
while true; do
    echo -e "${CYAN}════════════════════════════════════════════=${NC}"
    echo -e "${CYAN}  Selecciona un ejemplo:${NC}"
    echo -e "${CYAN}════════════════════════════════════════════=${NC}"
    echo
    echo -e "${GREEN}1)${NC} Inventario Completo (CSV)"
    echo -e "   ${YELLOW}--${NC} Todos los objetos en carpeta con timestamp"
    echo
    echo -e "${GREEN}2)${NC} Inventario sin Boards (CSV)"
    echo -e "   ${YELLOW}--${NC} Todo excepto Boards (mas rapido)"
    echo
    echo -e "${GREEN}3)${NC} Inventario sin Boards ni Test Plans (CSV)"
    echo -e "   ${YELLOW}--${NC} Para desarrollo, excluye boards y testing"
    echo
    echo -e "${GREEN}4)${NC} Solo Pipelines (CSV + JSON)"
    echo -e "   ${YELLOW}--${NC} Analisis de Build/Release pipelines"
    echo
    echo -e "${GREEN}5)${NC} Solo Repositorios (CSV + JSON)"
    echo -e "   ${YELLOW}--${NC} Inventario de repos, branches y politicas"
    echo
    echo -e "${GREEN}6)${NC} Solo Infraestructura y Seguridad (CSV)"
    echo -e "   ${YELLOW}--${NC} Agent pools, agents, usuarios y grupos"
    echo
    echo -e "${GREEN}7)${NC} Inventario Completo (JSON)"
    echo -e "   ${YELLOW}--${NC} Un solo archivo JSON con todo"
    echo
    echo -e "${GREEN}8)${NC} Core + Work Items + Repos (CSV)"
    echo -e "   ${YELLOW}--${NC} Para analisis de desarrollo"
    echo
    echo -e "${GREEN}9)${NC} Personalizado (ingresar comando manual)"
    echo -e "   ${YELLOW}--${NC} Escribe tu propio comando"
    echo
    echo -e "${RED}0)${NC} Salir"
    echo
    echo -e "${CYAN}═════════════════════════════════════════════${NC}"
    echo -ne "${MAGENTA}Ingresa tu opción [0-9]: ${NC}"
    read -r option
    echo

    case $option in
        1)
            echo -e "${BLUE}Ejecutando: Inventario Completo (CSV)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --all --format csv${NC}\n"
            $PYTHON_CMD inventory_cli.py --all --format csv
            ;;
        2)
            echo -e "${BLUE}Ejecutando: Inventario sin Boards (CSV)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --all --exclude boards --format csv${NC}\n"
            $PYTHON_CMD inventory_cli.py --all --exclude boards --format csv
            ;;
        3)
            echo -e "${BLUE}Ejecutando: Inventario sin Boards ni Test Plans (CSV)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --all --exclude boards test --format csv${NC}\n"
            $PYTHON_CMD inventory_cli.py --all --exclude boards test --format csv
            ;;
        4)
            echo -e "${BLUE}Ejecutando: Solo Pipelines (CSV + JSON)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --include pipelines --format both${NC}\n"
            $PYTHON_CMD inventory_cli.py --include pipelines --format both
            ;;
        5)
            echo -e "${BLUE}Ejecutando: Solo Repositorios (CSV + JSON)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --include repos --format both${NC}\n"
            $PYTHON_CMD inventory_cli.py --include repos --format both
            ;;
        6)
            echo -e "${BLUE}Ejecutando: Infraestructura y Seguridad (CSV)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --include infrastructure security --format csv${NC}\n"
            $PYTHON_CMD inventory_cli.py --include infrastructure security --format csv
            ;;
        7)
            echo -e "${BLUE}Ejecutando: Inventario Completo (JSON)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --all --format json --pretty${NC}\n"
            $PYTHON_CMD inventory_cli.py --all --format json --pretty
            ;;
        8)
            echo -e "${BLUE}Ejecutando: Core + Work Items + Repos (CSV)${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py --include core work_items repos --format csv${NC}\n"
            $PYTHON_CMD inventory_cli.py --include core work_items repos --format csv
            ;;
        9)
            echo -e "${MAGENTA}Ingresa tu comando personalizado (sin 'python inventory_cli.py'):${NC}"
            echo -ne "${CYAN}-- ${NC}"
            read -r custom_args
            echo
            echo -e "${BLUE}Ejecutando comando personalizado${NC}"
            echo -e "${YELLOW}Comando: python inventory_cli.py ${custom_args}${NC}\n"
            $PYTHON_CMD inventory_cli.py $custom_args
            ;;
        0)
            echo -e "${GREEN}Hasta luego!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Opcion invalida. Por favor ingresa un numero del 0 al 9.${NC}"
            ;;
    esac

    # Mostrar resultado
    if [ $? -eq 0 ]; then
        echo
        echo -e "${GREEN}Comando completado exitosamente${NC}"
    else
        echo
        echo -e "${RED}Error ejecutando el comando${NC}"
    fi

    echo
    echo -e "${CYAN}════════════════════════════════════════════=${NC}"
    echo -ne "${MAGENTA}Presiona ENTER para volver al menu...${NC}"
    read -r
    echo
done
