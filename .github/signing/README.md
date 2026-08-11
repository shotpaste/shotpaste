# Release signing identity

`ShotPaste-Release-Self-Signed.crt` is the public half of the fixed macOS release
signing identity. It is safe to distribute and lets the workflow and maintainers
verify the expected certificate without exposing the private key.

- Common name: `ShotPaste Release Self-Signed`
- SHA-1 fingerprint: `8CBB386A17831C9C093C6BA693C4F60BC239A213`
- Valid through: 2056-08-03
- Private P12: GitHub Actions repository secret `SELF_SIGNED_CERT_P12`
- P12 password: GitHub Actions repository secret `SELF_SIGNED_CERT_PASSWORD`

Verify the tracked certificate from the repository root:

```bash
openssl x509 \
  -in .github/signing/ShotPaste-Release-Self-Signed.crt \
  -noout -subject -enddate -fingerprint -sha1
```

Never commit a P12, private key, password, or Base64-encoded private credential.
