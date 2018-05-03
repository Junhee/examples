#!/bin/sh

# Horizon sample workload to query the cpu load from a sample microservice, calculate a window average, and publish it to Watson IoT Platform
# This workload expects the CPU microservice to be running, unless it is running in mock mode.

# Verify required environment variables are set
checkRequiredEnvVar() {
  varname=$1
  if [ -z $(eval echo \$$varname) ]; then
    echo "Error: Environment variable $varname must be set; exiting."
    exit 2
  else
    echo "  $varname="$(eval echo \$$varname)
  fi
}

# Environment variables that can optionally be set, or default
WIOTP_DOMAIN="${WIOTP_DOMAIN:-internetofthings.ibmcloud.com}"     # set in the pattern deployment_overrides field if you need to override
WIOTP_PEM_FILE="${WIOTP_PEM_FILE:-messaging.pem}"     # the cert to verify the WIoTP MQTT broker
# WIOTP_EDGE_MQTT_IP: local IP or hostname of the WIoTP Edge Connector microservice (enables severability). Otherwise send straight to the wiotp cloud broker.
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"    # reporting interval in seconds
PUBLISH="${PUBLISH:-true}"    # whether or not to actually send data to wiotp
MOCK="${MOCK:-false}"     # if "true", just pretend to call the cpu microservice REST API
VERBOSE="${VERBOSE:-0}"    # set to 1 for verbose output

echo "Optional environment variables (or default values): WIOTP_DOMAIN=$WIOTP_DOMAIN, WIOTP_PEM_FILE=$WIOTP_PEM_FILE, WIOTP_EDGE_MQTT_IP=$WIOTP_EDGE_MQTT_IP, SAMPLE_INTERVAL=$SAMPLE_INTERVAL, PUBLISH=$PUBLISH, MOCK=$MOCK"

# When this workload is running in standalone mode, there are no required env vars.
if [[ "$PUBLISH" == "true" ]]; then
  echo "Checking for required environment variables are set:"
  checkRequiredEnvVar "HZN_ORGANIZATION"      # automatically passed in by Horizon
  checkRequiredEnvVar "HZN_DEVICE_ID"      # automatically passed in by Horizon. Wiotp automatically gives this a value of: g@mygwtype@mygw
fi

# Parse the class id, device type, and device id from HZN_DEVICE_ID. It will have a value like 'g@mygwtype@mygw'
if [[ ! -z "$HZN_DEVICE_ID" ]]; then
  id="$HZN_DEVICE_ID"
  CLASS_ID=${id%%@*}   # the class id is not actually used anymore
  id=${id#*@}
  DEVICE_TYPE=${id%%@*}
  DEVICE_ID=${id#*@}
  if [[ -z "$DEVICE_TYPE" || -z "$DEVICE_ID" ]]; then
    echo 'Error: HZN_DEVICE_ID must have the format: g@mygwtype@mygw'
    exit 2
  fi

  if [[ "$VERBOSE" == 1 ]]; then echo "  DEVICE_TYPE=$DEVICE_TYPE, DEVICE_ID=$DEVICE_ID"; fi
fi

# Check the exit status of the previously run command and exit if nonzero (unless 'continue' is passed in)
checkrc() {
  if [[ $1 -ne 0 ]]; then
    echo "Error: exit code $1 from $2"
    # Sometimes it is useful to not exit on error, because if you do the container restarts so quickly it is hard to get in it a debug
    if [[ "$3" != "continue" ]]; then
      exit $1
    fi
  fi
}

echo 'Starting infinite loop to read from microservice then publish...'
sleep 20
while true; do
  # Get data from a local microservice
  if [[ "$MOCK" == "true" ]]; then
    output='{"YOLO":'$(date +%S)'} 200'
    curlrc=0
  else
    output=$(curl -sS -w %{http_code} "http://yolov3vnc:8359/v1/yolo")
    curlrc=$?     # save this before it gets overwritten
  fi

  httpcode=${output:$((${#output}-3))}    # the last 3 chars are the http code
  json="${output%?[0-9][0-9][0-9]}"   # for the output, get all but the newline and 3 digits of http code
  echo "output=$output, json=$json, httpcode=$httpcode, curlrc=$curlrc"
  if [[ "$curlrc" != 0 ]]; then
    echo "Warning: Curl command to the local yolo microservice returned exit code $curlrc, will try again next interval."
  elif [[ "$httpcode" != 200 ]]; then
    echo "Warning: HTTP code $httpcode from the local yolo microservice REST API, will try again next interval."
  else

    yoloresults=$(echo $json | jq '.yolo')
    json='{"yolo":'$yoloresults'}'

      if [[ "$PUBLISH" == "true" ]]; then
        # Send a "status" event to the Watson IoT Platform containing the data
        #clientId="$CLASS_ID:$HZN_ORGANIZATION:$DEVICE_TYPE:$DEVICE_ID"     # sending as the gateway
        #topic="iot-2/type/$DEVICE_TYPE/id/$DEVICE_ID/evt/status/fmt/json"
        clientId="a:${HZN_AGREEMENTID:0:36}"      # sending as an app - wiotp limit for app id is 36
        topic="iot-2/evt/status/fmt/json"
        if [[ -n "$WIOTP_EDGE_MQTT_IP" ]]; then
          # Send to the local WIoTP Edge Connector microservice mqtt broker, so it can store and forward
          msgHost="$WIOTP_EDGE_MQTT_IP"
        else
          # Send directly to the WIoTP cloud mqtt broker
          msgHost="$HZN_ORGANIZATION.messaging.$WIOTP_DOMAIN"
        fi

        echo mosquitto_pub -h "$msgHost" -p 8883 -i "$clientId" --cafile $WIOTP_PEM_FILE -q 1 -t "$topic" -m "$json"
        mosquitto_pub -h "$msgHost" -p 8883 -i "$clientId" --cafile $WIOTP_PEM_FILE -q 1 -t "$topic" -m "$json" >/dev/null
        checkrc $? "mosquitto_pub $msgHost" "continue"
      else
        echo "Yolo objects detected: $result"
      fi
  fi

  # Pause before looping again
  sleep $SAMPLE_INTERVAL
done
# Not reached