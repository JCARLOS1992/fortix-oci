#!/usr/bin/env bash
# =============================================================================
# fortix-oci-launch.sh
# Reintenta crear la instancia ARM (VM.Standard.A1.Flex) en Oracle Cloud hasta
# que haya capacidad. Además:
#   - crea (una sola vez) la VCN, el internet gateway, la ruta y la subred pública
#   - abre en la Security List: 22 (SSH), 80 y 443
#   - abre 80 y 443 en el firewall interno de Ubuntu (cloud-init)
#   - al crearse la instancia, le asigna una IP pública RESERVADA y la muestra
#
# Es seguro ejecutarlo varias veces: reutiliza lo que ya exista con los
# mismos nombres y no crea una segunda instancia si ya hay una "fortix".
#
# Requisitos: OCI CLI configurado (Cloud Shell ya lo trae listo).
# Uso:        bash fortix-oci-launch.sh
# Opcional:   SSH_CIDR="TU.IP.PUBLICA/32" bash fortix-oci-launch.sh
# =============================================================================
set -uo pipefail

# ----------------------------- Configuración ---------------------------------
REGION="${REGION:-sa-bogota-1}"                 # Colombia Central (Bogotá)
INSTANCE_NAME="${INSTANCE_NAME:-fortix}"
SHAPE="VM.Standard.A1.Flex"
OCPUS="${OCPUS:-4}"
MEMORY_GB="${MEMORY_GB:-24}"
BOOT_GB="${BOOT_GB:-150}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICY0swp29xNyJHkhUvCFMufuVhv/hTKcp2eRnCvYWxgM fortix-oracle}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"               # pon tu IP/32 para limitar el 22
RETRY_SECONDS="${RETRY_SECONDS:-60}"            # espera entre intentos
VCN_NAME="fortix-vcn"
IGW_NAME="fortix-igw"
SUBNET_NAME="fortix-subnet"
IP_NAME="fortix-ip"
LOG_FILE="${LOG_FILE:-fortix-oci-launch.log}"
MAX_MINUTES="${MAX_MINUTES:-0}"                 # 0 = sin límite; >0 = sale tras N minutos (GitHub Actions)
START_TS="$(date +%s)"

# ------------------------------- Utilidades ----------------------------------
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
oci_() { oci --region "$REGION" "$@"; }
# Devuelve vacío si el valor es "", "null" o "None"
clean() { case "${1:-}" in ""|null|None) echo "" ;; *) echo "$1" ;; esac; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ----------------------------- Comprobaciones --------------------------------
command -v oci >/dev/null 2>&1 || die "No encuentro el comando 'oci'. Instala OCI CLI o usa Cloud Shell."

