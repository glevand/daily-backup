#!/usr/bin/env bash

usage() {
	local old_xtrace
	old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace
	echo "${script_name} - Daily rsync backup." >&2
	echo "Usage: ${script_name} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -c --check    - Run shellcheck." >&2
	echo "  -h --help     - Show this help and exit." >&2
	echo "  -v --verbose  - Verbose execution." >&2

	echo "  -d --debug    - Debug mode." >&2
	echo "  -l --clean    - Delete oldest existing daily backup." >&2
	echo "  -s --stats    - Report BACKUP_SERVER disk stats." >&2
	echo "  -u --usage    - Report BACKUP_SERVER disk usage (slow)." >&2
	echo "Environment/Config:" >&2
	echo "  BACKUP_SERVER - Required. Default: '${BACKUP_SERVER:-(none)}'" >&2
	echo "  DAILY_MOUNT   - Default: '${DAILY_MOUNT}'" >&2
	echo "  DAILY_PATH    - Default: '${DAILY_PATH}'" >&2
	echo "  FULL_MOUNT    - Default: '${FULL_MOUNT}'" >&2
	echo "  FULL_PATH     - Default: '${FULL_PATH}'" >&2
	echo "  SRC           - List of directories to backup. Default: '${SRC}'" >&2
	echo "Examples:" >&2
	echo "  BACKUP_SERVER=\"my-backup\" ${script_name} -s"
	echo "  nice -n19 ${script_name} -v"
	eval "${old_xtrace}"
}

process_opts() {
	local short_opts="chvdlsu"
	local long_opts="check,help,verbose,debug,clean,stats,usage"

	local opts
	opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${script_name}" -- "$@")

	eval set -- "${opts}"

	while true ; do
		#echo "${FUNCNAME[0]}: @${1}@ @${2}@"
		case "${1}" in
		-c | --check)
			check=1
			shift
			;;
		-h | --help)
			usage=1
			shift
			;;
		-v | --verbose)
			verbose=1
			shift
			;;
		-l | --clean)
			clean=1
			shift
			;;
		-d | --debug)
			set -x
			verbose=1
			debug=1
			shift
			;;
		-s | --stats)
			disk_stats=1
			shift
			;;
		-u | --usage)
			disk_usage=1
			shift
			;;
		--)
			shift
			if [[ ${1} ]]; then
				echo "${script_name}: ERROR: Extra args found: '${*}'." >&2
				usage
				exit 1
			fi
			break
			;;
		*)
			echo "${script_name}: ERROR: Internal opts: '${*}'" >&2
			exit 1
			;;
		esac
	done
}

on_exit() {
	local result=${1}

	umount_vols
	echo "${script_name}: Done: ${result}" >&2
}

run_shellcheck() {
	local file=${1}

	shellcheck=${shellcheck:-"shellcheck"}

	if ! test -x "$(command -v "${shellcheck}")"; then
		echo "${script_name}: ERROR: Please install '${shellcheck}'." >&2
		exit 1
	fi

	${shellcheck} "${file}"
}

find_config () {
	local dirs="${SCRIPTS_TOP} ${HOME} /etc"
	local sufs=".conf .config"
	local d s

	for d in ${dirs}; do
		for s in ${sufs}; do
			local t="${d}/${script_name%.*}${s}"
			if [[ -f "${t}" ]]; then
				echo "${t}"
				return
			fi
		done
	done
}

disk_usage () {
	for mnt in ${FULL_MOUNT} ${DAILY_MOUNT}; do
		local cmd="${SSH} du -sh ${mnt}/*"
		eval "${cmd}" | grep -E --invert-match 'lost\+found' | grep -E '^d'
	done
}

get_files () {
	local mnt=${1}
	local cmd="${SSH} ls -ltr ${mnt}"

	eval "${cmd}" | grep -E --invert-match 'lost\+found'  | grep -E '^d'
}

print_files () {
	echo ""
	echo "Daily backups:"
	get_files "${DAILY_MOUNT}" | awk '{print $NF}'

	echo ""
	echo "Full backups:"
	get_files "${FULL_MOUNT}" | awk '{print $NF}'
}

get_disk_stats () {
	local mnt=${1}
	local cmd="${SSH} df -h"
	eval "${cmd}" | grep -E "${mnt}"
}

print_disk_stats () {
	echo "Filesystem      Size  Used Avail Use% Mounted on"
	get_disk_stats "${FULL_MOUNT}"
	get_disk_stats "${DAILY_MOUNT}"
}

