#!/bin/bash

# Copyright 2018  Brno University of Technology (author: Martin Karafiat)
# Licensed under the Apache License, Version 2.0 (the "License")

set -euo pipefail

export LANG=en_US.UTF-8; export LC_ALL=$LANG
bRM="T"
tmpdir=""
bNorm="T"
STAGE=0
STAGE_LAST=1000000   # 50 - 1stage.cmllr


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
	-tempdir | -tmpdir)
	    tmpdir=$2
	    mkdir -p $tmpdir
            shift
            shift
            ;;
	-wavname | -tag)
	    TAG=$2
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

DATADIR=$1
OUTDIR=${2:?}


#---
ROOTDIR=${0%/*}

source $ROOTDIR/path.sh

TOOLDIR=$ROOTDIR/tools

#---------------------
#   System settings
# --------------------
XFORMDIR=$RDTMODELDIR/xforms

CFG_PLP=$RDTMODELDIR/configs.kaldi/plp.conf
GLOBVAR_PLP=$XFORMDIR/plphlda/globalvar.kaldi
PLPHLDAMACROS=$XFORMDIR/plphlda/hlda.kaldi

XFORMDIR_NN=$XFORMDIR/nn.fbank24kf0

gmmsize=125;indim=69;oudim=69
FirstPassDirRDT=$XFORMDIR/MultRDT
FirstPassDirRDT_MACROS=$FirstPassDirRDT/gmm$gmmsize,$FirstPassDirRDT/rd${indim}to${oudim}_gmm${gmmsize}_7ctx,$FirstPassDirRDT/macros_rd${indim}to${oudim}_gmm${gmmsize}_7ctx
FirstPassDirRDT_GLOBVAR=$FirstPassDirRDT/globalvar



echo "Program $0 started at $(date) on $HOSTNAME"
echo "ROOTDIR $ROOTDIR"
###########################################################################

# Make dirs
[ -z $tmpdir ] && TMPDIR=$(mktemp -d) || TMPDIR=$tmpdir
echo TMPDIR $TMPDIR

SCPDIR=$TMPDIR/lib/flists
FEADIR=$TMPDIR/features
mkdir -p $OUTDIR $SCPDIR $FEADIR $TMPDIR
# ----------------

#root of the file name
# If it is empty pickup first one only
if [ -z $TAG ]; then
    TAG=$(awk '{print $1}' $DATADIR/wav.scp)
fi

# Convert waveform
awk -v tag=$TAG -v tmpdir=$TMPDIR '
$1==tag && NF==2{print "cp " $2 " " tmpdir "/" tag ".wav"} 
$1==tag && NF>2{$1=""; print $0 " cat > " tmpdir "/" tag ".wav"} 
' $DATADIR/wav.scp > $TMPDIR/prepare_wav.sh
bash $TMPDIR/prepare_wav.sh

WFORM=$TMPDIR/$TAG.wav


if [ ! -r $WFORM ]; then
  echo cannot open $WFORM; exit 1;
fi

if [ ! -d $OUTDIR ]; then mkdir -p $OUTDIR; fi



# ----------------------------------
# Kaldi Data Dir 
# ----------------------------------
datadir=$TMPDIR/data/$TAG/
mkdir -p $datadir

awk -v tag=$TAG '$2==tag' $DATADIR/segments > $datadir/segments
echo "$TAG $WFORM"                          >  $datadir/wav.scp
awk '{print $1 " " $2}' $datadir/segments > $datadir/utt2spk
utt2spk_to_spk2utt.pl   $datadir/utt2spk  > $datadir/spk2utt

# ----------------------------------
# HTK SCP 
# ----------------------------------
$TOOLDIR/scp.kaldisegments.ToHTK.sh $datadir - |\
   $TOOLDIR/scp.CorrectLengh.audio.wav.sh - > $SCPDIR/$TAG.wav.scp 2> $SCPDIR/$TAG.wav.corr.LOG
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

cfg_fbank=$RDTMODELDIR/configs.kaldi/fbank24.conf
cfg_f0=$RDTMODELDIR/configs.kaldi/pitch.conf
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
	    nnet-forward --verbose=2 --use-gpu=$use_gpu $nnet "$feats" \
		ark,scp:$feadir/feats.ark,$feadir/feats.scp ) > $log 2>&1; then 
	gzip $log
    fi
else
    echo "nnet-forward: NN: already done.. Skipped"
fi

if [ -e $log ]; then
    echo "ERROR: nnet-forward: Check $log"
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

# Create speaker mask 
percents=$(awk 'BEGIN{ l=length("'$TAG'"); for(i=0;i<l;i++) { str=str"%" }; print str;}')
MASK="$percents*"
MASK_NOSEG="*/$percents.???"
#-

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
    if $STKBIN/SFeaCat  \
	-A -D -V -T 1 -l $feadir -y fea \
	-C $feadir/sfeacat.config       \
	$feadir_in/$TAG.fea > $log 2>&1; then 
	gzip $log
    fi
else
    echo "SFeaCat: already done.. Skipped"
fi

if [ -e $log ]; then
    echo "ERROR: SFeaCat: Check $log"
    exit 1
fi


fi

###########################################################################
################## Copy final fea into outdir
###########################################################################

cp $feadir/$TAG.fea $OUTDIR/
echo "FINISHED OK ... $OUTDIR/$TAG.fea"
