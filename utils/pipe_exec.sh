# *- bash -*

# INCLUDE BASH LIBRARY
. ${panpipe_bindir}/panpipe_lib || exit 1

#############
# CONSTANTS #
#############

# MISC. CONSTANTS
LOCKFD=99
MAX_NUM_SCRIPT_OPTS_TO_DISPLAY=10

# BUILTIN SCHEDULER CONSTANTS
BUILTIN_SCHED_FAILED_STEP_STATUS="FAILED"

####################
# GLOBAL VARIABLES #
####################

# Declare builtin scheduler-related variables
declare -A BUILTIN_SCHED_STEP_STATUS
declare -A BUILTIN_SCHED_STEP_SPEC
declare -A BUILTIN_SCHED_STEP_DEPS
declare -A BUILTIN_SCHED_STEP_CPU
declare -A BUILTIN_SCHED_STEP_MEM
declare -A BUILTIN_SCHED_STEP_EXIT_CODES
declare -A BUILTIN_SCHED_ACTIVE_STEPS
declare BUILTIN_SCHED_SELECTED_STEPS
declare BUILTIN_SCHED_CPUS=1
declare BUILTIN_SCHED_MEM=256
declare BUILTIN_SCHED_ALLOC_CPUS=0
declare BUILTIN_SCHED_ALLOC_MEM=0

#############################
# OPTION HANDLING FUNCTIONS #
#############################

########
print_desc()
{
    echo "pipe_exec executes general purpose pipelines"
    echo "type \"pipe_exec --help\" to get usage information"
}

########
usage()
{
    echo "pipe_exec                 --pfile <string> --outdir <string> [--sched <string>]"
    echo "                          [--dflt-nodes <string>] [--dflt-throttle <string>]"
    echo "                          [--cfgfile <string>] [--reexec-outdated-steps]"
    echo "                          [--conda-support] [--showopts|--checkopts|--debug]"
    echo "                          [--version] [--help]"
    echo ""
    echo "--pfile <string>          File with pipeline steps to be performed (see manual"
    echo "                          for additional information)"
    echo "--outdir <string>         Output directory"
    echo "--sched <string>          Scheduler used to execute the pipeline (if not given,"
    echo "                          it is determined using information gathered during"
    echo "                          package configuration)" 
    echo "--dflt-nodes <string>     Default set of nodes used to execute the pipeline"
    echo "--dflt-throttle <string>  Default task throttle used when executing job arrays"
    echo "--cfgfile <string>        File with options (options provided in command line"
    echo "                          overwrite those given in the configuration file)"
    echo "--reexec-outdated-steps   Reexecute those steps with outdated code"
    echo "--conda-support           Enable conda support"
    echo "--showopts                Show pipeline options"
    echo "--checkopts               Check pipeline options"
    echo "--debug                   Do everything except launching pipeline steps"
    echo "--version                 Display version information and exit"
    echo "--help                    Display this help and exit"
}

########
save_command_line()
{
    input_pars="$*"
    command_name=$0
}

########
read_pars()
{
    pfile_given=0
    outdir_given=0
    sched_given=0
    dflt_nodes_given=0
    dflt_throttle_given=0
    cfgfile_given=0
    reexec_outdated_steps_given=0
    conda_support_given=0
    showopts_given=0
    checkopts_given=0
    debug=0
    while [ $# -ne 0 ]; do
        case $1 in
            "--help") usage
                      exit 1
                      ;;
            "--version") panpipe_version
                         exit 1
                         ;;
            "--pfile") shift
                  if [ $# -ne 0 ]; then
                      pfile=$1
                      pfile_given=1
                  fi
                  ;;
            "--outdir") shift
                  if [ $# -ne 0 ]; then
                      outd=$1
                      outdir_given=1
                  fi
                  ;;
            "--sched") shift
                  if [ $# -ne 0 ]; then
                      sched=$1
                      sched_given=1
                  fi
                  ;;
            "--dflt-nodes") shift
                  if [ $# -ne 0 ]; then
                      dflt_nodes=$1
                      dflt_nodes_given=1
                  fi
                  ;;
            "--dflt-throttle") shift
                  if [ $# -ne 0 ]; then
                      dflt_throttle=$1
                      dflt_throttle_given=1
                  fi
                  ;;
            "--cfgfile") shift
                  if [ $# -ne 0 ]; then
                      cfgfile=$1
                      cfgfile_given=1
                  fi
                  ;;
            "--reexec-outdated-steps")
                  if [ $# -ne 0 ]; then
                      reexec_outdated_steps_given=1
                  fi
                  ;;
            "--conda-support")
                  if [ $# -ne 0 ]; then
                      conda_support_given=1
                  fi
                  ;;
            "--showopts") showopts_given=1
                  ;;
            "--checkopts") checkopts_given=1
                  ;;
            "--debug") debug=1
                      ;;
        esac
        shift
    done   
}

