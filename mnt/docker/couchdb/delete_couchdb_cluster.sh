#!/bin/sh

# Iterate over all folder that starts with couchdb and delete their content
# The folder structure is in the format of couchdb1, couchdb2, couchdb3, etc.

for dir in ./couchdb*; do
    echo "rm -rf ${dir}/data/*"
    rm -rf ${dir}/data/*
    echo "rm -rf ${dir}/data/.[!.]*"
    rm -rf ${dir}/data/.[!.]*
    echo "rm -rf ${dir}/config/docker.ini"
    rm -rf ${dir}/config/docker.ini
done
rm -rf .cluster_initialized
