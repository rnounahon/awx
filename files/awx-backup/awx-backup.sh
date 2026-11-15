#!/bin/bash

# ==========================================
# BACKUP AUTOMATIQUE AWX
# AWX Operator 2.19.1
# ==========================================

set -Euo pipefail

log "Utilisateur : $(whoami)"
log "HOME : $HOME"

"$KUBECTL" config current-context 2>&1 | while read -r line
do
   log "$line"
done

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------
export KUBECONFIG="/home/rnounahon/.kube/config"

KUBECTL="/awx/config/kubectl"
NAMESPACE="awx"
AWX_NAME="awx"

BACKUP_PVC="awx-backup-postgres-pvc"
BACKUP_ROOT="/awx/backups"

LOCK_FILE="/tmp/backup-awx.lock"

mkdir -p "$BACKUP_ROOT"

LOG_FILE="${BACKUP_ROOT}/backup-awx.log"

exec >>"$LOG_FILE" 2>&1

# ------------------------------------------------------------------
# Fonctions
# ------------------------------------------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $*"
}

cleanup() {
    log "Fin d'exécution."
}

trap cleanup EXIT

# ------------------------------------------------------------------
# Verrou anti double exécution
# ------------------------------------------------------------------

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "Une sauvegarde est déjà en cours."
    exit 1
fi

# ------------------------------------------------------------------
# Début
# ------------------------------------------------------------------

log "===================================================="
log "DEBUT BACKUP AWX"
log "===================================================="

# ------------------------------------------------------------------
# Vérifications
# ------------------------------------------------------------------

if [[ ! -x "$KUBECTL" ]]; then
    log "ERREUR : kubectl introuvable : $KUBECTL"
    exit 1
fi

if [[ ! -d "$BACKUP_ROOT" ]]; then
    log "ERREUR : répertoire absent : $BACKUP_ROOT"
    exit 1
fi

if [[ ! -w "$BACKUP_ROOT" ]]; then
    log "ERREUR : répertoire non accessible en écriture : $BACKUP_ROOT"
    log "Utilisateur : $(id)"
    log "Permissions : $(ls -ld "$BACKUP_ROOT")"
    exit 1
fi

# Vérification réelle de l'écriture

touch "$BACKUP_ROOT/.write_test" 2>/dev/null || {
    log "ERREUR : impossible d'écrire dans $BACKUP_ROOT"
    exit 1
}

rm -f "$BACKUP_ROOT/.write_test"

# ------------------------------------------------------------------
# Diagnostic Kubernetes
# ------------------------------------------------------------------

log "Contexte Kubernetes :"

"$KUBECTL" config current-context 2>&1 | while read -r line
do
    log "$line"
done

log "PVC disponibles :"

"$KUBECTL" get pvc -A 2>&1 | while read -r line
do
    log "$line"
done

# ------------------------------------------------------------------
# Création sauvegarde
# ------------------------------------------------------------------

DATE=$(date '+%Y%m%d-%H%M%S')
BACKUP_NAME="awx-backup-${DATE}"

log "Création de la sauvegarde : $BACKUP_NAME"

cat <<EOF | "$KUBECTL" apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWXBackup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${NAMESPACE}
spec:
  deployment_name: ${AWX_NAME}
  backup_pvc: ${BACKUP_PVC}
  clean_backup_on_delete: false
  no_log: true
EOF

# ------------------------------------------------------------------
# Attente de la fin
# ------------------------------------------------------------------

TIMEOUT=10800
ELAPSED=0

while (( ELAPSED < TIMEOUT ))
do

    SUCCESS=$(
        "$KUBECTL" get awxbackup "$BACKUP_NAME" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' \
        2>/dev/null || true
    )

    FAILURE=$(
        "$KUBECTL" get awxbackup "$BACKUP_NAME" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' \
        2>/dev/null || true
    )

    if [[ "$SUCCESS" == "True" ]]; then
        log "Sauvegarde AWX terminée avec succès."
        break
    fi

    if [[ "$FAILURE" == "True" ]]; then
        log "ERREUR : échec signalé par AWX Operator."
        exit 1
    fi

    sleep 30
    ELAPSED=$((ELAPSED + 30))

done

if [[ "$SUCCESS" != "True" ]]; then
    log "ERREUR : délai dépassé après 3 heures."
    exit 1
fi

# ------------------------------------------------------------------
# Récupération du répertoire
# ------------------------------------------------------------------

BACKUP_DIRECTORY=$(
    "$KUBECTL" get awxbackup "$BACKUP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.backupDirectory}'
)

log "backupDirectory retourné : $BACKUP_DIRECTORY"

if [[ -z "$BACKUP_DIRECTORY" ]]; then
    log "ERREUR : backupDirectory vide."
    exit 1
fi

BACKUP_DIR="${BACKUP_ROOT}/$(basename "$BACKUP_DIRECTORY")"

log "Répertoire attendu : $BACKUP_DIR"

if [[ ! -d "$BACKUP_DIR" ]]; then
    log "ERREUR : sauvegarde introuvable."
    log "Vérifier le montage du volume entre le PVC et l'hôte."
    exit 1
fi

if ! find "$BACKUP_DIR" -type f -print -quit | grep -q .; then
    log "ERREUR : aucune archive trouvée dans $BACKUP_DIR"
    exit 1
fi

log "Sauvegarde disponible : $BACKUP_DIR"

# ------------------------------------------------------------------
# Rotation (4 sauvegardes)
# ------------------------------------------------------------------

mapfile -t OLD_BACKUPS < <(
    find "$BACKUP_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%T@ %p\n' |
    sort -rn |
    awk 'NR > 4 {$1=""; sub(/^ /,""); print}'
)

for OLD_BACKUP in "${OLD_BACKUPS[@]}"
do
    [[ -z "$OLD_BACKUP" ]] && continue

    log "Suppression ancienne sauvegarde : $OLD_BACKUP"
    rm -rf -- "$OLD_BACKUP"
done

# ------------------------------------------------------------------
# Fin
# ------------------------------------------------------------------

log "===================================================="
log "FIN BACKUP AWX"
log "Sauvegarde disponible dans : $BACKUP_DIR"
log "===================================================="

exit 0
