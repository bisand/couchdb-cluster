#!/bin/bash

# source .env
DEPLOYMENT_NAME=".${DOMAIN_NAME}"
REPLICAS=${COUCHDB_REPLICAS}

# Check if the cluster is already initialized or if node count has changed
if [[ -f /opt/couchdb/data/.cluster_initialized && $(cat /opt/couchdb/data/.cluster_initialized) -eq ${REPLICAS} ]]; then
  echo 'CouchDB cluster already initialized';
  exit 0;
fi

# Find node count from the list of nodes
NODE_COUNT=${REPLICAS}
echo "Node count: $NODE_COUNT"
# Get the old node count. If it doesn't exist, set it to 0
OLD_NODE_COUNT=$(cat /opt/couchdb/data/.cluster_initialized) || OLD_NODE_COUNT=0
echo "Old node count: $OLD_NODE_COUNT"

# Check if the node count has changed
if [ $OLD_NODE_COUNT -eq $NODE_COUNT ]; then
  echo 'Node count has not changed. Aborting initialization script';
  exit 0;
fi

# Make sure the cluster node folders exist. They are in the format of couchdb1, couchdb2, couchdb3, etc.
# With subfolders for config, data and log
DATA_FOLDER_ROOT="/opt/couchdb/data/"
for NODE_ID in $(seq 1 $NODE_COUNT); do
  NODE_FOLDER="${DATA_FOLDER_ROOT}${HOSTNAME_PREFIX}${NODE_ID}"
  mkdir -p "${NODE_FOLDER}/config"
  mkdir -p "${NODE_FOLDER}/data"
  mkdir -p "${NODE_FOLDER}/log"
  # Add the specified text to 00-default.ini if it doesn't exist
  if [ ! -f "${NODE_FOLDER}/config/00-default.ini" ]; then
    cat <<EOL > "${NODE_FOLDER}/config/00-default.ini"
[chttpd]
bind_address = 0.0.0.0

[chttpd_auth]
timeout = 1800

[httpd]
bind_address = 0.0.0.0

[prometheus]
bind_address = 0.0.0.0
EOL
  fi
done

echo 'Running CouchDB initialization script';

# Install curl and jq
apt -y update; apt -y install curl jq

# Define the list of expected nodes. Generate the list based on the node count
ALL_NODES=()
echo "HOSTNAME_PREFIX: ${HOSTNAME_PREFIX}"
echo "DEPLOYMENT_NAME: ${DEPLOYMENT_NAME}"
for NODE_ID in $(seq 1 $NODE_COUNT); do
  NODE="${HOSTNAME_PREFIX}${NODE_ID}${DEPLOYMENT_NAME}"
  echo "Adding node: ${NODE}"
  ALL_NODES+=("${NODE}")
done
echo "ALL_NODES: ${ALL_NODES[@]}"

# Define the list of all nodes and the coordinator node
COORDINATOR="${ALL_NODES[0]}"
ADDITIONAL_NODES=("${ALL_NODES[@]:1}")

echo "Coordinator Node: ${COORDINATOR}"
echo "Additional Nodes: ${ADDITIONAL_NODES[@]}"
echo "All Nodes:        ${ALL_NODES[@]}"

# Check if the coordinator node is healthy
# Keep trying until a 2xx response is received
while true; do
  STATUS_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://${COORDINATOR}:5984/)
  if [[ $STATUS_CODE -ge 200 && $STATUS_CODE -lt 300 ]]; then
    echo "Node ${COORDINATOR} is healthy with status code: $STATUS_CODE"
    break
  else
    echo "Node ${COORDINATOR} not healthy. Status code: $STATUS_CODE"
    sleep 5  # Wait before retrying
  fi
done

# Check if the node count has increased
if [[ $OLD_NODE_COUNT -ne 0 && $OLD_NODE_COUNT -lt $NODE_COUNT ]]; then
  echo 'Adding nodes to the cluster';
  # Add the new nodes to the cluster
  for NODE_ID in $(seq $(($OLD_NODE_COUNT + 1)) $NODE_COUNT); do
    echo "Adding node couchdb${NODE_ID}${DEPLOYMENT_NAME}"
    NODE_ID_FULL="${HOSTNAME_PREFIX}${NODE_ID}${DEPLOYMENT_NAME}"
    curl -X PUT "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_node/_local/_nodes/couchdb@${NODE_ID_FULL}" -d '{}'
    curl "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${NODE_ID_FULL}:5984/_session" -X GET
    curl -X POST --max-time 30 -H "Content-Type: application/json" "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${NODE_ID_FULL}:5984/_cluster_setup" -d '{"action": "finish_cluster"}'
    sleep 1
  done
  echo "${NODE_COUNT}" > /opt/couchdb/data/.cluster_initialized;
  exit 0;
fi

