#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log dosyası
LOG_FILE="/var/log/tpm_randomizer.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/tmp/tpm_backup_$TIMESTAMP"

# Başlangıç mesajı
echo -e "${BLUE}====================================${NC}"
echo -e "${GREEN}  RASTGELE TPM OLUŞTURMA SCRIPTI${NC}"
echo -e "${BLUE}====================================${NC}"
echo -e "${YELLOW}[+] Başlangıç zamanı: $(date)${NC}"

# Root kontrolü
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[HATA] Bu script root olarak çalıştırılmalıdır!${NC}"
  exit 1
fi

# Gerekli paketlerin kurulu olup olmadığını kontrol et
for pkg in tpm2_clear openssl; do
    if ! command -v $pkg &> /dev/null; then
        echo -e "${YELLOW}[!] $pkg bulunamadı, kuruluyor...${NC}"
        apt update && apt install -y tpm2-tools openssl
        break
    fi
done

# LUKS uyarısı
echo -e "${RED}[UYARI] Sisteminizde LUKS şifreli disk varsa TPM temizleme kilidi bozabilir!${NC}"
echo -e "${YELLOW}Devam etmek istiyor musunuz? (e/H): ${NC}"
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[eE]$ ]]; then
    echo -e "${YELLOW}[!] İptal edildi.${NC}"
    exit 0
fi

# Log dosyası oluştur
touch $LOG_FILE
echo "$(date): Script başlatıldı" >> $LOG_FILE

# Mevcut TPM durumunu yedekle
echo -e "${GREEN}[+] Mevcut TPM durumu yedekleniyor...${NC}"
mkdir -p $BACKUP_DIR
if [ -f /sys/class/tpm/tpm0/device/caps ]; then
    cp /sys/class/tpm/tpm0/device/caps $BACKUP_DIR/ 2>/dev/null
fi

# -------------------------------------------------------------------
# Rastgele parametreler oluştur
# FIX #1: keyedhash kaldırıldı — birincil anahtar için geçersiz tür
# -------------------------------------------------------------------
ALGORITMLAR=("sha256" "sha384" "sha512" "sha1")
TURLER=("rsa" "ecc")

