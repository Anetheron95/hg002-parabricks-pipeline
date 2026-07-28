#!/usr/bin/env bash
# =============================================================================
# Pipeline germinale HG002 - versione didattica
#
# Si legge dall'alto verso il basso:
#   1. controlla i FASTQ
#   2. crea e controlla il BAM
#   3. calcola BQSR e chiama le varianti
#   4. filtra e annota il VCF
#   5. produce QC, esportazione e report
# =============================================================================

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${PROJECT_DIR}/scripts/pipeline_functions.sh"


# -----------------------------------------------------------------------------
# 0. Modalita di esecuzione
# -----------------------------------------------------------------------------

MODE="full"
PREFLIGHT_ONLY="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --smoke)     MODE="smoke" ;;
        --preflight) PREFLIGHT_ONLY="true" ;;
        --help|-h)
            echo "Uso:"
            echo "  ./run_parabricks_hg002.sh              # analisi completa 40x"
            echo "  ./run_parabricks_hg002.sh --smoke      # collaudo piccolo"
            echo "  ./run_parabricks_hg002.sh --preflight  # soli controlli"
            exit 0
            ;;
        *) die "opzione sconosciuta: $1" ;;
    esac
    shift
done


# -----------------------------------------------------------------------------
# 1. Dati del progetto
# -----------------------------------------------------------------------------

SAMPLE="HG002"
REFERENCE="/project/ref/Homo_sapiens_assembly38.fasta"
KNOWN_SITES="/project/ref/Homo_sapiens_assembly38.dbsnp138.vcf.gz"

# Read group ricavato dall'header NovaSeq:
# flowcell HV3C3DSXX, lane 2, indici AGCGATAG+AGGCGAAG.
READ_GROUP_PU="HV3C3DSXX.2.AGCGATAG+AGGCGAAG"
READ_GROUP='@RG\tID:HV3C3DSXX.2\tPL:ILLUMINA\tPM:NovaSeq6000\tLB:HG002_PCR_FREE\tPU:HV3C3DSXX.2.AGCGATAG+AGGCGAAG\tSM:HG002'

PB_IMAGE="nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1"
TOOLS_IMAGE="bioinfo-codeserver:latest"

if [[ "$MODE" == "smoke" ]]; then
    PREFIX="HG002_NovaSeq_smoke_test"
    FASTQ_R1_HOST="${PROJECT_DIR}/smoke/HG002_NovaSeq_smoke_R1.fastq.gz"
    FASTQ_R2_HOST="${PROJECT_DIR}/smoke/HG002_NovaSeq_smoke_R2.fastq.gz"
    FASTQ_R1_CONTAINER="/project/smoke/HG002_NovaSeq_smoke_R1.fastq.gz"
    FASTQ_R2_CONTAINER="/project/smoke/HG002_NovaSeq_smoke_R2.fastq.gz"
    EXPECTED_R1_BYTES="75559067"
    EXPECTED_R2_BYTES="77823079"
    EXPECTED_PAIRS="1000000"
    WORK_VOLUME="hg002_smoke_work_v1"
    TMP_VOLUME="hg002_smoke_tmp_v1"
    INTERVAL_ARGS=(-L "chr20:1-1000000")
else
    PREFIX="HG002_NovaSeq_40x"
    FASTQ_R1_HOST="${PROJECT_DIR}/HG002.novaseq.pcr-free.40x.R1.fastq.gz"
    FASTQ_R2_HOST="${PROJECT_DIR}/HG002.novaseq.pcr-free.40x.R2.fastq.gz"
    FASTQ_R1_CONTAINER="/project/HG002.novaseq.pcr-free.40x.R1.fastq.gz"
    FASTQ_R2_CONTAINER="/project/HG002.novaseq.pcr-free.40x.R2.fastq.gz"
    EXPECTED_R1_BYTES="34156056301"
    EXPECTED_R2_BYTES="35449847992"
    EXPECTED_PAIRS="474384500"
    WORK_VOLUME="hg002_work_v1"
    TMP_VOLUME="hg002_tmp_v1"
    INTERVAL_ARGS=()
