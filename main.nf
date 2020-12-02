#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/slamseq
========================================================================================
 nf-core/slamseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/slamseq
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/slamseq --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                  Tab-separated file containing information about the samples in the experiment (see docs/usage.md)
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Options:
      --genome [str]                  Name of iGenomes reference

    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --fasta [file]                  Path to fasta reference
      --bed [file]                    Path to 3' UTR counting window reference
      --mapping [file]                Path to 3' UTR multimapper recovery reference (optional)
      --vcf [file]                    Path to VCF file for genomic SNPs to mask T>C conversion (optional)

    Processing parameters
      --trim5 [int]                   Number of basepairs to trim from 5' end of the read
      --polyA [int]                   Maximum number of As at the 3' end of a read.
      --multimappers [bool]           Activate multimapper retainment strategy
      --quantseq [bool]               Deactivate nucleotide-conversion aware scoring
      --endtoend [bool]               Use a end to end alignment algorithm for mapping.
      --min_coverage [int]            Minimimum coverage to call a SNP.
      --var_fraction [float]          Minimimum variant fraction to call a SNP.
      --conversions [int]             Minimum number of conversions to count a read as converted read
      --base_quality [int]            Minimum base quality to filter conversions
      --read_length [int]             Read length of processed reads
      --pvalue [float]                P-value cutoff for MA plot
      --skip_trimming [bool]          Skip trimming step
      --skip_deseq2 [bool]            Skip trimming step

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// Configurable reference genomes
//
//

// Validate input
if (!params.input) exit 1, "Input design file not specified!"

params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if (params.fasta) {
    if (params.fasta.endsWith(".gz")) {
        Channel
            .fromPath(params.fasta,  checkIfExists: true)
            .set { fastaGunzipChannel }

        process gunzipFasta {
            tag "$fasta"

            input:
            file fasta from fastaGunzipChannel

            output:
            file "ref.fa" into fastaMapChannel,
                               fastaSnpChannel,
                               fastaCountChannel,
                               fastaRatesChannel,
                               fastaUtrRatesChannel,
                               fastaReadPosChannel,
                               fastaUtrPosChannel

            script:
            """
            gunzip -c $fasta > ref.fa
            """
        }
    } else {
        Channel
            .fromPath(params.fasta, checkIfExists: true)
            .into { fastaMapChannel
                    fastaSnpChannel
                    fastaCountChannel
                    fastaRatesChannel
                    fastaUtrRatesChannel
                    fastaReadPosChannel
                    fastaUtrPosChannel }
    }
} else {
    exit 1, "Fasta file not specified!"
}

if (!params.bed && !params.genome) exit 1, "Bed file not specified!"

if (!params.bed) {
    gtf = params.genome ? params.genomes[ params.genome ].gtf ?: false : false

    Channel
        .fromPath(gtf, checkIfExists: true)
        .ifEmpty { exit 1, "GTF annotation file not found: ${gtf}" }
        .set { gtfChannel }

    process gtf2bed {
        tag "$gtf"

        input:
        file gtf from gtfChannel

        output:
        file "*.bed" into utrFilterChannel,
                          utrCountChannel,
                          utrratesChannel,
                          utrposChannel

        script:
        """
        gtf2bed.py $gtf | sort -k1,1 -k2,2n > ${gtf.baseName}.3utr.bed
        """
    }
} else {
    Channel
        .fromPath(params.bed, checkIfExists: true)
        .ifEmpty { exit 1, "BED 3' UTR annotation file not found: ${params.bed}" }
        .into { utrFilterChannel
                utrCountChannel
                utrratesChannel
                utrposChannel }
}

// Read length must be supplied
if (!params.read_length) exit 1, "Read length must be supplied."

if (params.mapping) {
    Channel
        .fromPath(params.mapping, checkIfExists: true)
        .ifEmpty { exit 1, "Mapping file not found: ${params.mapping}" }
        .set { utrFilterChannel }
}

