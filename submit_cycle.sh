#!/bin/bash -le 
#SBATCH --job-name=offline_noahmp
#SBATCH --account=gsienkf
#SBATCH --qos=debug
#SBATCH --nodes=1
#SBATCH --tasks-per-node=6
#SBATCH --cpus-per-task=1
#SBATCH -t 00:10:00
#SBATCH -o log_noahmp.%j.log
#SBATCH -e err_noahmp.%j.err

############################
# to do: 
# -specify resolution in this script (currently fixed at 96) 
# -update ICS directory to include forcing / res info.
# -decide how to manage soil moisture DA. Separate DA script to snow? 
# -add ensemble options

File_setting=$1
############################
# read in CYCLEDIR and exp_name
while read line
do
    [[ -z "$line" ]] && continue
    [[ $line =~ ^#.* ]] && continue
    key=$(echo ${line} | cut -d'=' -f 1)
    value=$(echo ${line} | cut -d'=' -f 2)
    case ${key} in
        "CYCLEDIR")
        CYCLEDIR=${value}
        ;;
        "exp_name")
        exp_name=${value}
        ;;
    esac
done < "$File_setting"
if [[ -z "$CYCLEDIR" ]]; then
    CYCLEDIR=$(pwd)  # this directory
fi

# read in DA settings for the experiment
while read line
do
    [[ -z "$line" ]] && continue
    [[ $line =~ ^#.* ]] && continue
    key=$(echo ${line} | cut -d'=' -f 1)
    value=$(echo ${line} | cut -d'=' -f 2)
    if [[ "$value" == *"{CYCLEDIR}"* ]]; then
        value=${value//'{CYCLEDIR}'/$CYCLEDIR}
    fi
    if [[ "$value" == *"{exp_name}"* ]]; then
        value=${value//'{exp_name}'/$exp_name}
    fi
    case ${key} in
        "ensemble_size")
        ensemble_size=${value}
        ;;
        "atmos_forc")
        atmos_forc=${value}
        ;;
        "dates_per_job")
        dates_per_job=${value}
        ;;
        "do_DA")
        do_DA=${value}
        ;;
        "do_hofx")
        do_hofx=${value}
        ;;
        "ASSIM_IMS")
        ASSIM_IMS=${value}
        ;;
        "ASSIM_GHCN")
        ASSIM_GHCN=${value}
        ;;
        "ASSIM_SYNTH")
        ASSIM_SYNTH=${value}
        ;;
        "DAtype")
        DAtype=${value}
        ;;
        "WORKDIR")
        WORKDIR=${value}
        ;;
        "ICSDIR")
        ICSDIR=${value}
        ;;
        "OUTDIR")
        OUTDIR=${value}
        ;;
        "vec2tileexec")
        vec2tileexec=${value}
        ;;
        "LSMexec")
        LSMexec=${value}
        ;;
        "DAscript")
        DAscript=${value}
        ;;
        "DADIR")
        DADIR=${value}
        ;;
        "analdate")
        analdate=${value}
        ;;
        "incdate")
        incdate=${value}
        ;;
        #default case
        #*)
        #echo ${line}
        #;;
    esac
done < "$File_setting"

############################
# set environment variables
export ensemble_size
export do_DA
export ASSIM_IMS
export ASSIM_GHCN
export ASSIM_SYNTH
export WORKDIR
export OUTDIR
                                
# load modules 
source cycle_mods_bash

# set default executables if undefined
if [[ -z "$vec2tileexec" ]]; then
    vec2tileexec=${CYCLEDIR}/vector2tile/vector2tile_converter.exe
fi
if [[ -z "$LSMexec" ]]; then
    LSMexec=${CYCLEDIR}/ufs_land_driver/ufsLand.exe 
fi
if [[ -z "$DAscript" ]]; then
    DAscript=${CYCLEDIR}/landDA_workflow/do_snowDA.sh 
fi
if [[ -z "$DADIR" ]]; then
    DADIR=${CYCLEDIR}/landDA_workflow/
fi
if [[ -z "$analdate" ]]; then
    analdate=${CYCLEDIR}/analdates.sh
