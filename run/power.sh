#!/usr/bin/env bash
set -eu

# Configure QEMU for graceful shutdown

QEMU_MONPORT=7100
QEMU_POWERDOWN_TIMEOUT=50

_QEMU_PID=/run/qemu.pid
_QEMU_SHUTDOWN_COUNTER=/run/qemu.counter

rm -f "${_QEMU_PID}"
rm -f "${_QEMU_SHUTDOWN_COUNTER}"

_trap(){
    func="$1" ; shift
    for sig ; do
        trap "$func $sig" "$sig"
    done
}

_graceful_shutdown() {

  [ ! -f "${_QEMU_PID}" ] && return
  [ -f "${_QEMU_SHUTDOWN_COUNTER}" ] && return

  set +e

  echo
  echo "Received $1 signal, shutting down..."
  echo 0 > "${_QEMU_SHUTDOWN_COUNTER}"

  # Don't send the powerdown signal because vDSM ignores ACPI signals
  # echo 'system_powerdown' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}" > /dev/null

  # Send shutdown command to host via serial port
  RESPONSE=$(curl -s -m 2 -S http://127.0.0.1:2210/write?command=6 2>&1)

  if [[ ! "${RESPONSE}" =~ "\"success\"" ]] ; then

    echo
    echo "Could not send shutdown command to guest, error: $RESPONSE"

    # If we cannot shutdown the usual way, fallback to the NMI method

    AGENT="${STORAGE}/${BASE}.agent"
    [ -f "$AGENT" ] && AGENT_VERSION=$(cat "${AGENT}") || AGENT_VERSION=1

    if ((AGENT_VERSION > 1)); then

      # Send a NMI interrupt which will be detected by the kernel
      echo 'nmi' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}" > /dev/null
 
    else

      echo
      echo "Please update the VirtualDSM Agent to allow for gracefull shutdowns..."

      PID=$(cat "${_QEMU_PID}")
      kill -15 "${PID}"
      pkill -f qemu-system-x86_64

    fi
  fi

  while [ "$(cat ${_QEMU_SHUTDOWN_COUNTER})" -lt "${QEMU_POWERDOWN_TIMEOUT}" ]; do

    # Increase the counter
    echo $(($(cat ${_QEMU_SHUTDOWN_COUNTER})+1)) > ${_QEMU_SHUTDOWN_COUNTER}

    # Try to connect to qemu
    if echo 'info version'| nc -q 1 -w 1 localhost "${QEMU_MONPORT}" > /dev/null; then

      sleep 1
      #echo "Shutting down, waiting... ($(cat ${_QEMU_SHUTDOWN_COUNTER})/${QEMU_POWERDOWN_TIMEOUT})"

    fi

  done

  echo
  echo "Quitting..."
  echo 'quit' | nc -q 1 -w 1 localhost "${QEMU_MONPORT}" > /dev/null || true

  return
}

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

MON_OPTS="-monitor telnet:localhost:${QEMU_MONPORT},server,nowait,nodelay"
