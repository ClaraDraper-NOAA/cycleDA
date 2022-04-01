############################
# experiment name
export exp_name=

############################
# model options
# ensemble_size of 1: LETKF-OI pseudo ensemble or do not run ensemble
export ensemble_size=1 

#options: gdas, gswp3, gefs_ens
export atmos_forc=gdas

# number of cycles to submit in a single job
export dates_per_job=2

############################
# DA options
# select "hofx" for using JEDI to calculate hofx, but do not do update
#        "LETKF-OI" or "LETKF" for doing full DA update
#        "NO" for running ufs-land-driver only
export do_DA=LETKF-OI

# options: "letkfoi_snow" , "letkf_snow"
export DAtype=letkfoi_snow

export ASSIM_IMS=NO
export ASSIM_GHCN=YES
export ASSIM_SYNTH=NO
export ASSIM_GTS=NO
export CYCHR=24

############################
# set your directories
# experiment directory
export EXPDIR=

# repo directory
export CYCLEDIR=
export DIFF_CYCLEDIR=

# temporary work dir
export WORKDIR=

# Observation directory
export OBSDIR=

# JEDI FV3 Bundle directories
export JEDI_EXECDIR=

# JEDI IODA-converter bundle directories
export IODA_BUILD_DIR=

# OUTDIR for experiment with initial conditions
# will use ensemble of restarts if present, otherwise will try 
# to copy a non-ensemble restart into each ensemble restart
export ICSDIR=
