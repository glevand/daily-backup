#!/usr/bin/env bash

usage() {
	local old_xtrace
	old_xtrace="$(shopt -po xtrace || :)"
	set +o xtrace

	{
		echo "${script_name} - Daily rsync backup."
		echo "Usage: ${script_name} [flags]"
		echo "Option flags:"
		echo "  -c --clean    - Delete oldest existing daily backup."
		echo "  -s --stats    - Report backup server disk stats."
		echo "  -u --usage    - Report backup server disk usage (slow)."
		echo "  -k --checksum - Use rsync checksum (slow)."
		echo "  -h --help     - Show this help and exit."
		echo "  -v --verbose  - Verbose execution. Default: '${verbose}'."
		echo "  -g --debug    - Extra verbose execution. Default: '${debug}'."
		echo "  -d --dry-run  - Dry run, don't run rsync."
		echo "Environment/Config:"
		echo "  backup_server      - Required. Default: '${backup_server:-(none)}'"
		echo "  backup_list        - List of directories to backup. Default: '${backup_list[@]}'"
		echo "  full_backup_mount  - Default: '${full_backup_mount}'"
		echo "  full_backup_path   - Default: '${full_backup_path}'"
		echo "  daily_backup_mount - Default: '${daily_backup_mount}'"
		echo "  daily_backup_path  - Default: '${daily_backup_path}'"
		echo "Examples:"
		echo "  backup_server=\"my-backup\" ${script_name} -s"
		echo "  nice -n19 ${script_name} -v"
	} >&2

	eval "${old_xtrace}"
}

process_opts() {
	local short_opts="csukhvgd"
	local long_opts="clean,stats,usage,checksum,help,verbose,debug,dry-run"

	local opts
	opts=$(getopt --options ${short_opts} --long ${long_opts} -n "${script_name}" -- "$@")

	eval set -- "${opts}"

	while true ; do
		#echo "${FUNCNAME[0]}: @${1}@ @${2}@"
		case "${1}" in
		-c | --clean)
			disk_clean=1
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
		-k | --checksum)
			checksum=1
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
		-g | --debug)
			verbose=1
			debug=1
			keep_tmp_dir=1
			set -x
			shift
			;;
		-d | --dry-run)
			dry_run=1
			shift
			;;
		--)
			shift
			arg_1="${1:-}"
			if [[ ${arg_1} ]]; then
				shift
			fi
			extra_args="${*}"
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

	local sec="${SECONDS}"

	if [[ -d "${tmp_dir:-}" ]]; then
		if [[ ${keep_tmp_dir:-} ]]; then
			echo "${script_name}: INFO: tmp dir preserved: '${tmp_dir}'" >&2
		else
			rm -rf "${tmp_dir:?}"
		fi
	fi

	umount_vols

	echo "${script_name}: Done: ${result}, ${sec} sec." >&2
}

on_err() {
	local f_name=${1}
	local line_no=${2}
	local err_no=${3}

	{
		if [[ ${on_err_debug:-} ]]; then
			echo '------------------------'
			set
			echo '------------------------'
		fi
		echo "${script_name}: ERROR: function=${f_name}, line=${line_no}, result=${err_no}"
	} >&2

	exit "${err_no}"
}

