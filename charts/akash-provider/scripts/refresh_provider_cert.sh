#!/bin/bash
# Filename: refresh_provider_cert.sh

set -x

# Figure the provider address
PROVIDER_ADDRESS="$(provider-services keys show $AKASH_FROM -a)"
if [[ -z "$PROVIDER_ADDRESS" ]]; then
  echo "PROVIDER_ADDRESS variable is empty. Something went wrong"
  exit 1
fi

# Setup paths
CERT_DIR="${AKASH_HOME}"
CERT_SYMLINK="${CERT_DIR}/${PROVIDER_ADDRESS}.pem"
CERT_PVC_PATH="/config/provider.pem"
CERT_WRITABLE_PATH="/tmp/provider.pem"

# Create necessary directories
mkdir -p "${CERT_DIR}"

# Default to regenerating certificate
GENERATE_NEW_CERT=true

# Check if certificate exists in the persistent volume
if [[ -f "${CERT_PVC_PATH}" && -s "${CERT_PVC_PATH}" ]]; then
  echo "Found existing certificate in persistent storage"
  
  # Copy certificate to writable location and symlink location
  cp -f "${CERT_PVC_PATH}" "${CERT_WRITABLE_PATH}"
  chmod 600 "${CERT_WRITABLE_PATH}"
  
  # Create direct copy in AKASH_HOME to avoid symlink issues
  cp -f "${CERT_PVC_PATH}" "${CERT_SYMLINK}"
  chmod 600 "${CERT_SYMLINK}"
  
  # Validate certificate format
  if openssl x509 -in "${CERT_SYMLINK}" -noout 2>/dev/null; then
    echo "Certificate is valid OpenSSL format"
    
    # Check certificate validity on blockchain
    LOCAL_CERT_SN="$(openssl x509 -in "${CERT_SYMLINK}" -serial -noout 2>/dev/null | cut -d'=' -f2)"
    if [[ -n "$LOCAL_CERT_SN" ]]; then
      LOCAL_CERT_SN_DECIMAL=$(echo "obase=10; ibase=16; $LOCAL_CERT_SN" | bc)
      REMOTE_CERT_STATUS="$(AKASH_OUTPUT=json provider-services query cert list --owner $PROVIDER_ADDRESS --state valid --serial $LOCAL_CERT_SN_DECIMAL --reverse 2>/dev/null | jq -r '.certificates[0].certificate.state' 2>/dev/null)"
      echo "Certificate serial: ${LOCAL_CERT_SN}, status: ${REMOTE_CERT_STATUS:-unknown}"
      
      # If status is valid, check expiration
      if [[ "valid" == "$REMOTE_CERT_STATUS" ]]; then
        # Check expiration (7 days)
        if openssl x509 -in "${CERT_SYMLINK}" -checkend 604800 -noout 2>/dev/null; then
          echo "Certificate is valid on blockchain and not expiring soon."
          GENERATE_NEW_CERT=false
        else
          echo "Certificate expires in less than 7 days, will regenerate"
        fi
      else
        echo "Certificate exists but is not valid on blockchain, will regenerate"
      fi
    else
      echo "Cannot extract serial number from certificate, will regenerate"
    fi
  else
    echo "Certificate is not in valid OpenSSL format, will regenerate"
  fi
fi

# Generate new certificate if needed
if $GENERATE_NEW_CERT; then
  echo "Generating new provider certificate"

  # Ensure certificate paths are ready
  rm -f "${CERT_WRITABLE_PATH}" 2>/dev/null || true
  touch "${CERT_WRITABLE_PATH}"
  chmod 600 "${CERT_WRITABLE_PATH}"
  rm -f "${CERT_SYMLINK}" 2>/dev/null || true

  # Generate the hostname
  PROVIDER_HOSTNAME="provider.{{ .Values.domain }}"

  # Check for existing certificates
  EXISTING_CERTS=$(provider-services query cert list --owner $PROVIDER_ADDRESS --state=valid -o json 2>/dev/null | jq -r '.certificates | length' 2>/dev/null || echo "0")
  if [[ "$EXISTING_CERTS" != "0" ]]; then
    echo "Certificate exists on blockchain, using --overwrite"
    OVERWRITE_FLAG="--overwrite"
  else
    OVERWRITE_FLAG=""
  fi

  # Generate certificate
  provider-services tx cert generate server $OVERWRITE_FLAG $PROVIDER_HOSTNAME

  # Check if generation succeeded
  if [[ ! -f "${CERT_SYMLINK}" || ! -s "${CERT_SYMLINK}" ]]; then
    echo "Certificate not found at expected location: ${CERT_SYMLINK}"
    
    # Try to locate the generated certificate
    GENERATED_CERT=$(find ${AKASH_HOME} -name "*.pem" -type f -print | head -1)
    
    if [[ -n "$GENERATED_CERT" ]]; then
      echo "Found certificate at: $GENERATED_CERT"
      cp -f "$GENERATED_CERT" "${CERT_SYMLINK}"
      chmod 600 "${CERT_SYMLINK}"
    else
      echo "No certificate found, generating fallback certificate"
      openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
        -subj "/CN=$PROVIDER_HOSTNAME" \
        -keyout "${CERT_WRITABLE_PATH}.key" \
        -out "${CERT_WRITABLE_PATH}" 2>/dev/null
      
      if [[ -f "${CERT_WRITABLE_PATH}" && -s "${CERT_WRITABLE_PATH}" ]]; then
        cat "${CERT_WRITABLE_PATH}.key" >> "${CERT_WRITABLE_PATH}"
        rm -f "${CERT_WRITABLE_PATH}.key"
        cp -f "${CERT_WRITABLE_PATH}" "${CERT_SYMLINK}"
        chmod 600 "${CERT_SYMLINK}"
      else
        echo "All certificate generation methods failed"
        exit 1
      fi
    fi
  fi

  # Publish the certificate
  echo "Publishing certificate to blockchain"
  provider-services tx cert publish server

  # Copy certificate to persistent storage
  cp -f "${CERT_SYMLINK}" "${CERT_PVC_PATH}"
  chmod 600 "${CERT_PVC_PATH}"
  echo "Certificate saved to persistent storage"

  # Create a backup in tmp
  cp -f "${CERT_SYMLINK}" "${CERT_WRITABLE_PATH}"
  chmod 600 "${CERT_WRITABLE_PATH}"
fi

# Verify file locations and permissions
echo "Certificate locations:"
ls -la "${CERT_SYMLINK}"
ls -la "${CERT_PVC_PATH}"
ls -la "${CERT_WRITABLE_PATH}"
