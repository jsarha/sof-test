#!/bin/bash

set -e

##
## Case Name: check suspend/resume status
## Preconditions:
##    N/A
## Description:
##    Run the suspend/resume command to check device status
## Case step:
##    1. switch suspend/resume operation
##    2. use rtcwake -m mem command to do suspend/resume
##    3. check command return value
##    4. check dmesg errors
##    5. check wakeup increase
## Expect result:
##    suspend/resume recover
##    check kernel log and find no errors
##

# shellcheck source=case-lib/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")"/../case-lib/lib.sh

random_min=3    # wait time should >= 3 for other device wakeup from sleep
random_max=20

OPT_NAME['l']='loop'     OPT_DESC['l']='loop count'
OPT_HAS_ARG['l']=1         OPT_VAL['l']=5

OPT_NAME['T']='type'    OPT_DESC['T']="suspend/resume type from /sys/power/mem_sleep"
OPT_HAS_ARG['T']=1         OPT_VAL['T']=""

OPT_NAME['S']='sleep'    OPT_DESC['S']='suspend/resume command:rtcwake sleep duration'
OPT_HAS_ARG['S']=1         OPT_VAL['S']=5

OPT_NAME['w']='wait'     OPT_DESC['w']='idle time after suspend/resume wakeup'
OPT_HAS_ARG['w']=1         OPT_VAL['w']=5

OPT_NAME['r']='random'   OPT_DESC['r']="Randomly setup wait/sleep time, range is [$random_min-$random_max], this option will overwrite s & w option"
OPT_HAS_ARG['r']=0         OPT_VAL['r']=0

func_opt_parse_option "$@"
func_lib_check_sudo

type=${OPT_VAL['T']}
# switch type
if [ "$type" ]; then
    # check for type value effect
    grep -q "$type" /sys/power/mem_sleep || {
        grep -H '^' /sys/power/mem_sleep
        die "Unsupported sleep type argument: $type"
    }
    dlogc "echo $type > /sys/power/mem_sleep"
    echo "$type" | >/dev/null sudo tee -a /sys/power/mem_sleep
fi
dlogi "Current suspend/resume type mode: $(cat /sys/power/mem_sleep)"

loop_count=${OPT_VAL['l']}
declare -a sleep_lst wait_lst

if [ ${OPT_VAL['r']} -eq 1 ]; then
    # create random number list
    for i in $(seq 1 $loop_count)
    do
        sleep_lst[$i]=$(func_lib_get_random $random_max $random_min)
        wait_lst[$i]=$(func_lib_get_random $random_max $random_min)
    done
else
    for i in $(seq 1 $loop_count)
    do
        sleep_lst[$i]=${OPT_VAL['S']}
        wait_lst[$i]=${OPT_VAL['w']}
    done
fi

save_initial_stats()
{
    printf '\n\n'

    INITIAL_DBG_SOURCES="$LOG_ROOT"/initial_wakeup_sources.txt
    sudo cat /sys/kernel/debug/wakeup_sources | sudo tee "$INITIAL_DBG_SOURCES"

    INITIAL_STATS="$LOG_ROOT"/initial_suspend_stats.txt
    grep ^ /sys/power/suspend_stats/*fail* |
        sudo tee "$INITIAL_STATS" > /dev/null

    if grep -E ':[[:digit:]]+$' "$INITIAL_STATS" | grep -q -v ':0$'; then
        dlogw "Starting test with earlier suspend failures!"
    fi
    printf '\n'

    find /sys/devices -wholename '*/power/wakeup' -print0 |
        xargs --null grep -H 'enabled'; printf '\n'
    dlogi "Note many of the devices above are typically buses, not actual devices"
    dlogi "https://docs.kernel.org/driver-api/pm/devices.html#sys-devices-power-wakeup-files"
    printf '\n'
    lspci;    printf '\n'
    lsusb -tvv; printf '\n\n'
}

check_suspend_fails()
{
    diff -u "$INITIAL_STATS" <(grep ^ /sys/power/suspend_stats/*fail*)
}

dump_stats()
{
    printf '\n'
    grep ^ /sys/power/suspend_stats/*
    printf '\n'
    # Show colunm names
    sudo cat /sys/kernel/debug/wakeup_sources | head -n 1
    # identical is most likely a bug!
    sudo diff -u --report-identical-files \
         "$INITIAL_DBG_SOURCES" /sys/kernel/debug/wakeup_sources ||
        true
    printf '\n'
}

dump_and_die()
{
    dump_stats
    die "$@"
}

# This is used to workaround https://github.com/thesofproject/sof-test/issues/650,
# which may be caused by kernel issue or unstable network connection.
# TODO: remove this after issue fixed.
sleep 1

expected_wakeup_count=$(cat /sys/power/wakeup_count)
expected_stats_success=$(cat /sys/power/suspend_stats/success)
save_initial_stats
for i in $(seq 1 $loop_count)
do
    dlogi "===== Round($i/$loop_count) ====="
    # set up checkpoint for each iteration
    setup_kernel_check_point
    expected_wakeup_count=$((expected_wakeup_count+1))
    expected_stats_success=$((expected_stats_success+1))
    dlogc "Run the command: rtcwake -m mem -s ${sleep_lst[$i]}"
    sudo rtcwake -m mem -s "${sleep_lst[$i]}" ||
        dump_and_die "rtcwake returned $?"
    dlogc "sleep for ${wait_lst[$i]}"
    sleep ${wait_lst[$i]}
    dlogi "Check for the kernel log status"
    # check kernel log for each iteration to catch issues
    sof-kernel-log-check.sh "$KERNEL_CHECKPOINT" || dump_and_die "Caught error in kernel log"
    # check wakeup count correct
    wake_count=$(cat /sys/power/wakeup_count)
    stats_success=$(cat /sys/power/suspend_stats/success)
    dlogi "Check for wakeup_count and suspend_stats"
    [ "$wake_count" -eq "$expected_wakeup_count" ] || {
        dump_stats
        dlogw "/sys/power/wakeup_count is $wake_count, expected $expected_wakeup_count"
        printf '\n'
        expected_wakeup_count=${wake_count}
    }
    [ "$stats_success" -eq "$expected_stats_success" ] ||
        dump_and_die "/sys/power/suspend_stats/success is $stats_success, expected $expected_stats_success"
    check_suspend_fails || dump_and_die "some failure counts have changed"

done

