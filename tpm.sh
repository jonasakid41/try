#!/bin/bash

# Renkler
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN}    TPM RASTGELELEŞTİRİCİ & DOĞRULAYICI${NC}"
echo -e "${BLUE}==========================================${NC}"

# 0. MEVCUT DURUMU KAYDET (KARŞILAŞTIRMA İÇİN)
echo -e "${YELLOW}[i] İşlem öncesi mevcut TPM durumu:${NC}"
PRE_HANDLE=$(tpm2_getcap handles-persistent | grep -o '0x81[0-9a-fA-F]*' | xargs)
if [ -z "$PRE_HANDLE" ]; then
    echo -e "    Mevcut Handle: (Boş/Temiz)"
else
    echo -e "    Mevcut Handle: $PRE_HANDLE"
fi
echo -e "------------------------------------------"

# 1. RASTGELE DEĞERLERİ HAZIRLA
ALGS=("sha256" "sha384") # sha1 bazı modern sistemlerde kısıtlı olabilir, sha256/384 en sağlıklısı
SEL_ALG=${ALGS[$RANDOM % ${#ALGS[@]}]}
RAND_HEX=$(printf "%02x" $(( (RANDOM % 254) + 1 )))
HANDLE="0x810100$RAND_HEX"
RAND_PASS=$(openssl rand -hex 6)

# 2. TPM TEMİZLEME
echo -e "${GREEN}[+] 1/4: TPM Temizleniyor...${NC}"
tpm2_clear > /dev/null 2>&1

# 3. ANAHTAR OLUŞTURMA
echo -e "${GREEN}[+] 2/4: Yeni benzersiz anahtar oluşturuluyor...${NC}"
if tpm2_createprimary -p "$RAND_PASS" -C e -g "$SEL_ALG" -G rsa -c primary.ctx > /dev/null 2>&1; then
    echo -e "${GREEN}[✓] Anahtar başarıyla oluşturuldu.${NC}"
else
    echo -e "${RED}[✗] HATA: Anahtar oluşturulamadı.${NC}"
    exit 1
fi

# 4. ESKİ HANDLE'LARI TEMİZLE
echo -e "${GREEN}[+] 3/4: Eski kalıcı adresler temizleniyor...${NC}"
CURRENT_HANDLES=$(tpm2_getcap handles-persistent | grep -o '0x81[0-9a-fA-F]*')
for h in $CURRENT_HANDLES; do
    tpm2_evictcontrol -C o -c $h > /dev/null 2>&1
done

# 5. FİNAL: YENİ HANDLE'A KAYDET
echo -e "${GREEN}[+] 4/4: Yeni kimlik belleğe işleniyor ($HANDLE)...${NC}"
if tpm2_evictcontrol -C o -c primary.ctx "$HANDLE" > /dev/null 2>&1; then
    
    # 6. DOĞRULAMA VE SONUÇ EKRANI
    echo -e "\n${BLUE}==========================================${NC}"
    echo -e "${GREEN}        İŞLEM BAŞARIYLA TAMAMLANDI!${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    echo -e "${YELLOW}ESKİ ADRES  :${NC} ${PRE_HANDLE:-Yok}"
    echo -e "${GREEN}YENİ ADRES  :${NC} $HANDLE"
    echo -e "${YELLOW}ALGORİTMA   :${NC} $SEL_ALG"
    
    echo -e "\n${BLUE}[i] Yeni Oluşturulan Kalıcı Handle Detayı:${NC}"
    tpm2_getcap handles-persistent
    
    echo -e "\n${BLUE}[i] Örnek PCR Değişimi (PCR 8):${NC}"
    # PCR 8'i de rastgeleleştirip gösterelim ki değişiklik tam kanıtlansın
    tpm2_pcrextend 8:sha256=$(openssl rand -hex 32) > /dev/null 2>&1
    tpm2_pcrread sha256:8 | grep -v "Selected"
    
    echo -e "${BLUE}==========================================${NC}"
else
    echo -e "${RED}[✗] HATA: Kalıcı hale getirme başarısız.${NC}"
fi

# Temizlik
rm -f primary.ctx 2>/dev/null
