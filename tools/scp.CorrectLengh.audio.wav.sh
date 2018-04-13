#!/bin/bash

file=$1

awk -F'[=,\\[]' '{print $2 " " $(NF-1) " " $0}'  $file | sort -k1,1g -k 2,2n  | awk '{print $NF}' |\
  awk -F "[=[,]" '{
gsub("]","",$4); from=$3+0;to=$4+0;logfile=$1; 
if (file != $2) {
  file=$2; 
# cmdline = "sox " file " -e stat 2>&1 | grep Length"; cmdline | getline maxseg; close(cmdline);
  cmdline = "sox " file " -n stat 2>&1 | grep Length"; cmdline | getline maxseg; close(cmdline);
  gsub("^[^0-9]*","",maxseg); 
  maxseg = int (100 * maxseg -5 ) 
}; 

#print ""
#print
#print "to:" to " maxseg:" maxseg

if (to>maxseg) {
  print logfile " " to "->" maxseg " " maxseg-to >"/dev/stderr" ; to=maxseg 
};
print logfile "=" file "[" from "," to "]"}'   

