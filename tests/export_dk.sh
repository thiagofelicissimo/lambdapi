#!/bin/bash

echo '############ test export -o dk ############'

lambdapi=${LAMBDAPI:-_build/install/default/bin/lambdapi}
dkcheck=${DKCHECK:-dk check}
dkdep=${DKDEP:-dk dep}

TIMEFORMAT="%Es"

root=`pwd`

outdir=/tmp/export_dk

reset_outdir() {
    rm -rf $outdir
    mkdir -p $outdir
}
reset_outdir

# compute lp files to test
for f in tests/OK/*.lp
do
    f=${f%.lp}
    case $f in
        tests/OK/ac);; # because dedukti does not handle commutative and non associative symbols
        tests/OK/π/utf_path);; # because dedukti does not accept unicode characters in module names
        tests/OK/escape_path|'tests/OK/a b/escape file');; # because dedukti does not accept spaces in module names
        tests/OK/262_private_in_lhs);; # because dedukti does not accept protected symbols in rule LHS arguments
        tests/OK/273|tests/OK/813);; # because dedukti SR algorithm fails
        tests/OK/file.with.dot|tests/OK/req.file.with.dot);; #FIXME
        tests/OK/indind);; #FIXME
        tests/OK/why3*);; #FIXME
        *) lp_files="$f.lp $lp_files";
           f=`echo $f | sed -e 's/\//_/g'`;
           dk_files="$f.dk $dk_files";;
    esac
done

# compile lp files
compile() {
    echo 'compile lp files ...'
    #$lambdapi check -w -c $lp_files # does not work because of #802
    for f in $lp_files
    do
        echo "compile $f ..."
        $lambdapi check -w -v 0 -c $f
    done
}
#time compile

# translate lp files to dk files
translate() {
    echo 'translate lp files ...'
    for f in $lp_files
    do
        f=${f%.lp}
        out=$outdir/`echo $f | sed -e 's/\//_/g'`
        echo "$f.lp --> $out.dk ..."
        $lambdapi export -w -v 0 -o dk $f.lp > $out.dk
        if test $? -ne 0; then echo KO; exit 1; fi
    done
}
time translate

# check dk files
check() {
    cd $outdir
    echo 'remove #REQUIRE commands (to be removed when https://github.com/Deducteam/Dedukti/issues/262 is fixed) ...'
    sed -i -e 's/#REQUIRE.*$//' $dk_files
    dk_files=`$dkdep -q -s $dk_files`
    echo $dkcheck -q -e $dk_files ...
    $dkcheck -q -e $dk_files
    res=$?
    cd $root
    if test $res -ne 0; then echo KO; else echo OK; fi
    exit $res
}
time check
