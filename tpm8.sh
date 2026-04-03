#!/bin/bash

# Renkler
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. ARAÇ KONTROLÜ (Hata Giderilmiş Versiyon)
echo -e "${YELLOW}[*] Bağımlılıklar kontrol ediliyor...${NC}"
# tpm2-tools paketindeki ana komut olan tpm2_pcrread'i kontrol eder
if ! command -v tpm2_pcrread &> /dev/null; then
    echo -e "${RED}[!] tpm2-tools bulunamadı. Kuruluyor...${NC}"
    # CD-ROM kaynaklı hataları görmezden gelmek ve sadece internet depolarını kullanmak için
    sudo apt-get update -qq
    sudo apt-get install -y -qq tpm2-tools openssl
else
    echo -e "${GREEN}[✓] Gerekli araçlar (tpm2-tools, openssl) hazır.${NC}"
fi

# 2. MEVCUT DURUMU KAYDET
PRE_HANDLES=$(tpm2_getcap handles-persistent | grep -o '0x81[0-9a-fA-F]*' | xargs | sed 's/ /, /g')
[ -z "$PRE_HANDLES" ] && PRE_HANDLES="Boş/Temiz"

# 3. RASTGELE DEĞERLERİ HAZIRLA
ALGS=("sha1" "sha256" "sha384")
SEL_ALG=${ALGS[$RANDOM % ${#ALGS[@]}]}
RAND_HEX=$(printf "%02x" $(( (RANDOM % 254) + 1 )))
HANDLE="0x810100$RAND_HEX"
RAND_PASS=$(openssl rand -hex 4)

# 4. TPM TEMİZLEME
echo -e "${GREEN}[+] 1/4: TPM Temizleniyor...${NC}"
tpm2_clear > /dev/null 2>&1

# 5. ANAHTAR OLUŞTURMA
echo -e "${GREEN}[+] 2/4: Rastgele birincil anahtar oluşturuluyor...${NC}"
if tpm2_createprimary -p "$RAND_PASS" -C e -g "$SEL_ALG" -G rsa -c primary.ctx > /dev/null 2>&1; then
    echo -e "${GREEN}[✓] Anahtar başarıyla oluşturuldu.${NC}"
else
    echo -e "${RED}[✗] HATA: Anahtar oluşturulamadı.${NC}"
    exit 1
fi

# 6. ESKİ HANDLE'LARI TEMİZLE
echo -e "${GREEN}[+] 3/4: Eski kalıcı adresler boşaltılıyor...${NC}"
CURRENT_HANDLES=$(tpm2_getcap handles-persistent | grep -o '0x81[0-9a-fA-F]*')
for h in $CURRENT_HANDLES; do
    tpm2_evictcontrol -C o -c $h > /dev/null 2>&1
done

# 7. FİNAL: YENİ RASTGELE HANDLE'A KAYDET
echo -e "${GREEN}[+] 4/4: Yeni kimlik kalıcı belleğe işleniyor...${NC}"
if tpm2_evictcontrol -C o -c primary.ctx "$HANDLE" > /dev/null 2>&1; then
    
    # Yeni durumu al
    NEW_HANDLES=$(tpm2_getcap handles-persistent | grep -o '0x81[0-9a-fA-F]*' | xargs | sed 's/ /, /g')
    
    echo -e "\n${BLUE}==========================================${NC}"
    echo -e "${GREEN}        İŞLEM BAŞARIYLA TAMAMLANDI!${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    printf "${YELLOW}%-20s :${NC} %s\n" "ESKİ DURUM" "$PRE_HANDLES"
    printf "${GREEN}%-20s :${NC} %s\n" "YENİ DURUM" "$NEW_HANDLES"
    printf "${YELLOW}%-20s :${NC} %s\n" "ALGORİTMA" "$SEL_ALG"
    printf "${YELLOW}%-20s :${NC} %s\n" "TOHUM (PASS)" "$RAND_PASS"
    
    echo -e "${BLUE}==========================================${NC}"
else
    echo -e "${RED}[✗] HATA: Kalıcı hale getirme başarısız.${NC}"
fi

# Temizlik
rm -f primary.ctx 2>/dev/null
