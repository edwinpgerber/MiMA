#!/bin/csh -f
#Minimal runscript for atmospheric dynamical cores
set echo 
#--------------------------------------------------------------------------------------------------------
# define variables
set platform  = nyu                                     # A unique identifier for your platform
set npes      = 16                                       # number of processors
set template  = $cwd/../bin/mkmf.template.$platform   # path to template for your platform
set mkmf      = $cwd/../bin/mkmf                      # path to executable mkmf
set sourcedir = $cwd/../src                           # path to directory containing model source code
set mppnccombine = $cwd/../bin/mppnccombine.$platform # path to executable mppnccombine
#--------------------------------------------------------------------------------------------------------
set execdir   = $cwd/exec.$platform       # where code is compiled and executable is created
set workdir   = $cwd/workdir              # where model is run and model output is produced
set pathnames = $cwd/path_names           # path to file containing list of source paths
set namelist  = $cwd/namelists            # path to namelist file
set diagtable = $cwd/diag_table           # path to diagnositics table
set fieldtable = $cwd/field_table         # path to field table (specifies tracers)
#--------------------------------------------------------------------------------------------------------
# compile mppnccombine.c, will be used only if $npes > 1
if ( ! -f $mppnccombine ) then
  icc -O -o $mppnccombine -I$NETCDF_INC -L$NETCDF_LIB $cwd/../postprocessing/mppnccombine.c -lnetcdf
endif
#--------------------------------------------------------------------------------------------------------