fi
if [[ -z "$incdate" ]]; then
    incdate=${CYCLEDIR}/incdate.sh
fi

export DADIR

# create clean workdir
if [[ -e ${WORKDIR} ]]; then 
   rm -rf ${WORKDIR} 
fi

mkdir ${WORKDIR}

############################
# create the jedi yaml name 

if [[ $do_DA == "YES" || $do_hofx == "YES" ]]; then  # do DA
   do_jedi=YES
   # construct yaml name
   if [ $do_DA == "YES" ]; then
        JEDI_YAML=${DAtype}"_offline_DA"
   elif [ $do_hofx == "YES" ]; then
        JEDI_YAML=${DAtype}"_offline_hofx"
   fi

   if [ $ASSIM_IMS == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_IMS" ; fi
   if [ $ASSIM_GHCN == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_GHCN" ; fi
   if [ $ASSIM_SYNTH == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_SYNTH"; fi

   JEDI_YAML=${JEDI_YAML}"_C96.yaml" # IMS and GHCN

   echo "JEDI YAML is: "$JEDI_YAML

   if [[ ! -e ${DADIR}/jedi/fv3-jedi/yaml_files/$JEDI_YAML ]]; then
        echo "YAML does not exist, exiting" 
        exit
   fi
   export JEDI_YAML
else
   do_jedi=NO
fi

############################
# create output directories if they do not already exist.

if [[ ! -e ${OUTDIR} ]]; then
    mkdir -p ${OUTDIR}/DA
    mkdir ${OUTDIR}/DA/IMSproc 
    mkdir ${OUTDIR}/DA/jedi_incr
    mkdir ${OUTDIR}/DA/logs
    mkdir ${OUTDIR}/DA/hofx
    mkdir ${OUTDIR}/modl
    n_ens=1
    while [ $n_ens -le $ensemble_size ]; do

        if [ $ensemble_size == 1 ]; then 
            mem_ens="" 
        else 
            mem_ens="mem`printf %03i $n_ens`"
        fi 

        mkdir -p ${OUTDIR}/modl/${mem_ens}/restarts/vector/ 
        mkdir ${OUTDIR}/modl/${mem_ens}/restarts/tile/
        mkdir -p ${OUTDIR}/modl/${mem_ens}/noahmp/
        n_ens=$((n_ens+1))
    done # n_ens < ensemble_size
fi 

############################
# fetch initial conditions, if not already in place 

# read in dates  
source ${analdate}

logfile=${CYCLEDIR}/cycle.log
touch $logfile
echo "***************************************" >> $logfile
echo "cycling from $STARTDATE to $ENDDATE" >> $logfile

sYYYY=`echo $STARTDATE | cut -c1-4`
sMM=`echo $STARTDATE | cut -c5-6`
sDD=`echo $STARTDATE | cut -c7-8`
sHH=`echo $STARTDATE | cut -c9-10`

# copy initial conditions
n_ens=1
while [ $n_ens -le $ensemble_size ]; do

    if [ $ensemble_size == 1 ]; then 
        mem_ens="" 
    else 
        mem_ens="mem`printf %03i $n_ens`"
    fi 

    MEM_OUTDIR=${OUTDIR}/modl/${mem_ens}/
    MEM_ICSDIR=${ICSDIR}/modl/${mem_ens}/

    source_restart=${MEM_ICSDIR}/restarts/vector/ufs_land_restart.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
    target_restart=${MEM_OUTDIR}/restarts/vector/ufs_land_restart_back.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc

    # if ensemble of restarts exist, use these. Otherwise, use single restart.
    if [[ ! -e ${target_restart} ]]; then 
        echo $source_restart
        if [[ -e ${source_restart} ]]; then
           cp ${source_restart} ${target_restart}
        else  # use non-ensemble restart
           echo 'using single restart for every ensemble member' 
           cp ${ICSDIR}/modl/restarts/vector/ufs_land_restart.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc ${target_restart}
        fi 
    fi 

    n_ens=$((n_ens+1))

done # n_ens < ensemble_size

############################
# loop over time steps

THISDATE=$STARTDATE
date_count=0

while [ $date_count -lt $dates_per_job ]; do

    if [ $THISDATE -ge $ENDDATE ]; then 
        echo "All done, at date ${THISDATE}"  >> $logfile
        cd $CYCLEDIR 
        rm -rf $WORKDIR
        exit  
    fi

    echo "starting $THISDATE"  

    # substringing to get yr, mon, day, hr info
    export YYYY=`echo $THISDATE | cut -c1-4`
    export MM=`echo $THISDATE | cut -c5-6`
    export DD=`echo $THISDATE | cut -c7-8`
    export HH=`echo $THISDATE | cut -c9-10`

    ############################
    # create work directory and copy in restarts

    n_ens=1
    while [ $n_ens -le $ensemble_size ]; do

        if [ $ensemble_size == 1 ]; then 
            mem_ens="" 
        else 
            mem_ens="mem`printf %03i $n_ens`"
        fi 
        
        MEM_WORKDIR=${WORKDIR}/${mem_ens}/
        MEM_OUTDIR=${OUTDIR}/modl/${mem_ens}/ # for model only

        # create temporary workdir
        if [[ -d $MEM_WORKDIR ]]; then 
          rm -rf $MEM_WORKDIR
        fi 

        # move to work directory, and copy in templates and restarts
        mkdir -p $MEM_WORKDIR
        cd $MEM_WORKDIR

        ln -s ${MEM_OUTDIR}/noahmp/ ${MEM_WORKDIR}/noahmp_output 

        mkdir ${MEM_WORKDIR}/restarts
        mkdir ${MEM_WORKDIR}/restarts/tile
        mkdir ${MEM_WORKDIR}/restarts/vector

        # copy restarts into work directory
        source_restart=${MEM_OUTDIR}/restarts/vector/ufs_land_restart_back.${YYYY}-${MM}-${DD}_${HH}-00-00.nc 
        target_restart=${MEM_WORKDIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
        cp $source_restart $target_restart 

        n_ens=$((n_ens+1))

    done # n_ens < ensemble_size

    ############################
    # call JEDI 

    if [ $do_jedi == "YES" ]; then  # do DA

        cd ${WORKDIR}

        # CSDtodo - do for every ensemble member
        # update vec2tile and tile2vec namelists
        cp  ${CYCLEDIR}/template.vector2tile vector2tile.namelist

        sed -i -e "s/XXYYYY/${YYYY}/g" vector2tile.namelist
        sed -i -e "s/XXMM/${MM}/g" vector2tile.namelist
        sed -i -e "s/XXDD/${DD}/g" vector2tile.namelist
        sed -i -e "s/XXHH/${HH}/g" vector2tile.namelist

        cp  ${CYCLEDIR}/template.tile2vector tile2vector.namelist

        sed -i -e "s/XXYYYY/${YYYY}/g" tile2vector.namelist
        sed -i -e "s/XXMM/${MM}/g" tile2vector.namelist
        sed -i -e "s/XXDD/${DD}/g" tile2vector.namelist
        sed -i -e "s/XXHH/${HH}/g" tile2vector.namelist

        # submit vec2tile 
        echo '************************************************'
        echo 'calling vector2tile' 
        $vec2tileexec vector2tile.namelist
        if [[ $? != 0 ]]; then
            echo "vec2tile failed"
            exit 
        fi
        # add coupler.res file
        cres_file=${WORKDIR}/restarts/tile/${YYYY}${MM}${DD}.${HH}0000.coupler.res
        cp  ${CYCLEDIR}/template.coupler.res $cres_file

        sed -i -e "s/XXYYYY/${YYYY}/g" $cres_file
        sed -i -e "s/XXMM/${MM}/g" $cres_file
        sed -i -e "s/XXDD/${DD}/g" $cres_file

        # CSDtodo - call once
        # submit snow DA 
        echo '************************************************'
        echo 'calling snow DA'
        export THISDATE
        $DAscript ${File_setting}
        if [[ $? != 0 ]]; then
            echo "land DA script failed"
            exit
        fi   
        # CSDtodo - every ensemble member 
        echo '************************************************'
        echo 'calling tile2vector' 
        $vec2tileexec tile2vector.namelist
        if [[ $? != 0 ]]; then
            echo "tile2vector failed"
            exit 
        fi

        # CSDtodo - every ensemble member 
        # save analysis restart
        cp ${WORKDIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc ${OUTDIR}/modl/restarts/vector/ufs_land_restart_anal.${YYYY}-${MM}-${DD}_${HH}-00-00.nc

    fi # DA step

    ############################
    # run the forecast model

    NEXTDATE=`${incdate} $THISDATE 24`
    export nYYYY=`echo $NEXTDATE | cut -c1-4`
    export nMM=`echo $NEXTDATE | cut -c5-6`
    export nDD=`echo $NEXTDATE | cut -c7-8`
    export nHH=`echo $NEXTDATE | cut -c9-10`

    # loop over ensemble members

    n_ens=1
    while [ $n_ens -le $ensemble_size ]; do

        if [ $ensemble_size == 1 ]; then 
            mem_ens="" 
        else 
            mem_ens="mem`printf %03i $n_ens`"
        fi 

        MEM_WORKDIR=${WORKDIR}/${mem_ens}/
        MEM_OUTDIR=${OUTDIR}/modl/${mem_ens}/ # for model only

        cd $MEM_WORKDIR

        # update model namelist 
     
        if [ $ensemble_size == 1 ]; then
            cp  ${CYCLEDIR}/template.ufs-noahMP.namelist.${atmos_forc}  ufs-land.namelist
        else
            #cp ${CYCLEDIR}/template.ens.ufs-noahMP.namelist.${atmos_forc} ufs-land.namelist
            echo 'CSD - temporarily using non-ensemble namelist' 
            cp  ${CYCLEDIR}/template.ufs-noahMP.namelist.${atmos_forc}  ufs-land.namelist
        fi

        sed -i -e "s/XXYYYY/${YYYY}/g" ufs-land.namelist
        sed -i -e "s/XXMM/${MM}/g" ufs-land.namelist
        sed -i -e "s/XXDD/${DD}/g" ufs-land.namelist
        sed -i -e "s/XXHH/${HH}/g" ufs-land.namelist
        NN="`printf %02i $n_ens`" # ensemble number 
        sed -i -e "s/XXMEM/${NN}/g" ufs-land.namelist

        # submit model
        echo '************************************************'
        echo 'calling model' 
        echo $MEM_WORKDIR
        $LSMexec

    # no error codes on exit from model, check for restart below instead
    #    if [[ $? != 0 ]]; then
    #        echo "model failed"
    #        exit 
    #    fi

        if [[ -e ${MEM_WORKDIR}/restarts/vector/ufs_land_restart.${nYYYY}-${nMM}-${nDD}_${nHH}-00-00.nc ]]; then 
           cp ${MEM_WORKDIR}/restarts/vector/ufs_land_restart.${nYYYY}-${nMM}-${nDD}_${nHH}-00-00.nc ${MEM_OUTDIR}/restarts/vector/ufs_land_restart_back.${nYYYY}-${nMM}-${nDD}_${nHH}-00-00.nc
        else 
           echo "Something is wrong, probably the model, exiting" 
           exit
        fi

        n_ens=$((n_ens+1))
    done # n_ens < ensemble_size

    echo "Finished job number, ${date_count},for  date: ${THISDATE}" >> $logfile

    #THISDATE=`${incdate} $THISDATE 24`
    THISDATE=$NEXTDATE
    date_count=$((date_count+1))

done #  date_count -lt dates_per_job


############################
# resubmit script 

if [ $THISDATE -lt $ENDDATE ]; then
    echo "export STARTDATE=${THISDATE}" > ${analdate}
    echo "export ENDDATE=${ENDDATE}" >> ${analdate}
    cd ${CYCLEDIR}
    sbatch ${CYCLEDIR}/submit_cycle.sh ${File_setting}
fi

