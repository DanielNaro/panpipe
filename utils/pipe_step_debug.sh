# PanPipe package
# Copyright (C) 2019,2020 Daniel Ortiz-Mart\'inez
#  
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.
#  
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#  
# You should have received a copy of the GNU Lesser General Public License
# along with this program; If not, see <http://www.gnu.org/licenses/>.
  
# *- bash -*

# INCLUDE BASH LIBRARY
. ${panpipe_bindir}/panpipe_lib || exit 1

########
print_desc()
{
    echo "pipe_step_debug executes a pipeline step for debugging purposes"
    echo "Usage: pipe_step_debug <pplfile> <stepname> <options>"
}

########
read_pars()
{
    if [ $# -lt 3 ]; then
        return 1
    fi

    pfile=$1
    shift
    stepname=$1
    shift
    opts=$*
}

########
check_pipeline_file()
{
    echo "* Checking pipeline file ($pfile)..." >&2

    ${panpipe_bindir}/pipe_check -p ${pfile} || return 1

    echo "" >&2
}

########
load_modules()
{
    echo "* Loading pipeline modules..." >&2

    local pfile=$1
    
    load_pipeline_modules ${pfile} || return 1

    echo "" >&2
}

########
execute_step()
{
    # Initialize variables
    local stepname=$1
    local opts=$2
    
    # Execute step
    echo "Executing: $stepname $opts" >&2
    ${stepname} $opts
}

########

if [ $# -eq 0 ]; then
    print_desc
    exit 1
fi

read_pars $* || { echo "Error: wrong input parameters" >&2 ; exit 1; }

check_pipeline_file || exit 1

load_modules ${pfile} || exit 1

execute_step ${stepname} "${opts}" || exit 1    
