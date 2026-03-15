#!/bin/bash
docker build --network host -t "$1" -f "$(dirname "$0")/Dockerfile" "$(dirname "$0")"
