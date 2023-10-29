#!/bin/bash

##### Inputs #####
#TYPE= MICROSERVICE | WEBAPP
#PACKAGE_LOCATION= {Location of the binary to upload to c8y}
#TENANT_URL= {Tenant base URL}
#AUTHORIZATION_CODE= {Base64 encoded string}
#APPLICATION_NAME= {Name of the application in c8y}
#CONTEXT_PATH= {Context path to c8y after deployment}
#DELETE_EXISTING= TRUE | FALSE - FALSE by default
##################

gather_input () {
	echo "[INFO] - Parsing input"
	TYPE="$1"
	PACKAGE_LOCATION="$2"
	TENANT_URL="$3"
	AUTHORIZATION_CODE="$4"
	APPLICATION_NAME="$5"
	CONTEXT_PATH="$6"
	DELETE_EXISTING="$7"

	if [ "${TYPE}" != "MICROSERVICE" ] && [ "${TYPE}" != "HOSTED" ]
	then
		echo "[ERROR] - Unsupported deployment type ${TYPE}"
		exit 1
	fi

	if [ ! -f ${PACKAGE_LOCATION} ]
	then
		echo "[ERROR] - Binary ${PACKAGE_LOCATION} doesn't exists"
		exit 1
	fi

	if [ ${DELETE_EXISTING} != "true" ] && [ ${DELETE_EXISTING} != "false" ]
        then
                echo "[ERROR] - Unsupported operation DELETE_EXISTING=${DELETE_EXISTING}"
                exit 1
        fi

	ENCODED_APPLICATION_NAME=`jq -rn --arg x "$APPLICATION_NAME" '$x|@uri'`
}

check_if_existing () {
	check=$(curl -H "Authorization:Basic ${AUTHORIZATION_CODE}" "${TENANT_URL}/application/applications?name=${ENCODED_APPLICATION_NAME}")

	if [ "x$(echo $check | jq -r .error)" != "xnull" ]
	then
		echo "[ERROR] - Unable to connect to tenant URL"
		exit 1
	fi

	echo $(echo $check | jq -r .applications[0].id)
}

get_app_id () {
	app=$(curl -H "Authorization:Basic ${AUTHORIZATION_CODE}" "${TENANT_URL}/application/applicationsByName/${ENCODED_APPLICATION_NAME}")
	if [ "x$(echo $app | jq -r .error)" != "xnull" ]
        then
                echo "[ERROR] - Unable to get application id"
                exit 1
        fi

	echo $(echo $app | jq -r .applications[0].id)
}

create_app () {
	if [ "${TYPE}" == "MICROSERVICE" ]
	then
                curl -X POST -s -d \
		    "{\"name\":\"${APPLICATION_NAME}\",\"type\":\"${TYPE}\",\"key\":\"${CONTEXT_PATH}-application-key\"}" \
		    -H "Authorization: Basic ${AUTHORIZATION_CODE}" \
		    -H "Content-type: application/json" \
		    "${TENANT_URL}/application/applications"
	fi

	if [ "${TYPE}" == "HOSTED" ]
	then
		curl -X POST -s -d \
                    "{\"name\":\"${APPLICATION_NAME}\",\"type\":\"${TYPE}\",\"key\":\"${CONTEXT_PATH}-application-key\",\"resourcesUrl\":\"/\", \"contextPath\": \"$CONTEXT_PATH\"}" \
                    -H "Authorization: Basic ${AUTHORIZATION_CODE}" \
		    -H "Content-type: application/vnd.com.nsn.cumulocity.application+json;charset=UTF-8;ver=0.9" \
                    "${TENANT_URL}/application/applications"
	fi
			
	APP_ID=$(get_app_id)
	if [ "x${APP_ID}" != "xnull" ]
	then
		echo "[INFO] - Application created successfully with ID: ${APP_ID}"
		CREATED="true"
	else
		echo "[ERROR] - Unable to create application"
		exit 1
	fi
}

delete_app () {
	APP_ID=$(check_if_existing)
	if [ "x$APP_ID" == "xnull" ]
	then
		echo "[INFO] - Application doesn't exist, nothing to delete"
	else
		echo "[INFO] - Deleting ${APP_ID}"
		curl -X DELETE -s -H "Authorization: Basic ${AUTHORIZATION_CODE}" \
			-H "Content-type: application/json" \
			"${TENANT_URL}/application/applications/${APP_ID}"
	fi
}

upload_binary () {
	echo "[INFO] - Uploading binary ${PACKAGE_LOCATION} to application ${APP_ID}"

        UPLOADED=$(curl -F "data=@${PACKAGE_LOCATION}" \
		-H "Authorization: Basic ${AUTHORIZATION_CODE}" \
		"${TENANT_URL}/application/applications/${APP_ID}/binaries")

	if [ "x$(echo $UPLOADED | jq -r .error)" != "xnull" ] && [ "x$(echo $UPLOADED | jq -r .error)" != "x" ]
	then
		echo "[ERROR] - Binary upload failed - $(echo $UPLOADED | jq -r .message)"
		exit 1
	else
		echo "[INFO] - Binary uploaded successfully!"
	fi
}

subscribe_ms () {
	tenant=$(curl -H "Authorization:Basic ${AUTHORIZATION_CODE}" "${TENANT_URL}/application/applications/${APP_ID}/bootstrapUser")
	TENANT=`echo $tenant | jq -r .tenant`

	if [ "x${TENANT}" == "xnull" ]
	then
		echo "[ERROR] - Unable to get the tenant ID for subscription"
		exit 1
	fi

	echo "[INFO] - Subscribing ${APP_ID} to tenant id ${TENANT}"

	curl -X POST -d '{"application":{"id": "'${APP_ID}'"}}'  \
		-H "Authorization: Basic ${AUTHORIZATION_CODE}" \
		-H "Content-type: application/json" \
		"${TENANT_URL}/tenant/tenants/${TENANT}/applications"

}

enable_ui () {
	upload=$(curl -H "Authorization:Basic ${AUTHORIZATION_CODE}" "${TENANT_URL}/application/applications/${APP_ID}/binaries?pageSize=50")
	UPLOAD=`echo $upload | jq -C -r '[.attachments[] | {id: .id, created: .created}] | sort_by(.created)|reverse[0] | .id'`
	
	if [ "x$UPLOAD" == "xnull" ]
	then
		echo "[ERROR] - Unable to get the binary id for ${APP_ID}"
		exit 1
	fi

	echo "[INFO] - Uploaded binary ID - $UPLOAD to be set as active"

	curl -X PUT -s \
		-d '{"id":"'${APP_ID}'","activeVersionId":"'$UPLOAD'"}' \
		-H "Authorization: Basic ${AUTHORIZATION_CODE}" \
		-H "Content-type: application/json" \
		"${TENANT_URL}/application/applications/${APP_ID}"
}

subscribe () {
	if [ "${TYPE}" == "MICROSERVICE" ]
	then
                 subscribe_ms
	fi

	if [ "${TYPE}" == "HOSTED" ]
	then
		enable_ui
	fi
}

##### START #####
gather_input "$@"

if [ ${DELETE_EXISTING} == "true" ]
then
	delete_app
	create_app
	upload_binary
	subscribe
else
	APP_ID=$(check_if_existing)
        if [ "x$APP_ID" == "xnull" ]
	then
		echo "[INFO] - Application doesn't exist, creating it"
		create_app
	fi
        upload_binary
	if [ "x${CREATED}" == "xtrue" ] || [ "${TYPE}" == "HOSTED" ]
	then
	        subscribe
	fi
fi

