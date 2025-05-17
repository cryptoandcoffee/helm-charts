#!/bin/bash
# Filename: refresh_provider_cert.sh

set -x

# Get provider address
PROVIDER_ADDRESS="$(provider-services keys show $AKASH_FROM -a)"
if [[ -z "$PROVIDER_ADDRESS" ]]; then
  echo "ERROR: Cannot determine provider address"
  exit 1
fi

# Define paths
CERT_PATH="${AKASH_HOME}/${PROVIDER_ADDRESS}.pem"
PVC_CERT_PATH="/config/provider.pem"

mkdir -p "${AKASH_HOME}"

# Default to needing certificate regeneration
GENERATE_NEW_CERT=true

# Check for existing certificates in order of preference
if [[ -f "${CERT_PATH}" && -s "${CERT_PATH}" ]]; then
  # Certificate exists in AKASH_HOME
  echo "Certificate found in AKASH_HOME"
  
  # Validate the certificate format
  if openssl x509 -in "${CERT_PATH}" -noout 2>/dev/null; then
    # Check certificate validity on blockchain
    LOCAL_CERT_SN="$(openssl x509 -in "${CERT_PATH}" -serial -noout 2>/dev/null | cut -d'=' -f2)"
    if [[ -n "$LOCAL_CERT_SN" ]]; then
      LOCAL_CERT_SN_DECIMAL=$(echo "obase=10; ibase=16; $LOCAL_CERT_SN" | bc)
      REMOTE_CERT_STATUS="$(AKASH_OUTPUT=json provider-services query cert list --owner $PROVIDER_ADDRESS --state valid --serial $LOCAL_CERT_SN_DECIMAL --reverse 2>/dev/null | jq -r '.certificates[0].certificate.state' 2>/dev/null)"
      echo "Certificate serial: ${LOCAL_CERT_SN}, status: ${REMOTE_CERT_STATUS:-unknown}"
      
      # If status is valid, check expiration
      if [[ "valid" == "$REMOTE_CERT_STATUS" ]]; then
        # Check expiration (7 days)
        if openssl x509 -in "${CERT_PATH}" -checkend 604800 -noout 2>/dev/null; then
          echo "Certificate in AKASH_HOME is valid on blockchain and not expiring soon"
          GENERATE_NEW_CERT=false
          
          # Save to PVC for persistence
          cp -f "${CERT_PATH}" "${PVC_CERT_PATH}"
          chmod 600 "${PVC_CERT_PATH}"
        else
          echo "Certificate in AKASH_HOME expires in less than 7 days"
        fi
      else
        echo "Certificate in AKASH_HOME is not valid on blockchain"
      fi
    else
      echo "Cannot extract serial number from certificate in AKASH_HOME"
    fi
  else
    echo "Certificate in AKASH_HOME is not in valid OpenSSL format"
  fi
fi

# If AKASH_HOME certificate is not valid, check PVC
if $GENERATE_NEW_CERT && [[ -f "${PVC_CERT_PATH}" && -s "${PVC_CERT_PATH}" ]]; then
  echo "Checking certificate in persistent storage"
  
  # Copy certificate from PVC
  cp -f "${PVC_CERT_PATH}" "${CERT_PATH}"
  chmod 600 "${CERT_PATH}"
  
  # Validate certificate format
  if openssl x509 -in "${CERT_PATH}" -noout 2>/dev/null; then
    # Check certificate validity on blockchain
    LOCAL_CERT_SN="$(openssl x509 -in "${CERT_PATH}" -serial -noout 2>/dev/null | cut -d'=' -f2)"
    if [[ -n "$LOCAL_CERT_SN" ]]; then
      LOCAL_CERT_SN_DECIMAL=$(echo "obase=10; ibase=16; $LOCAL_CERT_SN" | bc)
      REMOTE_CERT_STATUS="$(AKASH_OUTPUT=json provider-services query cert list --owner $PROVIDER_ADDRESS --state valid --serial $LOCAL_CERT_SN_DECIMAL --reverse 2>/dev/null | jq -r '.certificates[0].certificate.state' 2>/dev/null)"
      echo "Certificate serial: ${LOCAL_CERT_SN}, status: ${REMOTE_CERT_STATUS:-unknown}"
      
      # If status is valid, check expiration
      if [[ "valid" == "$REMOTE_CERT_STATUS" ]]; then
        # Check expiration (7 days)
        if openssl x509 -in "${CERT_PATH}" -checkend 604800 -noout 2>/dev/null; then
          echo "Certificate from persistent storage is valid on blockchain and not expiring soon"
          GENERATE_NEW_CERT=false
        else
          echo "Certificate from persistent storage expires in less than 7 days"
        fi
      else
        echo "Certificate from persistent storage is not valid on blockchain"
      fi
    else
      echo "Cannot extract serial number from certificate in persistent storage"
    fi
  else
    echo "Certificate from persistent storage is not in valid OpenSSL format"
  fi
fi

# Generate new certificate if needed
if $GENERATE_NEW_CERT; then
  echo "Generating new provider certificate"

  # Check for existing certificates on blockchain
  EXISTING_CERTS=$(provider-services query cert list --owner $PROVIDER_ADDRESS --state=valid -o json 2>/dev/null | jq -r '.certificates | length' 2>/dev/null || echo "0")
  if [[ "$EXISTING_CERTS" != "0" ]]; then
    echo "Certificate exists on blockchain, using --overwrite flag"
    OVERWRITE_FLAG="--overwrite"
  else
    OVERWRITE_FLAG=""
  fi

  # Generate certificate
  provider-services tx cert generate server $OVERWRITE_FLAG provider.{{ .Values.domain }}

  # Verify certificate was generated
  if [[ ! -f "${CERT_PATH}" || ! -s "${CERT_PATH}" ]]; then
    echo "ERROR: Certificate generation failed"
    exit 1
  fi

  # Validate the generated certificate format
  if ! openssl x509 -in "${CERT_PATH}" -noout 2>/dev/null; then
    echo "ERROR: Generated certificate is not in valid OpenSSL format"
    exit 1
  fi

  # Publish certificate
  echo "Publishing certificate to blockchain"
  provider-services tx cert publish server

  # Save to PVC for persistence
  cp -f "${CERT_PATH}" "${PVC_CERT_PATH}"
  chmod 600 "${PVC_CERT_PATH}"
  echo "Certificate successfully generated and saved to persistent storage"
fi

# Final verification
if [[ ! -f "${CERT_PATH}" || ! -s "${CERT_PATH}" ]]; then
  echo "ERROR: Certificate not available at ${CERT_PATH}"
  exit 1
fi

echo "Certificate process completed successfully"
