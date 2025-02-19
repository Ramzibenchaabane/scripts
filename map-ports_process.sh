#!/bin/bash

# De la déco
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Vérification des droits root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ce script doit être exécuté en tant que root${NC}"
   exit 1
fi

echo -e "${GREEN}=== Analyse des ports, processus et services ===${NC}"
echo ""

# Fichier temporaire
TEMP_FILE=$(mktemp)

# Fonction pour obtenir le chemin d'installation
get_process_path() {
    local pid=$1
    if [ -n "$pid" ]; then
        readlink -f /proc/$pid/exe 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# Fonction pour obtenir l'utilisateur
get_process_user() {
    local pid=$1
    if [ -n "$pid" ]; then
        ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || echo "N/A"
    else
        echo "N/A"
    fi
}

# Fonction pour obtenir le service
get_service_name() {
    local process_name=$1
    local pid=$2
    
    # Tenter de trouver le service via systemctl
    if systemctl list-units --type=service --all | grep -q "$process_name"; then
        systemctl list-units --type=service --all | grep "$process_name" | head -1 | awk '{print $1}' | sed 's/\.service$//'
    else
        echo "N/A"
    fi
}

echo -e "${BLUE}Collecte des informations...${NC}"

# on get les infos
lsof -i -P -n | grep LISTEN | while read -r line; do
    program=$(echo "$line" | awk '{print $1}')
    pid=$(echo "$line" | awk '{print $2}')
    user=$(echo "$line" | awk '{print $3}')
    proto=$(echo "$line" | awk '{print $8}' | cut -d':' -f1)
    port=$(echo "$line" | awk '{print $9}' | rev | cut -d':' -f1 | rev)
    
    # on get les paths
    path=$(get_process_path "$pid")
    
    # on get les services
    service=$(get_service_name "$program" "$pid")
    
    # stockage dans un fichier temporaire
    echo -e "$proto\t$port\t$program\t$service\t$user\t$path" >> "$TEMP_FILE"
done

# Si lsof n'a rien trouvé, utiliser netstat comme backup
if [ ! -s "$TEMP_FILE" ]; then
    netstat -tulpn | grep LISTEN | while read -r line; do
        proto=$(echo "$line" | awk '{print $1}')
        port=$(echo "$line" | awk '{print $4}' | rev | cut -d':' -f1 | rev)
        pid_program=$(echo "$line" | awk '{print $7}')
        
        pid=$(echo "$pid_program" | cut -d'/' -f1)
        program=$(echo "$pid_program" | cut -d'/' -f2-)
        
        if [ "$pid" != "-" ]; then
            user=$(get_process_user "$pid")
            path=$(get_process_path "$pid")
            service=$(get_service_name "$program" "$pid")
            
            echo -e "$proto\t$port\t$program\t$service\t$user\t$path" >> "$TEMP_FILE"
        fi
    done
fi

# Affichage des résultats
echo -e "\n${GREEN}=== Résultats ===${NC}"
printf "${BLUE}%-10s %-8s %-15s %-15s %-15s %-s${NC}\n" "PROTOCOLE" "PORT" "PROCESSUS" "SERVICE" "UTILISATEUR" "CHEMIN D'INSTALLATION"
echo "--------------------------------------------------------------------------------------------------------"

# Tri et affichage des résultats
if [ -s "$TEMP_FILE" ]; then
    sort -n -k2 "$TEMP_FILE" | while IFS=$'\t' read -r proto port program service user path; do
        printf "%-10s %-8s %-15s %-15s %-15s %-s\n" "$proto" "$port" "$program" "$service" "$user" "$path"
    done
else
    echo "Aucun port en écoute trouvé"
fi

# Nettoyage
rm -f "$TEMP_FILE"

echo -e "\n${GREEN}=== Analyse terminée ===${NC}"