find_config() {
	local dirs="${SCRIPT_TOP} ${HOME} /etc"
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

run_remote_cmd() {
	local host=${1}
	shift
	local cmd="${@}"
	local ssh_opts=''

	if [[ ! ${verbose} ]]; then
		ssh_opts=' --quiet'
	fi

	if [[ "${host}" == 'localhost' ]]; then
		full_cmd="${cmd}"
	else
		full_cmd="${ssh} ${ssh_opts} ${host} ${cmd}"
	fi
	eval "${full_cmd}"
}

disk_usage() {
	for mnt in ${full_backup_mount} ${daily_backup_mount}; do
		local cmd="${SSH} du -sh ${mnt}/*"
		eval "${cmd}" | grep -E --invert-match 'lost\+found' | grep -E '^d'
	done
}

get_files() {
	local dir=${1}

	run_remote_cmd "${backup_server}" ls -dgotr "${dir}" | grep -E --invert-match 'lost\+found'  | grep -E '^d'
}

print_files() {
	{
		echo "${script_name}: INFO: full backups:"
		get_files "${full_backup_mount}${full_backup_path}/full/*"

		echo
		echo "${script_name}: INFO: daily backups:"
		get_files "${daily_backup_mount}${daily_backup_path}/daily-*"
		echo
	}
}

get_disk_stats() {
	local mnt=${1}

	run_remote_cmd "${backup_server}" df -h | grep -E "(Filesystem|${mnt})"
}

print_disk_stats() {
	{
		echo "${script_name}: INFO: full mount stats:"
		get_disk_stats "${full_backup_mount}"
		echo
		echo "${script_name}: INFO: daily mount stats:"
		get_disk_stats "${daily_backup_mount}"
		echo
	}
}

print_disk_info() {
	print_files
	print_disk_stats
}

clean_daily() {
	#local files
	#files=$(get_files "${daily_backup_mount}" | awk '{print $NF}')

	local oldest
	oldest="$(get_files "${daily_backup_mount}" | awk '{print $NF}' | head -1 | sed 's/\r//')"

	if [[ -z "${oldest}" ]]; then
		echo "${script_name}: INFO: No files found: '${backup_server}:${daily_backup_mount}'." >&2
		return 0
	fi

	echo "TODO: Would clean: '${backup_server}:${daily_backup_mount}/${oldest}'."

	if [[ ${verbose} ]]; then
		local extra="--verbose"
	fi

	#local cmd="${SSH} rm -rf ${extra} ${daily_backup_mount}/${oldest}"
	local cmd="${SSH} ls -ld ${daily_backup_mount}/${oldest}"

	eval "${cmd}"
}

mount_vols() {
	local mnt

	for mnt in "${full_backup_mount}" "${daily_backup_mount}"; do
		if [[ "${backup_server}" == 'localhost' ]] && mountpoint -q "${mnt}"; then
			if [[ ${verbose} ]]; then
				echo "${script_name}: INFO: '${mnt}' already mounted." >&2
			fi
			continue
		fi
		unmount_list+=("${mnt}")
		run_remote_cmd "${backup_server}" mount --verbose "${unmount_list[i]}"
	done

# 	echo "${FUNCNAME[0]}: unmount_list count = ${#unmount_list[@]}"
# 	for (( i = 0; i < ${#unmount_list[@]}; i++ )); do
# 		echo "${FUNCNAME[0]}: '${unmount_list[i]}'"
# 	done
}

umount_vols() {
	local i

# 	echo "${FUNCNAME[0]}: unmount_list count = ${#unmount_list[@]}"

	for (( i = 0; i < ${#unmount_list[@]}; i++ )); do
		echo "${FUNCNAME[0]}: '${unmount_list[i]}'"

		run_remote_cmd "${backup_server}" umount --verbose "${unmount_list[i]}"
		unset unmount_list[i]
	done
}

#===============================================================================
export PS4='\[\e[0;33m\]+ ${BASH_SOURCE##*/}:${LINENO}:(${FUNCNAME[0]:-main}):\[\e[0m\] '

script_name="${0##*/}"

SECONDS=0
start_time="$(date +%Y.%m.%d-%H.%M.%S)"

real_source="$(realpath "${BASH_SOURCE}")"
SCRIPT_TOP="$(realpath "${SCRIPT_TOP:-${real_source%/*}}")"

trap "on_exit 'Failed'" EXIT
trap 'on_err ${FUNCNAME[0]:-main} ${LINENO} ${?}' ERR
trap 'on_err SIGUSR1 ? 3' SIGUSR1

set -eE
set -o pipefail
set -o nounset

disk_clean=''
disk_stats=''
disk_usage=''
checksum=''
usage=''
verbose=''
debug=''
dry_run=''

keep_tmp_dir=''
rsync_opts=''

declare -a unmount_list=()

ssh="${ssh:-ssh}"
rsync="${rsync:-rsync}"

process_opts "${@}"

config_file="${config_file:-$(find_config)}"

if [[ -f "${config_file}" ]]; then
	source "${config_file}"
else
	echo "${script_name}: WARNING: No config file found." >&2
fi

if [[ ${usage} ]]; then
	usage
	trap - EXIT
	exit 0
fi

{
	echo "${script_name} -- ${start_time}"
	echo
}

full_dir="${full_backup_mount}${full_backup_path}/full"
daily_dir="${daily_backup_mount}${daily_backup_path}/daily-${start_time}"

mount_vols

if [[ ${disk_usage} ]]; then
	print_disk_info
	echo ""
	echo "Getting disk usage..."
	disk_usage
	trap "on_exit 'Success'" EXIT
	exit 0
fi

if [[ ${disk_stats} ]]; then
	print_disk_info
	trap "on_exit 'Success'" EXIT
	exit 0
fi

if [[ ${disk_clean} ]]; then
	clean_daily
	echo ""
	print_disk_info
	trap "on_exit 'Success'" EXIT
	exit 0
fi

if [[ ${verbose} ]]; then
	rsync_opts+=" --verbose"
fi

if [[ ${checksum} ]]; then
	rsync_opts+=' --checksum'
fi

if [[ "${backup_server}" == 'localhost' ]]; then
	remote_host=''
else
	remote_host="${backup_server}"
fi

# for (( i = 0; i < ${#backup_list[@]}; i++ )); do
# 	echo "${script_name}: INFO: Processing '${backup_list[i]}'." >&2
# 
# 	backup_dir="${backup_list[i]%/*}"
# 	full_dir="${full_backup_mount}${full_backup_path}/full${backup_dir}"
# 	daily_dir="${daily_backup_mount}${daily_backup_path}/daily-${start_time}${backup_dir}"
# 
# 	run_remote_cmd "${backup_server}" mkdir -p "${full_dir}"
# 	run_remote_cmd "${backup_server}" mkdir -p "${daily_dir}"
# 
# 	"${rsync}" --archive --delete --inplace --times ${rsync_opts} --backup \
# 		--backup-dir="${remote_host}${daily_dir}" \
# 		"${backup_list[i]}" "${remote_host}${full_dir}"
# done

for (( i = 0; i < ${#backup_list[@]}; i++ )); do
	echo "${script_name}: INFO: Processing '${backup_list[i]}'." >&2

	run_remote_cmd "${backup_server}" mkdir -p "${full_dir%/*}" "${daily_dir%/*}"

	"${rsync}" --archive --delete --inplace --times ${rsync_opts} --backup \
		--backup-dir="${remote_host}${daily_dir}" \
		"${backup_list[i]}" "${remote_host}${full_dir}"
done

print_disk_stats

trap "on_exit 'Success'" EXIT
exit 0
