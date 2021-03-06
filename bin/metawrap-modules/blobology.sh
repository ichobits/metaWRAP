#!/bin/bash -l

##############################################################################################################################################################
#
# This script is a modified pipeline from the program 'BLOBOLOGY', which produces a GC vs Coverage plot of the contigs, helping visualize bins and phylogenetic 
# composition.The original script has been modified to be better suited for running on clusters.
#
# Author of original pipeline: Sujai Kumar (https://github.com/blaxterlab). Author of modifications: German Uritskiy. I do not take any credit for the original pipeline.
# For questions, bugs, and suggestions, contact German Uritskiy at guritsk1@jhu.edu.
# 
##############################################################################################################################################################



help_message () {
	echo ""
	echo "Usage: metaWRAP blobology [options] -a assembly.fasta -o output_dir readsA_1.fastq readsA_2.fastq [readsB_1.fastq readsB_2.fastq ... ]"
	echo "Options:"
	echo ""
	echo "	-a STR		assembly fasta file"
	echo "	-o STR          output directory"
	echo "	-t INT          number of threads"
	echo ""
	echo "	--subsamble 	INT	Number of contigs to run blobology on. Subsampling is randomized. (default=ALL)"
	echo "	--bins		STR	Folder containing bins. Contig names must match those of the assembly file. (default=None)"
	echo "";}

comm () { ${SOFT}/print_comment.py "$1" "-"; }
error () { ${SOFT}/print_comment.py "$1" "*"; exit 1; }
warning () { ${SOFT}/print_comment.py "$1" "*"; }
announcement () { ${SOFT}/print_comment.py "$1" "#"; }


########################################################################################################
########################               LOADING IN THE PARAMETERS                ########################
########################################################################################################


# setting scripts and databases from config file (should be in same folder as main script)
source config-metawrap

# Set defaults
threads=1; out="false"; n_contigs=1000000000; 
ASSEMBLY="false"; bin_folder=false

# load in params
OPTS=`getopt -o ht:o:a: --long help,bins,subsample -- "$@"`
# make sure the params are entered correctly
if [ $? -ne 0 ]; then help_message; exit 1; fi

# loop through input params
while true; do
        case "$1" in
                -t) threads=$2; shift 2;;
                -o) out=$2; shift 2;;
                -a) ASSEMBLY=$2; shift 2;;
                -h | --help) help_message; exit 1; shift 1;;
                --bins) bin_folder=$2; shift 2;;
                --subsample) n_contigs=$2; shift 2;;
                --) help_message; exit 1; shift; break ;;
                *) break;;
        esac
done



######################################################################################################o#
########################           MAKING SURE EVERYTHING IS SET UP             ########################
########################################################################################################

# check if all parameters are entered
if [ "$out" = "false" ] || [ "$ASSEMBLY" = "false" ]; then 
	help_message; exit 1
fi

# Checks for correctly configures meta-scripts folder
if [ ! -s $SOFT/sort_contigs.py ]; then
	error "The folder $SOFT doesnt exist. Please make sure the meta-scripts folder path is correctly set in config.sh file"
fi

#  Checks for NCBI_nt database for BLAST
if [ ! -f "${BLASTDB}/nt.00.nhd" ]; then
	error "The file ${BLASTDB}/nt.00.nhd doesnt exist, which likely means that you havent set the correct path to your NCBI_nt database or\
	 havent downloaded it. Please look and the the script and manually set the correct path to NCBI_nt, and follow these steps to download the\
	  database: wget ftp://ftp.ncbi.nlm.nih.gov/blast/db/nt.*.tar.gz; for a in nt.*.tar.gz; do tar xzf $a; done"
fi

#  Checks for NCBI_tax database for BLAST
if [ ! -f "${TAXDUMP}/citations.dmp" ]; then
	error "The file ${TAXDUMP}/citations.dmp doesnt exist, which likely means that you havent set the correct path to your NCBI_tax database,\
	 or havent downloaded it yet. Please look and the the script and manually set the correct path to NCBI_tax, and follow these steps to download \
	 the database: wget ftp://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz; tar -xvf taxdump.tar.gz;"
fi


# check for at least one pair of read fastq files:
F="no"; R="no"
for num in "$@"; do
	if [[ $num == *"_1.fastq" ]]; then F="yes"; fi
	if [[ $num == *"_2.fastq" ]]; then R="yes"; fi
done
if [ $F = "no" ] || [ $R = "no" ]; then
	comm "Unable to find proper fastq read pair in the format *_1.fastq and *_2.fastq"
	help_message; exit 1
fi

