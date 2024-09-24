#!/usr/bin/env bash

set -e

DEMO_REPO="https://github.com/patsec/everest-demo.git"
DEMO_BRANCH="mre_external_ocsp"

CSMS_URL="http://localhost:9410"

PROJECT="everest-ac-demo"

usage="usage: $(basename "$0") [-r <repo>] [-b <branch>] [-j|1|2|3|c] [-h]

This script will run EVerest ISO 15118-2 AC charging with external OCPP demos.

Pro Tip: to use a local copy of this everest-demo repo, provide the current
directory to the -r option (e.g., '-r \$(pwd)').

where:
    -r   URL to everest-demo repo to use (default: $DEMO_REPO)
    -b   Branch of everest-demo repo to use (default: $DEMO_BRANCH)
    -c   URL to CSMS (default: $CSMS_URL)
    -1   OCPP v2.0.1 Security Profile 1
    -2   OCPP v2.0.1 Security Profile 2
    -3   OCPP v2.0.1 Security Profile 3
    -h   Show this message"

DEMO_VERSION=
DEMO_COMPOSE_FILE_NAME=

# loop through positional options/arguments
while getopts ':r:b:c:123h' option; do
	case "$option" in
	r) DEMO_REPO="$OPTARG" ;;
	b) DEMO_BRANCH="$OPTARG" ;;
	c) CSMS_URL="$OPTARG" ;;
	1)
		DEMO_VERSION="v2.0.1-sp1"
		DEMO_COMPOSE_FILE_NAME="docker-compose.ocpp201.yml"
		;;
	2)
		DEMO_VERSION="v2.0.1-sp2"
		DEMO_COMPOSE_FILE_NAME="docker-compose.ocpp201.yml"
		;;
	3)
		DEMO_VERSION="v2.0.1-sp3"
		DEMO_COMPOSE_FILE_NAME="docker-compose.ocpp201.yml"
		;;
	h)
		echo -e "$usage"
		exit
		;;
	\?)
		echo -e "illegal option: -$OPTARG\n" >&2
		echo -e "$usage" >&2
		exit 1
		;;
	esac
done

if [[ ! "${DEMO_VERSION}" ]]; then
	echo 'Error: no demo version option provided.'
	echo
	echo -e "$usage"

	exit 1
fi

DEMO_DIR="$(mktemp -d)"

if [[ ! "${DEMO_DIR}" || ! -d "${DEMO_DIR}" ]]; then
	echo 'Error: Failed to create a temporary directory for the demo.'
	exit 1
fi

delete_temporary_directory() {
	echo "Cleaning up Docker Compose project $PROJECT"
	docker compose -p $PROJECT down

	echo "Cleaning up temporary demo directory $DEMO_DIR"
	rm -rf "$DEMO_DIR"
}

trap delete_temporary_directory EXIT

echo "DEMO REPO:    $DEMO_REPO"
echo "DEMO BRANCH:  $DEMO_BRANCH"
echo "DEMO VERSION: $DEMO_VERSION"
echo "DEMO CONFIG:  $DEMO_COMPOSE_FILE_NAME"
echo "DEMO DIR:     $DEMO_DIR"
echo "CSMS URL:     $CSMS_URL"

mkdir "${DEMO_DIR}/everest-demo" || exit 1
cp -a * "${DEMO_DIR}/everest-demo/" || exit 1
cp -a .env "${DEMO_DIR}/everest-demo/.env" || exit 1

cd "${DEMO_DIR}" || exit 1

# echo "Cloning EVerest from ${DEMO_REPO} into ${DEMO_DIR}/everest-demo"
# git clone --branch "${DEMO_BRANCH}" "${DEMO_REPO}" everest-demo

if [[ "$DEMO_VERSION" =~ sp1 ]]; then
	echo "Adding charge station with Security Profile 1 to CSMS (note: profiles in MaEVe start with 0 so SP-0 == OCPP SP-1)"
	curl $CSMS_URL/api/v0/cs/cp001 -H 'content-type: application/json' \
		-d '{"securityProfile": 0, "base64SHA256Password": "3oGi4B5I+Y9iEkYtL7xvuUxrvGOXM/X2LQrsCwf/knA="}'
