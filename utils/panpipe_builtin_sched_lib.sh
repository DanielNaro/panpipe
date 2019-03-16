# *- bash -*

#############
# CONSTANTS #
#############

BUILTIN_SCHED_FAILED_STEP_STATUS="FAILED"

####################
# GLOBAL VARIABLES #
####################

# Declare built-in scheduler-related variables
declare -A BUILTIN_SCHED_STEP_SCRIPT_FILENAME
declare -A BUILTIN_SCHED_STEP_SPEC
declare -A BUILTIN_SCHED_STEP_DEPS
declare -A BUILTIN_SCHED_STEP_ARRAY_SIZE
declare -A BUILTIN_SCHED_STEP_THROTTLE
declare -A BUILTIN_SCHED_STEP_CPUS
declare -A BUILTIN_SCHED_STEP_ALLOC_CPUS
declare -A BUILTIN_SCHED_STEP_MEM
declare -A BUILTIN_SCHED_STEP_ALLOC_MEM
declare -A BUILTIN_SCHED_CURR_STEP_STATUS
declare BUILTIN_SCHED_SELECTED_STEPS
declare BUILTIN_SCHED_CPUS=1
declare BUILTIN_SCHED_MEM=256
declare BUILTIN_SCHED_ALLOC_CPUS=0
declare BUILTIN_SCHED_ALLOC_MEM=0

###############################
# BUILTIN SCHEDULER FUNCTIONS #
###############################

########
builtin_sched_cpus_within_limit()
{
    local cpus=$1
    if [ ${BUILTIN_SCHED_CPUS} -eq 0 ]; then
        return 0
    else
        if [ ${BUILTIN_SCHED_CPUS} -ge $cpus ]; then
            return 0
        else
            return 1
        fi
    fi
}

########
builtin_sched_mem_within_limit()
{
    local mem=$1
    if [ ${BUILTIN_SCHED_MEM} -eq 0 ]; then
        return 0
    else
        if [ ${BUILTIN_SCHED_MEM} -ge $mem ]; then
            return 0
        else
            return 1
        fi
    fi
}

