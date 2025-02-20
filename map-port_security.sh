#!/bin/bash

# Définition des couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Vérification des droits root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ce script doit être exécuté en tant que root${NC}"
   exit 1
fi

echo -e "${GREEN}=== Analyse des ports, processus et règles de sécurité ===${NC}"
echo ""

# Fichiers temporaires
TEMP_FILE=$(mktemp)
FIREWALL_RULES=$(mktemp)

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
    if systemctl list-units --type=service --all | grep -q "$process_name"; then
        systemctl list-units --type=service --all | grep "$process_name" | head -1 | awk '{print $1}' | sed 's/\.service$//'
    else
        echo "N/A"
    fi
}

# Fonction pour obtenir les règles de pare-feu pour un port
get_firewall_rules() {
    local port=$1
    local proto=$2
    local rules=""
    
    # Vérifier si iptables est installé
    if command -v iptables >/dev/null 2>&1; then
        # Récupérer les règles iptables
        local iptables_rules=$(iptables-save | grep -E "dport.*${port}|${port}.*dport" | grep -v '^#' || echo "")
        if [ -n "$iptables_rules" ]; then
            while IFS= read -r rule; do
                local source=$(echo "$rule" | grep -o -E 's:(([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}|anywhere)' | cut -d':' -f2)
                [ -n "$source" ] && rules="${rules}${source}, "
            done <<< "$iptables_rules"
        fi
    fi
    
    # Vérifier si nftables est installé
    if command -v nft >/dev/null 2>&1; then
        # Récupérer les règles nftables
        local nft_rules=$(nft list ruleset 2>/dev/null | grep -E "dport.*${port}|${port}.*dport" || echo "")
        if [ -n "$nft_rules" ]; then
            while IFS= read -r rule; do
                local source=$(echo "$rule" | grep -o -E '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' || echo "")
                [ -n "$source" ] && rules="${rules}${source}, "
            done <<< "$nft_rules"
        fi
    fi

    # Vérifier si c'est une instance AWS
    if curl -s http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
        echo -e "${YELLOW}Instance AWS détectée - Récupération des Security Groups...${NC}"
        # Tentative de récupération des règles des Security Groups
        if command -v aws >/dev/null 2>&1; then
            local instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
            local region=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
            
            local sg_rules=$(aws ec2 describe-instance-attribute --instance-id "$instance_id" --attribute groupSet --region "$region" 2>/dev/null)
            if [ -n "$sg_rules" ]; then
                rules="${rules}[AWS SG Rules présentes]"
            fi
        else
            rules="${rules}[AWS CLI non installé]"
        fi
    fi
    
    # Si aucune règle n'est trouvée
    if [ -z "$rules" ]; then
        echo "0.0.0.0/0 (TOUT)"
    else
        echo "${rules%, }"
    fi
}

echo -e "${BLUE}Collecte des informations...${NC}"

# Collecter les informations sur les ports
lsof -i -P -n | grep LISTEN | while read -r line; do
    program=$(echo "$line" | awk '{print $1}')
    pid=$(echo "$line" | awk '{print $2}')
    user=$(echo "$line" | awk '{print $3}')
    proto=$(echo "$line" | awk '{print $8}' | cut -d':' -f1)
    port=$(echo "$line" | awk '{print $9}' | rev | cut -d':' -f1 | rev)
    
    path=$(get_process_path "$pid")
    service=$(get_service_name "$program" "$pid")
    subnets=$(get_firewall_rules "$port" "$proto")
    
    echo -e "$proto\t$port\t$program\t$service\t$user\t$path\t$subnets" >> "$TEMP_FILE"
done

# Si lsof n'a rien trouvé, utiliser netstat
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
            subnets=$(get_firewall_rules "$port" "$proto")
            
            echo -e "$proto\t$port\t$program\t$service\t$user\t$path\t$subnets" >> "$TEMP_FILE"
        fi
    done
fi

# Affichage des résultats
echo -e "\n${GREEN}=== Résultats ===${NC}"
printf "${BLUE}%-10s %-8s %-15s %-15s %-15s %-30s %-s${NC}\n" \
    "PROTOCOLE" "PORT" "PROCESSUS" "SERVICE" "UTILISATEUR" "CHEMIN D'INSTALLATION" "SUBNETS AUTORISÉS"
echo "----------------------------------------------------------------------------------------------------------------"

if [ -s "$TEMP_FILE" ]; then
    sort -n -k2 "$TEMP_FILE" | while IFS=$'\t' read -r proto port program service user path subnets; do
        printf "%-10s %-8s %-15s %-15s %-15s %-30s %-s\n" \
            "$proto" "$port" "$program" "$service" "$user" "$path" "$subnets"
    done
else
    echo "Aucun port en écoute trouvé"
fi

# Nettoyage
rm -f "$TEMP_FILE" "$FIREWALL_RULES"

echo -e "\n${GREEN}=== Analyse terminée ===${NC}"