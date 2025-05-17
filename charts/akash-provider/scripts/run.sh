#!/bin/bash
# Filename: run.sh

# fail fast should these packages be missing
type curl || exit 1
type jq || exit 1
type awk || exit 1
type bc || exit 1

##
# Wait for RPC
##
/scripts/wait_for_rpc.sh

##
# Create/Update Provider certs
##
/scripts/refresh_provider_cert.sh

# Verify certificate exists before starting provider
PROVIDER_ADDRESS="$(provider-services keys show $AKASH_FROM -a)"
CERT_PATH="${AKASH_HOME}/${PROVIDER_ADDRESS}.pem"

if [[ ! -f "$CERT_PATH" || ! -s "$CERT_PATH" ]]; then
  echo "ERROR: Certificate not found at $CERT_PATH before starting provider"
  
  # Try to recover from PVC or tmp
  if [[ -f "/config/provider.pem" && -s "/config/provider.pem" ]]; then
    echo "Recovering certificate from persistent storage"
    cp -f "/config/provider.pem" "$CERT_PATH"
    chmod 600 "$CERT_PATH"
  elif [[ -f "/tmp/provider.pem" && -s "/tmp/provider.pem" ]]; then
    echo "Recovering certificate from temporary storage"
    cp -f "/tmp/provider.pem" "$CERT_PATH"
    chmod 600 "$CERT_PATH"
  else
    echo "No certificate found in any location. Provider cannot start."
    exit 1
  fi
fi

# Start provider-services and monitor its output
provider-services run
