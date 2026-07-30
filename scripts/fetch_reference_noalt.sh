#!/usr/bin/env bash
# =============================================================================
# Scarica e prepara il riferimento GRCh38 senza contig ALT (iterazione 2).
#
# Perche': il riferimento della prima iterazione (Homo_sapiens_assembly38)
# contiene 261 contig _alt ma non il file .alt che dice a BWA che un contig ALT
# e il suo locus primario sono lo stesso pezzo di genoma. Le read che mappano
# su entrambi ricevono MAPQ 0, HaplotypeCaller le scarta sotto MAPQ 20, e le
# varianti sottostanti non vengono mai chiamate: nell'MHC di chr6 si perde il
# 98,51 % degli SNP veri.
#
# La variante scelta e' no_alt_plus_hs38d1: rispetto ad oggi cambia una sola
# cosa, cioe' toglie i contig ALT (e gli HLA che dipendono da loro) e tiene i
# decoy, che servono ad assorbire le read spazzatura.
#
# Gli indici BWA sono pubblicati da NCBI e non vengono ricostruiti: bwa index
# su 3 Gb costerebbe circa un'ora di CPU per un risultato identico.
#
# Download, decompressione e indici girano DENTRO il container: la cartella
# ref/ appartiene a root e l'utente di WSL non puo' scriverci. Il container
# gira come root, quindi non serve sudo. L'host si limita a orchestrare e a
# fare i confronti in lettura, che e' il modello usato da tutta la pipeline.
#
#   Uso:  bash scripts/fetch_reference_noalt.sh
# =============================================================================

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REF_DIR="${PROJECT_DIR}/ref"

REF_NAME="GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna"
BASE_URL="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids"

REF="${REF_DIR}/${REF_NAME}"
DICT="${REF_DIR}/${REF_NAME%.*}.dict"
OLD_FAI="${REF_DIR}/Homo_sapiens_assembly38.fasta.fai"
TOOLS_IMAGE="${TOOLS_IMAGE:-bioinfo-codeserver:latest}"

msg()    { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
errore() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }


# --- 1. Prerequisiti ---------------------------------------------------------
msg "1/4 - Prerequisiti"
command -v docker >/dev/null || errore "Docker non disponibile."
docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1 ||
    errore "immagine ${TOOLS_IMAGE} assente: serve per curl, samtools e il .dict."
[[ -d "$REF_DIR" ]] || errore "cartella non trovata: $REF_DIR"
[[ -s "$OLD_FAI" ]] || errore "manca il .fai del riferimento attuale: $OLD_FAI"

libero_kb="$(df -Pk "$REF_DIR" | awk 'END {print $4}')"
(( libero_kb >= 20 * 1024 * 1024 )) ||
    errore "servono almeno 20 GiB liberi in ${REF_DIR}."
printf 'Spazio libero: %.1f GiB\n' "$(awk -v k="$libero_kb" 'BEGIN{print k/1024/1024}')"


# --- 2. Scarico e preparo, dentro il container -------------------------------
msg "2/4 - Download, verifica MD5, indici BWA, .fai e .dict"
docker run --rm -i \
    --name hg002_fetch_reference \
    --entrypoint /bin/bash \
    --mount "type=bind,source=${REF_DIR},target=/ref" \
    "$TOOLS_IMAGE" -s -- "$REF_NAME" "$BASE_URL" <<'PAYLOAD'
set -Eeuo pipefail

REF_NAME="$1"
BASE_URL="$2"
REF="/ref/${REF_NAME}"
DICT="/ref/${REF_NAME%.*}.dict"