########
check_pars()
{
    if [ ${pfile_given} -eq 0 ]; then   
        echo "Error! --pfile parameter not given!" >&2
        exit 1
    else
        if [ ! -f ${pfile} ]; then
            echo "Error! file ${pfile} does not exist" >&2
            exit 1
        fi
    fi
    
    if [ ${outdir_given} -eq 0 ]; then
        echo "Error! --outdir parameter not given!" >&2
        exit 1
    else
        if [ -d ${outd} ]; then
            echo "Warning! output directory does exist" >&2 
        fi
    fi

    if [ ${cfgfile_given} -eq 1 ]; then
        if [ ! -f ${cfgfile} ]; then
            echo "Error: ${cfgfile} file does not exist" >&2
            exit 1
        fi
    fi

    if [ ${showopts_given} -eq 1 -a ${checkopts_given} -eq 1 ]; then
        echo "Error! --showopts and --checkopts options cannot be given simultaneously"
        exit 1
    fi

    if [ ${showopts_given} -eq 1 -a ${debug} -eq 1 ]; then
        echo "Error! --showopts and --debug options cannot be given simultaneously"
        exit 1
    fi

    if [ ${checkopts_given} -eq 1 -a ${debug} -eq 1 ]; then
        echo "Error! --checkopts and --debug options cannot be given simultaneously"
        exit 1
    fi
}

########
absolutize_file_paths()
{
    if [ ${pfile_given} -eq 1 ]; then   
        pfile=`get_absolute_path ${pfile}`
    fi

    if [ ${outdir_given} -eq 1 ]; then   
        outd=`get_absolute_path ${outd}`
    fi

    if [ ${cfgfile_given} -eq 1 ]; then   
        cfgfile=`get_absolute_path ${cfgfile}`
    fi
}

########
check_pipeline_file()
{
    echo "* Checking pipeline file ($pfile)..." >&2

    ${panpipe_bindir}/pipe_check -p ${pfile} || return 1

    echo "" >&2
}

####################################
# GENERAL PIPE EXECUTION FUNCTIONS #
####################################

########
reorder_pipeline_file()
{
    echo "* Obtaining reordered pipeline file ($pfile)..." >&2

    ${panpipe_bindir}/pipe_check -p ${pfile} -r 2> /dev/null || return 1

    echo "" >&2
}

########
gen_stepdeps()
{
    echo "* Generating step dependencies information ($pfile)..." >&2

    ${panpipe_bindir}/pipe_check -p ${pfile} -d 2> /dev/null || return 1

    echo "" >&2
}

