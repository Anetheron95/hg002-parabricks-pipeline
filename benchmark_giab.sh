#!/usr/bin/env bash
# =============================================================================
# Benchmark GIAB: quanto sono accurate le varianti chiamate dalla pipeline?
#
# Confronta il VCF prodotto dalla pipeline con il truth set NIST/GIAB per HG002
# (v4.2.1, GRCh38) usando hap.py con il motore vcfeval.
#
# Il confronto e' ristretto al BED ad alta confidenza: fuori da quelle regioni
# nemmeno GIAB sa quale sia la risposta giusta, quindi contarle come errori
# falserebbe il risultato.
#
# Resta volutamente separato dalla pipeline principale: si esegue una volta,
# a run conclusa, e non tocca nessun risultato.
#
#   Uso:  bash benchmark_giab.sh
# =============================================================================

set -Eeuo pipefail

PROGETTO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Il riferimento deve essere quello contro cui il VCF e' stato chiamato:
# vcfeval normalizza le varianti rileggendo le basi, e con il riferimento
# sbagliato i conteggi non hanno senso.
REF_NAME="${HG002_REF_NAME:-GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna}"
REFERENCE="${PROGETTO}/ref/${REF_NAME}"
REFERENCE_CONTAINER="/data/ref/${REF_NAME}"

# Da quando i prefissi portano la chiave di provenance non sono piu' costanti.
# Se PREFIX non e' passato, viene dedotto dai VCF presenti in output/, e in caso
# di ambiguita' lo script si ferma invece di scegliere al posto tuo.
if [[ -z "${PREFIX:-}" ]]; then
    mapfile -t candidati < <(
        find "${PROGETTO}/output" -maxdepth 1 -name '*.hardfiltered.vcf.gz' \
             -printf '%f\n' 2>/dev/null | sed 's/\.hardfiltered\.vcf\.gz$//' | sort
    )
    case "${#candidati[@]}" in
        0) printf 'Nessun VCF hard-filtered in output/. Esegui prima la pipeline.\n' >&2
           exit 1 ;;
        1) PREFIX="${candidati[0]}" ;;
        *) printf 'Piu di un VCF disponibile: indica quale valutare con PREFIX=...\n' >&2
           printf '  %s\n' "${candidati[@]}" >&2
           exit 1 ;;
    esac
fi

QUERY_VCF="${PROGETTO}/output/${PREFIX}.hardfiltered.vcf.gz"
GIAB_DIR="${PROGETTO}/ref/giab"
SDF_DIR="${GIAB_DIR}/${REF_NAME%.*}.sdf"

# Una cartella per prefisso. Con OUT_DIR fisso, valutare una seconda run
# sovrascriveva il benchmark della prima: hap.py scrive sempre gli stessi nomi
# (happy.summary.csv, happy.roc.*, happy.vcf.gz). L'iterazione 2 avrebbe
# cancellato il proprio termine di paragone.
OUT_DIR="${PROGETTO}/reports/giab/${PREFIX}"
LOG_FILE="${OUT_DIR}/happy.log"

HAPPY_IMG="jmcdani20/hap.py:v0.3.12"
GIAB_BASE="https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38"
TRUTH_VCF="${GIAB_DIR}/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"
TRUTH_BED="${GIAB_DIR}/HG002_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed"

DOCKER="${DOCKER:-docker}"

