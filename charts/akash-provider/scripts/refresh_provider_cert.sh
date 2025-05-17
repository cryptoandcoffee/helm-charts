#!/bin/bash
# Filename: refresh_provider_cert.sh

set -x

# Figure the provider address in case the user passes `--from=<key_name>` instead of `--from=<akash1...>` address.
PROVIDER_ADDRESS="$(provider-services keys show $AKASH_FROM -a)"
if [[ -z "$PROVIDER_ADDRESS" ]]; then
  echo "PROVIDER_ADDRESS variable is empty. Something went wrong"
  exit 1
fi

# Setup paths for certificates
CERT_SYMLINK="${AKASH_HOME}/${PROVIDER_ADDRESS}.pem"
CERT_SECRET_PATH="/config/provider.pem"
CERT_WRITABLE_PATH="/tmp/provider.pem"

# Check if the certificate exists in the secret
if [[ -f "${CERT_SECRET_PATH}" ]]; then
  # Copy certificate from read-only secret to writable location
  cp -f "${CERT_SECRET_PATH}" "${CERT_WRITABLE_PATH}"
  
  # Create symlink to the writable certificate
  rm -vf "$CERT_SYMLINK"
  ln -sv "${CERT_WRITABLE_PATH}" "$CERT_SYMLINK"
  
  # Check certificate validity on blockchain
  LOCAL_CERT_SN="$(cat "${CERT_WRITABLE_PATH}" | openssl x509 -serial -noout | cut -d'=' -f2)"
  if [[ -n "$LOCAL_CERT_SN" ]]; then
    LOCAL_CERT_SN_DECIMAL=$(echo "obase=10; ibase=16; $LOCAL_CERT_SN" | bc)
    REMOTE_CERT_STATUS="$(AKASH_OUTPUT=json provider-services query cert list --owner $PROVIDER_ADDRESS --state valid --serial $LOCAL_CERT_SN_DECIMAL --reverse | jq -r '.certificates[0].certificate.state')"
    echo "Provider certificate serial number: ${LOCAL_CERT_SN}, status on chain: ${REMOTE_CERT_STATUS:-unknown}"
    
    # Check certificate expiration (7 days)
    openssl x509 -checkend 604800 -noout -in "${CERT_WRITABLE_PATH}" 2>/dev/null 1>&2
    EXPIRY_CHECK=$?
    
    if [[ "valid" == "$REMOTE_CERT_STATUS" && $EXPIRY_CHECK -eq 0 ]]; then
      echo "Certificate is valid on chain and not expiring soon. No need to regenerate."
      exit 0
    else
      if [[ "valid" != "$REMOTE_CERT_STATUS" ]]; then
        echo "Certificate exists but is not valid on chain. Will generate a new one."
      else
        echo "Certificate expires in less than 7 days. Will generate a new one."
      fi
    fi
  else
    echo "Certificate exists but appears to be malformed. Will generate a new one."
  fi
else
  echo "Certificate not found in secret. Will generate a new one."
fi

# Certificate needs to be generated
echo "Generating new provider certificate in writable path ${CERT_WRITABLE_PATH}"

# Ensure CERT_SYMLINK points to writable location
rm -vf "$CERT_SYMLINK"
touch "${CERT_WRITABLE_PATH}"
ln -sv "${CERT_WRITABLE_PATH}" "$CERT_SYMLINK"

# Generate new certificate
provider-services tx cert generate server provider.{{ .Values.domain }}

# Verify the new certificate was generated successfully
if [[ ! -f "${CERT_WRITABLE_PATH}" || ! -s "${CERT_WRITABLE_PATH}" ]]; then
  echo "ERROR: Certificate generation failed or certificate file is empty"
  exit 1
fi

# Publish the new certificate
echo "Publishing new provider certificate"
provider-services tx cert publish server

# Verify certificate was published successfully
CERT_SN="$(cat "${CERT_WRITABLE_PATH}" | openssl x509 -serial -noout | cut -d'=' -f2)"
if [[ -n "$CERT_SN" ]]; then
  CERT_SN_DECIMAL=$(echo "obase=10; ibase=16; $CERT_SN" | bc)
  PUBLISHED_STATUS="$(AKASH_OUTPUT=json provider-services query cert list --owner $PROVIDER_ADDRESS --state valid --serial $CERT_SN_DECIMAL --reverse | jq -r '.certificates[0].certificate.state')"
  
  if [[ "valid" == "$PUBLISHED_STATUS" ]]; then
    echo "Certificate successfully published and verified on chain."
  else
    echo "WARNING: Certificate may not have been published correctly. Status: ${PUBLISHED_STATUS:-unknown}"
  fi
else
  echo "WARNING: Unable to verify certificate publication. Certificate may be malformed."
fi

# The certificate is now in the writable path and symlinked correctly
# Note: The certificate won't be automatically persisted to the secret
# External process should capture this certificate for persistence
echo "Certificate regeneration complete. Location: ${CERT_WRITABLE_PATH}"
