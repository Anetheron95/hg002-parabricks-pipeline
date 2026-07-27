#!/usr/bin/env bash
# Funzioni tecniche usate da run_hg002.sh.
# Lo studente puo' concentrarsi sul file principale: qui sono raccolti Docker,
# checkpoint, log ed esportazione sicura.

set -Eeuo pipefail

say() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf '\nERRORE: %s\n' "$*" >&2
    exit 1
}

write_state() {
    local key="$1"
    local label="$2"
    local status="$3"
    local started="${4:-}"
    printf 'STEP_KEY=%s\nSTEP_LABEL=%s\nSTEP_STATUS=%s\nSTEP_STARTED=%s\n' \
        "$key" "$label" "$status" "$started" > "${STATE_FILE}.tmp"
    mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

record_timing() {
    local key="$1"
    local started="$2"
    local ended="$3"
    local seconds="$4"
    local status="$5"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$key" "$started" "$ended" "$seconds" "$status" >> "$TIMING_FILE"
}

skip_step() {
    local key="$1"
    local label="$2"
    local now
    now="$(date --iso-8601=seconds)"
    printf '[OK] %s: checkpoint gia valido, passo oltre.\n' "$label"
    record_timing "$key" "$now" "$now" "0" "SKIPPED_VALID"
}

run_step() {
    local key="$1"
    local label="$2"
    shift 2

    local started ended start_epoch end_epoch rc log_file
    started="$(date --iso-8601=seconds)"
    start_epoch="$(date +%s)"
    log_file="${RUN_DIR}/${key}.log"

    say "$label"
    write_state "$key" "$label" "RUNNING" "$started"

    set +e
    "$@" 2>&1 | tee "$log_file"
    rc="${PIPESTATUS[0]}"
    set -e

    ended="$(date --iso-8601=seconds)"
    end_epoch="$(date +%s)"

    if [[ "$rc" -eq 0 ]]; then
        record_timing "$key" "$started" "$ended" "$((end_epoch - start_epoch))" "PASS"
        write_state "$key" "$label" "PASS" "$started"
        printf '[OK] %s completato.\n' "$label"
        return 0
    fi

    record_timing "$key" "$started" "$ended" "$((end_epoch - start_epoch))" "FAILED"
    write_state "$key" "$label" "FAILED" "$started"
    printf '[ERRORE] %s fallito (codice %s). Log: %s\n' "$label" "$rc" "$log_file" >&2
    return "$rc"
}

remove_stopped_container() {
    local name="$1"
    local running
    running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
    if [[ "$running" == "true" ]]; then
        die "il container ${name} e' gia attivo. Non avvio un secondo processo sugli stessi file."
    fi
    if [[ "$running" == "false" ]]; then
        docker rm "$name" >/dev/null
    fi
}

run_parabricks() {
    local container_name="$1"
    shift
    remove_stopped_container "$container_name"
    docker run --rm \
        --name "$container_name" \
        --gpus all \
        --mount "type=bind,source=${PROJECT_DIR},target=/project,readonly" \
        --mount "type=volume,source=${WORK_VOLUME},target=/work" \
        --mount "type=volume,source=${TMP_VOLUME},target=/pbtmp" \
        "$PB_IMAGE" "$@"
}

run_tools() {
    local container_name="$1"
    shift
    remove_stopped_container "$container_name"
    docker run --rm \
        --name "$container_name" \
        --mount "type=bind,source=${PROJECT_DIR},target=/project,readonly" \
        --mount "type=volume,source=${WORK_VOLUME},target=/work" \
        --mount "type=volume,source=${TMP_VOLUME},target=/pbtmp" \
        "$TOOLS_IMAGE" "$@"
}

tools_quiet() {
    docker run --rm \
        --mount "type=bind,source=${PROJECT_DIR},target=/project,readonly" \
        --mount "type=volume,source=${WORK_VOLUME},target=/work" \
        --mount "type=volume,source=${TMP_VOLUME},target=/pbtmp" \
        "$TOOLS_IMAGE" "$@" >/dev/null 2>&1
}

work_remove() {
    if [[ "$#" -gt 0 ]]; then
        docker run --rm \
            --mount "type=volume,source=${WORK_VOLUME},target=/work" \
            alpine:3.20 rm -f -- "$@" >/dev/null
    fi
}

work_file_exists() {
    local path="$1"
    docker run --rm \
        --mount "type=volume,source=${WORK_VOLUME},target=/work,readonly" \
        alpine:3.20 test -s "$path" >/dev/null 2>&1
}

valid_fastq_json() {
    local path="/work/${PREFIX}.fastq_validation.json"
    tools_quiet python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
expected = int(sys.argv[2])
ok = (
    d.get("status") == "PASS"
    and d.get("full_gzip_integrity_checked") is True
    and d.get("paired_ids_match") is True
    and d.get("fastq_structure_valid") is True
    and int(d.get("total_pairs", -1)) == expected
)
raise SystemExit(0 if ok else 1)
' "$path" "$EXPECTED_PAIRS"
}

valid_bam() {
    local bam="/work/${PREFIX}.bam"
    local bai="${bam}.bai"
    tools_quiet bash /project/scripts/postprocess.sh check-bam "$bam" "$bai" "$SAMPLE" "$READ_GROUP_PU"
}

valid_partial_bam() {
    local bam="/work/${PREFIX}.partial.bam"
    local bai="${bam}.bai"
    tools_quiet bash /project/scripts/postprocess.sh check-bam "$bam" "$bai" "$SAMPLE" "$READ_GROUP_PU"
}

valid_recal() {
    tools_quiet bash /project/scripts/postprocess.sh check-recal "/work/${PREFIX}.recal.txt"
}

valid_vcf() {
    local path="$1"
    tools_quiet bash /project/scripts/postprocess.sh check-vcf "$path" "${path}.tbi" "$SAMPLE"
}

valid_hardfilter() {
    tools_quiet bash /project/scripts/postprocess.sh check-hardfilter "$PREFIX" "$SAMPLE"
}

valid_annotation() {
    tools_quiet bash /project/scripts/postprocess.sh check-annotation "$PREFIX" "$SAMPLE"
}

valid_qc() {
    tools_quiet bash /project/scripts/postprocess.sh check-qc "$PREFIX"
}

copy_validation_checkpoint() {
    local candidate relative
    for candidate in "${VALIDATION_CANDIDATES[@]}"; do
        [[ -s "$candidate" ]] || continue
        relative="${candidate#"$PROJECT_DIR"/}"
        docker run --rm \
            --mount "type=bind,source=${PROJECT_DIR},target=/project,readonly" \
            --mount "type=volume,source=${WORK_VOLUME},target=/work" \
            alpine:3.20 cp "/project/${relative}" "/work/${PREFIX}.fastq_validation.json"
        if valid_fastq_json; then
            printf 'Riutilizzo il controllo completo gia superato: %s\n' "$relative"
            return 0
        fi
        work_remove "/work/${PREFIX}.fastq_validation.json"
    done
    return 1
}

ensure_fastq_integrity() {
    if valid_fastq_json; then
        skip_step "1_fastq_integrity" "1/9 - Integrita FASTQ e pairing"
        return
    fi

    if [[ "$(stat -c '%s' "$FASTQ_R1_HOST")" == "$EXPECTED_R1_BYTES" ]] &&
       [[ "$(stat -c '%s' "$FASTQ_R2_HOST")" == "$EXPECTED_R2_BYTES" ]] &&
       copy_validation_checkpoint; then
        skip_step "1_fastq_integrity" "1/9 - Integrita FASTQ e pairing"
        return
    fi

    work_remove "/work/${PREFIX}.fastq_validation.json"
    run_step "1_fastq_integrity" "1/9 - Integrita FASTQ e pairing" \
        run_tools "hg002_1_fastq_integrity" \
        bash /project/scripts/postprocess.sh integrity \
        "$PREFIX" "$FASTQ_R1_CONTAINER" "$FASTQ_R2_CONTAINER"

    valid_fastq_json || die "il controllo FASTQ non ha prodotto un checkpoint valido."
}

preflight() {
    say "Controlli preliminari"

    grep -qi microsoft /proc/version ||
        die "esegui questo script con Ubuntu WSL2, non con Git Bash."
    command -v docker >/dev/null || die "Docker non e' disponibile in Ubuntu WSL2."
    command -v nvidia-smi >/dev/null || die "nvidia-smi non e' disponibile in Ubuntu WSL2."

    local required=(
        "$FASTQ_R1_HOST"
        "$FASTQ_R2_HOST"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.fasta"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.fasta.fai"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.dict"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.fasta.amb"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.fasta.ann"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.fasta.bwt"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.fasta.pac"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.fasta.sa"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.dbsnp138.vcf.gz"
        "$PROJECT_DIR/ref/Homo_sapiens_assembly38.dbsnp138.vcf.gz.tbi"
        "$PROJECT_DIR/snpEff_data/hg38/snpEffectPredictor.bin"
        "$PROJECT_DIR/scripts/postprocess.sh"
        "$PROJECT_DIR/scripts/generate_report.py"
    )
    local file
    for file in "${required[@]}"; do
        [[ -s "$file" ]] || die "file obbligatorio mancante o vuoto: $file"
    done

    docker info >/dev/null || die "Docker Desktop non risponde."
    docker image inspect "$PB_IMAGE" >/dev/null ||
        die "immagine Parabricks non trovata: $PB_IMAGE"
    docker image inspect "$TOOLS_IMAGE" >/dev/null ||
        die "immagine bioinformatica non trovata: $TOOLS_IMAGE"
    docker image inspect alpine:3.20 >/dev/null ||
        die "immagine di servizio alpine:3.20 non trovata."

    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader |
        sed 's/^/GPU: /'

    docker volume create "$WORK_VOLUME" >/dev/null
    docker volume create "$TMP_VOLUME" >/dev/null

    local docker_free_kb host_free_kb docker_min_kb host_min_kb
    docker_free_kb="$(
        docker run --rm \
            --mount "type=volume,source=${WORK_VOLUME},target=/work" \
            alpine:3.20 sh -c "df -Pk /work | awk 'END {print \$4}'"
    )"
    host_free_kb="$(df -Pk "$PROJECT_DIR" | awk 'END {print $4}')"

    if [[ "$MODE" == "full" ]]; then
        docker_min_kb=$((300 * 1024 * 1024))
        host_min_kb=$((150 * 1024 * 1024))
    else
        docker_min_kb=$((5 * 1024 * 1024))
        host_min_kb=$((5 * 1024 * 1024))
    fi

    (( docker_free_kb >= docker_min_kb )) ||
        die "spazio insufficiente nel disco Linux di Docker."
    (( host_free_kb >= host_min_kb )) ||
        die "spazio insufficiente sul disco Windows per esportare i risultati."

    printf 'Spazio libero Docker: %.1f GiB\n' "$(awk -v k="$docker_free_kb" 'BEGIN{print k/1024/1024}')"
    printf 'Spazio libero Windows: %.1f GiB\n' "$(awk -v k="$host_free_kb" 'BEGIN{print k/1024/1024}')"
    printf 'Modalita: %s | Campione: %s | Volume risultati: %s\n' \
        "$MODE" "$SAMPLE" "$WORK_VOLUME"
}

