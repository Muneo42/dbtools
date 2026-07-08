#!/usr/bin/env bash
#
# rebuild.sh — Détruit et reconstruit intégralement l'infra DBTools.
#
# Enchaîne : destroy → apply → nettoyage known_hosts → contrôle réseau →
#            playbook Ansible complet → backups de validation (MariaDB + PostgreSQL).
#
# Ne touche PAS à la VM GitLab 203 (uniquement les 3 LXC).
#
# Usage :
#   ./rebuild.sh          # demande confirmation avant de détruire
#   ./rebuild.sh -y       # pas de confirmation (destruction directe)
#
set -euo pipefail

# --- Configuration ---------------------------------------------------------
INFRA_DIR="$HOME/DBTools"
TOFU_DIR="$INFRA_DIR/opentofu"
ANSIBLE_DIR="$INFRA_DIR/ansible"
ENV_FILE="$INFRA_DIR/.env"
LXC_TARGET='proxmox_virtual_environment_container.db'
LXC_IPS=(192.168.1.160 192.168.1.161 192.168.1.162)
DBTOOLS_IP=192.168.1.160

# --- Couleurs (facultatif, pour la lisibilité) -----------------------------
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
else
    BOLD=''; GREEN=''; RED=''; YELLOW=''; RESET=''
fi

step() { echo; echo "${BOLD}==> $*${RESET}"; }
ok()   { echo "${GREEN}  [OK] $*${RESET}"; }
warn() { echo "${YELLOW}  [!] $*${RESET}"; }
die()  { echo "${RED}  [ERREUR] $*${RESET}" >&2; exit 1; }

# --- Vérifications préalables ----------------------------------------------
[[ -f "$ENV_FILE" ]] || die "Fichier $ENV_FILE introuvable (endpoint + token Proxmox)."
[[ -d "$TOFU_DIR" ]] || die "Répertoire $TOFU_DIR introuvable."
[[ -d "$ANSIBLE_DIR" ]] || die "Répertoire $ANSIBLE_DIR introuvable."

# Charge l'endpoint et le token Proxmox (TF_VAR_*)
# shellcheck source=/dev/null
source "$ENV_FILE"

# --- Confirmation ----------------------------------------------------------
AUTO_YES=false
[[ "${1:-}" == "-y" ]] && AUTO_YES=true

if ! $AUTO_YES; then
    echo "${YELLOW}Ce script va DÉTRUIRE puis reconstruire les LXC 160, 161, 162.${RESET}"
    echo "La VM GitLab 203 ne sera pas touchée."
    read -r -p "Continuer ? [oui/non] " reply
    [[ "$reply" == "oui" ]] || die "Annulé."
fi

# --- 1. Destroy ------------------------------------------------------------
step "1/5 — Destruction des 3 LXC"
cd "$TOFU_DIR"
tofu destroy -target="$LXC_TARGET" -auto-approve
ok "LXC détruits."

# --- 2. Apply --------------------------------------------------------------
step "2/5 — Recréation des 3 LXC (IP statiques, MAC fixes)"
tofu apply -target="$LXC_TARGET" -auto-approve
ok "LXC recréés."

# --- 3. Nettoyage known_hosts ----------------------------------------------
step "3/5 — Rafraîchissement des clés d'hôte SSH"
for ip in "${LXC_IPS[@]}"; do
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
done
# Laisse le temps aux conteneurs de démarrer complètement
sleep 8
for ip in "${LXC_IPS[@]}"; do
    ssh-keyscan -H "$ip" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
done
ok "known_hosts à jour."

# --- 4. Contrôle réseau ----------------------------------------------------
step "4/5 — Contrôle de la connectivité Internet des LXC"
net_fail=0
for ip in "${LXC_IPS[@]}"; do
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
           "root@$ip" "ping -c1 -W2 1.1.1.1 >/dev/null 2>&1"; then
        ok "$ip — Internet OK"
    else
        warn "$ip — pas de connectivité Internet"
        net_fail=1
    fi
done
[[ $net_fail -eq 0 ]] || die "Au moins un LXC n'a pas Internet — arrêt avant Ansible."

# --- 5. Configuration Ansible ----------------------------------------------
step "5/5 — Configuration via Ansible (MariaDB + PostgreSQL + dbtools)"
cd "$ANSIBLE_DIR"
ansible all -m ping
ansible-playbook db.yml

# --- Validation : backups des deux SGBD ------------------------------------
step "Validation — backups depuis le LXC dbtools"
ssh "root@$DBTOOLS_IP" "cd /opt/dbtools && \
    php vendor/bin/db-tools --version && \
    php vendor/bin/db-tools database:backup -c mariadb --no-interaction && \
    php vendor/bin/db-tools database:backup -c postgresql --no-interaction"

echo
ok "${BOLD}Reconstruction complète terminée avec succès.${RESET}"
echo "Les dumps sont dans /opt/dbtools/var/<connexion>/AAAA/MM/ sur le LXC 160."
