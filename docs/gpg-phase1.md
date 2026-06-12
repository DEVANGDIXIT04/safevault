# Phase 1 GPG setup

SafeVault encrypts backup artifacts with a public key. Restores require the matching private key.

For the local demo, create a test-only key:

```bash
export GNUPGHOME="$PWD/.gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

gpg --batch --passphrase '' --quick-generate-key \
  safevault@example.local default default never

gpg --list-keys safevault@example.local
```

Do not commit `.gnupg/`, exported private keys, or `safevault.conf`.

