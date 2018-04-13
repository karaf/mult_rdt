# Modify $KALDI_ROOT and $STKBIN $RDTMODELS
#
# STK with RDT extension can be downloaded by:
# git clone -b rd_xforms https://github.com/stk-developers/stk.git

# RDTMODELS can be downloaded from http://speech.fit.vutbr.cz/software/MultRDT

export KALDI_ROOT=`pwd`/../../Kaldi

[ -f $KALDI_ROOT/tools/env.sh ] && . $KALDI_ROOT/tools/env.sh
export PATH=$KALDI_ROOT/egs/wsj/s5/utils/:$KALDI_ROOT/tools/openfst/bin:$PWD:$PATH
[ ! -f $KALDI_ROOT/tools/config/common_path.sh ] && echo >&2 "The standard file $KALDI_ROOT/tools/config/common_path.sh is not present -> Exit!" && exit 1
. $KALDI_ROOT/tools/config/common_path.sh
export LC_ALL=C

LMBIN=$KALDI_ROOT/tools/irstlm/bin
SRILM=$KALDI_ROOT/tools/srilm/bin/i686-m64
BEAMFORMIT=$KALDI_ROOT/tools/BeamformIt

STKBIN=$KALDI_ROOT/tools/STK/bin
RDTMODELDIR=/mnt/matylda3/karafiat/BABEL/GIT/mult_rdt/systems/MultRDTv1

export PATH=$PATH:$LMBIN:$BEAMFORMIT:$SRILM

