# Data sources

Direct download addresses for everything the pipeline expects to find locally.
None of these files are versioned in this repository: they amount to tens of
gigabytes and all come from public archives.

## GRCh38 reference

Public GATK hg38 bundle on Google Cloud, the same one used by GATK workflows.

```
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta.fai
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.dict
```

Pre-built BWA indexes, so they do not have to be regenerated locally:

```
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta.64.alt
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta.64.amb
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta.64.ann
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta.64.bwt
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta.64.pac
https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.fasta.64.sa
```

All of these belong in `ref/`.

## HG002 FASTQ

Whole-genome NovaSeq PCR-free, paired-end, nominal 40× depth.

Measured properties of the files in use:

| Quantity | Value |
|---|---|
| Read pairs | 474,384,500 |
| Read length | 151 bp, uniform |
| Total bases | ~143.3 Gbp |
| Raw coverage over 3.1 Gbp | ~46× |
| Coverage after duplicates (8.6%) | ~42× |
| File sizes | 34.2 GB (R1) and 35.4 GB (R2) |

Source, from the public Google Brain Genomics bucket:

```
https://storage.googleapis.com/brain-genomics-public/research/sequencing/fastq/novaseq/wgs_pcr_free/40x/HG002.novaseq.pcr-free.40x.R1.fastq.gz
https://storage.googleapis.com/brain-genomics-public/research/sequencing/fastq/novaseq/wgs_pcr_free/40x/HG002.novaseq.pcr-free.40x.R2.fastq.gz
```

Provenance verified by direct comparison: the remote objects report
34,156,056,301 and 35,449,847,992 bytes, byte-for-byte identical to the local
files. "40×" is the name under which the publisher distributes the dataset; the
raw coverage computed above is higher because the nominal figure refers to the
usable coverage expected after mapping and duplicate removal.

> **Do not confuse this with the UCSC variant.** The Giraffe directory of the
> UCSC project hosts an HG002 NovaSeq PCR-free set with a deceptively similar
> name — 35×, different capitalisation (`HG002.NovaSeq.pcr-free.35x.*`), and
> sizes of 29,911,262,422 and 31,043,207,981 bytes. It is not the source used
> here.
>
> ```
> https://cgl.gi.ucsc.edu/data/giraffe/mapping/reads/real/HG002/HG002.NovaSeq.pcr-free.35x.R1.fastq.gz
> https://cgl.gi.ucsc.edu/data/giraffe/mapping/reads/real/HG002/HG002.NovaSeq.pcr-free.35x.R2.fastq.gz
> ```

## GIAB truth set for benchmarking

GIAB/NIST HG002 GRCh38 v4.2.1, the ground truth used to measure precision and
recall of the variant calling.

```
https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz
https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz.tbi
https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed
```

The BED delimits the high-confidence regions: the comparison must be restricted
to those, otherwise regions where not even GIAB knows the answer get counted as
errors.

## dbSNP for BQSR

The project uses `Homo_sapiens_assembly38.dbsnp138.vcf.gz`, available in the
same Broad bundle. As stated in the README limitations, this is not the complete
known-sites set from the Best Practices.
