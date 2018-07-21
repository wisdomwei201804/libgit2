#!/usr/bin/env bash

set -e

if [ -n "$SKIP_TESTS" ]; then
	exit 0
fi

cleanup() {
	echo "Cleaning up..."

	if [ ! -z "$GITDAEMON_DIR" -a -f "${GITDAEMON_DIR}/pid" ]; then
		kill $(cat "${GITDAEMON_DIR}/pid")
	fi

	if [ ! -z "$SSHD_DIR" -a -f "${SSHD_DIR}/pid" ]; then
		kill $(cat "${SSHD_DIR}/pid")
	fi
}

die() {
	cleanup
	exit $1
}

TMPDIR=${TMPDIR:-/tmp}
USER=${USER:-$(whoami)}

# Configure the test environment; run them early so that we're certain
# that they're started by the time we need them.

echo "##############################################################################"
echo "## Configuring test environment"
echo "##############################################################################"

if [ -z "$SKIP_GITDAEMON_TESTS" ]; then
	echo "Starting git daemon..."
	GITDAEMON_DIR=`mktemp -d ${TMPDIR}/gitdaemon.XXXXXXXX`
	git init --bare "${GITDAEMON_DIR}/test.git"
	git daemon --listen=localhost --export-all --enable=receive-pack --pid-file="${GITDAEMON_DIR}/pid" --base-path="${GITDAEMON_DIR}" "${GITDAEMON_DIR}" 2>/dev/null &
fi

if [ -z "$SKIP_PROXY_TESTS" ]; then
	echo "Starting HTTP proxy..."
	curl -L https://github.com/ethomson/poxyproxy/releases/download/v0.1.0/poxyproxy-0.1.0.jar >poxyproxy.jar
	java -jar poxyproxy.jar -d --port 8080 --credentials foo:bar >/dev/null 2>&1 &
fi

if [ -z "$SKIP_SSH_TESTS" ]; then
	echo "Starting ssh daemon..."
	HOME=`mktemp -d ${TMPDIR}/home.XXXXXXXX`
	SSHD_DIR=`mktemp -d ${TMPDIR}/sshd.XXXXXXXX`
	git init --bare "${SSHD_DIR}/test.git"
	cat >"${SSHD_DIR}/sshd_config" <<-EOF
	Port 2222
	ListenAddress 0.0.0.0
	Protocol 2
	HostKey ${SSHD_DIR}/id_rsa
	PidFile ${SSHD_DIR}/pid
	AuthorizedKeysFile ${HOME}/.ssh/authorized_keys
	LogLevel DEBUG
	RSAAuthentication yes
	PasswordAuthentication yes
	PubkeyAuthentication yes
	ChallengeResponseAuthentication no
	StrictModes no
	# Required here as sshd will simply close connection otherwise
	UsePAM no
	EOF
	ssh-keygen -t rsa -f "${SSHD_DIR}/id_rsa" -N "" -q
	/usr/sbin/sshd -f "${SSHD_DIR}/sshd_config" -E "${SSHD_DIR}/log"

	# Set up keys
	mkdir "${HOME}/.ssh"
	ssh-keygen -t rsa -f "${HOME}/.ssh/id_rsa" -N "" -q
	cat "${HOME}/.ssh/id_rsa.pub" >>"${HOME}/.ssh/authorized_keys"
	while read algorithm key comment; do
		echo "[localhost]:2222 $algorithm $key" >>"${HOME}/.ssh/known_hosts"
	done <"${SSHD_DIR}/id_rsa.pub"

	# Get the fingerprint for localhost and remove the colons so we can
	# parse it as a hex number. Older versions have a different output
	# format.
	if [[ $(ssh -V 2>&1) == OpenSSH_6* ]]; then
		SSH_FINGERPRINT=$(ssh-keygen -F '[localhost]:2222' -f "${HOME}/.ssh/known_hosts" -l | tail -n 1 | cut -d ' ' -f 2 | tr -d ':')
	else
		SSH_FINGERPRINT=$(ssh-keygen -E md5 -F '[localhost]:2222' -f "${HOME}/.ssh/known_hosts" -l | tail -n 1 | cut -d ' ' -f 3 | cut -d : -f2- | tr -d :)
	fi
fi

# Run the tests that do not require network connectivity.

if [ -z "$SKIP_OFFLINE_TESTS" ]; then
	echo ""
	echo "##############################################################################"
	echo "## Running (offline) tests"
	echo "##############################################################################"

	ctest -V -R offline || die $?
fi

if [ -z "$SKIP_ONLINE_TESTS" ]; then
	# Run the various online tests.  The "online" test suite only includes the
	# default online tests that do not require additional configuration.  The
	# "proxy" and "ssh" test suites require further setup.

	echo ""
	echo "##############################################################################"
	echo "## Running (online) tests"
	echo "##############################################################################"

	ctest -V -R online || die $?
fi

if [ -z "$SKIP_GITDAEMON_TESTS" ]; then
	echo ""
	echo "Running gitdaemon tests"
	echo ""

	export GITTEST_REMOTE_URL="git://localhost/test.git"
	ctest -V -R gitdaemon || die $?
	unset GITTEST_REMOTE_URL
fi

if [ -z "$SKIP_PROXY_TESTS" ]; then
	echo ""
	echo "Running proxy tests"
	echo ""

	export GITTEST_REMOTE_PROXY_URL="localhost:8080"
	export GITTEST_REMOTE_PROXY_USER="foo"
	export GITTEST_REMOTE_PROXY_PASS="bar"
	ctest -V -R proxy || die $?
	unset GITTEST_REMOTE_PROXY_URL
	unset GITTEST_REMOTE_PROXY_USER
	unset GITTEST_REMOTE_PROXY_PASS
fi

if [ -z "$SKIP_SSH_TESTS" ]; then
	echo ""
	echo "Running ssh tests"
	echo ""

	export GITTEST_REMOTE_URL="ssh://localhost:2222/$SSHD_DIR/test.git"
	export GITTEST_REMOTE_USER=$USER
	export GITTEST_REMOTE_SSH_KEY="${HOME}/.ssh/id_rsa"
	export GITTEST_REMOTE_SSH_PUBKEY="${HOME}/.ssh/id_rsa.pub"
	export GITTEST_REMOTE_SSH_PASSPHRASE=""
	export GITTEST_REMOTE_SSH_FINGERPRINT="${SSH_FINGERPRINT}"
	ctest -V -R ssh || die $?
	unset GITTEST_REMOTE_URL
	unset GITTEST_REMOTE_USER
	unset GITTEST_REMOTE_SSH_KEY
	unset GITTEST_REMOTE_SSH_PUBKEY
	unset GITTEST_REMOTE_SSH_PASSPHRASE
	unset GITTEST_REMOTE_SSH_FINGERPRINT
fi

cleanup