#determine number of fastq read files provided:
num_of_F_read_files=$(for I in "$@"; do echo $I | grep _1.fastq; done | wc -l)
num_of_R_read_files=$(for I in "$@"; do echo $I | grep _2.fastq; done | wc -l)

comm "$num_of_F_read_files forward and $num_of_R_read_files reverse read files detected"
if [ ! $num_of_F_read_files == $num_of_R_read_files ]; then error "Number of F and R reads must be the same!"; fi



########################################################################################################
########################                    BEGIN PIPELINE!                     ########################
########################################################################################################



########################################################################################################
########################       ASIGN TAXONOMY TO CONTIGS WITH MEGABLAST         ########################
########################################################################################################
announcement "ASIGN TAXONOMY TO CONTIGS WITH MEGABLAST"


if [ ! -d $out ]; then
        mkdir $out;
else
        echo "Warning: $out already exists."
fi

assembly=${ASSEMBLY##*/}
SAMPLE=${assembly%.*}

## the following command selects desired number of contigs at random to classify and plot:
comm "Choosing $n contigs from $ASSEMBLY"
${SOFT}/blobology/fastaqual_select.pl -f $ASSEMBLY -s r -n $n_contigs > ${out}/$assembly

comm "Running MEGABLAST on $assembly"
if [[ ! -s ${out}/${SAMPLE}.nt.1e-5.megablast ]] ; then
	blastn -task megablast -query ${out}/$assembly -db ${BLASTDB}/nt\
	 -evalue 1e-5 -num_threads $threads -max_target_seqs 1 -outfmt '6 qseqid sseqid staxids'\
	 | cut -f 1,3 > ${out}/${SAMPLE}.nt.1e-5.megablast
fi

if [[ ! -s ${out}/${SAMPLE}.nt.1e-5.megablast ]] ; then 
	error "Something went wrong with asigning taxonomy to contigs with megablast. Exiting";
fi


########################################################################################################
########################          MAP READS TO ASSEMBLY WITH BOWTIE2            ########################
########################################################################################################
announcement "MAP READS TO ASSEMBLY WITH BOWTIE2"

comm "Indexing ${out}/$assembly"
bowtie2-build -q ${out}/$assembly ${out}/$assembly

for arg in "$@"; do
        if [[ $arg == *"_1.fastq" ]]; then
		f_reads=$arg
		r_reads=${arg%_*}_2.fastq
	
		if [ ! -s $f_reads ]; then error "$f_reads file does not exist. Exiting..."; fi
		if [ ! -s $r_reads ]; then error "$r_reads file does not exist. Exiting..."; fi
	
		base=${arg##*/}
		sample=${base%_*}

		comm "Now processing sample $sample ... Aligning $f_reads and $r_reads to ${out}/$assembly with bowtie2"

		${SOFT}/blobology/shuffleSequences_fastx.pl 4 <(cat $f_reads) <(cat $r_reads) > ${out}/tmp
		if [[ $? -ne 0 ]]; then error "Something went wrong with shuffling reads. Exiting..."; fi
		
		bowtie2 -x ${out}/$assembly --very-fast-local -k 1 -t -p $threads --reorder --mm -U ${out}/tmp\
		 | samtools view -S -b -@ $threads - > ${out}/${sample}.bowtie2.bam
		if [[ $? -ne 0 ]]; then error "Failed to run bowtie2 on sample $sample reads. Exiting..."; fi
		rm ${out}/tmp

		if [[ ! -s ${out}/${sample}.bowtie2.bam ]] ; then
			error "Something went wrong with aligning reads from sample $sample back to the contigs with bowtie2. Exiting.";
		fi
	fi
done


########################################################################################################
########################     MAKE BLOB FILE FROM BLAST AND BOWTIE2 OUTPUTS      ########################
########################################################################################################
announcement "MAKE BLOB FILE FROM BLAST AND BOWTIE2 OUTPUT"

${SOFT}/blobology/gc_cov_annotate.pl --blasttaxid ${out}/${SAMPLE}.nt.1e-5.megablast\
 --assembly ${out}/$assembly --bam ${out}/*.bowtie2.bam\
 --out ${out}/${SAMPLE}.blobplot --taxdump $TAXDUMP --taxlist species genus family order subclass phylum superkingdom
if [[ ! -s ${out}/${SAMPLE}.blobplot ]]; then 
	error "Something went wrong with making the blob file from the .bam and .megablast files. Exiting."; fi
comm "blobplot text file saved to ${out}/${SAMPLE}.blobplot"

if [ ! "$bin_folder" = false ]; then
	comm "adding bin annotations to blobfile ${out}/${SAMPLE}.blobplot"
	${SOFT}/add_bins_to_blobplot.py ${out}/${SAMPLE}.blobplot $bin_folder > ${out}/${SAMPLE}.binned.blobplot
	
	if [[ $? -ne 0 ]]; then error "Something went wrong with annotating the blobplot by bins. Exiting..."; fi

	if [ $(cut -f12 ${out}/${SAMPLE}.binned.blobplot | grep -v "Unbinned" | wc -l) -lt 2 ]; then 
		warning "No contigs matches were found in the bins privided. The blobplot will not be annotated with bins."
		rm ${out}/${SAMPLE}.binned.blobplot
		$bin_folder=false
	else
		mv ${out}/${SAMPLE}.binned.blobplot ${out}/${SAMPLE}.blobplot
		grep -v "Unbinned" ${out}/${SAMPLE}.blobplot > ${out}/${SAMPLE}.binned.blobplot
	fi
fi

########################################################################################################
########################              MAKE FINAL BLOBPLOT IMAGES                ########################
########################################################################################################
announcement "MAKE FINAL BLOBPLOT IMAGES"

comm "making blobplots with phylogeny annotations (order, phylum, and superkingdom)."
${SOFT}/blobology/makeblobplot.R ${out}/${SAMPLE}.blobplot 0.005 taxlevel_order
if [[ $? -ne 0 ]]; then error "Something went wrong with making the order bloblot image. Exiting..."; fi

${SOFT}/blobology/makeblobplot.R ${out}/${SAMPLE}.blobplot 0.005 taxlevel_phylum
if [[ $? -ne 0 ]]; then error "Something went wrong with making the phylum blobplot image. Exiting..."; fi
${SOFT}/blobology/makeblobplot.R ${out}/${SAMPLE}.blobplot 0.005 taxlevel_superkingdom
if [[ $? -ne 0 ]]; then error "Something went wrong with making the superkingdom blobplot image. Exiting..."; fi

## The output file blobplot.txt can also be loaded into Blobsplorer - see github.com/mojones/blobsplorer
if [[ ! -s ${out}/${SAMPLE}.blobplot.taxlevel_phylum.png ]]; then 
	error "Something went wrong with making the plots from the blob file. Exiting."; 
fi

if [ ! "$bin_folder" = false ]; then
	comm "making blobplot image with bin annotations"
	${SOFT}/blobology/makeblobplot_with_bins.R ${out}/${SAMPLE}.blobplot 0.005 bin
	if [[ $? -ne 0 ]]; then error "Something went wrong with making the blobplot image with bin annotations. Exiting..."; fi

	${SOFT}/blobology/makeblobplot_with_bins.R ${out}/${SAMPLE}.blobplot 0.005 binned_yes_no
	if [[ $? -ne 0 ]]; then error "Something went wrong with making the blobplot image with binned yes/no annotations. Exiting..."; fi

	${SOFT}/blobology/makeblobplot_with_bins.R ${out}/${SAMPLE}.blobplot 0.005 binned_phylum
	if [[ $? -ne 0 ]]; then error "Something went wrong with making the blobplot image with binned phylum annotations. Exiting..."; fi
	

	comm "making blobplot images of only the contigs taht were binned"
	${SOFT}/blobology/makeblobplot_with_bins.R ${out}/${SAMPLE}.binned.blobplot 0.01 bin
	if [[ $? -ne 0 ]]; then error "Something went wrong with making the blobplot image with bin annotations. Exiting..."; fi

	comm "making blobplots of only binned contigs with phylogeny annotations (order, phylum, and superkingdom)."
	${SOFT}/blobology/makeblobplot.R ${out}/${SAMPLE}.binned.blobplot 0.005 taxlevel_order
	if [[ $? -ne 0 ]]; then error "Something went wrong with making the binned order blobplot image. Exiting..."; fi
	
	${SOFT}/blobology/makeblobplot.R ${out}/${SAMPLE}.binned.blobplot 0.005 taxlevel_phylum
	if [[ $? -ne 0 ]]; then error "Something went wrong with making the binned phylum blobplot image. Exiting..."; fi

	${SOFT}/blobology/makeblobplot.R ${out}/${SAMPLE}.binned.blobplot 0.005 taxlevel_superkingdom
	if [[ $? -ne 0 ]]; then error "Something went wrong with making the binned superkingdom blobplot image. Exiting..."; fi
fi

########################################################################################################
########################      BLOBPLOT PIPELINE FINISHED SUCCESSFULLY!!!        ########################
########################################################################################################
announcement "BLOBPLOT PIPELINE FINISHED SUCCESSFULLY!!!"