fi


# -----------------------------------------------------------------------------
# 2. Log e protezione contro due avvii simultanei
# -----------------------------------------------------------------------------

OUTPUT_DIR="${PROJECT_DIR}/output"
REPORT_DIR="${PROJECT_DIR}/reports"
LOG_DIR="${PROJECT_DIR}/logs"
RUN_ID="$(date '+%Y%m%d_%H%M%S')_${MODE}"
RUN_DIR="${LOG_DIR}/runs/${RUN_ID}"
TIMING_FILE="${RUN_DIR}/${PREFIX}.step_times.tsv"
STATE_FILE="${LOG_DIR}/current_step.env"

mkdir -p "$OUTPUT_DIR" "$REPORT_DIR" "$RUN_DIR"

exec 9>"${LOG_DIR}/pipeline.lock"
flock -n 9 || die "un'altra pipeline HG002 e' gia in esecuzione."

cat > "${LOG_DIR}/current_run.env.tmp" <<EOF
RUN_ID=${RUN_ID}
MODE=${MODE}
PREFIX=${PREFIX}
WORK_VOLUME=${WORK_VOLUME}
STARTED=$(date --iso-8601=seconds)
EOF
mv -f "${LOG_DIR}/current_run.env.tmp" "${LOG_DIR}/current_run.env"

printf 'Step\tStarted\tEnded\tSeconds\tStatus\n' > "$TIMING_FILE"
exec 3>&1 4>&2
exec > >(tee -a "${RUN_DIR}/pipeline.log" >&3) 2>&1
TEE_PID="$!"

on_pipeline_exit() {
    local rc="$?"
    if [[ "$rc" -ne 0 ]]; then
        pipeline_failed "$rc" "${BASH_LINENO[0]:-?}"
    fi
    # Chiude il flusso verso tee e aspetta che il log sia scritto interamente.
    exec 1>&3 2>&4
    wait "$TEE_PID" 2>/dev/null || true
    return "$rc"
}
trap on_pipeline_exit EXIT

VALIDATION_CANDIDATES=(
    "${OUTPUT_DIR}/${PREFIX}.fastq_validation.json"
    "${OUTPUT_DIR}/HG002_NovaSeq_${MODE}.fastq_validation.json"
    "${LOG_DIR}/previous_attempts/HG002_NovaSeq_${MODE}.fastq_validation.json"
    "${LOG_DIR}/previous_attempts/HG002_NovaSeq_40x.fastq_validation.json"
    "${LOG_DIR}/previous_attempts/HG002_NovaSeq_smoke.fastq_validation.json"
)

echo "============================================================"
echo " Pipeline HG002 | modalita: ${MODE}"
echo " Run: ${RUN_ID}"
echo "============================================================"


# =============================================================================
# PASSO 1 - Controlli preliminari e integrita dei FASTQ
# =============================================================================

preflight
ensure_fastq_integrity

if [[ "$PREFLIGHT_ONLY" == "true" ]]; then
    write_state "preflight" "Controlli preliminari" "PASS" "$(date --iso-8601=seconds)"
    echo
    echo "PREFLIGHT SUPERATO. Nessun BAM o VCF e' stato calcolato."
    exit 0
fi


# =============================================================================
# PASSO 2 - FASTQ -> BAM allineato, ordinato e con duplicati marcati
# =============================================================================

if valid_bam; then
    skip_step "2_fq2bam" "2/9 - fq2bam"
    skip_step "2b_bam_check" "Controllo di integrita del BAM"