msg()    { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
errore() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$GIAB_DIR" "$OUT_DIR"

# --- 1. Prerequisiti ---------------------------------------------------------
msg "1/5 - Controllo dei prerequisiti"
command -v "$DOCKER" >/dev/null || errore "Docker non disponibile."
[[ -s "$QUERY_VCF" ]] || errore "VCF da valutare non trovato: $QUERY_VCF
   Esegui prima la pipeline con .\\Start-HG002.ps1"
[[ -s "$REFERENCE" ]] || errore "Riferimento non trovato: $REFERENCE"

if ! $DOCKER image inspect "$HAPPY_IMG" >/dev/null 2>&1; then
    echo "Immagine $HAPPY_IMG assente: la scarico..."
    $DOCKER pull "$HAPPY_IMG"
fi
echo "VCF da valutare: ${PREFIX} ($(du -h "$QUERY_VCF" | cut -f1))"
echo "Riferimento:     ${REF_NAME}"

# --- 2. Truth set ------------------------------------------------------------
msg "2/5 - Truth set GIAB v4.2.1 (circa 250 MB, solo la prima volta)"
scarica() {
    local url="$1" dest="$2"
    if [[ -s "$dest" ]]; then
        echo "Gia' presente: $(basename "$dest")"
        return
    fi
    echo "Scarico $(basename "$dest") ..."
    curl -L --fail --retry 3 -C - -o "$dest" "$url" || errore "Download fallito: $url"
}
scarica "${GIAB_BASE}/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"                  "$TRUTH_VCF"
scarica "${GIAB_BASE}/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz.tbi"              "${TRUTH_VCF}.tbi"
scarica "${GIAB_BASE}/HG002_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed"      "$TRUTH_BED"

# --- 3. Indice RTG del riferimento (SDF) -------------------------------------
# vcfeval lavora su un indice proprio del riferimento. Costruirlo una volta
# rende le esecuzioni successive molto piu' rapide. Se la costruzione non
# riesce non e' grave: hap.py se lo crea da solo, temporaneo, ad ogni giro.
msg "3/5 - Indice RTG del riferimento (una tantum, alcuni minuti)"
if [[ -d "$SDF_DIR" && -n "$(ls -A "$SDF_DIR" 2>/dev/null)" ]]; then
    echo "SDF gia' presente, salto."
    USA_SDF=1
else
    rm -rf "$SDF_DIR"
    if $DOCKER run --rm \
            --volume "${PROGETTO}":/data \
            --env "REF_CONTAINER=${REFERENCE_CONTAINER}" \
            --env "SDF_CONTAINER=/data/ref/giab/$(basename "$SDF_DIR")" \
            "$HAPPY_IMG" \
            bash -lc 'RTG="$(command -v rtg || true)"
                      [[ -n "$RTG" ]] || RTG=/opt/hap.py/libexec/rtg-tools-install/rtg
                      [[ -x "$RTG" ]] || exit 42
                      "$RTG" format -o "$SDF_CONTAINER" "$REF_CONTAINER"'; then
        echo "SDF creato."
        USA_SDF=1
    else
        echo "Non sono riuscito a creare l'SDF: hap.py se lo costruira' da solo."
        rm -rf "$SDF_DIR"
        USA_SDF=0
    fi
fi

# --- 4. hap.py ---------------------------------------------------------------
# Una sola esecuzione basta: hap.py riporta i risultati sia per l'intero
# callset (riga ALL) sia per le sole varianti PASS (riga PASS).
msg "4/5 - Confronto con hap.py (motore vcfeval)"

CORE="$(nproc)"
THREADS=$(( CORE < 8 ? CORE : 8 ))   # con 32 GB di RAM meglio non esagerare
echo "Uso ${THREADS} thread su ${CORE} disponibili."

OPZIONI_SDF=()
[[ "$USA_SDF" -eq 1 ]] &&
    OPZIONI_SDF=(--engine-vcfeval-template "/data/ref/giab/$(basename "$SDF_DIR")")

$DOCKER run --rm \
    --volume "${PROGETTO}":/data \
    --env "HGREF=${REFERENCE_CONTAINER}" \
    --env RTG_MEM=12G \
    "$HAPPY_IMG" \
    /opt/hap.py/bin/hap.py \
        "/data/ref/giab/$(basename "$TRUTH_VCF")" \
        "/data/output/${PREFIX}.hardfiltered.vcf.gz" \
        -f "/data/ref/giab/$(basename "$TRUTH_BED")" \
        -r "$REFERENCE_CONTAINER" \
        -o "/data/reports/giab/${PREFIX}/happy" \
        --engine=vcfeval \
        "${OPZIONI_SDF[@]}" \
        --threads "$THREADS" \
    2>&1 | tee "$LOG_FILE"

[[ -s "${OUT_DIR}/happy.summary.csv" ]] || errore "hap.py non ha prodotto il riepilogo. Vedi $LOG_FILE"

# --- 5. Tabella leggibile ----------------------------------------------------
msg "5/5 - Risultati"
python3 - "$OUT_DIR" <<'PY'
import csv, json, sys, os

out_dir = sys.argv[1]
righe = list(csv.DictReader(open(os.path.join(out_dir, "happy.summary.csv"))))

def num(v, cifre=4):
    try:
        return round(float(v), cifre)
    except (TypeError, ValueError):
        return None

intestazione = f"{'Tipo':<7}{'Filtro':<8}{'Recall':>9}{'Precision':>11}{'F1':>9}{'TP':>10}{'FN':>9}{'FP':>9}"
print(intestazione)
print("-" * len(intestazione))

risultati = {}
for r in righe:
    tipo, filtro = r["Type"], r["Filter"]
    rec, prec, f1 = num(r["METRIC.Recall"]), num(r["METRIC.Precision"]), num(r["METRIC.F1_Score"])
    print(f"{tipo:<7}{filtro:<8}"
          f"{rec if rec is not None else 'n/d':>9}"
          f"{prec if prec is not None else 'n/d':>11}"
          f"{f1 if f1 is not None else 'n/d':>9}"
          f"{r['TRUTH.TP']:>10}{r['TRUTH.FN']:>9}{r['QUERY.FP']:>9}")
    risultati[f"{tipo}_{filtro}"] = {
        "recall": rec, "precision": prec, "f1": f1,
        "truth_total": num(r["TRUTH.TOTAL"], 0), "tp": num(r["TRUTH.TP"], 0),
        "fn": num(r["TRUTH.FN"], 0), "fp": num(r["QUERY.FP"], 0),
    }

with open(os.path.join(out_dir, "giab_benchmark.json"), "w", encoding="utf-8") as f:
    json.dump({"truth_set": "HG002 GIAB v4.2.1 GRCh38 (chr1-22, high-confidence BED)",
               "engine": "vcfeval", "results": risultati}, f, indent=2)
print(f"\nRiepilogo JSON: {os.path.join(out_dir, 'giab_benchmark.json')}")
PY

msg "Benchmark completato. Dettagli in ${OUT_DIR}"
