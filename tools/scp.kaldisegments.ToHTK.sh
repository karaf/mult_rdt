#!/bin/bash

# Defaults
                                                                                                                    
for i in $*; do
    case "$1" in
        -?*)
            echo Unknown option $1
            exit
            ;;
        *)
            break
            ;;
    esac
done

DATA=$1
OU_SCP=$2

#if [ "$IN_SCP" == "-" ];                   then IN_SCP=/dev/stdin; fi
if [ "$OU_SCP" == "-" ] || [ -z $OU_SCP ]; then OU_SCP=/dev/stdout;fi

fseg=$DATA/segments
fwav=$DATA/wav.scp

for f in $fseg $fwav; do
    if [ ! -e $f ]; then echo "ERROR: $0: File $f do not exists"; exit 1; fi
done

 awk '
 function Round100(x){
  return int(x*100+0.5)
 }

k==0{
 wavid=$1; wav=$2
 WAV[wavid]=wav
}

k==1{
  seg=$1; wavid=$2; frm_start=Round100($3); frm_end=Round100($4);
  seg=seg ".wav"
  wav=WAV[wavid]

  if ( (frm_end-frm_start) > 30 ){
     print seg "=" wav "[" frm_start ","  frm_end "]"
   }else{
     print "Warning: " $0 " too short segment <30frames" > "/dev/stderr"
   }
}'  k=0 $fwav k=1 $fseg > $OU_SCP
