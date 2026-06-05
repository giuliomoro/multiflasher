#!/bin/bash

set -e

EXPERT=0
QUIET=0
USER_DISK=
FILE=
usage() {
	echo ""
	echo "  Usage: $0 [-e -q -h] <file> <user-provided-disk>"
	echo ""
	echo "  Flashes file <file> to all external disks and, if provided, to <user-provided-disk?"
	echo "  Flashing happens in parallel on all disks"
	echo "  When done, or an error occurs, it launches a system notification and sound"
	echo "  Options:"
	echo "    -e: expert mode, do not prompt for confirmation"
	echo "    -q: quiet mode: do not send notifications and sounds"
	echo "    -h: print this help"
}

[ $# == 0 ] && {
	usage
	exit 1
}
while [ $# -ne 0 ]; do
	case "$1" in
		-e)
			EXPERT=1
		;;
		-q)
			QUIET=1
		;;
		-h)
			usage
		;;
		*)
			IS_VALID=$(if [ -f "$1" -o -b "$1" ]; then echo yes; else echo no; fi)
			if [ -z "$FILE" -a $IS_VALID == yes ]; then
				FILE="$1"
			elif [ -n "$FILE" -a -z "$USER_DISK" -a $IS_VALID == yes ]; then
				USER_DISK="$1"
			else
				echo "Error: unknown option or non-existing filename or invalid disk '$1'"
				exit 1
			fi
		;;
	esac
	shift
done
[ -z "$FILE" ] && {
	echo "Error: missing argument <file>"
	usage
	exit 1
}
# Background tasks will no longer write directly to the console; instead,
#  they will write to temporary files which will be read periodically
#  by a special log printer task (which will display everything nicely.)
#
# Name of temporary files
STATUS_BASENAME="/tmp/~$$.status"
# Process IDs of backgrounded tasks; we record them so we can wait on them
#  specifically but not wait on the special log printer task
TASK_PIDS=""

notify() {
	TEXT="$@"
	echo "$TEXT"
	if [ $QUIET -eq 0  ]; then
		which -s osascript && osascript -e 'display notification "'"$TEXT"'" with title "multiflasher"' || true
		which -s say && say "$TEXT" || true
	fi
}