finalize_bam() {
    run_tools "hg002_2_bam_check" \
        bash /project/scripts/postprocess.sh finalize-bam \
        "/work/${PREFIX}.partial.bam" \
        "/work/${PREFIX}.bam" \
        "$SAMPLE" "$READ_GROUP_PU" \
        "/work/${PREFIX}.duplicate_metrics.partial.txt" \
        "/work/${PREFIX}.duplicate_metrics.txt"
}

finalize_recal() {
    run_tools "hg002_3_bqsr_check" \
        bash /project/scripts/postprocess.sh finalize-recal \
        "/work/${PREFIX}.recal.partial.txt" \
        "/work/${PREFIX}.recal.txt"
}

finalize_vcf() {
    local partial="$1"
    local final="$2"
    local name="$3"
    run_tools "$name" \
        bash /project/scripts/postprocess.sh finalize-vcf \
        "$partial" "$final" "$SAMPLE"
}

export_results() {
    local stage="${OUTPUT_DIR}/.incoming_${PREFIX}_${RUN_ID}"
    mkdir -p "$stage"

    local files=(
        "${PREFIX}.fastq_validation.json"
        "${PREFIX}.bam"
        "${PREFIX}.bam.bai"
        "${PREFIX}.duplicate_metrics.txt"
        "${PREFIX}.recal.txt"
        "${PREFIX}.g.vcf.gz"
        "${PREFIX}.g.vcf.gz.tbi"
        "${PREFIX}.vcf.gz"
        "${PREFIX}.vcf.gz.tbi"
        "${PREFIX}.hardfiltered.vcf.gz"
        "${PREFIX}.hardfiltered.vcf.gz.tbi"
        "${PREFIX}_annotated.vcf.gz"
        "${PREFIX}_annotated.vcf.gz.tbi"
        "${PREFIX}_high_impact_variants.tsv"
        "${PREFIX}_snpEff_summary.html"
        "${PREFIX}_snpEff_summary.genes.txt"
        "${PREFIX}.snpeff.log"
        "${PREFIX}.annotation_qc.tsv"
        "${PREFIX}.flagstat.txt"
        "${PREFIX}.samtools_stats.txt"
        "${PREFIX}.idxstats.tsv"
        "${PREFIX}.bam_header.sam"
        "${PREFIX}.coverage.tsv"
        "${PREFIX}.wgs_metrics.txt"
        "${PREFIX}.depth_thresholds.tsv"
        "${PREFIX}.vcf_contigs.txt"
    )

    local source_paths=()
    local name
    for name in "${files[@]}"; do
        source_paths+=("/work/${name}")
    done

    docker run --rm \
        --mount "type=volume,source=${WORK_VOLUME},target=/work,readonly" \
        --mount "type=bind,source=${stage},target=/export" \
        alpine:3.20 cp -a "${source_paths[@]}" /export/

    cp "$TIMING_FILE" "${stage}/${PREFIX}.step_times.tsv"

    docker run --rm \
        --mount "type=bind,source=${stage},target=/export,readonly" \
        "$TOOLS_IMAGE" bash -c '
set -euo pipefail
p="$1"
samtools quickcheck -v "/export/${p}.bam"
test -s "/export/${p}.bam.bai"
samtools idxstats "/export/${p}.bam" >/dev/null
for v in \
    "/export/${p}.g.vcf.gz" \
    "/export/${p}.vcf.gz" \
    "/export/${p}.hardfiltered.vcf.gz" \
    "/export/${p}_annotated.vcf.gz"
do
    gzip -t "$v"
    test -s "${v}.tbi"
    tabix -l "$v" >/dev/null
done
' _ "$PREFIX"

    for name in "${files[@]}" "${PREFIX}.step_times.tsv"; do
        mv -f "${stage}/${name}" "${OUTPUT_DIR}/${name}"
    done
    rmdir "$stage"
}

generate_report() {
    docker run --rm \
        --name "hg002_9_report" \
        --entrypoint python3 \
        --mount "type=bind,source=${PROJECT_DIR},target=/project,readonly" \
        --mount "type=bind,source=${OUTPUT_DIR},target=/project/output" \
        --mount "type=bind,source=${REPORT_DIR},target=/project/reports" \
        "$TOOLS_IMAGE" \
        /project/scripts/generate_report.py report \
        --root /project \
        --prefix "$PREFIX" \
        --sample "$SAMPLE" \
        --mode "$MODE"
}

pipeline_failed() {
    local rc="$1"
    local line="$2"
    printf '\nPipeline interrotta alla riga %s (codice %s).\n' "$line" "$rc" >&2
    printf 'I risultati gia validati restano nel volume %s e verranno riutilizzati.\n' \
        "$WORK_VOLUME" >&2
}
