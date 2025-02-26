#!/bin/ksh

# Codes couleur
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Vérification des droits root
if [ $(id -u) -ne 0 ]; then
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
        proc_info=$(ps -fp "$pid" 2>/dev/null | tail -1)
        cmd=$(echo "$proc_info" | awk '{for(i=8;i<=NF;++i)print $i}' | xargs)
        if [[ $cmd == /* ]]; then
            echo "$cmd" | awk '{print $1}'
        else
            echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

# Fonction pour obtenir l'utilisateur
get_process_user() {
    local pid=$1
    if [ -n "$pid" ]; then
        ps -fp "$pid" 2>/dev/null | tail -1 | awk '{print $1}' || echo "N/A"
    else
        echo "N/A"
    fi
}

# Fonction pour obtenir le service
get_service_name() {
    local process_name=$1
    local pid=$2
    
    # Vérifier si c'est un daemon connu
    if [ -f /etc/rc.d/init.d/"$process_name" ]; then
        echo "$process_name"
    elif lssrc -a | grep -q "$process_name"; then
        lssrc -a | grep "$process_name" | head -1 | awk '{print $1}'
    else
        echo "N/A"
    fi
}

echo -e "${BLUE}Collecte des informations...${NC}"

# Utilisation de netstat pour lister les ports en écoute
netstat -Aan | grep LISTEN | while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    port=$(echo "$line" | awk '{print $5}' | awk -F. '{print $NF}')
    
    # Pour TCP/IP, nous utilisons rmsock pour obtenir le PID
    if [[ "$proto" == "tcp"* ]]; then
        socket=$(echo "$line" | awk '{print $2}')
        pid_info=$(rmsock "$socket" tcpcb 2>/dev/null)
        pid=$(echo "$pid_info" | grep "Process ID" | awk '{print $NF}')
    else
        # Pour UDP, c'est plus difficile, on utilise une approche différente
        socket=$(echo "$line" | awk '{print $2}')
        pid_info=$(rmsock "$socket" inpcb 2>/dev/null)
        pid=$(echo "$pid_info" | grep "Process ID" | awk '{print $NF}')
    fi
    
    if [ -n "$pid" ]; then
        # Obtenir le nom du programme à partir du PID
        program=$(ps -p "$pid" -o comm=)
        user=$(get_process_user "$pid")
        path=$(get_process_path "$pid")
        service=$(get_service_name "$program" "$pid")
        
        # Stocker dans le fichier temporaire
        echo -e "$proto\t$port\t$program\t$service\t$user\t$path" >> "$TEMP_FILE"
    fi
done

# Si aucun port n'a été trouvé, essayer une méthode alternative
if [ ! -s "$TEMP_FILE" ]; then
    # Méthode alternative utilisant lsof si disponible
    if command -v lsof >/dev/null 2>&1; then
        lsof -i -P | grep LISTEN | while read -r line; do
            program=$(echo "$line" | awk '{print $1}')
            pid=$(echo "$line" | awk '{print $2}')
            user=$(echo "$line" | awk '{print $3}')
            proto=$(echo "$line" | awk '{print $8}' | cut -d':' -f1)
            port=$(echo "$line" | awk '{print $9}' | rev | cut -d':' -f1 | rev)
            
            path=$(get_process_path "$pid")
            service=$(get_service_name "$program" "$pid")
            
            echo -e "$proto\t$port\t$program\t$service\t$user\t$path" >> "$TEMP_FILE"
        done
    fi
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