COMPARTMENT_ID="${COMPARTMENT_ID:-${OCI_TENANCY:-}}"
if [ -z "$COMPARTMENT_ID" ]; then
  CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
  COMPARTMENT_ID="$(awk -F'=' '
      /^\[/ { s = ($0 == "[DEFAULT]") }
      s && $1 ~ /^[[:space:]]*tenancy[[:space:]]*$/ { gsub(/[[:space:]]/, "", $2); print $2; exit }
    ' "$CONFIG_FILE" 2>/dev/null)"
fi
[ -n "$COMPARTMENT_ID" ] || die "No pude obtener el OCID del tenancy. Exporta COMPARTMENT_ID=ocid1.tenancy..."

oci_ iam availability-domain list -c "$COMPARTMENT_ID" >/dev/null 2>&1 \
  || die "OCI CLI no puede autenticarse. Revisa 'oci setup config' o usa Cloud Shell."

C="$COMPARTMENT_ID"
log "Región: $REGION | Compartimento: ${C:0:30}..."

# --------------------------------- Red ---------------------------------------
VCN_ID="$(clean "$(oci_ network vcn list -c "$C" --display-name "$VCN_NAME" \
  --lifecycle-state AVAILABLE --query 'data[0].id' --raw-output 2>/dev/null)")"
if [ -z "$VCN_ID" ]; then
  log "Creando VCN $VCN_NAME (10.0.0.0/16)..."
  VCN_ID="$(oci_ network vcn create -c "$C" --display-name "$VCN_NAME" \
    --cidr-blocks '["10.0.0.0/16"]' --dns-label fortix \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output 2>>"$LOG_FILE")"
  VCN_ID="$(clean "$VCN_ID")"
  [ -n "$VCN_ID" ] || die "No se pudo crear la VCN (detalle en $LOG_FILE)."
else
  log "VCN existente: $VCN_NAME"
fi

RT_ID="$(oci_ network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)"
SL_ID="$(oci_ network vcn get --vcn-id "$VCN_ID" --query 'data."default-security-list-id"' --raw-output)"

IGW_ID="$(clean "$(oci_ network internet-gateway list -c "$C" --vcn-id "$VCN_ID" \
  --query 'data[0].id' --raw-output 2>/dev/null)")"
if [ -z "$IGW_ID" ]; then
  log "Creando internet gateway..."
  IGW_ID="$(clean "$(oci_ network internet-gateway create -c "$C" --vcn-id "$VCN_ID" \
    --display-name "$IGW_NAME" --is-enabled true \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output 2>>"$LOG_FILE")")"
  [ -n "$IGW_ID" ] || die "No se pudo crear el internet gateway."
fi

log "Configurando ruta 0.0.0.0/0 -> internet gateway..."
oci_ network route-table update --rt-id "$RT_ID" --force \
  --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" \
  >/dev/null 2>>"$LOG_FILE" || die "No se pudo actualizar la tabla de rutas."

log "Reglas de entrada: 22 desde $SSH_CIDR, 80 y 443 desde 0.0.0.0/0..."
INGRESS="$(cat <<EOF
[
  {"source":"$SSH_CIDR","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
  {"source":"0.0.0.0/0","protocol":"1","isStateless":false,"icmpOptions":{"type":3,"code":4}},
  {"source":"10.0.0.0/16","protocol":"1","isStateless":false,"icmpOptions":{"type":3}}
]
EOF
)"
oci_ network security-list update --security-list-id "$SL_ID" --force \
  --ingress-security-rules "$INGRESS" >/dev/null 2>>"$LOG_FILE" \
  || die "No se pudo actualizar la Security List."

SUBNET_ID="$(clean "$(oci_ network subnet list -c "$C" --vcn-id "$VCN_ID" \
  --display-name "$SUBNET_NAME" --query 'data[0].id' --raw-output 2>/dev/null)")"
if [ -z "$SUBNET_ID" ]; then
  log "Creando subred pública $SUBNET_NAME (10.0.0.0/24)..."
  SUBNET_ID="$(clean "$(oci_ network subnet create -c "$C" --vcn-id "$VCN_ID" \
    --display-name "$SUBNET_NAME" --cidr-block 10.0.0.0/24 --dns-label publica \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output 2>>"$LOG_FILE")")"
  [ -n "$SUBNET_ID" ] || die "No se pudo crear la subred."
fi
log "Red lista."

# --------------------------- Imagen y dominio --------------------------------
AD="$(oci_ iam availability-domain list -c "$C" --query 'data[0].name' --raw-output)"
IMAGE_ID="$(clean "$(oci_ compute image list -c "$C" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all \
  --query "data[?!(contains(\"display-name\", 'Minimal'))] | [0].id" --raw-output 2>/dev/null)")"
[ -n "$IMAGE_ID" ] || die "No encontré la imagen Ubuntu 24.04 aarch64 para $SHAPE."
IMAGE_NAME="$(oci_ compute image get --image-id "$IMAGE_ID" --query 'data."display-name"' --raw-output)"
log "Imagen: $IMAGE_NAME"
log "Dominio de disponibilidad: $AD"

# ------------------------ Archivos para el arranque --------------------------
KEY_FILE="$TMP_DIR/key.pub"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$KEY_FILE"

USERDATA_FILE="$TMP_DIR/cloud-init.sh"
cat > "$USERDATA_FILE" <<'EOF'
#!/bin/bash
# La imagen Ubuntu de Oracle bloquea todo salvo el 22 en iptables.
# Abrimos 80 y 443 justo antes de la regla REJECT y lo dejamos persistente.
POS=$(iptables -L INPUT --line-numbers | awk '/REJECT/ {print $1; exit}')
POS=${POS:-1}
iptables -I INPUT "$POS" -m state --state NEW -p tcp --dport 443 -j ACCEPT
iptables -I INPUT "$POS" -m state --state NEW -p tcp --dport 80 -j ACCEPT
netfilter-persistent save || true
EOF

# ------------------------- ¿Ya existe la instancia? --------------------------
INSTANCE_ID="$(clean "$(oci_ compute instance list -c "$C" --display-name "$INSTANCE_NAME" \
  --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
  --raw-output 2>/dev/null)")"

# ------------------------------ Bucle de intentos ----------------------------
if [ -n "$INSTANCE_ID" ]; then
  log "Ya existe una instancia '$INSTANCE_NAME'; no creo otra."
else
  log "Intentando crear $SHAPE con $OCPUS OCPU / $MEMORY_GB GB y disco de $BOOT_GB GB."
  log "Reintentará cada ~${RETRY_SECONDS}s hasta que haya capacidad. Ctrl+C para detener."
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    # Si otra copia del script (Cloud Shell o la lanzadera) ya la creó, no duplicar.
    INSTANCE_ID="$(clean "$(oci_ compute instance list -c "$C" --display-name "$INSTANCE_NAME" \
      --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
      --raw-output 2>/dev/null)")"
    if [ -n "$INSTANCE_ID" ]; then
      log "La instancia '$INSTANCE_NAME' ya existe (creada por otra ejecución)."
      break
    fi
    out="$(oci_ compute instance launch -c "$C" \
      --availability-domain "$AD" \
      --display-name "$INSTANCE_NAME" \
      --shape "$SHAPE" \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
      --image-id "$IMAGE_ID" \
      --boot-volume-size-in-gbs "$BOOT_GB" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip false \
      --ssh-authorized-keys-file "$KEY_FILE" \
      --user-data-file "$USERDATA_FILE" \
      --query 'data.id' --raw-output 2>&1)"

    INSTANCE_ID="$(grep -o 'ocid1\.instance\.[^"[:space:]]*' <<<"$out" | head -n1)"
    if [ -n "$INSTANCE_ID" ]; then
      log "¡Instancia creada en el intento $attempt!"
      break
    fi

    if grep -qiE 'out of (host )?capacity' <<<"$out"; then
      wait_s=$RETRY_SECONDS
      log "Intento $attempt: sin capacidad."
    elif grep -qiE 'TooManyRequests|"status": 429' <<<"$out"; then
      wait_s=$((RETRY_SECONDS * 3))
      log "Intento $attempt: Oracle pide ir más despacio (429)."
    elif grep -qiE 'InternalError|ServiceUnavailable|"status": 5[0-9][0-9]|timed out|RequestException|Connection' <<<"$out"; then
      wait_s=$RETRY_SECONDS
      log "Intento $attempt: error temporal del servicio."
    else
      log "Intento $attempt: error no recuperable. Respuesta de Oracle:"
      printf '%s\n' "$out" | tee -a "$LOG_FILE"
      exit 1
    fi
    if [ "$MAX_MINUTES" -gt 0 ] && [ $(( $(date +%s) - START_TS )) -ge $(( MAX_MINUTES * 60 )) ]; then
      log "Se alcanzó el límite de $MAX_MINUTES min sin capacidad. La próxima ejecución seguirá intentando."
      exit 0
    fi
    sleep_s=$((wait_s + RANDOM % 15))
    log "Reintento en ${sleep_s}s..."
    sleep "$sleep_s"
  done