print_disk_info () {
	print_files
	echo ""
	print_disk_stats
}

clean_daily () {
	#local files
	#files=$(get_files "${DAILY_MOUNT}" | awk '{print $NF}')

	local oldest
	oldest="$(get_files "${DAILY_MOUNT}" | awk '{print $NF}' | head -1 | sed 's/\r//')"

	if [[ -z "${oldest}" ]]; then
		echo "INFO: No files found: '${BACKUP_SERVER}:${DAILY_MOUNT}'." >&2
		return 0
	fi

	echo "TODO: Would clean: '${BACKUP_SERVER}:${DAILY_MOUNT}/${oldest}'."

	if [[ ${verbose} ]]; then
		local extra="--verbose"
	fi

	#local cmd="${SSH} rm -rf ${extra} ${DAILY_MOUNT}/${oldest}"
	local cmd="${SSH} ls -ld ${DAILY_MOUNT}/${oldest}"

	eval "${cmd}"
}

mount_op () {
	local op="${1}"
	local mnt
	local cmd

	if [[ ${verbose} ]]; then
		local extra="--verbose"
	fi

	for mnt in "${FULL_MOUNT}" "${DAILY_MOUNT}"; do
		cmd="${SSH} ${op} ${extra} ${mnt}"

		eval "${cmd}"

		if [[ "${op}" == "mount" ]]; then
			need_umount=1
		fi
	done
}

mount_vols () {
	mount_op "mount"
}

umount_vols () {
	if [[ ${need_umount} ]]; then
		mount_op "umount"
	fi
}

#===============================================================================
# program start
#===============================================================================
export PS4='\[\e[0;33m\]+ ${BASH_SOURCE##*/}:${LINENO}:(${FUNCNAME[0]:-"?"}):\[\e[0m\] '

script_name="${0##*/}"
SCRIPTS_TOP=${SCRIPTS_TOP:-"$( cd "${BASH_SOURCE%/*}" && pwd )"}

trap "on_exit 'failed.'" EXIT
set -e

today=$(date +%Y-%m-%d-%A-%H:%M)
SECONDS=0

process_opts "${@}"

config_file="${config_file:-$(find_config)}"

if [[ -f "${config_file}" ]]; then
	# shellcheck source=/dev/null
	source "${config_file}"
else
	echo "${config_file}: WARNING: No config file found." >&2
fi

SRC=${SRC:-"/etc /home"}
FULL_MOUNT=${FULL_MOUNT:-"/home/${HOSTNAME}-full-backup"}
DAILY_MOUNT=${DAILY_MOUNT:-"/home/${HOSTNAME}-daily-backup"}
FULL_PATH=${FULL_PATH:-"/full"}
DAILY_PATH=${DAILY_PATH:-"/${today}"}

if [[ ${usage} ]]; then
	usage
	trap - EXIT
	exit 0
fi

if [[ ${check} ]]; then
	run_shellcheck "${0}"
	trap - EXIT
	exit 0
fi

if [[ ${verbose} ]]; then
	SSH="ssh -t ${BACKUP_SERVER}"
else
	SSH="ssh -q -t ${BACKUP_SERVER}"
fi

mount_vols

if [[ ${disk_usage} ]]; then
	print_disk_info
	echo ""
	echo "Getting disk usage..."
	disk_usage
	trap "on_exit 'success.'" EXIT
	exit 0
fi

if [[ ${disk_stats} ]]; then
	print_disk_info
	trap "on_exit 'success.'" EXIT
	exit 0
fi

if [[ ${clean} ]]; then
	clean_daily
	echo ""
	print_disk_info
	trap "on_exit 'success.'" EXIT
	exit 0
fi

echo "-- ${today} backup --"

if [[ ${debug} ]]; then
	rsync_extra="--verbose"
fi

for s in ${SRC}; do
	suf=${s////-}
	cmd="sudo rsync -a --delete --inplace --backup \
		${rsync_extra} \
		--backup-dir=${DAILY_MOUNT}${DAILY_PATH}-${suf}/ \
		${s}/ ${BACKUP_SERVER}:${FULL_MOUNT}${FULL_PATH}-${suf}/"

	if ! eval "${cmd}"; then
		echo "${script_name}: ERROR: failed (${?}): '${cmd}'." >&2
		exit 1
	fi
done

print_disk_stats

trap "on_exit 'success.'" EXIT
exit 0
