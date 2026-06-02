#!/bin/bash
# Command: ssh_setup - Setup SSH connectivity

ssh_setup_help() {
    echo "Usage:"
    echo "  Setup mode:   $0 ssh_setup -setup -user <username> -hosts \"host1 host2\" [options]"
    echo "  Verify mode:  $0 ssh_setup -verify -user <username> -hosts \"host1 host2\" [options]"
    echo ""
    echo "Common options:"
    echo "  -hosts \"<space separated hostlist>\""
    echo "  -hostfile <absolute path of cluster configuration file>"
    echo "  -shared     : For NFS/shared home directories"
    echo "  -advanced   : Setup SSH between remote hosts as well (default in setup mode)"
    echo "  -simple     : Only setup SSH from local to remote hosts (override -advanced)"
    echo "  -exverify   : Perform exhaustive verification (all hosts to all hosts)"
    echo "  -confirm    : Skip confirmation prompts (default in setup mode)"
    echo "  -usePassphrase : Use passphrase for SSH key"
    echo ""
    echo "Setup mode defaults:"
    echo "  -confirm yes -noPromptPassphrase yes -advanced yes"
}
run_ssh() {
#!/bin/sh

numargs=$#

ADVANCED=false
CONFIRM=no
SHARED=false
i=1
USR=$USER
MODE=""

if test -z "$TEMP"
then
  TEMP=/tmp
fi

IDENTITY=id_rsa
LOGFILE=$TEMP/sshUserSetup_`date +%F-%H-%M-%S`.log
PASSPHRASE=no
RERUN_SSHKEYGEN=no
NO_PROMPT_PASSPHRASE=no
EXHAUSTIVE_VERIFY=false

while [ $i -le $numargs ]
do
  j=$1 
  if [ $j = "-hosts" ] 
  then
     HOSTS=$2
     shift 1
     i=`expr $i + 1`
  fi
  if [ $j = "-user" ] 
  then
     USR=$2
     shift 1
     i=`expr $i + 1`
   fi
  if [ $j = "-logfile" ] 
  then
     LOGFILE=$2
     shift 1
     i=`expr $i + 1`
   fi
  if [ $j = "-confirm" ] 
  then
     CONFIRM=yes
   fi
  if [ $j = "-hostfile" ] 
  then
     CLUSTER_CONFIGURATION_FILE=$2
     shift 1
     i=`expr $i + 1`
   fi
  if [ $j = "-usePassphrase" ] 
  then
     PASSPHRASE=yes
   fi
  if [ $j = "-noPromptPassphrase" ] 
  then
     NO_PROMPT_PASSPHRASE=yes
   fi
  if [ $j = "-shared" ] 
  then
     SHARED=true
   fi
  if [ $j = "-exverify" ] 
  then
     EXHAUSTIVE_VERIFY=true
   fi
  if [ $j = "-advanced" ] 
  then
     ADVANCED=true
   fi
  if [ $j = "-simple" ] 
  then
     ADVANCED=false
   fi
  if [ $j = "-setup" ] 
  then
     MODE="setup"
     if [ "$CONFIRM" = "no" ]; then
         CONFIRM=yes
     fi
     if [ "$PASSPHRASE" = "no" ]; then
         NO_PROMPT_PASSPHRASE=yes
     fi
     if [ "$ADVANCED" = "false" ]; then
         ADVANCED=true
     fi
   fi
  if [ $j = "-verify" ] 
  then
     MODE="verify"
   fi
  if [ $j = "-help" ] 
  then
     echo "Usage:"
     echo "  Setup mode:   $0 ssh -setup -user <username> -hosts \"host1 host2\" [options]"
     echo "  Verify mode:  $0 ssh -verify -user <username> -hosts \"host1 host2\" [options]"
     echo ""
     echo "Common options:"
     echo "  -hosts \"<space separated hostlist>\""
     echo "  -hostfile <absolute path of cluster configuration file>"
     echo "  -shared     : For NFS/shared home directories"
     echo "  -advanced   : Setup SSH between remote hosts as well (default in setup mode)"
     echo "  -simple     : Only setup SSH from local to remote hosts (override -advanced)"
     echo "  -exverify   : Perform exhaustive verification (all hosts to all hosts)"
     echo "  -confirm    : Skip confirmation prompts (default in setup mode)"
     echo "  -usePassphrase : Use passphrase for SSH key"
     echo ""
     echo "Setup mode defaults:"
     echo "  -confirm yes -noPromptPassphrase yes -advanced yes"
     exit 0
   fi
  i=`expr $i + 1`
  shift 1
done

if [ "$MODE" = "setup" ]
then
    if [ -z "$CONFIRM" ] || [ "$CONFIRM" = "no" ]; then
        CONFIRM=yes
    fi
    if [ -z "$NO_PROMPT_PASSPHRASE" ] || [ "$NO_PROMPT_PASSPHRASE" = "no" ]; then
        NO_PROMPT_PASSPHRASE=yes
    fi
    if [ -z "$ADVANCED" ] || [ "$ADVANCED" = "false" ]; then
        ADVANCED=true
    fi
	if [ -z "$EXHAUSTIVE_VERIFY" ] || [ "$EXHAUSTIVE_VERIFY" = "false" ]; then
        EXHAUSTIVE_VERIFY=true
    fi
fi

if [ "$MODE" = "verify" ]
then
    if [ -z "$EXHAUSTIVE_VERIFY" ] || [ "$EXHAUSTIVE_VERIFY" = "false" ]; then
        EXHAUSTIVE_VERIFY=true
    fi
    if [ -z "$ADVANCED" ] || [ "$ADVANCED" = "false" ]; then
        ADVANCED=false
    fi
fi

if test -z "$HOSTS"
then
   if test -n "$CLUSTER_CONFIGURATION_FILE" && test -f "$CLUSTER_CONFIGURATION_FILE"
   then
      HOSTS=`awk '$1 !~ /^#/ { str = str " " $1 } END { print str }' $CLUSTER_CONFIGURATION_FILE` 
   elif ! test -f "$CLUSTER_CONFIGURATION_FILE"
   then
     echo "Please specify a valid and existing cluster configuration file."
   fi
fi

if test -z "$HOSTS" || test -z "$USR" || test -z "$MODE"
then
ssh_setup_help
exit 1
fi

if [ -d $LOGFILE ]; then
    echo $LOGFILE is a directory, setting logfile to $LOGFILE/ssh.log
    LOGFILE=$LOGFILE/ssh.log
fi

echo The output of this script is also logged into $LOGFILE | tee -a $LOGFILE
if [ `echo $?` != 0 ]; then
    echo Error writing to the logfile $LOGFILE, Exiting
    exit 1
fi

SSH="/usr/bin/ssh"
SCP="/usr/bin/scp"
SSH_KEYGEN="/usr/bin/ssh-keygen"

# Function: get current hostname
get_current_host() {
    hostname 2>/dev/null || uname -n 2>/dev/null || echo "localhost"
}

calculateOS()
{
    platform=`uname -s`
    case "$platform"
    in
       "SunOS")  os=solaris;;
       "Linux")  os=linux;;
       "HP-UX")  os=hpunix;;
         "AIX")  os=aix;;
             *)  echo "Sorry, $platform is not currently supported." | tee -a $LOGFILE
                 exit 1;;
    esac
    echo "Platform: $platform" | tee -a $LOGFILE
}
calculateOS
BITS=1024
ENCR="rsa"

