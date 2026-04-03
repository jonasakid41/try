#!/bin/bash

# Renkler
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Algoritmalar arasından rastgele seç (sha1, sha256, sha384)
ALGS=("sha1" "sha256" "sha384")
SEL_ALG=${ALGS[$RANDOM % ${#ALGS[@]}]}

# Handle adresini rastgele yap (0x81010001 ile 0x810100FF arası)
RAND_HEX=$(printf "%02x" $(( (RANDOM % 254) + 1 )))
HANDLE="0x810100$RAND_HEX"

# Anahtar şifresini (hierarchy auth) rastgele 8 haneli yap
RAND_PASS=$(openssl rand -hex 4)

echo -e "${YELLOW}[i] Seçilen Algoritma : $SEL_ALG${NC}"
echo -e "${YELLOW}[i] Yeni TPM Handle    : $HANDLE${NC}"
echo -e "${YELLOW}[i] Rastgele Tohum    : $RAND_PASS${NC}"

# 2. TPM TEMİZLEME
echo -e "${GREEN}[+] 1/4: TPM Temizleniyor...${NC}"
tpm2_clear

# 3. ANAHTAR OLUŞTURMA (Rastgele Algoritma ve Şifre ile)
echo -e "${GREEN}[+] 2/4: Rastgele birincil anahtar oluşturuluyor...${NC}"
# Not: -p ile rastgele şifre ekleyerek anahtarın "unique" (benzersiz) olmasını sağlıyoruz
if tpm2_createprimary -p "$RAND_PASS" -C e -g "$SEL_ALG" -G rsa -c primary.ctx; then
    echo -e "${GREEN}[✓] Anahtar başarıyla oluşturuldu.${NC}"
else
    echo -e "${RED}[✗] HATA: Anahtar oluşturulamadı.${NC}"
    exit 1
fi

# 4. ESKİ HANDLE'LARI TEMİZLE (Çakışma Olmaması İçin)
echo -e "${GREEN}[+] 3/4: Eski kalıcı adresler boşaltılıyor...${NC}"
CURRENT_HANDLES=$(tpm2_getcap handles-persistent | grep -o '0x81[0-9a-fA-F]*')
for h in $CURRENT_HANDLES; do
    tpm2_evictcontrol -C o -c $h 2>/dev/null
done

# 5. FİNAL: YENİ RASTGELE HANDLE'A KAYDET
echo -e "${GREEN}[+] 4/4: Yeni kimlik kalıcı belleğe işleniyor...${NC}"
if tpm2_evictcontrol -C o -c primary.ctx "$HANDLE"; then
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${GREEN}   [✓] İŞLEM BAŞARIYLA TAMAMLANDI!${NC}"
    echo -e "${GREEN}   YENİ HANDLE: $HANDLE${NC}"
    echo -e "${BLUE}==========================================${NC}"
else
    echo -e "${RED}[✗] HATA: Kalıcı hale getirme başarısız.${NC}"
fi

# Temizlik
rm -f primary.ctx endorsement_pub.pem 2>/dev/null