# Special log printer task
status_printer() {
	# First time in the loop is special insofar we don't have to
	#  scroll up to overwrite previous output.
	LOGS=()
	FIRST_TIME=1
	while [ true ] ; do
		# If not first time, scroll up as many lines as we have
		#  regular background tasks to overwrite previous output.
		PRINTED_LINES=${#TASK_PIDS[@]}
		(( PRINTED_LINES = PRINTED_LINES * 1))
		if test $FIRST_TIME -eq 0; then
			printf '\033[%dF' "$PRINTED_LINES"
		fi
		FIRST_TIME=0
		TASK_ID=0
		for ((n=0;n<${#TASK_PIDS[@]};n++)); do
				PID=${TASK_PIDS[$n]}
				LOG="${STATUS_BASENAME}.${TASK_ID}"
				LOGS[$n]="$LOG"
				# If status file exists print first line
				printf "$n ${DISKS[$n]} ${LOG} : "
				test -f ${LOG} && {
					awk -v RS='\r' 'NF { last=$0 } END { print last }' "$LOG"
				} || echo "waiting... "
				TASK_ID=`expr $TASK_ID + 1` # using expr for portability :)
		done
		test -f "${STATUS_BASENAME}.done" && {
			break
		}
		sudo -v # extend lifetime of sudo credentials so we can use it for killing dd at the end
		sleep 1 # seconds to wait between updates
	done
	set +e
	ERROR=
	for l in ${LOGS[@]}; do
		ERROR="$ERROR$(cat $l | grep -i error)" || true
	done
	if [ "$ERROR" == "" ]; then
		notify "Completed" &
	else
		notify "Completed with errors" &
		echo __"$ERROR"__
	fi

	rm -f "${STATUS_BASENAME}."*
}

do_flash() {
	# First parameter must be a task ID starting at 0 incremented by 1
	TASK_ID=$1
	d=$2
	LOG="${STATUS_BASENAME}.${TASK_ID}"
	set +e
	sudo dd if=$FILE of=$d bs=1m status=progress conv=fsync >${LOG} 2>&1
	if [ $? -eq 0 ]; then
		# printf "\rsuccess\e[J" > ${LOG}
		printf "\rsuccess\e[J" > ${LOG}
	else
		printf "\rERROR\e[J" > ${LOG}
	fi
}

cleanup() {
	set +e
	# Gracefully stop special printer task instead of just killing it
	echo yesdone > "${STATUS_BASENAME}.done"
	# Cleanup
	for p in ${TASK_PIDS[@]}; do
		sudo kill -9 $p 2>/dev/null
	done
	wait $PRINTER_PID
}

print_disk() {
	DISK="$1"
	TAG="$2"
	SIZE=$(diskutil list "$DISK" | grep "disk[0-9]*$" | sed "s/ \{1,\}/ /g" | cut -d" " -f 4,5 | sed "s/\*//g")
	NUMBER=$(echo $SIZE | cut -d" " -f1 | sed "s/\..*//" )
	UNIT=$(echo $SIZE | cut -d" " -f2)
	[ $NUMBER -gt 70 -o "GB" != "$UNIT" ] && {
		echo "Disk $DISK's size $SIZE looks suspicious. Abort"
		exit 1
	}
	printf "   $DISK $SIZE $TAG\n"
}

rm -f "${STATUS_BASENAME}."*
FILE=/Users/giulio/Downloads/pocketbeagle2-debian-12.13-bela-v6.12-arm64-2026-03-25-8gb.img
echo Retrieving disks...
DISKS=($(diskutil list external | grep -o "/dev/disk[0-9]*" | grep -v "/dev/disk0\|/dev/disk1")) || true # safety filtering!

trap cleanup EXIT

n=0
while true; do
	echo "The following disks have been detected for flashing:"
	for ((n=0;n<${#DISKS[@]};n++)); do
		print_disk "${DISKS[$n]}"
	done
	[ -n "$USER_DISK" ] && {
		if [ -f "$USER_DISK" ]; then
			echo "User-provided disk $USER_DISK not found"
		else
			print_disk $USER_DISK "(user-provided)"
			DISKS+=("$USER_DISK")
		fi
	}
	if [ "$EXPERT" == 0 ]; then
		echo " Make sure they are all good and press enter to continue. To kill the program at any time press ctrl-C"
		read LINE
		if [ "$LINE" == "" ]; then
			break
		fi
	else
		break
	fi
done

if [ "$EXPERT" == 0 ]; then
	echo "Enter the sudo password to continue flashing $FILE onto disks ${DISKS[@]}"
	# prompting for passwword here makes sure we won't be prompted when flashing actually starts
	sudo -k
	sudo echo Continuing...
else
	echo "Expert mode: you may be prompted for sudo password, if needed"
	sudo -v
fi

echo "Unmounting disks"

TASK_PIDS=()
for ((n=0;n<${#DISKS[@]};n++)); do
	d=${DISKS[$n]}
	diskutil umountDisk $d &
	TASK_PIDS[$n]="$TASK_PIDS $!"
done
wait ${TASK_PIDS[@]}

echo "Starting flashing processes"

TASK_PIDS=()
for ((n=0;n<${#DISKS[@]};n++)); do
	d=${DISKS[$n]}
	d=$(echo $d | sed "s:/disk:/rdisk:g")
	echo $d
	do_flash $n $d &
	TASK_PIDS[$n]="$TASK_PIDS $!"
done

echo Flashing status:
status_printer &
PRINTER_PID=$!

# Wait for background tasks
wait ${TASK_PIDS[@]}

# cleanup() will be called now by the trap
