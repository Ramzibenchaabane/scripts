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

echo -e "${GREEN}=== Analyse des ports, processus et services sur AIX ===${NC}"
echo ""

# Fichier temporaire
TEMP_FILE=/tmp/map_ports.$
touch $TEMP_FILE
if [ $? -ne 0 ]; then
   echo -e "${RED}Impossible de créer un fichier temporaire${NC}"
   exit 1
fi
chmod 600 $TEMP_FILE

# Fonction pour obtenir le chemin d'installation
get_process_path() {
    local pid=$1
    if [ -n "$pid" ]; then
        # Sur AIX, on peut utiliser procfiles pour obtenir le chemin du binaire
        path=$(procfiles -n $pid 2>/dev/null | grep -m 1 "^[0-9]* : F" | awk '{print $4}')
        if [ -n "$path" ]; then
            echo "$path"
        else
            # Méthode alternative
            which $(ps -p $pid -o comm= | tr -d ' ') 2>/dev/null || echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

# Fonction pour obtenir l'utilisateur
get_process_user() {
    local pid=$1
    if [ -n "$pid" ]; then
        ps -p "$pid" -o user= 2>/dev/null | tr -d ' ' || echo "N/A"
    else
        echo "N/A"
    fi
}

# Fonction pour obtenir le service
get_service_name() {
    local process_name=$1
    local pid=$2
    
    # Vérifier via lssrc (SRC - AIX Subsystem Resource Controller)
    local subsys=$(lssrc -a 2>/dev/null | grep -i "$process_name" | head -1 | awk '{print $1}')
    if [ -n "$subsys" ]; then
        echo "$subsys"
        return
    fi
    
    # Vérifier via les scripts de démarrage
    for initdir in /etc/rc.d/init.d /etc/rc.d /sbin/rc.d; do
        if [ -d "$initdir" ]; then
            for f in "$initdir"/*; do
                if [ -f "$f" ] && grep -q "$process_name" "$f" 2>/dev/null; then
                    basename "$f"
                    return
                fi
            done
        fi
    done
    
    # Vérifier via ps pour les démons spécifiques à AIX
    if ps -ef | grep -v grep | grep -q "/$process_name "; then
        echo "$process_name"
        return
    fi
    
    echo "N/A"
}

echo -e "${BLUE}Collecte des informations...${NC}"

# Utilisation de netstat pour lister les ports TCP en écoute
echo -e "${BLUE}Analyse des ports TCP...${NC}"
netstat -Aan | grep LISTEN | while read -r line; do
    proto="tcp"
    local_addr=$(echo "$line" | awk '{print $5}')
    port=$(echo "$local_addr" | awk -F. '{print $NF}')
    socket=$(echo "$line" | awk '{print $2}')
    
    # Utiliser rmsock pour obtenir le PID
    pid_info=$(rmsock $socket tcpcb 2>/dev/null)
    if [ $? -eq 0 ]; then
        pid=$(echo "$pid_info" | grep "Process ID" | awk '{print $NF}')
        if [ -n "$pid" ]; then
            program=$(ps -p "$pid" -o comm= | tr -d ' ')
            user=$(get_process_user "$pid")
            path=$(get_process_path "$pid")
            service=$(get_service_name "$program" "$pid")
            
            # Stocker dans le fichier temporaire
            echo -e "$proto\t$port\t$program\t$service\t$user\t$path" >> "$TEMP_FILE"
        fi
    fi
done

# Analyse des ports UDP
echo -e "${BLUE}Analyse des ports UDP...${NC}"
netstat -Aan | grep "^udp" | while read -r line; do
    proto="udp"
    local_addr=$(echo "$line" | awk '{print $5}')
    port=$(echo "$local_addr" | awk -F. '{print $NF}')
    socket=$(echo "$line" | awk '{print $2}')
    
    # Utiliser rmsock pour UDP
    pid_info=$(rmsock $socket inpcb 2>/dev/null)
    if [ $? -eq 0 ]; then
        pid=$(echo "$pid_info" | grep "Process ID" | awk '{print $NF}')
        if [ -n "$pid" ]; then
            program=$(ps -p "$pid" -o comm= | tr -d ' ')
            user=$(get_process_user "$pid")
            path=$(get_process_path "$pid")
            service=$(get_service_name "$program" "$pid")
            
            # Stocker dans le fichier temporaire
            echo -e "$proto\t$port\t$program\t$service\t$user\t$path" >> "$TEMP_FILE"
        fi
    fi
done

# Méthode alternative utilisant lsof si disponible et si nécessaire
if [ ! -s "$TEMP_FILE" ] && command -v lsof >/dev/null 2>&1; then
    echo -e "${BLUE}Utilisation de lsof comme méthode alternative...${NC}"
    lsof -i -P | grep LISTEN | while read -r line; do
        program=$(echo "$line" | awk '{print $1}')
        pid=$(echo "$line" | awk '{print $2}')
        user=$(echo "$line" | awk '{print $3}')
        proto_port=$(echo "$line" | awk '{print $9}')
        proto=$(echo "$proto_port" | cut -d':' -f1)
        port=$(echo "$proto_port" | rev | cut -d':' -f1 | rev)
        
        path=$(get_process_path "$pid")
        service=$(get_service_name "$program" "$pid")
        
        echo -e "$proto\t$port\t$program\t$service\t$user\t$path" >> "$TEMP_FILE"
    done
fi

# Méthode spécifique AIX inetd (pour les services inetd)
echo -e "${BLUE}Vérification des services inetd...${NC}"
if [ -f /etc/inetd.conf ]; then
    grep -v "^#" /etc/inetd.conf | while read -r line; do
        if [ -n "$line" ]; then
            service_name=$(echo "$line" | awk '{print $1}')
            socket_type=$(echo "$line" | awk '{print $2}')
            proto=$(echo "$line" | awk '{print $3}')
            wait_flag=$(echo "$line" | awk '{print $4}')
            user=$(echo "$line" | awk '{print $5}')
            server_path=$(echo "$line" | awk '{print $6}')
            program=$(basename "$server_path")
            
            # Obtenir le port à partir du service
            port=$(grep "^$service_name" /etc/services | head -1 | awk '{print $2}' | cut -d'/' -f1)
            
            if [ -n "$port" ]; then
                echo -e "$proto\t$port\t$program\t$service_name\t$user\t$server_path" >> "$TEMP_FILE"
            fi
        fi
    done
fi

# Affichage des résultats
echo -e "\n${GREEN}=== Résultats ===${NC}"
printf "${BLUE}%-10s %-8s %-20s %-20s %-15s %-s${NC}\n" "PROTOCOLE" "PORT" "PROCESSUS" "SERVICE" "UTILISATEUR" "CHEMIN D'INSTALLATION"
echo "-------------------------------------------------------------------------------------------------------------"

# Tri et affichage des résultats
if [ -s "$TEMP_FILE" ]; then
    # Éliminer les doublons potentiels (même protocole et port)
    sort -u -k1,2 "$TEMP_FILE" | sort -n -k2 | while IFS=$'\t' read -r proto port program service user path; do
        printf "%-10s %-8s %-20s %-20s %-15s %-s\n" "$proto" "$port" "$program" "$service" "$user" "$path"
    done
else
    echo "Aucun port en écoute trouvé"
fi

# Nettoyage
rm -f "$TEMP_FILE"

echo -e "\n${GREEN}=== Analyse terminée ===${NC}"