else
    if valid_partial_bam &&
       work_file_exists "/work/${PREFIX}.duplicate_metrics.partial.txt"; then
        skip_step "2_fq2bam" "2/9 - fq2bam (output parziale gia completo)"
    else
        work_remove \
            "/work/${PREFIX}.partial.bam" \
            "/work/${PREFIX}.partial.bam.bai" \
            "/work/${PREFIX}.duplicate_metrics.partial.txt"

        run_step "2_fq2bam" "2/9 - fq2bam: allineamento, sort e duplicati" \
            run_parabricks "hg002_2_fq2bam" \
            pbrun fq2bam \
            --ref "$REFERENCE" \
            --in-fq "$FASTQ_R1_CONTAINER" "$FASTQ_R2_CONTAINER" "$READ_GROUP" \
            --out-bam "/work/${PREFIX}.partial.bam" \
            --out-duplicate-metrics "/work/${PREFIX}.duplicate_metrics.partial.txt" \
            --bwa-options=-Y \
            --low-memory \
            --memory-limit 8 \
            --bwa-normalized-queue-capacity 2 \
            --gpuwrite \
            --monitor-usage \
            --tmp-dir /pbtmp \
            --num-gpus 1
    fi

    run_step "2b_bam_check" "Controllo BAM: struttura, indice e read group" \
        finalize_bam
    valid_bam || die "il BAM finale non supera il controllo."
fi


# =============================================================================
# PASSO 3 - BQSR separato, poi chiamata delle varianti
# =============================================================================

# BQSR e' separato da fq2bam: cosi la RAM viene liberata tra i due processi.
if valid_recal; then
    skip_step "3_bqsr" "3/9 - Base Quality Score Recalibration"
    skip_step "3b_bqsr_check" "Controllo del report BQSR"
else
    if tools_quiet bash /project/scripts/postprocess.sh check-recal \
        "/work/${PREFIX}.recal.partial.txt"; then
        skip_step "3_bqsr" "3/9 - BQSR (report parziale gia completo)"
    else
        work_remove "/work/${PREFIX}.recal.partial.txt"
        run_step "3_bqsr" "3/9 - BQSR: modello di ricalibrazione delle qualita" \
            run_parabricks "hg002_3_bqsr" \
            pbrun bqsr \
            --ref "$REFERENCE" \
            --in-bam "/work/${PREFIX}.bam" \
            --knownSites "$KNOWN_SITES" \
            --out-recal-file "/work/${PREFIX}.recal.partial.txt" \
            "${INTERVAL_ARGS[@]}" \
            --tmp-dir /pbtmp \
            --num-gpus 1
    fi
    run_step "3b_bqsr_check" "Controllo del report BQSR" finalize_recal
    valid_recal || die "il report BQSR finale non e' valido."
fi

# HaplotypeCaller genera un gVCF e applica BQSR al volo con --in-recal-file.
GVCF="/work/${PREFIX}.g.vcf.gz"
GVCF_PARTIAL="/work/${PREFIX}.partial.g.vcf.gz"
if valid_vcf "$GVCF"; then
    skip_step "4_haplotypecaller" "4/9 - HaplotypeCaller (gVCF)"
    skip_step "4b_gvcf_check" "Controllo di integrita del gVCF"
else
    if valid_vcf "$GVCF_PARTIAL"; then
        skip_step "4_haplotypecaller" "4/9 - HaplotypeCaller (gVCF parziale valido)"
    else
        work_remove "$GVCF_PARTIAL" "${GVCF_PARTIAL}.tbi"
        run_step "4_haplotypecaller" "4/9 - HaplotypeCaller: produzione del gVCF" \
            run_parabricks "hg002_4_haplotypecaller" \
            pbrun haplotypecaller \
            --ref "$REFERENCE" \
            --in-bam "/work/${PREFIX}.bam" \
            --in-recal-file "/work/${PREFIX}.recal.txt" \
            --out-variants "$GVCF_PARTIAL" \
            --gvcf \
            --htvc-low-memory \
            "${INTERVAL_ARGS[@]}" \
            --tmp-dir /pbtmp \
            --num-gpus 1
    fi
    run_step "4b_gvcf_check" "Controllo e finalizzazione del gVCF" \
        finalize_vcf "$GVCF_PARTIAL" "$GVCF" "hg002_4b_gvcf_check"
    valid_vcf "$GVCF" || die "il gVCF finale non e' valido."
fi