passo()  { printf '\n  [%s]\n' "$*"; }
errore() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# --no-progress-meter tiene il log leggibile; l'avanzamento si segue guardando
# crescere i file in ref/.
#
# Il ciclo esterno esiste perche' l'FTP di NCBI chiude la connessione a
# tradimento su archivi da 3 GB: curl restituisce 18 (transfer closed) e
# --retry non lo considera ritentabile. Ogni giro riprende con -C - dal punto
# raggiunto, quindi un'interruzione a fine download costa pochi MB e non 3 GB.
scarica() {
    local url="$1" dest="$2" tentativo=0
    if [[ -s "$dest" ]]; then
        printf '  gia presente: %-58s %s\n' "$(basename "$dest")" "$(du -h "$dest" | cut -f1)"
        return
    fi
    printf '  scarico:      %s\n' "$(basename "$dest")"
    until curl -L --fail --retry 5 --retry-delay 5 --retry-all-errors \
               --no-progress-meter -C - -o "${dest}.part" "$url"; do
        tentativo=$((tentativo + 1))
        (( tentativo < 8 )) ||
            errore "download fallito dopo ${tentativo} tentativi: $url"
        printf '  interrotto, riprendo (tentativo %s, %s scaricati)\n' \
            "$tentativo" "$(du -h "${dest}.part" 2>/dev/null | cut -f1 || echo 0)"
        sleep 10
    done
    mv -f "${dest}.part" "$dest"
    printf '  scaricato:    %-58s %s\n' "$(basename "$dest")" "$(du -h "$dest" | cut -f1)"
}

passo "download"
scarica "${BASE_URL}/${REF_NAME}.gz"               "${REF}.gz"
scarica "${BASE_URL}/${REF_NAME}.fai"              "${REF}.fai.ncbi"
scarica "${BASE_URL}/${REF_NAME}.bwa_index.tar.gz" "${REF}.bwa_index.tar.gz"

passo "verifica MD5 dichiarati da NCBI"
if curl -L --fail --silent --max-time 120 \
        -o /ref/md5checksums.ncbi.txt "${BASE_URL}/md5checksums.txt"; then
    cd /ref
    for f in "${REF_NAME}.gz" "${REF_NAME}.bwa_index.tar.gz"; do
        atteso="$(awk -v n="$f" 'index($2, n) {print $1}' md5checksums.ncbi.txt | head -1)"
        if [[ -z "$atteso" ]]; then
            printf '  %-58s md5 non dichiarato\n' "$f"
            continue
        fi
        ottenuto="$(md5sum "$f" | cut -d' ' -f1)"
        [[ "$atteso" == "$ottenuto" ]] ||
            errore "md5 diverso per ${f}: atteso ${atteso}, ottenuto ${ottenuto}"
        printf '  %-58s md5 OK\n' "$f"
    done
else
    echo "  md5checksums.txt non disponibile: verifica MD5 saltata."
    rm -f /ref/md5checksums.ncbi.txt
fi

passo "decompressione del FASTA"
if [[ -s "$REF" ]]; then
    echo "  FASTA gia decompresso."
else
    gzip -t "${REF}.gz" || errore "archivio FASTA corrotto: riscaricalo."
    gunzip -c "${REF}.gz" > "${REF}.part"
    mv -f "${REF}.part" "$REF"
fi
printf '  FASTA: %s\n' "$(du -h "$REF" | cut -f1)"

# NCBI pubblica gli indici BWA gia costruiti. Alcune versioni li nominano con
# l'infisso ".64"; BWA e Parabricks li cercano senza infisso, quindi vengono
# rinominati (rename, non copia: non serve spazio in piu').
passo "indici BWA"
if [[ -s "${REF}.bwt" && -s "${REF}.sa" && -s "${REF}.pac" &&
      -s "${REF}.amb" && -s "${REF}.ann" ]]; then
    echo "  indici BWA gia presenti."