# Rastgele seçimler yap
ALGORITMA=${ALGORITMLAR[$RANDOM % ${#ALGORITMLAR[@]}]}
TUR=${TURLER[$RANDOM % ${#TURLER[@]}]}

# FIX #2: Handle 0x81010001–0x810100FE aralığında doğru üretildi
HANDLE=$(printf "0x81010%02x" $(( (RANDOM % 254) + 1 )))

echo -e "${GREEN}[+] Rastgele TPM parametreleri oluşturuldu:${NC}"
echo -e "${YELLOW}    Algoritma : $ALGORITMA${NC}"
echo -e "${YELLOW}    Tür       : $TUR${NC}"
echo -e "${YELLOW}    Handle    : $HANDLE${NC}"

echo "$(date): Yeni TPM profili - Algoritma: $ALGORITMA, Tür: $TUR, Handle: $HANDLE" >> $LOG_FILE

# -------------------------------------------------------------------
# Komut 1: TPM'i temizle
# -------------------------------------------------------------------
echo -e "${GREEN}[+] 1/5: TPM temizleniyor...${NC}"
if tpm2_clear; then
    echo -e "${GREEN}[✓] TPM başarıyla temizlendi${NC}"
else
    echo -e "${RED}[✗] TPM temizlenemedi${NC}"
    exit 1
fi

# -------------------------------------------------------------------
# Komut 2: Rastgele parametrelerle birincil anahtar oluştur
# FIX #3: Artık gerçekten rastgele algoritma ve tür kullanılıyor
# -------------------------------------------------------------------
echo -e "${GREEN}[+] 2/5: Birincil anahtar oluşturuluyor ($TUR / $ALGORITMA)...${NC}"
if tpm2_createprimary -C e -g $ALGORITMA -G $TUR -c primary.ctx; then
    echo -e "${GREEN}[✓] Birincil anahtar başarıyla oluşturuldu${NC}"
else
    echo -e "${RED}[✗] Birincil anahtar oluşturulamadı${NC}"
    exit 1
fi

# -------------------------------------------------------------------
# Komut 3: Ortak anahtarı oku ve kaydet
# -------------------------------------------------------------------
echo -e "${GREEN}[+] 3/5: Ortak anahtar okunuyor...${NC}"
if tpm2_readpublic -c primary.ctx -f pem -o $BACKUP_DIR/endorsement_pub.pem; then
    echo -e "${GREEN}[✓] Ortak anahtar $BACKUP_DIR/endorsement_pub.pem dosyasına kaydedildi${NC}"
else
    echo -e "${RED}[✗] Ortak anahtar okunamadı${NC}"
    exit 1
fi

# -------------------------------------------------------------------
# Komut 4: İkinci birincil anahtar oluştur — ayrı ctx dosyasına
# FIX #3 (devam): primary.ctx ezilmiyor, secondary.ctx kullanılıyor
# -------------------------------------------------------------------
echo -e "${GREEN}[+] 4/5: İkinci birincil anahtar oluşturuluyor (sha1 / rsa)...${NC}"
if tpm2_createprimary -C e -g sha1 -G rsa -c secondary.ctx; then
    echo -e "${GREEN}[✓] İkinci birincil anahtar başarıyla oluşturuldu${NC}"
else
    echo -e "${RED}[✗] İkinci birincil anahtar oluşturulamadı${NC}"
    exit 1
fi

# -------------------------------------------------------------------
# Komut 5: Rastgele parametreli anahtarı (primary.ctx) kalıcı yap
# FIX #3 (devam): evictcontrol artık doğru (rastgele) ctx'i kullanıyor
# -------------------------------------------------------------------
echo -e "${GREEN}[+] 5/5: Anahtar kalıcı hale getiriliyor...${NC}"
if tpm2_evictcontrol -C o -c primary.ctx $HANDLE; then
    echo -e "${GREEN}[✓] Anahtar kalıcı hale getirildi (Handle: $HANDLE)${NC}"
else
    echo -e "${RED}[✗] Anahtar kalıcı hale getirilemedi${NC}"
    exit 1
fi

# -------------------------------------------------------------------
# PCR değerleri rastgeleleştir
# FIX #4: PCR 0–7 sistem ölçümleri için ayrılmıştır, atlandı.
#          Secure Boot / LUKS bağlantısı korunuyor.
#          Sadece 8–23 arası kullanıcı PCR'ları rastgeleleştiriliyor.
# -------------------------------------------------------------------
echo -e "${GREEN}[+] Kullanıcı PCR değerleri rastgeleleştiriliyor (8-23)...${NC}"
FAILED_PCRS=()
for i in {8..23}; do
    RANDOM_VALUE=$(openssl rand -hex 32)
    if ! tpm2_pcrextend $i:sha256=$RANDOM_VALUE 2>/dev/null; then
        FAILED_PCRS+=($i)
    fi
done

if [ ${#FAILED_PCRS[@]} -eq 0 ]; then
    echo -e "${GREEN}[✓] PCR 8-23 değerleri başarıyla rastgeleleştirildi${NC}"
else
    echo -e "${YELLOW}[!] Şu PCR'lar atlandı: ${FAILED_PCRS[*]}${NC}"
fi

# TPM durumunu doğrula
echo -e "${GREEN}[+] TPM durumu doğrulanıyor...${NC}"
tpm2_getcap properties-fixed

# Temizlik
rm -f primary.ctx secondary.ctx

# Başarı mesajı
echo -e "${BLUE}====================================${NC}"
echo -e "${GREEN}[✓] TPM rastgeleleştirme tamamlandı!${NC}"
echo -e "${GREEN}    Yeni TPM Handle   : $HANDLE${NC}"
echo -e "${GREEN}    Yedekleme konumu  : $BACKUP_DIR${NC}"
echo -e "${GREEN}    Log dosyası       : $LOG_FILE${NC}"
echo -e "${BLUE}====================================${NC}"

echo "$(date): Script başarıyla tamamlandı. Handle: $HANDLE" >> $LOG_FILE

exit 0
