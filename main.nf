#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

if (params.help) {
    log.info \
    """
NAME
    jev-analysis-pipeline - Automated analysis of Japanese Encephalitis Virus next-generation sequencing data

SYNOPSIS
    nextflow run millironx/jev-analysis-pipeline
        --kraken-db <kraken2 database location>

OPTIONS
    --readsfolder
        The folder containing parired-end Illumina reads in gzipped fastq format. Defaults
        to the current directory

    --threads
        Number of threads to process each sample with. Can't be adjusted on a per-process
        basis. Defaults to 4

    --runname
        A friendly identifier to describe the samples being analyzed. Defaults to
        'jev-analysis'

    --outfolder
        The place where the final anlysis products will be stored. Defaults to runname_out

    --dev
        Run using fewer inputs and faster process options

    --devinputs
        The number of inputs to take in when using --dev

PROCESS-SPECIFIC OPTIONS
Kraken:
    See https://github.com/DerrickWood/kraken2/wiki/Manual for full documentation of
    Kraken 2's available options
    --kraken-db
        Path to Kraken 2 database. REQUIRED
"""
exit 0
}

// Declare what we're going to call our reference genome
ReferenceName = 'JEV'

// Create an output folder name if one wasn't provided
if(params.outfolder == "") {
    OutFolder = params.runname + "_out"
}
else {
    OutFolder = params.outfolder
}

// Main workflow: will be promoted to ont workflow someday
workflow {
    // Pull and index the reference genome of choice
    reference_genome_pull | reference_genome_index

    // Bring in the reads files
    raw_reads = Channel
        .fromPath("${params.readsfolder}/*.{fastq,fq}.gz")
        .take( params.dev ? params.devinputs : -1 )
        .map{ file -> tuple(file.simpleName, file) }
}

// Get the reference genome
process reference_genome_pull {
    cpus 1

    output:
    file '*'

    script:
    """
    efetch -db nucleotide -id ${params.genomeId} -format fasta > reference.fasta
    """
}

// Index the reference genome
process reference_genome_index {
    cpus params.threads

    input:
    file genome

    output:
    file("*.bt2")

    script:
    """
    bowtie2-build --threads ${params.threads} ${genome} ${ReferenceName}
    """
}

// Classify reads using Kraken
process kraken {
    cpus params.threads

    input:
    set val(sampleName), file(readsFile) from RawReads

    output:
    tuple sampleName, file("${sampleName}.kraken"), file("${sampleName}.krpt"), file(readsFile) into KrakenFile

    script:
    quickflag = params.dev ? '--quick' : ''
    """
    kraken2 --db ${params.krakenDb} --threads ${params.threads} ${quickflag} \
        --report "${sampleName}.krpt" \
        --output "${sampleName}.kraken" \
        ${readsFile}
    """
}

// Pull the viral reads and any unclassified reads from the original reads
// files for futher downstream processing using KrakenTools
process filterreads {
    cpus 1

    input:
    set val(sampleName), file(krakenFile), file(krakenReport), file(readsFile) from KrakenFile

    output:
    tuple sampleName, file("${sampleName}_filtered.fastq.gz") into FilteredReads

    // Although I haven't seen it documented anywhere, 0 is unclassified reads
    // and 10239 is viral reads
    script:
    """
    extract_kraken_reads.py -k ${krakenFile} \
        -s ${readsFile} \
        -r ${krakenReport} \
        -t 0 10239 --include-children \
        --fastq-output \
        -o ${sampleName}_filtered.fastq
    gzip ${sampleName}_filtered.fastq
    """
}

// Assemble using Canu
process assembly {
    cpus params.threads

    input:
    set val(sampleName), file(readsFile) from FilteredReads

    output:
    tuple val(sampleName), file("${sampleName}.contigs.fasta") into FastaContigs
    file(readsFile) into BypassReads

    script:
    """
    canu -p ${sampleName} -d out \
        genomeSize=10976\
        maxThreads=${params.threads} \
        stopOnLowCoverage=3 \
        -nanopore ${readsFile}
    cp out/${sampleName}.contigs.fasta .
    """
}


// Convert the contigs to fastq with dummy read scores for realignment
process convertcontigs {
    cpus 1

    input:
    set val(sampleName), file(contigs) from FastaContigs

    output:
    tuple val(sampleName), file("${sampleName}.contigs.fastq.gz") into FastqContigs

    script:
    """
    fastx-converter -i ${contigs} -o ${sampleName}.contigs.fastq.gz
    """
}

// Remap contigs using bowtie2
process realign {
    cpus params.threads

    input:
    set val(sampleName), file(contigs) from FastqContigs
    file(readsFile) from BypassReads
    file(reference) from IndexedReferenceGenome


    output:
    tuple val(sampleName), file("${sampleName}.contigs.sam"), file("${sampleName}.sam") into RemappedReads

    script:
    """
    bowtie2 --threads ${params.threads} -x ${ReferenceName} -U ${contigs} > ${sampleName}.contigs.sam
    bowtie2 --threads ${params.threads} -x ${ReferenceName} -U ${readsFile} > ${sampleName}.sam
    """
}

// Sort and compress the sam files for visualization
process sortsam {
    cpus 1

    input:
    set val(sampleName), file(contigs), file(samfile) from RemappedReads

    output:
    file("*.{bam,bai}") into Assemblies

    script:
    """
    # Convert, sort and index the reads file
    samtools view -S -b ${samfile} > sample.bam
    samtools sort sample.bam -o ${sampleName}.bam
    samtools index ${sampleName}.bam

    # Convert, sort, and index the contigs file
    samtools view -S -b ${contigs} > contigs.bam
    samtools sort contigs.bam -o ${sampleName}.contigs.bam
    samtools index ${sampleName}.contigs.bam

    # Remove intermediate files
    rm sample.bam contigs.bam
    """
}

process sortreference {
    cpus 1

    input:
    file(reference) from ReferenceGenomeIndex

    output:
    tuple file("${ReferenceName}.fasta"), file("*.fai") into SortedReferenceGenome

    script:
    """
    # Create a reference genome index
    cp ${reference} ${ReferenceName}.fasta
    samtools faidx ${ReferenceName}.fasta
    """
}

// Create a viewer of all the assembly files
process assemblyview {
    cpus 1

    publishDir OutFolder, mode: 'copy'

    input:
    file '*' from Assemblies.collect()
    file '*' from SortedReferenceGenome

    output:
    file 'index.html'
    file 'index.js'
    file 'package.json'
    file 'data/*'

    script:
    """
    mkdir data
    mv *.fasta *.fasta.fai *.bam *.bam.bai data
    git clone https://github.com/MillironX/igv-bundler.git igv-bundler
    mv igv-bundler/{index.html,index.js,package.json} .
    """
}
*/
