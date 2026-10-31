#!/bin/zsh
# 生成自签的「代码签名」证书并导入登录钥匙串
# 用途：给 HappyVoice 一个稳定的签名身份，避免重编译后麦克风授权被重置
set -e

CN="HappyVoice Dev"
CERT_DIR="$HOME/Library/Application Support/HappyVoice/certs"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "已存在签名身份：$CN"
  security find-identity -v -p codesigning | grep "$CN"
  exit 0
fi

cat > openssl.cnf <<'EOF'
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext
default_md         = sha256

[ dn ]
CN = HappyVoice Dev
O  = HappyVoice Local Development
C  = CN

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

echo "== 生成私钥与自签证书 =="
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout key.pem -out cert.pem -days 3650 \
  -config openssl.cnf -extensions ext

echo "== 打包成 p12 =="
openssl pkcs12 -export -inkey key.pem -in cert.pem \
  -name "$CN" -out identity.p12 -passout pass:happyvoice

echo "== 导入登录钥匙串 =="
security import identity.p12 -k "$KEYCHAIN" -P happyvoice \
  -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

echo "== 信任该证书用于代码签名（用户域，无需管理员）=="
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem || \
  echo "  跳过信任设置（codesign 通常无需信任即可签名）"

rm -f identity.p12

echo "== 结果 =="
security find-identity -v -p codesigning | grep "$CN" || {
  echo "!!! 未能列出签名身份，请检查钥匙串"
  exit 1
}
echo "证书文件保留在：$CERT_DIR"