########
configure_scheduler()
{
    echo "* Configuring scheduler..." >&2
    echo "" >&2

    if [ ${sched_given} -eq 1 ]; then
        echo "** Setting scheduler type from value of \"--sched\" option..." >&2
        set_panpipe_scheduler ${sched} || return 1
        echo "scheduler: ${sched}" >&2
        echo "" >&2
    fi

    if [ ${dflt_nodes_given} -eq 1 ]; then
        echo "** Setting default nodes for pipeline execution... (${dflt_nodes})" >&2
        set_panpipe_default_nodes ${dflt_nodes} || return 1
        echo "" >&2
    fi

    if [ ${dflt_throttle_given} -eq 1 ]; then
        echo "** Setting default job array task throttle... (${dflt_throttle})" >&2
        set_panpipe_default_array_task_throttle ${dflt_throttle} || return 1
        echo "" >&2
    fi
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
show_pipeline_opts()
{
    echo "* Pipeline options..." >&2

    # Read input parameters
    local pfile=$1

    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`
            local explain_cmdline_opts_funcname=`get_explain_cmdline_opts_funcname ${stepname}`
            DIFFERENTIAL_CMDLINE_OPT_STR=""
            ${explain_cmdline_opts_funcname} || exit 1
            update_opt_to_step_map ${stepname} "${DIFFERENTIAL_CMDLINE_OPT_STR}"
        fi
    done < ${pfile}

    # Print options
    print_pipeline_opts

    echo "" >&2
}

########
check_pipeline_opts()
{
    echo "* Checking pipeline options..." >&2
    
    # Read input parameters
    local cmdline=$1
    local pfile=$2
        
    # Read information about the steps to be executed
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`
            define_opts_for_script "${cmdline}" "${stepspec}" || return 1
            local script_opts_array=("${SCRIPT_OPT_LIST_ARRAY[@]}")
            local serial_script_opts=`serialize_string_array "script_opts_array" " ||| " ${MAX_NUM_SCRIPT_OPTS_TO_DISPLAY}`
            echo "STEP: ${stepname} ; OPTIONS: ${serial_script_opts}" >&2
        fi
    done < ${pfile}

    echo "" >&2
}

########
process_conda_req_entry() 
{
    local env_name=$1
    local yml_fname=$2

    # Check if environment already exists
    if conda_env_exists ${env_name}; then
        :
    else
        local condadir=`get_absolute_condadir`

        # Obtain absolute yml file name
        local abs_yml_fname=`get_abs_yml_fname ${yml_fname}`

        echo "Creating conda environment ${env_name} from file ${abs_yml_fname}..." >&2
        conda_env_prepare ${env_name} ${abs_yml_fname} ${condadir} || return 1
        echo "Package successfully installed"
    fi
}

########
process_conda_requirements_for_step()
{
    stepname=$1
    step_conda_envs=$2

    # Read information about conda environments
    while read conda_env_entry; do
        # Convert string to array
        local array
        IFS=' ' read -r -a array <<< $conda_env_entry
        local arraylen=${#array[@]}
        if [ ${arraylen} -ge 2 ]; then
            local env_name=${array[0]}
            local yml_fname=${array[1]}
            process_conda_req_entry ${env_name} ${yml_fname} || return 1
        else
            echo "Error: invalid conda entry for step ${stepname}; Entry: ${step_conda_envs}" >&2
        fi        
    done < <(echo ${step_conda_envs})
}

########
process_conda_requirements()
{
    echo "* Processing conda requirements (if any)..." >&2

    # Read input parameters
    local pfile=$1

    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`
            
            # Process conda envs information
            local conda_envs_funcname=`get_conda_envs_funcname ${stepname}`
            if check_func_exists ${conda_envs_funcname}; then
                step_conda_envs=`${conda_envs_funcname}` || exit 1
                process_conda_requirements_for_step ${stepname} "${step_conda_envs}" || return 1
            fi
        fi
    done < ${pfile}

    echo "Processing complete" >&2

    echo "" >&2
}

########
define_forced_exec_steps()
{
    echo "* Defining steps forced to be reexecuted (if any)..." >&2

    # Read input parameters
    local pfile=$1

    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`
            local step_forced=`extract_attr_from_stepspec "$stepspec" "force"`
            if [ ${step_forced} = "yes" ]; then
                mark_step_as_reexec $stepname ${FORCED_REEXEC_REASON}
            fi 
        fi
    done < ${pfile}

    echo "Definition complete" >&2

    echo "" >&2
}

########
check_script_is_older_than_modules()
{
    local script_filename=$1
    local fullmodnames=$2
    
    # Check if script exists
    if [ -f ${script_filename} ]; then
        # script exists
        script_older=0
        local mod
        for mod in ${fullmodnames}; do
            if [ ${script_filename} -ot ${mod} ]; then
                script_older=1
                echo "Warning: ${script_filename} is older than module ${mod}" >&2
            fi
        done
        # Return value
        if [ ${script_older} -eq 1 ]; then
            return 0
        else
            return 1
        fi
    else
        # script does not exist
        echo "Warning: ${script_filename} does not exist" >&2
        return 0
    fi
}

########
define_reexec_steps_due_to_code_update()
{
    echo "* Defining steps to be reexecuted due to code updates (if any)..." >&2

    # Read input parameters
    local dirname=$1
    local pfile=$2

    # Get names of pipeline modules
    local fullmodnames=`get_pipeline_fullmodnames $pfile` || return 1

    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`
            local status=`get_step_status ${dirname} ${stepname}`
            local script_filename=`get_script_filename ${dirname} ${stepname}`

            # Handle checkings depending of step status
            if [ "${status}" = "${FINISHED_STEP_STATUS}" ]; then
                if check_script_is_older_than_modules ${script_filename} "${fullmodnames}"; then
                    echo "Warning: last execution of step ${stepname} used outdated modules">&2
                    mark_step_as_reexec $stepname ${OUTDATED_CODE_REEXEC_REASON}
                fi
            fi

            if [ "${status}" = "${INPROGRESS_STEP_STATUS}" ]; then
                if check_script_is_older_than_modules ${script_filename} "${fullmodnames}"; then
                    echo "Warning: current execution of step ${stepname} is using outdated modules">&2
                fi
            fi
        fi
    done < ${pfile}

    echo "Definition complete" >&2

    echo "" >&2
}

########
define_reexec_steps_due_to_deps()
{
    echo "* Defining steps to be reexecuted due to dependencies (if any)..." >&2

    local stepdeps_file=$1
    
    # Obtain list of steps to be reexecuted due to dependencies
    local reexec_steps_string=`get_reexec_steps_as_string`
    local reexec_steps_file=${outd}/.reexec_steps_due_to_deps.txt
    ${panpipe_bindir}/get_reexec_steps_due_to_deps -r "${reexec_steps_string}" -d ${stepdeps_file} > ${reexec_steps_file} || return 1

    # Read information about the steps to be re-executed due to
    # dependencies
    local stepname
    while read stepname; do
        if [ "${stepname}" != "" ]; then
            mark_step_as_reexec $stepname ${DEPS_REEXEC_REASON}
        fi
    done < ${reexec_steps_file}

    echo "Definition complete" >&2

    echo "" >&2
}

########
release_lock()
{
    local fd=$1
    local file=$2

    $FLOCK -u $fd
    $FLOCK -xn $fd && rm -f $file
}

########
prepare_lock()
{
    local fd=$1
    local file=$2
    eval "exec $fd>\"$file\""; trap "release_lock $fd $file" EXIT;
}

########
ensure_exclusive_execution()
{
    local lockfile=${outd}/lock

    prepare_lock $LOCKFD $lockfile

    $FLOCK -xn $LOCKFD || return 1
}

########
create_basic_dirs()
{
    mkdir -p ${outd} || { echo "Error! cannot create output directory" >&2; return 1; }
    set_panpipe_outdir ${outd}
    
    mkdir -p ${outd}/scripts || { echo "Error! cannot create scripts directory" >&2; return 1; }

    local fifodir=`get_absolute_fifoname`
    mkdir -p ${fifodir} || { echo "Error! cannot create fifos directory" >&2; return 1; }

    local condadir=`get_absolute_condadir`
    if [ ${conda_support_given} -eq 1 ]; then
        mkdir -p ${condadir}
    fi
}

########
create_shared_dirs()
{
    # Create shared directories required by the pipeline steps
    # IMPORTANT NOTE: the following function can only be executed after
    # loading pipeline modules
    create_pipeline_shdirs
}

########
register_fifos()
{
    # Register FIFOs (named pipes) required by the pipeline steps
    # IMPORTANT NOTE: the following function can only be executed after
    # loading pipeline modules
    register_pipeline_fifos
}

########
print_command_line()
{
    echo "cd $PWD" > ${outd}/command_line.sh
    echo ${command_line} >> ${outd}/command_line.sh
}

########
obtain_augmented_cmdline()
{
    local cmdline=$1
    
    if [ ${cfgfile_given} -eq 1 ]; then
        echo "* Processing configuration file (${cfgfile})..." >&2
        cfgfile_str=`cfgfile_to_string ${cfgfile}` || return 1
        echo "${cmdline} ${cfgfile_str}"
        echo "" >&2
    else
        echo $cmdline
    fi
}

########
get_stepdeps_from_detailed_spec()
{
    local stepdeps_spec=$1
    local sdeps=""

    # Iterate over the elements of the step specification: type1:stepname1,...,typen:stepnamen
    local stepdeps_spec_blanks=`replace_str_elem_sep_with_blank "," ${stepdeps_spec}`
    local dep_spec
    for dep_spec in ${stepdeps_spec_blanks}; do
        local deptype=`get_deptype_part_in_dep ${dep_spec}`
        local step=`get_stepname_part_in_dep ${dep_spec}`
        
        # Check if there is a id for the step
        local step_id=${step}_id
        if [ ! -z "${!step_id}" ]; then
            if [ -z "${sdeps}" ]; then
                sdeps=${deptype}":"${!step_id}
            else
                sdeps=${sdeps}","${deptype}":"${!step_id}
            fi
        fi
    done

    echo ${sdeps}
}

########
get_stepdeps()
{
    local stepdeps_spec=$1
    case ${stepdeps_spec} in
            "afterok:all") apply_deptype_to_stepids ${step_ids} afterok
                    ;;
            "none") echo ""
                    ;;
            *) get_stepdeps_from_detailed_spec ${stepdeps_spec}
               ;;
    esac
}

########
archive_script()
{
    local script_filename=$1
        
    # Archive script with date info
    local curr_date=`date '+%Y_%m_%d'`
    cp ${script_filename} ${script_filename}.${curr_date}
}

########
execute_step()
{
    # Initialize variables
    local cmdline=$1
    local dirname=$2
    local stepname=$3
    local stepspec=$4
    
    # Execute step

    ## Obtain step status
    local status=`get_step_status ${dirname} ${stepname}`
    echo "STEP: ${stepname} ; STATUS: ${status} ; STEPSPEC: ${stepspec}" >&2

    ## Decide whether the step should be executed
    if [ "${status}" != "${FINISHED_STEP_STATUS}" -a "${status}" != "${INPROGRESS_STEP_STATUS}" ]; then
        # Create script
        local script_filename=`get_script_filename ${dirname} ${stepname}`
        local step_function=`get_name_of_step_function ${stepname}`
        local step_function_post=`get_name_of_step_function_post ${stepname}`
        define_opts_for_script "${cmdline}" "${stepspec}" || return 1
        local script_opts_array=("${SCRIPT_OPT_LIST_ARRAY[@]}")
        local array_size=${#script_opts_array[@]}
        create_script ${script_filename} ${step_function} "${step_function_post}" "script_opts_array"

        # Archive script
        archive_script ${script_filename}

        # Prepare files and directories for step
        update_step_completion_signal ${status} ${script_filename} || { echo "Error when updating step completion signal for step" >&2 ; return 1; }
        clean_step_log_files ${array_size} ${script_filename} || { echo "Error when cleaning log files for step" >&2 ; return 1; }
        local remove=0
        if [ ${array_size} -eq 1 ]; then
            remove=1
        fi
        prepare_outdir_for_step ${dirname} ${stepname} ${remove} || { echo "Error when preparing output directory for step" >&2 ; return 1; }
        prepare_fifos_owned_by_step ${stepname}
        
        # Execute script
        local job_array_list=`get_job_array_list ${array_size} ${script_filename}`
        local stepdeps_spec=`extract_stepdeps_from_stepspec "$stepspec"`
        local stepdeps="`get_stepdeps ${stepdeps_spec}`"
        local stepname_id=${stepname}_id
        launch ${script_filename} "${job_array_list}" "${stepspec}" "${stepdeps}" ${stepname_id} || { echo "Error while launching step!" >&2 ; return 1; }
        
        # Update variables storing ids
        step_ids="${step_ids}:${!stepname_id}"

        # Write id to file
        write_step_id_to_file ${dirname} ${stepname} ${!stepname_id}
    else
        # If step is in progress, its id should be retrieved so as to
        # correctly express dependencies
        if [ "${status}" = "${INPROGRESS_STEP_STATUS}" ]; then
            local stepname_id=${stepname}_id
            local sid=`read_step_id_from_file ${dirname} ${stepname}` || { echo "Error while retrieving id of in-progress step" >&2 ; return 1; }
            eval "${stepname_id}='${sid}'"
            step_ids="${step_ids}:${!stepname_id}"
        fi        
    fi
}

########
execute_pipeline_steps()
{
    echo "* Executing pipeline steps..." >&2

    # Read input parameters
    local cmdline=$1
    local dirname=$2
    local pfile=$3
        
    # step_ids will store the step ids of the pipeline steps
    local step_ids=""
    
    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step name
            local stepname=`extract_stepname_from_stepspec "$stepspec"`

            execute_step "${cmdline}" ${dirname} ${stepname} "${stepspec}" || return 1
        fi
    done < ${pfile}

    echo "" >&2
}

########
debug_step()
{
    # Initialize variables
    local cmdline=$1
    local dirname=$2
    local stepname=$3
    local stepspec=$4
    
    # Debug step

    ## Obtain step status
    local status=`get_step_status ${dirname} ${stepname}`
    echo "STEP: ${stepname} ; STATUS: ${status} ; STEPSPEC: ${stepspec}" >&2

    ## Obtain step options
    local define_opts_funcname=`get_define_opts_funcname ${stepname}`
    ${define_opts_funcname} "${cmdline}" "${stepspec}" || return 1
}

########
execute_pipeline_steps_debug()
{
    echo "* Executing pipeline steps... (debug mode)" >&2

    # Read input parameters
    local cmdline=$1
    local dirname=$2
    local pfile=$3
        
    # step_ids will store the step ids of the pipeline steps
    local step_ids=""
    
    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step name
            local stepname=`extract_stepname_from_stepspec "$stepspec"`

            debug_step "${cmdline}" ${dirname} ${stepname} "${stepspec}" || return 1                
        fi
    done < ${pfile}

    echo "" >&2
}

###############################
# BUILTIN SCHEDULER FUNCTIONS #
###############################

########
builtin_sched_init_step_status()
{
    local dirname=$1
    local pfile=$2

    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`
            local status=`get_step_status ${dirname} ${stepname}`
            local stepdeps=`extract_stepdeps_from_stepspec "$stepspec"`
            local cpus=`extract_cpus_from_stepspec "$stepspec"`
            local mem=`extract_mem_from_stepspec "$stepspec"`

            # Register step information
            BUILTIN_SCHED_STEP_STATUS[${stepname}]=${status}   
            BUILTIN_SCHED_STEP_SPEC[${stepname}]=${stepspec}   
            BUILTIN_SCHED_STEP_DEPS[${stepname}]=${stepdeps}
            BUILTIN_SCHED_STEP_CPU[${stepname}]=${cpus}
            BUILTIN_SCHED_STEP_MEM[${stepname}]=${mem}
        fi
    done < ${pfile}
}

########
builtin_sched_init_active_steps()
{
    # Iterate over defined steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_STEP_STATUS[@]}"; do
        status=${BUILTIN_SCHED_STEP_STATUS[${stepname}]}
        if [ ${status} != ${FINISHED_STEP_STATUS} ]; then
            BUILTIN_SCHED_ACTIVE_STEPS[${stepname}]=${status}
        fi
    done
}

########
builtin_sched_get_updated_step_status()
{
    local dirname=$1

    # Iterate over defined steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_ACTIVE_STEPS[@]}"; do
        local status=`get_step_status ${dirname} ${stepname}`
        BUILTIN_SCHED_ACTIVE_STEPS_UPDATED[${stepname}]=${status}
    done
}

########
builtin_sched_release_mem()
{
    local stepname=$1
    BUILTIN_SCHED_ALLOC_MEM=`expr BUILTIN_SCHED_ALLOC_MEM - BUILTIN_SCHED_STEP_MEM[${stepname}]`
}

########
builtin_sched_release_cpus()
{
    local stepname=$1
    BUILTIN_SCHED_ALLOC_CPUS=`expr BUILTIN_SCHED_ALLOC_CPUS - BUILTIN_SCHED_STEP_CPUS[${stepname}]`    
}

########
builtin_sched_reserve_mem()
{
    local stepname=$1
    BUILTIN_SCHED_ALLOC_MEM=`expr BUILTIN_SCHED_ALLOC_MEM + BUILTIN_SCHED_STEP_MEM[${stepname}]`
}

########
builtin_sched_reserve_cpus()
{
    local stepname=$1
    BUILTIN_SCHED_ALLOC_CPUS=`expr BUILTIN_SCHED_ALLOC_CPUS + BUILTIN_SCHED_STEP_CPUS[${stepname}]`    
}

########
builtin_sched_update_comp_resources()
{
    # Iterate over active steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_ACTIVE_STEPS[@]}"; do
        prev_status=${BUILTIN_SCHED_ACTIVE_STEPS[${stepname}]}
        updated_status=${BUILTIN_SCHED_ACTIVE_STEPS_UPDATED[${stepname}]}
        if [ "${updated_status}" != "" ]; then
            # Check if resources should be released
            if [ ${prev_status} = ${INPROGRESS_STEP_STATUS} -a ${updated_status} != ${INPROGRESS_STEP_STATUS} ]; then
                builtin_sched_release_mem $stepname
                builtin_sched_release_cpus $stepname
            fi

            # Check if resources should be reserved
            if [ ${prev_status} != ${INPROGRESS_STEP_STATUS} -a ${updated_status} = ${INPROGRESS_STEP_STATUS} ]; then
                builtin_sched_reserve_mem $stepname
                builtin_sched_reserve_cpus $stepname
            fi
        fi
    done
}
    
########
builtin_sched_fix_updated_step_status()
{
    # Copy updated status into current status
    local stepname
    for stepname in "${!BUILTIN_SCHED_ACTIVE_STEPS[@]}"; do
        prev_status=${BUILTIN_SCHED_ACTIVE_STEPS[${stepname}]}
        updated_status=${BUILTIN_SCHED_ACTIVE_STEPS_UPDATED[${stepname}]}
        if [ "${updated_status}" != "" ]; then
            if [ ${prev_status} = ${INPROGRESS_STEP_STATUS} -a ${updated_status} != ${INPROGRESS_STEP_STATUS} -a ${updated_status} != ${FINISHED_STEP_STATUS} ]; then
                BUILTIN_SCHED_ACTIVE_STEPS[${stepname}]=${BUILTIN_SCHED_FAILED_STEP_STATUS}
            else
                BUILTIN_SCHED_ACTIVE_STEPS[${stepname}]=${BUILTIN_SCHED_ACTIVE_STEPS_UPDATED[${stepname}]}
            fi
        fi
    done
}

########
get_available_cpus()
{
    echo `expr BUILTIN_SCHED_CPUS - BUILTIN_SCHED_ALLOC_CPUS`
}

########
get_available_mem()
{
    echo `expr BUILTIN_SCHED_MEM - BUILTIN_SCHED_ALLOC_MEM`
}

########
builtin_sched_check_comp_res()
{
    local stepname=$1

    local available_cpus=`get_available_cpus`
    if [ ${BUILTIN_SCHED_STEP_CPU} -gt ${available_cpus} ]; then
        return 1
    fi

    local available_mem=`get_available_mem`
    if [ ${BUILTIN_SCHED_STEP_MEM} -gt ${available_mem} ]; then
        return 1
    fi

    return 0
}

########
builtin_sched_check_step_deps()
{
    local stepname=$1
    local stepdeps=${BUILTIN_SCHED_STEP_DEPS[${stepname}]}

    # Iterate over dependencies
    local stepdeps_blanks=`replace_str_elem_sep_with_blank "," ${stepdeps}`
    local dep
    for dep in ${stepdeps_blanks}; do
        # Extract information from dependency
        local deptype=`get_deptype_part_in_dep ${dep}`
        local depsname=`get_stepname_part_in_dep ${dep}`

        # Process dependency
        depstatus=${BUILTIN_SCHED_STEP_STATUS[${depsname}]}
            
        # Process exit code
        case ${deptype} in
            ${AFTER_STEPDEP_TYPE})
                if [ ${depstatus} = ${TODO_STEP_STATUS} -o  ${depstatus} = ${UNFINISHED_STEP_STATUS} ]; then
                    return 1
                fi
                ;;
            ${AFTEROK_STEPDEP_TYPE})
                if [ ${depstatus} != ${FINISHED_STEP_STATUS} ]; then
                    return 1
                fi
                ;;
            ${AFTERNOTOK_STEPDEP_TYPE})
                if [ ${depstatus} != ${BUILTIN_SCHED_FAILED_STEP_STATUS} ]; then
                    return 1
                fi
                ;;
            ${AFTERANY_STEPDEP_TYPE})
                if [ ${depstatus} = ${FINISHED_STEP_STATUS} -o ${depstatus} = ${BUILTIN_SCHED_FAILED_STEP_STATUS} ]; then
                    return 1
                fi 
                ;;
        esac
    done

    return 0
}

