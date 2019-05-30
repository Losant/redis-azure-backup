#!/bin/bash

VERSION='1.0'
SCRIPT_NAME="redis-cloud-backup.sh"
#exit on any error
set -e
# Prints the usage for this script
function print_usage() {
  echo "Redis Backup to Google Cloud Storage Version: ${VERSION}"
  cat <<'EOF'
Usage: ./redis-cloud-backup.sh [ options ] <command>
Description:
  Utility for creating Redis Backups with Google Cloud Storage.
  Run with admin level privileges.

Flags:
  -a, --alt-hostname
    Specify an alternate server name to be used in the service account container path construction. Used
    to create or retrieve backups from different servers

  -b, --gcsbucket
   Azure Storage Account container used in deployment and by the cluster.

  -d, --rdbdir
    The directory in which the redis RDB file is stored

  -h, --help
    Print this help message.

  -l, --log-dir
    Activate logging to file 'RedisBackup${DATE}.log' from stdout
    Include an optional directory path to write the file
    Default path is /var/log/redis

  -n, --noop
    Will attempt a dry run and verify all the settings are correct

  -v, --verbose
    When provided will print additional information to log file

Commands:
  backup, inventory, commands, options

backup                Backup Redis based on passed in options

inventory             List available backups

commands              List available commands

options               list available options
EOF
}

# List all commands for command completion.
function commands() {
  print_usage | sed -n -e '/^Commands:/,/^$/p' | tail -n +2 | head -n -1 | tr -d ','
}

# List all options for command completion.
function options() {
  print_usage | grep -E '^ *-' | tr -d ','
}

# Override the date function
function prepare_date() {
  date "$@"
}

# Prefix a date prior to echo output
function loginfo() {
  if  ${LOG_OUTPUT}; then
     echo "$(prepare_date +%F_%H:%M:%S): ${@}" >> "${LOG_FILE}"
  else
     echo "$(prepare_date +%F_%H:%M:%S): ${@}"
  fi
}

# Only used if -v --verbose is passed in
function logverbose() {
  if ${VERBOSE}; then
    loginfo "VERBOSE: ${@}"
  fi
}

# Pass errors to stderr.
function logerror() {
  loginfo "ERROR: ${@}" >&2
  let ERROR_COUNT++
}

# Bad option was found.
function print_help() {
  logerror "Unknown Option Encountered. For help run '${SCRIPT_NAME} --help'"
  print_usage
  exit 1
}

# Validate that all configuration options are correct and no conflicting options are set
function validate() {
  touch_logfile
  single_script_check
  verbose_vars
  loginfo "***************VALIDATING INPUT******************"
  if [ -z ${AZCLI} ]; then
    logerror "Cannot find az utility please make sure it is in the PATH"
    exit 1
  fi
  if [ -z ${AZ_BUCKET} ]; then
      logerror "Please pass in the Azure Container name to use with this script"
      exit 1
  else
      if ! ${AZCLI} storage blog list --container-name ${AZ_BUCKET} &> /dev/null; then
      # if ! ${AZCLI} ls ${AZ_BUCKET} &> /dev/null; then   # Change this
        logerror "Cannot access Azure Storage Account container ${AZ_BUCKET} make sure" \
        " it exists"
        exit 1
      fi
  fi

  logverbose "ERROR_COUNT: ${ERROR_COUNT}"

  if [ ${ERROR_COUNT} -gt 0 ]; then
    loginfo "*************ERRORS WHILE VALIDATING INPUT*************"
    exit 1
  fi
  loginfo "*************SUCCESSFULLY VALIDATED INPUT**************"
}

# Print out all the important variables if -v is set
function verbose_vars() {
  logverbose "************* PRINTING VARIABLES ****************\n"
  logverbose "ACTION: ${ACTION}"
  logverbose "RDB_DIR: ${RDB_DIR}"
  logverbose "DATE: ${DATE}"
  logverbose "DRY_RUN: ${DRY_RUN}"
  logverbose "GCS_BUCKET: ${GCS_BUCKET}"
  logverbose "AZCLI: ${AZCLI}"
  logverbose "HOSTNAME: ${HOSTNAME}"
  logverbose "LOG_DIR: ${LOG_DIR}"
  logverbose "LOG_FILE: ${LOG_FILE}"
  logverbose "LOG_OUTPUT: ${LOG_OUTPUT}"
  logverbose "SUFFIX: ${SUFFIX}"
  logverbose "************* DONE PRINTING VARIABLES ************\n"
}