elif [[ "$DEMO_VERSION" =~ sp2 ]]; then
	echo "Adding charge station with Security Profile 2 to CSMS (note: profiles in MaEVe start with 0 so SP-1 == OCPP SP-2)"
	curl $CSMS_URL/api/v0/cs/cp001 -H 'content-type: application/json' \
		-d '{"securityProfile": 1, "base64SHA256Password": "3oGi4B5I+Y9iEkYtL7xvuUxrvGOXM/X2LQrsCwf/knA="}'
elif [[ "$DEMO_VERSION" =~ sp3 ]]; then
	echo "Adding charge station with Security Profile 3 to CSMS (note: profiles in MaEVe start with 0 so SP-2 == OCPP SP-3)"
	curl $CSMS_URL/api/v0/cs/cp001 -H 'content-type: application/json' -d '{"securityProfile": 2}'
fi

echo "Charge station added to CSMS, adding user token"

curl $CSMS_URL/api/v0/token -H 'content-type: application/json' -d '{
  "countryCode": "GB",
  "partyId": "TWK",
  "type": "RFID",
  "uid": "DEADBEEF",
  "contractId": "GBTWK012345678V",
  "issuer": "Thoughtworks",
  "valid": true,
  "cacheMode": "ALWAYS"
}'

curl $CSMS_URL/api/v0/token -H 'content-type: application/json' -d '{"countryCode": "USA", "partyId": "EonTi", "contractId": "USCPIC001LTON3", "uid": "USCPIC001LTON3", "issuer": "EonTi", "valid": true, "cacheMode": "ALWAYS"}'

echo "API calls to CSMS finished, starting everest"

pushd everest-demo || exit 1

docker compose -p $PROJECT --file "${DEMO_COMPOSE_FILE_NAME}" up -d --wait
docker compose -p $PROJECT cp config-sil-ocpp201-pnc.yaml manager:/ext/source/config/config-sil-ocpp201-pnc.yaml

if [[ "$DEMO_VERSION" =~ sp2 || "$DEMO_VERSION" =~ sp3 ]]; then
	docker compose -p $PROJECT cp manager/patsec_certs.tar.gz manager:/ext/source/build/certs.tar.gz
	docker compose -p $PROJECT exec manager /bin/bash -c "pushd /ext/source/build && tar xf certs.tar.gz"

	echo "Configured everest certs, validating that the chain is set up correctly"
	docker compose -p $PROJECT exec manager /bin/bash -c "pushd /ext/source/build && openssl verify -show_chain -CAfile dist/etc/everest/certs/ca/v2g/V2G_ROOT_CA.pem --untrusted dist/etc/everest/certs/ca/csms/CPO_SUB_CA1.pem --untrusted dist/etc/everest/certs/ca/csms/CPO_SUB_CA2.pem dist/etc/everest/certs/client/csms/CSMS_LEAF.pem"
fi

if [[ "$DEMO_VERSION" =~ sp1 ]]; then
	echo "Copying device DB, configured to SecurityProfile: 1"
	docker compose -p $PROJECT cp manager/device_model_storage_maeve_sp1.db \
		manager:/ext/source/build/dist/share/everest/modules/OCPP201/device_model_storage.db
elif [[ "$DEMO_VERSION" =~ sp2 ]]; then
	echo "Copying device DB, configured to SecurityProfile: 2"
	docker compose -p $PROJECT cp manager/device_model_storage_maeve_sp2.db \
		manager:/ext/source/build/dist/share/everest/modules/OCPP201/device_model_storage.db
elif [[ "$DEMO_VERSION" =~ sp3 ]]; then
	echo "Copying device DB, configured to SecurityProfile: 3"
	docker compose -p $PROJECT cp manager/device_model_storage_maeve_sp3_external.db \
		manager:/ext/source/build/dist/share/everest/modules/OCPP201/device_model_storage.db
fi

echo "Starting software in the loop simulation"
docker compose -p $PROJECT exec manager sh /ext/source/build/run-scripts/run-sil-ocpp201-pnc.sh