########
builtin_sched_step_can_be_executed()
{
    local stepname=$1

    # Check there are enough computational resources
    builtin_sched_check_comp_res $stepname || return 1
    
    # Check step dependencies are satisfied
    builtin_sched_check_step_deps $stepname || return 1

    return 0
}

########
builtin_sched_get_executable_steps()
{    
    # Iterate over active steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_ACTIVE_STEPS[@]}"; do
        status=${BUILTIN_SCHED_ACTIVE_STEPS[${stepname}]}
        if [ ${status} !=${INPROGRESS_STEP_STATUS} -a ${status} !=${FINISHED_STEP_STATUS} -a ${status} !=${BUILTIN_SCHED_FAILED_STEP_STATUS} ]; then
            if builtin_sched_step_can_be_executed ${stepname}; then
                BUILTIN_SCHED_EXECUTABLE_STEPS[${stepname}]=1
            fi
        fi
    done
}

########
builtin_sched_select_steps_to_exec()
{
    local dirname=$1

    # Create file with item and weight specification
    specfile=${dirname}/.knapsack_spec.txt
    rm -f ${specfile}
    local stepname
    local step_value=1
    for stepname in "${!BUILTIN_SCHED_EXECUTABLE_STEPS[@]}"; do
        echo "$stepname $stepvalue BUILTIN_SCHED_STEP_CPUS[${stepname}] BUILTIN_SCHED_STEP_MEM[${stepname}]" >> ${specfile}
    done
    
    # Solve knapsack problem
    local available_cpus=`get_available_cpus`
    local available_mem=`get_available_mem`
    local time_limit=1
    local knapsack_sol=${dirname}/.knapsack_sol.txt
    ${panpipe_bindir}/solve_knapsack_ga -s ${specfile} -c ${available_cpus},${available_mem} -t ${time_limit} > ${knapsack_sol}

    # Store solution in output variable
    BUILTIN_SCHED_SELECTED_STEPS=`${AWK} -F ": " '{if($1=="Packed items") print $2}' ${knapsack_sol}`
}

