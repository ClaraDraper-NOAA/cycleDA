#!/bin/bash -l
#SBATCH --job-name=offline_noahmp
#SBATCH --account=gsienkf
#SBATCH --qos=debug
#SBATCH --nodes=1
#SBATCH --tasks-per-node=6
#SBATCH --cpus-per-task=1
#SBATCH -t 00:10:00
#SBATCH -o log_noahmp.%j.log
#SBATCH -e err_noahmp.%j.err

# experiment name 
exp_name=open_testing
open_loop=True # If "False" do DA.

# set your directories
export WORKDIR=/scratch1/NCEPDEV/stmp4/Zhichang.Guo/Work/TestcycleDA/experiment1/workdir/ # temporary work dir
export OUTDIR=/scratch1/NCEPDEV/stmp4/Zhichang.Guo/Work/TestcycleDA/experiment1/${exp_name}/output/

dates_per_job=20

ens_list=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)
frc_list=(precipitation temperature specific_humidity wind_speed surface_pressure solar_radiation longwave_radiation)

######################################################
# shouldn't need to change anything below here

SAVEDIR=${OUTDIR}/restarts # dir to save restarts
MODLDIR=${OUTDIR}/noahmp # dir to save noah-mp output
# create output dircetories
mkdir -p ${OUTDIR}/DA
mkdir -p ${OUTDIR}/DA/IMSproc 
mkdir -p ${OUTDIR}/DA/jedi_incr
mkdir -p ${OUTDIR}/DA/logs
mkdir -p ${OUTDIR}/DA/hofx
mkdir -p ${OUTDIR}/restarts
mkdir -p ${OUTDIR}/restarts/vector
mkdir -p ${OUTDIR}/restarts/tile
mkdir -p ${OUTDIR}/noahmp

source cycle_mods_bash

# executables

CYCLEDIR=$(pwd)  # this directory
vec2tileexec=${CYCLEDIR}/vector2tile/vector2tile_converter.exe
#LSMexec=${CYCLEDIR}/ufs_land_driver/ufsLand.exe 
LSMexec=/scratch2/NCEPDEV/stmp3/Zhichang.Guo/EMCLandPreP7/ufs-land-driver/run/ufsLand.exe
DAscript=${CYCLEDIR}/landDA_workflow/do_snowDA.sh 
export DADIR=${CYCLEDIR}/landDA_workflow/

analdate=${CYCLEDIR}/analdates.sh
incdate=${CYCLEDIR}/incdate.sh

logfile=${CYCLEDIR}/cycle.log
touch $logfile

# read in dates 
source ${analdate}

# Create output directory and emporary workdir for ecah ensemble member
for ens_member in "${ens_list[@]}"
do
    ENSEMBLE_DIR=${WORKDIR}/ens${ens_member}
    mkdir -p ${ENSEMBLE_DIR}
    mkdir -p ${ENSEMBLE_DIR}/restarts
    mkdir -p ${ENSEMBLE_DIR}/restarts/tile
    mkdir -p ${ENSEMBLE_DIR}/restarts/vector
    mkdir -p ${MODLDIR}/ens${ens_member}
    ln -fs ${MODLDIR}/ens${ens_member} ${ENSEMBLE_DIR}/noahmp_output
done

echo "***************************************" >> $logfile
echo "cycling from $STARTDATE to $ENDDATE" >> $logfile

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

    # for each ensemble member
    for ens_member in "${ens_list[@]}"
    do
        ENSEMBLE_DIR=${WORKDIR}/ens${ens_member}

        cd ${ENSEMBLE_DIR}

        # copy initial restart
        src_restart=${SAVEDIR}/vector/ufs_land_restart.ens${ens_member}_back.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
        cp ${src_restart} ${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc

        # update model namelist 
        cp  ${CYCLEDIR}/template.ens.ufs-noahMP.namelist.gswp3  ufs-land.namelist

        sed -i -e "s/XXYYYY/${YYYY}/g" ufs-land.namelist 
        sed -i -e "s/XXMM/${MM}/g" ufs-land.namelist
        sed -i -e "s/XXDD/${DD}/g" ufs-land.namelist
        sed -i -e "s/XXHH/${HH}/g" ufs-land.namelist

        for variable in "${frc_list[@]}"
        do
            sed -i -e "s/USER_${variable}/${variable}${ens_member}/g" ufs-land.namelist
        done
     
        if [ $open_loop == "False" ]; then  # do DA

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
            cres_file=${ENSEMBLE_DIR}/restarts/tile/${YYYY}${MM}${DD}.${HH}0000.coupler.res
            cp  ${CYCLEDIR}/template.coupler.res $cres_file

            sed -i -e "s/XXYYYY/${YYYY}/g" $cres_file
            sed -i -e "s/XXMM/${MM}/g" $cres_file
            sed -i -e "s/XXDD/${DD}/g" $cres_file

            # submit snow DA 
            echo '************************************************'
            echo 'calling snow DA'
            export THISDATE
            $DAscript
            if [[ $? != 0 ]]; then
                echo "land DA script failed"
                exit
            fi  # submit tile2vec

            echo '************************************************'
            echo 'calling tile2vector' 
            $vec2tileexec tile2vector.namelist
            if [[ $? != 0 ]]; then
                echo "tile2vector failed"
                exit 
            fi

            # save analysis restart
            src_restart=${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
            cp ${src_restart} ${SAVEDIR}/vector/ufs_land_restart.ens${ens_member}_anal.${YYYY}-${MM}-${DD}_${HH}-00-00.nc

        fi # DA step

        # submit model
        echo '************************************************'
        echo 'calling model for ensemble member '${ens_member}
        $LSMexec
# no error codes on exit from model, check for restart below instead
#    if [[ $? != 0 ]]; then
#        echo "model failed"
#        exit 
#    fi

        NEXTDATE=`${incdate} $THISDATE 24`
        CUR_YYYY=`echo $NEXTDATE | cut -c1-4`
        CUR_MM=`echo $NEXTDATE | cut -c5-6`
        CUR_DD=`echo $NEXTDATE | cut -c7-8`
        CUR_HH=`echo $NEXTDATE | cut -c9-10`

        src_restart=${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${CUR_YYYY}-${CUR_MM}-${CUR_DD}_${CUR_HH}-00-00.nc
        if [[ -e ${src_restart} ]]; then
           cp ${src_restart} ${SAVEDIR}/vector/ufs_land_restart.ens${ens_member}_back.${CUR_YYYY}-${CUR_MM}-${CUR_DD}_${CUR_HH}-00-00.nc
           echo "Finished job number, ${date_count},for ensemble member: ${ens_member}, for date: ${THISDATE}" >> $logfile
        else
           echo "Something is wrong, probably the model, exiting" 
           exit
        fi
    done
    wait

    THISDATE=`${incdate} $THISDATE 24`
    date_count=$((date_count+1))

done

# resubmit
if [ $THISDATE -lt $ENDDATE ]; then
    echo "export STARTDATE=${THISDATE}" > ${analdate}
    echo "export ENDDATE=${ENDDATE}" >> ${analdate}
    cd ${CYCLEDIR}
    rm -rf ${WORKDIR}
    sbatch ${CYCLEDIR}/submit_cycle_ens.sh
fi