if [ $platform = "Linux" ]
then
    PING="/bin/ping"
else
    PING="/usr/sbin/ping"
fi

echo "==========================================" | tee -a $LOGFILE
echo "Mode: $MODE" | tee -a $LOGFILE
echo "User: $USR" | tee -a $LOGFILE
echo "Hosts: $HOSTS" | tee -a $LOGFILE
echo "==========================================" | tee -a $LOGFILE

# Check for required binaries
PATH_ERROR=0
if test ! -x $SSH ; then
    echo "ssh not found at $SSH. Please set SSH_PATH variable." | tee -a $LOGFILE
    PATH_ERROR=1
fi 
if test ! -x $SCP ; then
    echo "scp not found at $SCP. Please set SCP_PATH variable." | tee -a $LOGFILE
    PATH_ERROR=1
fi 
if test ! -x $SSH_KEYGEN ; then
    echo "ssh-keygen not found at $SSH_KEYGEN. Please set SSH_KEYGEN_PATH variable." | tee -a $LOGFILE
    PATH_ERROR=1
fi 
if test ! -x $PING ; then
    echo "ping not found at $PING. Please set PING_PATH variable." | tee -a $LOGFILE
    PATH_ERROR=1
fi 
if [ $PATH_ERROR = 1 ]; then
    echo "ERROR: one or more of the required binaries not found, exiting" | tee -a $LOGFILE
    exit 1
fi

# Function: ping check
ping_check() {
    echo "Ping connectivity check:" | tee -a $LOGFILE
    echo "========================" | tee -a $LOGFILE
    
    alivehosts=""
    deadhosts=""
    
    for host in $HOSTS
    do
        if [ $platform = "SunOS" ]; then
            $PING -s $host 5 5 > /dev/null 2>&1
        elif [ $platform = "HP-UX" ]; then
            $PING $host -n 5 -m 5 > /dev/null 2>&1
        else
            $PING -c 5 -w 5 $host > /dev/null 2>&1
        fi
        
        if [ $? = 0 ]
        then
            echo "✓ $host" | tee -a $LOGFILE
            alivehosts="$alivehosts $host"
        else
            echo "✗ $host" | tee -a $LOGFILE
            deadhosts="$deadhosts $host"
        fi
    done
    
    if test -z "$deadhosts"
    then
        echo "All hosts are reachable via ping." | tee -a $LOGFILE
        return 0
    else
        echo "Some hosts are not reachable via ping:" $deadhosts | tee -a $LOGFILE
        echo "Please ensure all hosts are up and reachable." | tee -a $LOGFILE
        return 1
    fi
}