# GenotypeGVCF trasforma il gVCF in un normale VCF di varianti.
VCF="/work/${PREFIX}.vcf.gz"
VCF_PARTIAL="/work/${PREFIX}.partial.vcf.gz"
if valid_vcf "$VCF"; then
    skip_step "5_genotypegvcf" "5/9 - GenotypeGVCF"
    skip_step "5b_vcf_check" "Controllo di integrita del VCF"
else
    if valid_vcf "$VCF_PARTIAL"; then
        skip_step "5_genotypegvcf" "5/9 - GenotypeGVCF (VCF parziale valido)"
    else
        work_remove "$VCF_PARTIAL" "${VCF_PARTIAL}.tbi"
        run_step "5_genotypegvcf" "5/9 - GenotypeGVCF: gVCF -> VCF" \
            run_parabricks "hg002_5_genotypegvcf" \
            pbrun genotypegvcf \
            --ref "$REFERENCE" \
            --in-gvcf "$GVCF" \
            --out-vcf "$VCF_PARTIAL" \
            --tmp-dir /pbtmp
    fi
    run_step "5b_vcf_check" "Controllo e finalizzazione del VCF" \
        finalize_vcf "$VCF_PARTIAL" "$VCF" "hg002_5b_vcf_check"
    valid_vcf "$VCF" || die "il VCF finale non e' valido."
fi


# =============================================================================
# PASSO 4 - Hard filtering e annotazione snpEff
# =============================================================================

if valid_hardfilter; then
    skip_step "6_hardfilter" "6/9 - Hard filtering"
else
    run_step "6_hardfilter" "6/9 - Hard filtering senza eliminare record" \
        run_tools "hg002_6_hardfilter" \
        bash /project/scripts/postprocess.sh hardfilter "$PREFIX" "$SAMPLE"
    valid_hardfilter || die "il VCF hard-filtered non e' valido."
fi

if valid_annotation; then
    skip_step "7_annotation" "7/9 - Annotazione snpEff"
else
    run_step "7_annotation" "7/9 - Annotazione snpEff e tabella PASS+HIGH" \
        run_tools "hg002_7_annotation" \
        bash /project/scripts/postprocess.sh annotate "$PREFIX" "$SAMPLE"
    valid_annotation || die "gli output di annotazione non sono validi."
fi


# =============================================================================
# PASSO 5 - QC completo, esportazione su Windows e report HTML
# =============================================================================

if valid_qc; then
    skip_step "8_qc" "8/9 - QC completo"
else
    run_step "8_qc" "8/9 - QC: allineamento, copertura e metriche WGS" \
        run_tools "hg002_8_qc" \
        bash /project/scripts/postprocess.sh qc "$PREFIX" "$MODE"
    valid_qc || die "le metriche QC obbligatorie sono incomplete."
fi

# I file grandi vengono copiati su C: soltanto ora, dopo tutti i controlli.
# Se la copia fallisse, gli originali validi resterebbero nel volume Linux.
run_step "8b_export" "Esportazione dei risultati gia validati su Windows" \
    export_results

run_step "9_report" "9/9 - Report HTML e riepilogo JSON" \
    generate_report

[[ -s "${REPORT_DIR}/${PREFIX}_Report.html" ]] ||
    die "il report HTML non e' stato creato."
[[ -s "${REPORT_DIR}/${PREFIX}_summary.json" ]] ||
    die "il riepilogo JSON non e' stato creato."

# Il volume temporaneo e' dedicato a questa pipeline e non contiene risultati.
docker volume rm "$TMP_VOLUME" >/dev/null 2>&1 || true

write_state "complete" "Pipeline completata" "PASS" "$(date --iso-8601=seconds)"

echo
echo "============================================================"
echo " PIPELINE COMPLETATA E VALIDATA"
echo "============================================================"
echo " Risultati: ${OUTPUT_DIR}"
echo " Report:    ${REPORT_DIR}/${PREFIX}_Report.html"
echo " Log:       ${RUN_DIR}"
echo " Volume di recupero: ${WORK_VOLUME}"
echo
echo " Il benchmark GIAB non e' stato eseguito: rimane separato."
echo "============================================================"