# Check that script is not running more than once
function single_script_check() {
  local grep_script
  #wraps a [] around the first letter to trick the grep statement into ignoring itself
  grep_script="$(echo ${SCRIPT_NAME} | sed 's/^/\[/' | sed 's/^\(.\{2\}\)/\1\]/')"
  logverbose "checking that script isn't already running"
  logverbose "grep_script: ${grep_script}"
  status="$(ps -feww | grep -w \"${grep_script}\" \
    | awk -v pid=$$ -- '$2 != pid { print $2 }')"
  if [ ! -z "${status}" ]; then
    logerror " ${SCRIPT_NAME} : Process is already running. Aborting"
    exit 1;
  fi
}

# Create the log file if requested
function touch_logfile() {
  if [ "${LOG_OUTPUT}" = true ] && [ ! -f "${LOG_FILE}" ]; then
    touch "${LOG_FILE}"
  fi
}

# List available backups in GCS
function inventory() {
  loginfo "Available Backups:"
  # gsutil ls -d "${GCS_BUCKET}/backups/${HOSTNAME}/${SUFFIX}/*"
  az storage blob list --container-name "${AZ_BUCKET}" | jq -r .[].name
}

# This is the main backup function that orchestrates all the options
# to create the backup set and then push it to GCS
function backup() {
  create_gcs_backup_path
  copy_to_azure
}

# Set the backup path bucket URL
function create_gcs_backup_path() {
  AZ_BACKUP_PATH="backups/${HOSTNAME}/${SUFFIX}/${DATE}/"
  loginfo "Will use target backup directory: ${AZ_BACKUP_PATH}"
}

# Copy the backup files up to the GCS bucket
function copy_to_azure() {
  loginfo "Copying files to ${AZ_BACKUP_PATH}"
  if ${DRY_RUN}; then
    loginfo "az storage blob upload --container-name ${AZ_BUCKET} --file ${RDB_DIR}/dump.rdb --name ${AZ_BACKUP_PATH}dump.rdb"
  else
    # Add these options
    # [--account-key]
    # [--account-name]
    az storage blob upload --container-name ${AZ_BUCKET} --file "${RDB_DIR}/dump.rdb" --name ${AZ_BACKUP_PATH}dump.rdb
  fi
}

# Transform long options to short ones
for arg in "$@"; do
  shift
  case "$arg" in

    "backup")   set -- "$@" "-B" ;;
    "commands")
                    commands
                    exit 0
                    ;;
    "options")
                    options
                    exit 0
                    ;;
    "inventory") set -- "$@" "-I" ;;
    "--alt-hostname")   set -- "$@" "-a" ;;
    "--gcsbucket") set -- "$@" "-b" ;;
    "--rdbdir")   set -- "$@" "-d" ;;
    "--help") set -- "$@" "-h" ;;
    "--log-dir")   set -- "$@" "-l" ;;
    "--noop")   set -- "$@" "-n" ;;
    "--verbose")   set -- "$@" "-v" ;;
    *)        set -- "$@" "$arg"
  esac
done

while getopts 'a:b:BcCd:DfhH:iIjkl:LnN:p:rs:S:T:u:U:vwy:z' OPTION
do
  case $OPTION in
      a)
          HOSTNAME=${OPTARG}
          ;;
      b)
          GCS_BUCKET=${OPTARG%/}
          ;;
      B)
          ACTION="backup"
          ;;
      d)
          RDB_DIR=${OPTARG}
          ;;
      h)
          print_usage
          exit 0
          ;;
      I)
          ACTION="inventory"
          ;;
      l)
          LOG_OUTPUT=true
          [ -d ${OPTARG} ] && LOG_DIR=${OPTARG%/}
          ;;
      n)
          DRY_RUN=true
          ;;
      v)
          VERBOSE=true
          ;;
      ?)
          print_help
          ;;
  esac
done

ACTION=${ACTION:-backup}
RDB_DIR=${RDB_DIR:-/var/lib/redis/6379} # RDB base directory
DATE="$(prepare_date +%F_%H-%M )" #nicely formatted date string for files
DRY_RUN=${DRY_RUN:-false} #flag to only print what would have executed
ERROR_COUNT=0 #used in validation step will exit if > 0
AZCLI="$(which az)" #which az script
HOSTNAME=${HOSTNAME:-"$(hostname)"} #used for gcs backup location
LOG_DIR=${LOG_DIR:-/var/log/redis} #where to write the log files
LOG_FILE="${LOG_DIR}/RedisBackup${DATE}.log" #script log file
LOG_OUTPUT=${LOG_OUTPUT:-false} #flag to output to log file instead of stdout
SUFFIX="rdb"
VERBOSE=${VERBOSE:-false} #prints detailed information

# Validate input
validate
# Execute the requested action
eval $ACTION
