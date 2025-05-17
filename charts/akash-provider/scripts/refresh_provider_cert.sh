#!/bin/bash
# Filename: refresh_provider_cert.sh

set -x

# Figure the provider address in case the user passes `--from=<key_name>` instead of `--from=<akash1...>` address.
PROVIDER_ADDRESS="$(provider-services keys show $AKASH_FROM -a)"
if [[ -z "$PROVIDER_ADDRESS" ]]; then
  echo "PROVIDER_ADDRESS variable is empty. Something went wrong"
  exit 1
fi

CERT_SYMLINK="${AKASH_HOME}/${PROVIDER_ADDRESS}.pem"
CERT_REAL_PATH="/config/provider.pem"
rm -vf "$CERT_SYMLINK"
# Provider cert is coming from the mounted secret
ln -sv "$CERT_REAL_PATH" "$CERT_SYMLINK"
# 0 = yes; otherwise do not (re-)generate new provider certificate
GEN_NEW_CERT=1

# Check whether the certificate is present and valid on the blockchain
if [[ -f "${CERT_REAL_PATH}" ]]; then
  LOCAL_CERT_SN="$(cat "${CERT_REAL_PATH}" | openssl x509 -serial -noout | cut -d'=' -f2)"
  if [[ -n "$LOCAL_CERT_SN" ]]; then
    LOCAL_CERT_SN_DECIMAL=$(echo "obase=10; ibase=16; $LOCAL_CERT_SN" | bc)
    REMOTE_CERT_STATUS="$(AKASH_OUTPUT=json provider-services query cert list --owner $PROVIDER_ADDRESS --state valid --serial $LOCAL_CERT_SN_DECIMAL --reverse | jq -r '.certificates[0].certificate.state')"
    echo "Provider certificate serial number: ${LOCAL_CERT_SN}, status on chain: ${REMOTE_CERT_STATUS:-unknown}"
    
    # If certificate is valid on chain, check expiration
    if [[ "valid" == "$REMOTE_CERT_STATUS" ]]; then
      # Check if certificate expires soon (within 7 days)
      openssl x509 -checkend 604800 -noout -in "${CERT_REAL_PATH}" 2>/dev/null 1>&2
      rc=$?
      if [[ $rc -eq 0 ]]; then
        echo "Certificate is valid and not expiring soon. No need to regenerate."
        exit 0
      else
        echo "Certificate expires in less than 7 days, will generate a new one."
        GEN_NEW_CERT=0
      fi
    else
      echo "Certificate exists but is not valid on chain. Will generate a new one."
      GEN_NEW_CERT=0
    fi
  else
    echo "LOCAL_CERT_SN variable is empty. Certificate file exists but may be empty or malformed."
    GEN_NEW_CERT=0
  fi
else
  echo "${CERT_REAL_PATH} file is missing. Will generate a new certificate."
  GEN_NEW_CERT=0
fi

if [[ "$GEN_NEW_CERT" -eq "0" ]]; then
  echo "Generating new provider certificate"
  provider-services tx cert generate server provider.{{ .Values.domain }}

  echo "Publishing new provider certificate"
  provider-services tx cert publish server
  
  # Save the new certificate to the secret
  # First, retrieve the generated certificate
  NEW_CERT=$(cat "${CERT_REAL_PATH}")
  
  # Create a temporary file with the new certificate
  TEMP_CERT_FILE="/tmp/provider.pem"
  echo "$NEW_CERT" > $TEMP_CERT_FILE
  
  # Update the Kubernetes secret
  kubectl -n {{ .Release.Namespace }} create secret generic {{ include "provider.fullname" . }}-cert \
    --from-file=provider.pem=$TEMP_CERT_FILE \
    --dry-run=client -o yaml | kubectl apply -f -
    
  rm -f $TEMP_CERT_FILE
fi
