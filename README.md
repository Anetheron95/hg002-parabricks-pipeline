# HG002 germline WGS with NVIDIA Parabricks

Educational germline analysis of the HG002 reference sample, sequenced on
NovaSeq PCR-free at nominal 40× coverage with consumer Nvidia RTX 3090 GPU.

The pipeline runs automatically:

1. full integrity check and pairing of the FASTQ files;
2. BWA alignment, sorting and duplicate marking;
3. BAM verification and BQSR as a separate process;
4. HaplotypeCaller in gVCF mode, then GenotypeGVCFs;
5. hard filtering, snpEff annotation, WGS QC and an HTML report.

## Project status

Last updated 27 July 2026.

- **Validated end to end on the smoke test**: 1,000,000 NovaSeq read pairs,
  every step completed with `PASS` and a final exit code of 0. Details in
  `logs/PIPELINE_VALIDATION_20260725.md`, report in `reports/`.
- **Full 40× run: not executed yet.** The preflight for full mode passed —
  reference, indexes, dbSNP, snpEff database, GPU and disk space all verified —
  but the alignment of the complete FASTQ files has never been started. **No
  figure published in this repository comes from a 40× analysis.**
- **GIAB benchmark: pending.** Precision, recall and F1 against the HG002
  v4.2.1 truth set will be added once the 40× VCF is available.

## The three commands you need

Open PowerShell in the project directory.

Preliminary checks only, no analysis:

```powershell
.\Start-HG002.ps1 -PreflightOnly
```

Small end-to-end trial run:

```powershell
.\Start-HG002.ps1 -SmokeTest
```

Full 40× run:

```powershell
.\Start-HG002.ps1
```

To watch progress, throughput, estimates and resource usage:

```powershell
.\Get-PipelineStatus.ps1 -Watch
```

To stop deliberately:

```powershell
.\Stop-HG002.ps1
```

The pipeline resumes automatically from any checkpoint that passes validation.
A file is never treated as valid merely because it exists.

## How the code is organised

- `run_parabricks_hg002.sh` — the main recipe;
- `scripts/pipeline_functions.sh` — Docker orchestration, checkpoints and logs;
- `scripts/postprocess.sh` — filtering, annotation and QC metrics;
- `scripts/generate_report.py` — HTML report and JSON summary;
- `Start-HG002.ps1` — small Windows launcher that runs Bash inside Ubuntu WSL2;
- `Get-PipelineStatus.ps1` — monitor;
- `Stop-HG002.ps1` — controlled shutdown;
- `docs/parabricks-basic-commands.md` — teaching notes on the two Parabricks
  commands taken individually, runnable against the reduced FASTQ in `smoke/`;
- `docs/data-sources.md` — provenance and download URLs for every input file.

## Why large files are not written straight to C:

An earlier attempt failed during the BQSR rewrite of the BAM with
`Cannot allocate memory`, while writing to a Windows-mounted path. The current
pipeline:

- runs `fq2bam` without integrated BQSR;
- uses `--low-memory`, an 8 GB RAM cap and reduced BWA queues;
- writes the BAM, gVCF and intermediates to a Linux Docker volume;
- releases memory by shutting down the container after each phase;
- computes BQSR separately;
- applies the BQSR report inside HaplotypeCaller;
- copies only validated results to `output/`.

If the export to Windows fails, the valid copy stays in the `hg002_work_v1`
volume.

## Directories that matter

- `logs/` — current logs and previous attempts;
- `output/` — validated final results;
- `reports/` — HTML and JSON reports;
- `ref/` — GRCh38/assembly38 and its indexes;
- `snpEff_data/` — local hg38 database;
- `smoke/` — small FASTQ files used for the trial run.

The full FASTQ files, the reference, the databases and the outputs must not be
pushed to GitHub. `.gitignore` excludes them. See `docs/data-sources.md` for
where to obtain each of them.

## Stated limitations

- The workstation has 32 GB of RAM, well below the 100 GB NVIDIA officially
  recommends for WGS. Splitting the work across separate containers reduces the
  risk and passed the smoke test, but the configuration remains outside the
  official specification.
- BQSR uses the dbSNP set included in the project; this is not the complete
  known-sites bundle from the Broad Best Practices.
- The snpEff hg38 database does not recognise some decoy/alt contigs of
  assembly38. The pipeline keeps those records, quantifies the limitation in the
  report, and does not present them as annotated.
- Hard filters and snpEff are technical controls, not clinical interpretation.