########
builtin_sched_init_step_info()
{
    local cmdline=$1
    local dirname=$2
    local pfile=$3

    # Read information about the steps to be executed
    local stepspec
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`
            local script_filename=`get_script_filename ${dirname} ${stepname}`
            local status=`get_step_status ${dirname} ${stepname}`
            local stepdeps=`extract_stepdeps_from_stepspec "$stepspec"`
            local spec_throttle=`extract_attr_from_stepspec "$stepspec" "throttle"`
            local sched_throttle=`get_scheduler_throttle ${spec_throttle}`
            local array_size=`get_job_array_size_for_step "${cmdline}" "${stepspec}"`

            # Get cpus info
            local cpus=`extract_cpus_from_stepspec "$stepspec"`
            str_is_natural_number ${cpus} || { echo "Error: number of cpus ($cpus) for $stepname should be a natural number" >&2; return 1; }

            # Get mem info
            local mem=`extract_mem_from_stepspec "$stepspec"`
            mem=`convert_mem_value_to_mb ${mem}` || { echo "Invalid memory specification for step ${stepname}" >&2; return 1; }
            str_is_natural_number ${mem} || { echo "Error: amount of memory ($mem) for $stepname should be a natural number" >&2; return 1; }

            # Obtain full throttle cpus value
            local full_throttle_cpus=${cpus}
            if [ $array_size -gt 1 ]; then
                full_throttle_cpus=`expr ${cpus} \* ${sched_throttle}`
            fi
            # Check full_throttle_cpus value
            builtin_sched_cpus_within_limit ${full_throttle_cpus} || { echo "Error: number of cpus for step $stepname exceeds limit (cpus: ${cpus}, array size: ${array_size}, throttle: ${sched_throttle})" >&2; return 1; }

            # Obtain full throttle mem value
            local full_throttle_mem=${mem}
            if [ $array_size -gt 1 ]; then
                full_throttle_mem=`expr ${mem} \* ${sched_throttle}`
            fi
            # Check mem value
            builtin_sched_mem_within_limit ${full_throttle_mem} || { echo "Error: amount of memory for step $stepname exceeds limit (mem: ${mem}, array size: ${array_size}, throttle: ${sched_throttle})" >&2; return 1; }

            # Register step information
            BUILTIN_SCHED_STEP_SCRIPT_FILENAME[${stepname}]=${script_filename}
            BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]=${status}   
            BUILTIN_SCHED_STEP_SPEC[${stepname}]="${stepspec}"
            BUILTIN_SCHED_STEP_DEPS[${stepname}]=${stepdeps}
            BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]=${array_size}
            BUILTIN_SCHED_STEP_THROTTLE[${stepname}]=${sched_throttle}
            BUILTIN_SCHED_STEP_CPUS[${stepname}]=${cpus}
            BUILTIN_SCHED_STEP_MEM[${stepname}]=${mem}
        fi
    done < ${pfile}
}

########
builtin_sched_release_mem()
{
    local stepname=$1
    
    BUILTIN_SCHED_ALLOC_MEM=`expr ${BUILTIN_SCHED_ALLOC_MEM} - ${BUILTIN_SCHED_STEP_ALLOC_MEM[${stepname}]}`
    BUILTIN_SCHED_STEP_ALLOC_MEM[${stepname}]=0
}

########
builtin_sched_release_cpus()
{
    local stepname=$1
    
    BUILTIN_SCHED_ALLOC_CPUS=`expr ${BUILTIN_SCHED_ALLOC_CPUS} - ${BUILTIN_SCHED_STEP_ALLOC_CPUS[${stepname}]}`
    BUILTIN_SCHED_STEP_ALLOC_CPUS[${stepname}]=0
}

########
builtin_sched_get_step_mem()
{
    local stepname=$1

    if [ ${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]} -eq 1 ]; then
        echo ${BUILTIN_SCHED_STEP_MEM[${stepname}]}
    else
        echo `expr ${BUILTIN_SCHED_STEP_MEM[${stepname}]} \* ${BUILTIN_SCHED_STEP_THROTTLE[${stepname}]}`
    fi
}

########
builtin_sched_get_step_mem_given_num_tasks()
{
    local stepname=$1
    local ntasks=$2

    if [ ${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]} -eq 1 ]; then
        echo ${BUILTIN_SCHED_STEP_MEM[${stepname}]}
    else
        echo `expr ${BUILTIN_SCHED_STEP_MEM[${stepname}]} \* ${ntasks}`
    fi
}

########
builtin_sched_reserve_mem()
{
    local stepname=$1
    local step_mem=`builtin_sched_get_step_mem ${stepname}`
    BUILTIN_SCHED_ALLOC_MEM=`expr ${BUILTIN_SCHED_ALLOC_MEM} + ${step_mem}`
    BUILTIN_SCHED_STEP_ALLOC_MEM[${stepname}]=${step_mem}
}

########
builtin_sched_get_step_cpus()
{
    local stepname=$1

    if [ ${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]} -eq 1 ]; then
        echo ${BUILTIN_SCHED_STEP_CPUS[${stepname}]}
    else
        echo `expr ${BUILTIN_SCHED_STEP_CPUS[${stepname}]} \* ${BUILTIN_SCHED_STEP_THROTTLE[${stepname}]}`
    fi
}

########
builtin_sched_get_step_cpus_given_num_tasks()
{
    local stepname=$1
    local ntasks=$2

    if [ ${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]} -eq 1 ]; then
        echo ${BUILTIN_SCHED_STEP_CPUS[${stepname}]}
    else
        echo `expr ${BUILTIN_SCHED_STEP_CPUS[${stepname}]} \* ${ntasks}`
    fi
}

########
builtin_sched_reserve_cpus()
{
    local stepname=$1
    local step_cpus=`builtin_sched_get_step_cpus ${stepname}`
    BUILTIN_SCHED_ALLOC_CPUS=`expr ${BUILTIN_SCHED_ALLOC_CPUS} + ${step_cpus}`
    BUILTIN_SCHED_STEP_ALLOC_CPUS[${stepname}]=${step_cpus}
}

########
builtin_sched_get_failed_array_taskids()
{
    local dirname=$1
    local stepname=$2
    local array_size=${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]}
    local result

    for taskid in `seq ${array_size}`; do
        local task_status=`get_array_task_status $dirname $stepname $taskid`
        if [ ${task_status} = ${FAILED_TASK_STATUS} ]; then
            if [ "${result}" = "" ]; then
                result=$taskid
            else
                result="$result $taskid"
            fi
        fi
    done

    echo $result
}

########
builtin_sched_get_finished_array_taskids()
{
    local dirname=$1
    local stepname=$2
    local array_size=${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]}
    local result

    for taskid in `seq ${array_size}`; do
        local task_status=`get_array_task_status $dirname $stepname $taskid`
        if [ ${task_status} = ${FINISHED_TASK_STATUS} ]; then
            if [ "${result}" = "" ]; then
                result=$taskid
            else
                result="$result $taskid"
            fi
        fi
    done

    echo $result
}

########
builtin_sched_get_inprogress_array_taskids()
{
    local dirname=$1
    local stepname=$2
    local array_size=${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]}
    local result

    for taskid in `seq ${array_size}`; do
        local task_status=`get_array_task_status $dirname $stepname $taskid`
        if [ ${task_status} = ${INPROGRESS_STEP_STATUS} ]; then
            if [ "${result}" = "" ]; then
                result=$taskid
            else
                result="$result $taskid"
            fi
        fi
    done

    echo $result
}

########
builtin_sched_get_max_throttle_for_step()
{
    local dirname=$1
    local stepname=$2

    local failed_tasks=`builtin_sched_get_failed_array_taskids $dirname $stepname`
    local num_failed_tasks=`get_num_words_in_string "${failed_tasks}"`

    local finished_tasks=`builtin_sched_get_finished_array_taskids $dirname $stepname`
    local num_finished_tasks=`get_num_words_in_string "${finished_tasks}"`

    local array_size=${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]}
    echo `expr ${array_size} - ${num_failed_tasks} - ${num_finished_tasks}`
}

########
builtin_sched_revise_array_mem()
{
    local dirname=$1
    local stepname=$2

    inprogress_tasks=`builtin_sched_get_inprogress_array_taskids ${dirname} ${stepname}`
    local num_inprogress_tasks=`get_num_words_in_string "${inprogress_tasks}"`    
    step_revised_mem=`builtin_sched_get_step_mem_given_num_tasks ${stepname} ${num_inprogress_tasks}`
    BUILTIN_SCHED_ALLOC_MEM=`expr ${BUILTIN_SCHED_ALLOC_MEM} - ${BUILTIN_SCHED_STEP_ALLOC_MEM[${stepname}]} + ${step_revised_mem}`
    BUILTIN_SCHED_STEP_ALLOC_MEM[${stepname}]=${step_revised_mem}
}

########
builtin_sched_revise_array_cpus()
{
    local dirname=$1
    local stepname=$2

    inprogress_tasks=`builtin_sched_get_inprogress_array_taskids ${dirname} ${stepname}`
    local num_inprogress_tasks=`get_num_words_in_string "${inprogress_tasks}"`    
    step_revised_cpus=`builtin_sched_get_step_cpus_given_num_tasks ${stepname} ${num_inprogress_tasks}`
    BUILTIN_SCHED_ALLOC_CPUS=`expr ${BUILTIN_SCHED_ALLOC_CPUS} - ${BUILTIN_SCHED_STEP_ALLOC_CPUS[${stepname}]} + ${step_revised_cpus}`
    BUILTIN_SCHED_STEP_ALLOC_CPUS[${stepname}]=${step_revised_cpus}
}

########
builtin_sched_init_curr_comp_resources()
{
    # Iterate over defined steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_CURR_STEP_STATUS[@]}"; do
        status=${BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]}
        if [ ${status} = ${INPROGRESS_STEP_STATUS} ]; then
            builtin_sched_reserve_mem $stepname
            builtin_sched_reserve_cpus $stepname
        fi
    done
}

########
builtin_sched_get_updated_step_status()
{
    local dirname=$1

    # Iterate over defined steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_CURR_STEP_STATUS[@]}"; do
        local status=`get_step_status ${dirname} ${stepname}`
        BUILTIN_SCHED_CURR_STEP_STATUS_UPDATED[${stepname}]=${status}
    done
}

########
builtin_sched_update_comp_resources()
{
    local dirname=$1
    
    # Iterate over steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_CURR_STEP_STATUS[@]}"; do
        prev_status=${BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]}
        updated_status=${BUILTIN_SCHED_CURR_STEP_STATUS_UPDATED[${stepname}]}
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

            # Check if resources of job array should be revised
            if [ ${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]} -gt 1 -a ${prev_status} = ${INPROGRESS_STEP_STATUS} -a ${updated_status} = ${INPROGRESS_STEP_STATUS} ]; then
                builtin_sched_revise_array_mem $dirname $stepname
                builtin_sched_revise_array_cpus $dirname $stepname
            fi
        fi
    done
}
    
########
builtin_sched_fix_updated_step_status()
{
    # Copy updated status into current status
    local stepname
    for stepname in "${!BUILTIN_SCHED_CURR_STEP_STATUS[@]}"; do
        prev_status=${BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]}
        updated_status=${BUILTIN_SCHED_CURR_STEP_STATUS_UPDATED[${stepname}]}
        if [ "${updated_status}" != "" ]; then
            if [ ${prev_status} = ${INPROGRESS_STEP_STATUS} -a ${updated_status} != ${INPROGRESS_STEP_STATUS} -a ${updated_status} != ${FINISHED_STEP_STATUS} ]; then
                BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]=${BUILTIN_SCHED_FAILED_STEP_STATUS}
            else
                BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]=${BUILTIN_SCHED_CURR_STEP_STATUS_UPDATED[${stepname}]}
            fi
        fi
    done
}

########
get_available_cpus()
{
    if [ ${BUILTIN_SCHED_CPUS} -eq 0 ]; then
        echo 0
    else
        echo `expr ${BUILTIN_SCHED_CPUS} - ${BUILTIN_SCHED_ALLOC_CPUS}`
    fi
}

########
get_available_mem()
{
    if [ ${BUILTIN_SCHED_MEM} -eq 0 ]; then
        echo 0
    else
        echo `expr ${BUILTIN_SCHED_MEM} - ${BUILTIN_SCHED_ALLOC_MEM}`
    fi
}

########
builtin_sched_check_comp_res()
{
    local stepname=$1

    if [ ${BUILTIN_SCHED_CPUS} -gt 0 ]; then
        local available_cpus=`get_available_cpus`
        step_cpus=`builtin_sched_get_step_cpus ${stepname}`
        if [ ${step_cpus} -gt ${available_cpus} ]; then
            return 1
        fi
    fi

    if [ ${BUILTIN_SCHED_MEM} -gt 0 ]; then
        local available_mem=`get_available_mem`
        step_mem=`builtin_sched_get_step_mem ${stepname}`
        if [ ${step_mem} -gt ${available_mem} ]; then
            return 1
        fi
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
        depstatus=${BUILTIN_SCHED_CURR_STEP_STATUS[${depsname}]}
            
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
get_pending_task_ids()
{
    local stepname=$1
    # TBD
}

########
builtin_sched_get_executable_steps()
{    
    # Iterate over steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_CURR_STEP_STATUS[@]}"; do
        local status=${BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]}
        local array_size=${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]}
        if [ ${array_size} -eq 1 ]; then
            # step is not an array
            if [ ${status} != ${INPROGRESS_STEP_STATUS} -a ${status} != ${FINISHED_STEP_STATUS} -a ${status} != ${BUILTIN_SCHED_FAILED_STEP_STATUS} ]; then
                if builtin_sched_step_can_be_executed ${stepname}; then
                    BUILTIN_SCHED_EXECUTABLE_STEPS[${stepname}]=1
                fi
            fi
        else
            # step is an array
            if [ ${status} != ${FINISHED_STEP_STATUS} -a ${status} != ${BUILTIN_SCHED_FAILED_STEP_STATUS} ]; then
                if builtin_sched_step_can_be_executed ${stepname}; then
                    pending_task_ids=`get_pending_task_ids ${stepname}`
                    BUILTIN_SCHED_EXECUTABLE_STEPS[${stepname}]=${pending_task_ids}
                fi
            fi
        fi
    done
}

########
get_knapsack_cpus_for_step()
{
    local stepname=$1
    
    if [ ${BUILTIN_SCHED_CPUS} -gt 0 ]; then
        echo ${BUILTIN_SCHED_STEP_CPUS[${stepname}]}
    else
        echo 0
    fi
}

########
get_knapsack_mem_for_step()
{
    local stepname=$1
    
    if [ ${BUILTIN_SCHED_MEM} -gt 0 ]; then
        echo ${BUILTIN_SCHED_STEP_MEM[${stepname}]}
    else
        echo 0
    fi
}

########
print_knapsack_spec()
{
    local stepvalue=1
    local stepname
    for stepname in "${!BUILTIN_SCHED_EXECUTABLE_STEPS[@]}"; do
        # Obtain array size
        local array_size=${BUILTIN_SCHED_STEP_ARRAY_SIZE[${stepname}]}

        # Determine cpu requirements
        cpus=`get_knapsack_cpus_for_step ${stepname}`
        
        # Determine memory requirements
        mem=`get_knapsack_mem_for_step ${stepname}`

        if [ ${array_size} -eq 1 ]; then
            echo "$stepname ${stepvalue} ${cpus} ${mem}"
        else
            for id in ${BUILTIN_SCHED_EXECUTABLE_STEPS[${stepname}]}; do
                echo "${stepname}_${id} ${stepvalue} ${cpus} ${mem}"
            done
        fi
    done
}

########
print_knapsack_sol()
{
    local available_cpus=`get_available_cpus`
    local available_mem=`get_available_mem`
    local time_limit=1
    local knapsack_sol=${dirname}/.knapsack_sol.txt
    ${panpipe_bindir}/solve_knapsack_ga -s ${specfile} -c ${available_cpus},${available_mem} -t ${time_limit}
}

########
builtin_sched_select_steps_to_exec()
{
    local dirname=$1

    # Create file with item and weight specification
    specfile=${dirname}/.knapsack_spec.txt
    rm -f ${specfile}
    print_knapsack_spec > ${specfile}
    
    # Solve knapsack problem
    print_knapsack_sol > ${knapsack_sol}

    # Store solution in output variable
    BUILTIN_SCHED_SELECTED_STEPS=`${AWK} -F ": " '{if($1=="Packed items") print $2}' ${knapsack_sol}`
}

########
builtin_sched_count_executable_steps()
{
    echo ${#BUILTIN_SCHED_EXECUTABLE_STEPS[@]}
}

########
builtin_sched_end_condition_reached()
{
    # Iterate over steps
    local stepname
    for stepname in "${!BUILTIN_SCHED_CURR_STEP_STATUS[@]}"; do
        status=${BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]}
        if [ ${status} = ${INPROGRESS_STEP_STATUS} -o ${status} = ${TODO_STEP_STATUS} -o ${status} = ${UNFINISHED_STEP_STATUS} ]; then
            return 1
        fi        
    done
    
    return 0
}

########
builtin_sched_select_steps_to_be_exec()
{
    local dirname=$1

    # Obtain updated status for steps
    local -A BUILTIN_SCHED_CURR_STEP_STATUS_UPDATED
    builtin_sched_get_updated_step_status $dirname

    # Update computational resources depending on changes
    builtin_sched_update_comp_resources $dirname

    # Set updated status as current one
    builtin_sched_fix_updated_step_status

    # Obtain set of steps that can be executed
    local -A BUILTIN_SCHED_EXECUTABLE_STEPS
    builtin_sched_get_executable_steps

    if [ ${builtinsched_debug} -eq 1 ]; then
        local step_status=""
        local stepname
        for stepname in "${!BUILTIN_SCHED_CURR_STEP_STATUS[@]}"; do step_status="${step_status} ${stepname} -> ${BUILTIN_SCHED_CURR_STEP_STATUS[${stepname}]};"; done
        echo "[BUILTIN_SCHED] - BUILTIN_SCHED_CURR_STEP_STATUS: ${step_status}"
        echo "[BUILTIN_SCHED] - COMPUTATIONAL RESOURCES: total cpus= ${BUILTIN_SCHED_CPUS}, allocated cpus= ${BUILTIN_SCHED_ALLOC_CPUS}; total mem= ${BUILTIN_SCHED_MEM}, allocated mem= ${BUILTIN_SCHED_ALLOC_MEM}"
        local exec_steps=""
        for stepname in "${!BUILTIN_SCHED_EXECUTABLE_STEPS[@]}"; do exec_steps="${exec_steps} ${stepname} -> ${BUILTIN_SCHED_EXECUTABLE_STEPS[${stepname}]};"; done
        echo "[BUILTIN_SCHED] - BUILTIN_SCHED_EXECUTABLE_STEPS: ${exec_steps}" 2>&1
    fi
        
    if builtin_sched_end_condition_reached; then
        # End condition reached
        return 1
    else
        # If there are executable steps, select which ones will be executed
        num_exec_steps=${#BUILTIN_SCHED_EXECUTABLE_STEPS[@]}
        if [ ${num_exec_steps} -gt 0 ]; then
            builtin_sched_select_steps_to_exec $dirname

            if [ ${builtinsched_debug} -eq 1 ]; then
                echo "[BUILTIN_SCHED] - BUILTIN_SCHED_SELECTED_STEPS: ${BUILTIN_SCHED_SELECTED_STEPS}" 2>&1
            fi

            return 0
        else
            return 0
        fi
    fi
}

########
builtin_sched_print_task_header()
{
    local fname=$1
    local step_name=$2
    
    echo "PANPIPE_TASK_FILENAME=${fname}"
    echo "PANPIPE_STEP_NAME=${step_name}"
    echo "NUM_CONCURRENT_PIPE_TASKS=0"
}

########
builtin_sched_get_job_array_task_varname()
{
    local arrayname=$1
    local taskid=$2
    
    echo "BUILTIN_SCHED_ARRAY_TASK_${arrayname}_${taskid}"
}

########
builtin_sched_print_task_body()
{
    # Initialize variables
    local num_scripts=$1
    local fname=$2
    local base_fname=`$BASENAME $fname`
    local taskid=$3
    local funct=$4
    local post_funct=$5
    local script_opts=$6

    # Write start of code block
    echo "{"
    
    # Write treatment for task id
    if [ ${num_scripts} -gt 1 ]; then
        local varname=`builtin_sched_get_job_array_task_varname ${base_fname} ${taskid}`
        echo "if [ \"\${${varname}}\" -eq 1 ]; then"
    fi

    # Write function to be executed
    echo "execute_funct_plus_postfunct ${num_scripts} ${fname} ${taskid} ${funct} ${post_funct} \"${script_opts}\" &"
    
    # Close if statement
    if [ ${num_scripts} -gt 1 ]; then
        echo "fi" 
    fi

    # Write end of code block with redirection
    if [ ${num_scripts} -gt 1 ]; then
        echo "} > ${fname}_${taskid}.${BUILTIN_SCHED_LOG_FEXT} 2>&1"
    else
        echo "} > ${fname}.${BUILTIN_SCHED_LOG_FEXT} 2>&1"
    fi
}

########
builtin_sched_print_task_foot()
{
    :
}

########
builtin_sched_create_script()
{
    # Init variables
    local fname=$1
    local funct=$2
    local post_funct=$3
    local opts_array_name=$4[@]
    local opts_array=("${!opts_array_name}")
    
    # Write bash shebang
    local BASH_SHEBANG=`init_bash_shebang_var`
    echo ${BASH_SHEBANG} > ${fname} || return 1
    
    # Write environment variables
    set | exclude_readonly_vars | exclude_bashisms >> ${fname} || return 1

    # Print header
    builtin_sched_print_task_header ${fname} ${funct} >> ${fname} || return 1
    
    # Iterate over options array
    local lineno=1
    local num_scripts=${#opts_array[@]}
    local script_opts
    for script_opts in "${opts_array[@]}"; do

        builtin_sched_print_task_body ${num_scripts} ${fname} ${lineno} ${funct} ${post_funct} "${script_opts}" >> ${fname} || return 1

        lineno=`expr $lineno + 1`

    done

    # Print foot
    builtin_sched_print_task_foot >> ${fname} || return 1
    
    # Give execution permission
    chmod u+x ${fname} || return 1
}

########
builtin_sched_launch()
{
    # Initialize variables
    local file=$1
    local taskid=$2
    local base_fname=`$BASENAME $file`

    # Enable execution of specific task id
    local task_varname=`get_job_array_task_varname ${base_fname} ${taskid}`
    export ${task_varname}=1

    # Execute file
    ${file} &
    local pid=$!
    echo $pid > ${fname}_${taskid}.${STEPID_FEXT}
}

########
builtin_sched_execute_step()
{
    # Initialize variables
    local cmdline=$1
    local dirname=$2
    local stepname=$3
    local taskid=$4
    
    # Execute step

    ## Obtain step status
    local status=`get_step_status ${dirname} ${stepname}`
    echo "STEP: ${stepname} ; STATUS: ${status} ; STEPSPEC: ${stepspec}" >&2

    # Create script
    local script_filename=`get_script_filename ${dirname} ${stepname}`
    local step_function=`get_name_of_step_function ${stepname}`
    local step_function_post=`get_name_of_step_function_post ${stepname}`
    define_opts_for_script "${cmdline}" "${stepspec}" || return 1
    local script_opts_array=("${SCRIPT_OPT_LIST_ARRAY[@]}")
    local array_size=${#script_opts_array[@]}
    builtin_sched_create_script ${script_filename} ${step_function} "${step_function_post}" "script_opts_array"

    # Archive script
    archive_script ${script_filename}

    # Prepare files and directories for step
    local remove=0
    if [ ${array_size} -eq 1 ]; then
        remove=1
    fi
    prepare_outdir_for_step ${dirname} ${stepname} ${remove} || { echo "Error when preparing output directory for step" >&2 ; return 1; }
    prepare_fifos_owned_by_step ${stepname}
        
    # Execute script
    local job_array_list=${taskid}
    builtin_sched_launch ${script_filename} "${taskid}" || { echo "Error while launching step!" >&2 ; return 1; }
        
    # Write id to file
    write_step_id_to_file ${dirname} ${stepname} ${!stepname_id}

    # TBD: avoid multiple creation of scripts for job arrays
}

########
builtin_sched_exec_steps_and_update_status()
{
    local cmdline=$1
    local dirname=$2

    local stepname_info
    for stepname_info in ${BUILTIN_SCHED_SELECTED_STEPS}; do
        # Extract step name and task id
        stepname= #TBD
        taskid= #TBD
        
        # Execute step
        builtin_sched_execute_step "${cmdline}" ${dirname} ${stepname} ${taskid} || return 1
        
        # Update step status
        BUILTIN_SCHED_CURR_STEP_STATUS_UPDATED[${stepname}]=${INPROGRESS_STEP_STATUS}
    done
    
    # Reset variable
    BUILTIN_SCHED_SELECTED_STEPS=""
}
    
########
builtin_sched_exec_steps()
{
    local cmdline=$1
    local dirname=$2

    # Execute selected steps and update status accordingly
    if [ "${BUILTIN_SCHED_SELECTED_STEPS}" != "" ]; then
        local -A BUILTIN_SCHED_CURR_STEP_STATUS_UPDATED
        builtin_sched_exec_steps_and_update_status "${cmdline}" $dirname
    fi
    
    # Update computational resources after execution
    builtin_sched_update_comp_resources $dirname

    # Set updated status as current one
    builtin_sched_fix_updated_step_status
}

########
execute_pipeline_steps_builtin()
{
    # Read input parameters
    local cmdline=$1
    local dirname=$2
    local pfile=$3
    local iterno=1

    echo "* Configuring scheduler..." >&2
    if [ ${builtinsched_cpus_given} -eq 1 ]; then
        BUILTIN_SCHED_CPUS=${builtinsched_cpus}
    fi
    
    if [ ${builtinsched_mem_given} -eq 1 ]; then
        BUILTIN_SCHED_MEM=${builtinsched_mem}
    fi
    echo "- Available CPUS: ${BUILTIN_SCHED_CPUS}" >&2
    echo "- Available memory: ${BUILTIN_SCHED_MEM}" >&2
    echo "" >&2
    
    echo "* Executing pipeline steps..." >&2
    
    # Initialize step status
    builtin_sched_init_step_info "${cmdline}" ${dirname} ${pfile} || return 1

    # Initialize current step status
    builtin_sched_init_curr_comp_resources || return 1
    
    # Execute scheduling loop
    local end=0
    local sleep_time=5
    while [ ${end} -eq 0 ]; do
        if [ ${builtinsched_debug} -eq 1 ]; then
            echo "[BUILTIN_SCHED] * Iteration ${iterno}" 2>&1
        fi

        # Select steps that should be executed
        if builtin_sched_select_steps_to_be_exec ${dirname}; then
            # Execute steps
            builtin_sched_exec_steps "${cmdline}" ${dirname}
            
            sleep ${sleep_time}
        else
            # There are no steps to be executed
            end=1
        fi

        iterno=`expr $iterno + 1`
    done
}