fi

# --------------------------- Esperar a RUNNING -------------------------------
log "Esperando a que la instancia esté RUNNING..."
oci_ compute instance get --instance-id "$INSTANCE_ID" \
  --wait-for-state RUNNING --max-wait-seconds 1200 >/dev/null 2>>"$LOG_FILE" \
  || die "La instancia no llegó a RUNNING. Revísala en la consola."

# --------------------------- IP pública reservada ----------------------------
VNIC_ID="$(oci_ compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0].id' --raw-output)"
PRIV_IP_ID="$(oci_ network private-ip list --vnic-id "$VNIC_ID" --query 'data[0].id' --raw-output)"

PUBLIC_IP="$(clean "$(oci_ network public-ip get --private-ip-id "$PRIV_IP_ID" \
  --query 'data."ip-address"' --raw-output 2>/dev/null)")"
if [ -z "$PUBLIC_IP" ]; then
  log "Asignando IP pública reservada..."
  oci_ network public-ip create -c "$C" --lifetime RESERVED \
    --private-ip-id "$PRIV_IP_ID" --display-name "$IP_NAME" \
    --wait-for-state ASSIGNED >/dev/null 2>>"$LOG_FILE" \
    || die "No se pudo asignar la IP reservada (detalle en $LOG_FILE)."
  PUBLIC_IP="$(oci_ network public-ip get --private-ip-id "$PRIV_IP_ID" \
    --query 'data."ip-address"' --raw-output)"
fi

printf '\a'
log "=============================================================="
log " LISTO. IP pública reservada: $PUBLIC_IP"
log " Conéctate con:  ssh -i <ruta-a-tu-llave-privada> ubuntu@$PUBLIC_IP"
log " Abiertos: 22 (desde $SSH_CIDR), 80 y 443."
log "=============================================================="
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '## ✅ Instancia fortix lista\n\n**IP pública reservada:** `%s`\n\nYa puedes desactivar este workflow.\n' \
    "$PUBLIC_IP" >> "$GITHUB_STEP_SUMMARY"
fi
