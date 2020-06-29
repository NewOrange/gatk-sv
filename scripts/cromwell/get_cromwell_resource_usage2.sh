#!/bin/bash

function show_help() {
    cat <<-END
USAGE: get_cromwell_memory_usage2.sh WORKFLOW_ID
             or
       get_cromwell_memory_usage2.sh GCS_PATH_TO_WORKFLOW_FOLDER
             or
       get_cromwell_memory_usage2.sh LOCAL_PATH_TO_WORKFLOW_FOLDER
Displays #tasks x #fields table of resource usage info with two
header lines, and additional column of task descriptions.
-This script works by finding all the logs, sorting them into sensible
 order, and chopping up their paths to make a description column. If
 any jobs have not completed they will simply be omitted. The script
 makes no attempt to figure out what tasks *should* have run. However,
 the description field should make any such omissions discoverable.
-If you run on a local path, the log file names must still be
 "monitoring.log", and the local folder structure must be the same as
 in the original cloud bucket (other non-log files are not required
 though)
-If you pass a workflow id, cromshell will be used to find the
 appropriate workflow folder in google cloud storage.
-If cromshell is not located on your PATH, then define the ENV
 variable CROMSHELL with the appropriate path.
-Since there is significant start-up time to running gsutil functions,
 running the inner loop of this script in parallel results in
 signficant speed-up. Installing gnu parallel (available on osx and
 linux) triggers this automatically.
END
}

