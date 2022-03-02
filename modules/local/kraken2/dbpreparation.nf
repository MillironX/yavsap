process KRAKEN2_DBPREPARATION {
    tag "$db"
    label 'process_low'

    conda (params.enable_conda ? "bioconda::sed=4.7" : null)
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://containers.biocontainers.pro/s3/SingImgsRepo/biocontainers/v1.2.0_cv1/biocontainers_v1.2.0_cv1.img':
        'quay.io/biocontainers/biocontainers:v1.2.0_cv1' }"

    input:
    path db

    output:
    path "${dbname}", emit: db
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    dbname = db.getSimpleName()
    """
    find . -name "*.tar.gz" -exec tar -xvf {} \\;
    find . -name "*.tgz" -exec tar -xvf {} \\;
    mkdir ${dbname}
    find . -name "*.k2d" -exec mv {} ${dbname} \\;

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        tar: \$(echo \$(tar --version 2>&1) | sed 's/^.*(GNU tar) //; s/ Copyright.*\$//')
    END_VERSIONS
    """
}