# Function: verify SSH connectivity
verify_ssh() {
    local from_host=$1
    local to_host=$2
    local ssh_cmd=$SSH
    
    if [ "$SHARED" = "true" ] && [ "$from_host" != "local" ]
    then
        ssh_cmd="$SSH -i .ssh/${IDENTITY}_${from_host}"
    fi
    
    if [ "$from_host" = "local" ]
    then
        # From local host
        $SSH -o BatchMode=yes -o ConnectTimeout=5 -l $USR $to_host "/bin/sh -c 'exit 0'" >/dev/null 2>&1
    else
        # From remote host to another host
        $SSH -o BatchMode=yes -o ConnectTimeout=5 -l $USR $from_host "$ssh_cmd -o BatchMode=yes -o ConnectTimeout=5 -l $USR $to_host \"/bin/sh -c 'exit 0'\"" >/dev/null 2>&1
    fi
    
    return $?
}

# Function: basic verification (local to all hosts)
basic_verification() {
    echo "Basic SSH connectivity verification (local -> all hosts):" | tee -a $LOGFILE
    echo "========================================================" | tee -a $LOGFILE
    
    for host in $HOSTS
    do
        if verify_ssh "local" "$host"
        then
            echo "local -> $host: success" | tee -a $LOGFILE
        else
            echo "local -> $host: failed" | tee -a $LOGFILE
        fi
    done
    echo
}


exhaustive_verification() {
    echo "Exhaustive SSH connectivity verification:" | tee -a $LOGFILE
    echo "==========================================" | tee -a $LOGFILE
    
    # Print header
    printf "%-10s" "From\\To"
    for serverhost in $HOSTS
    do
        printf " %-10s" $serverhost
    done
    printf "\n"
    
    for clienthost in $HOSTS
    do
        printf "%-10s" $clienthost
        
        for serverhost in $HOSTS
        do

            if verify_ssh "$clienthost" "$serverhost"
            then
                printf " %-10s" "success"
            else
                printf " %-10s" "failed"
            fi
        done
        printf "\n"
    done
    echo
}

# Function: advanced verification (first host to all hosts)
advanced_verification() {
    firsthost=`echo $HOSTS | awk '{print $1}; END { }'`
    echo "Advanced SSH connectivity verification ($firsthost -> all hosts):" | tee -a $LOGFILE
    echo "=================================================================" | tee -a $LOGFILE
    
    for host in $HOSTS
    do
        if verify_ssh "$firsthost" "$host"
        then
            echo "$firsthost -> $host: success" | tee -a $LOGFILE
        else
            echo "$firsthost -> $host: failed" | tee -a $LOGFILE
        fi
    done
    echo
}

