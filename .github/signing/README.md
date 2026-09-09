# 发布签名身份

`ShotPaste-Release-Self-Signed.crt` 是固定 macOS 发布签名身份的公开证书。
可安全分发，供工作流与维护者在不暴露私钥的情况下核对预期证书。

- 通用名称：`ShotPaste Release Self-Signed`
- SHA-1 指纹：`8CBB386A17831C9C093C6BA693C4F60BC239A213`
- 有效期至：2056-08-03
- 私有 P12：GitHub Actions 仓库 Secret `SELF_SIGNED_CERT_P12`
- P12 密码：GitHub Actions 仓库 Secret `SELF_SIGNED_CERT_PASSWORD`

在仓库根目录验证已跟踪证书：

```bash
openssl x509 \
  -in .github/signing/ShotPaste-Release-Self-Signed.crt \
  -noout -subject -enddate -fingerprint -sha1
```

禁止提交 P12、私钥、密码或 Base64 编码的私有凭据。