if (params.vcf) {
    Channel
        .fromPath(params.vcf, checkIfExists: true)
        .ifEmpty { exit 1, "Vcf file not found: ${params.vcf}" }
        .set { vcfChannel }
} else {
    Channel
        .empty()
        .set { vcfChannel }
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$baseDir/docs/images/", checkIfExists: true)

/*
 * Create a channel for sample list
 */
Channel
    .fromPath(params.input, checkIfExists: true)
    .ifEmpty { exit 1, "input file not found: ${params.input}" }
    .set { checkChannel }

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
summary['Input']            = params.input
summary['Fasta Ref']        = params.fasta
summary['Vcf']              = params.vcf
summary['Trim 5']           = params.trim5
summary['Poly-A']           = params.polyA
summary['Multimappers']     = params.multimappers
summary['Quantseq']         = params.quantseq
summary['Endtoend']         = params.endtoend
summary['Minimum coverage'] = params.min_coverage
summary['Variant fraction'] = params.var_fraction
summary['Conversions']      = params.conversions
summary['base_quality']     = params.base_quality
summary['read_length']      = params.read_length
summary['P-value']          = params.pvalue
summary['Skip Trimming']    = params.skip_trimming
summary['Skip DESeq2']      = params.skip_deseq2
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-slamseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/slamseq Workflow Summary'
    section_href: 'https://github.com/nf-core/slamseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    trim_galore --version > v_trimgalore.txt
    slamdunk --version > v_slamdunk.txt
    echo \$(R --version 2>&1) > v_R.txt
    R -e 'packageVersion("DESeq2")' | grep "\\[1\\]" > v_DESeq2.txt
    multiqc --version > v_multiqc.txt
    varscan > v_varscan.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * Check design
 */
process checkDesign {
    tag "$design"

    input:
    file design from checkChannel

    output:
    file "*.txt" into rawFileChannel,
                      deseq2ConditionChannel,
                      splitChannel,
                      vcfSampleChannel

    script:
    """
    check_design.py $design nfcore_slamseq_design.txt
    """
}

rawFileChannel
    .splitCsv( header: true, sep: '\t' )
    .map { row -> tuple(row, file(row.reads, checkIfExists: true) ) }
    .set { rawFiles }

splitChannel
    .splitCsv( header: true, sep: '\t' )
    .set { conditionDeconvolution }

vcfSampleChannel
    .splitCsv( header: true, sep: '\t' )
    .map{ it -> return it.name }
    .combine(vcfChannel)
    .set{ vcfCombineChannel }

/*
 * STEP 1 - TrimGalore!
 */
if (params.skip_trimming) {
    rawFiles
        .map{ it -> return tuple(it, file(it.reads)) }
        .set{ trimmedFiles }
    trimgaloreQC = Channel.empty()
    trimgaloreFastQC = Channel.empty()
} else {
    process trim {
        tag "$meta.name"

        input:
        set val(meta), file(reads) from rawFiles

        output:
        set val(meta), file("TrimGalore/${meta.name}_trimmed.fq.gz") into trimmedFiles
        file ("TrimGalore/*.txt") into trimgaloreQC
        file ("TrimGalore/*.{zip,html}") into trimgaloreFastQC

        script:
        """
        mkdir -p TrimGalore
        trim_galore \\
            $reads \\
            --stringency 3 \\
            --fastqc \\
            --cores $task.cpus \\
            --output_dir TrimGalore \\
            --basename ${meta.name}
        """
    }
}

/*
 * STEP 2 - Map
 */
process map {
    tag "$meta.name"

    input:
    set val(meta), file(fastq) from trimmedFiles
    each file(fasta) from fastaMapChannel

    output:
    set val(meta.name), file("map/*bam") into slamdunkMap

    script:
    quantseq = params.quantseq ? "-q" : ""
    endtoend = params.endtoend ? "-e" : ""
    """
    slamdunk map \\
        -r $fasta \\
        -o map \\
        -5 $params.trim5 \\
        -n 100 \\
        -a $params.polyA \\
        -t $task.cpus \\
        --sampleName ${meta.name} \\
        --sampleType ${meta.type} \\
        --sampleTime ${meta.time} \\
        --skip-sam \\
        $quantseq \\
        $endtoend \\
        $fastq
    """
 }

 /*
  * STEP 3 - Filter
  */
process filter {
    tag "$name"
    label 'slamdunk_process'

    publishDir path: "${params.outdir}/slamdunk/bam", mode: 'copy',
               overwrite: 'true', pattern: "filter/*bam*",
               saveAs: { filename ->
                             if (filename.endsWith(".bam")) file(filename).getName()
                             else if (filename.endsWith(".bai")) file(filename).getName()
                       }

    input:
    set val(name), file(map) from slamdunkMap
    each file(bed) from utrFilterChannel

    output:
    set val(name), file("filter/*bam*") into slamdunkFilter,
                                             slamdunkCount,
                                             slamdunkFilterSummary

    script:
    multimappers = params.multimappers ? "-b ${bed}" : ""
    """
    slamdunk filter \\
        -o filter \\
        $multimappers \\
       -t $task.cpus \\
       $map
    """
}

/*
 * STEP 4 - Snp
 */
process snp {
    tag "$name"
    publishDir path: "${params.outdir}/slamdunk/vcf", mode: 'copy',
               overwrite: 'true', pattern: "snp/*vcf",
               saveAs: { it.endsWith(".vcf") ? file(it).getName() : it }

    input:
    set val(name), file(filter) from slamdunkFilter
    each file(fasta) from fastaSnpChannel

    output:
    set val(name), file("snp/*vcf") into slamdunkSnp

    when:
    !params.vcf && !params.quantseq

    script:
    """
    slamdunk snp \\
        -o snp \\
        -r $fasta \\
        -c $params.min_coverage \\
        -f $params.var_fraction \\
        -t $task.cpus \\
        ${filter[0]}
    """
}

vcfComb = slamdunkSnp.mix(vcfCombineChannel)

// Join by column 3 (reads)
slamdunkCount
    .join(vcfComb)
    .into { slamdunkResultsChannel
            slamdunkForRatesChannel
            slamdunkForUtrRatesChannel
            slamdunkForTcPerReadPosChannel
            slamdunkForTcPerUtrPosChannel }

/*
 * STEP 5 - Count
 */
process count {
    tag "$name"
    label 'slamdunk_process'

    publishDir path: "${params.outdir}/slamdunk/count/utrs", mode: 'copy',
               overwrite: 'true', pattern: "count/*.tsv",
               saveAs: { it.endsWith(".tsv") ? file(it).getName() : it }

    input:
    set val(name), file(filter), file(snp) from slamdunkResultsChannel
    each file(bed) from utrCountChannel
    each file(fasta) from fastaCountChannel

    output:
    set val(name), file("count/*tsv") into slamdunkCountOut,
                                           slamdunkCountAlleyoop

    when:
    !params.quantseq

    script:
    snpMode = params.vcf ? "-v $params.vcf" : "-s . "
    """
    slamdunk count -o count \\
        -r $fasta \\
        $snpMode \\
        -b $bed \\
        -l $params.read_length \\
        -c $params.conversions \\
        -q $params.base_quality \\
        -t $task.cpus \\
        ${filter[0]}
    """
}

/*
 * STEP 6 - Collapse
 */
process collapse {
    tag "$name"
    label 'slamdunk_process'

    publishDir path: "${params.outdir}/slamdunk/count/genes", mode: 'copy',
               overwrite: 'true', pattern: "collapse/*.csv",
               saveAs: { it.endsWith(".csv") ? file(it).getName() : it }

    input:
    set val(name), file(count) from slamdunkCountOut

    output:
    set val(name), file("collapse/*csv") into slamdunkCollapseOut

    when:
    !params.quantseq

    script:
    """
    alleyoop collapse \\
        -o collapse \\
        -t $task.cpus \
        $count
    sed -i "1i# name:${name}" collapse/*csv
    """
}

/*
 * STEP 7 - rates
 */
process rates {
    tag "$name"
    label 'slamdunk_process'

    input:
    set val(name), file(filter), file(snp) from slamdunkForRatesChannel
    each file(fasta) from fastaRatesChannel

    output:
    file("rates/*csv") into alleyoopRatesOut

    when:
    !params.quantseq

    script:
    """
    alleyoop rates \\
        -o rates \\
        -r $fasta \\
        -mq $params.base_quality \\
        -t $task.cpus \\
        ${filter[0]}
    """
}

/*
 * STEP 8 - utrrates
 */
process utrrates {
    tag "$name"
    label 'slamdunk_process'

    input:
    set val(name), file(filter), file(snp) from slamdunkForUtrRatesChannel
    each file(fasta) from fastaUtrRatesChannel
    each file(bed) from utrratesChannel

    output:
    file("utrrates/*csv") into alleyoopUtrRatesOut

    when:
    !params.quantseq

    script:
    """
    alleyoop utrrates \\
        -o utrrates \\
        -r $fasta \\
        -mq $params.base_quality \\
        -b $bed \\
        -l $params.read_length \\
        -t $task.cpus \\
        ${filter[0]}
    """
}

/*
 * STEP 9 - tcperreadpos
 */
process tcperreadpos {
    tag "$name"
    label 'slamdunk_process'

    input:
    set val(name), file(filter), file(snp) from slamdunkForTcPerReadPosChannel
    each file(fasta) from fastaReadPosChannel

    output:
    file("tcperreadpos/*csv") into alleyoopTcPerReadPosOut

    when:
    !params.quantseq

    script:
    snpMode = params.vcf ? "-v $params.vcf" : "-s . "
    """
    alleyoop tcperreadpos \\
        -o tcperreadpos \\
        -r $fasta \\
        $snpMode \\
        -mq $params.base_quality \\
        -l $params.read_length \\
        -t $task.cpus \\
        ${filter[0]}
    """
}

/*
 * STEP 10 - tcperutrpos
 */
process tcperutrpos {
    tag "$name"
    label 'slamdunk_process'

    input:
    set val(name), file(filter), file(snp) from slamdunkForTcPerUtrPosChannel
    each file(fasta) from fastaUtrPosChannel
    each file(bed) from utrposChannel

    output:
    file("tcperutrpos/*csv") into alleyoopTcPerUtrPosOut

    when:
    !params.quantseq

    script:
    snpMode = params.vcf ? "-v $params.vcf" : "-s . "
    """
    alleyoop tcperutrpos \\
        -o tcperutrpos \\
        -r $fasta \\
        -b $bed \\
        $snpMode \\
        -mq $params.base_quality \\
        -l $params.read_length \\
        -t $task.cpus \\
        ${filter[0]}
    """
}

slamdunkFilterSummary
    .flatten()
    .filter( ~/.*bam$/ )
    .collect()
    .set { slamdunkFilterSummaryCollected }

slamdunkCountAlleyoop
    .collect()
    .flatten()
    .filter( ~/.*tsv$/ )
    .collect()
    .set { slamdunkCountAlleyoopCollected }

/*
 * STEP 11 - Summary
 */
process summary {

    input:
    file("filter/*") from slamdunkFilterSummaryCollected
    file("count/*") from slamdunkCountAlleyoopCollected.ifEmpty([])

    output:
    file("summary*.txt") into summaryQC

    script:
    countFolderFlag = !params.quantseq ? "-t ./count" : ""
    """
    alleyoop summary \\
        -o summary.txt \\
        $countFolderFlag \\
        ./filter/*bam
    """
}

conditionDeconvolution
    .map { it -> return tuple(it.name, it.group) }
    .join(slamdunkCollapseOut)
    .map { it -> return tuple(it[1],it[2]) }
    .groupTuple()
    .set { deseq2FileChannel }

/*
 * STEP 12 - DESeq2
 */
process deseq2 {
    label 'slamdunk_process'

    publishDir path: "${params.outdir}/deseq2", mode: 'copy', overwrite: 'true'

    input:
    file (conditions) from deseq2ConditionChannel.collect()
    set val(group), file("counts/*") from deseq2FileChannel

    output:
    file("${group}") optional true into deseq2out

    when:
    !params.quantseq && !params.skip_deseq2

    script:
    """
    deseq2_slamdunk.r -t $group -d $conditions -c counts -p $params.pvalue -O $group
    """
}

/*
 * STEP 13 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/multiqc", mode: 'copy'

    input:
    file (multiqc_config) from ch_multiqc_config
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    file("rates/*") from alleyoopRatesOut.collect().ifEmpty([])
    file("utrrates/*") from alleyoopUtrRatesOut.collect().ifEmpty([])
    file("tcperreadpos/*") from alleyoopTcPerReadPosOut.collect().ifEmpty([])
    file("tcperutrpos/*") from alleyoopTcPerUtrPosOut.collect().ifEmpty([])
    file(summary) from summaryQC
    file ("TrimGalore/*") from trimgaloreQC.collect().ifEmpty([])
    file ("TrimGalore/*") from trimgaloreFastQC.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    """
    multiqc -m fastqc -m cutadapt -m slamdunk -f $rtitle $rfilename $custom_config_file .
    """
}

/*
 * STEP 14 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs
    file images from ch_output_docs_images

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/slamseq] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/slamseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/slamseq] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/slamseq] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/slamseq] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/slamseq] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/slamseq]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/slamseq]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/slamseq v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
