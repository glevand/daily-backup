#!/bin/bash

today=$(date +%Y-%m-%d-%A-%H:%M-%p)

dir="$(cd "$( dirname "${BASH_SOURCE[0]}" )/" && pwd)"
basename="$(basename $0)"

find_config () {
	local name="${basename%.*}"
	local ds="${dir} ${HOME} /etc"
	local ss=".conf .config"
	local d s

	for d in ${ds}; do
		for s in ${ss}; do
			local t="${d}/${name}${s}"
			if [[ -f "${t}" ]]; then
				echo "${t}"
				return
			fi
		done
	done
}

config=$(find_config)

if [[ -f "${config}" ]]; then
	source "${config}"
else
	echo "${basename}: WARNING: No config file found." >&2
fi

: ${SRC:="/etc /home"}
: ${FULL_MOUNT:="/home/${HOSTNAME}-full-backup"}
: ${DAILY_MOUNT:="/home/${HOSTNAME}-daily-backup"}
: ${FULL_PATH:="/full"}
: ${DAILY_PATH:="/${today}"}

usage () {
	echo "${basename} - Daily rsync backup." >&2
	echo "Usage: ${basename} [flags]" >&2
	echo "Option flags:" >&2
	echo "  -c --clean    - Delete oldest existing daily backup." >&2
	echo "  -d --dry-run  - Do not run commands." >&2
	echo "  -g --debug    - Debug mode." >&2
	echo "  -h --help     - Show this help and exit." >&2
	echo "  -s --stats    - Report BACKUP_SERVER disk stats." >&2
	echo "  -u --usage    - Report BACKUP_SERVER disk usage (slow)." >&2
	echo "  -v --verbose  - Verbose execution." >&2
	echo "Environment/Config:" >&2
	echo "  BACKUP_SERVER - Required. Default: '${BACKUP_SERVER:-(none)}'" >&2
	echo "  DAILY_MOUNT   - Default: '${DAILY_MOUNT}'" >&2
	echo "  DAILY_PATH    - Default: '${DAILY_PATH}'" >&2
	echo "  FULL_MOUNT    - Default: '${FULL_MOUNT}'" >&2
	echo "  FULL_PATH     - Default: '${FULL_PATH}'" >&2
	echo "  SRC           - List of directories to backup. Default: '${SRC}'" >&2
	echo "Examples:" >&2
	echo "  BACKUP_SERVER=\"my-backup\" ${basename} -s"
	echo "  nice -n19 ${basename} -v"
}

short_opts="cdghsuv"
long_opts="clean,dry-run,debug,help,stats,usage,verbose"

opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${basename}" -- "$@")

if [ $? != 0 ]; then
	echo "${basename}: Terminating..." >&2 
	exit 1
fi

eval set -- "${opts}"

while true ; do
	case "${1}" in
	-c | --clean)
		clean=1
		shift
		;;
	-d | --dry-run)
		dry_run=1
		shift
		;;
	-g | --debug)
		set -x
		verbose=1
		debug=1
		exit 0
		;;
	-h | --help)
		usage=1
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
	-v | --verbose)
		verbose=1
		shift
		;;
	--)
		shift
		run_args=${*}
		break
		;;
	*)
		run_args="${run_args} ${1}"
		shift
		;;
	esac
done

if [[ -n "${run_args}" ]]; then
	echo "${basename}: ERROR: Extra args found: ${run_args}." >&2
	usage
	exit 1
fi

if [[ -n ${usage} ]]; then
	usage
	exit 0
fi

if [[ -n ${verbose} ]]; then
	SSH="ssh -t ${BACKUP_SERVER}"
else
	SSH="ssh -q -t ${BACKUP_SERVER}"
fi
result=1

run_cmd () {
	local cmd=${@}

	if [[ -n ${verbose} || -n "${dry_run}" ]]; then
		echo "==> ${cmd}"
	fi
	if [[ -n "${dry_run}" ]]; then
		true
	else
		${cmd}
	fi
}

disk_usage () {
	for mnt in ${FULL_MOUNT} ${DAILY_MOUNT}; do
		local cmd="${SSH} du -sh ${mnt}/* | egrep --invert-match 'lost\+found$'"
		run_cmd ${cmd}
	done
}

get_files () {
	local mnt=${1}
	local cmd="${SSH} ls -ltr ${mnt} | egrep --invert-match 'lost\+found$' | egrep '^d'"

	run_cmd ${cmd}
}

print_files () {
	echo ""
	echo "Daily backups:"
	local files="$(get_files ${DAILY_MOUNT})"
	echo "${files}" | awk '{print $NF}'

	echo ""
	echo "Full backups:"
	files="$(get_files ${FULL_MOUNT})"
	echo "${files}" | awk '{print $NF}'
}

get_disk_stats () {
	local mnt=${1}
	local cmd="${SSH} df -h | egrep '${mnt}'"

	run_cmd ${cmd}
}

print_disk_stats () {
	echo "Filesystem      Size  Used Avail Use% Mounted on"
	get_disk_stats ${FULL_MOUNT}
	get_disk_stats ${DAILY_MOUNT}
}

print_disk_info () {
	print_files
	echo ""
	print_disk_stats
}

clean_daily () {
	[[ -n ${verbose} ]] && local extra="--verbose"
	local oldest="${DAILY_MOUNT}/$(echo "$(get_files)" | head -1 \
		| awk '{print $NF}' | tr -d '[:cntrl:]')"

	echo "TODO: Would clean: @@${BACKUP_SERVER}:${oldest}@@."

	#local cmd="${SSH} rm -rf ${extra} ${oldest}"
	local cmd="${SSH} ls -ld ${extra} ${oldest}"

	run_cmd ${cmd}
	exit 1
}

mount_op () {
	local extra
	[[ -n ${verbose} ]] && local extra="--verbose"
	local op="${1}"
	local mnt
	local cmd
	
	for mnt in ${FULL_MOUNT} ${DAILY_MOUNT}; do
		cmd="${SSH} ${op} ${extra} ${mnt}"

		run_cmd ${cmd}

		if [[ "${op}" == "mount" ]]; then
			need_umount=1
		fi
	done
}

mount_vols () {
	mount_op "mount"
}

umount_vols () {
	trap - EXIT INT PIPE
	if [[ ${need_umount} ]]; then
		mount_op "umount"
	fi
	exit ${result}
}

on_exit () {
	trap - EXIT INT PIPE
	umount_vols
	exit ${result}
}

trap on_exit EXIT INT PIPE

mount_vols

if [[ -n "${disk_usage}" ]]; then
	print_disk_info
	echo ""
	echo "Getting disk usage..."
	disk_usage
	exit 0
fi

if [[ -n "${disk_stats}" ]]; then
	print_disk_info
	exit 0
fi

if [[ -n "${clean}" ]]; then
	clean_daily
	echo ""
	print_disk_info
	exit 0
fi

echo "-- ${today} backup --"

[[ -n ${debug} ]] && rsync_extra="--verbose"

result=0
for s in ${SRC}; do
	suf=${s////-}
	cmd="sudo rsync -a --delete --inplace --backup \
		${rsync_extra} \
		--backup-dir=${DAILY_MOUNT}${DAILY_PATH}-${suf}/ \
		${s}/ ${BACKUP_SERVER}:${FULL_MOUNT}${FULL_PATH}-${suf}/"
	run_cmd ${cmd}
	[[ $? != 0 ]] && result=$?
done

print_disk_stats
