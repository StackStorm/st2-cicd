#!/bin/bash

set -eu

FROM_VERSION=''
TO_VERSION=''
MIGRATION_MIN_VERSION_SUPPORTED='1.5'
MIGRATION_FUNC_BASE_NAME="migrate_to_"

# http://stackoverflow.com/questions/59895/can-a-bash-script-tell-what-directory-its-stored-in
MIGRATION_SCRIPT_BASE_PATH="/opt/stackstorm/st2/bin/"

# Version check util methods

verlte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

verlt() {
    [ "$1" = "$2" ] && return 1 || verlte $1 $2
}

vergte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | tail -n1`" ]
}

vergt() {
    [ "$1" = "$2" ] && return 1 || vergte $1 $2
}

# Other util functions

get_major_minor_version() {
  echo $1 | awk -F \. {'print $1"."$2'}
}

get_major_version() {
  echo $1 | awk -F \. {'print $1'}
}

get_minor_version() {
  echo $1 | awk -F \. {'print $2'}
}

get_patch_version() {
  echo $1 | awk -F \. {'print $3'}
}

# Banner functions

fail() {
  echo "############### ERROR ###############"
  echo "# Failed on step - $STEP #"
  echo "#####################################"
}

ok_message() {
  echo "############################## SUCCESS  ###########################################"
  echo "Successfully migrated models for upgrade from version $FROM_VERSION to $TO_VERSION."
  echo "###################################################################################"
  exit 0
}

# Actual work functions

setup_args() {
  for i in "$@"
    do
      case $i in
          --from=*)
          FROM_VERSION="${i#*=}"
          shift
          ;;
          --to=*)
          TO_VERSION="${i#*=}"
          shift
          ;;
          *)
          # unknown option
          ;;
      esac
    done
}

validate_versions() {
  if [[ -z "$FROM_VERSION" ]]; then
    echo "Upgrading *from* unknown version."
    exit 1
  fi

  if [[ -z "$TO_VERSION" ]]; then
    echo "Upgrading *to* unknown version."
    exit 1
  fi

  if [ "$FROM_VERSION" = "$TO_VERSION" ]; then
    echo "Upgrading from version $FROM_VERSION to same version $TO_VERSION. Skipping migration."
    exit 0
  fi

  if verlt $TO_VERSION $FROM_VERSION; then
    echo "You are downgrading from version $FROM_VERSION to version $TO_VERSION. Unsupported!!!"
    exit 2
  fi

  if verlt $TO_VERSION $MIGRATION_MIN_VERSION_SUPPORTED; then
    echo "Model migrations are supported only from upgrading to $MIGRATION_MIN_VERSION_SUPPORTED onwards."
    exit 2
  fi
}

perform_migration() {
  local STEP='0.1'

  local FROM_MINOR_VER=$(get_minor_version $FROM_VERSION)
  local FROM_MAJOR_VER=$(get_major_version $FROM_VERSION)
  let "BUMP_MINOR_VER=$FROM_MINOR_VER + 1"

  local START_VER=$FROM_MAJOR_VER.$BUMP_MINOR_VER
  local END_VER=$(get_major_minor_version $TO_VERSION)

  for migration_ver in `seq $START_VER $STEP $END_VER`
    do
      version_migration_func=${MIGRATION_FUNC_BASE_NAME}${migration_ver}
      # Only some versions have migration steps
      if [ -n "$(type -t $version_migration_func)" ] && [ "$(type -t $version_migration_func)" = function ]; then
        echo "--> Performing migration steps for version $migration_ver"
        STEP="Version $migration_ver migration" && $version_migration_func
      else
        echo "--> No migrations to run for version $migration_ver"
      fi
    done
}

run_migration_scripts() {
  scripts=$1
  for script in "${scripts[@]}"
  do
    script_full_path=$MIGRATION_SCRIPT_BASE_PATH/${script}
    $script_full_path

    if [[ $? != 0 ]]; then
      echo "ERROR: Failed running migration script $script_full_path."
      exit 1
    fi
  done
}

update_mistral_db() {
  sudo service mistral-api stop
  sudo service mistral stop
  /opt/stackstorm/mistral/bin/mistral-db-manage --config-file /etc/mistral/mistral.conf upgrade head
  /opt/stackstorm/mistral/bin/mistral-db-manage --config-file /etc/mistral/mistral.conf populate
}

## Version specific migration functions. Note that the function names must have to
## migrate_to_${major}.${minor}. Otherwise, those methods won't be run.

migrate_to_1.5() {
  local scripts=("st2-migrate-datastore-to-include-scope-secret.py")
  run_migration_scripts $scripts
}

trap 'fail' EXIT
STEP="Setup args" && setup_args $@
STEP="Validate versions" && validate_versions
STEP="Perform migration" && perform_migration
STEP="Perform updates" && update_mistral_db
trap - EXIT

ok_message
