#!/bin/bash
#
# @(#) cdsinit - Vignette CDS init script
#
# John Helliwell 20090624 6th revision

# Usage
# cdsinit [ start|stop|restart|status ]

LOCKDIR=/export/home/xml0
LOCKFILE="$LOCKDIR/.lock.$HOSTNAME"
MAXORACON=32
DURATION=1200
MAXFDS=600
MAILTO="[REDACTED]"
LOGFILE=/var/log/filedescriptors
DOCROOT=/opt/vignette/5.0/docroot
MYPID=$$
MYNAME=`basename $0`
TMPDIR=/var/tmp
TIMESTAMP=${TMPDIR}/${MYNAME}.timestamp
TOLOG="yes"
MAILOUT=${TMPDIR}/${MYNAME}.mailout.${MYPID}
LASTLOG=${TMPDIR}/${MYNAME}.lastlog
SQLTMP=${TMPDIR}/sqltmp.${MYPID}
trap _exit 1 2 15

mylog()
{
	[ "$TOLOG" ] || return 1
        [ -f $LOGFILE ] || /usr/bin/echo "${MYNAME}[${MYPID}]: `date` - Starting new logfile\c" >> $LOGFILE
        [ -f $LASTLOG ] || echo "init" > $LASTLOG
        if [ $# -gt 0 ]
        then
                last="`cat $LASTLOG`"
                if [ "$last" = "$*" ]
                then
                        /usr/bin/echo ".\c" >> $LOGFILE
                        return 0
                fi
                echo "$@" > $LASTLOG
                /usr/bin/echo "\n${MYNAME}[${MYPID}]: `date` - $@\c" >> $LOGFILE
        else
                /usr/bin/echo "\n${MYNAME}[${MYPID}]: `date` -\n`cat -`\c" >> $LOGFILE
        fi
        return 0
}

mailout()
{
	/usr/bin/echo "`date` : $@\t"
	/usr/bin/echo "`date` : $@\t" >> $MAILOUT
}

abort_mailout()
{
	rm -f $MAILOUT
}

_exit()
{
	if [ -f $MAILOUT ]
	then
                { 
                	echo "From: ${MYNAME} <root@${HOSTNAME}>"
                	echo "To: ${MAILTO}"
                	echo "Subject: sysmsg:${MYNAME} CDS restart activity"
                	echo ""
			cat $MAILOUT
			echo ""
			echo "For more detail, please refer to $LOGFILE"
		} | /usr/lib/sendmail ${MAILTO}
		rm -f $MAILOUT
	fi
	rm -f ${SQLTMP}.stage1 ${SQLTMP}
	exit $@
}

there_is_a_lock()
{
	##
	# Determine if another cds is in the process of restarting
	# On any CDS machine. If so,then restarting CDS on this
	# node should be avoided.
	# The locking mechanism uses shared storage between CDS's
	##

	# OTHERLOCKS will include locks on THIS host, plus
	# locks on any other CDS host
	OTHERLOCKS=`ls -1 $LOCKDIR/.lock.* 2>/dev/null`
	if [ "$OTHERLOCKS" ]
	then
		mylog "NOTICE: Already locked - $OTHERLOCKS"
		return 0
	else
		return 1
	fi
}

lock_is_mine()
{
	# If LOCKFILE file exists, the lockfile belongs to THIS host
	if [ -f "$LOCKFILE" ]
	then
		return 0
	else
		return 1
	fi
}

lock_is_stale()
{
	##
	# Determine if a previous lock file is stale. 
	##

	if lock_is_mine
	then
		OLDPID=`cat $LOCKFILE`
		if ps -fp"$OLDPID"
		then
			return 1
		else
			mylog "NOTICE: Lock file is stale"
			return 0
		fi
	fi
	# Lock is another system's lock file. We exit here it's not safe to restart vignette right now
	abort_mailout
	_exit 1
}

create_lock()
{
	su vgnadmin -c "echo $MYPID > $LOCKFILE"
	NEW=`cat $LOCKFILE`
	if [ "$MYPID" = "$NEW" ]
	then
		mylog "Created new lock file"
		return 0
	else
		mylog "FATAL: Unable to create lock"
		_exit 255
	fi
}

remove_lock()
{
	mylog "Removing lock"
	su vgnadmin -c "rm -f $LOCKFILE"
	return 0
}

check_lock()
{
	# Avoid a race condition situation where multiple systems
	# create a lock at exactly the same time, by making
	# different systems sleep for a different amount of time
	race_condition=`hostname | tr -d "[A-Z][a-z]."`
	sleep $race_condition
	if there_is_a_lock
	then
		if lock_is_stale
		then
			remove_lock
		else
			abort_mailout
			_exit 1
		fi
	fi
	return 0
}

safekill()
{
	for process in $@
	do
		if ps -fp$process > /dev/null 2>&1
		then
			mylog "Sending SIGTERM to `ps -o comm -fp$process | tail -1`"
			kill $process
		else
			mylog "safekill: $process has already terminated"
		fi
	done
	return 0
}

reallykill()
{
	for process in $@
	do
		if ps -fp$process > /dev/null 2>&1
		then
			mylog "Sending SIGKILL to `ps -o comm -fp$process | tail -1`"
			kill -9 $process
		else
			mylog "reallykill: $process has already terminated"
		fi
	done
	return 0
}

left_running_after()
{
	mylog "Checking for any running instances of $2"
	NUM=`pgrep $2 | wc -l`
	if [ $NUM -eq 0 ]
	then
		mylog "There are no $2 processes left running"
		return 1
	else
		mylog "There are $NUM $2 processes still running"
	fi
	mylog "Pausing for a maximum of $1 seconds for $2 to terminate"
	echo "          Waiting for $2 to terminate"
	CHECK=0
	while [ $CHECK -lt $1 ]
	do
		if [ `pgrep $2 | wc -l` -eq 0 ]
		then
			mylog "$2 terminated itself after $CHECK seconds"
			return 1
		fi
		sleep 1
		/usr/bin/echo "`expr $1 - $CHECK`                    \r\c"
		let CHECK=CHECK+1
	done
	if [ `pgrep $2 | wc -l` -eq 0 ]
	then
		mylog "$2 terminated after $CHECK seconds"
		return 1
	else
		mylog "$2 did not terminate in the alotted time period"
		return 0
	fi
}

left_running()
{
	if [ `pgrep $1 | wc -l` -eq 0 ]
	then
		return 1
	else
		return 0
	fi
}

pid_left_running()
{
	return `ps -fp$1 >/dev/null 2>&1`
}

pid_left_running_after()
{
	name="unknown"
	if pid_left_running $2
	then
		name=`ps -o comm -fp$2 | grep -v COMMAND | grep -v defunct | tail -1`
		[ "$name" ] || name="unknown"
	else
		[ "$3" = "nolog" ] || mylog "Process ID $2 has completed"
		return 1
	fi
	[ "$3" = "nolog" ] || mylog "Pausing for a maximum of $1 seconds for Process ID $2 ($name) to terminate"
	echo "          Waiting for $2 ($name) to terminate"
	CHECK=0
	while [ $CHECK -lt $1 ]
	do
		if ! pid_left_running $2
		then
			[ "$3" = "nolog" ] || mylog "Process ID $2 ($name) terminated itself after $CHECK seconds"
			return 1
		fi
		/usr/bin/echo "`expr $1 - $CHECK`                    \r\c"
		sleep 1
		let CHECK=CHECK+1
	done
	if ! pid_left_running $2
	then
		[ "$3" = "nolog" ] || mylog "Process ID $2 ($name) terminated after $CHECK seconds"
		return 1
	else
		[ "$3" = "nolog" ] || mylog "Process ID $2 ($name) did not terminate in the alotted time period"
		return 0
	fi
}
	
oracle_session_kill()
{
	##
	# Kill sessions from inside Oracle.
	# During a busy time once, this SQL script took an hour to complete
	# To combat this kind of thing, we background the SQL and then if
	# it hasnt terminated in a timely fashion, we mercilessly kill it
	##

	##
	# This sqlplus procedure was adapted from kill_cds_processes.sh written by Steve G
	##

	ORACLE_SID=TEAM
	export ORACLE_SID
	ORACLE_HOME=/oracle/product/8.1.6
	export ORACLE_HOME ORACLE_SID

	echo "
col Process_count_per_machine for 99999999999
col machine_name for a24
set linesize 100
set head off
set feed off
set verify off
set pages 0
  select s.sid as ssid,
         s.serial#,
         s.MACHINE, p.spid
  from v\$session s,
          v\$process p
  where
 p.addr = s.paddr
 and s.username = 'VIGNETTE'
 and s.osuser = 'vgnadmin'
 and s.machine = '"${HOSTNAME}"'
  order by s.sid; 
spool "${SQLTMP}"
  select 
'ALTER SYSTEM KILL SESSION '||''''||s.sid||','||s.serial#||''''||';'
  from v\$session s,
          v\$process p
  where
 p.addr = s.paddr
 and s.username = 'VIGNETTE'
 and s.osuser = 'vgnadmin'
 and s.machine = '"${HOSTNAME}"'
  order by s.sid;
spool off

start "${SQLTMP}"
start "${SQLTMP}"

exit; " > "${SQLTMP}.stage1"
cat "${SQLTMP}.stage1" | ${ORACLE_HOME}/bin/sqlplus -s system/REDACTED &
ORAKILL=$!
mylog "Oracle session kill is running with Process ID $ORAKILL"
if pid_left_running_after $1 $ORAKILL
then
	mylog "Timed out waiting for the Oracle session kill SQL after $1 seconds"
	safekill $ORAKILL
	if pid_left_running after $1 $ORAKILL
	then
		mylog "WARNING: had to kill -9 the Oracle Session kill SQL"
		reallykill $ORAKILL
	fi
else
	mylog "Oracle session kill SQL contained the following"
	cat $SQLTMP | mylog
fi

echo "Waiting for Oracle"
sleep 30

}

stop_cds()
{

	##
	# You can be confident that when this procedure returns, there will be NO vignette processes running AT ALL
	##

	create_lock
	mylog "Stopping CDS"
	mailout "Phase 1 - Stopping CDS"
	/opt/vignette/inst-teamtalk/conf/admin stop 
	mailout "Phase 2 - Checking processes"
	WAIT_TIME=10
	if left_running_after $WAIT_TIME ctlds
	then
		#mailout "Phase 2a - Disconnecting leftover Oracle sessions"
		#oracle_session_kill $WAIT_TIME > /dev/null 2>&1
		mailout "Phase 2a - Killing leftover ctlds processes"
		CTLDSPIDS=`pgrep ctlds`
		safekill "$CTLDSPIDS"
	fi

	WAIT_TIME=10
	for process in tmd pad cmd
	do
		if left_running_after $WAIT_TIME $process
		then
			mailout "Phase 2b - Killing leftover $process process"
			TMDPIDS=`pgrep $process`
			safekill "$TMDPIDS"
		fi
	done
	
	# Right. We've given Vignette loads of opportunity to shut down gracefully
	# Now we just blast it out of the Sky
	
	# ctldm spawns new ctlds's sometimes so its good practice to test for ctlds processes
	# more than once. Three loops through won't hurt
	for kill_loop in 1 2 3
	do
		if left_running ctlds
		then
			if left_running_after $WAIT_TIME ctlds
			then
				mailout "Phase 2c - Disconnecting remaining Oracle sessions"
				oracle_session_kill $WAIT_TIME > /dev/null 2>&1
				mailout "Phase 2d - Killing (with -9) remaining ctlds processes"
				CTLDSPIDS=`pgrep ctlds`
				reallykill "$CTLDSPIDS"
			fi
		fi
		for process in tmd pad cmd
		do
			if left_running $process
			then
				mylog "Stray $process processes left: Sending SIGKILL"
				if left_running_after 5 $process
				then
					mailout "Phase 2e - Killing (with -9) remaining $process process"
					TMDPIDS=`pgrep $process`
					reallykill "$TMDPIDS"
				fi
			fi
		done
	done

	if left_running ctldm
	then
		CTLDM=`pgrep ctldm`
		safekill $CTLDM
		mylog "NOTICE: kill -15 ctldm"
		if left_running ctldm
		then
			if left_running_after 5 ctldm
			then
				mylog "NOTICE: kill -9 ctldm"
				reallykill ctldm
			fi
		fi
	fi

	# status
	echo "Phase 3 - Checking remaining CDS processes"
	for process in ctldm ctlds pad tmd cmd
	do
		if left_running $process
		then
			echo "Problem: There are still $process processes running"
		else
			echo "$process DOWN"
		fi
	done
}

start_cds()
{
	remove_lock		# Let the other systems restart their CDS
	date "+%Y%m%d%H%M%S" > $TIMESTAMP
	mylog "Starting CDS"
	mailout "Phase 3 - Initiating CDS admin start"
	/opt/vignette/inst-teamtalk/conf/admin start
}

restart_cds()
{
	##
	# Restart Vignette Content Management Services
	##

	# If you call this with an argument of "immediate" it restarts CDS real quick!
	# otherwise it does a nice graceful restart of CDS

	mailout "Restart of CDS on $HOSTNAME"

	# Avoid situations where this script may constantly restart Vignette
	# by disallowing more than one restart in a 10 minute period
	
	if [ -f $TIMESTAMP ]
	then
		LAST=`cat $TIMESTAMP`
		NOW=`date "+%Y%m%d%H%M%S"`
		AGE=`expr $NOW - $LAST`
		if [ "$AGE" -le $DURATION ]
		then
			mylog "NOTICE: CDS was only restarted $AGE out of $DURATION seconds ago. Not restarting now"
			abort_mailout
			return 1
		fi
	fi

	# Emergency restart only checks the lock on this host, not other hosts
	if [ "$1" = "immediate" ]
	then
		if there_is_a_lock
		then
			if lock_is_mine
			then
				mylog "Emergency restart already in progress on this host"
				abort_mailout
				_exit 1
			fi
		fi
	else
		check_lock		# Check that another system isn't currently restarting CDS
		sleep 10
		check_lock		# Recheck. check_lock exits if it's not safe
	fi
	stop_cds $1
	start_cds
	mailout "Restart of CDS on $HOSTNAME is complete"

	return 0
}

i_am_root()
{
	##
	# This script needs to be run as root, so we perform that check here
	##

	ID=`/usr/xpg4/bin/id -u`
	return $ID
}

layer7ping()
{
	# The perl script this calls is embedded at the bottom of this script
	# The layer 7 ping is backgrounded so that if it connects to a hung / filtered port we can timeout
	# since perl IO::Socket timeouts are broken
        L7TMP=$TMPDIR/${MYNAME}.l7tmp.${MYPID}
        perl -x /usr/local/bin/cdsinit $1 >$L7TMP &
        BGPID=$!
        if pid_left_running_after 15 $BGPID nolog
        then
                kill -9 $BGPID > /dev/null 2>&1
		rm -f $L7TMP
                return 1
        fi
        if [ `cat $L7TMP |  grep "HTTP/1.0 200 OK" | wc -l` -eq 1 ]
        then
                rm -f $L7TMP
                return 0
        else
                rm -f $L7TMP
                return 1
        fi
}

##
# main()
##

if i_am_root
then

	case "$1" in
	restart) 
		mailout "Immediate cds restart in progress"
		restart_cds immediate
		_exit ;;
	start)
		mailout "Start cds in progress"
		start_cds
		_exit ;;
	stop)
		mailout "Stop cds in progress"
		stop_cds immediate
		_exit ;;
	status)
		if there_is_a_lock
		then
			echo "The vignette CDS restart mechanism is locked."
			ls -l $LOCKDIR/.lock.*
		else
			echo "The vignette CDS restart mechanism has no locks"
		fi
		/opt/vignette/inst-teamtalk/conf/admin status
		_exit ;;
	*)
		# Rest of script will now run in cron'd supervise / babysit mode. 
		if [ ! -d ${DOCROOT}/fds ]
		then
			mkdir ${DOCROOT}/fds > /dev/null 2>&1
		fi

		##
		# Find out how many connections to Oracle we have got
		# This is for the purpose of MRTG
		##

		ORACONS=`netstat | grep ora | grep EST | wc -l`
		echo $ORACONS > ${DOCROOT}/fds/oracons
	
		##
		# Get the PID of the running CTLDM process
		##
	
		PID=`pgrep ctldm`
	
		if [ `echo "$PID" | wc -l` -gt 1 ]
		then
			# Exit here - two ctldm processes indicate that Vignette is cleaning itself up
			# and doesnt need to be messed around with. After a few seconds the older ctldm
			# process will die, and relinquish control to it's successor. 
			_exit 1
		fi
		
		if [ "$PID" ] # If CTLDM is running
		then
			##
			# Find out how many file descriptors the CTLDM is currently using
			##
			FDS=`/usr/proc/bin/pfiles "$PID" | grep "size" | tail -1 | awk -F: ' { print $1 }'`
			echo $FDS > ${DOCROOT}/fds/fds # for MRTG

			if [ -f /var/tmp/disable ]
			then
				_exit
			fi
			
			if [ "$FDS" -ge 1000 ]
			then
				mailout "Emergency restart of CDS in progress - Reason: $FDS file descriptors in use"
				mylog "CRITICAL - ctldm is using $FDS fd's. Emergency CDS restart required."
				restart_cds immediate
				_exit 0
			fi
	
			if [ "$FDS" -ge ${MAXFDS} ]
			then
				mylog "NOTICE - ctldm is using $FDS fd's, CDS restart required"
				mailout "Automated restart of CDS in progress - Reason: $FDS file descriptors in use"
				restart_cds
				_exit 0
			fi
	
			if [ "$FDS" -ge 300 ]
			then
				mylog "WARNING - ctldm is using $FDS fd's"
			fi
		fi


		if [ -f /var/tmp/disable ]
		then
			_exit
		fi
	
		##
		# Check to see if any running ctlds processes have allocated huge amounts of memory
		# because Vignette memory leaks all over the place
		##

		BIGPIDS=`ps -elf | grep '/opt/vignette/6.0/bin/solaris/ctlds' | awk ' $10 >= 100000 { print $4 } '`
		for BIGPID in $BIGPIDS
		do
			mylog "WARNING: ctlds process $BIGPID has grown too large - Killing."
			safekill $BIGPID
			if pid_left_running_after 10 $BIGPID nolog
			then
				reallykill $BIGPID
			fi
		done

		##
		# Check for other critical Vignette processes, pad, tmd, cmd
		##
		
		# Only check for these processes if the restart mechanism is not locked
		# This is to avoid conflicts when support staff have shut vignette down on purpose
		# or if the system is in the process of being booted up or shutdown
	
		if ! lock_is_mine
		then
			for PROCESS in cmd pad tmd ctldm ctlds
			do
				PID=`pgrep $PROCESS`
				if [ ! "$PID" ]
				then
					# Work out how long the process hasn't been running for
					PROCFILE=${TMPDIR}/${MYNAME}.${PROCESS}
					if [ -f "$PROCFILE" ]
					then
						# There was already a note. There might be a problem
						STARTTIME=`cat $PROCFILE`
						ENDTIME=`date "+%Y%m%d%H%M%S"`
						DUR=`expr $ENDTIME - $STARTTIME`
						if [ "$DUR" -ge "$DURATION" ]
						then
							mylog "CRITICAL - $PROCESS has not been running for the last 20 minutes"
							mailout "CRITICAL - $PROCESS has not been running for the last 20 minutes"
							mailout "Automated restart of CDS in progress - Reason: $PROCESS is not running"
							rm -f $PROCFILE
							restart_cds graceful
						fi
					else
						date "+%Y%m%d%H%M%S" > $PROCFILE
					fi
				else
					PROCFILE=${TMPDIR}/${MYNAME}.${PROCESS}
					rm -f $PROCFILE
				fi
			done
		fi 

		##
		# Now this bit connects to the Vignette deamons over TCP and asks for their status
		# This gets round the situation where Vignette processes are there but have actually hung!
		##

		if ! lock_is_mine
		then
			for PORT in 3737 3738 3739 3740
			do
				if ! layer7ping $PORT
				then
					# Work out how long the port hasn't answered for
					PROCFILE=${TMPDIR}/${MYNAME}.${PORT}
					if [ -f "$PROCFILE" ]
					then
						# There was already a note. There might be a problem
						STARTTIME=`cat $PROCFILE`
						ENDTIME=`date "+%Y%m%d%H%M%S"`
						DUR=`expr $ENDTIME - $STARTTIME`
						if [ "$DUR" -ge "$DURATION" ]
						then
							case "$PORT" in
							3737) SERVICE="ctldm" ;;
							3738) SERVICE="pad" ;;
							3739) SERVICE="tmd" ;;
							3740) SERVICE="cmd" ;;
							esac
							mylog "CRITICAL - Service $SERVICE on port $PORT has not been responding for the last 20 minutes"
							mailout "Automated restart of CDS in progress - Reason: $SERVICE is not responding"
							rm -f $PROCFILE
							restart_cds graceful
						fi
					else
						date "+%Y%m%d%H%M%S" > $PROCFILE
					fi
				else
					PROCFILE=${TMPDIR}/${MYNAME}.${PORT}
					rm -f $PROCFILE
				fi
			done
		fi ;;
	esac

	##
	# Now cope with malfunctions related to the number of Oracle connections open
	##

	PROCFILE=${TMPDIR}/${MYNAME}.oracons
	if [ "$ORACONS" -eq 0 -o "$ORACONS" -ge "$MAXORACON" ]
	then
		# Work out how long there have been problems with the number of Oracle connections

		if [ -f "$PROCFILE" ]
		then
			# There was already a note. There might be a problem
			STARTTIME=`cat $PROCFILE`
			ENDTIME=`date "+%Y%m%d%H%M%S"`
			DUR=`expr $ENDTIME - $STARTTIME`
			if [ "$DUR" -ge "$DURATION" ]
			then
				mylog "CRITICAL - There have been $ORACONS Oracle connections open for the last 20 minutes"
                                mailout "Automated restart of CDS in progress - Reason: Abnormal number (${ORACONS}) of Oracle connections"
				rm -f $PROCFILE
				restart_cds graceful
			fi
		else
			date "+%Y%m%d%H%M%S" > $PROCFILE
		fi
	else
		rm -f $PROCFILE
	fi
else
	echo "You need to be root!"
fi
_exit 0 

##
# Here lies embedded Perl script to perform the code for the layer 7 ping
##

#!/usr/bin/perl

use IO::Socket;

$porty = $ARGV[0];

my $sock = new IO::Socket::INET (
        PeerAddr => 'localhost',
        PeerPort => $porty,
        Proto => 'tcp', 6,
        timeout => '5' );
die "Could not create socket: $!\n" unless $sock;
print $sock "GET /status HTTP/1.0\n\n";
while ( <$sock> ) { print }
close($sock);

