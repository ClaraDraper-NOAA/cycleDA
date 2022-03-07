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

##########
# to do: 
# -specify resolution in this script (currently fixed at 96) 
# -decide how to manage soil moisture DA. Separate DA script to snow? 
# -add ensemble options

# experiment name 

exp_name=open_testing
#exp_name=DA_testing

################################################################
# specify DA and Ensemble options (all should be "YES" or "NO") 
################################################################

export do_DA=YES  # do full DA update
do_hofx=NO  # use JEDI to calculate hofx, but do not do update 
            # only used if do_DA=NO  
export do_ens=YES # If "YES"  do ensemble run
export ensemble_size=2

# DA options (select "YES" to assimilate or calcualte hofx) 
DAtype="letkfoi_snow" # for snow, use "letkfoi_snow" 
export ASSIM_IMS=NO
export ASSIM_GHCN=YES
export ASSIM_SYNTH=NO
if [[ $do_DA == "YES" || $do_hofx == "YES" ]]; then  # do DA
   do_jedi=YES
   # construct yaml name
   if [ $do_ens == "YES" ]; then
        JEDI_YAML="ens_"
   else
        JEDI_YAML=""
   fi

   if [ $do_DA == "YES" ]; then
        JEDI_YAML=${JEDI_YAML}${DAtype}"_offline_DA"
   elif [ $do_hofx == "YES" ]; then
        JEDI_YAML=${JEDI_YAML}${DAtype}"_offline_hofx"
   fi

   if [ ${ASSIM_SYNTH} == "YES" ]; then
       JEDI_YAML=letkf_snow_offline_synthetic_snowdepth
   else
       if [ ${ASSIM_IMS} == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_IMS" ; fi
       if [ ${ASSIM_GHCN} == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_GHCN" ; fi
   fi
   JEDI_YAML=${JEDI_YAML}"_C96.yaml" # IMS and GHCN

   echo "JEDI YAML is: "$JEDI_YAML

   if [[ ! -e ./landDA_workflow/jedi/fv3-jedi/yaml_files/$JEDI_YAML ]]; then
        echo "YAML does not exist, exiting" 
        exit
   fi
   export JEDI_YAML
else
   do_jedi=NO
fi

# set your directories
export WORKDIR=/scratch1/NCEPDEV/stmp4/Zhichang.Guo/Work/TestcycleDA/experiment1/workdir/ # temporary work dir
export OUTDIR=/scratch1/NCEPDEV/stmp4/Zhichang.Guo/Work/TestcycleDA/experiment1/${exp_name}/output/
#export RSTDIR=/scratch1/NCEPDEV/da/Azadeh.Gholoubi/jedi_experiment1/cycleDA/output/restarts/vector/
export RSTDIR=/scratch2/BMC/gsienkf/Clara.Draper/gerrit-hera/AZworkflow/
#export RSTDIR=/scratch2/NCEPDEV/stmp3/Zhichang.Guo/GEFS/exps/

dates_per_job=2

# Match the variable names in forcing files to those in land drivers
# for examples: precipitation_conserve in the forcing files will be used for precipitaton
#            or precipitation01 in the forcing files will be used for precipitation for the first ensemble member
frc_in_list=(precipitation temperature specific_humidity wind_speed surface_pressure solar_radiation longwave_radiation)
frc_in_file=(precipitation temperature specific_humidity wind_speed surface_pressure solar_radiation longwave_radiation)
#frc_in_file=(precipitation_conserve temperature specific_humidity wind_speed surface_pressure solar_radiation longwave_radiation)
variable_size=${#frc_in_list[@]}

# Specify ensemble list for do_ens
if [ $do_ens == "YES" ] && [ $ensemble_size -gt 1 ]; then
    declare -a ens_list=( $(for (( i=1; i<=${ensemble_size}; i++ )); do echo 0; done) ) # empty array
    ensemble_count=0
    for i in ${ens_list[@]}
    do
        ens_list[ensemble_count]="mem_`printf %02i $((ensemble_count + 1))`"
        ensemble_count=$((ensemble_count+1))
    done
else
    ensemble_size=1
fi
ens_list=(mem_pos mem_neg)

######################################################
# shouldn't need to change anything below here

MKDIR=/usr/bin/mkdir
CUT=/usr/bin/cut
RM=/usr/bin/rm
CP=/usr/bin/cp
LN=/usr/bin/ln
SED=/usr/bin/sed
TOUCH=/usr/bin/touch
SCRIPT=$0

SAVEDIR=${OUTDIR}/restarts # dir to save restarts
MODLDIR=${OUTDIR}/noahmp # dir to save noah-mp output

# create output dircetories if they do not already exist.
if [[ ! -e ${OUTDIR} ]]; then
    ${MKDIR} -p ${OUTDIR}/DA
    ${MKDIR} ${OUTDIR}/DA/IMSproc 
    ${MKDIR} ${OUTDIR}/DA/jedi_incr
    ${MKDIR} ${OUTDIR}/DA/logs
    ${MKDIR} ${OUTDIR}/DA/hofx
    ${MKDIR} ${OUTDIR}/restarts
    ${MKDIR} ${OUTDIR}/restarts/vector
    ${MKDIR} ${OUTDIR}/restarts/tile
    ${MKDIR} ${OUTDIR}/noahmp
fi

source cycle_mods_bash

# executables

CYCLEDIR=$(pwd)  # this directory
#vec2tileexec=${CYCLEDIR}/vector2tile/vector2tile_converter.exe
vec2tileexec=/scratch1/NCEPDEV/stmp4/Zhichang.Guo/Work/Test/jedi/cycleDA/vector2tile/vector2tile_converter.exe
#LSMexec=${CYCLEDIR}/ufs_land_driver/ufsLand.exe 
LSMexec=/scratch2/NCEPDEV/stmp3/Zhichang.Guo/EMCLandPreP7/ufs-land-driver/run/ufsLand.exe
DAscript=${CYCLEDIR}/landDA_workflow/do_snowDA.sh 
export DADIR=${CYCLEDIR}/landDA_workflow/

analdate=${CYCLEDIR}/analdates.sh
incdate=${CYCLEDIR}/incdate.sh

logfile=${CYCLEDIR}/cycle.log
${TOUCH} $logfile

# read in dates 
source ${analdate}

echo "***************************************" >> $logfile
echo "cycling from $STARTDATE to $ENDDATE" >> $logfile

# If there is no restart in experiment directory, copy from current directory

sYYYY=`echo $STARTDATE | ${CUT} -c1-4`
sMM=`echo $STARTDATE | ${CUT} -c5-6`
sDD=`echo $STARTDATE | ${CUT} -c7-8`
sHH=`echo $STARTDATE | ${CUT} -c9-10`

if [ $do_ens == "YES" ] && [ $ensemble_size -gt 1 ]; then
    for ens_member in "${ens_list[@]}"
    do
        source_restart=${RSTDIR}/ufs_land_restart.${ens_member}.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
        target_restart=${SAVEDIR}/vector/ufs_land_restart.${ens_member}_back.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
        if [[ ! -e ${source_restart} ]]; then
            source_restart=${RSTDIR}/ufs_land_restart.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
        fi
        if [[ ! -e ${target_restart} ]]; then
            echo "Trace 01 restart file in "${SCRIPT}": "${target_restart}" is copied from "${source_restart}
            ${CP} ${source_restart} ${target_restart}
        fi
    done
else
    target_restart=${SAVEDIR}/vector/ufs_land_restart_back.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
    source_restart=${RSTDIR}/ufs_land_restart.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
    if [[ ! -e ${target_restart} ]]; then
        if [[ -e ${source_restart} ]]; then
            echo "Trace 02A restart file in "${SCRIPT}": "${target_restart}" is copied from "${source_restart}
            ${CP} ${source_restart} ${target_restart}
        else
            echo "Trace 02B restart file in "${SCRIPT}": "${target_restart}" is copied from "${source_restart}
            source_restart=${RSTDIR}/ufs_land_restart_back.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
            ${CP} ${source_restart} ${target_restart}
        fi
    fi
fi

THISDATE=$STARTDATE

date_count=0

while [ $date_count -lt $dates_per_job ]; do

    if [ $THISDATE -ge $ENDDATE ]; then 
        echo "All done, at date ${THISDATE}"  >> $logfile
        cd $CYCLEDIR 
        ${RM} -rf $WORKDIR
        exit  
    fi

    echo "starting $THISDATE"  

    # Create output directory and temporary workdir for ecah ensemble member
    if [[ -d ${WORKDIR} ]]; then
      ${RM} -rf ${WORKDIR}
    fi

    ${MKDIR} ${WORKDIR}
    cd ${WORKDIR}

    if [ $do_ens == "YES" ] && [ $ensemble_size -gt 1 ]; then
        for ens_member in "${ens_list[@]}"
        do
            ENSEMBLE_DIR=${WORKDIR}/${ens_member}
            OUTPUT_DIR=${MODLDIR}/${ens_member}
            ${MKDIR} -p ${ENSEMBLE_DIR}
            ${MKDIR} ${ENSEMBLE_DIR}/restarts
            ${MKDIR} ${ENSEMBLE_DIR}/restarts/tile
            ${MKDIR} ${ENSEMBLE_DIR}/restarts/vector
            ${MKDIR} -p ${OUTPUT_DIR}
            ${LN} -s ${OUTPUT_DIR} ${ENSEMBLE_DIR}/noahmp_output
        done
    else
        ${MKDIR} ${WORKDIR}/restarts
        ${MKDIR} ${WORKDIR}/restarts/tile
        ${MKDIR} ${WORKDIR}/restarts/vector
        ${LN} -s ${MODLDIR} ${WORKDIR}/noahmp_output
    fi

    # substringing to get yr, mon, day, hr info
    export YYYY=`echo $THISDATE | ${CUT} -c1-4`
    export MM=`echo $THISDATE | ${CUT} -c5-6`
    export DD=`echo $THISDATE | ${CUT} -c7-8`
    export HH=`echo $THISDATE | ${CUT} -c9-10`

    # for each ensemble member
    for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
    do
        if [ $do_ens == "YES" ]; then
            ens_member=${ens_list[$ensemble_count]}
            ENSEMBLE_DIR=${WORKDIR}/${ens_member}
            restart_back_id=.${ens_member}_back
        else
            ENSEMBLE_DIR=${WORKDIR}
            restart_back_id='_back'
        fi

        cd ${ENSEMBLE_DIR}

        # copy initial restart
        source_restart=${SAVEDIR}/vector/ufs_land_restart${restart_back_id}.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
        target_restart=${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
        echo "Trace 03 restart file in "${SCRIPT}": "${target_restart}" is copied from "${source_restart}
        ${CP} ${source_restart} ${target_restart}

        if [ $do_jedi == "YES" ]; then

            # update vec2tile and tile2vec namelists
            ${CP}  ${CYCLEDIR}/template.vector2tile vector2tile.namelist

            ${SED} -i -e "s/XXYYYY/${YYYY}/g" vector2tile.namelist
            ${SED} -i -e "s/XXMM/${MM}/g" vector2tile.namelist
            ${SED} -i -e "s/XXDD/${DD}/g" vector2tile.namelist
            ${SED} -i -e "s/XXHH/${HH}/g" vector2tile.namelist

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
            ${CP}  ${CYCLEDIR}/template.coupler.res $cres_file

            ${SED} -i -e "s/XXYYYY/${YYYY}/g" $cres_file
            ${SED} -i -e "s/XXMM/${MM}/g" $cres_file
            ${SED} -i -e "s/XXDD/${DD}/g" $cres_file

        fi
    done
    wait

    if [ $do_jedi == "YES" ]; then  # do DA
        # submit snow DA 
        echo '************************************************'
        echo 'calling snow DA'
        export THISDATE
        $DAscript
        if [[ $? != 0 ]]; then
            echo "land DA script failed"
            exit
        fi
    fi

    # for each ensemble member
    for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
    do
        if [ $do_ens == "YES" ]; then
            ens_member=${ens_list[$ensemble_count]}
            ENSEMBLE_DIR=${WORKDIR}/${ens_member}
            restart_anal_id=.${ens_member}_anal
            restart_back_id=.${ens_member}_back
        else
            ENSEMBLE_DIR=${WORKDIR}
            restart_anal_id='_anal'
            restart_back_id='_back'
        fi

        cd ${ENSEMBLE_DIR}

        if [ $do_jedi == "YES" ]; then
            ${CP}  ${CYCLEDIR}/template.tile2vector tile2vector.namelist

            ${SED} -i -e "s/XXYYYY/${YYYY}/g" tile2vector.namelist
            ${SED} -i -e "s/XXMM/${MM}/g" tile2vector.namelist
            ${SED} -i -e "s/XXDD/${DD}/g" tile2vector.namelist
            ${SED} -i -e "s/XXHH/${HH}/g" tile2vector.namelist

            echo '************************************************'
            echo 'calling tile2vector' 
            $vec2tileexec tile2vector.namelist
            if [[ $? != 0 ]]; then
                echo "tile2vector failed"
                exit 
            fi

            # save analysis restart
            source_restart=${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
            target_restart=${SAVEDIR}/vector/ufs_land_restart${restart_anal_id}.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
            echo "Trace 09 restart file in "${SCRIPT}": "${target_restart}" is copied from "${source_restart}
            ${CP} ${source_restart} ${target_restart}
        fi

        # update model namelist 
        if [ $do_ens == "YES" ]; then
            namelist_file=${CYCLEDIR}/template.ens.ufs-noahMP.namelist.gswp3
        else
            namelist_file=${CYCLEDIR}/template.ufs-noahMP.namelist.gdas
        fi
        #force UFS Noah-MP namelist
        namelist_file=${CYCLEDIR}/template.ufs-noahMP.namelist.gdas
        ${CP}  ${namelist_file}  ufs-land.namelist

        ${SED} -i -e "s/XXYYYY/${YYYY}/g" ufs-land.namelist 
        ${SED} -i -e "s/XXMM/${MM}/g" ufs-land.namelist
        ${SED} -i -e "s/XXDD/${DD}/g" ufs-land.namelist
        ${SED} -i -e "s/XXHH/${HH}/g" ufs-land.namelist

        # Match the variable names in forcing files to those in land drivers for the namelist
#       if [ $do_ens == "YES" ]; then
#           for (( variable_count=0; variable_count<variable_size; variable_count++ ))
#           do
#               vname_proxy=USER_${frc_in_list[$variable_count]}
#               vname_in_file=${frc_in_file[$variable_count]}
#               ${SED} -i -e "s/${vname_proxy}/${vname_in_file}${ens_member}/g" ufs-land.namelist
#           done
#       fi
     
        # submit model
        echo '************************************************'
        if [ $do_ens == "YES" ]; then
            echo 'calling model for ensemble member '${ens_member}
        else
            echo 'calling model'
        fi
        $LSMexec

        NEXTDATE=`${incdate} $THISDATE 24`
        CUR_YYYY=`echo ${NEXTDATE} | ${CUT} -c1-4`
        CUR_MM=`echo ${NEXTDATE} | ${CUT} -c5-6`
        CUR_DD=`echo ${NEXTDATE} | ${CUT} -c7-8`
        CUR_HH=`echo ${NEXTDATE} | ${CUT} -c9-10`

        source_restart=${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${CUR_YYYY}-${CUR_MM}-${CUR_DD}_${CUR_HH}-00-00.nc
        target_restart=${SAVEDIR}/vector/ufs_land_restart${restart_back_id}.${CUR_YYYY}-${CUR_MM}-${CUR_DD}_${CUR_HH}-00-00.nc
        echo "Trace 10 restart file in "${SCRIPT}": "${target_restart}" is copied from "${source_restart}
        if [[ -e ${source_restart} ]]; then
           ${CP} ${source_restart} ${target_restart}
           if [ $do_ens == "YES" ]; then
               echo "Finished job number, ${date_count},for ensemble member: ${ens_member}, for date: ${THISDATE}" >> $logfile
           else
               echo "Finished job number, ${date_count}, for date: ${THISDATE}" >> $logfile
           fi
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
    ${RM} -rf ${WORKDIR}
    sbatch ${CYCLEDIR}/submit_cycle_ens.sh
fi

