#!/bin/bash

MapToNewName="TRUE"
MapToNewName="F"
export LANG=en_US.UTF-8; export LC_ALL=$LANG
bRM="T"
bCP_SCP="F"
tmpdir=""
ANAL=""
bNorm="T"
STAGE=0
STAGE_LAST=1000000   # 50 - 1stage.cmllr

bPHX_CRBE=false

#### Defaults #####
NN_STARTFRMEXT=15
NN_ENDFRMEXT=15

NNname_2stage=2stageAdaptNN
bPrintFirstPass=T

for i in $*; do
    case "$1" in
        -system-cfg)
            SYSTEM_CFG=$2
            shift
            shift
            ;;
	-rm)
	    bRM=$2
	    shift
	    shift
	    ;;
	-bMapToNewName)
	    MapToNewName="TRUE"
	    shift
	    ;;
	-tempdir | -tmpdir)
	    tmpdir=$2
	    mkdir -p $tmpdir
            shift
            shift
            ;;
	-anal) 
	    ANAL=$2
	    if [ ! -r $ANAL ]; then
		echo cannot open $ANAL; exit 1;
	    fi
	    shift
            shift
            ;;
	-wavname | -tag)
	    TAG=$2
	    shift
	    shift
	    ;;
	-cp-scp)
	    bCP_SCP=$2
	    shift
	    shift
	    ;;
	-stage)
	    STAGE=$2
	    shift
	    shift
	    ;;
	-stage-final | -stage-last | -last-stage | -stage_last)
	    STAGE_LAST=$2
	    shift
            shift
            ;;
	-fea-crbe)
	    fea_crbe=$2
	    shift
            shift
            ;;
#        -*)
#            echo Unknown option $1
#            exit
#            ;;
        *)
            break
            ;;
    esac
done