if [[ $# == 0 ]]; then
    show_help
    exit 0
fi
for ((i=1; i<=$#; ++i)); do
    if [[ ${!i} =~ -+(h|help) ]]; then
        show_help
        exit 0
    fi
done

set -Eeu -o pipefail

CROMSHELL=${CROMSHELL:-"cromshell"}

WORKFLOW_INFO="$1"
REMOTE=true
if [[ $WORKFLOW_INFO == "gs://"* ]]; then
    WORKFLOW_DIR="$WORKFLOW_INFO"
elif [[ -d "$WORKFLOW_INFO" ]]; then
    # workflow info is a local file
    WORKFLOW_DIR="$WORKFLOW_INFO"
    REMOTE=false
else
    WORKFLOW_ID="$WORKFLOW_INFO"
    # get the metadata for this workflow id
    if ! METADATA=$(2>/dev/null $CROMSHELL -t 60 slim-metadata $WORKFLOW_ID); then
        1>&2 echo "Unable to obtain workflow $WORKFLOW_ID metadata from cromshell, try supplying GCS_PATH_TO_WORKFLOW_FOLDER"
        exit 1
    fi
    # get the appropriate path in google cloud for the workflow dir
    # from the metadata
    # a) find lines in the metadata that include a 
    WORKFLOW_DIR=$( \
        echo "$METADATA" \
        | grep -Eo "gs://[^[:space:]]*$WORKFLOW_ID" \
        | tail -n1 \
    )
fi
1>&2 echo "WORKFLOW_DIR=$WORKFLOW_DIR"

function get_monitor_logs() {
    TOP_DIR=$1
    REMOTE=$2
    if $REMOTE; then
      gsutil -m ls "$TOP_DIR/**monitoring.log" 2>/dev/null || echo ""
    else
      find "$TOP_DIR" -name "monitoring.log" 2>/dev/null || echo ""
    fi
}


# ingest LOG_FILE, TOP_DIR, NUM_SHARDS
# print out sorting key of form ATTEMPT_KEY -tab- MAIN_KEY
#    where ATTEMPT_KEY
#       -lists the attempt number of the executing tasks OR
#       -if there is no attempt in the path, calls it attempt 0
#       -digits are padded the same as shards
#    where MAIN_KEY
#       -preserves info about calls and shard numbers, each separated
#        by '/'
#       -shard numbers having enough 0-padded digts to all be of
#        the same length
function get_task_sort_key() {
    LOG_FILE=$1
    TOP_DIR=$2
    N_START=$((1 + $(echo "$TOP_DIR" | tr / '\n' | wc -l)))
    NUM_SHARDS=$(($3))
    MAX_SHARD_DIGITS=${#NUM_SHARDS}
    SHARD_FORMAT="%0${MAX_SHARD_DIGITS}d"
    # keep info about task calls, shards, and attempts below top-dir
    # if there is no preemption folder in the path, call it attempt 0
    echo "$LOG_FILE" \
        | tr / '\n' \
        | tail -n+$N_START \
        | awk -v FS='-' \
              -v SHARD_FORMAT="$SHARD_FORMAT" ' {
            if($1 == "shard") {
                SHARD_KEY=sprintf("%s/" SHARD_FORMAT, SHARD_KEY, $2)
            } else if($1 == "call") {
                CALL_KEY=sprintf("%s/%s", CALL_KEY, $2)
            } else if($1 == "attempt") {
                ATTEMPT_NUMBER=$2
            }
          } END {
            printf SHARD_FORMAT "\t%s/%s", ATTEMPT_NUMBER, CALL_KEY, SHARD_KEY
          }'
}


function sort_monitor_logs() {
    TOP_DIR="$1"
    LOGS_LIST=$(cat)
    NUM_LOGS=$(($(echo "$LOGS_LIST" | wc -l)))
    # The older bash on OSX does not have associative arrays, so to
    # sort file names according to a key, we join the key and the file
    # name into one string with tab delimiters (okay because these are
    # cloud paths produced by cromwell and have no tabs). Then sort by
    # the key, and ultimately cut away the key. There is one extra
    # complication that there may be multiple "attempts" at each task,
    # and we only want to keep the final (presumably successful)
    # attempt.
    #
    # 1. for each log file
    #  a) get a sort key of form: ATTEMPT_KEY tab MAIN_KEY
    #  b) print line of form: LOG_FILE tab MAIN_KEY tab ATTEMPT_KEY
    # 2. sort lines by increasing MAIN_KEY, and secondarily by
    #      decreasing (numeric) ATTEMPT_KEY
    # 3. keep first unique instance of MAIN_KEY (i.e. the last attempt)
    # 4. print out the log file (the first field) in sorted order
    echo "$LOGS_LIST" \
        | while read -r LOG_FILE; do
            SORT_KEY=$(get_task_sort_key "$LOG_FILE" "$TOP_DIR" "$NUM_LOGS")
            printf "%s\t%s\n" "$LOG_FILE" "$SORT_KEY"
          done \
        | sort -t $'\t' -k3,3 -k2,2rn \
        | uniq -f2 \
        | cut -d$'\t' -f1
}


# Scan LOG_FILE, extract header, and print maximum of each column.
# If a column is missing data, print "nan"
function get_task_peak_resource_usage() {
    LOG_FILE=$1
    if $REMOTE; then
        gsutil cat "$LOG_FILE"
    else
        cat "$LOG_FILE"
    fi \
        | awk '
            BEGIN {
                NEED_HEADER=2
            }
            NEED_HEADER == 0 {
                PEAK_VALUE[1] = $1
                for(i=2; i<=NF; ++i) {
                    if($i > PEAK_VALUE[i]) {
                        PEAK_VALUE[i] = $i
                    }
                }
            }
            NEED_HEADER>0 {
                if(NEED_HEADER==2) {
                    if($1 == "ElapsedTime") {
                        PEAK_VALUE[1] = 0.0
                        for(i=2; i<=NF; ++i) {
                            PEAK_VALUE[i] = -1.0
                        }
                        print $0
                        --NEED_HEADER
                    }
                } else {
                    print $0
                    --NEED_HEADER
                }
            }
            END {
                for(i=1; i<=length(PEAK_VALUE); ++i) {
                    v = PEAK_VALUE[i]
                    if(v < 0.0) {
                        v = "nan"
                    }
                    if(i == 1) {
                      printf "%s", v
                    } else {
                      printf "\t%s", v
                    }
                }
                printf "\n"
            }
        '
}
export -f get_task_peak_resource_usage


# Condense directory structure of full path to LOG_FILE into a succinct
# description of the task. Ignore components above TOP_DIR, as they are
# common to all the log files that are being requested.
function get_task_description() {
    LOG_FILE=$1
    if [ $# -ge 2 ]; then
        TOP_DIR=$2
        N_START=$((1 + $(echo "$TOP_DIR" | tr / '\n' | wc -l)))
    else
        N_START=1
    fi
    # keep info about task calls and shards below top-dir
    echo "$LOG_FILE" \
        | tr / '\n' \
        | tail -n+$N_START \
        | grep -E "^(call-|shard-|attempt-)" \
        | tr '\n' / \
        | sed -e 's/call-//g' -e 's,/$,,'
}
export -f get_task_description

function get_task_columns() {
    LOG_NUMBER=$1
    LOG_FILE="$2"
    TOP_DIR="$3"
    DESCRIPTION=$(get_task_description "$LOG_FILE" "$TOP_DIR")
    RESOURCE_USAGE=$(get_task_peak_resource_usage "$LOG_FILE")
    if [[ $LOG_NUMBER == 1 ]]; then
        # due to OSX having an ancient version of bash, this produces syntax errors:
        # paste <(echo "$RESOURCE_USAGE" | head -n2) <(echo "task")
        printf "%s\ttask\n" "$(echo "$RESOURCE_USAGE" | head -n1)"
        echo "$RESOURCE_USAGE" | tail -n2 | head -n1
    fi
    printf "%s\t%s\n" "$(echo "$RESOURCE_USAGE" | tail -n1)" "$DESCRIPTION"
}
export -f get_task_columns


function get_workflow_peak_resource_usage() {
    export TOP_DIR=$1
    export REMOTE=$2
    LOGS=$(get_monitor_logs "$TOP_DIR" $REMOTE | sort_monitor_logs "$TOP_DIR")
    if [ -z "$LOGS" ]; then
        1>&2 echo "No logs found in $TOP_DIR"
        exit 0
    fi
    if command -v parallel > /dev/null; then
        # parallel command is installed, use it, much faster!
        if [ -t 1 ]; then
            # stdout is a terminal, not being redirected, don't use bar
            BAR=""
        else
            # being redirected, show progress via bar to stderr
            BAR="--bar"
        fi
        echo "$LOGS" | nl -s $'\t' | parallel ${BAR} --env TOP_DIR -k --colsep $'\t' "get_task_columns {1} {2} $TOP_DIR"
    else
        1>&2 echo "Consider installing 'parallel', it will give significant speed-up"
        echo "$LOGS" | nl -s $'\t' | while read -r LOG_NUMBER WORKFLOW_LOG; do
            get_task_columns $LOG_NUMBER "$WORKFLOW_LOG" "$TOP_DIR"
        done
    fi
}

get_workflow_peak_resource_usage "$WORKFLOW_DIR" $REMOTE