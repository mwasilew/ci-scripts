#!/bin/sh -e
# Copyright (c) 2019 Foundries.io, SPDX-License-Identifier: Apache-2.0
set -o pipefail

HERE=$(dirname $(readlink -f $0))
. $HERE/../helpers.sh

require_params FACTORY

run apk --no-cache add file git

ARCH=amd64
file /bin/busybox | grep -q aarch64 && ARCH=arm64 || true
file /bin/busybox | grep -q armhf && ARCH=arm || true

manifest_arch=$ARCH
[ $manifest_arch = "arm" ] && manifest_arch=armv6
status Grabbing manifest-tool for $manifest_arch
wget -O /bin/manifest-tool https://github.com/estesp/manifest-tool/releases/download/v0.8.0/manifest-tool-linux-$manifest_arch
chmod +x /bin/manifest-tool

if [ -z "$IMAGES" ] ; then
	IMAGES=$(find * -prune -type d)
fi

status Launching dockerd
unset DOCKER_HOST
DOCKER_TLS_CERTDIR= /usr/local/bin/dockerd-entrypoint.sh --raw-logs >/archive/dockerd.log 2>&1 &
for i in `seq 12` ; do
	sleep 1
	docker info >/dev/null 2>&1 && break
	if [ $i = 12 ] ; then
		status Timed out trying to connect to internal docker host
		exit 1
	fi
done

TAG=${GIT_SHA:0:7}

if [ -f /secrets/osftok ] ; then
	mkdir -p $HOME/.docker
fi

echo '<testsuite name="unit-tests">' > /archive/junit.xml
trap 'echo "</testsuite>" >> /archive/junit.xml' TERM INT EXIT

for x in $IMAGES ; do
	# Skip building things that end with .disabled
	echo $x | grep -q -E \\.disabled$ && continue
	unset CHANGED SKIP_ARCHS MANIFEST_PLATFORMS EXTRA_TAGS_$ARCH TEST_CMD

	no_op_tag=0
	CHANGED=$(git diff --name-only $GIT_OLD_SHA..$GIT_SHA $x/)
	if [[ ! -z "$CHANGED" ]]; then
		status "Detected changes to $x"
	else
		status "No changes to $x, tagging only"
		no_op_tag=1
	fi

	conf=$x/docker-build.conf
	if [ -f $conf ] ; then
		echo "Sourcing docker-build.conf for build rules in $x"
		. $conf
	fi

	# check to see if we should skip building this image`
	found=0
	for a in $SKIP_ARCHS ; do
		if [ "$a" = "$ARCH" ] ; then
			status "Skipping build of $x on $ARCH"
			found=1
			break
		fi
	done
	[ $found -eq 1 ] && continue

	# allow the docker-build.conf to override our manifest platforms
	MANIFEST_PLATFORMS="${MANIFEST_PLATFORMS-linux/amd64,linux/arm,linux/arm64}"

	ct_base="hub.foundries.io/${FACTORY}/$x"

	auth=0
	if [ -f /secrets/osftok ] ; then
		status "Doing docker-login to hub.foundries.io with secret"
		docker login hub.foundries.io --username=doesntmatter --password=$(cat /secrets/osftok) | indent
		# sanity check and pull in a cached image if it exists
		run docker pull ${ct_base}:${GIT_OLD_SHA:0:7}-$ARCH || echo "WARNING - no cached image"
		auth=1
	fi

	cd $x
<<<<<<< HEAD
	run docker build --cache-from ${ct_base}:${GIT_OLD_SHA:0:7}-$ARCH -t ${ct_base}:$TAG-$ARCH --force-rm .
=======
	if [ $no_op_tag -eq 1 ] ; then
		status Tagging docker image $x for $ARCH
		docker tag ${ct_base}:${GIT_OLD_SHA:0:7}-$ARCH ${ct_base}:$TAG-$ARCH
	else
		status Building docker image $x for $ARCH
		run docker build --cache-from ${ct_base}::${GIT_OLD_SHA:0:7}-$ARCH -t ${ct_base}:$TAG-$ARCH --force-rm .
	fi

>>>>>>> factory-containers/build.sh: fix modification detection
	if [ $auth -eq 1 ] ; then
		run docker push ${ct_base}:$TAG-$ARCH

		run manifest-tool push from-args \
			--platforms $MANIFEST_PLATFORMS \
			--template ${ct_base}:$TAG-ARCH \
			--target ${ct_base}:$TAG || true
		run manifest-tool push from-args \
			--platforms $MANIFEST_PLATFORMS \
			--template ${ct_base}:$TAG-ARCH \
			--target ${ct_base}:latest || true
	else
		echo "osftoken not provided, skipping publishing step"
	fi

	if [ -n "$TEST_CMD" ] ; then
		status Running test command inside container: $TEST_CMD
		echo "<testcase name=\"test-$x\">" >> /archive/junit.xml
		echo "   docker run --rm --entrypoint=\"\" ${ct_base}:$TAG-$ARCH $TEST_CMD"
		if ! docker run --rm --entrypoint="" ${ct_base}:$TAG-$ARCH $TEST_CMD > /archive/$x-test.log 2>&1 ; then
			status "Testing for $x failed"
			echo "<failure>" >> /archive/junit.xml
			cat /archive/$x-test.log | sed -e 's/</\&lt;/g' -e 's/>/\&gt;/g' >> /archive/junit.xml
			echo "</failure>" >> /archive/junit.xml
		fi
		echo "</testcase>" >> /archive/junit.xml
	fi
	cd ..
done