# Check if the node count has decreased
if [[ $OLD_NODE_COUNT -ne 0 && $OLD_NODE_COUNT -gt $NODE_COUNT ]]; then
  echo 'Removing nodes from the cluster';
  # Remove the nodes that are no longer part of the cluster
  for NODE_ID in $(seq $OLD_NODE_COUNT -1 $(($NODE_COUNT + 1))); do
    echo "Removing node ${HOSTNAME_PREFIX}${NODE_ID}${DEPLOYMENT_NAME}"
    NODE_ID_FULL="${HOSTNAME_PREFIX}${NODE_ID}${DEPLOYMENT_NAME}"
    # Get the response from the GET request
    response=$(curl -s -X GET "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_node/_local/_nodes/couchdb@${NODE_ID_FULL}")
    echo "Response: $response"
    # Extract the rev value from the response
    REV=$(echo $response | jq -r '._rev')
    echo "Rev: $REV"
    # Use the rev value in the DELETE request
    curl -X DELETE "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_node/_local/_nodes/couchdb@${NODE_ID_FULL}?rev=${REV}"

    NODE_FOLDER="${DATA_FOLDER_ROOT}${HOSTNAME_PREFIX}${NODE_ID}"
    rm -rf "${NODE_FOLDER}"

    sleep 1
  done
  echo "${NODE_COUNT}" > /opt/couchdb/data/.cluster_initialized;
  exit 0;
fi

# see http://docs.couchdb.org/en/stable/setup/cluster.html#the-cluster-setup-api

# Create the necessary databases
curl "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_session" -X GET
curl -X PUT http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_users
curl -X PUT http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_replicator
curl -X PUT http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_global_changes

sleep 1

# Initialize the cluster
echo "Enabling the cluster"
curl -X POST \
      --max-time 30 \
      -H "Content-Type: application/json" "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_cluster_setup" \
      -d '{"action": "enable_cluster", "bind_address":"0.0.0.0", "username": "'"${COUCHDB_USER}"'", "password":"'"${COUCHDB_USER}"'", "node_count":"'"${NODE_COUNT}"'"}'
echo You may safely ignore the warning above.

sleep 1

for NODE_ID in "${ADDITIONAL_NODES[@]}"
do
  echo "Adding node ${NODE_ID} to the cluster"
  curl -X POST --max-time 30 -H "Content-Type: application/json" "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_cluster_setup" -d '{"action": "enable_cluster", "bind_address":"0.0.0.0", "username": "'"${COUCHDB_USER}"'", "password":"'"${COUCHDB_PASSWORD}"'", "port": 5984, "node_count": "'"${NODE_COUNT}"'", "remote_node": "'"${NODE_ID}"'", "remote_current_user": "'"${COUCHDB_USER}"'", "remote_current_password": "'"${COUCHDB_PASSWORD}"'" }'
  curl -X POST --max-time 30 -H "Content-Type: application/json" "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_cluster_setup" -d '{"action": "add_node", "host":"'"${NODE_ID}"'", "port": 5984, "username": "'"${COUCHDB_USER}"'", "password":"'"${COUCHDB_PASSWORD}"'"}'
  echo You may safely ignore the warning above.
  sleep 1
done

# see http://github.com/apache/couchdb/issues/2858
for NODE_ID in "${ALL_NODES[@]}"
do
  echo "Finishing cluster setup on node ${NODE_ID}"
  curl "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${NODE_ID}:5984/_session" -X GET
  curl -X POST --max-time 30 -H "Content-Type: application/json" "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${NODE_ID}:5984/_cluster_setup" -d '{"action": "finish_cluster"}'
  sleep 1
done

# Check the cluster status
echo "Checking the cluster status"
curl "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_session" -X GET
sleep 1
curl "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_cluster_setup" -X GET
sleep 1

# Fetch the current membership information
MEMBERSHIP=$(curl -s "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_membership" -X GET)
echo "Membership data: $(echo "$MEMBERSHIP" | jq -c .)"

# Parse all_nodes and cluster_nodes
ALL_NODES=$(echo "$MEMBERSHIP" | jq -r '.all_nodes[]')
CLUSTER_NODES=$(echo "$MEMBERSHIP" | jq -r '.cluster_nodes[]')

# Add any missing node to the cluster
for NODE in "${ALL_NODES[@]}"; do
  if ! echo "$ALL_NODES" | grep -q "$NODE" || ! echo "$CLUSTER_NODES" | grep -q "$NODE"; then
    echo "Node $NODE is missing from all_nodes or cluster_nodes. Trying to add it..."
    # Use curl to add the missing node
    curl -X PUT --max-time 30 "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${REACHABLE_NODE_SHORT}:5984/_node/_local/_nodes/${NODE}" -d '{}' || {
      echo "Failed to add node $NODE."
      continue
    }
    sleep 1
  else
    echo "Node $NODE is already present in all_nodes and cluster_nodes."
  fi
done

# Fetch and display the updated membership
UPDATED_MEMBERSHIP=$(curl -s "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${COORDINATOR}:5984/_membership" -X GET)
echo "Updated membership: $(echo "$UPDATED_MEMBERSHIP" | jq -c .)"

echo "Your cluster nodes are available at:"
for NODE_ID in "${ALL_NODES[@]}"
do
  echo "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${NODE_ID}"
done

echo "${NODE_COUNT}" > /opt/couchdb/data/.cluster_initialized;
echo "CouchDB cluster initialized";