########
builtin_sched_count_executable_steps()
{
    echo ${#BUILTIN_SCHED_EXECUTABLE_STEPS[@]}
}

########
builtin_sched_determine_steps_to_be_exec()
{
    local dirname=$1

    # Obtain updated status for steps
    local -A BUILTIN_SCHED_ACTIVE_STEPS_UPDATED
    builtin_sched_get_updated_step_status $dirname

    # Update computational resources depending on changes
    builtin_sched_update_comp_resources

    # Set updated status as current one
    builtin_sched_fix_updated_step_status

    # Obtain set of steps that can be executed
    local -A BUILTIN_SCHED_EXECUTABLE_STEPS
    builtin_sched_get_executable_steps

    # Get number of executable steps
    num_exec=`builtin_sched_count_executable_steps`

    if [ ${num_exec} -eq 0 ]; then
        # There are no executable steps
        return 1
    else
        # There are executable steps, select which ones will be executed
        builtin_sched_select_steps_to_exec $dirname

        return 0
    fi
}

########
builtin_sched_exec_steps_and_update_status()
{
    local cmdline=$1
    local dirname=$2

    for stepname in ${BUILTIN_SCHED_SELECTED_STEPS}; do
        # Execute step
        stepspec=${BUILTIN_SCHED_STEP_SPEC[${stepname}]}
        execute_step "${cmdline}" ${dirname} ${stepname} "${stepspec}" || return 1

        # Update step status
        BUILTIN_SCHED_ACTIVE_STEPS_UPDATED[${stepname}]=${INPROGRESS_STEP_STATUS}
    done
}
    
########
builtin_sched_exec_steps()
{
    local cmdline=$1
    local dirname=$2

    # Execute selected steps and update status accordingly
    local -A BUILTIN_SCHED_ACTIVE_STEPS_UPDATED
    builtin_sched_exec_steps_and_update_status "${cmdline}" $dirname

    # Update computational resources after execution
    builtin_sched_update_comp_resources

    # Set updated status as current one
    builtin_sched_fix_updated_step_status
}

########
execute_pipeline_steps_builtin()
{
    echo "* Executing pipeline steps..." >&2

    # Read input parameters
    local cmdline=$1
    local dirname=$2
    local pfile=$3

    # Initialize step status
    builtin_sched_init_step_status ${dirname} ${pfile}

    # Initialize active steps
    builtin_sched_init_active_steps
    
    # Execute scheduling loop
    local end=0
    local sleep_time=5
    while [ ${end} -eq 0 ]; do
        # Determine steps that should be executed
        if builtin_sched_determine_steps_to_be_exec ${dirname}; then
            # Execute steps
            builtin_sched_exec_steps "${cmdline}" ${dirname}
            
            sleep ${sleep_time}
        else
            # There are no steps to be executed
            end=1
        fi
    done
}

#################
# MAIN FUNCTION #
#################

########

if [ $# -eq 0 ]; then
    print_desc
    exit 1
fi

# Save command line
command_line="$0 $*"

read_pars $@ || exit 1

check_pars || exit 1

absolutize_file_paths || exit 1

create_basic_dirs || exit 1

check_pipeline_file || exit 1

reordered_pfile=${outd}/reordered_pipeline.ppl
reorder_pipeline_file > ${reordered_pfile} || exit 1

stepdeps_file=${outd}/.stepdeps.txt
gen_stepdeps > ${stepdeps_file} || exit 1

configure_scheduler || exit 1

load_modules ${reordered_pfile} || exit 1

if [ ${showopts_given} -eq 1 ]; then
    show_pipeline_opts ${reordered_pfile} || exit 1
else
    augmented_cmdline=`obtain_augmented_cmdline "${command_line}"` || exit 1
    
    if [ ${checkopts_given} -eq 1 ]; then
        check_pipeline_opts "${augmented_cmdline}" ${reordered_pfile} || exit 1
    else
        load_pipeline_modules=1
        check_pipeline_opts "${augmented_cmdline}" ${reordered_pfile} || exit 1
        
        # NOTE: exclusive execution should be ensured after creating the output directory
        ensure_exclusive_execution || { echo "Error: exec_pipeline is being executed for the same output directory" ; exit 1; }

        create_shared_dirs

        register_fifos

        if [ ${conda_support_given} -eq 1 ]; then
            process_conda_requirements ${reordered_pfile} || exit 1
        fi

        define_forced_exec_steps ${reordered_pfile} || exit 1

        if [ ${reexec_outdated_steps_given} -eq 1 ]; then
            define_reexec_steps_due_to_code_update ${outd} ${reordered_pfile} || exit 1
        fi
        
        define_reexec_steps_due_to_deps ${stepdeps_file} || exit 1

        print_command_line || exit 1

        if [ ${debug} -eq 1 ]; then
            execute_pipeline_steps_debug "${augmented_cmdline}" ${outd} ${pfile} || exit 1
        else
#            if [ ${sched} = ${BUILTIN_SCHEDULER} ]; then
#                execute_pipeline_steps_builtin "${augmented_cmdline}" ${outd} ${pfile} || exit 1
#            else
                execute_pipeline_steps "${augmented_cmdline}" ${outd} ${pfile} || exit 1
#            fi
        fi
    fi
fi