#use this on speech data
if [ $# != 2 ]; then 
  echo $0 WAV_file OUTDIR; exit 1;
fi

WFORM=$1
OUTDIR=${2:?}


#change PWD in SGE
echo PWD:$PWD
[ -d "$SGE_O_WORKDIR" ] && cd $SGE_O_WORKDIR
echo SGE_O_WORKDIR:$SGE_O_WORKDIR
echo PWD:$PWD

#---
ROOTDIR=${0%/*}
ROOTDIR=/mnt/matylda3/karafiat/BABEL/tasks/FeatureExtraction.BUTv3_Y4

BINDIR=$ROOTDIR/bin
#STKDIR=$ROOTDIR/bin/STK/bin
#HTKDIR=$ROOTDIR/bin/HTK/bin ## Linked into bin
TOOLDIR=$ROOTDIR/tools

# -- Kaldi
export KALDI_ROOT=/mnt/matylda3/karafiat/BABEL/GIT/Kaldi
[ -f $KALDI_ROOT/tools/env.sh ] && . $KALDI_ROOT/tools/env.sh
export PATH=$KALDI_ROOT/egs/wsj/s5/utils/:$KALDI_ROOT/tools/openfst/bin:$PWD:$PATH
[ ! -f $KALDI_ROOT/tools/config/common_path.sh ] && echo >&2 "The standard file $KALDI_ROOT/tools/config/common_path.sh is not present -> Exit!" && exit 1
. $KALDI_ROOT/tools/config/common_path.sh
export LC_ALL=C

KALDI_STEPS=$KALDI_ROOT/egs/wsj/s5/steps

#---------------------
#   System settings
# --------------------

if [ -z $SYSTEM_CFG ]; then
    SYSTEM_CFG=$ROOTDIR/systems/MultRDTv0.ENV  # Default
    echo "Setting up defaut Language environment to $SYSTEM_CFG"
fi

if [ -e $SYSTEM_CFG ]; then
    echo "Sourcing system definition cfg $SYSTEM_CFG"
    source $SYSTEM_CFG
else
    echo "ERROR: $0: Environment configuration file $SYSTEM_CFG is missing!!"
    exit 1
fi

echo "Program $0 started at $(date) on $HOSTNAME";
###########################################################################

# Make dirs
[ -z $tmpdir ] && TMPDIR=$(mktemp -d) || TMPDIR=$tmpdir
echo TMPDIR $TMPDIR

#SCPDIR=$OUTDIR/lib/flists
#VADDIR=$OUTDIR/VAD
#FEADIR=$OUTDIR/features
SCPDIR=$TMPDIR/lib/flists
VADDIR=$TMPDIR/VAD
FEADIR=$TMPDIR/features
mkdir -p $OUTDIR $SCPDIR $VADDIR $FEADIR $TMPDIR
# ----------------

#root of the file name
if [ -z $TAG ]; then
    TAG=${WFORM##*/}; TAG=${TAG%.*}
fi


if [ "$WFORM" == "-" ]; then
    echo "$0: waveform is read from /dev/stdin"
    [ -z $TAG ] && "ERROR: $0: -wavname is not defined"
    [ -z $TAG ] && exit 1
    sox -t wav /dev/stdin -t wav $TMPDIR/file.wav
    WFORM=$TMPDIR/file.wav
fi


# Map into new name if needed
TAG_ORIG=$TAG
if [ "$MapToNewName" == "TRUE" ];then
   echo  $WFORM | sed 's/\(.*\/\)\(.*\)/\1\2 \2/;s/\.sph$/ sph/;s/\.wav$/ wav/;s/\.raw$/ raw/;s/\.flac$/ flac/'| awk '{name=$2;tmp="echo " $2 " | openssl md5 | cut -f2 -d\" \""; tmp | getline cksum; $2=cksum" "name; print }'  |awk -v AD=$TMPDIR '{print "ln -s " $1" " AD"/"$2"."$4}' > $TMPDIR/audio_lnk.sh
   chmod u+x $TMPDIR/audio_lnk.sh
   $TMPDIR/audio_lnk.sh
   WFORM=`head -1 $TMPDIR/audio_lnk.sh |awk '{print $4}'`
   TAG=${WFORM##*/}; TAG=${TAG%.*}
fi



if [ ! -r $WFORM ]; then
  echo cannot open $WFORM; exit 1;
fi

if [ ! -d $OUTDIR ]; then mkdir -p $OUTDIR; fi

if [ $WFORM == ${WFORM//\//} ]; then WFORM=$PWD/$WFORM; fi



#normalize features
percents=$(awk 'BEGIN{ l=length("'$TAG'"); for(i=0;i<l;i++) { str=str"%" }; print str;}')
MASK="$percents*"
MASK_NOSEG="*/$percents.???"



echo "Running VAD with using $VADBIN"
#sox $WFORM -t raw -r 8000 -s -w -c 1 $TMPDIR/$TAG.raw || { echo "ERROR"; exit 1; }
###########################################################################
################ Make Segmentation
###########################################################################

VADlabel=${VADlabel:-VAD}
VADfrmext=${VADfrmext:-0}
VADminspace=${VADminspace:-0}

outfile=$VADDIR/$TAG.txt
log=$VADDIR/$TAG.log
mkdir -p $VADDIR/logs
if [ ! -e $log.gz ]; then
    bRunneed="T"
    touch $outfile
    echo $VADBIN $WFORM $outfile
    if [ ! -e $log.gz ]; then if eval $VADBIN $WFORM $outfile > $log 2>&1; then gzip $outfile $log; fi; fi
fi

if [ ! -e $outfile.gz ]; then
    echo "ERROR: VAD was not computed. Check $log"
    exit 1
fi

gunzip -c $outfile | awk -v name=$TAG '{Start=$3; End=$4; print name " A " Start " " End-Start " <SPEECH>"}' > $VADDIR/$TAG.ctm
echo -n "$outfile "; gunzip -c $outfile | grep -c '<SPEECH>' > $VADDIR/$TAG.speechcounts

# ----------------------------------
# Kaldi Data Dir 
# ----------------------------------
datadir=$TMPDIR/data/$TAG/
mkdir -p $datadir

gzcat $VADDIR/$TAG.txt.gz > $datadir/segments
echo "$TAG $WFORM" >  $datadir/wav.scp
awk '{print $1 " " $2}' $datadir/segments > $datadir/utt2spk
utt2spk_to_spk2utt.pl   $datadir/utt2spk > $datadir/spk2utt

# ----------------------------------
# HTK SCP 
# ----------------------------------
audiodir=${WFORM%/*}
cat $VADDIR/$TAG.ctm | awk '$NF=="<SPEECH>"' | \
    $TOOLDIR/ctm2mlf.awk | $TOOLDIR/mlf.GenLabList.sh -    | \
    awk -v audiodir=$audiodir -v frmext=$VADfrmext 'BEGIN{SilExtension=frmext}
{gsub(".lab$","",$1); seg=$1;spkr_unmap=$1;
     nS=split(seg,S,"[_-]"); StartFrame=S[nS-1];EndFrame=S[nS];
     StartFrame-=SilExtension;EndFrame+=SilExtension; if(StartFrame<0) StartFrame=0;
     gsub("-[[:digit:]]+-[[:digit:]]+$","",spkr_unmap); gsub("^_+","",spkr_unmap);
     print seg ".wav=" audiodir "/" spkr_unmap ".wav[" StartFrame "," EndFrame "]";
     #if ( spkr_unmap in MAP ){
     #  print seg ".raw=" MAP[spkr_unmap] "[" StartFrame "," EndFrame "]";
     #}else{
     #   print spkr_unmap  " is not in mapping file" > "/dev/stderr"; exit
     #}
}' /dev/stdin > $SCPDIR/$TAG.wav.scp_uncorr

$TOOLDIR/scp.CorrectLengh.audio.wav.sh $SCPDIR/$TAG.wav.scp_uncorr > $SCPDIR/$TAG.wav.scp 2> $SCPDIR/$TAG.wav.corr.LOG
# ----------------



if [ ! -s $SCPDIR/$TAG.wav.scp  ]; then
    echo "WARNING: $SCPDIR/$TAG.wav.scp is empty, normalization is switch-off" 
    bNorm="F"
fi

function MakeSCP()
{
    feakind=$1
    feaext=$2
    
    local scpwav=$SCPDIR/$TAG.wav.scp
    local feadir=$FEADIR/$feakind

    #echo "sed \"s:=.*/:=$feadir/:;s:\.[^.]\+\([\[=]\):.$feaext\1:\" $scpwav" > /dev/stderr
    sed "s:=.*/:=$feadir/:;s:\.[^.]\+\([=[]\):.$feaext\1:g" $scpwav  
}


if [ $bCP_SCP == "T" ]; then
    mkdir -p $OUTDIR
    cat  $SCPDIR/$TAG.wav.scp >  $OUTDIR/$TAG.wav.scp
fi

###########################################################################
################ PLP
###########################################################################
if [ $STAGE -le 5 ] && [ $STAGE_LAST -ge 5 ]; then

feakind=plp
feadir=$FEADIR/$feakind
#MakeSCP $feakind plp > $SCPDIR/$TAG.$feakind.scp

echo "Make plp" 
[ ! -e $feadir ] && cp -r $datadir $feadir
log=$feadir/feats.log
cfg=$CFG_PLP


if [ ! -e $log.gz ]; then 
    echo "compute-plp-feats --verbose=2 --config=$cfg scp:$datadir/wav.scp ark,scp:$feadir/feats.ark,$feadir/feats.scp" > $log 
       if compute-plp-feats --verbose=2 --config=$cfg scp:$datadir/wav.scp ark,scp:$feadir/feats.ark,$feadir/feats.scp >> $log 2>&1; then gzip $log; fi
else
    echo "compute-plp-feats already done.. Skipped"
fi


if [ -e $log ]; then
    echo "ERROR: compute-plp-feats: check $log"
    exit 1
fi

echo "Computer CMVN stats" 


if [ "$bNorm" == "T" ]; then
    # Direct 
    ! compute-cmvn-stats --spk2utt=ark:$feadir/spk2utt ark:"extract-feature-segments --snip-edges=false --min-segment-length=0.025 --max-overshoot=0.025 scp:$feadir/feats.scp $feadir/segments ark:- |" ark,scp:$feadir/cmvn.ark,$feadir/cmvn.scp \
	2> $feadir/cmvn.log && echo "Error computing CMVN stats, see $feadir/cmvn.log" && exit 1;
    # _D_A_T
    ! compute-cmvn-stats --spk2utt=ark:$feadir/spk2utt ark:"extract-feature-segments --snip-edges=false --min-segment-length=0.025 --max-overshoot=0.025 scp:$feadir/feats.scp $feadir/segments ark:- | add-deltas --delta-order=3 ark:- ark:- |" ark,scp:$feadir/cmvn.52d.ark,$feadir/cmvn.52d.scp \
	2> $feadir/cmvn.52d.log && echo "Error computing CMVN 52d stats, see $feadir/cmvn.52d.log" && exit 1;
else
    dim=`feat-to-dim scp:$feadir/feats.scp -`
    # Direct
    ! cat $feadir/spk2utt |\
 awk -v dim=$dim '{
 print $1, "["; for (n=0; n < dim; n++) { printf("0 "); } print "1";
 for (n=0; n < dim; n++) { printf("1 "); } print "0 ]";
}' | \
    copy-matrix ark:- ark,scp:$feadir/cmvn.ark,$cmvndir/cmvn.scp && \
    echo "Error creating fake CMVN stats" && exit 1;
    # _D_A_T
    ! cat $feadir/spk2utt |\
 awk -v dim=$((dim*3)) '{
 print $1, "["; for (n=0; n < dim; n++) { printf("0 "); } print "1";
 for (n=0; n < dim; n++) { printf("1 "); } print "0 ]";
}' | \
    copy-matrix ark:- ark,scp:$feadir/cmvn.52d.ark,$cmvndir/cmvn.52d.scp && \
    echo "Error creating fake CMVN 52d stats" && exit 1;
fi

nc=`cat $feadir/cmvn.scp | wc -l` 
nu=`cat $feadir/spk2utt | wc -l` 
if [ $nc -ne $nu ]; then
  echo "$0: warning: it seems not all of the speakers got cmvn stats ($nc != $nu);"
  [ $nc -eq 0 ] && exit 1;
fi


    
# Get cvn norms for 52d stats (1/std)
copy-matrix scp:$feadir/cmvn.52d.scp ark,t:- |\
  awk '
NR==2{
 # mean stats
 dim=NF-1; N=$NF
 for(n=1; n < NF; n++) M[n]=$n/N
}
NR==3{
 # var stats
 floor=1e-20
 for(n=1; n <= dim; n++) {
   V[n]=$n/N - M[n]*M[n]
   if(V[n]<floor){
    print "WARNING: flooring " n " variance: " V[n] > "/dev/stderr"
    V[n]=floor
   }
 }
}
END{
 printf "[";
 for(n=1; n<=dim; n++){
   for(m=1; m<=dim; m++){ 
     printf " "; if(n==m){ printf 1/sqrt(V[n]) }else{ printf("0.0") }
   };
   printf "\n";
 }
printf " ]\n";
}' > $feadir/cvn_52d.mat
echo "Succeeded creating CMVN stats"
fi
###########################################################################
################ PLPHLDA
###########################################################################
if [ $STAGE -le 7 ] && [ $STAGE_LAST -ge 7 ]; then
    
    echo "Make plphlda"
    feakind_in=plp
    feakind=plphlda
    feadir_in=$FEADIR/$feakind_in
    feadir=$FEADIR/$feakind
    
    #MakeSCP $feakind fea > $SCPDIR/$TAG.$feakind.scp
    log=$feadir/feats.log
    [ ! -e $feadir ] && cp -r $datadir $feadir
    
    if [ ! -e $log.gz ]; then 
	if ( apply-cmvn --norm-means=true  --norm-vars=false scp:$feadir_in/cmvn.scp     scp:$feadir_in/feats.scp ark:- |\
    add-deltas --delta-order=3 ark:- ark:- |\
    transform-feats  $feadir_in/cvn_52d.mat ark:- ark,t:- |\
    transform-feats  $GLOBVAR_PLP ark:- ark:- |\
    transform-feats  $PLPHLDAMACROS ark:- ark,scp:$feadir/feats.ark,$feadir/feats.scp ) > $log 2>&1
	then 
	    gzip $log
	else
	    echo "HLDA: already done.. Skipped"
	fi
	
	if [ -e $log ]; then
	    echo "ERROR: PLP-HLDA: check $log"
	    exit 1
	fi

    fi
fi

###########################################################################
################ CRBE
###########################################################################

if [ $STAGE -le 10 ] && [ $STAGE_LAST -ge 10 ]; then


echo "Make CRBE"
feakind=fbank24_kf0pd

feadir=$FEADIR/$feakind
[ ! -e $feadir ] && cp -r $datadir $feadir

if [ ! -z $fea_crbe ] && [ -s $fea_crbe ]; then
    cp -r $fea_crbe $feadir
    touch $feadir/CrbeF0.log.gz
fi

cfg_fbank=$SYSTEMDIR/configs.kaldi/fbank24.conf
cfg_f0=$SYSTEMDIR/configs.kaldi/pitch.conf
log=$feadir/CrbeF0.log
if [ ! -e $log.gz ]; then
    fbank_feats="ark:compute-fbank-feats --verbose=2 --config=$cfg_fbank    scp:$datadir/wav.scp ark:- |"
    pitch_feats="ark:compute-kaldi-pitch-feats --verbose=2 --config=$cfg_f0 scp:$datadir/wav.scp ark:- | process-kaldi-pitch-feats ark:- ark:- |"
    
    
#      echo $TOOLDIR/create_xx_fbanks_f0m_f0mlog_f0sl_ffv_kf0d.pl -Nbands 24 $WFORM $feadir/$TAG.fea 
    if ( paste-feats --length-tolerance=2 "$fbank_feats" "$pitch_feats" ark:- |\
	copy-feats --compress=true ark:- \
	ark,scp:$feadir/feats.ark,$feadir/feats.scp ) > $log 2>&1 
    then
	gzip $log
    fi
else
    echo "CrbeF0: already done.. Skipped"
fi

if [ -e $log ]; then
    echo "ERROR: CrbeF0: Check $log"
    exit 1
fi

MakeSCP $feakind fea > $SCPDIR/$TAG.$feakind.scp

if [ "$bNorm" == "T" ]; then
    # Direct 
    ! compute-cmvn-stats --spk2utt=ark:$feadir/spk2utt ark:"extract-feature-segments --snip-edges=false --min-segment-length=0.025 --max-overshoot=0.025 scp:$feadir/feats.scp $feadir/segments ark:- |" ark,scp:$feadir/cmvn.ark,$feadir/cmvn.scp \
	2> $feadir/cmvn.log && echo "Error computing CMVN stats, see $feadir/cmvn.log" && exit 1;
else
    dim=`feat-to-dim scp:$feadir/feats.scp -`
    # Direct
    ! cat $feadir/spk2utt |\
 awk -v dim=$dim '{
 print $1, "["; for (n=0; n < dim; n++) { printf("0 "); } print "1";
 for (n=0; n < dim; n++) { printf("1 "); } print "0 ]";
}' | \
    copy-matrix ark:- ark,scp:$feadir/cmvn.ark,$cmvndir/cmvn.scp && \
    echo "Error creating fake CMVN stats" && exit 1;
fi

feakind_crbe=$feakind

fi

###########################################################################
################ NN
###########################################################################
if [ $STAGE -le 20 ] && [ $STAGE_LAST -ge 20 ]; then

echo "Make NN fea"
feakind_in=$feakind_crbe
feakind=sbn
feadir_in=$FEADIR/$feakind_in
feadir=$FEADIR/$feakind

use_gpu=no
nnet=$XFORMDIR_NN/macro_NN.nnet1


MakeSCP $feakind fea > $SCPDIR/$TAG.$feakind.scp
log=$feadir/bn-forward.log
[ ! -e $feadir ] && cp -r $datadir $feadir




if [ ! -e $log.gz ]; then 
    feats="ark:copy-feats scp:$feadir_in/feats.scp ark:- |"
    feats="$feats apply-cmvn --norm-means=true --norm-vars=false scp:$feadir_in/cmvn.scp ark:- ark:- |"
    
    if (
	    nnet-forward --verbose=2 $nnet_forward_opts --use-gpu=$use_gpu $nnet "$feats" \
		ark,scp:$feadir/feats.ark,$feadir/feats.scp ) > $log 2>&1; then 
	gzip $log
    fi
else
    echo "SFeaCat: NN: already done.. Skipped"
fi

if [ -e $log ]; then
    echo "ERROR: SFeaCat: Check $log"
    exit 1
fi

fi
###########################################################################
################ Concat plphlda + SBN 
###########################################################################
if [ $STAGE_LAST -ge 30 ]; then

echo "Concat fea ...."
feakind_in1=plphlda
feakind_in2=sbn
feakind=${feakind_in1}_${feakind_in2}

feadir_in1=$FEADIR/$feakind_in1
feadir_in2=$FEADIR/$feakind_in2
feadir=$FEADIR/$feakind

MakeSCP $feakind fea > $SCPDIR/$TAG.$feakind.scp
log=$feadir/concat-fea.log

[ ! -e $feadir ] && cp -r $datadir $feadir

if [ ! -e $log.gz ]; then
    fbank_feats="ark:scp:$datadir/wav.scp ark:- |"
    pitch_feats="ark:compute-kaldi-pitch-feats --verbose=2 --config=$cfg_f0 scp:$datadir/wav.scp ark:- | process-kaldi-pitch-feats ark:- ark:- |"

    if ( paste-feats --length-tolerance=2 scp:$feadir_in1/feats.scp scp:$feadir_in2/feats.scp ark:- |\
	copy-feats --compress=true ark:- \
	ark,scp:$feadir/feats.ark,$feadir/feats.scp ) > $log 2>&1 
    then
	gzip $log
    fi
else
    echo "Concat-fea: already done.. Skipped"
fi

if [ -e $log ]; then
    echo "ERROR: Concat-fea: Check $log"
    exit 1
fi


if [ "$bNorm" == "T" ]; then
    # Direct 
    ! compute-cmvn-stats --spk2utt=ark:$feadir/spk2utt ark:"extract-feature-segments --snip-edges=false --min-segment-length=0.025 --max-overshoot=0.025 scp:$feadir/feats.scp $feadir/segments ark:- |" ark,scp:$feadir/cmvn.ark,$feadir/cmvn.scp \
	2> $feadir/cmvn.log && echo "Error computing CMVN stats, see $feadir/cmvn.log" && exit 1;
else
    dim=`feat-to-dim scp:$feadir/feats.scp -`
    # Direct
    ! cat $feadir/spk2utt |\
 awk -v dim=$dim '{
 print $1, "["; for (n=0; n < dim; n++) { printf("0 "); } print "1";
 for (n=0; n < dim; n++) { printf("1 "); } print "0 ]";
}' | \
    copy-matrix ark:- ark,scp:$feadir/cmvn.ark,$cmvndir/cmvn.scp && \
    echo "Error creating fake CMVN stats" && exit 1;
fi

# converting fea to htk/stk
copy-feats-to-htk --output-dir=$feadir --output-ext=fea  scp:$feadir/feats.scp

# Convert stats into HTK format
# Get cvn norms for 52d stats (1/std)
cmndir=$feadir/cmn
cvndir=$feadir/cvn

mkdir -p $cmndir $cvndir
copy-matrix scp:$feadir/cmvn.scp ark,t:- |\
  awk -v cmndir=$cmndir -v cvndir=$cvndir '
NR==1{name=$1} 
NR==2{
# mean stats
dim=NF-1; N=$NF
for(n=1; n < NF; n++) M[n]=$n/N
}
NR==3{
# var stats
for(n=1; n < NF; n++) V[n]=$n/N - M[n]*M[n]
}
END{
 fmean=cmndir "/" name
 fvar =cvndir "/" name

 print "<CEPSNORM> <USER>" > fmean
 print "<MEAN> " dim >> fmean
 for(n=1; n<=dim; n++) printf " " M[n] >> fmean; printf "\n" >> fmean

 print "<CEPSNORM> <USER_Z>" > fvar
 print "<VARIANCE> " dim    >> fvar
 for(n=1; n<=dim; n++) printf " " V[n] >> fvar; printf "\n" >> fvar
}'
echo "Succeeded in converting stats to HTK/STK"

fi


###########################################################################
################ RDT forward 
###########################################################################
if [ $STAGE_LAST -ge 32 ]; then

echo "Make RDTFea"
feakind_in=$feakind
feakind=$feakind_in.rdt
feadir_in=$FEADIR/$feakind_in
feadir=$FEADIR/$feakind

MakeSCP $feakind fea > $SCPDIR/$TAG.$feakind.scp
log=$feadir/SFeaCat.log



#MACROS=$(echo $FeaExtrDir_MACROS | awk -F, '{for(i=1;i<=NF;i++) {printf " -H " $i " "}}')

if [ ! -e $log.gz ]; then 
    mkdir -p $feadir 
    ( echo "TARGETKIND   = USER_Z"
	echo "CMEANDIR     = $feadir_in/cmn"
	echo "CMEANMASK    = $MASK_NOSEG"
	echo "VARSCALEFN   = $FirstPassDirRDT_GLOBVAR"
	echo "VARSCALEDIR  = $feadir_in/cvn"
	echo "VARSCALEMASK = $MASK_NOSEG"

	echo "SOURCEMMF   = $FirstPassDirRDT_MACROS"
	echo "STARTFRMEXT = 9"
	echo "ENDFRMEXT   = 9"

	#echo "MMF_dir=$adaptdir.stk"
	#echo "MMF-mask=$MASK_NOSEG"
    ) > $feadir/sfeacat.config

#    if /usr/bin/time -v $BINDIR/SFeaCat  \
    if $BINDIR/SFeaCat  \
	--HMMDEFFILTER="$TOOLDIR/readfile.sh $ " \
	-A -D -V -T 1 -l $feadir -y fea \
	-C $feadir/sfeacat.config       \
	$feadir_in/$TAG.fea > $log 2>&1; then 
	gzip $log
    fi
else
    echo "SFeaCat: SATRDT: already done.. Skipped"
fi

if [ -e $log ]; then
    echo "ERROR: SFeaCat: Check $log"
    exit 1
fi

if [ "$bNorm" == "T" ]; then
    $TOOLDIR/cmncvn.sh -mask $MASK -cmn-fea USER -cvn-fea USER_Z $feadir $SCPDIR/$TAG.$feakind.scp
else
    mkdir -p $feadir/{cmn,cvn}
    $TOOLDIR/cmncvn.PrintEmptyCMN.sh -dim 69 -feakind USER   > $feadir/cmn/$TAG
    $TOOLDIR/cmncvn.PrintEmptyCVN.sh -dim 69 -feakind USER_Z > $feadir/cvn/$TAG
fi


fi

###########################################################################
################## Copy final fea into outdir
###########################################################################

if [ "$MapToNewName" == "TRUE" ];then
  dirname=$(dirname $OUTDIR/$TAG_ORIG.fea); mkdir -p $dirname   
  cp $feadir/$TAG.fea $OUTDIR/$TAG_ORIG.fea
  echo "FINISHED OK ... $OUTDIR/$TAG_ORIG.fea"
else
  cp $feadir/$TAG.fea $OUTDIR/
  echo "FINISHED OK ... $OUTDIR/$TAG.fea"
fi