else
    tar -tzf "${REF}.bwa_index.tar.gz" >/dev/null ||
        errore "archivio degli indici BWA corrotto: riscaricalo."
    tar -xzf "${REF}.bwa_index.tar.gz" -C /ref
    if [[ ! -s "${REF}.bwt" && ! -s "${REF}.64.bwt" ]]; then
        annidato="$(find /ref -mindepth 2 -name '*.bwt' -print -quit)"
        [[ -n "$annidato" ]] || errore "indici BWA non trovati dopo l'estrazione."
        mv -f "$(dirname "$annidato")"/* /ref/
        rmdir "$(dirname "$annidato")" 2>/dev/null || true
    fi
    for est in amb ann bwt pac sa; do
        if [[ ! -s "${REF}.${est}" && -s "${REF}.64.${est}" ]]; then
            mv -f "${REF}.64.${est}" "${REF}.${est}"
            printf '  rinominato .64.%s -> .%s\n' "$est" "$est"
        fi
        [[ -s "${REF}.${est}" ]] || errore "indice BWA mancante: ${REF}.${est}"
    done
fi
for est in amb ann bwt pac sa; do
    printf '  %-6s %s\n' ".${est}" "$(du -h "${REF}.${est}" | cut -f1)"
done

# Il .fai viene rigenerato e confrontato con quello pubblicato da NCBI: se
# coincidono, il FASTA scaricato e' integro riga per riga.
passo ".fai e .dict"
[[ -s "${REF}.fai" ]] || samtools faidx "$REF"
if cmp -s "${REF}.fai" "${REF}.fai.ncbi"; then
    echo "  .fai rigenerato identico a quello pubblicato da NCBI."
else
    errore ".fai rigenerato diverso da quello NCBI: il FASTA non e' integro."
fi
[[ -s "$DICT" ]] || samtools dict -o "$DICT" "$REF"
[[ -s "$DICT" ]] || errore "dizionario .dict non creato."
printf '  .dict: %s sequenze\n' "$(grep -c '^@SQ' "$DICT")"
PAYLOAD


# --- 3. Che cosa e' cambiato -------------------------------------------------
# E' il controllo che conta: dice quali contig spariscono e conferma che i
# cromosomi primari NON cambiano, cioe' che dbSNP, snpEff e il BED di GIAB
# restano compatibili senza toccarli.
msg "3/4 - Confronto con il riferimento della prima iterazione"
vecchi="$(mktemp)"; nuovi="$(mktemp)"; rimossi="$(mktemp)"; aggiunti="$(mktemp)"
trap 'rm -f "$vecchi" "$nuovi" "$rimossi" "$aggiunti"' EXIT
cut -f1 "$OLD_FAI"   | sort > "$vecchi"
cut -f1 "${REF}.fai" | sort > "$nuovi"
comm -23 "$vecchi" "$nuovi" > "$rimossi"
comm -13 "$vecchi" "$nuovi" > "$aggiunti"

# grep -c stampa sempre il conteggio, ma esce con 1 quando e' zero: serve
# ignorare l'esito, non sostituire l'output.
conta()    { grep -cE  "$1" "$2" || true; }
conta_non() { grep -vcE "$1" "$2" || true; }
printf 'Contig totali : %s -> %s\n' "$(wc -l < "$vecchi")" "$(wc -l < "$nuovi")"
printf 'Rimossi       : %s (_alt: %s, HLA-: %s, altri: %s)\n' \
    "$(wc -l < "$rimossi")" \
    "$(conta '_alt$' "$rimossi")" \
    "$(conta '^HLA-' "$rimossi")" \
    "$(conta_non '(_alt$|^HLA-)' "$rimossi")"
printf 'Aggiunti      : %s\n' "$(wc -l < "$aggiunti")"
[[ -s "$aggiunti" ]] && sed 's/^/    + /' "$aggiunti" | head -20


# --- 4. Compatibilita' con dbSNP, snpEff e il BED di GIAB --------------------
msg "4/4 - I cromosomi primari sono rimasti identici?"
if grep -qE '^chr([0-9]{1,2}|X|Y|M)$' "$aggiunti"; then
    errore "un cromosoma primario ha cambiato nome: dbSNP e il BED GIAB non sarebbero piu compatibili."
fi
if grep -qE '^chr([0-9]{1,2}|X|Y|M)$' "$rimossi"; then
    errore "manca un cromosoma primario nel riferimento nuovo."
fi
for c in chr1 chr6 chr10 chr20 chrX chrY chrM; do
    v="$(awk -v c="$c" '$1==c {print $2}' "$OLD_FAI")"
    n="$(awk -v c="$c" '$1==c {print $2}' "${REF}.fai")"
    [[ -n "$n" ]] || errore "${c} assente nel riferimento nuovo."
    [[ "$v" == "$n" ]] ||
        errore "${c} ha lunghezza diversa (${v} vs ${n}): non e' lo stesso GRCh38."
    printf '  %-6s %s bp, identico\n' "$c" "$n"
done
echo
echo "Nomi e lunghezze dei cromosomi primari invariati."
echo "dbSNP, snpEff e il BED di GIAB restano validi senza modifiche."

msg "Riferimento pronto: ${REF}"
echo "La pipeline lo usa gia' come default. Per tornare a quello vecchio:"
echo "  HG002_REF_NAME=Homo_sapiens_assembly38.fasta bash run_parabricks_hg002.sh --preflight"