# Function: setup SSH
setup_ssh() {
    echo "Starting SSH setup with default options:" | tee -a $LOGFILE
    echo "  - Skip confirmation prompts (CONFIRM=yes)" | tee -a $LOGFILE
    echo "  - No passphrase prompts (NO_PROMPT_PASSPHRASE=yes)" | tee -a $LOGFILE
    echo "  - Advanced mode enabled (ADVANCED=true)" | tee -a $LOGFILE
    echo
    
    # Create local .ssh directory
    echo "Creating .ssh directory on local host..." | tee -a $LOGFILE
    mkdir -p $HOME/.ssh | tee -a $LOGFILE
    touch $HOME/.ssh/authorized_keys $HOME/.ssh/known_hosts | tee -a $LOGFILE
    chmod 644 $HOME/.ssh/authorized_keys $HOME/.ssh/known_hosts | tee -a $LOGFILE
    
    # Create SSH config
    echo "Host *" > $HOME/.ssh/config
    echo "ForwardX11 no" >> $HOME/.ssh/config
    chmod 644 $HOME/.ssh/config
    
    # Generate SSH key if needed
    if ! test -f $HOME/.ssh/${IDENTITY} || ! test -f $HOME/.ssh/${IDENTITY}.pub
    then
        echo "Generating SSH key pair (no passphrase)..." | tee -a $LOGFILE
        $SSH_KEYGEN -t $ENCR -b $BITS -f $HOME/.ssh/${IDENTITY} -N '' | tee -a $LOGFILE
    else
        echo "SSH key pair already exists, using existing keys." | tee -a $LOGFILE
    fi
    
    # Determine remote hosts to configure
    if [ $SHARED = "true" ]
    then
        if [ $USER = $USR ]
        then
            REMOTEHOSTS=""
        else
            firsthost=`echo $HOSTS | awk '{print $1}; END { }'`
            REMOTEHOSTS="${firsthost}"
        fi
    else
        REMOTEHOSTS="$HOSTS"
    fi
    
    # Setup each remote host
    for host in $REMOTEHOSTS
    do
        echo "Setting up SSH on remote host $host..." | tee -a $LOGFILE
        
        # Create .ssh directory on remote host
        echo "  Creating .ssh directory and setting permissions..." | tee -a $LOGFILE
        $SSH -o StrictHostKeyChecking=no -x -l $USR $host "/bin/sh -c \"mkdir -p .ssh; chmod og-w . .ssh; touch .ssh/authorized_keys .ssh/known_hosts; chmod 644 .ssh/authorized_keys .ssh/known_hosts\"" >/dev/null 2>&1
        
        # Copy public key to remote host
        echo "  Copying public key to remote host..." | tee -a $LOGFILE
        $SCP -o BatchMode=yes $HOME/.ssh/${IDENTITY}.pub $USR@$host:.ssh/authorized_keys >/dev/null 2>&1
        
        if [ $? -ne 0 ]
        then
            echo "  Warning: SCP failed, trying with password prompt..." | tee -a $LOGFILE
            $SCP $HOME/.ssh/${IDENTITY}.pub $USR@$host:.ssh/authorized_keys | tee -a $LOGFILE
        fi
        
        # Add local public key to local authorized_keys
        cat $HOME/.ssh/${IDENTITY}.pub >> $HOME/.ssh/authorized_keys
    done
    
    # Advanced setup (setup SSH between remote hosts)
    if [ "$ADVANCED" = "true" ]
    then
        echo "Setting up SSH between remote hosts (advanced mode)..." | tee -a $LOGFILE
        
        for host in $HOSTS
        do
            echo "  Configuring SSH on $host..." | tee -a $LOGFILE
            
            # Generate key on remote host if needed
            if [ "$SHARED" = "true" ]
            then
                IDENTITY_FILE_NAME=${IDENTITY}_$host
            else
                IDENTITY_FILE_NAME=${IDENTITY}
            fi
            
            $SSH -o BatchMode=yes -o ConnectTimeout=5 -l $USR $host " /bin/sh -c \"if ! test -f .ssh/${IDENTITY_FILE_NAME}; then $SSH_KEYGEN -t $ENCR -b $BITS -f .ssh/${IDENTITY_FILE_NAME} -N '' >/dev/null 2>&1; echo 'Generated key on $host'; fi\"" | tee -a $LOGFILE
            
            # For non-shared homes, collect all public keys
            if [ "$SHARED" != "true" ]
            then
                $SCP -o BatchMode=yes $USR@$host:.ssh/${IDENTITY}.pub $HOME/.ssh/${IDENTITY}.pub.$host >/dev/null 2>&1
                if [ -f $HOME/.ssh/${IDENTITY}.pub.$host ]
                then
                    cat $HOME/.ssh/${IDENTITY}.pub.$host >> $HOME/.ssh/authorized_keys
                    rm -f $HOME/.ssh/${IDENTITY}.pub.$host
                fi
            fi
        done
        
        # Update authorized_keys on all hosts for non-shared homes
        if [ "$SHARED" != "true" ]
        then
            echo "  Distributing authorized_keys to all hosts..." | tee -a $LOGFILE
            for targethost in $REMOTEHOSTS
            do
                $SCP -o BatchMode=yes $HOME/.ssh/authorized_keys $USR@$targethost:.ssh/authorized_keys >/dev/null 2>&1
                if [ $? -ne 0 ]
                then
                    echo "  Warning: Failed to copy authorized_keys to $targethost" | tee -a $LOGFILE
                fi
            done
        fi
    fi
    
    echo "SSH setup completed." | tee -a $LOGFILE
}

# Main execution
echo

# Always do ping check first
if ! ping_check
then
    echo "Ping check failed. Exiting." | tee -a $LOGFILE
    exit 1
fi

case "$MODE" in
    "setup")
        setup_ssh
        echo
        echo "Verification after setup:" | tee -a $LOGFILE
        echo "========================" | tee -a $LOGFILE
        if [ "$EXHAUSTIVE_VERIFY" = "true" ]
        then
            exhaustive_verification
        fi
        ;;
        
    "verify")
        if [ "$EXHAUSTIVE_VERIFY" = "true" ]
        then
            exhaustive_verification
        elif [ "$ADVANCED" = "true" ]
        then
            advanced_verification
        fi
        ;;
        
    *)
        echo "Unknown mode: $MODE" | tee -a $LOGFILE
        exit 1
        ;;
esac

}
